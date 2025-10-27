#!/usr/bin/env bash
# Migração A -> B com validação + troca de rota no Proxy
# Requisitos: ssh com chave, rsync, jq, nc
# Uso típico (com defaults abaixo):
#   ./migrate.sh \
#     --src-host 10.0.0.10 --src-user usuario --src-path /srv/filesA/grande.txt \
#     --dst-host 10.0.0.11 --dst-user usuario --dst-path /srv/filesB/grande.txt \
#     --proxy-host 10.0.0.10 --proxy-user usuario \
#     --routes /home/usuario/sd/routes.json \
#     --name grande.txt --backend-host 10.0.0.11 --backend-port 3001 \
#     --reload fsnotify

set -euo pipefail

# ===================== defaults (ajuste se quiser) =====================
SRC_HOST="${SRC_HOST:-10.0.0.10}"       # M1 (FileServer A)
SRC_USER="${SRC_USER:-usuario}"
SRC_PATH="${SRC_PATH:-/srv/filesA/grande.txt}"

DST_HOST="${DST_HOST:-10.0.0.11}"       # M2 (FileServer B)
DST_USER="${DST_USER:-usuario}"
DST_PATH="${DST_PATH:-/srv/filesB/grande.txt}"

PROXY_HOST="${PROXY_HOST:-10.0.0.10}"   # M1 (Proxy)
PROXY_USER="${PROXY_USER:-usuario}"
ROUTES="${ROUTES:-/home/usuario/sd/routes.json}"

NAME="${NAME:-grande.txt}"              # nome lógico solicitado pelo cliente
BACKEND_HOST="${BACKEND_HOST:-10.0.0.11}"
BACKEND_PORT="${BACKEND_PORT:-3001}"
RELOAD="${RELOAD:-fsnotify}"            # fsnotify | sighup | none
# ======================================================================

print_usage() {
  sed -n '1,120p' "$0" | sed -n '1,60p' | sed 's/^# \{0,1\}//'
  echo ""
  echo "Flags disponíveis:"
  cat <<'EOF'
  --src-host HOST           IP/host do servidor A
  --src-user USER           usuário SSH do A
  --src-path PATH           caminho absoluto do arquivo em A
  --dst-host HOST           IP/host do servidor B
  --dst-user USER           usuário SSH do B
  --dst-path PATH           caminho absoluto do arquivo em B
  --proxy-host HOST         IP/host do Proxy (onde está o routes.json)
  --proxy-user USER         usuário SSH do Proxy
  --routes PATH             caminho do routes.json no Proxy
  --name NAME               nome lógico do arquivo (chave no routes.json)
  --backend-host HOST       host do novo backend (B)
  --backend-port PORT       porta do novo backend (ex.: 3001)
  --reload fsnotify|sighup|none  estratégia de reload no Proxy
  -h | --help               mostra esta ajuda
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

need_local_bin() {
  command -v "$1" >/dev/null 2>&1 || die "comando local não encontrado: $1"
}

# ---- pré-checks locais ----
need_local_bin ssh
need_local_bin rsync
need_local_bin jq
need_local_bin nc

# ---- helpers ----
ssh_a() { ssh -o StrictHostKeyChecking=no "${SRC_USER}@${SRC_HOST}" "$@"; }
ssh_b() { ssh -o StrictHostKeyChecking=no "${DST_USER}@${DST_HOST}" "$@"; }
ssh_p() { ssh -o StrictHostKeyChecking=no "${PROXY_USER}@${PROXY_HOST}" "$@"; }

# ===================== 1) checagens de conectividade ===================
log "checando conectividade SSH..."
ssh_a 'echo OK_A' >/dev/null || die "não conectou em A (${SRC_HOST})"
ssh_b 'echo OK_B' >/dev/null || die "não conectou em B (${DST_HOST})"
ssh_p 'echo OK_PROXY' >/dev/null || die "não conectou no Proxy (${PROXY_HOST})"

# ===================== 2) valida origem e destinos =====================
log "validando arquivo de origem em A: ${SRC_PATH}"
SRC_SIZE="$(ssh_a "stat -c %s '${SRC_PATH}'" 2>/dev/null || true)"
[[ -n "${SRC_SIZE}" && "${SRC_SIZE}" -gt 0 ]] || die "arquivo de origem não existe ou tem tamanho 0"

log "garantindo diretório de destino em B: $(dirname "${DST_PATH}")"
ssh_b "mkdir -p '$(dirname "${DST_PATH}")'"

# ===================== 3) copia A -> B (rsync via SSH) =================
log "copiando de A (${SRC_HOST}) para B (${DST_HOST})..."
rsync -av --progress -e 'ssh -o StrictHostKeyChecking=no' \
  "${SRC_USER}@${SRC_HOST}:${SRC_PATH}" \
  "${DST_USER}@${DST_HOST}:${DST_PATH}"

# ===================== 4) valida cópia no B ============================
DST_SIZE="$(ssh_b "stat -c %s '${DST_PATH}'")" || die "não consegui obter tamanho no B"
[[ "${DST_SIZE}" == "${SRC_SIZE}" ]] || die "tamanho difere (A=${SRC_SIZE}, B=${DST_SIZE})"

log "cópia validada com sucesso (${DST_SIZE} bytes)."

# ===================== 5) smoke test no FileServer B ===================
# Testa se o FileServer B (porta 3001 por padrão) responde DATA para NAME
log "testando fileserver B em ${BACKEND} para '${NAME}'..."
if ! printf 'GET %s 0\r\n' "${NAME}" | nc -w 3 -v "${BACKEND_HOST}" "${BACKEND_PORT}" | head -n1 | grep -q '^DATA '; then
  die "fileserver B não respondeu 'DATA' (verifique se o arquivo '${NAME}' existe em --base do B e os serviços estão de pé)"
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
    log "enviando SIGHUP ao tcp_proxy no Proxy..."
    ssh_p 'pid=$(pgrep -f tcp_proxy || true); if [ -n "$pid" ]; then kill -HUP "$pid"; echo "SIGHUP enviado (PID=$pid)"; else echo "tcp_proxy não encontrado"; fi'
    ;;
  none)
    log "reload desativado (--reload=none). Atualize manualmente se necessário."
    ;;
  *)
    die "valor inválido para --reload: ${RELOAD}"
    ;;
esac

log "rota trocada para ${BACKEND}. Migração concluída com sucesso."
