#!/usr/bin/env bash
set -euo pipefail

# --------------------------- uso / args ---------------------------
if [ $# -ne 5 ]; then
  echo "uso: $0 <SRC_LOCAL_ABS> <DST_USER@DST_HOST:/ABS/DEST> <ROUTES_JSON_LOCAL_ABS> <NAME> <BACKEND_HOST:PORT>"
  echo "ex.: $0 /path/src.bin user@192.168.0.2:/path/dst.bin /path/routes.json arquivo 192.168.0.2:3001"
  exit 1
fi

SRC_LOCAL="$1"           # ex: /home/user/proj/tmp/grande.txt  (LOCAL ao Proxy/A)
DST_SPEC="$2"            # ex: user@192.168.25.13:/Users/user/tmp/grande.txt
ROUTES_LOCAL="$3"        # ex: /home/user/proj/routes.json     (LOCAL ao Proxy/A)
NAME="$4"                # ex: grande.txt
BACKEND="$5"             # ex: 192.168.25.13:3001

# ----------------------- deps e helpers ---------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "[migrate] falta '$1'"; exit 1; }; }
need rsync; need jq; need nc; need ssh; need stat

# tamanhos portáveis (macOS BSD stat / GNU stat / wc -c)
get_size_local() {
  local p="$1"
  (stat -f %z -- "$p" 2>/dev/null) || (stat -c %s -- "$p" 2>/dev/null) || (wc -c < "$p" 2>/dev/null)
}
get_size_remote() {
  local uh="$1" p="$2"
  ssh -o StrictHostKeyChecking=no "$uh" \
    "stat -f %z -- \"\$1\" 2>/dev/null || stat -c %s -- \"\$1\" 2>/dev/null || wc -c < \"\$1\"" _ "$p"
}

# parse de destino e backend
DST_USER_HOST="${DST_SPEC%%:*}"        # user@host
DST_PATH_ABS="${DST_SPEC#*:}"          # /abs/path
B_HOST="${BACKEND%:*}"
B_PORT="${BACKEND#*:}"

# valida caminhos absolutos
case "$SRC_LOCAL"   in /*) ;; *) echo "[migrate] ERRO: SRC_LOCAL precisa ser ABSOLUTO"; exit 1;; esac
case "$DST_PATH_ABS" in /*) ;; *) echo "[migrate] ERRO: DST_PATH precisa ser ABSOLUTO"; exit 1;; esac
case "$ROUTES_LOCAL" in /*) ;; *) echo "[migrate] ERRO: ROUTES_JSON precisa ser ABSOLUTO"; exit 1;; esac

# ----------------------- 1) tamanho origem ------------------------
SRC_SIZE="$(get_size_local "$SRC_LOCAL")"
[ -n "$SRC_SIZE" ] && [ "$SRC_SIZE" -gt 0 ] || { echo "[migrate] ERRO: origem inexistente ou tamanho 0"; exit 1; }
echo "[migrate] origem: $SRC_LOCAL ($SRC_SIZE bytes)"

# ----------------------- 2) cópia local → remoto -------------------
echo "[migrate] copiando para $DST_SPEC ..."
rsync -av --progress -e 'ssh -o StrictHostKeyChecking=no' -- "$SRC_LOCAL" "$DST_SPEC"

# ----------------------- 3) valida tamanho no B -------------------
DST_SIZE="$(get_size_remote "$DST_USER_HOST" "$DST_PATH_ABS")"
[ "$DST_SIZE" = "$SRC_SIZE" ] || { echo "[migrate] ERRO: tamanhos diferentes (A=$SRC_SIZE, B=$DST_SIZE)"; exit 1; }
echo "[migrate] cópia validada no B ($DST_SIZE bytes)."

# ----------------------- 4) smoke test no B -----------------------
echo "[migrate] testando fileserver em $BACKEND para '$NAME' ..."
if ! printf 'GET %s 0\r\n' "$NAME" | nc -w 3 -v "$B_HOST" "$B_PORT" | head -n1 | grep -q '^DATA ' ; then
  echo "[migrate] ERRO: B não respondeu DATA para '$NAME' (arquivo no --base do B? serviço rodando?)"
  exit 1
fi

# ----------------------- 5) atualiza routes.json -------------------
echo "[migrate] atualizando $ROUTES_LOCAL: $NAME -> $BACKEND"
tmp="$(mktemp)"
jq --arg k "$NAME" --arg v "$BACKEND" '.[ $k ] = $v' "$ROUTES_LOCAL" > "$tmp"
mv "$tmp" "$ROUTES_LOCAL"
echo "[migrate] ok! rota trocada para $BACKEND (fsnotify deve recarregar no proxy)."
