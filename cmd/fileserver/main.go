package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var (
	addr         = flag.String("addr", "0.0.0.0:3000", "endereço para escutar (IPv4)")
	baseDir      = flag.String("base", "./tmp", "diretório base dos arquivos")
	throttleKbps = flag.Int("throttle-kbps", 0, "limite de envio por conexão (kB/s), 0 = sem limite")
	chunkSize    = flag.Int("chunk", 64*1024, "tamanho do bloco em bytes")
)

func main() {
	flag.Parse()

	// garante base abs
	absBase, err := filepath.Abs(*baseDir)
	if err != nil {
		panic(err)
	}
	if err := os.MkdirAll(absBase, 0o755); err != nil {
		panic(err)
	}

	ln, err := net.Listen("tcp4", *addr)
	if err != nil {
		panic(err)
	}
	fmt.Println("[fileserver] listening on", *addr, "base", absBase)

	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go handleConn(c, absBase)
	}
}

func handleConn(c net.Conn, base string) {
	defer c.Close()
	r := bufio.NewReader(c)
	w := bufio.NewWriter(c)

	// primeira linha: GET <name> <offset>\r\n
	line, err := r.ReadString('\n')
	if err != nil {
		return
	}
	line = strings.TrimSpace(line)
	if !strings.HasPrefix(line, "GET ") {
		fmt.Fprint(w, "ERR bad request\r\n")
		_ = w.Flush()
		return
	}
	parts := strings.Fields(line)
	if len(parts) != 3 {
		fmt.Fprint(w, "ERR bad request\r\n")
		_ = w.Flush()
		return
	}
	name := parts[1]
	offStr := parts[2]

	// sanitiza caminho (sem subir diretórios)
	clean := filepath.Clean("/" + name) // prefix para evitar colapsos
	if strings.Contains(clean, "..") {
		fmt.Fprint(w, "ERR invalid name\r\n")
		_ = w.Flush()
		return
	}
	full := filepath.Join(base, clean)

	offset, err := strconv.ParseInt(offStr, 10, 64)
	if err != nil || offset < 0 {
		fmt.Fprint(w, "ERR invalid offset\r\n")
		_ = w.Flush()
		return
	}

	f, err := os.Open(full)
	if err != nil {
		fmt.Fprint(w, "ERR not found\r\n")
		_ = w.Flush()
		return
	}
	defer f.Close()

	// seek para o offset
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		fmt.Fprint(w, "ERR seek error\r\n")
		_ = w.Flush()
		return
	}

	buf := make([]byte, *chunkSize)
	var sentSinceTick int
	var tick = time.Now()

	for {
		n, rerr := f.Read(buf)
		if n > 0 {
			// header + payload
			fmt.Fprintf(w, "DATA %d\r\n", n)
			if _, err := w.Write(buf[:n]); err != nil {
				return
			}
			// throttle simples
			if *throttleKbps > 0 {
				sentSinceTick += n
				limit := (*throttleKbps) * 1024
				elapsed := time.Since(tick)
				if sentSinceTick > limit {
					// se enviou mais que o limite no intervalo de 1s, dorme o restante
					if elapsed < time.Second {
						time.Sleep(time.Second - elapsed)
					}
					tick = time.Now()
					sentSinceTick = 0
				} else if elapsed >= time.Second {
					tick = time.Now()
					sentSinceTick = 0
				}
			}
		}
		if rerr == io.EOF {
			fmt.Fprint(w, "EOF\r\n")
			_ = w.Flush()
			return
		}
		if rerr != nil {
			return
		}
		if err := w.Flush(); err != nil {
			return
		}
	}
}
