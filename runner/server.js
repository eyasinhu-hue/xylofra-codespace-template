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

app.post("/preview", async (req, res) => {
  const { port } = req.body || {};
  const p = parseInt(port || "3000", 10);
  if (!CODESPACE_NAME) {
    return res.json({ url: `http://localhost:${p}`, note: "Not in Codespace" });
  }
  const url = `https://${CODESPACE_NAME}-${p}.${PORT_FORWARD_DOMAIN}`;
  res.json({ url, port: p, codespace: CODESPACE_NAME });
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
