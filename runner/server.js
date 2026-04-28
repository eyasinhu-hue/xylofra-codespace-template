"use strict";

const express = require("express");
const fs = require("fs");
const fsp = require("fs/promises");
const path = require("path");
const { spawn, exec } = require("child_process");

const PORT = parseInt(process.env.RUNNER_PORT || "3939", 10);
const SECRET = process.env.RUNNER_SECRET || "";
const WORKSPACE_DIR = process.env.WORKSPACE_DIR || "/workspaces/workspace";
const CODESPACE_NAME = process.env.CODESPACE_NAME || "";
const PORT_FORWARD_DOMAIN =
  process.env.GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN || "app.github.dev";

if (!fs.existsSync(WORKSPACE_DIR)) fs.mkdirSync(WORKSPACE_DIR, { recursive: true });

const app = express();
app.use(express.json({ limit: "20mb" }));

// --- Auth middleware --------------------------------------------------------
app.use((req, res, next) => {
  if (req.path === "/health") return next();
  const auth = req.get("authorization") || "";
  const token = auth.replace(/^Bearer\s+/i, "");
  if (!SECRET || token !== SECRET) {
    return res.status(401).json({ error: "unauthorized" });
  }
  next();
});

// --- Helpers ----------------------------------------------------------------
function safePath(rel) {
  const p = path.resolve(WORKSPACE_DIR, rel || ".");
  if (!p.startsWith(WORKSPACE_DIR)) {
    throw new Error("path escapes workspace");
  }
  return p;
}

function runShell(cmd, opts = {}) {
  return new Promise((resolve) => {
    const child = exec(cmd, {
      cwd: opts.cwd || WORKSPACE_DIR,
      timeout: opts.timeoutMs || 120000,
      maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, ...opts.env },
    }, (err, stdout, stderr) => {
      resolve({
        stdout: String(stdout || "").slice(0, 200000),
        stderr: String(stderr || "").slice(0, 50000),
        exitCode: err ? (err.code || 1) : 0,
        signal: err && err.signal ? err.signal : null,
      });
    });
    child.on("error", () => {});
  });
}

// --- Routes ----------------------------------------------------------------
app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    codespace: CODESPACE_NAME,
    workspace: WORKSPACE_DIR,
    port: PORT,
    forward_domain: PORT_FORWARD_DOMAIN,
    uptime: process.uptime(),
  });
});

app.post("/exec", async (req, res) => {
  const { cmd, cwd, timeoutMs, env } = req.body || {};
  if (!cmd || typeof cmd !== "string") return res.status(400).json({ error: "cmd required" });
  try {
    const result = await runShell(cmd, {
      cwd: cwd ? safePath(cwd) : WORKSPACE_DIR,
      timeoutMs,
      env,
    });
    res.json(result);
  } catch (e) {
    res.status(400).json({ error: String(e.message || e) });
  }
});

app.post("/file/write", async (req, res) => {
  const { path: rel, content, encoding } = req.body || {};
  if (!rel || content === undefined) return res.status(400).json({ error: "path and content required" });
  try {
    const target = safePath(rel);
    await fsp.mkdir(path.dirname(target), { recursive: true });
    if (encoding === "base64") {
      await fsp.writeFile(target, Buffer.from(content, "base64"));
    } else {
      await fsp.writeFile(target, content, "utf8");
    }
    const stat = await fsp.stat(target);
    res.json({ ok: true, path: rel, bytes: stat.size });
  } catch (e) {
    res.status(400).json({ error: String(e.message || e) });
  }
});

app.post("/file/read", async (req, res) => {
  const { path: rel, encoding } = req.body || {};
  if (!rel) return res.status(400).json({ error: "path required" });
  try {
    const target = safePath(rel);
    const buf = await fsp.readFile(target);
    if (encoding === "base64") {
      res.json({ content: buf.toString("base64"), encoding: "base64", bytes: buf.length });
    } else {
      res.json({ content: buf.toString("utf8"), encoding: "utf8", bytes: buf.length });
    }
  } catch (e) {
    res.status(400).json({ error: String(e.message || e) });
  }
});

app.post("/file/list", async (req, res) => {
  const { path: rel, recursive, limit } = req.body || {};
  try {
    const target = safePath(rel || ".");
    const max = Math.min(parseInt(limit || "1000", 10), 5000);
    const entries = [];
    if (recursive) {
      const stack = [target];
      while (stack.length && entries.length < max) {
        const dir = stack.pop();
        let items;
        try { items = await fsp.readdir(dir, { withFileTypes: true }); } catch (_) { continue; }
        for (const it of items) {
          if (it.name === "node_modules" || it.name === ".git") continue;
          const full = path.join(dir, it.name);
          const relPath = path.relative(WORKSPACE_DIR, full);
          entries.push({ name: relPath, type: it.isDirectory() ? "dir" : "file" });
          if (it.isDirectory()) stack.push(full);
          if (entries.length >= max) break;
        }
      }
    } else {
      const items = await fsp.readdir(target, { withFileTypes: true });
      for (const it of items) {
        entries.push({ name: it.name, type: it.isDirectory() ? "dir" : "file" });
      }
    }
    res.json({ entries });
  } catch (e) {
    res.status(400).json({ error: String(e.message || e) });
  }
});

app.post("/file/delete", async (req, res) => {
  const { path: rel, recursive } = req.body || {};
  if (!rel) return res.status(400).json({ error: "path required" });
  try {
    const target = safePath(rel);
    await fsp.rm(target, { recursive: !!recursive, force: true });
    res.json({ ok: true });
  } catch (e) {
    res.status(400).json({ error: String(e.message || e) });
  }
});

app.post("/file/mkdir", async (req, res) => {
  const { path: rel } = req.body || {};
  if (!rel) return res.status(400).json({ error: "path required" });
  try {
    const target = safePath(rel);
    await fsp.mkdir(target, { recursive: true });
    res.json({ ok: true });
  } catch (e) {
    res.status(400).json({ error: String(e.message || e) });
  }
});

app.post("/file/search", async (req, res) => {
  const { pattern, file_pattern } = req.body || {};
  if (!pattern) return res.status(400).json({ error: "pattern required" });
  const include = file_pattern ? `--include="${file_pattern.replace(/"/g, "")}"` : "";
  const safe = pattern.replace(/"/g, '\\"');
  const result = await runShell(
    `grep -r ${include} -n --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" --include="*.json" --include="*.css" --include="*.html" -e "${safe}" . 2>/dev/null | head -80`
  );
  res.json({ matches: result.stdout.trim() || "(no matches)" });
});

// --- Per-port public preview tunnels (cloudflared quick tunnels under pm2) --
// Each user-app port (3000, 5173, 8000, ...) gets its OWN public cloudflared
// quick tunnel so the preview is reachable WITHOUT GitHub auth. Tunnels are
// pm2-supervised so they survive the runner crashing.
const PREVIEW_LOG_DIR = "/tmp";
const previewLog = (p) => `${PREVIEW_LOG_DIR}/xylofra-preview-${p}.log`;
const previewUrlFile = (p) => `${PREVIEW_LOG_DIR}/xylofra-preview-${p}.url`;
const previewName = (p) => `xylofra-preview-${p}`;

function execCmd(cmd, timeoutMs = 15000) {
  return new Promise((resolve) => {
    exec(cmd, { timeout: timeoutMs, maxBuffer: 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({ ok: !err, stdout: String(stdout || ""), stderr: String(stderr || ""), err });
    });
  });
}

async function readPreviewUrl(p, timeoutMs = 25000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const buf = await fsp.readFile(previewLog(p), "utf8");
      const m = buf.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/);
      if (m) return m[0];
    } catch (_) { /* log not created yet */ }
    await new Promise((r) => setTimeout(r, 500));
  }
  return null;
}

app.post("/preview", async (req, res) => {
  const { port, force } = req.body || {};
  const p = parseInt(port || "3000", 10);
  if (!Number.isInteger(p) || p < 1 || p > 65535) {
    return res.status(400).json({ error: "invalid port" });
  }

  // 1) Cached URL? Try the file written by a prior /preview call.
  if (!force) {
    try {
      const cached = (await fsp.readFile(previewUrlFile(p), "utf8")).trim();
      if (cached.startsWith("https://")) {
        // Verify pm2 tunnel still alive
        const list = await execCmd(`pm2 jlist`, 8000);
        let alive = false;
        try {
          const arr = JSON.parse(list.stdout || "[]");
          alive = arr.some((x) => x.name === previewName(p) && x.pm2_env?.status === "online");
        } catch (_) {}
        if (alive) return res.json({ url: cached, port: p, cached: true });
      }
    } catch (_) { /* no cache */ }
  }

  // 2) Find cloudflared binary
  const which = await execCmd(`command -v cloudflared || echo ""`, 4000);
  const cfdBin = which.stdout.trim();
  if (!cfdBin) {
    // Fallback: GitHub auth-protected URL (only works in browser w/ auth)
    if (CODESPACE_NAME) {
      const url = `https://${CODESPACE_NAME}-${p}.${PORT_FORWARD_DOMAIN}`;
      return res.json({ url, port: p, fallback: "github-port-forward", note: "cloudflared missing" });
    }
    return res.status(500).json({ error: "cloudflared not installed and not in Codespace" });
  }

  // 3) Spawn cloudflared under pm2 (idempotent — delete then start)
  await execCmd(`pm2 delete ${previewName(p)} 2>/dev/null`, 4000);
  // Wipe the old log so we don't read a stale URL
  try { await fsp.writeFile(previewLog(p), ""); } catch (_) {}
  const startCmd =
    `pm2 start "${cfdBin}" --name ${previewName(p)} --time --restart-delay 3000 ` +
    `--output "${previewLog(p)}" --error "${previewLog(p)}" ` +
    `-- tunnel --no-autoupdate --url http://localhost:${p}`;
  const started = await execCmd(startCmd, 10000);
  if (!started.ok) {
    return res.status(500).json({
      error: "failed to start preview tunnel",
      detail: (started.stderr || started.stdout).slice(0, 500),
    });
  }
  await execCmd(`pm2 save --force 2>/dev/null`, 4000);

  // 4) Poll log for trycloudflare URL
  const url = await readPreviewUrl(p, 30000);
  if (!url) {
    let tail = "";
    try { tail = (await fsp.readFile(previewLog(p), "utf8")).slice(-600); } catch (_) {}
    return res.status(504).json({
      error: "tunnel started but URL not found in log",
      log_tail: tail,
    });
  }
  try { await fsp.writeFile(previewUrlFile(p), url); } catch (_) {}
  res.json({ url, port: p, cached: false });
});

app.post("/preview/stop", async (req, res) => {
  const { port } = req.body || {};
  const p = parseInt(port, 10);
  if (!Number.isInteger(p)) return res.status(400).json({ error: "invalid port" });
  await execCmd(`pm2 delete ${previewName(p)} 2>/dev/null`, 5000);
  try { await fsp.unlink(previewUrlFile(p)); } catch (_) {}
  res.json({ ok: true, port: p });
});

app.get("/preview/list", async (_req, res) => {
  const list = await execCmd(`pm2 jlist`, 8000);
  let entries = [];
  try {
    const arr = JSON.parse(list.stdout || "[]");
    for (const x of arr) {
      const m = (x.name || "").match(/^xylofra-preview-(\d+)$/);
      if (!m) continue;
      const p = parseInt(m[1], 10);
      let url = null;
      try { url = (await fsp.readFile(previewUrlFile(p), "utf8")).trim() || null; } catch (_) {}
      entries.push({ port: p, status: x.pm2_env?.status || "unknown", url });
    }
  } catch (_) {}
  res.json({ entries });
});

// Streaming snapshot of all text files (used by edge function syncAll)
app.post("/file/snapshot", async (req, res) => {
  const { max_files, max_bytes } = req.body || {};
  const maxFiles = Math.min(parseInt(max_files || "200", 10), 1000);
  const maxBytes = Math.min(parseInt(max_bytes || "5242880", 10), 50 * 1024 * 1024);
  const out = [];
  let totalBytes = 0;
  const skip = new Set(["node_modules", ".git", "dist", "build", ".next", ".cache", ".turbo", "coverage"]);
  const stack = [WORKSPACE_DIR];
  while (stack.length && out.length < maxFiles && totalBytes < maxBytes) {
    const dir = stack.pop();
    let items;
    try { items = await fsp.readdir(dir, { withFileTypes: true }); } catch (_) { continue; }
    for (const it of items) {
      if (skip.has(it.name)) continue;
      const full = path.join(dir, it.name);
      if (it.isDirectory()) { stack.push(full); continue; }
      let stat;
      try { stat = await fsp.stat(full); } catch (_) { continue; }
      if (stat.size > 512 * 1024) continue;
      let content;
      try { content = await fsp.readFile(full, "utf8"); } catch (_) { continue; }
      const rel = path.relative(WORKSPACE_DIR, full);
      out.push({ path: rel, content, bytes: stat.size });
      totalBytes += stat.size;
      if (out.length >= maxFiles || totalBytes >= maxBytes) break;
    }
  }
  res.json({ files: out, total_files: out.length, total_bytes: totalBytes });
});

app.listen(PORT, "0.0.0.0", () => {
  console.log(`[xylofra-runner] listening on :${PORT}, workspace=${WORKSPACE_DIR}, codespace=${CODESPACE_NAME}`);
});
