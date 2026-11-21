#!/bin/zsh
# Starts the FitMix vision service on this Mac.
#   ./run.sh                 real pipeline (fill in .env first)
#   MOCK_MODE=1 ./run.sh     realistic fake data, no keys, no model downloads
set -e
cd "$(dirname "$0")"
PORT="${PORT:-$(sed -n 's/^PORT=//p' .env 2>/dev/null | tail -1)}"
PORT="${PORT:-8790}"

if [ ! -d .venv ]; then
  # torch wheels lag new Python releases, so prefer a well-supported version when several are installed.
  for candidate in python3.12 python3.13 python3.11 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
      PY="$candidate"; break
    fi
  done
  if [ -z "$PY" ]; then
    echo "The vision service needs Python 3.10 or newer. Install it with: brew install python@3.12"; exit 1
  fi
  "$PY" -m venv .venv
fi
.venv/bin/pip install -q --disable-pip-version-check -r requirements.txt
[ -f .env ] || cp .env.example .env

HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
echo "FitMix vision service on http://localhost:$PORT  (from an iPhone on the same Wi-Fi: http://$HOST.local:$PORT)"
# Values already in the environment (for example MOCK_MODE=1 ./run.sh) win over .env.
exec .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port "$PORT" --env-file .env --no-access-log
