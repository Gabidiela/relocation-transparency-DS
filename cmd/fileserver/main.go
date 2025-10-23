// ============================ cmd/tcp_fileserver/main.go ============================
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

func main() {
    throttleKB := flag.Int("throttle-kbps", 0, "limite de envio em KB/s (0 = sem limite)")
    addr := flag.String("addr", ":5000", "endereço TCP para escutar")
    base := flag.String("base", "/srv/files", "diretório base dos arquivos")
    flag.Parse()

    if err := os.MkdirAll(*base, 0o755); err != nil { panic(err) }

    ln, err := net.Listen("tcp", *addr)
    if err != nil { panic(err) }
    fmt.Println("fileserver escutando em", *addr, "base=", *base)

    for {
        c, err := ln.Accept()
        if err != nil { continue }
        go handleConn(c, *base, *throttleKB)
    }
}

func handleConn(c net.Conn, base string, throttleKB int) {
    defer c.Close()
    r := bufio.NewReader(c)
    w := bufio.NewWriter(c)

    line, err := r.ReadString('\n')
    if err != nil { return }

    parts := strings.Fields(strings.TrimSpace(line))
    if len(parts) != 3 || strings.ToUpper(parts[0]) != "GET" {
        fmt.Fprint(w, "ERR bad request\r\n"); _ = w.Flush(); return
    }
    name := parts[1]
    off, _ := strconv.ParseInt(parts[2], 10, 64)

    fpath := filepath.Join(base, filepath.Clean("/"+name))
    fi, err := os.Stat(fpath)
    if err != nil || fi.IsDir() { fmt.Fprint(w, "ERR not found\r\n"); _ = w.Flush(); return }

    f, err := os.Open(fpath)
    if err != nil { fmt.Fprint(w, "ERR open\r\n"); _ = w.Flush(); return }
    defer f.Close()

    if _, err := f.Seek(off, io.SeekStart); err != nil { fmt.Fprint(w, "ERR seek\r\n"); _ = w.Flush(); return }

    buf := make([]byte, 256*1024)
    for {
        n, er := f.Read(buf)
        if n > 0 {
            // header + payload + flush
            fmt.Fprintf(w, "DATA %d\r\n", n)
            if _, e2 := w.Write(buf[:n]); e2 != nil { return }
            if err := w.Flush(); err != nil { return }

            // THROTTLE: calcula o tempo ideal pra enviar n bytes a (throttleKB KB/s)
            if throttleKB > 0 {
                // duração = (n bytes) / (KB/s * 1024)  => em segundos
                // escrevendo como duração: time.Second * n / (throttleKB*1024)
                sleep := time.Second * time.Duration(n) / time.Duration(throttleKB*1024)
                if sleep > 0 {
                    time.Sleep(sleep)
                }
            }
        }
        if er == io.EOF {
            fmt.Fprint(w, "EOF\r\n"); _ = w.Flush(); return
        }
        if er != nil { return }
    }
}