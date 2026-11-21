#!/bin/zsh
# Starts the FitMix backend on this Mac and tells debug builds of the app where to find it.
#   ./run.sh            real avatars (needs OPENAI_API_KEY in .env)
#   FITMIX_MOCK=1 ./run.sh   placeholder avatars, no key needed
set -e
cd "$(dirname "$0")"
PORT="${PORT:-8787}"

[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q --disable-pip-version-check -r requirements.txt
[ -f .env ] || cp .env.example .env

# A shared secret, so other devices on the network can't spend your OpenAI credit.
TOKEN="$(sed -n 's/^FITMIX_APP_TOKEN=//p' .env | tail -1)"
if [ -z "$TOKEN" ]; then
  TOKEN="$(.venv/bin/python -c 'import secrets; print(secrets.token_urlsafe(24))')"
  sed -i '' '/^FITMIX_APP_TOKEN=/d' .env
  echo "FITMIX_APP_TOKEN=$TOKEN" >> .env
fi

# Debug builds read this file (ignored by Git) to find the server. Rebuild the app after it changes.
HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
mkdir -p ../FitMix/Resources
printf '{"url": "http://%s.local:%s", "token": "%s"}\n' "$HOST" "$PORT" "$TOKEN" > ../FitMix/Resources/Backend.local.json

if [ -z "$(sed -n 's/^OPENAI_API_KEY=//p' .env | tail -1)" ] && [ -z "$OPENAI_API_KEY" ] && [ "${FITMIX_MOCK:-$(sed -n 's/^FITMIX_MOCK=//p' .env | tail -1)}" != "1" ]; then
  echo "No OPENAI_API_KEY in Backend/.env yet: the server will start, but avatars can't be made until you add it."
fi
echo "FitMix backend on http://$HOST.local:$PORT  (keep this window open; your iPhone must be on the same Wi-Fi)"
# Values already in the environment (for example FITMIX_MOCK=1 ./run.sh) win over .env.
exec .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port "$PORT" --env-file .env --no-access-log
