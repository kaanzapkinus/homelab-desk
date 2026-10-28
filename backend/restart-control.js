// restart-control.js — Homelab Hub restart/recovery modeli ve güvenli envanteri.
// Katalog, doğrulama, atomik job store ve state geçişleri.
"use strict";

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");
let rawCatalog = { services: [] };
const defaultCatalogPath = path.join(__dirname, "service-catalog.json");
const exampleCatalogPath = path.join(__dirname, "service-catalog.example.json");
try {
  if (fs.existsSync(defaultCatalogPath)) {
    rawCatalog = JSON.parse(fs.readFileSync(defaultCatalogPath, "utf8"));
  } else if (fs.existsSync(exampleCatalogPath)) {
    rawCatalog = JSON.parse(fs.readFileSync(exampleCatalogPath, "utf8"));
  }
} catch {}
const SERVICE_CATALOG = new Map((rawCatalog.services || []).map((service) => [service.id, service]));

function serviceMetadata(key, fallback) {
  const service = SERVICE_CATALOG.get(key);
  if (!service) return fallback;
  return {
    ...fallback,
    display: service.name,
    activation: service.activation,
    ports: [...new Set((service.endpoints || []).map((endpoint) => endpoint.port))],
  };
}

// ===== Sabitler =====
const CONTROL_HEADER = "x-homelab-control";
const CONTROL_VALUE = "restart-v1";
const MAX_BODY_BYTES = 8192;
const RESTART_CONFIRM = "RESTART";
const BULK_CONFIRM = "RESTART";
const DEFAULT_DEADLINE_MS = 120000;

// LaunchAgent allowlist — SADECE homelab'a ait uzun ömürlü servisler.
// Planlı işler (backup, ompweb-daily), Google/AltTab ve root LaunchDaemon'ları bilinçli dışarıda.
const LAUNCH_AGENT_ALLOWLIST = {
  "ai.openclaw.gateway": { display: "OpenClaw Gateway", ports: [18789] },
  "com.homelab.backup": {
    display: "Homelab Yedek",
    ports: [],
    activation: "scheduled",
    actionLabel: "Şimdi Çalıştır",
    warning: "Günlük yedekleme betiği hemen çalıştırılır.",
  },
  "com.homelab.agyauth": { display: "Google Hesapları", ports: [8098] },
  "com.homelab.agy-scheduler": { display: "Google Kota Zamanlayıcısı", ports: [] },
  "com.homelab.avci-bridge": { display: "avci Bridge", ports: [18790] },
  "com.homelab.media-gateway": { display: "Media Gateway", ports: [3005] },
  "com.homelab.ompweb": { display: "OMP Web", ports: [30177] },
  "com.homelab.ompweb-daily": {
    display: "OMP Günlük Bakım",
    ports: [],
    activation: "scheduled",
    actionLabel: "Şimdi Çalıştır",
    warning: null,
  },
  "com.homelab.openclaw-omp-worker": { display: "OpenClaw OMP Worker", ports: [] },
  "com.homelab.orbguard": { display: "OrbStack Bekçisi", ports: [] },
  "com.homelab.persona": { display: "Persona", ports: [8092] },
  "com.homelab.persona-runner": { display: "Persona Runner", ports: [8100] },
  "com.homelab.status": { display: "Status API", ports: [8091] },
  "com.homelab.ttyd": { display: "Terminal (ttyd)", ports: [7681] },
  "com.homelab.webstream": { display: "WebStream", ports: [8097] },
};

// Katalogda görünür, ancak asla başlatılmaz/restart edilmez.
const NON_ACTIONABLE_AGENTS = {
  "com.homelab.novnc": { display: "noVNC (emekli)", ports: [6080], activation: "retired", reason: "emekli servis; geri yüklenmez" },
  "com.homelab.tg-omp-bot": { display: "Telegram OMP Bot (emekli)", ports: [], activation: "retired", reason: "OpenClaw Telegram devraldı; legacy Python poller disabled — yeniden açılırsa çift poller olur" },
};
const AGENT_CATALOGUE = { ...LAUNCH_AGENT_ALLOWLIST, ...NON_ACTIONABLE_AGENTS };
const LAUNCH_AGENTS_DIR = process.env.HOMELAB_LAUNCH_AGENTS_DIR || path.join(os.homedir(), "Library/LaunchAgents");
const AGENT_UID = typeof process.getuid === "function" ? process.getuid() : 501;
const AGENT_DOMAIN = "gui/" + AGENT_UID;

const SYSTEM_DAEMON_ALLOWLIST = {
  "com.ollama.server": {
    display: "Ollama",
    ports: [11434],
    plistPath: "/Library/LaunchDaemons/com.ollama.server.plist",
    activation: "always-on",
    domain: "system",
    warning: null,
    allowRecovery: true,
  },
  "homebrew.mxcl.tailscale": {
    display: "Tailscale",
    ports: [],
    plistPath: "/Library/LaunchDaemons/homebrew.mxcl.tailscale.plist",
    activation: "always-on",
    domain: "system",
    warning: "Tailscale yeniden başlatılırken Hub bağlantısı kısa süre kesilebilir.",
    allowRecovery: true,
  },
  "com.homelab.pf": {
    display: "Packet Filter (pf)",
    ports: [],
    plistPath: "/Library/LaunchDaemons/com.homelab.pf.plist",
    activation: "one-shot",
    domain: "system",
    warning: null,
    allowRecovery: true,
  },
  "com.apple.screensharing": {
    display: "VNC / Ekran Paylaşımı",
    ports: [5900],
    plistPath: "/System/Library/LaunchDaemons/com.apple.screensharing.plist",
    activation: "on-demand",
    domain: "system",
    warning: null,
    allowRecovery: false,
    reasonIfAbsent: "sistem ekran paylaşımı servisi; launchd dışından bootstrap edilmez",
  },
};

const RUNTIME_ALLOWLIST = {
  "orbstack": {
    display: "OrbStack Runtime",
    ports: [],
    activation: "always-on",
    domain: "host",
    warning: "OrbStack yeniden başlatılırken Hub ve tüm container'lar geçici olarak durur.",
  },
};

// Servis kartı → primary hedef eşlemesi (UI için; katalog doğrulaması runtime envanteriyle)
const SERVICE_TARGET_HINTS = {
  "OMP Web": "agent:com.homelab.ompweb",
  "TorBox Manager": "agent:com.homelab.media-gateway",
  "avci": "container:avci",
  "Drive": "container:filebrowser",
  "Beam": "container:beam",
  "Terminal": "agent:com.homelab.ttyd",
  "Persona": "agent:com.homelab.persona",
  "OpenGym": "container:opengym-web",
  "Google Hesapları": "agent:com.homelab.agyauth",
  "Bifrost": "container:bifrost",
  "Prowlarr": "container:prowlarr",
  "Gatus": "container:gatus",
  "Ntfy": "container:ntfy",
  "Dozzle": "container:dozzle",
  "Cloud (SMB)": "container:cloud-samba",
  "Ollama": "daemon:com.ollama.server",
  "Tailscale": "daemon:homebrew.mxcl.tailscale",
  "OrbStack": "runtime:orbstack",
  "VNC": "daemon:com.apple.screensharing",
};

// ===== Komut sözleşmesi — asla shell stringi değil, executable + argv =====
const BIN_DOCKER = [path.join(os.homedir(), ".orbstack/bin/docker"), "/usr/local/bin/docker", "/opt/homebrew/bin/docker"].find((p) => fs.existsSync(p)) || "/usr/local/bin/docker";
const BIN_NODE = process.execPath || "/opt/homebrew/bin/node";
const BIN_LAUNCHCTL = "/bin/launchctl";
const BIN_SUDO = "/usr/bin/sudo";
const BIN_ORBCTL = [path.join(os.homedir(), ".orbstack/bin/orbctl"), "/usr/local/bin/orbctl", "/opt/homebrew/bin/orbctl"].find((p) => fs.existsSync(p)) || "/usr/local/bin/orbctl";


// Loaded servis hiçbir zaman deregister edilmez.
function buildKickstartArgs(label, domain = AGENT_DOMAIN) {
  if (domain === "system") {
    return [BIN_SUDO, "-n", BIN_LAUNCHCTL, "kickstart", "-k", "system/" + label];
  }
  return [BIN_LAUNCHCTL, "kickstart", "-k", AGENT_DOMAIN + "/" + label];
}

function buildBootstrapArgs(plistPath, domain = AGENT_DOMAIN) {
  if (domain === "system") {
    return [BIN_SUDO, "-n", BIN_LAUNCHCTL, "bootstrap", "system", plistPath];
  }
  return [BIN_LAUNCHCTL, "bootstrap", AGENT_DOMAIN, plistPath];
}


function agentPlistPath(label) {
  if (!Object.hasOwn(AGENT_CATALOGUE, label)) throw new Error("allowlist dışı agent");
  return path.join(LAUNCH_AGENTS_DIR, label + ".plist");
}

function sameFile(a, b) {
  return a.dev === b.dev && a.ino === b.ino && a.size === b.size &&
    a.mtimeMs === b.mtimeMs && a.ctimeMs === b.ctimeMs;
}

// launchctl'e yalnız sabit dizindeki, kullanıcıya ait ve değiştirilmemiş plist gider.
function inspectAgentPlist(label, { fsImpl = fs, execFile = execFileSync } = {}) {
  const plistPath = agentPlistPath(label);
  let fd;
  let installed = false;
  try {
    const entry = fsImpl.lstatSync(plistPath);
    installed = true;
    if (!entry.isFile() || entry.isSymbolicLink()) throw new Error("plist normal dosya değil veya symlink");
    if (entry.uid !== AGENT_UID || (entry.mode & 0o022)) throw new Error("plist sahipliği/izinleri güvenli değil");
    for (const dir of [os.homedir(), path.join(os.homedir(), "Library"), LAUNCH_AGENTS_DIR]) {
      const stat = fsImpl.lstatSync(dir);
      if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== AGENT_UID || (stat.mode & 0o022)) {
        throw new Error("plist üst dizini güvenli değil");
      }
    }
    if (fsImpl.realpathSync(plistPath) !== plistPath) throw new Error("plist canonical yol uyuşmazlığı");
    fd = fsImpl.openSync(plistPath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const before = fsImpl.fstatSync(fd);
    if (!sameFile(entry, before) || before.size > 65536) throw new Error("plist kimliği/boyutu geçersiz");
    const contents = fsImpl.readFileSync(fd);
    const after = fsImpl.fstatSync(fd);
    if (!sameFile(before, after) || !sameFile(after, fsImpl.lstatSync(plistPath))) throw new Error("plist okuma sırasında değişti");
    const plist = JSON.parse(execFile("/usr/bin/plutil", ["-convert", "json", "-o", "-", "-"], {
      input: contents, timeout: 3000, encoding: "utf8", maxBuffer: 131072,
    }));
    if (!plist || plist.Label !== label) throw new Error("plist Label uyuşmazlığı");
    const meta = AGENT_CATALOGUE[label] || {};
    const isScheduled = meta.activation === "scheduled";
    if (plist.Disabled === true) throw new Error("plist devre dışı bırakılmış");
    if (isScheduled) {
      if (plist.StartInterval == null && plist.StartCalendarInterval == null) {
        throw new Error("planlı iş StartInterval veya StartCalendarInterval içermeli");
      }
    } else {
      if (plist.StartInterval != null || plist.StartCalendarInterval != null || plist.StartOnMount ||
          plist.WatchPaths != null || plist.QueueDirectories != null || plist.Sockets != null ||
          plist.MachServices != null || plist.LaunchEvents != null ||
          plist.RunAtLoad !== true || plist.KeepAlive !== true) {
        throw new Error("plist uzun ömürlü otomatik servis değil (planlı/on-demand)");
      }
    }
    const executable = plist.Program || (Array.isArray(plist.ProgramArguments) && plist.ProgramArguments[0]);
    if (typeof executable !== "string" || !path.isAbsolute(executable)) throw new Error("plist executable yolu geçersiz");
    return { installed, valid: true, reason: null, plistPath, identity: after };
  } catch (err) {
    return { installed, valid: false, reason: !installed && err.code === "ENOENT" ? "kurulu plist yok" : String(err.message || err), plistPath };
  } finally {
    if (fd != null) fsImpl.closeSync(fd);
  }
}

function inspectAgentState(label, execFile = execFileSync) {
  try {
    const text = execFile(BIN_LAUNCHCTL, ["print", AGENT_DOMAIN + "/" + label], {
      timeout: 3000, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
    });
    const info = parseLaunchctlPrint(text);
    if (!info.loaded) throw new Error("launchctl print çıktısı tanınmadı");
    return { ...info, absent: false, inspectionError: null };
  } catch (err) {
    // Diğer launchctl hataları (izin, timeout, domain kaybı) yokluk kanıtı değildir.
    const errText = [err.stderr, err.stdout, err.message].filter(Boolean).map(String).join("\n");
    const missing = (err.status === 113 || err.code === 113) &&
      errText.includes('Could not find service "' + label + '" in domain for user gui: ' + AGENT_UID);
    return { loaded: false, state: null, pid: null, absent: missing,
      inspectionError: missing ? null : "launchd durumu doğrulanamadı: " + String(err.stderr || err.stdout || err.message || "").trim() };
  }
}

function collectAgentInventory() {
  const inv = {};
  for (const label of Object.keys(AGENT_CATALOGUE)) {
    inv[label] = { ...inspectAgentState(label), ...inspectAgentPlist(label) };
  }
  return inv;
}

function inspectSystemPlist(label, { fsImpl = fs, execFile = execFileSync } = {}) {
  const meta = Object.hasOwn(SYSTEM_DAEMON_ALLOWLIST, label) && SYSTEM_DAEMON_ALLOWLIST[label];
  if (!meta) throw new Error("allowlist dışı sistem daemoni");
  const plistPath = meta.plistPath;
  let fd;
  let installed = false;
  try {
    const entry = fsImpl.lstatSync(plistPath);
    installed = true;
    if (!entry.isFile() || entry.isSymbolicLink()) throw new Error("plist normal dosya değil veya symlink");
    if (entry.uid !== 0 || (entry.mode & 0o022)) throw new Error("plist sahipliği/izinleri güvenli değil (root 0 olmalı ve world/group writable olmamalı)");
    if (fsImpl.realpathSync(plistPath) !== plistPath) throw new Error("plist canonical yol uyuşmazlığı");
    fd = fsImpl.openSync(plistPath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const before = fsImpl.fstatSync(fd);
    if (!sameFile(entry, before) || before.size > 65536) throw new Error("plist kimliği/boyutu geçersiz");
    const contents = fsImpl.readFileSync(fd);
    const after = fsImpl.fstatSync(fd);
    if (!sameFile(before, after) || !sameFile(after, fsImpl.lstatSync(plistPath))) throw new Error("plist okuma sırasında değişti");
    const plist = JSON.parse(execFile("/usr/bin/plutil", ["-convert", "json", "-o", "-", "-"], {
      input: contents, timeout: 3000, encoding: "utf8", maxBuffer: 131072,
    }));
    if (!plist || plist.Label !== label) throw new Error("plist Label uyuşmazlığı");
    return { installed, valid: true, reason: null, plistPath, identity: after };
  } catch (err) {
    return { installed, valid: false, reason: !installed && err.code === "ENOENT" ? "kurulu plist yok" : String(err.message || err), plistPath };
  } finally {
    if (fd != null) fsImpl.closeSync(fd);
  }
}

function inspectSystemState(label, execFile = execFileSync) {
  try {
    const text = execFile(BIN_LAUNCHCTL, ["print", "system/" + label], {
      timeout: 3000, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
    });
    const info = parseLaunchctlPrint(text);
    if (!info.loaded) throw new Error("launchctl print çıktısı tanınmadı");
    return { ...info, absent: false, inspectionError: null };
  } catch (err) {
    const missing = err.status === 113 &&
      String(err.stderr || "").includes('Could not find service "' + label + '" in domain for system');
    return {
      loaded: false,
      state: null,
      pid: null,
      lastExit: null,
      absent: missing,
      inspectionError: missing ? null : "launchd durumu doğrulanamadı: " + String(err.stderr || err.message || "").trim(),
    };
  }
}

function collectDaemonInventory() {
  const inv = {};
  for (const label of Object.keys(SYSTEM_DAEMON_ALLOWLIST)) {
    inv[label] = { ...inspectSystemState(label), ...inspectSystemPlist(label) };
  }
  return inv;
}

function inspectOrbStackRuntime(execFile = execFileSync) {
  try {
    const statusText = execFile(BIN_ORBCTL, ["status"], {
      timeout: 3000, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
    }).trim();
    const running = statusText.toLowerCase() === "running";
    return {
      installed: true,
      loaded: true,
      running,
      state: statusText.toLowerCase(),
      statusText,
      inspectionError: null,
    };
  } catch (err) {
    return {
      installed: true,
      loaded: false,
      running: false,
      state: "stopped",
      statusText: "durduruldu",
      inspectionError: "orbctl ulaşılamadı: " + String(err.stderr || err.message || "").trim(),
    };
  }
}
// Transient launchd worker submit — bağımsız job (status API ölse de yaşar)
function buildSubmitArgs({ label, workerPath, jobId, targetKey }) {
  return [
    BIN_LAUNCHCTL, "submit", "-l", label,
    "--", BIN_NODE, workerPath, jobId, targetKey,
  ];
}

function workerLabel(jobId) {
  return "com.homelab.restart-" + jobId.slice(0, 12);
}

// ===== Biçim doğrulayıcılar =====
const LABEL_RE = /^[a-zA-Z0-9][a-zA-Z0-9.\-]{2,63}$/;
const CONTAINER_NAME_RE = /^[a-zA-Z0-9][a-zA-Z0-9_.\-]{0,63}$/;
const JOB_ID_RE = /^[a-f0-9]{32}$/;
const TARGET_RE = /^(container|agent|daemon|runtime):([A-Za-z0-9][A-Za-z0-9_.\-]{1,63})$/;

function isValidJobId(id) {
  return typeof id === "string" && JOB_ID_RE.test(id);
}

function parseTargetKey(raw) {
  if (typeof raw !== "string") return null;
  if (raw === "containers:all") return { kind: "bulk", id: "all" };
  const m = TARGET_RE.exec(raw);
  if (!m) return null;
  const kind = m[1];
  const id = m[2];
  if (kind === "container" && !CONTAINER_NAME_RE.test(id)) return null;
  if (kind === "agent" && !LABEL_RE.test(id)) return null;
  if (kind === "agent" && !Object.hasOwn(LAUNCH_AGENT_ALLOWLIST, id)) return null;
  if (kind === "daemon" && !Object.hasOwn(SYSTEM_DAEMON_ALLOWLIST, id)) return null;
  if (kind === "runtime" && !Object.hasOwn(RUNTIME_ALLOWLIST, id)) return null;
  return { kind, id };
}

// ===== Hedef kataloğu =====
// dockerEnvanter: [{ id, name, state, status }]  (docker ps -a çıktısı; id 12 haneli kısa form)
function buildDockerTargets(dockerInventory) {
  const out = [];
  for (const c of dockerInventory) {
    if (!c || typeof c.name !== "string" || !CONTAINER_NAME_RE.test(c.name)) continue;
    const service = SERVICE_CATALOG.get("container:" + c.name);
    const excluded = service && ["retired", "disabled"].includes(service.activation);
    out.push({
      key: "container:" + c.name,
      kind: "container",
      id: c.name,
      containerId: c.id || null,
      display: service ? service.name : c.name,
      installed: true,
      actionable: !excluded,
      restartable: !excluded,
      recoverable: !excluded && c.state !== "running",
      activation: service ? service.activation : "unknown",
      reason: excluded ? "emekli veya devre dışı servis; geri yüklenmez" : null,
      ports: Array.isArray(c.ports) ? c.ports : [],
      running: c.state === "running",
      healthy: c.state === "running" && !(typeof c.status === "string" && c.status.includes("unhealthy")),
      statusText: c.status || c.state || "",
    });
  }
  return out;
}

// launchctl print gui/501/<label> çıktısını parse et (state = ..., pid = ...)
function parseLaunchctlPrint(text) {
  const res = { loaded: false, state: null, pid: null, lastExit: null, runs: null };
  if (typeof text !== "string" || !text.trim()) return res;
  if (!/path = \/.+\.plist/.test(text) && !/state = /.test(text)) return res;
  res.loaded = true;
  const st = text.match(/^\tstate = (.+)$/m);
  if (st) res.state = st[1];
  const pid = text.match(/^\tpid = (\d+)/m);
  if (pid) res.pid = Number(pid[1]);
  const exit = text.match(/^\tlast exit code = (.+)$/m);
  if (exit) res.lastExit = exit[1];
  const runs = text.match(/^\truns = (\d+)$/m);
  if (runs) res.runs = Number(runs[1]);
  return res;
}

// launchAgentsEnvanter: { [label]: { loaded, state, pid } }
function buildAgentTargets(agentInventory) {
  const out = [];
  for (const [label, allowedMeta] of Object.entries(AGENT_CATALOGUE)) {
    const meta = serviceMetadata("agent:" + label, allowedMeta);
    const inv = agentInventory[label] || { loaded: false, state: null, pid: null, installed: false, valid: false, absent: false };
    const allowed = Object.hasOwn(LAUNCH_AGENT_ALLOWLIST, label);
    const alreadyRunning = meta.activation === "scheduled" && inv.state === "running";
    const actionable = allowed && !alreadyRunning && inv.valid === true && !inv.inspectionError && (inv.loaded || inv.absent === true);
    const reason = !allowed ? meta.reason : alreadyRunning ? "planlı iş zaten çalışıyor; tekrar başlatılmaz" : inv.inspectionError || (!inv.valid ? inv.reason || "kurulu plist doğrulanamadı" : !actionable ? "launchd durumu doğrulanamadı" : null);
    out.push({
      key: "agent:" + label,
      kind: "agent",
      domain: "gui/" + AGENT_UID,
      id: label,
      display: meta.display,
      installed: !!inv.installed,
      actionable,
      restartable: actionable && !!inv.loaded,
      recoverable: actionable && !inv.loaded,
      activation: meta.activation || "always-on",
      actionLabel: meta.actionLabel || (inv.loaded ? "Yeniden Başlat" : "Geri Yükle"),
      warning: meta.warning || null,
      reason,
      inspectionError: inv.inspectionError || null,
      loaded: !!inv.loaded,
      state: inv.state || null,
      pid: inv.pid || null,
      lastExit: inv.lastExit || null,
      running: !!inv.loaded && inv.state === "running",
      ports: meta.ports,
      statusText: inv.loaded
        ? (meta.activation === "scheduled" ? (inv.state === "running" ? "çalışıyor" : "planlı / beklemede") : (inv.state || "loaded"))
        : (inv.installed ? "kurulu, launchd'ye yüklü değil" : "kurulu değil"),
    });
  }
  return out;
}

function buildDaemonTargets(daemonInventory) {
  const out = [];
  for (const [label, allowedMeta] of Object.entries(SYSTEM_DAEMON_ALLOWLIST)) {
    const meta = serviceMetadata("daemon:" + label, allowedMeta);
    const inv = daemonInventory[label] || { loaded: false, state: null, pid: null, installed: false, valid: false, absent: false };
    const actionable = inv.valid === true && !inv.inspectionError && (inv.loaded || (inv.absent === true && meta.allowRecovery === true));
    const reason = inv.inspectionError || (!inv.valid ? inv.reason || "kurulu plist doğrulanamadı" : (!inv.loaded && meta.allowRecovery === false ? meta.reasonIfAbsent || "bu sistem servisi otomatik bootstrap edilemez" : !actionable ? "launchd durumu doğrulanamadı" : null));
    const isRunning = meta.activation === "one-shot"
      ? (inv.loaded && inv.lastExit === "0")
      : (inv.loaded && inv.state === "running");
    const statusText = inv.loaded
      ? (meta.activation === "one-shot" ? (inv.lastExit === "0" ? "tamamlandı (exit 0)" : (inv.state || "loaded")) : (inv.state || "loaded"))
      : (inv.installed ? "kurulu, launchd'ye yüklü değil" : "kurulu değil");
    out.push({
      key: "daemon:" + label,
      kind: "daemon",
      domain: meta.domain || "system",
      id: label,
      display: meta.display,
      installed: !!inv.installed,
      actionable,
      restartable: actionable && !!inv.loaded,
      recoverable: actionable && !inv.loaded,
      activation: meta.activation || "always-on",
      warning: meta.warning || null,
      reason,
      inspectionError: inv.inspectionError || null,
      loaded: !!inv.loaded,
      state: inv.state || null,
      pid: inv.pid || null,
      lastExit: inv.lastExit || null,
      running: !!isRunning,
      ports: meta.ports,
      statusText,
    });
  }
  return out;
}

function buildRuntimeTargets(runtimeInventory) {
  const out = [];
  for (const [id, allowedMeta] of Object.entries(RUNTIME_ALLOWLIST)) {
    const meta = serviceMetadata("runtime:" + id, allowedMeta);
    const inv = (runtimeInventory && runtimeInventory[id]) || runtimeInventory || { running: false, loaded: false, installed: false, state: null, statusText: null, inspectionError: null };
    const actionable = !inv.inspectionError && !!inv.installed;
    out.push({
      key: "runtime:" + id,
      kind: "runtime",
      domain: meta.domain || "host",
      id,
      display: meta.display,
      installed: !!inv.installed,
      actionable,
      restartable: actionable,
      recoverable: actionable && !inv.running,
      activation: meta.activation || "always-on",
      warning: meta.warning || null,
      reason: inv.inspectionError || null,
      inspectionError: inv.inspectionError || null,
      loaded: !!inv.loaded,
      state: inv.state || (inv.running ? "running" : "stopped"),
      pid: null,
      running: !!inv.running,
      ports: meta.ports || [],
      statusText: inv.statusText || (inv.running ? "Running" : "Stopped"),
    });
  }
  return out;
}

function findTarget(targets, rawKey) {
  const t = parseTargetKey(rawKey);
  if (!t) return null;
  return targets.find((x) => x.kind === t.kind && x.id === t.id) || null;
}

// ===== Doğrulama: mutation guard =====
// origin: istek Origin header'ı (yoksa null); loopback: isteğin loopback'ten gelip geldiği
const TRUSTED_ORIGINS = [
  "http://127.0.0.1:8000",
  "http://localhost:8000",
];

function guardMutation({ origin, remoteAddress, controlHeader, contentType, bodyBytes }) {
  const isLoopback = typeof remoteAddress === "string" &&
    (remoteAddress === "127.0.0.1" || remoteAddress === "::1" || remoteAddress === "::ffff:127.0.0.1");
  const originOk = origin == null ? isLoopback : TRUSTED_ORIGINS.includes(origin);
  if (!originOk) return { ok: false, code: 403, error: "güvenilmeyen origin" };
  if (controlHeader !== CONTROL_VALUE) return { ok: false, code: 403, error: "control header eksik/hatalı" };
  if (contentType == null || !/^application\/json/i.test(contentType)) {
    return { ok: false, code: 415, error: "content-type application/json olmalı" };
  }
  if (bodyBytes > MAX_BODY_BYTES) return { ok: false, code: 413, error: "body çok büyük" };
  return { ok: true };
}

// Body parse + confirm kontrolü
function parseMutationBody(raw) {
  if (raw == null || raw.length > MAX_BODY_BYTES) return { ok: false, code: 413, error: "body çok büyük" };
  let j;
  try { j = JSON.parse(raw.toString("utf8")); } catch { return { ok: false, code: 400, error: "bozuk JSON" }; }
  if (typeof j !== "object" || j === null || Array.isArray(j)) return { ok: false, code: 400, error: "bozuk JSON" };
  return { ok: true, body: j };
}

function requireConfirm(body, expected) {
  if (typeof body !== "object" || body === null || body.confirm !== expected) {
    return { ok: false, code: 400, error: "confirm gerekli: " + expected };
  }
  return { ok: true };
}

// ===== Job store (atomik JSON dosyaları) =====
// root: /tmp/homelab-restart-jobs — worker ve server paylaşımlı.
// Tüm yazma işlemleri write-to-temp + rename (atomik). BİR aktif iş kuralı store seviyesinde.
const PHASES = ["queued", "stopping", "starting", "healthy", "failed", "timed_out"];
const TERMINAL_PHASES = ["healthy", "failed", "timed_out"];

function activeJobOf(list, targetKey) {
  if (!Array.isArray(list)) return null;
  return list.find((j) => j && j.targetKey === targetKey && !TERMINAL_PHASES.includes(j.phase)) || null;
}

function anyActiveJob(list) {
  if (!Array.isArray(list)) return null;
  return list.find((j) => j && !TERMINAL_PHASES.includes(j.phase)) || null;
}

function transitionAllowed(from, to) {
  if (!PHASES.includes(from) || !PHASES.includes(to)) return false;
  if (TERMINAL_PHASES.includes(from)) return false; // terminal durumdan çıkış yok
  if (from === to) return false;
  return true;
}

function deadlineForTarget(targetKey) {
  if (targetKey === "agent:com.homelab.backup") return 600000;
  if (targetKey === "containers:all" || targetKey === "runtime:orbstack") return 180000;
  return DEFAULT_DEADLINE_MS;
}

function recoveryAction(target) {
  return target.activation === "scheduled" ? "run_now" : target.running ? "restart" : "restore";
}

// No approval fields means the existing HTTP endpoint's explicitly confirmed restart.
// Native approvals always bind an effect and an absolute expiry together.
function approvalError(job, now) {
  if (job.approvedAction === undefined && job.approvalExpiresAt === undefined) return null;
  if (!["restart", "restore", "run_now"].includes(job.approvedAction) ||
      !Number.isFinite(job.approvalExpiresAt)) return "invalid recovery approval";
  if (now >= job.approvalExpiresAt) return "recovery approval expired";
  return null;
}

function newJobRecord({ id, targetKey, kind, name, now, approvedAction, approvalExpiresAt }) {
  return {
    id,
    targetKey,
    kind,
    name,
    ...(approvedAction !== undefined || approvalExpiresAt !== undefined
      ? { approvedAction, approvalExpiresAt } : {}),
    phase: "queued",
    history: [{ phase: "queued", at: now }],
    requestedAt: now,
    updatedAt: now,
    deadlineAt: now + deadlineForTarget(targetKey),
    workerPid: null,
    workerStartedAt: null,
    message: "restart kuyruğa alındı",
    error: null,
  };
}

function applyTransition(job, phase, now, message) {
  if (!job || !transitionAllowed(job.phase, phase)) return false;
  job.phase = phase;
  job.history.push({ phase, at: now });
  job.updatedAt = now;
  if (message != null) job.message = message;
  return true;
}

function jobFilePath(root, id) {
  return path.join(root, id + ".json");
}

function writeJobAtomic(root, job) {
  fs.mkdirSync(root, { recursive: true, mode: 0o700 });
  const fp = jobFilePath(root, job.id);
  const tmp = fp + ".tmp-" + crypto.randomBytes(4).toString("hex");
  const fd = fs.openSync(tmp, "wx", 0o600);
  try {
    fs.writeSync(fd, JSON.stringify(job, null, 1));
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(tmp, fp);
  return fp;
}

function readJobAtomic(root, id) {
  if (!isValidJobId(id)) return null;
  try {
    return JSON.parse(fs.readFileSync(jobFilePath(root, id), "utf8"));
  } catch {
    return null;
  }
}

function listJobs(root) {
  let entries = [];
  try { entries = fs.readdirSync(root); } catch { return []; }
  const jobs = [];
  for (const e of entries) {
    if (!e.endsWith(".json")) continue;
    const id = e.slice(0, -5);
    const j = readJobAtomic(root, id);
    if (j && isValidJobId(id)) jobs.push(j);
  }
  return jobs;
}

function inspectRestartWorker(job, execFile = execFileSync) {
  const label = workerLabel(job.id);
  try {
    const text = execFile(BIN_LAUNCHCTL, ["print", AGENT_DOMAIN + "/" + label], {
      timeout: 2000, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
    });
    const state = parseLaunchctlPrint(text);
    return { alive: state.loaded ? Number.isInteger(state.pid) && state.pid > 0 : null };
  } catch (err) {
    if (err.status === 113 && String(err.stderr || "").includes('Could not find service "' + label + '"')) {
      return { alive: false };
    }
    // An inspection timeout or permission failure does not prove an owner dead.
    return { alive: null };
  }
}

function reconcileJobs(root, now, { inspectWorker = inspectRestartWorker, queueGraceMs = 15000 } = {}) {
  for (const job of listJobs(root)) {
    if (TERMINAL_PHASES.includes(job.phase) || now - job.requestedAt < queueGraceMs) continue;
    const owner = inspectWorker(job);
    if (owner.alive !== false) continue;
    const expired = !Number.isFinite(job.deadlineAt) || now >= job.deadlineAt;
    const message = expired
      ? "restart deadline aşıldı; çalışan worker yok"
      : "restart worker sonlanmış; işlem operatör tarafından yeniden istenmeli";
    applyTransition(job, expired ? "timed_out" : "failed", now, message);
    job.error = message;
    writeJobAtomic(root, job);
  }
}

function cleanupTerminalJobs(root, now, maxAgeMs, options = {}) {
  reconcileJobs(root, now, options);
  for (const j of listJobs(root)) {
    if (TERMINAL_PHASES.includes(j.phase) && now - j.updatedAt > maxAgeMs) {
      try { fs.unlinkSync(jobFilePath(root, j.id)); } catch {}
    }
  }
}

function makeJobId() {
  return crypto.randomBytes(16).toString("hex");
}

module.exports = {
  CONTROL_HEADER, CONTROL_VALUE, MAX_BODY_BYTES, RESTART_CONFIRM, BULK_CONFIRM, DEFAULT_DEADLINE_MS,
  LAUNCH_AGENT_ALLOWLIST, SERVICE_TARGET_HINTS, TRUSTED_ORIGINS,
  LABEL_RE, CONTAINER_NAME_RE, JOB_ID_RE, TARGET_RE,
  isValidJobId, parseTargetKey, buildDockerTargets, parseLaunchctlPrint, buildAgentTargets, findTarget,
  guardMutation, parseMutationBody, requireConfirm,
  PHASES, TERMINAL_PHASES, activeJobOf, anyActiveJob, transitionAllowed, newJobRecord, applyTransition,
  jobFilePath, writeJobAtomic, readJobAtomic, listJobs, cleanupTerminalJobs, makeJobId,
  BIN_DOCKER, BIN_NODE, BIN_LAUNCHCTL, buildKickstartArgs, buildSubmitArgs, workerLabel,
  AGENT_CATALOGUE, NON_ACTIONABLE_AGENTS, LAUNCH_AGENTS_DIR, AGENT_UID, AGENT_DOMAIN,
  SYSTEM_DAEMON_ALLOWLIST, RUNTIME_ALLOWLIST, BIN_SUDO, BIN_ORBCTL,
  inspectSystemPlist, inspectSystemState, collectDaemonInventory, inspectOrbStackRuntime,
  buildDaemonTargets, buildRuntimeTargets, buildBootstrapArgs,
  agentPlistPath, inspectAgentPlist, inspectAgentState, collectAgentInventory, sameFile,
  deadlineForTarget, inspectRestartWorker, reconcileJobs,
  recoveryAction, approvalError,
};
