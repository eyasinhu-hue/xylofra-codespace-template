#!/usr/bin/env bash
# postStart.sh — runs every time the codespace starts (cold or wake-up).
# Boots the runner + Cloudflare quick tunnel + a URL watcher under pm2 and
# registers the public URL via the runner-registry edge function (NOT direct
# SQL RPC — keeps anon out of SECURITY DEFINER functions).
set -euo pipefail

LOG=/tmp/xylofra-diag.log
exec > >(tee -a "$LOG") 2>&1
echo "[$(date -Iseconds)] postStart starting"

REPO_DIR="/workspaces/$(basename "$(pwd)")"
[ -d "$REPO_DIR" ] || REPO_DIR="/workspaces/xylofra-codespace-template"
cd "$REPO_DIR"

# Pull latest template changes (safe fast-forward only)
git fetch --quiet origin main || true
git checkout --quiet main 2>/dev/null || true
git merge --ff-only origin/main 2>/dev/null || true
echo "[$(date -Iseconds)] git at $(git rev-parse --short HEAD)"

# Optional local override file
if [ -f runner.env ]; then
  set -a
  # shellcheck disable=SC1091
  source runner.env
  set +a
fi

: "${RUNNER_SECRET:?RUNNER_SECRET codespace secret missing}"
: "${SUPABASE_URL_PUBLIC:?SUPABASE_URL_PUBLIC codespace secret missing}"
: "${SUPABASE_ANON_KEY:?SUPABASE_ANON_KEY codespace secret missing}"

# Strip /rest/v1 suffix the user may have added
SUPABASE_URL_PUBLIC="${SUPABASE_URL_PUBLIC%/rest/v1}"
SUPABASE_URL_PUBLIC="${SUPABASE_URL_PUBLIC%/}"

PORT=3939
echo "$RUNNER_SECRET" > /tmp/xylofra-runner.secret
chmod 600 /tmp/xylofra-runner.secret

# Install runner deps if missing
if [ -d runner ]; then
  pushd runner >/dev/null
  [ -d node_modules ] || npm install --quiet
  popd >/dev/null
fi

# pm2
command -v pm2 >/dev/null || npm install -g pm2 >/dev/null

pm2 delete xylofra-runner 2>/dev/null || true
pm2 start runner/server.js --name xylofra-runner --update-env -- --port "$PORT"

# Wait for runner /health
for _ in $(seq 1 30); do
  if curl -fsS "http://localhost:${PORT}/health" >/dev/null 2>&1; then break; fi
  sleep 1
done

# Install cloudflared if missing
if ! command -v cloudflared >/dev/null; then
  curl -fsSL -o /tmp/cf.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cf.deb >/dev/null
fi

pm2 delete xylofra-tunnel 2>/dev/null || true
pm2 start "cloudflared tunnel --url http://localhost:${PORT} --no-autoupdate" \
  --name xylofra-tunnel --update-env

# Wait for the public URL
URL=""
for _ in $(seq 1 30); do
  URL=$(pm2 logs xylofra-tunnel --lines 200 --nostream 2>/dev/null \
        | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)
  [ -n "$URL" ] && break
  sleep 2
done
echo "[$(date -Iseconds)] tunnel URL: ${URL:-<not detected>}"

CS_NAME="${CODESPACE_NAME:-$(hostname)}"

register_payload () {
  curl -sS -m 8 -X POST "${SUPABASE_URL_PUBLIC}/functions/v1/runner-registry" \
    -H "Authorization: Bearer ${SUPABASE_ANON_KEY}" \
    -H "apikey: ${SUPABASE_ANON_KEY}" \
    -H "Content-Type: application/json" \
    --data "$1"
  echo
}

if [ -n "$URL" ]; then
  echo "[$(date -Iseconds)] registering URL via runner-registry..."
  register_payload "{\"secret\":\"${RUNNER_SECRET}\",\"url\":\"${URL}\",\"codespace\":\"${CS_NAME}\",\"port\":${PORT}}"
fi

# url-watcher: re-register if the tunnel URL changes + heartbeat every 4 min
cat > /tmp/xylofra-watcher.sh <<WATCH
#!/usr/bin/env bash
LAST=""
while true; do
  CUR=\$(pm2 logs xylofra-tunnel --lines 200 --nostream 2>/dev/null \
        | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)
  if [ -n "\$CUR" ]; then
    SECRET=\$(cat /tmp/xylofra-runner.secret 2>/dev/null)
    PAYLOAD="{\"secret\":\"\$SECRET\",\"url\":\"\$CUR\",\"codespace\":\"${CS_NAME}\",\"port\":${PORT}}"
    curl -sS -m 8 -X POST "${SUPABASE_URL_PUBLIC}/functions/v1/runner-registry" \
      -H "Authorization: Bearer ${SUPABASE_ANON_KEY}" \
      -H "apikey: ${SUPABASE_ANON_KEY}" \
      -H "Content-Type: application/json" \
      --data "\$PAYLOAD" >/dev/null
    LAST="\$CUR"
  fi
  sleep 240
done
WATCH
chmod +x /tmp/xylofra-watcher.sh

pm2 delete xylofra-watcher 2>/dev/null || true
pm2 start /tmp/xylofra-watcher.sh --name xylofra-watcher --interpreter bash

# Final diag push
DIAG=$(tail -c 12000 "$LOG")
register_payload "{\"secret\":\"${RUNNER_SECRET}\",\"diag\":$(printf %s "$DIAG" | jq -Rs .)}"

echo "[$(date -Iseconds)] postStart complete"
