#!/usr/bin/env bash
# Do NOT use `set -e` — we want to capture and report errors, not abort silently.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER_DIR="$REPO_ROOT/runner"
RUNNER_LOG="/tmp/xylofra-runner.log"
TUNNEL_LOG="/tmp/xylofra-tunnel.log"
URL_FILE="/tmp/xylofra-public-url.txt"
DIAG_FILE="/tmp/xylofra-diag.log"

: > "$DIAG_FILE"
diag() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$DIAG_FILE"; }

# Auto-update repo so future postStart edits apply on restart
(cd "$REPO_ROOT" && git fetch --quiet origin main && git reset --hard origin/main >/dev/null 2>&1) && diag "git updated to $(git -C "$REPO_ROOT" rev-parse --short HEAD)" || diag "git update FAILED"

# Source repo-stored runner.env if present (overrides Codespaces secret)
if [ -f "$REPO_ROOT/.devcontainer/runner.env" ]; then
  set -a; . "$REPO_ROOT/.devcontainer/runner.env"; set +a
  diag "sourced runner.env"
fi

# Detect injected env vars (don't print values)
for v in RUNNER_SECRET SUPABASE_URL_PUBLIC SUPABASE_ANON_KEY XYLOFRA_PROJECT_REF; do
  if [ -n "${!v:-}" ]; then diag "env $v: present (len=${#!v})"; else diag "env $v: MISSING"; fi
done

# Persist runner secret
SECRET_FILE="/tmp/xylofra-runner.secret"
if [ ! -f "$SECRET_FILE" ]; then
  if [ -n "${RUNNER_SECRET:-}" ]; then
    echo -n "$RUNNER_SECRET" > "$SECRET_FILE"
  else
    head -c 48 /dev/urandom | base64 | tr -d '/+=' | head -c 40 > "$SECRET_FILE"
  fi
fi
SECRET_VAL="$(cat "$SECRET_FILE")"
diag "runner secret persisted (len=${#SECRET_VAL})"

# Helper: post text diag back to Supabase (best effort)
report_diag() {
  if [ -z "${SUPABASE_URL_PUBLIC:-}" ] || [ -z "${SUPABASE_ANON_KEY:-}" ]; then
    diag "report_diag: missing supabase env, skipping"
    return 0
  fi
  local payload diag_text
  diag_text="$(tail -n 100 "$DIAG_FILE" 2>/dev/null | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"\"")"
  payload="{\"p_secret\":$(printf %s "$SECRET_VAL" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))'),\"p_diag\":$diag_text}"
  local resp
  resp=$(curl -sS -X POST \
    -H "apikey: ${SUPABASE_ANON_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_ANON_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${SUPABASE_URL_PUBLIC}/rest/v1/rpc/register_runner_diag" 2>&1)
  diag "report_diag resp: $resp"
}
trap report_diag EXIT

# Ensure runner deps installed
if [ ! -d "$RUNNER_DIR/node_modules" ]; then
  (cd "$RUNNER_DIR" && npm install --no-audit --no-fund) > /tmp/runner-install.log 2>&1 \
    && diag "runner npm install: ok" \
    || diag "runner npm install: FAILED ($(tail -n 5 /tmp/runner-install.log | tr '\n' ' '))"
fi

mkdir -p /workspaces/workspace

# 1) Start the runner if not running
if ! pgrep -f "node.*runner/server.js" > /dev/null 2>&1; then
  diag "starting runner on :${RUNNER_PORT:-3939}"
  RUNNER_SECRET="$SECRET_VAL" \
  WORKSPACE_DIR="/workspaces/workspace" \
  PORT="${RUNNER_PORT:-3939}" \
  nohup node "$RUNNER_DIR/server.js" > "$RUNNER_LOG" 2>&1 &
  disown
else
  diag "runner already running"
fi

# 2) Wait for runner local health
RUNNER_OK=0
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${RUNNER_PORT:-3939}/health" > /dev/null 2>&1; then
    RUNNER_OK=1; diag "runner local health OK after ${i}s"; break
  fi
  sleep 1
done
if [ "$RUNNER_OK" != "1" ]; then
  diag "runner local health FAILED. tail of log: $(tail -n 20 "$RUNNER_LOG" 2>/dev/null | tr '\n' '|')"
  exit 0
fi

# 3) Install cloudflared
if ! command -v cloudflared > /dev/null 2>&1; then
  diag "downloading cloudflared..."
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cloudflared
  if [ -s /tmp/cloudflared ]; then
    chmod +x /tmp/cloudflared
    sudo mv /tmp/cloudflared /usr/local/bin/cloudflared 2>/dev/null || mv /tmp/cloudflared "$HOME/cloudflared"
    [ ! -x "$(command -v cloudflared)" ] && export PATH="$HOME:$PATH"
    diag "cloudflared installed at: $(command -v cloudflared || echo MISSING)"
  else
    diag "cloudflared download FAILED"
    exit 0
  fi
fi

# 4) Start cloudflared quick tunnel
if ! pgrep -f "cloudflared.*tunnel" > /dev/null 2>&1; then
  : > "$TUNNEL_LOG"
  diag "starting cloudflared tunnel -> http://localhost:${RUNNER_PORT:-3939}"
  nohup cloudflared tunnel --no-autoupdate --url "http://localhost:${RUNNER_PORT:-3939}" \
    > "$TUNNEL_LOG" 2>&1 &
  disown
fi

# 5) Parse the trycloudflare URL
PUBLIC_URL=""
for i in $(seq 1 60); do
  PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -n1)"
  if [ -n "$PUBLIC_URL" ]; then diag "tunnel URL acquired in ${i}s: $PUBLIC_URL"; break; fi
  sleep 1
done

if [ -z "$PUBLIC_URL" ]; then
  diag "FAILED to obtain public URL. tunnel log tail: $(tail -n 30 "$TUNNEL_LOG" 2>/dev/null | tr '\n' '|')"
  exit 0
fi

echo -n "$PUBLIC_URL" > "$URL_FILE"

# 6) Self-register with Supabase
if [ -n "${SUPABASE_URL_PUBLIC:-}" ] && [ -n "${SUPABASE_ANON_KEY:-}" ]; then
  REG_BODY="{\"p_secret\":\"$SECRET_VAL\",\"p_url\":\"$PUBLIC_URL\"}"
  REG_RESP=$(curl -sS -X POST \
    -H "apikey: ${SUPABASE_ANON_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_ANON_KEY}" \
    -H "Content-Type: application/json" \
    -d "$REG_BODY" \
    "${SUPABASE_URL_PUBLIC}/rest/v1/rpc/register_runner_url" 2>&1)
  diag "register_runner_url resp: $REG_RESP"
else
  diag "WARN: Supabase env vars not set; URL not auto-registered."
fi

diag "postStart complete."
