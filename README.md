# Projeto: Transparência de Relocação (Tema 09)
## Topologia

Três máquinas reais na mesma LAN:

- **Máquina A**: PROXY TCP (porta 7000) + (opcional) FileServer A TCP (porta 5000)
- **Máquina B**: FileServer B TCP (porta 5001)
- **Máquina C**: Cliente TCP (downloader)

## Conceito

O cliente abre **um socket TCP fixo** para o PROXY (`A:7000`).  
O PROXY mantém uma tabela local (`routes.json`) no formato `{nome -> host:porta}`.  
Durante a migração, um script copia o arquivo de A para B, atualiza o `routes.json` e envia `SIGHUP` ao proxy.  
O proxy troca de backend e **continua o streaming** mantendo o mesmo socket com o cliente — o cliente não percebe a migração.

## Protocolo

- **Cliente → Proxy:**  
  `GET <nome> <offset>` (offset inicial normalmente 0)
- **Proxy → Servidor:**  
  Repassa `GET <nome> <offset>`
- **Servidor → (Proxy → Cliente):**  
  Repete blocos:  
  `DATA <n>` seguido de `<n>` bytes de payload  
  Ao final: `EOF`
- **Erros:**  
  Qualquer erro rompe somente Proxy ↔ Servidor; Proxy mantém Cliente aberto, relê `routes.json` e reconecta no novo backend com o offset acumulado.

## Build mínimo

- Go 1.20+

## Estrutura de diretórios

```
/cmd/tcp_fileserver/main.go   # roda em A e B, portas 5000/5001
/cmd/tcp_proxy/main.go        # roda em A, porta 7000, lê routes.json; SIGHUP=reload
/cmd/tcp_client/main.go       # roda em C; pode usar apenas esse cliente
/scripts/migrate.sh           # rsync A->B e atualiza rota + SIGHUP
routes.json                   # ex.: {"big.bin":"10.0.0.11:5000"}
go.mod
```

## Instruções rápidas

1. Inicialize o módulo Go:
   ```sh
   go mod init reloc-tcp && go mod tidy
   ```
2. Compile os binários:
   ```sh
   go build ./cmd/tcp_fileserver ./cmd/tcp_proxy ./cmd/tcp_client
   ```
3. Execute:
   - **A:**  
     `./tcp_proxy --addr :7000 --routes ./routes.json`  
     `./tcp_fileserver --addr :5000 --base /srv/filesA`
   - **B:**  
     `./tcp_fileserver --addr :5001 --base /srv/filesB`
   - **Cliente (C):**  
     `./tcp_client --proxy 10.0.0.10:7000 --name big.bin --out big.bin`
   - **Migrar durante o download:**  
     `scripts/migrate.sh` (ver script no final)

---

## Exemplo de go.mod

```go
module reloc-tcp

go 1.20
```



