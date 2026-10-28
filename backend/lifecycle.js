"use strict";
const fs = require("fs");
const path = require("path");
const { spawn, execFileSync } = require("child_process");
const HELPER = [
  path.join(__dirname, "lifecycle.py"),
  path.join(__dirname, "../orbstack-guard/lifecycle.py"),
].find((f) => fs.existsSync(f)) || path.join(__dirname, "lifecycle.py");
const PYTHON = "/usr/bin/python3";
const maintenanceFile = () => process.env.HOMELAB_MAINTENANCE_FILE || path.join(__dirname, "maintenance.json");
const configuredDataDir = () => execFileSync(PYTHON, [HELPER, "data-dir"], { timeout: 5000, encoding: "utf8" }).trim();

function readMaintenance(file = maintenanceFile(), nowSec = Date.now() / 1000) {
  let record;
  try {
    const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    try {
      const info = fs.fstatSync(fd);
      if (!info.isFile() || info.size > 65536) throw new Error("maintenance must be a bounded regular file");
      record = JSON.parse(fs.readFileSync(fd, "utf8"));
    } finally { fs.closeSync(fd); }
  }
  catch (error) {
    if (error.code === "ENOENT") return { active: false, state: "clear", reason: "" };
    return { active: true, state: "maintenance-invalid", reason: "maintenance unreadable or corrupt; operator required" };
  }
  if (!record || typeof record.active !== "boolean" ||
      !["scope", "owner", "reason"].every(key => typeof record[key] === "string" && record[key].trim()) ||
      !["since", "deadline"].every(key => Number.isFinite(record[key]) && record[key] >= 0) || record.deadline <= record.since) {
    return { active: true, state: "maintenance-invalid", reason: "maintenance schema invalid; operator required" };
  }
  return { ...record, state: !record.active ? "clear" : record.deadline <= nowSec ? "maintenance-expired" : "maintenance" };
}

async function withOwnership(job, dependencies, operation) {
  const options = dependencies.lifecycleOptions || {};
  const file = options.maintenanceFile || maintenanceFile();
  const now = dependencies.now || Date.now;
  const check = () => {
    const maintenance = readMaintenance(file);
    if (maintenance.active) throw new Error(maintenance.state + ": " + maintenance.reason);
    // Fixture overrides can add a block but can never disable native maintenance.
    if (dependencies.maintenanceActive && dependencies.maintenanceActive()) throw new Error("maintenance: recovery blocked");
    if (!Number.isFinite(job.deadlineAt) || now() >= job.deadlineAt) {
      const error = new Error("job deadline exceeded"); error.deadline = true; throw error;
    }
  };
  check();
  // Fixture clocks may differ from wall time; only the injected clock controls
  // those deadlines. Production sessions enforce the same absolute job deadline.
  const sessionDeadline = dependencies.now ? Date.now() + Math.max(1, job.deadlineAt - now()) : job.deadlineAt;
  const child = spawn(PYTHON, [HELPER, "--maintenance-file", file, "session", "--deadline-ms", String(sessionDeadline)], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  let finished = false;
  child.once("exit", () => { finished = true; });
  child.once("error", () => { finished = true; });
  child.stdin.on("error", () => {});
  let stderr = "";
  child.stderr.on("data", chunk => { stderr += chunk.toString(); });
  let endpoint;
  try {
    endpoint = await new Promise((resolve, reject) => {
      let buffer = "";
      const timer = setTimeout(() => reject(new Error("lifecycle ownership acquisition deadline")), 5000);
      const fail = error => { clearTimeout(timer); reject(error); };
      child.once("error", fail);
      child.once("exit", () => fail(new Error(stderr.trim() || "recovery operation already owned")));
      child.stdout.on("data", chunk => {
        buffer += chunk.toString();
        if (!buffer.includes("\n")) return;
        clearTimeout(timer);
        try { resolve(JSON.parse(buffer.split("\n")[0]).socket); } catch (error) { reject(error); }
      });
    });
    check();
    if (dependencies.beforeOperation) dependencies.beforeOperation();
    const execFile = (binary, args, settings = {}) => {
      check();
      const timeout = Math.max(1, Math.min(settings.timeout || 15000, job.deadlineAt - now()));
      if (dependencies.execFile) return dependencies.execFile(binary, args, { ...settings, timeout });
      return execFileSync(PYTHON, [HELPER, "exec", "--socket", endpoint, "--request",
        JSON.stringify({ args: [binary, ...args], timeout })], {
        ...settings, timeout: timeout + 2000, encoding: "utf8",
      });
    };
    return await operation({ ...dependencies, execFile, lifecycleCheck: check,
      lifecycleDataDir: options.dataDir || null });
  } finally {
    // Wait for ownership release before a caller starts another operation. Never
    // kill the holder: it may still be waiting for a command after client death.
    child.stdin.end();
    if (!finished) {
      await new Promise(resolve => {
        const timer = setTimeout(resolve, 1200);
        child.once("exit", () => { clearTimeout(timer); resolve(); });
      });
    }
    if (!finished) {
      // A stuck CLI retains the helper's lock. Detach, never kill/unlock it.
      child.unref();
      child.stdout.destroy();
      child.stderr.destroy();
      child.stdin.destroy();
    }
  }
}

module.exports = { readMaintenance, withOwnership, configuredDataDir, maintenanceFile };
