#!/bin/sh
# Arranque de la imagen siux (Dockerfile.siux): levanta un Temporal embebido y después
# corre lo mismo que el CMD de Dockerfile.dev. Si TEMPORAL_ADDRESS apunta a otro host,
# no lo levanta y usa ese.
TEMPORAL_DB_FILE="${TEMPORAL_DB_FILE:-/config/temporal.db}"

case "${TEMPORAL_ADDRESS:-localhost:7233}" in
  localhost:* | 127.0.0.1:*)
    mkdir -p "$(dirname "$TEMPORAL_DB_FILE")"
    # Fuera de pm2: el script pm2 de Postiz arranca con "pm2 delete all". El loop lo
    # reinicia si se cae; la base SQLite en el volumen conserva los posts programados.
    (
      while true; do
        temporal server start-dev --headless --ip 127.0.0.1 \
          --db-filename "$TEMPORAL_DB_FILE" --log-level warn
        echo "temporal terminó, reiniciando en 2s" >&2
        sleep 2
      done
    ) &
    i=0
    until temporal operator cluster health --address 127.0.0.1:7233 >/dev/null 2>&1; do
      i=$((i + 1))
      if [ "$i" -ge 60 ]; then
        echo "temporal no respondió en 60s, sigo igual" >&2
        break
      fi
      sleep 1
    done
    ;;
esac

nginx && pnpm run pm2
