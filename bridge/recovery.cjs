#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");
const { execFileSync } = require("child_process");

const MAX_STDIN_BYTES = 8192;
const MAX_DIAGNOSTIC_BYTES = 16384;

const candidateDirs = [
  process.env.HOMELAB_STATUS_DIR,
  path.resolve(__dirname, "../backend"),
  path.resolve(__dirname, "../../status"),
].filter(Boolean);
const resolvedStatusDir = candidateDirs.find((d) => fs.existsSync(d)) || path.resolve(__dirname, "../backend");
const C = require(path.join(resolvedStatusDir, "restart-control.js"));
const Lifecycle = require(path.join(resolvedStatusDir, "lifecycle.js"));
const { scheduleRestartWorker } = require(path.join(resolvedStatusDir, "restart-coordinator.js"));

const JOBS_DIR = process.env.HOMELAB_RESTART_JOBS_DIR || "/tmp/homelab-restart-jobs";

function sendResponse(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function filterLaunchctlOutput(text) {
  if (typeof text !== "string") return "";
  // Exclude entire environment blocks from launchctl print output
  let clean = text.replace(/(?:^|\n)(\s*(?:inherited\s+)?environment\s*=\s*\{[\s\S]*?\n\s*\})/g, "\n\tenvironment = { [EXCLUDED] }");
  // Also strip any remaining launchctl environment variable assignments
  clean = clean.replace(/([A-Za-z0-9_.-]*(?:KEY|SECRET|TOKEN|PASS|AUTH|CREDENTIAL|PRIVATE)[A-Za-z0-9_.-]*\s*=>\s*)[^\n\r]+/gi, "$1[REDACTED]");
  return clean;
}

function redactSecrets(text) {
  if (typeof text !== "string") return "";
  let result = text;

  // 1. Private keys (PEM format)
  result = result.replace(/-----BEGIN (?:[A-Z0-9_-]+ )*PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z0-9_-]+ )*PRIVATE KEY-----/gi, "[REDACTED PRIVATE KEY]");

  // 2. Bearer / Basic / Token auth headers
  result = result.replace(/((?:bearer|basic|token)\s+)[A-Za-z0-9._~+/-]+=*/gi, "$1[REDACTED]");

  // 3. Launchctl arrow style: KEY => VALUE
  result = result.replace(/(\b[A-Za-z0-9_.-]*(?:key|secret|token|password|passwd|auth|credential|private)[A-Za-z0-9_.-]*\b\s*=>\s*)[^\n\r]+/gi, "$1[REDACTED]");

  // 4. Structured JSON field credentials: "key": "value" or 'key': 'value' or key: "value", including escaped \"key\": \"value\"
  result = result.replace(
    /((?:\\?["']?)(?:[A-Za-z0-9_.-]*(?:key|secret|token|password|passwd|auth|credential|private)[A-Za-z0-9_.-]*)(?:\\?["']?)\s*:\s*)(?:\\"(?:\\\\.|[^"\\])*\\"|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;{}\[\]]+)/gi,
    '$1"[REDACTED]"'
  );

  // 5. Generic key-value assignment in query/env/logs: key=value or key: value
  result = result.replace(
    /(\b(?:api[_-]?key|secret|token|password|passwd|auth|credential|access_token|refresh_token)[a-z0-9_.-]*\s*[:=]\s*["']?)[^\s"',;{}\[\]]{4,}["']?/gi,
    "$1[REDACTED]"
  );

  // 6. URL query parameters
  result = result.replace(
    /([?&](?:api[_-]?key|token|secret|password|passwd|auth)=)[^&\s]+/gi,
    "$1[REDACTED]"
  );

  return result;
}

function collectTargets() {
  const nowIso = new Date().toISOString();
  let dockerTargets = [];

  try {
    const stdout = execFileSync(C.BIN_DOCKER, ["ps", "-a", "--format", "{{json .}}"], {
      timeout: 6000,
      encoding: "utf8",
    });
    const lines = stdout.split("\n").filter(Boolean);
    const dockerInv = lines.map((line) => {
      try {
        const item = JSON.parse(line);
        return {
          id: (item.ID || "").slice(0, 12),
          name: (item.Names || "").replace(/^\//, ""),
          state: item.State || (item.Status && item.Status.startsWith("Up") ? "running" : "exited"),
          status: item.Status || "",
        };
      } catch {
        return null;
      }
    }).filter(Boolean);
    dockerTargets = C.buildDockerTargets(dockerInv);
  } catch {
    dockerTargets = [];
  }

  const agentInv = C.collectAgentInventory();
  const agentTargets = C.buildAgentTargets(agentInv);

  const daemonInv = C.collectDaemonInventory();
  const daemonTargets = C.buildDaemonTargets(daemonInv);

  const runtimeInv = C.inspectOrbStackRuntime();
  const runtimeTargets = C.buildRuntimeTargets(runtimeInv);

  const allRaw = [...agentTargets, ...daemonTargets, ...runtimeTargets, ...dockerTargets];

  return allRaw.map((t) => {
    let actionable = Boolean(t.actionable);
    let reason = t.reason || null;
    let highRisk = false;

    // Tailscale and remote access protection
    if (t.key === "daemon:homebrew.mxcl.tailscale" || t.key.includes("tailscale")) {
      highRisk = true;
    }

    // Screensharing protection
    if (t.key === "daemon:com.apple.screensharing" || t.key.includes("screensharing")) {
      highRisk = true;
    }

    // Firewall protection - unsupported target: explicit deny reason
    if (t.key === "daemon:com.homelab.pf" || t.key.includes("pf") || t.key.includes("firewall")) {
      actionable = false;
      reason = "Firewall (pf) kurtarma işlemi uzaktan kilitlenmeyi önlemek için bu arayüzden desteklenmez";
      highRisk = true;
    }

    const isScheduled = t.activation === "scheduled";
    const action = C.recoveryAction(t);
    const defaultLabel = isScheduled
      ? "Şimdi Çalıştır"
      : (t.running ? "Yeniden Başlat" : (t.installed ? "Geri Yükle" : "Başlat"));
    const actionLabel = isScheduled ? (t.actionLabel || defaultLabel) : defaultLabel;
    const warning = t.warning || null;

    return {
      key: t.key,
      display: t.display || t.id,
      kind: t.kind || "agent",
      state: t.state || (t.running ? "running" : "stopped"),
      running: Boolean(t.running),
      installed: Boolean(t.installed),
      actionable,
      reason,
      activation: t.activation || null,
      actionLabel,
      action,
      warning,
      highRisk,
      observedAt: nowIso,
    };
  });
}

function handleInventory() {
  const targets = collectTargets();
  return { ok: true, targets };
}

function handleDiagnostics(input) {
  const targetKey = input.targetKey;
  let diag = "";

  if (targetKey != null && targetKey !== "") {
    if (typeof targetKey !== "string") {
      return { ok: false, error: "targetKey must be a string" };
    }
    const parsedKey = C.parseTargetKey(targetKey);
    if (!parsedKey) {
      return { ok: false, error: "invalid targetKey format" };
    }

    if (parsedKey.kind === "container") {
      try {
        const logs = execFileSync(C.BIN_DOCKER, ["logs", "--tail", "50", parsedKey.id], {
          timeout: 5000,
          encoding: "utf8",
        });
        diag += `=== Container Logs: ${parsedKey.id} ===\n${logs}\n`;
      } catch (err) {
        diag += `=== Container Logs: ${parsedKey.id} (failed: ${err.message}) ===\n`;
      }
      try {
        const inspect = execFileSync(C.BIN_DOCKER, ["inspect", "--format", "State: {{json .State}}", parsedKey.id], {
          timeout: 5000,
          encoding: "utf8",
        });
        diag += `=== Container State: ${parsedKey.id} ===\n${inspect}\n`;
      } catch {}
    } else if (parsedKey.kind === "agent") {
      try {
        const outRaw = execFileSync(C.BIN_LAUNCHCTL, ["print", `${C.AGENT_DOMAIN}/${parsedKey.id}`], {
          timeout: 5000,
          encoding: "utf8",
        });
        const out = filterLaunchctlOutput(outRaw);
        diag += `=== LaunchAgent: ${parsedKey.id} ===\n${out}\n`;
      } catch (err) {
        diag += `=== LaunchAgent: ${parsedKey.id} (not loaded or error: ${err.message}) ===\n`;
      }
    } else if (parsedKey.kind === "daemon") {
      try {
        const outRaw = execFileSync(C.BIN_LAUNCHCTL, ["print", `system/${parsedKey.id}`], {
          timeout: 5000,
          encoding: "utf8",
        });
        const out = filterLaunchctlOutput(outRaw);
        diag += `=== LaunchDaemon: ${parsedKey.id} ===\n${out}\n`;
      } catch (err) {
        diag += `=== LaunchDaemon: ${parsedKey.id} (not loaded or error: ${err.message}) ===\n`;
      }
    } else if (parsedKey.kind === "runtime") {
      try {
        const out = execFileSync(C.BIN_ORBCTL, ["status"], {
          timeout: 5000,
          encoding: "utf8",
        });
        diag += `=== Runtime Status: ${parsedKey.id} ===\n${out}\n`;
      } catch (err) {
        diag += `=== Runtime Status: ${parsedKey.id} (error: ${err.message}) ===\n`;
      }
    }
  } else {
    // Overall diagnostics
    const maintenance = Lifecycle.readMaintenance();
    const jobs = C.listJobs(JOBS_DIR);
    diag += `=== System Overview ===\n`;
    diag += `Uptime: ${Math.round(os.uptime())}s\n`;
    diag += `Load: ${os.loadavg().map((x) => x.toFixed(2)).join(", ")}\n`;
    diag += `Free RAM: ${Math.round(os.freemem() / 1024 / 1024)} MB / Total: ${Math.round(os.totalmem() / 1024 / 1024)} MB\n`;
    diag += `Maintenance: ${JSON.stringify(maintenance)}\n`;
    diag += `Active Jobs: ${jobs.length}\n`;
    for (const j of jobs) {
      diag += `  - [${j.id}] ${j.targetKey} (${j.phase}): ${j.message || ""}\n`;
    }
  }

  const redacted = redactSecrets(diag);
  const bounded = redacted.length > MAX_DIAGNOSTIC_BYTES
    ? redacted.slice(0, MAX_DIAGNOSTIC_BYTES) + "\n[... truncated ...]"
    : redacted;

  return { ok: true, diagnostics: bounded };
}

function handleRecover(input, dependencies = {}) {
  const targetKey = input.targetKey;
  if (!targetKey || typeof targetKey !== "string") {
    return { ok: false, error: "targetKey must be a non-empty string" };
  }

  // Parse key and validate syntax
  const parsedKey = C.parseTargetKey(targetKey);
  if (!parsedKey) {
    return { ok: false, error: "invalid target key syntax: " + targetKey };
  }

  // Explicit deny for unsupported reboot and firewall targets
  if (parsedKey.id === "com.homelab.pf" || targetKey.includes("pf") || targetKey.includes("firewall")) {
    return { ok: false, error: "Firewall (pf) kurtarma işlemi uzaktan kilitlenmeyi önlemek için desteklenmez" };
  }
  if (targetKey.includes("reboot")) {
    return { ok: false, error: "Sistem yeniden başlatma (reboot) bu arayüzden desteklenmez" };
  }

  // Approval date checks: <= 60 seconds age, not future
  const approvedAt = input.approvedAt;
  if (!approvedAt || typeof approvedAt !== "string") {
    return { ok: false, error: "approvedAt must be an ISO8601 date string" };
  }
  const approvedTime = Date.parse(approvedAt);
  if (isNaN(approvedTime)) {
    return { ok: false, error: "invalid approvedAt date string" };
  }
  const now = (dependencies.now || Date.now)();
  const ageMs = now - approvedTime;
  if (ageMs < -5000) {
    return { ok: false, error: "future approval date not permitted" };
  }
  if (ageMs > 60000) {
    return { ok: false, error: "approval expired (>60s)" };
  }

  // Maintenance check before shared coordinator
  const maintenance = (dependencies.readMaintenance || Lifecycle.readMaintenance)();
  if (maintenance && maintenance.active) {
    return { ok: false, error: "bakım modu aktif (" + (maintenance.reason || maintenance.state) + "); kurtarma engellendi" };
  }

  // Fresh inventory check
  const targets = (dependencies.collectTargets || collectTargets)();
  const target = targets.find((t) => t.key === targetKey);
  if (!target) {
    return { ok: false, error: "hedef bulunamadı veya allowlist dışında: " + targetKey };
  }
  if (!target.actionable) {
    return { ok: false, error: target.reason || "hedef kurtarma işlemi için uygun değil" };
  }

  // Effect / Action check: verify fresh target state matches the approved action
  const approvedAction = input.action;
  if (!["restart", "restore", "run_now"].includes(approvedAction)) {
    return { ok: false, error: "explicit approved action is required" };
  }
  if (target.action !== approvedAction) {
    return {
      ok: false,
      error: `onaylanan işlem (${approvedAction}) hedefin güncel durumuyla (${target.action}) uyuşmuyor; işlem engellendi`,
    };
  }
  // High-risk sole-access confirmation check
  const independentAccess = input.independentAccess === true;
  if (target.highRisk && !independentAccess) {
    return { ok: false, error: "protected access recovery is blocked without independent access confirmation" };
  }

  // Schedule restart worker via shared coordinator
  const sched = (dependencies.scheduleRestartWorker || scheduleRestartWorker)(
    targetKey, parsedKey.kind, target.display || parsedKey.id,
    { jobsDir: JOBS_DIR, approvedAction, approvalExpiresAt: approvedTime + 60000 });
  if (!sched.ok) {
    return { ok: false, error: sched.error };
  }

  return {
    ok: true,
    job: {
      id: sched.data.jobId,
      targetKey,
      phase: sched.data.phase || "queued",
      message: "Kurtarma işi kuyruğa alındı",
      error: null,
    },
  };
}

function handleJob(input) {
  const id = input.id;
  if (!id || typeof id !== "string" || !C.isValidJobId(id)) {
    return { ok: false, error: "invalid job id" };
  }

  try {
    C.reconcileJobs(JOBS_DIR, Date.now());
  } catch {}

  const jobRecord = C.readJobAtomic(JOBS_DIR, id);
  if (!jobRecord) {
    return { ok: false, error: "job not found: " + id };
  }

  return {
    ok: true,
    job: {
      id: jobRecord.id,
      targetKey: jobRecord.targetKey,
      phase: jobRecord.phase,
      message: jobRecord.message || null,
      error: jobRecord.error || null,
    },
  };
}

function handleCommand(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    return { ok: false, error: "input must be a JSON object" };
  }

  const cmd = input.command;
  switch (cmd) {
    case "inventory":
      return handleInventory();
    case "diagnostics":
      return handleDiagnostics(input);
    case "recover":
      return handleRecover(input);
    case "job":
      return handleJob(input);
    default:
      return { ok: false, error: "unknown command: " + String(cmd) };
  }
}

function main() {
  let chunks = [];
  let totalBytes = 0;
  let terminated = false;

  process.stdin.on("data", (chunk) => {
    if (terminated) return;
    totalBytes += chunk.length;
    if (totalBytes > MAX_STDIN_BYTES) {
      terminated = true;
      sendResponse({ ok: false, error: "stdin payload exceeds 8 KiB limit" });
      process.exit(0);
    }
    chunks.push(chunk);
  });

  process.stdin.on("end", () => {
    if (terminated) return;
    terminated = true;
    const bodyRaw = Buffer.concat(chunks).toString("utf8").trim();
    if (!bodyRaw) {
      sendResponse({ ok: false, error: "empty input" });
      return;
    }

    let input;
    try {
      input = JSON.parse(bodyRaw);
    } catch {
      sendResponse({ ok: false, error: "invalid JSON input" });
      return;
    }

    try {
      const response = handleCommand(input);
      sendResponse(response);
    } catch (err) {
      sendResponse({ ok: false, error: "bridge internal error: " + (err.message || String(err)) });
    }
  });
}

if (require.main === module) main();

module.exports = { redactSecrets, filterLaunchctlOutput, handleCommand, handleRecover };
