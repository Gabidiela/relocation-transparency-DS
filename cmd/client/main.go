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
	proxyAddr = flag.String("proxy", "127.0.0.1:8000", "endereço do proxy")
	name      = flag.String("name", "grande.txt", "nome lógico do arquivo")
	out       = flag.String("out", "grande.txt", "arquivo de saída")
	retryWait = flag.Duration("retry-wait", 2*time.Second, "tempo de espera entre tentativas")
)

func main() {
	flag.Parse()

	part := *out + ".part"
	if err := os.MkdirAll(filepath.Dir(part), 0o755); err != nil && !os.IsExist(err) {
		// se for o diretório atual, tudo bem
	}

	// abre .part em append para calcular offset e continuar
	f, err := os.OpenFile(part, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		fmt.Println("ERRO abrindo .part:", err)
		os.Exit(1)
	}
	defer f.Close()

	// calcula offset inicial
	offset, err := fileSize(part)
	if err != nil {
		fmt.Println("ERRO lendo tamanho:", err)
		os.Exit(1)
	}
	fmt.Println("offset inicial:", offset)

	for {
		err = downloadOnce(*proxyAddr, *name, f, &offset)
		if err == nil {
			// renomeia .part -> final
			_ = f.Close()
			if err := os.Rename(part, *out); err != nil {
				fmt.Println("ERRO ao renomear:", err)
				os.Exit(1)
			}
			fmt.Println("OK: download concluído e renomeado.")
			return
		}
		fmt.Println("WARN:", err, " — tentando de novo após", *retryWait)
		time.Sleep(*retryWait)
		// reabre o arquivo em append (caso a conexão tenha fechado e o handle se perca)
		f, _ = os.OpenFile(part, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	}
}

func downloadOnce(proxy, name string, dst *os.File, offset *int64) error {
	conn, err := net.Dial("tcp4", proxy)
	if err != nil {
		return fmt.Errorf("dial proxy: %w", err)
	}
	defer conn.Close()

	// envia GET <name> <offset>\r\n
	fmt.Fprintf(conn, "GET %s %d\r\n", name, *offset)

	r := bufio.NewReader(conn)
	for {
		h, err := r.ReadString('\n')
		if err != nil {
			return fmt.Errorf("ler header: %w", err)
		}
		h = strings.TrimSpace(h)

		if strings.HasPrefix(h, "SRV ") {
			backend := strings.TrimSpace(strings.TrimPrefix(h, "SRV"))
			fmt.Println("BACKEND:", backend)
			continue
		}

		if strings.HasPrefix(h, "DATA ") {
			nStr := strings.TrimSpace(strings.TrimPrefix(h, "DATA"))
			n, perr := strconv.ParseInt(nStr, 10, 64)
			if perr != nil || n < 0 {
				return fmt.Errorf("DATA inválido: %s", h)
			}
			if n == 0 {
				continue
			}
			if err := copyN(dst, r, n); err != nil {
				return fmt.Errorf("copiando payload: %w", err)
			}
			*offset += n
			fmt.Printf("... +%d bytes (total=%d)\n", n, *offset)
			continue
		}

		if h == "EOF" {
			return nil
		}
		if strings.HasPrefix(h, "ERR ") {
			return fmt.Errorf("servidor: %s", h)
		}
		// header inesperado — loga e segue
		fmt.Println("HDR desconhecido:", h)
	}
}

func copyN(dst *os.File, r io.Reader, n int64) error {
	// copia exatamente n bytes do reader para o arquivo
	remaining := n
	buf := make([]byte, 64*1024)
	for remaining > 0 {
		toRead := int64(len(buf))
		if remaining < toRead {
			toRead = remaining
		}
		m, err := io.ReadFull(r, buf[:toRead])
		if err != nil {
			return err
		}
		if _, err := dst.Write(buf[:m]); err != nil {
			return err
		}
		remaining -= int64(m)
	}
	return nil
}

func fileSize(path string) (int64, error) {
	st, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	return st.Size(), nil
}
