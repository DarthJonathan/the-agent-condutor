#!/bin/sh
# Local-only development setup. Existing environment files are never overwritten.
set -eu
conductor_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$conductor_root"
if [ ! -f .env ]; then
  (umask 077; python3 - <<'PY'
import secrets
from pathlib import Path
with Path('.env').open('x') as file:
    file.write('PUBLIC_ORIGIN=http://localhost:3005\nWEB_PORT=3005\nDEVELOPMENT=true\nALLOW_SIGNUP=true\n')
    file.write('POSTGRES_PASSWORD=' + secrets.token_hex(32) + '\n')
    file.write('SESSION_SECRET=' + secrets.token_hex(32) + '\n')
PY
  )
fi
docker compose up -d --build
printf 'Conductor web: http://localhost:3005\nCreate your account there, then sign in from the Mac app’s Remote screen.\n'
