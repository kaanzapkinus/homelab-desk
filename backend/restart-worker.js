#!/opt/homebrew/bin/node
// restart-worker.js — Homelab Hub bağımsız transient launchd restart worker'ı.
// `launchctl submit` ile yaratılır; Status API veya Hub ölse/restart olsa dahi yaşamaya devam eder.
// Parametreler: process.argv[2] = jobId (32 hex), process.argv[3] = targetKey (container:x, agent:y, containers:all)
// Sorumluluk:
//   1. Job kaydını yükler, doğrular.
//   2. Self-restart (status/hub) durumunda HTTP yanıtının istemciye ulaşması için 2.5s bekler.
//   3. Durdurma ve başlatma adımlarını icra eder, `stopping` ve `starting` state transition'larını atomik yazar.
//   4. Health ve readiness'ı deadline dolana kadar her 2s'de bir yoklar.
//   5. Sonucu (`healthy`, `failed`, `timed_out`) yazar, kendi transient launchd tanımını kaldırır.
"use strict";

const net = require("net");
const fs = require("fs");
const path = require("path");
const { execFileSync, spawn } = require("child_process");
const C = require("./restart-control.js");
const Lifecycle = require("./lifecycle.js");

async function ownedOperation(operation, job, id, dependencies = {}) {
  try {
    return await Lifecycle.withOwnership(job, dependencies, io => {
      checkApproval(job, io);
      return operation(job, id, io);
    });
  } catch (error) {
    if (error.obsolete) return;
    const now = dependencies.now || Date.now;
    C.applyTransition(job, error.deadline ? "timed_out" : "failed", now(), error.message);
    job.error = error.message;
    const persist = dependencies.persist || (record => C.writeJobAtomic(JOBS_DIR, record));
    persist(job);
  }
}

const runContainerRestart = (job, id, dependencies) => ownedOperation(containerRestartOwned, job, id, dependencies);
const runAgentRestart = (job, id, dependencies) => ownedOperation(agentRestartOwned, job, id, dependencies);
const runDaemonRestart = (job, id, dependencies) => ownedOperation(daemonRestartOwned, job, id, dependencies);
const runRuntimeRestart = (job, id, dependencies) => ownedOperation(runtimeRestartOwned, job, id, dependencies);
const runBulkRestart = (job, dependencies) => ownedOperation(bulkRestartOwned, job, null, dependencies);


function checkApproval(job, dependencies, actualAction) {
  dependencies.lifecycleCheck();
  const error = C.approvalError(job, (dependencies.now || Date.now)());
  if (error) throw new Error(error);
  if (job.approvedAction !== undefined && actualAction !== undefined &&
      job.approvedAction !== actualAction) {
    throw new Error("approved recovery effect changed: " + job.approvedAction + " -> " + actualAction);
  }
}

function checkLaunchApproval(job, meta, info, initiallyLoaded, dependencies) {
  const running = meta.activation === "one-shot" ? info.loaded && info.lastExit === "0"
    : info.loaded && info.state === "running";
  checkApproval(job, dependencies, C.recoveryAction({ activation: meta.activation, running }));
  if (job.approvedAction === "restore" && !initiallyLoaded && info.loaded) {
    throw new Error("restore target became loaded; new approval required");
  }
}
const JOBS_DIR = process.env.HOMELAB_RESTART_JOBS_DIR || "/tmp/homelab-restart-jobs";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function portOpen(port, host = "127.0.0.1", timeout = 900) {
  const tryHost = (h) =>
    new Promise((res) => {
      const s = net.connect({ port, host: h, timeout });
      s.on("connect", () => { s.destroy(); res(true); });
      s.on("error", () => res(false));
      s.on("timeout", () => { s.destroy(); res(false); });
    });
  return tryHost("127.0.0.1");
}

function selfRemove(jobId) {
  const label = C.workerLabel(jobId);
  try {
    spawn(C.BIN_LAUNCHCTL, ["remove", label], { detached: true, stdio: "ignore" }).unref();
  } catch {}
}

async function containerRestartOwned(job, name, dependencies) {
  const execFile = dependencies.execFile;
  const pause = dependencies.sleep || sleep;
  const clock = dependencies.now || Date.now;
  const persist = dependencies.persist || (record => C.writeJobAtomic(JOBS_DIR, record));
  const now = clock();
  const target = C.buildDockerTargets([{ name, state: "running" }])[0];
  if (!target || !target.actionable) throw new Error("container retired/disabled or invalid; restart prohibited");
  const inspectRunning = () => {
    try {
      const out = execFile(
        C.BIN_DOCKER,
        ["inspect", "-f", "{{.State.Running}}", name],
        { timeout: 5000, encoding: "utf8" }
      ).trim();
      return out === "true";
    } catch {
      return false;
    }
  };

  if (job.approvedAction !== undefined) {
    let running = inspectRunning();
    checkApproval(job, dependencies, C.recoveryAction({ activation: "always-on", running }));
    if (!running) {
      await pause(250);
      running = inspectRunning();
      checkApproval(job, dependencies, C.recoveryAction({ activation: "always-on", running }));
    }
  }

  const needsStop = job.approvedAction !== "restore";
  if (needsStop) {
    C.applyTransition(job, "stopping", now(), "container durduruluyor…");
    persist(job);

    try {
      execFile(C.BIN_DOCKER, ["container", "stop", "--time", "10", name], {
        timeout: Math.min(60000, job.deadlineAt - clock()),
        encoding: "utf8",
      });
    } catch (err) {
      const msg = "docker restart başarısız: " + (err.stderr || err.message || "").trim();
      C.applyTransition(job, "failed", Date.now(), msg);
      job.error = msg;
      persist(job);
      return;
    }
  }

  checkApproval(job, dependencies);
  C.applyTransition(job, "starting", clock(), "container başlatılıyor…");
  persist(job);

  try {
    execFile(C.BIN_DOCKER, ["container", "start", name], {
      timeout: Math.min(60000, job.deadlineAt - clock()), encoding: "utf8",
    });
  } catch (err) {
    const msg = "docker restart başarısız: " + (err.stderr || err.message || "").trim();
    C.applyTransition(job, "failed", Date.now(), msg);
    job.error = msg;
    persist(job);
    return;
  }

  C.applyTransition(job, "starting", clock(), "sağlık ve hazır olma durumu bekleniyor…");
  persist(job);

  // Readiness döngüsü
  while (clock() < job.deadlineAt) {
    await pause(Math.min(2000, Math.max(1, job.deadlineAt - clock())));
    dependencies.lifecycleCheck();
    let inspectOut = "";
    try {
      inspectOut = execFile(
        C.BIN_DOCKER,
        ["inspect", "-f", "{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}", name],
        { timeout: 5000, encoding: "utf8" }
      ).trim();
    } catch {
      continue;
    }

    const [runningStr, health] = inspectOut.split("|");
    const isRunning = runningStr === "true";
    if (!isRunning) continue;

    if (health === "healthy" || health === "none") {
      C.applyTransition(job, "healthy", Date.now(), "container başarıyla çalışıyor ve sağlıklı");
      persist(job);
      return;
    }

    if (health === "unhealthy") {
      const msg = "container sağlık kontrolünden geçemedi (unhealthy)";
      C.applyTransition(job, "failed", Date.now(), msg);
      job.error = msg;
      persist(job);
      return;
    }
  }

  const msg = "container hazır olma süresi aşıldı (deadline: " + Math.round(C.DEFAULT_DEADLINE_MS / 1000) + "s)";
  C.applyTransition(job, "timed_out", Date.now(), msg);
  job.error = msg;
  persist(job);
}

async function agentRestartOwned(job, label, dependencies) {
  // Injectable I/O exercises real state transitions without touching host services.
  const execFile = dependencies.execFile || execFileSync;
  const inspectState = dependencies.inspectState || ((id) => C.inspectAgentState(id, execFile));
  const inspectPlist = dependencies.inspectPlist || C.inspectAgentPlist;
  const persist = dependencies.persist || ((record) => C.writeJobAtomic(JOBS_DIR, record));
  const now = dependencies.now || Date.now;
  const pause = dependencies.sleep || sleep;
  const probePort = dependencies.portOpen || portOpen;
  const fail = (message) => {
    C.applyTransition(job, "failed", now(), message);
    job.error = message;
    persist(job);
  };
  const meta = Object.hasOwn(C.LAUNCH_AGENT_ALLOWLIST, label) && C.LAUNCH_AGENT_ALLOWLIST[label];
  if (!meta) return fail("allowlist dışı launch agent");

  const plist = inspectPlist(label);
  if (!plist.valid) return fail("kurulu plist güvenli değil: " + plist.reason);
  let info = inspectState(label);
  if (info.inspectionError || (!info.loaded && !info.absent)) return fail(info.inspectionError || "launchd yokluğu doğrulanamadı");

  const initiallyLoaded = info.loaded;
  checkLaunchApproval(job, meta, info, initiallyLoaded, dependencies);
  // Confirm absence repeatedly. Native restore never escalates to forced restart.
  if (!info.loaded) {
    await pause(250);
    info = inspectState(label);
    if (info.inspectionError || (!info.loaded && !info.absent)) return fail(info.inspectionError || "launchd yokluğu doğrulanamadı");
    checkLaunchApproval(job, meta, info, initiallyLoaded, dependencies);
  }
  const checkedPlist = inspectPlist(label);
  if (!checkedPlist.valid || !C.sameFile(plist.identity, checkedPlist.identity)) {
    return fail("plist işlem öncesinde değişti veya geçersiz: " + (checkedPlist.reason || "dosya kimliği değişti"));
  }
  // launchctl bootstrap yalnız doğrulanmış yoklukta; mevcut kayıt asla unload edilmez.
  if (!info.loaded) {
    info = inspectState(label);
    if (info.inspectionError || (!info.loaded && !info.absent)) return fail(info.inspectionError || "launchd yokluğu doğrulanamadı");
  }
  if (job.approvedAction !== undefined && initiallyLoaded) {
    info = inspectState(label);
    if (info.inspectionError || !info.loaded) return fail(info.inspectionError || "launchd durumu değişti");
  }
  checkLaunchApproval(job, meta, info, initiallyLoaded, dependencies);
  if (now() >= job.deadlineAt) {
    C.applyTransition(job, "timed_out", now(), "işlem başlamadan deadline aşıldı");
    job.error = job.message;
    persist(job);
    return;
  }
  const oldPid = info.pid;
  const oldRuns = info.runs;
  if (meta.activation === "scheduled" && info.state === "running") {
    return fail("planlı iş zaten çalışıyor; çalışan iş kesilmez");
  }
  const recovering = !info.loaded;
  const command = recovering
    ? [C.BIN_LAUNCHCTL, "bootstrap", C.AGENT_DOMAIN, checkedPlist.plistPath]
    : meta.activation === "scheduled"
      ? [C.BIN_LAUNCHCTL, "kickstart", C.AGENT_DOMAIN + "/" + label]
      : job.approvedAction === "restore"
        ? [C.BIN_LAUNCHCTL, "kickstart", C.AGENT_DOMAIN + "/" + label]
        : C.buildKickstartArgs(label);
  C.applyTransition(job, recovering ? "starting" : "stopping", now(),
    recovering ? "kurulu servis launchd'ye geri yükleniyor…" : "launchctl " + command.slice(1).join(" ") + " gönderiliyor…");
  persist(job);
  try {
    checkApproval(job, dependencies);
    execFile(command[0], command.slice(1), { timeout: Math.min(15000, Math.max(1, job.deadlineAt - now())), encoding: "utf8" });
  } catch (err) {
    return fail((recovering ? "bootstrap" : "kickstart") + " başarısız: " + String(err.stderr || err.message || "").trim());
  }
  if (!recovering) C.applyTransition(job, "starting", now(), "servisin hazır olması bekleniyor…");
  else job.message = "servis geri yüklendi; hazır olması bekleniyor…";
  persist(job);

  if (recovering && meta.activation === "scheduled") {
    // Bootstrap restores the schedule; the explicit user action must also run it once.
    try {
      info = inspectState(label);
      if (!info.loaded || info.inspectionError || info.state === "running") {
        return fail(info.inspectionError || "planlı iş zaten çalışıyor veya launchd kaydı değişti");
      }
      checkApproval(job, dependencies, "run_now");
      execFile(C.BIN_LAUNCHCTL, ["kickstart", C.AGENT_DOMAIN + "/" + label], {
        timeout: Math.min(15000, Math.max(1, job.deadlineAt - now())), encoding: "utf8",
      });
    } catch (err) {
      return fail("planlı iş başlatılamadı: " + String(err.stderr || err.message || "").trim());
    }
  }

  if (meta.activation === "scheduled") {
    let sawRunning = false;
    while (now() < job.deadlineAt) {
      await pause(Math.min(2000, Math.max(1, job.deadlineAt - now())));
      if (now() >= job.deadlineAt) break;
      info = inspectState(label);
      if (!info.loaded) {
        return fail("iş yürütülürken launchd kaydı kayboldu");
      }
      if (info.state === "running") {
        sawRunning = true;
        job.message = "planlı iş çalışıyor (PID: " + info.pid + ")…";
        persist(job);
        continue;
      }
      if (info.state === "not running") {
        const runCompleted = sawRunning || (info.runs != null && (oldRuns == null ? info.runs > 0 : info.runs > oldRuns));
        if (runCompleted) {
          if (info.lastExit === "0") {
            C.applyTransition(job, "healthy", now(), "planlı iş başarıyla tamamlandı (exit 0)");
            persist(job);
            return;
          }
          if (info.lastExit && info.lastExit !== "0" && info.lastExit !== "(never exited)") {
            return fail("planlı iş başarısız tamamlandı (exit code: " + info.lastExit + ")");
          }
        }
      }
    }
    const msg = "planlı iş tamamlama süresi aşıldı";
    C.applyTransition(job, "timed_out", now(), msg);
    job.error = msg;
    persist(job);
    return;
  }

  let stablePidCount = 0;
  let lastSeenPid = null;
  while (now() < job.deadlineAt) {
    await pause(Math.min(2000, Math.max(1, job.deadlineAt - now())));
    if (now() >= job.deadlineAt) break;
    info = inspectState(label);
    if (!info.loaded || info.state !== "running" || info.pid == null || (oldPid != null && info.pid === oldPid)) {
      stablePidCount = 0;
      lastSeenPid = null;
      continue;
    }
    // Tüm servislerde stabil yeni PID; portlar sadece ek readiness kanıtıdır.
    if (info.pid === lastSeenPid) stablePidCount++;
    else { lastSeenPid = info.pid; stablePidCount = 1; }
    let allPortsUp = true;
    for (const port of meta.ports) {
      if (!await probePort(port)) { allPortsUp = false; break; }
    }
    if (!allPortsUp) { stablePidCount = 0; continue; }
    if (stablePidCount >= 2) {
      C.applyTransition(job, "healthy", now(), "servis ayakta ve stabil (PID: " + info.pid + ")");
      persist(job);
      return;
    }
  }
  const msg = "servisin hazır olma süresi aşıldı";
  C.applyTransition(job, "timed_out", now(), msg);
  job.error = msg;
  persist(job);
}

async function daemonRestartOwned(job, label, dependencies) {
  const execFile = dependencies.execFile || execFileSync;
  const inspectState = dependencies.inspectState || ((id) => C.inspectSystemState(id, execFile));
  const inspectPlist = dependencies.inspectPlist || C.inspectSystemPlist;
  const persist = dependencies.persist || ((record) => C.writeJobAtomic(JOBS_DIR, record));
  const now = dependencies.now || Date.now;
  const pause = dependencies.sleep || sleep;
  const probePort = dependencies.portOpen || portOpen;
  const fail = (message) => {
    C.applyTransition(job, "failed", now(), message);
    job.error = message;
    persist(job);
  };

  const meta = Object.hasOwn(C.SYSTEM_DAEMON_ALLOWLIST, label) && C.SYSTEM_DAEMON_ALLOWLIST[label];
  if (!meta) return fail("allowlist dışı sistem daemoni");

  const plist = inspectPlist(label);
  if (!plist.valid) return fail("kurulu plist güvenli değil: " + plist.reason);

  let info = inspectState(label);
  if (info.inspectionError || (!info.loaded && !info.absent)) {
    return fail(info.inspectionError || "launchd yokluğu doğrulanamadı");
  }
  const initiallyLoaded = info.loaded;
  checkLaunchApproval(job, meta, info, initiallyLoaded, dependencies);

  if (!info.loaded && meta.allowRecovery === false) {
    return fail(meta.reasonIfAbsent || "bu sistem servisi otomatik bootstrap edilemez");
  }

  if (!info.loaded) {
    await pause(250);
    info = inspectState(label);
    if (info.inspectionError || (!info.loaded && !info.absent)) {
      return fail(info.inspectionError || "launchd yokluğu doğrulanamadı");
    }
    checkLaunchApproval(job, meta, info, initiallyLoaded, dependencies);
  }

  const checkedPlist = inspectPlist(label);
  if (!checkedPlist.valid || !C.sameFile(plist.identity, checkedPlist.identity)) {
    return fail("plist işlem öncesinde değişti veya geçersiz: " + (checkedPlist.reason || "dosya kimliği değişti"));
  }

  if (!info.loaded) {
    info = inspectState(label);
    if (info.inspectionError || (!info.loaded && !info.absent)) {
      return fail(info.inspectionError || "launchd yokluğu doğrulanamadı");
    }
  }
  if (job.approvedAction !== undefined && initiallyLoaded) {
    info = inspectState(label);
    if (info.inspectionError || !info.loaded) return fail(info.inspectionError || "launchd durumu değişti");
  }
  checkLaunchApproval(job, meta, info, initiallyLoaded, dependencies);

  if (now() >= job.deadlineAt) {
    C.applyTransition(job, "timed_out", now(), "işlem başlamadan deadline aşıldı");
    job.error = job.message;
    persist(job);
    return;
  }

  const oldPid = info.pid;
  const oldRuns = info.runs;
  const recovering = !info.loaded;
  const command = recovering
    ? C.buildBootstrapArgs(checkedPlist.plistPath, "system")
    : job.approvedAction === "restore"
      ? [C.BIN_SUDO, "-n", C.BIN_LAUNCHCTL, "kickstart", "system/" + label]
      : C.buildKickstartArgs(label, "system");

  C.applyTransition(
    job,
    recovering ? "starting" : "stopping",
    now(),
    recovering
      ? "sistem daemoni geri yükleniyor (sudo launchctl bootstrap)…"
      : command.slice(1).join(" ") + " gönderiliyor…"
  );
  persist(job);

  try {
    checkApproval(job, dependencies);
    execFile(command[0], command.slice(1), {
      timeout: Math.min(15000, Math.max(1, job.deadlineAt - now())),
      encoding: "utf8",
    });
  } catch (err) {
    return fail((recovering ? "bootstrap" : "kickstart") + " başarısız: " + String(err.stderr || err.message || "").trim());
  }

  if (!recovering) {
    C.applyTransition(job, "starting", now(), "servisin hazır olması bekleniyor…");
  } else {
    job.message = "servis geri yüklendi; hazır olması bekleniyor…";
  }
  persist(job);

  let stablePidCount = 0;
  let lastSeenPid = null;
  let sawOneShotRunning = false;

  while (now() < job.deadlineAt) {
    await pause(Math.min(2000, Math.max(1, job.deadlineAt - now())));
    if (now() >= job.deadlineAt) break;
    info = inspectState(label);
    if (!info.loaded) {
      stablePidCount = 0;
      lastSeenPid = null;
      continue;
    }

    if (meta.activation === "one-shot") {
      if (info.state === "running") { sawOneShotRunning = true; continue; }
      const completed = sawOneShotRunning || (info.runs != null && (oldRuns == null ? info.runs > 0 : info.runs > oldRuns));
      if (!completed) continue;
      if (info.lastExit === "0") {
        C.applyTransition(job, "healthy", now(), "servis başarıyla tamamlandı (exit code 0)");
        persist(job);
        return;
      }
      if (info.lastExit && info.lastExit !== "0") {
        return fail("servis başarısız tamamlandı (exit code: " + info.lastExit + ")");
      }
      continue;
    }

    if (meta.activation === "on-demand") {
      if (meta.ports && meta.ports.length > 0) {
        let allPortsUp = true;
        for (const port of meta.ports) {
          if (!await probePort(port)) { allPortsUp = false; break; }
        }
        if (allPortsUp) {
          C.applyTransition(job, "healthy", now(), "servis hazır ve soket dinliyor");
          persist(job);
          return;
        }
      } else if (info.state === "running" || info.state === "waiting") {
        C.applyTransition(job, "healthy", now(), "on-demand servis hazır");
        persist(job);
        return;
      }
      continue;
    }

    if (info.state !== "running" || info.pid == null || (oldPid != null && info.pid === oldPid)) {
      stablePidCount = 0;
      lastSeenPid = null;
      continue;
    }

    if (info.pid === lastSeenPid) stablePidCount++;
    else { lastSeenPid = info.pid; stablePidCount = 1; }

    let allPortsUp = true;
    for (const port of meta.ports) {
      if (!await probePort(port)) { allPortsUp = false; break; }
    }
    if (!allPortsUp) {
      stablePidCount = 0;
      continue;
    }

    if (stablePidCount >= 2) {
      C.applyTransition(job, "healthy", now(), "servis ayakta ve stabil (PID: " + info.pid + ")");
      persist(job);
      return;
    }
  }

  const msg = "servisin hazır olma süresi aşıldı";
  C.applyTransition(job, "timed_out", now(), msg);
  job.error = msg;
  persist(job);
}

async function runtimeRestartOwned(job, id, dependencies) {
  const execFile = dependencies.execFile || execFileSync;
  const inspectRuntime = dependencies.inspectRuntime || (() => C.inspectOrbStackRuntime(execFile));
  const persist = dependencies.persist || ((record) => C.writeJobAtomic(JOBS_DIR, record));
  const now = dependencies.now || Date.now;
  const pause = dependencies.sleep || sleep;
  const fail = (message) => {
    C.applyTransition(job, "failed", now(), message);
    job.error = message;
    persist(job);
  };

  if (id !== "orbstack") return fail("desteklenmeyen runtime: " + id);
  if (job.approvedAction !== undefined) {
    let inv = inspectRuntime();
    try {
      checkApproval(job, dependencies, C.recoveryAction({ activation: "always-on", running: inv.running }));
      if (!inv.running) {
        await pause(250);
        inv = inspectRuntime();
        checkApproval(job, dependencies, C.recoveryAction({ activation: "always-on", running: inv.running }));
      }
    } catch (err) {
      return fail(err.message);
    }
  }


  const needsStop = job.approvedAction !== "restore";
  if (needsStop) {
    C.applyTransition(job, "stopping", now(), "OrbStack durduruluyor (orbctl stop)…");
    persist(job);

    try {
      execFile(C.BIN_ORBCTL, ["stop"], {
        timeout: Math.min(20000, Math.max(1, job.deadlineAt - now())),
        encoding: "utf8",
      });
    } catch (err) {
      return fail("orbctl stop başarısız: " + String(err.stderr || err.message || "").trim());
    }

    await pause(1500);
  }

  if (now() >= job.deadlineAt) {
    C.applyTransition(job, "timed_out", now(), "OrbStack başlatılamadan deadline aşıldı");
    job.error = job.message;
    persist(job);
    return;
  }

  C.applyTransition(job, "starting", now(), "OrbStack başlatılıyor (orbctl start)…");
  persist(job);

  try {
    // Shared configured directory; mounted data is a hard preflight failure.
    const mountpointPy = [
      path.join(__dirname, "mountpoint.py"),
      path.join(__dirname, "../orbstack-guard/mountpoint.py"),
    ].find((f) => fs.existsSync(f)) || path.join(__dirname, "mountpoint.py");
    execFile("/usr/bin/python3", [mountpointPy, dependencies.lifecycleDataDir || Lifecycle.configuredDataDir()], {
      timeout: Math.min(5000, Math.max(1, job.deadlineAt - now())),
      encoding: "utf8",
    });
    if (now() >= job.deadlineAt) {
      C.applyTransition(job, "timed_out", now(), "OrbStack başlatılmadan deadline aşıldı");
      job.error = job.message;
      persist(job);
      return;
    }
    execFile(C.BIN_ORBCTL, ["start"], {
      timeout: Math.min(20000, Math.max(1, job.deadlineAt - now())),
      encoding: "utf8",
    });
  } catch (err) {
    return fail("orbctl start başarısız: " + String(err.stderr || err.message || "").trim());
  }

  while (now() < job.deadlineAt) {
    await pause(Math.min(2500, Math.max(1, job.deadlineAt - now())));
    if (now() >= job.deadlineAt) break;
    const inv = inspectRuntime();
    if (!inv.running) continue;

    let dockerOk = false;
    try {
      execFile(C.BIN_DOCKER, ["ps", "-q"], { timeout: 4000, encoding: "utf8" });
      dockerOk = true;
    } catch {}

    if (dockerOk) {
      C.applyTransition(job, "healthy", now(), "OrbStack runtime ve Docker motoru hazır");
      persist(job);
      return;
    }
  }

  const msg = "OrbStack hazır olma süresi aşıldı";
  C.applyTransition(job, "timed_out", now(), msg);
  job.error = msg;
  persist(job);
}

async function bulkRestartOwned(job, _id, dependencies) {
  const execFile = dependencies.execFile;
  const now = dependencies.now || Date.now;
  const pause = dependencies.sleep || sleep;
  const persist = dependencies.persist || (record => C.writeJobAtomic(JOBS_DIR, record));
  C.applyTransition(job, "stopping", now(), "tüm çalışan container'lar listeleniyor…");
  persist(job);

  let runningIds = [];
  try {
    const out = execFile(C.BIN_DOCKER, ["ps", "--format", "{{json .}}"], { timeout: 10000, encoding: "utf8" }).trim();
    const inventory = out.split("\n").filter(Boolean).map(line => {
      const item = JSON.parse(line);
      if (!/^[a-f0-9]{12,64}$/.test(item.ID)) throw new Error("invalid Docker container identity");
      return { id: item.ID, name: item.Names, state: "running", status: item.Status };
    });
    runningIds = C.buildDockerTargets(inventory).filter(target => target.actionable && target.running).map(target => target.containerId);
  } catch (err) {
    const msg = "docker ps başarısız: " + (err.message || "");
    C.applyTransition(job, "failed", Date.now(), msg);
    job.error = msg;
    persist(job);
    return;
  }

  if (!runningIds.length) {
    C.applyTransition(job, "healthy", Date.now(), "çalışan container bulunamadı");
    persist(job);
    return;
  }

  try {
    execFile(C.BIN_DOCKER, ["container", "stop", "--time", "10", ...runningIds], {
      timeout: 120000,
      encoding: "utf8",
    });
    dependencies.lifecycleCheck();
    C.applyTransition(job, "starting", now(), "çalışan container kümesi başlatılıyor…");
    persist(job);
    execFile(C.BIN_DOCKER, ["container", "start", ...runningIds], {
      timeout: 120000, encoding: "utf8",
    });
  } catch (err) {
    const msg = "toplu docker restart başarısız: " + (err.message || "");
    C.applyTransition(job, "failed", Date.now(), msg);
    job.error = msg;
    persist(job);
    return;
  }

  C.applyTransition(job, "starting", now(), "tüm container'ların ayağa kalkması bekleniyor…");
  persist(job);

  // Tüm ID'lerin tekrar docker ps çıktısında görünmesi
  while (now() < job.deadlineAt) {
    await pause(Math.min(3000, Math.max(1, job.deadlineAt - now())));
    dependencies.lifecycleCheck();
    try {
      const cur = execFile(C.BIN_DOCKER, ["ps", "-q"], { timeout: 10000, encoding: "utf8" }).trim();
      const curSet = new Set(cur.split(/\s+/).filter(Boolean));
      const allUp = runningIds.every((id) => curSet.has(id));
      if (allUp) {
        C.applyTransition(job, "healthy", Date.now(), `${runningIds.length} container başarıyla yeniden başlatıldı`);
        persist(job);
        return;
      }
    } catch {}
  }

  const msg = "toplu container hazır olma süresi aşıldı";
  C.applyTransition(job, "timed_out", Date.now(), msg);
  job.error = msg;
  persist(job);
}

async function main() {
  const [jobId, targetKey] = process.argv.slice(2);
  if (!C.isValidJobId(jobId)) {
    console.error("geçersiz jobId:", jobId);
    process.exit(1);
  }

  const parsed = C.parseTargetKey(targetKey);
  if (!parsed) {
    console.error("geçersiz targetKey:", targetKey);
    process.exit(1);
  }

  const job = C.readJobAtomic(JOBS_DIR, jobId);
  if (!job) {
    console.error("job bulunamadı:", jobId);
    process.exit(1);
  }

  if (job.targetKey !== targetKey) {
    console.error("targetKey uyuşmazlığı:", job.targetKey, "vs", targetKey);
    process.exit(1);
  }

  if (C.TERMINAL_PHASES.includes(job.phase)) {
    console.log("job zaten tamamlanmış:", job.phase);
    selfRemove(jobId);
    process.exit(0);
  }

  job.workerPid = process.pid;
  job.workerStartedAt = Date.now();
  C.writeJobAtomic(JOBS_DIR, job);

  // Self-restart güvenli gecikmesi: Status API veya Hub yeniden başlatılırken
  // HTTP yanıtının tarayıcıya/istemciye tam iletilmesi için 2.5 saniye bekle
  const isSelf =
    targetKey === "agent:com.homelab.status" ||
    targetKey === "container:homelab-hub" ||
    targetKey === "containers:all" ||
    targetKey === "runtime:orbstack" ||
    targetKey === "daemon:homebrew.mxcl.tailscale";

  if (isSelf) {
    await sleep(2500);
  }

  try {
    const current = C.readJobAtomic(JOBS_DIR, jobId);
    if (!current || C.TERMINAL_PHASES.includes(current.phase)) return;
    const workerDependencies = { beforeOperation() {
      const latest = C.readJobAtomic(JOBS_DIR, jobId);
      if (!latest || C.TERMINAL_PHASES.includes(latest.phase)) {
        const error = new Error("job no longer active"); error.obsolete = true; throw error;
      }
    } };
    if (parsed.kind === "container") {
      await runContainerRestart(job, parsed.id, workerDependencies);
    } else if (parsed.kind === "agent") {
      await runAgentRestart(job, parsed.id, workerDependencies);
    } else if (parsed.kind === "daemon") {
      await runDaemonRestart(job, parsed.id, workerDependencies);
    } else if (parsed.kind === "runtime") {
      await runRuntimeRestart(job, parsed.id, workerDependencies);
    } else if (parsed.kind === "bulk") {
      await runBulkRestart(job, workerDependencies);
    }
  } catch (fatal) {
    const msg = "beklenmeyen hata: " + (fatal.stack || fatal.message || fatal);
    C.applyTransition(job, "failed", Date.now(), msg);
    job.error = msg;
    try { C.writeJobAtomic(JOBS_DIR, job); } catch {}
  } finally {
    selfRemove(jobId);
  }
}

if (require.main === module) {
  main().then(
    () => process.exit(0),
    (err) => {
      console.error("worker ölümcül hata:", err);
      process.exit(1);
    }
  );
}

module.exports = {
  portOpen,
  runContainerRestart,
  runAgentRestart,
  runBulkRestart,
  runDaemonRestart,
  runRuntimeRestart,
};
