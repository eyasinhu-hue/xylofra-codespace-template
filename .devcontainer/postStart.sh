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

# 1) Ensure pm2 (process supervisor) is installed
if ! command -v pm2 > /dev/null 2>&1; then
  diag "installing pm2 globally..."
  npm install -g pm2 > /tmp/pm2-install.log 2>&1 \
    && diag "pm2 installed: $(pm2 --version 2>/dev/null)" \
    || diag "pm2 install FAILED ($(tail -n 3 /tmp/pm2-install.log | tr '\n' '|'))"
fi

# 2) Start the runner under pm2 (idempotent — restarts cleanly each call)
if command -v pm2 > /dev/null 2>&1; then
  pm2 delete xylofra-runner > /dev/null 2>&1 || true
  RUNNER_SECRET="$SECRET_VAL" \
  WORKSPACE_DIR="/workspaces/workspace" \
  PORT="${RUNNER_PORT:-3939}" \
  pm2 start "$RUNNER_DIR/server.js" \
    --name xylofra-runner --time --update-env --max-memory-restart 1G \
    > /tmp/pm2-start.log 2>&1 \
    && diag "runner started under pm2" \
    || diag "pm2 start FAILED ($(tail -n 3 /tmp/pm2-start.log | tr '\n' '|'))"
  pm2 save --force > /dev/null 2>&1 || true
else
  # Fallback: nohup (won't survive SSH sessions)
  diag "WARN: pm2 unavailable, falling back to nohup"
  pkill -f "node.*runner/server.js" 2>/dev/null || true
  RUNNER_SECRET="$SECRET_VAL" \
  WORKSPACE_DIR="/workspaces/workspace" \
  PORT="${RUNNER_PORT:-3939}" \
  nohup setsid node "$RUNNER_DIR/server.js" > "$RUNNER_LOG" 2>&1 < /dev/null &
  disown
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

# 4) Start cloudflared quick tunnel under pm2 (so it survives SSH session end
#    and auto-restarts on crash)
CFD_BIN="$(command -v cloudflared || echo /usr/local/bin/cloudflared)"
: > "$TUNNEL_LOG"

if command -v pm2 > /dev/null 2>&1 && [ -x "$CFD_BIN" ]; then
  pm2 delete xylofra-tunnel > /dev/null 2>&1 || true
  diag "starting cloudflared under pm2 -> http://localhost:${RUNNER_PORT:-3939}"
  pm2 start "$CFD_BIN" \
    --name xylofra-tunnel --time --restart-delay 3000 \
    --output "$TUNNEL_LOG" --error "$TUNNEL_LOG" \
    -- tunnel --no-autoupdate --url "http://localhost:${RUNNER_PORT:-3939}" \
    > /tmp/pm2-tunnel.log 2>&1 \
    && diag "tunnel started under pm2" \
    || diag "pm2 tunnel start FAILED ($(tail -n 3 /tmp/pm2-tunnel.log | tr '\n' '|'))"
  pm2 save --force > /dev/null 2>&1 || true
else
  pkill -f "cloudflared.*tunnel" 2>/dev/null || true
  diag "WARN: pm2 unavailable, falling back to nohup for cloudflared"
  nohup setsid cloudflared tunnel --no-autoupdate --url "http://localhost:${RUNNER_PORT:-3939}" \
    > "$TUNNEL_LOG" 2>&1 < /dev/null &
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

# 6) Helper: register URL with Supabase (used by initial registration AND watcher)
register_url() {
  local URL="$1"
  if [ -z "${SUPABASE_URL_PUBLIC:-}" ] || [ -z "${SUPABASE_ANON_KEY:-}" ]; then
    return 1
  fi
  curl -sS -m 10 -X POST \
    -H "apikey: ${SUPABASE_ANON_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_ANON_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"p_secret\":\"$SECRET_VAL\",\"p_url\":\"$URL\"}" \
    "${SUPABASE_URL_PUBLIC}/rest/v1/rpc/register_runner_url"
}

# 6a) Initial registration
REG_RESP=$(register_url "$PUBLIC_URL" 2>&1)
diag "register_runner_url resp: $REG_RESP"

# 7) URL watcher under pm2: detects when cloudflared crashes/restarts and gets
#    a new *.trycloudflare.com URL, then re-registers it with Supabase. Also
#    fires a heartbeat re-registration every 5 minutes to keep
#    runner_last_seen fresh.
WATCHER_SCRIPT="$HOME/.xylofra-url-watcher.sh"
cat > "$WATCHER_SCRIPT" <<WATCHER_EOF
#!/usr/bin/env bash
TUNNEL_LOG="$TUNNEL_LOG"
URL_FILE="$URL_FILE"
SECRET_VAL="$SECRET_VAL"
SUPABASE_URL_PUBLIC="${SUPABASE_URL_PUBLIC:-}"
SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}"

last_url=""
[ -s "\$URL_FILE" ] && last_url="\$(cat "\$URL_FILE")"
heartbeat=0
while true; do
  current="\$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "\$TUNNEL_LOG" 2>/dev/null | tail -n1)"
  if [ -n "\$current" ] && [ "\$current" != "\$last_url" ]; then
    echo "[watcher] URL changed: \$last_url -> \$current"
    echo -n "\$current" > "\$URL_FILE"
    last_url="\$current"
    heartbeat=0
    if [ -n "\$SUPABASE_URL_PUBLIC" ] && [ -n "\$SUPABASE_ANON_KEY" ]; then
      curl -sS -m 10 -X POST \
        -H "apikey: \$SUPABASE_ANON_KEY" \
        -H "Authorization: Bearer \$SUPABASE_ANON_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"p_secret\":\"\$SECRET_VAL\",\"p_url\":\"\$current\"}" \
        "\$SUPABASE_URL_PUBLIC/rest/v1/rpc/register_runner_url" > /dev/null
      echo "[watcher] re-registered: \$current"
    fi
  fi
  heartbeat=\$((heartbeat + 1))
  if [ \$heartbeat -ge 30 ] && [ -n "\$last_url" ]; then
    # Heartbeat every ~5 min (30 * 10s) to refresh runner_last_seen
    if [ -n "\$SUPABASE_URL_PUBLIC" ] && [ -n "\$SUPABASE_ANON_KEY" ]; then
      curl -sS -m 10 -X POST \
        -H "apikey: \$SUPABASE_ANON_KEY" \
        -H "Authorization: Bearer \$SUPABASE_ANON_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"p_secret\":\"\$SECRET_VAL\",\"p_url\":\"\$last_url\"}" \
        "\$SUPABASE_URL_PUBLIC/rest/v1/rpc/register_runner_url" > /dev/null
    fi
    heartbeat=0
  fi
  sleep 10
done
WATCHER_EOF
chmod +x "$WATCHER_SCRIPT"

if command -v pm2 > /dev/null 2>&1; then
  pm2 delete xylofra-watcher > /dev/null 2>&1 || true
  pm2 start "$WATCHER_SCRIPT" \
    --name xylofra-watcher --time --interpreter bash \
    --restart-delay 5000 \
    > /tmp/pm2-watcher.log 2>&1 \
    && diag "watcher started under pm2" \
    || diag "pm2 watcher start FAILED ($(tail -n 3 /tmp/pm2-watcher.log | tr '\n' '|'))"
  pm2 save --force > /dev/null 2>&1 || true
fi

diag "postStart complete."
