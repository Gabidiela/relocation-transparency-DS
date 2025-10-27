package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"

	"github.com/fsnotify/fsnotify"
)

var (
	addr       = flag.String("addr", "0.0.0.0:8000", "endereço para escutar (IPv4)")
	routesPath = flag.String("routes", "./routes.json", "arquivo de rotas (name -> host:port)")
	watch      = flag.Bool("watch", true, "habilita hot-reload de routes.json (fsnotify)")
)

type routeMap = map[string]string

var routes atomic.Value // guarda routeMap

func main() {
	flag.Parse()

	rp, _ := filepath.Abs(*routesPath)
	if err := loadRoutes(rp); err != nil {
		fmt.Println("[proxy] erro load routes:", err)
		os.Exit(1)
	}
	fmt.Println("[proxy] routes carregado:", rp)

	if *watch {
		go watchRoutes(rp)
	}

	ln, err := net.Listen("tcp4", *addr)
	if err != nil {
		panic(err)
	}
	fmt.Println("[proxy] listening on", *addr)

	for {
		cli, err := ln.Accept()
		if err != nil {
			continue
		}
		go handleClient(cli)
	}
}

func currentRoutes() routeMap {
	if v := routes.Load(); v != nil {
		return v.(routeMap)
	}
	return routeMap{}
}

func loadRoutes(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var m routeMap
	if err := json.Unmarshal(data, &m); err != nil {
		return err
	}
	routes.Store(m)
	return nil
}

func watchRoutes(path string) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		fmt.Println("[proxy] fsnotify erro:", err)
		return
	}
	defer w.Close()

	dir := filepath.Dir(path)
	_ = w.Add(dir)
	fmt.Println("[proxy] watching", dir)

	for ev := range w.Events {
		// qualquer write/rename no arquivo alvo dispara reload
		if ev.Name == path && (ev.Op&fsnotify.Write != 0 || ev.Op&fsnotify.Create != 0 || ev.Op&fsnotify.Rename != 0) {
			if err := loadRoutes(path); err == nil {
				fmt.Println("[proxy] routes recarregado")
			} else {
				fmt.Println("[proxy] erro recarregando:", err)
			}
		}
	}
}

func handleClient(cli net.Conn) {
	defer cli.Close()
	cr := bufio.NewReader(cli)

	// lê a primeira linha do cliente (não consome payload; só existe essa linha no protocolo)
	first, err := cr.ReadString('\n')
	if err != nil {
		return
	}
	line := strings.TrimSpace(first)
	if !strings.HasPrefix(line, "GET ") {
		fmt.Fprint(cli, "ERR bad request\r\n")
		return
	}
	fields := strings.Fields(line)
	if len(fields) != 3 {
		fmt.Fprint(cli, "ERR bad request\r\n")
		return
	}
	name := fields[1]

	// resolve backend
	m := currentRoutes()
	backend, ok := m[name]
	if !ok {
		// fallback: tenta chave "" (default) ou responde erro
		if def, has := m[""]; has {
			backend = def
		} else {
			fmt.Fprint(cli, "ERR no route\r\n")
			return
		}
	}

	// informa para o cliente qual backend atenderá
	fmt.Fprintf(cli, "SRV %s\r\n", backend)

	// conecta ao backend e encaminha a primeira linha
	srv, err := net.DialTimeout("tcp4", backend, 5*time.Second)
	if err != nil {
		fmt.Fprint(cli, "ERR backend_unreachable\r\n")
		return
	}
	defer srv.Close()

	if _, err := io.WriteString(srv, first); err != nil {
		return
	}

	// pipeline: respostas do backend -> cliente
	// (protocolo é unidirecional nesse sentido; mas se quiser bidirecional, crie a segunda cópia)
	_, _ = io.Copy(cli, srv)
}
