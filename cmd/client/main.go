// cmd/tcp_client/main.go (versão verbosa)
package main

import (
	"bufio"
	"flag"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

func main() {
	proxy := flag.String("proxy", "127.0.0.1:8000", "endereço do proxy/fileserver TCP")
	name := flag.String("name", "example.txt", "nome do arquivo")
	out := flag.String("out", "example.txt", "arquivo de saída")
	flag.Parse()

	part := *out + ".part"
	var offset int64 = 0
	if st, err := os.Stat(part); err == nil { offset = st.Size() }

	f, err := os.OpenFile(part, os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil { panic(err) }
	if _, err := f.Seek(offset, 0); err != nil { panic(err) }

	c, err := net.Dial("tcp", *proxy)
	if err != nil { panic(err) }
	defer c.Close()
	r := bufio.NewReader(c)

	// envia pedido
	fmt.Fprintf(c, "GET %s %d\n", *name, offset)

	var written int64 = 0
	seenEOF := false

	for {
		// evita travar para sempre se o servidor morrer sem mandar EOF
		_ = c.SetReadDeadline(time.Now().Add(10 * time.Second))

		hdr, err := r.ReadString('\n')
		if err != nil {
			fmt.Println("ERRO lendo header:", err)
			break
		}
		hdr = strings.TrimSpace(hdr)
		fmt.Println("HDR:", hdr)

		if hdr == "EOF" {
			seenEOF = true
			break
		}
		if !strings.HasPrefix(hdr, "DATA ") {
			fmt.Println("Cabeçalho inesperado do servidor:", hdr)
			break
		}
		nStr := strings.TrimPrefix(hdr, "DATA ")
		n, err := strconv.ParseInt(nStr, 10, 64)
		if err != nil || n < 0 {
			fmt.Println("DATA inválido:", nStr)
			break
		}

		if err := recvToFile(r, f, n); err != nil {
			fmt.Println("erro ao receber bloco:", err)
			break
		}
		offset += n
		written += n
		fmt.Printf("... +%d bytes (total=%d)\n", n, offset)
	}

	_ = f.Close()

	if seenEOF && written > 0 {
		if err := os.Rename(part, *out); err == nil {
			fmt.Println("OK: download concluído e renomeado.")
		} else {
			fmt.Println("Baixado, mas falhou ao renomear:", err)
		}
	} else {
		fmt.Println("ATENÇÃO: sem EOF ou 0 bytes recebidos — .part preservado para debug.")
	}
}

func recvToFile(r *bufio.Reader, f *os.File, n int64) error {
	buf := make([]byte, 64*1024)
	left := n
	for left > 0 {
		chunk := int64(len(buf))
		if chunk > left { chunk = left }
		m, err := r.Read(buf[:chunk])
		if m > 0 {
			if _, e2 := f.Write(buf[:m]); e2 != nil { return e2 }
			left -= int64(m)
		}
		if err != nil { return err }
	}
	return nil
}
