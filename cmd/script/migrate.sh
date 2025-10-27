#!/usr/bin/env bash
# Migração A -> B com validação + troca de rota no Proxy
# Requisitos: ssh com chave, rsync, jq, nc

set -euo pipefail

# ===================== defaults (ajuste se quiser) =====================
SRC_HOST="${SRC_HOST:-10.0.0.10}"       # A (pode ser a própria máquina onde roda o script)
SRC_USER="${SRC_USER:-usuario}"
SRC_PATH="${SRC_PATH:-/srv/filesA/grande.txt}"

DST_HOST="${DST_HOST:-10.0.0.11}"       # B
DST_USER="${DST_USER:-usuario}"
DST_PATH="${DST_PATH:-/srv/filesB/grande.txt}"

PROXY_HOST="${PROXY_HOST:-10.0.0.10}"   # máquina do Proxy (onde fica o routes.json)
PROXY_USER="${PROXY_USER:-usuario}"
ROUTES="${ROUTES:-/home/usuario/sd/routes.json}"

NAME="${NAME:-grande.txt}"
BACKEND_HOST="${BACKEND_HOST:-10.0.0.11}"
BACKEND_PORT="${BACKEND_PORT:-3001}"
RELOAD="${RELOAD:-fsnotify}"            # fsnotify | sighup | none
# ======================================================================

print_usage() {
  cat <<'EOF'
Uso:
  ./migrate.sh \
    --src-host 192.168.x.x --src-user user --src-path /caminho/ABS/origem \
    --dst-host 192.168.x.x --dst-user user --dst-path /caminho/ABS/destino \
    --proxy-host 192.168.x.x --proxy-user user \
    --routes /caminho/ABS/routes.json \
    --name grande.txt --backend-host 192.168.x.x --backend-port 3001 \
    --reload fsnotify|sighup|none
EOF
}

# ---- parse flags ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src-host) SRC_HOST="$2"; shift 2;;
    --src-user) SRC_USER="$2"; shift 2;;
    --src-path) SRC_PATH="$2"; shift 2;;
    --dst-host) DST_HOST="$2"; shift 2;;
    --dst-user) DST_USER="$2"; shift 2;;
    --dst-path) DST_PATH="$2"; shift 2;;
    --proxy-host) PROXY_HOST="$2"; shift 2;;
    --proxy-user) PROXY_USER="$2"; shift 2;;
    --routes) ROUTES="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --backend-host) BACKEND_HOST="$2"; shift 2;;
    --backend-port) BACKEND_PORT="$2"; shift 2;;
    --reload) RELOAD="$2"; shift 2;;
    -h|--help) print_usage; exit 0;;
    *) echo "Argumento inválido: $1"; print_usage; exit 1;;
  esac
done

BACKEND="${BACKEND_HOST}:${BACKEND_PORT}"

log() { printf '[migrate] %s\n' "$*"; }
die() { printf '[migrate] ERRO: %s\n' "$*" >&2; exit 1; }

need_local_bin() { command -v "$1" >/dev/null 2>&1 || die "comando local não encontrado: $1"; }

# ---- pré-checks locais ----
need_local_bin ssh
need_local_bin rsync
need_local_bin jq
need_local_bin nc

# ---- helpers SSH ----
ssh_a() { ssh -o StrictHostKeyChecking=no "${SRC_USER}@${SRC_HOST}" "$@"; }
ssh_b() { ssh -o StrictHostKeyChecking=no "${DST_USER}@${DST_HOST}" "$@"; }
ssh_p() { ssh -o StrictHostKeyChecking=no "${PROXY_USER}@${PROXY_HOST}" "$@"; }

# ---- função p/ detectar se um IP/host é local a esta máquina ----
is_local_host() {
  local host="$1"
  # IPs locais via 'ip' ou 'hostname -I'
  local ips
  if command -v ip >/dev/null 2>&1; then
    ips=$(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1)
  else
    ips=$(hostname -I 2>/dev/null || true)
  fi
  # hostname local
  local self
  self=$(hostname -s)
  # normalizações
  [[ "$host" = "127.0.0.1" || "$host" = "localhost" || "$host" = "$self" ]] && return 0
  echo "$ips" | tr ' ' '\n' | grep -Fxq "$host"
}

# ---- garanta caminhos ABS ----
case "$SRC_PATH" in /*) ;; *) die "--src-path precisa ser ABSOLUTO (ex.: /home/.../grande.txt)";; esac
case "$DST_PATH" in /*) ;; *) die "--dst-path precisa ser ABSOLUTO";; esac
case "$ROUTES"   in /*) ;; *) die "--routes precisa ser ABSOLUTO";; esac

# ===================== 1) checagens de conectividade ===================
log "checando conectividade SSH..."
ssh_a 'echo OK_A' >/dev/null || die "não conectou em A (${SRC_HOST})"
ssh_b 'echo OK_B' >/dev/null || die "não conectou em B (${DST_HOST})"
ssh_p 'echo OK_PROXY' >/devnull || ssh_p 'echo OK_PROXY' >/dev/null || die "não conectou no Proxy (${PROXY_HOST})"

# ===================== 2) valida origem e destinos =====================
log "validando arquivo de origem em A: ${SRC_PATH}"
SRC_SIZE="$(ssh_a "stat -c %s '${SRC_PATH}'" 2>/dev/null || true)"
[[ -n "${SRC_SIZE}" && "${SRC_SIZE}" -gt 0 ]] || die "arquivo de origem não existe ou tem tamanho 0"

log "garantindo diretório de destino em B: $(dirname "${DST_PATH}")"
ssh_b "mkdir -p '$(dirname "${DST_PATH}")'"

# ===================== 3) copia A -> B (sem remote→remote local) =======
log "copiando de A (${SRC_HOST}) para B (${DST_HOST})..."

SRC_LOCAL=false; DST_LOCAL=false
is_local_host "$SRC_HOST" && SRC_LOCAL=true
is_local_host "$DST_HOST" && DST_LOCAL=true

if $SRC_LOCAL && ! $DST_LOCAL; then
  # A é local, B é remoto
  rsync -av --progress -e 'ssh -o StrictHostKeyChecking=no' \
    "${SRC_PATH}" "${DST_USER}@${DST_HOST}:'${DST_PATH}'"
elif ! $SRC_LOCAL && $DST_LOCAL; then
  # A é remoto, B é local
  rsync -av --progress -e 'ssh -o StrictHostKeyChecking=no' \
    "${SRC_USER}@${SRC_HOST}:'${SRC_PATH}'" "${DST_PATH}"
elif $SRC_LOCAL && $DST_LOCAL; then
  # ambos locais (raro, mas ok)
  rsync -av --progress "${SRC_PATH}" "${DST_PATH}"
else
  # ambos remotos -> execute o rsync a partir do SRC via SSH (precisa chave SRC->DST)
  ssh -o StrictHostKeyChecking=no "${SRC_USER}@${SRC_HOST}" \
    "rsync -av --progress '${SRC_PATH}' '${DST_USER}@${DST_HOST}':'${DST_PATH}'"
fi

# ===================== 4) valida cópia no B ============================
DST_SIZE="$(ssh_b "stat -c %s '${DST_PATH}'")" || die "não consegui obter tamanho no B"
[[ "${DST_SIZE}" == "${SRC_SIZE}" ]] || die "tamanho difere (A=${SRC_SIZE}, B=${DST_SIZE})"

log "cópia validada com sucesso (${DST_SIZE} bytes)."

# ===================== 5) smoke test no FileServer B ===================
log "testando fileserver B em ${BACKEND} para '${NAME}'..."
if ! printf 'GET %s 0\r\n' "${NAME}" | nc -w 3 -v "${BACKEND_HOST}" "${BACKEND_PORT}" | head -n1 | grep -q '^DATA '; then
  die "fileserver B não respondeu 'DATA' (verifique se '${NAME}' existe no --base do B e se o serviço está rodando)"
fi

# ===================== 6) atualiza routes.json no Proxy =================
log "atualizando routes.json no Proxy (${ROUTES}) => ${NAME} -> ${BACKEND}"
ssh_p "test -f '${ROUTES}' || { echo 'routes.json inexistente em ${ROUTES}' >&2; exit 1; }"
ssh_p "tmp=\$(mktemp) && jq --arg k '${NAME}' --arg v '${BACKEND}' '.[\$k]=\$v' '${ROUTES}' > \"\$tmp\" && mv \"\$tmp\" '${ROUTES}'" \
  || die "falha ao atualizar routes.json no Proxy"

# ===================== 7) reload do Proxy ==============================
case "${RELOAD}" in
  fsnotify)
    log "fsnotify habilitado: salvar o arquivo já disparou o reload no proxy."
    ;;
  sighup)
    log "enviando SIGHUP ao proxy..."
    # OBS: nome do processo 'proxy' (cmd/proxy), não 'tcp_proxy'
    ssh_p 'pid=$(pgrep -f "[/]bin/proxy" || pgrep -f "[c]md/proxy" || pgrep -f proxy || true); if [ -n "$pid" ]; then kill -HUP "$pid"; echo "SIGHUP enviado (PID=$pid)"; else echo "proxy não encontrado"; fi'
    ;;
  none)
    log "reload desativado (--reload=none). Atualize manualmente se necessário."
    ;;
  *)
    die "valor inválido para --reload: ${RELOAD}"
    ;;
esac

log "rota trocada para ${BACKEND}. Migração concluída com sucesso."
