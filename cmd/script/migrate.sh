#!/usr/bin/env bash
set -euo pipefail

# Uso:
#  Local (rodando NO host do proxy; routes.json local):
#    scripts/migrate.sh \
#      --src user@A:/srv/filesA/big.bin \
#      --dst user@B:/srv/filesB/big.bin \
#      --routes /home/ec2-user/reloc/routes.json \
#      --name big.bin \
#      --backend 10.0.0.11:3001 \
#      --reload fsnotify        # ou sighup / none
#
#  Remoto (rodando de outra máquina; atualiza routes.json via SSH no host do proxy):
#    scripts/migrate.sh \
#      --src user@A:/srv/filesA/big.bin \
#      --dst user@B:/srv/filesB/big.bin \
#      --routes /home/ec2-user/reloc/routes.json \
#      --name big.bin \
#      --backend 10.0.0.11:3001 \
#      --proxy-host ec2-user@10.0.0.10 \
#      --reload sighup          # se não tiver auto-reload
#
# Flags:
#   --src         Caminho origem (local ou user@host:/path)
#   --dst         Caminho destino (local ou user@host:/path)
#   --routes      Caminho do routes.json no host do proxy
#   --name        Nome lógico do arquivo (chave no routes.json)
#   --backend     Novo backend "host:porta" (ex.: 10.0.0.11:3001)
#   --proxy-host  (opcional) user@host do PROXY para atualizar o routes.json via SSH
#   --reload      (opcional) fsnotify|sighup|none  (default: fsnotify)
#   --proxy-pid   (opcional) PID do tcp_proxy (para sighup quando --proxy-host estiver vazio)

SRC=""; DST=""; ROUTES=""; NAME=""; BACKEND=""
PROXY_HOST=""; RELOAD="fsnotify"; PROXY_PID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC="$2"; shift 2;;
    --dst) DST="$2"; shift 2;;
    --routes) ROUTES="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --backend) BACKEND="$2"; shift 2;;
    --proxy-host) PROXY_HOST="$2"; shift 2;;
    --reload) RELOAD="$2"; shift 2;;
    --proxy-pid) PROXY_PID="$2"; shift 2;;
    -h|--help) sed -n '1,120p' "$0"; exit 0;;
    *) echo "arg desconhecido: $1"; exit 1;;
  esac
done

[[ -z "$SRC" || -z "$DST" || -z "$ROUTES" || -z "$NAME" || -z "$BACKEND" ]] && {
  echo "Erro: faltam parâmetros obrigatórios. Use --help."; exit 1; }

echo "[migrate] copiando: $SRC -> $DST"
if command -v rsync >/dev/null 2>&1; then
  rsync -av --progress "$SRC" "$DST" || { echo "[migrate] rsync falhou, tentando scp..."; scp "$SRC" "$DST"; }
else
  echo "[migrate] rsync não encontrado, usando scp"; scp "$SRC" "$DST"
fi

update_routes_local() {
  local routes="$1" name="$2" backend="$3"
  [[ -f "$routes" ]] || { echo "[migrate] routes.json não encontrado em $routes"; exit 1; }
  command -v jq >/dev/null 2>&1 || { echo "[migrate] jq é necessário"; exit 1; }
  local tmp
  tmp="$(mktemp)"
  # Atualização atômica: grava em tmp e mv por cima (bom para fsnotify)
  jq --arg k "$name" --arg v "$backend" '.[$k]=$v' "$routes" > "$tmp"
  mv "$tmp" "$routes"
  echo "[migrate] routes.json atualizado localmente: $name -> $backend"
}

update_routes_remote() {
  local proxy="$1" routes="$2" name="$3" backend="$4"
  # Faz a edição no host remoto usando jq
  ssh -o BatchMode=yes "$proxy" "command -v jq >/dev/null 2>&1 || sudo dnf -y install jq || sudo yum -y install jq"
  ssh "$proxy" "test -f '$routes' || { echo 'routes.json não existe em $routes' >&2; exit 1; }"
  ssh "$proxy" "tmp=\$(mktemp) && jq --arg k '$name' --arg v '$backend' '.[\$k]=\$v' '$routes' > \$tmp && mv \$tmp '$routes'"
  echo "[migrate] routes.json atualizado no proxy ($proxy): $name -> $backend"
}

reload_proxy_sighup_local() {
  local pid="$1"
  if [[ -z "$pid" ]]; then
    pid="$(pgrep -f tcp_proxy || true)"
  fi
  [[ -n "$pid" ]] || { echo "[migrate] não encontrei tcp_proxy local"; return 1; }
  kill -HUP "$pid" && echo "[migrate] SIGHUP enviado ao tcp_proxy (PID=$pid)"
}

reload_proxy_sighup_remote() {
  local proxy="$1"
  ssh "$proxy" 'pid=$(pgrep -f tcp_proxy || true); if [ -n "$pid" ]; then kill -HUP "$pid"; echo "SIGHUP enviado ao tcp_proxy (PID=$pid)"; else echo "tcp_proxy não encontrado"; fi'
}

# Atualiza rotas (local ou via SSH)
if [[ -n "$PROXY_HOST" ]]; then
  update_routes_remote "$PROXY_HOST" "$ROUTES" "$NAME" "$BACKEND"
else
  update_routes_local "$ROUTES" "$NAME" "$BACKEND"
fi

# Estratégia de reload
case "$RELOAD" in
  fsnotify)
    echo "[migrate] usando fsnotify: salvar o arquivo já acionou o reload no proxy."
    ;;
  sighup)
    if [[ -n "$PROXY_HOST" ]]; then
      reload_proxy_sighup_remote "$PROXY_HOST"
    else
      reload_proxy_sighup_local "$PROXY_PID"
    fi
    ;;
  none)
    echo "[migrate] sem reload automático solicitado (--reload=none)."
    ;;
  *)
    echo "[migrate] valor inválido para --reload: $RELOAD"; exit 1;;
esac

echo "[migrate] migração concluída."
