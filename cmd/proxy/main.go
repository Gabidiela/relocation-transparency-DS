// ============================ cmd/tcp_proxy/main.go ============================
package main

import (
    "bufio"
    "encoding/json"
    "flag"
    "fmt"
    "net"
    "os"
    "os/signal"
    "path/filepath"
    "strconv"
    "strings"
    "sync"
    "syscall"
    "time"
    "github.com/fsnotify/fsnotify"

)

type Routes map[string]string // name -> "host:port"

var (
    routes   Routes
    routesMu sync.RWMutex
    routesFn string
)

func loadRoutes(fn string) (Routes, error) {
    f, err := os.Open(fn)
    if err != nil { return nil, err }
    defer f.Close()
    var r Routes
    if err := json.NewDecoder(f).Decode(&r); err != nil { return nil, err }
    return r, nil
}

func currentBackend(name string) (string, bool) {
    routesMu.RLock(); defer routesMu.RUnlock()
    v, ok := routes[name]
    return v, ok
}

func reload() error {
    r, err := loadRoutes(routesFn)
    if err != nil { return err }
    routesMu.Lock(); routes = r; routesMu.Unlock()
    fmt.Println("[proxy] rotas recarregadas:", routes)
    return nil
}

func main() {
    addr := flag.String("addr", ":8000", "endereço TCP do proxy")
    flag.StringVar(&routesFn, "routes", "./routes.json", "arquivo de rotas JSON")
    flag.Parse()

    if _, err := os.Stat(routesFn); os.IsNotExist(err) {
        // cria vazio se não existir
        _ = os.MkdirAll(filepath.Dir(routesFn), 0o755)
        _ = os.WriteFile(routesFn, []byte("{}"), 0o644)
    }
    if err := reload(); err != nil { fmt.Println("erro ao ler rotas:", err) }

    sig := make(chan os.Signal, 1)
    signal.Notify(sig, syscall.SIGHUP)
    go func() {
        for range sig { _ = reload() }
    }()

    go func() {
        w, err := fsnotify.NewWatcher()
        if err != nil {
            fmt.Println("[proxy] fsnotify error:", err)
            return
        }
        defer w.Close()

        // Observa o arquivo E o diretório (editores fazem rename/temp-file)
        dir := filepath.Dir(routesFn)
        if err := w.Add(dir); err != nil {
            fmt.Println("[proxy] watch dir error:", err)
            return
        }

        // debounce: espera ~200ms sem novos eventos antes de recarregar
        var (
            timer   *time.Timer
            )

        schedule := func() {
            if timer != nil {
                timer.Reset(200 * time.Millisecond)
            } else {
                timer = time.AfterFunc(200*time.Millisecond, func() {
                    // só recarrega se o routes.json existe
                    if _, err := os.Stat(routesFn); err == nil {
                        if err := reload(); err != nil {
                            fmt.Println("[proxy] reload error:", err)
                        }
                    }
                })
            }
        }

        for {
            select {
            case ev, ok := <-w.Events:
                if !ok { return }
                // eventos relevantes no arquivo específico
                if filepath.Clean(ev.Name) == filepath.Clean(routesFn) &&
                (ev.Op&(fsnotify.Write|fsnotify.Create|fsnotify.Rename|fsnotify.Chmod)) != 0 {
                    schedule()
                }
                // se editor faz "rename atomic", o arquivo pode reaparecer
                if ev.Op&fsnotify.Remove != 0 && filepath.Clean(ev.Name) == filepath.Clean(routesFn) {
                    schedule()
                }

            case err, ok := <-w.Errors:
                if !ok { return }
                fmt.Println("[proxy] watch error:", err)
            }
        }
    }()


    ln, err := net.Listen("tcp4", *addr)
    if err != nil { panic(err) }
    fmt.Println("proxy escutando em", *addr, "routes=", routesFn)

    for {
        c, err := ln.Accept()
        if err != nil { continue }
        go handleClient(c)
    }
}

func handleClient(cli net.Conn) {
    defer cli.Close()
    cr := bufio.NewReader(cli)
    cw := bufio.NewWriter(cli)

    // 1) lê pedido do cliente: "GET name offset\n"
    line, err := cr.ReadString('\n')
    if err != nil {
        fmt.Println("[proxy] erro lendo pedido do cliente:", err)
        return
    }
    parts := strings.Fields(strings.TrimSpace(line))
    if len(parts) != 3 || strings.ToUpper(parts[0]) != "GET" {
        cw.WriteString("ERR bad request\r\n"); cw.Flush()
        return
    }
    name := parts[1]
    offset, err := strconv.ParseInt(parts[2], 10, 64)
    if err != nil || offset < 0 {
        cw.WriteString("ERR bad offset\r\n"); cw.Flush()
        return
    }

    for { // loop de reencaminhamento: mantém o socket do cliente aberto
        backend, ok := currentBackend(name)
        if !ok {
            cw.WriteString("ERR route not found\r\n"); cw.Flush()
            return
        }
        fmt.Println("[proxy] encaminhando", name, "para", backend, "a partir de offset", offset)

        srv, err := net.DialTimeout("tcp", backend, 5*time.Second)
        if err != nil {
            fmt.Println("[proxy] falhou conectar ao backend:", err)
            time.Sleep(800 * time.Millisecond)
            continue
        }

        // 2) envia o pedido ao servidor com o offset atual
        fmt.Fprintf(srv, "GET %s %d\r\n", name, offset)
        sr := bufio.NewReader(srv)

        // 3) loop de cópia: lê cabeçalhos do servidor e REPASSA ao cliente
        for {
            hdr, er := sr.ReadString('\n')
            if er != nil {
                fmt.Println("[proxy] erro lendo header do backend:", er)
                srv.Close()
                break // tenta reconectar (mantém cliente aberto)
            }
            hdr = strings.TrimSpace(hdr)
            // DEBUG opcional:
            // fmt.Println("[proxy] HDR upstream:", hdr)

            switch {
            case hdr == "EOF":
                // repassa EOF ao cliente e conclui
                cw.WriteString("EOF\r\n")
                cw.Flush()
                srv.Close()
                return

            case strings.HasPrefix(hdr, "ERR "):
                // repassa erro ao cliente para debug
                cw.WriteString(hdr + "\r\n")
                cw.Flush()
                srv.Close()
                return

            case strings.HasPrefix(hdr, "DATA "):
                nStr := strings.TrimPrefix(hdr, "DATA ")
                n, per := strconv.ParseInt(nStr, 10, 64)
                if per != nil || n < 0 {
                    cw.WriteString("ERR bad length\r\n"); cw.Flush()
                    srv.Close()
                    return
                }
                // repassa header ao cliente
                fmt.Fprintf(cw, "DATA %d\r\n", n)
                // copia exatamente n bytes do servidor para o cliente
                if err := copyN(cw, sr, n); err != nil {
                    fmt.Println("[proxy] erro copiando payload:", err)
                    srv.Close()
                    break // reconectar e retomar do offset atual
                }
                if err := cw.Flush(); err != nil {
                    fmt.Println("[proxy] erro no flush ao cliente:", err)
                    srv.Close()
                    return
                }
                offset += n

            default:
                // protocolo inesperado
                cw.WriteString("ERR bad upstream\r\n")
                cw.Flush()
                srv.Close()
                return
            }
        }

        // caiu aqui por erro de backend: tenta de novo (rota pode mudar após SIGHUP)
        time.Sleep(400 * time.Millisecond)
    }
}


func copyN(w *bufio.Writer, r *bufio.Reader, n int64) error {
    buf := make([]byte, 64*1024)
    var left = n
    for left > 0 {
        chunk := int64(len(buf))
        if chunk > left { chunk = left }
        m, err := r.Read(buf[:chunk])
        if m > 0 {
            if _, e2 := w.Write(buf[:m]); e2 != nil { return e2 }
            left -= int64(m)
        }
        if err != nil { return err }
    }
    return nil
}