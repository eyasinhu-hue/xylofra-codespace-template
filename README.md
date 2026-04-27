# Xylofra Codespace Template

This repo is the template that Xylofra uses to spin up an isolated GitHub
Codespace for every user project. Each Codespace runs a small HTTP runner
service (Express) on port `3939` so the Supabase Edge Function can execute
shell commands, read/write files, and serve previews.

## Layout

```
.devcontainer/
  devcontainer.json   # Codespace spec (Node 22, ports, postCreate)
  postCreate.sh       # one-time setup (npm install)
  postStart.sh        # start the runner on every codespace boot
runner/
  server.js           # Express HTTP server (the runner itself)
  package.json
```

## Runner endpoints

All require `Authorization: Bearer <RUNNER_SECRET>` (except `/health`).

- `GET  /health`           – liveness + codespace identity
- `POST /exec`             – run a shell command (`{ cmd, cwd?, timeoutMs? }`)
- `POST /file/write`       – write a file (`{ path, content, encoding? }`)
- `POST /file/read`        – read a file (`{ path, encoding? }`)
- `POST /file/list`        – list a directory (`{ path, recursive?, limit? }`)
- `POST /file/delete`      – delete (`{ path, recursive? }`)
- `POST /file/mkdir`       – make directory
- `POST /file/search`      – grep-style search
- `POST /file/snapshot`    – bulk snapshot of all text files (for syncAll)
- `POST /preview`          – return public Codespaces forward URL for a port

## Workspace

User project files live in `/workspaces/workspace`. The runner
sandboxes paths to that directory.

## Created by Xylofra Agent System
