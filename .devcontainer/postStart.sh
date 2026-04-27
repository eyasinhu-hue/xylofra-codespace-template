#!/usr/bin/env bash
set -e
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER_DIR="$REPO_ROOT/runner"
LOG_FILE="/tmp/xylofra-runner.log"

# Ensure deps installed (in case postCreate skipped)
if [ ! -d "$RUNNER_DIR/node_modules" ]; then
  (cd "$RUNNER_DIR" && npm install --no-audit --no-fund)
fi

# Persist a runner secret if not present
SECRET_FILE="/tmp/xylofra-runner.secret"
if [ ! -f "$SECRET_FILE" ]; then
  if [ -n "${RUNNER_SECRET:-}" ]; then
    echo -n "$RUNNER_SECRET" > "$SECRET_FILE"
  else
    head -c 48 /dev/urandom | base64 | tr -d '/+=' | head -c 40 > "$SECRET_FILE"
  fi
fi

# Start the runner detached if not already running
if ! pgrep -f "node.*runner/server.js" > /dev/null 2>&1; then
  echo "[xylofra] starting runner on :${RUNNER_PORT:-3939}"
  RUNNER_SECRET="$(cat "$SECRET_FILE")" \
  WORKSPACE_DIR="/workspaces/workspace" \
  nohup node "$RUNNER_DIR/server.js" > "$LOG_FILE" 2>&1 &
  disown
fi

echo "[xylofra] postStart done"
