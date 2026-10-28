# Homelab Desk

Native macOS system monitor, isolated AI recovery assistant, and WidgetKit extension for Apple Silicon Mac servers.

Works completely independently of external HTTP APIs or web runtimes — directly reading Mach kernel metrics and launchd service states.

---

## Features

- **Direct Kernel Metrics**: Real-time CPU, RAM, compressed memory, swap, disk, and connectivity via Mach primitives (`host_statistics64`, `vm_statistics64`), sysctl, and `Network.framework`.
- **Isolated AI Assistant**: Runs local OMP in isolated RPC mode (`--mode rpc-ui`) with no tools/extensions enabled. Dynamic model selection (e.g. `openai-codex/gpt-6.1-sol`, `anthropic/claude-3.7-sonnet`).
- **Strict Security Boundary**: The model only has access to read-only diagnostics and recovery proposals. It cannot execute shell commands or restart services.
- **Native User Approval**: 60-second single-use local confirmation cards with action/effect binding and atomic file locks.
- **Tri-Modal Layout**:
  - **Desktop**: Pinned directly above wallpaper icons behind active apps.
  - **Focus**: Standard window level with native keyboard/paste focus.
  - **Remote / Phone**: 450pt single-column touch interface for remote desktop control.
- **WidgetKit Extension**: 5 widgets (Overview, Memory, Storage, Network, Services) with deep links into the app.

---

## Build & Install

Requires macOS 14.0+ and Xcode Command Line Tools.

```bash
# Build and install to ~/Applications with ad-hoc signature
./build.sh --install

# Optional: configure local service health URL for widgets
HOMELAB_STATUS_URL="http://localhost:8091/api/bootlog" ./build.sh --install
```

Launch the app from `/Applications` or Spotlight: `Homelab Desk`.

---

## Architecture

```text
Homelab Desk.app (SwiftUI + AppKit)
 ├── HostMetrics (Mach kernel & sysctl)
 ├── DeviceMonitor (visibility-aware fast 2.5s / slow 45s sampling)
 ├── OMPClient (local OMP NDJSON RPC client, MCP suppressed)
 ├── ApprovalPolicy (single-use expiring user approval)
 └── RecoveryBackend
      └── recovery.cjs (Node.js bridge with diagnostic secret redaction)
           ├── restart-coordinator.js (atomic admission lock)
           └── restart-worker.js (transient launchctl worker)
```

---

## License

MIT License. Copyright (c) 2026 Kaan.
