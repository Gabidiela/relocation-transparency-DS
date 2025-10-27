#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 5 ]; then
  echo "uso: $0 <SRC_LOCAL> <DST_USER@HOST:/ABS/DEST> <ROUTES_JSON_LOCAL> <NAME> <BACKEND_HOST:PORT>"
  exit 1
fi

SRC_LOCAL="$1"           # ex: /home/.../grande.txt
DST_SPEC="$2"            # ex: user@192.168.x.x:/Users/.../grande.txt
ROUTES_LOCAL="$3"        # ex: /home/.../routes.json
NAME="$4"                # ex: grande.txt
BACKEND="$5"             # ex: 192.168.25.13:3001

# 0) pré-checagens
command -v rsync >/dev/null || { echo "rsync não encontrado"; exit 1; }
command -v jq    >/dev/null || { echo "jq não encontrado"; exit 1; }
command -v nc    >/dev/null || { echo "nc (netcat) não encontrado"; exit 1; }

# 1) tamanhos para validar
SRC_SIZE=$(stat -c %s "$SRC_LOCAL")
echo "[migrate] origem local: $SRC_LOCAL ($SRC_SIZE bytes)"

# 2) copia local -> remoto (B)
echo "[migrate] copiando para $DST_SPEC ..."
rsync -av --progress -e 'ssh -o StrictHostKeyChecking=no' "$SRC_LOCAL" "$DST_SPEC"

# 3) valida no B (usa ssh só para pegar tamanho)
DST_USER_HOST="${DST_SPEC%%:*}"        # user@host
DST_PATH_ABS="${DST_SPEC#*:}"          # /abs/path
DST_SIZE=$(ssh -o StrictHostKeyChecking=no "$DST_USER_HOST" "stat -c %s '$DST_PATH_ABS'")
[ "$DST_SIZE" = "$SRC_SIZE" ] || { echo "[migrate] ERRO: tamanhos diferentes (A=$SRC_SIZE, B=$DST_SIZE)"; exit 1; }
echo "[migrate] cópia validada em B ($DST_SIZE bytes)."

# 4) smoke test no fileserver B
B_HOST="${BACKEND%:*}"; B_PORT="${BACKEND#*:}"
echo "[migrate] testando fileserver em $BACKEND para '$NAME' ..."
printf 'GET %s 0\r\n' "$NAME" | nc -w 3 -v "$B_HOST" "$B_PORT" | head -n1 | grep -q '^DATA ' \
  || { echo "[migrate] ERRO: B não respondeu DATA para $NAME"; exit 1; }

# 5) atualiza routes.json local (proxy com fsnotify pega a mudança)
echo "[migrate] atualizando $ROUTES_LOCAL: $NAME -> $BACKEND"
tmp=$(mktemp)
jq --arg k "$NAME" --arg v "$BACKEND" '.[ $k ] = $v' "$ROUTES_LOCAL" > "$tmp" && mv "$tmp" "$ROUTES_LOCAL"

echo "[migrate] ok! rota trocada para $BACKEND."
