#!/usr/bin/env bash
set -e
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER_DIR="$REPO_ROOT/runner"
RUNNER_LOG="/tmp/xylofra-runner.log"
TUNNEL_LOG="/tmp/xylofra-tunnel.log"
URL_FILE="/tmp/xylofra-public-url.txt"

# Source repo-stored runner.env if present
if [ -f "$REPO_ROOT/.devcontainer/runner.env" ]; then
  set -a; . "$REPO_ROOT/.devcontainer/runner.env"; set +a
fi

# Ensure runner deps installed
if [ ! -d "$RUNNER_DIR/node_modules" ]; then
  (cd "$RUNNER_DIR" && npm install --no-audit --no-fund) || true
fi

# Ensure shared workspace dir exists
mkdir -p /workspaces/workspace

# Persist runner secret (use injected RUNNER_SECRET if available)
SECRET_FILE="/tmp/xylofra-runner.secret"
if [ ! -f "$SECRET_FILE" ]; then
  if [ -n "${RUNNER_SECRET:-}" ]; then
    echo -n "$RUNNER_SECRET" > "$SECRET_FILE"
  else
    head -c 48 /dev/urandom | base64 | tr -d '/+=' | head -c 40 > "$SECRET_FILE"
  fi
fi
SECRET_VAL="$(cat "$SECRET_FILE")"

# 1) Start the runner if not already running
if ! pgrep -f "node.*runner/server.js" > /dev/null 2>&1; then
  echo "[xylofra] starting runner on :${RUNNER_PORT:-3939}"
  RUNNER_SECRET="$SECRET_VAL" \
  WORKSPACE_DIR="/workspaces/workspace" \
  PORT="${RUNNER_PORT:-3939}" \
  nohup node "$RUNNER_DIR/server.js" > "$RUNNER_LOG" 2>&1 &
  disown
fi

# 2) Wait until runner answers locally
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${RUNNER_PORT:-3939}/health" > /dev/null 2>&1; then
    echo "[xylofra] runner healthy locally"
    break
  fi
  sleep 1
done

# 3) Install cloudflared if missing
if ! command -v cloudflared > /dev/null 2>&1; then
  echo "[xylofra] installing cloudflared..."
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /tmp/cloudflared
  chmod +x /tmp/cloudflared
  sudo mv /tmp/cloudflared /usr/local/bin/cloudflared || mv /tmp/cloudflared "$HOME/cloudflared"
  command -v cloudflared > /dev/null 2>&1 || export PATH="$HOME:$PATH"
fi

# 4) Start cloudflared quick tunnel if not running
if ! pgrep -f "cloudflared.*tunnel" > /dev/null 2>&1; then
  echo "[xylofra] starting cloudflared quick tunnel..."
  rm -f "$TUNNEL_LOG"
  nohup cloudflared tunnel --no-autoupdate --url "http://localhost:${RUNNER_PORT:-3939}" \
    > "$TUNNEL_LOG" 2>&1 &
  disown
fi

# 5) Parse the trycloudflare URL from logs
PUBLIC_URL=""
for i in $(seq 1 60); do
  PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -n1 || true)"
  if [ -n "$PUBLIC_URL" ]; then break; fi
  sleep 1
done

if [ -z "$PUBLIC_URL" ]; then
  echo "[xylofra] FAILED to obtain public URL from cloudflared. tail of log:"
  tail -n 50 "$TUNNEL_LOG" || true
  exit 0
fi

echo -n "$PUBLIC_URL" > "$URL_FILE"
echo "[xylofra] public URL: $PUBLIC_URL"

# 6) Self-register the URL with Supabase (uses anon key + secret)
if [ -n "${SUPABASE_URL_PUBLIC:-}" ] && [ -n "${SUPABASE_ANON_KEY:-}" ]; then
  REG_BODY=$(cat <<JSON
{"p_secret":"$SECRET_VAL","p_url":"$PUBLIC_URL"}
JSON
  )
  REG_RESP=$(curl -sS -X POST \
    -H "apikey: ${SUPABASE_ANON_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_ANON_KEY}" \
    -H "Content-Type: application/json" \
    -d "$REG_BODY" \
    "${SUPABASE_URL_PUBLIC}/rest/v1/rpc/register_runner_url" || true)
  echo "[xylofra] register_runner_url response: $REG_RESP"
else
  echo "[xylofra] WARN: SUPABASE_URL_PUBLIC or SUPABASE_ANON_KEY missing; URL not auto-registered."
fi

echo "[xylofra] postStart complete."
