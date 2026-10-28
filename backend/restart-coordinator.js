"use strict";

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const C = require("./restart-control.js");

const Lifecycle = require("./lifecycle.js");

const DEFAULT_WORKER_PATH = path.join(__dirname, "restart-worker.js");
const DEFAULT_JOBS_DIR = process.env.HOMELAB_RESTART_JOBS_DIR || "/tmp/homelab-restart-jobs";

function scheduleRestartWorker(targetKey, targetKind, targetName, options = {}) {
  const jobsDir = options.jobsDir || DEFAULT_JOBS_DIR;
  const workerPath = options.workerPath || DEFAULT_WORKER_PATH;
  const execFile = options.execFile || execFileSync;
  const fsImpl = options.fsImpl || fs;
  const now = typeof options.now === "function" ? options.now() : (typeof options.now === "number" ? options.now : Date.now());
  const lockPath = options.lockPath || path.join(jobsDir, ".admission.lock");

  try {
    fsImpl.mkdirSync(jobsDir, { recursive: true, mode: 0o700 });
  } catch {}

  let lockFd = null;
  try {
    lockFd = fsImpl.openSync(lockPath, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_RDWR, 0o600);
  } catch (err) {
    if (err && err.code === "EEXIST") {
      // Lock already exists. Fail closed on corrupt or stale lock rather than auto-delete live owner.
      let existingLock = null;
      try {
        const raw = fsImpl.readFileSync(lockPath, "utf8");
        existingLock = JSON.parse(raw);
      } catch {
        return {
          ok: false,
          code: 409,
          error: "kurtarma kabul kilidi bozuk veya okunamıyor; operatör müdahalesi gerekli",
        };
      }

      if (!existingLock || typeof existingLock !== "object" ||
          existingLock.active !== true ||
          !Number.isFinite(existingLock.since) ||
          !Number.isFinite(existingLock.deadline) ||
          existingLock.deadline <= existingLock.since) {
        return {
          ok: false,
          code: 409,
          error: "kurtarma kabul kilidi şeması geçersiz; operatör müdahalesi gerekli",
        };
      }

      return {
        ok: false,
        code: 409,
        error: "başka bir kurtarma işlemi kabul aşamasında (" + (existingLock.targetKey || "kilit aktif") + ")",
      };
    }

    return {
      ok: false,
      code: 500,
      error: "kurtarma kabul kilidi açılamadı: " + (err ? (err.message || String(err)) : "bilinmeyen hata"),
    };
  }

  try {
    const lockRecord = {
      active: true,
      owner: process.pid,
      targetKey,
      since: now,
      deadline: now + 30000,
    };
    fsImpl.writeFileSync(lockFd, JSON.stringify(lockRecord, null, 1));
    if (typeof fsImpl.fsyncSync === "function") {
      try { fsImpl.fsyncSync(lockFd); } catch {}
    }

    // Re-read the clock after acquiring admission: native consent may have
    // expired while the caller was obtaining ownership.
    const admittedAt = typeof options.now === "function" ? options.now()
      : typeof options.now === "number" ? options.now : Date.now();
    const approval = {
      approvedAction: options.approvedAction,
      approvalExpiresAt: options.approvalExpiresAt,
    };
    const approvalError = C.approvalError(approval, admittedAt);
    if (approvalError) return { ok: false, code: 409, error: approvalError };

    // Maintenance check
    const nativeMaintenance = Lifecycle.readMaintenance(options.maintenanceFile, admittedAt / 1000);
    const maintenance = nativeMaintenance.active ? nativeMaintenance : options.maintenance;
    if (maintenance && maintenance.active) {
      return {
        ok: false,
        code: 409,
        error: "bakım modu aktif (" + (maintenance.reason || maintenance.state) + "); kurtarma engellendi",
      };
    }

    // Terminal job cleanup and active job check
    C.cleanupTerminalJobs(jobsDir, now, 86400000);
    const active = C.anyActiveJob(C.listJobs(jobsDir));
    if (active) {
      return { ok: false, code: 409, error: "zaten devam eden bir restart işlemi var (Job: " + active.id + ")" };
    }

    const jobId = C.makeJobId();
    const job = C.newJobRecord({ id: jobId, targetKey, kind: targetKind, name: targetName, now: admittedAt, ...approval });
    C.writeJobAtomic(jobsDir, job);

    const label = C.workerLabel(jobId);
    const submitArgs = C.buildSubmitArgs({
      label,
      workerPath,
      jobId,
      targetKey,
    });

    try {
      execFile(submitArgs[0], submitArgs.slice(1), { timeout: 8000, encoding: "utf8" });
    } catch (err) {
      try { fsImpl.unlinkSync(C.jobFilePath(jobsDir, jobId)); } catch {}
      const errText = String((err && (err.stderr || err.message)) || "").trim();
      return { ok: false, code: 503, error: "worker başlatılamadı: " + errText };
    }

    return { ok: true, code: 202, data: { ok: true, jobId, phase: "queued" } };
  } finally {
    if (lockFd != null) {
      try { fsImpl.closeSync(lockFd); } catch {}
      try { fsImpl.unlinkSync(lockPath); } catch {}
    }
  }
}

module.exports = {
  scheduleRestartWorker,
  DEFAULT_WORKER_PATH,
  DEFAULT_JOBS_DIR,
};
