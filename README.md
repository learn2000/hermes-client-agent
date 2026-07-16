# Hermes Client Agent

[![Python](https://img.shields.io/badge/python-3.10%2B-blue)](https://python.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Tests](https://github.com/scwall/hermes-client-agent/actions/workflows/tests.yml/badge.svg)](https://github.com/scwall/hermes-client-agent/actions/workflows/tests.yml)

### Remote machine control agent for the Hermes AI assistant

A lightweight agent that installs on any machine (Windows, Linux, macOS) and lets Hermes control it remotely — shell, files, mouse, keyboard, screenshot, processes — via a simple REST API.

---

## What's new in v1.1.0

| Feature | Description |
|---------|-------------|
| **ACP Bridge** | Delegate coding tasks to a local AI coding agent (OpenCode). Hermes sends a prompt, the bridge auto-spawns a runtime, submits the task, and polls transparently until completion. No polling logic needed in Hermes. |
| **Auto-spawn & session reuse** | The bridge manages OpenCode runtimes: auto-launches on first use, reuses existing sessions, cleans up stale ones on restart. |
| **Provider auto-detection** | When a `model` field is passed (e.g. `deepseek-chat`), the bridge infers the provider from model patterns and discovers available models via `/models` and `/config` endpoints. |
| **Linux support** | Screenshot and exec endpoints work on Linux. Cross-platform `exec` handler with `ps` alias for PowerShell. |
| **JSONC config parsing** | Diagnostics module can parse JSONC config files (strip comments, trailing commas) for agent inspection. |

---

## Why?

Hermes is a powerful AI assistant, but it runs on **one** machine. If you want it to interact with your other computers — trigger a build on Windows, test a UI on a laptop, check a process on a server — you have two options:

1. Install Hermes on every machine → heavy, resource-intensive
2. Deploy this lightweight agent → ~100 MB RAM, single command

The agent exposes a REST API. On the Hermes side, a native plugin adds **25 tools** (`exec`, `screenshot`, `mouse_click`, `open_app`, `acp`, etc.) that call this API. Hermes keeps the intelligence, the agent does the execution.

---

## Architecture

```
                        ┌─────────────────────┐
                        │      HERMES          │
                        │  (anywhere: VPS,     │
                        │   LAN, RPi, laptop,  │
                        │   home server...)    │
                        │                      │
                        │  Native plugin       │
                        │  windows_control     │
                        │  25 tools            │
                        └──────┬──────────────┘
                               │
                    HTTP REST (LAN or VPN)
                               │
          ┌────────────────────┼────────────────────┐
          │                    │                    │
          ▼                    ▼                    ▼
   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
   │  Agent       │   │  Agent       │   │  Agent       │
   │  Windows     │   │  Linux       │   │  macOS       │
   │              │   │              │   │              │
   │  PowerShell  │   │  bash/sh     │   │  zsh/bash    │
   │  Files       │   │  Files       │   │  Files       │
   │  Mouse       │   │  Mouse       │   │  Mouse       │
   │  Keyboard    │   │  Keyboard    │   │  Keyboard    │
   │  Screenshot  │   │  Screenshot  │   │  Screenshot  │
   └──────────────┘   └──────────────┘   └──────────────┘
```

Hermes runs wherever you want. Agents live on target machines. Communication goes over the local network or a VPN (Tailscale, WireGuard). Each agent is independent.

---

## Where to run

| Scenario | Hermes | Agents | Network |
|----------|--------|--------|---------|
| **Home / lab** | NAS, RPi, or old PC | Windows PC, Linux laptop, Mac | LAN (192.168.x.x) |
| **VPS + machines** | VPS (Hetzner, DO...) | Home PCs, servers | VPN (Tailscale/WireGuard) |
| **All-in-one** | Same machine as agents | localhost | 127.0.0.1 |

---

## Features

| Category | Endpoints | Hermes tool |
|----------|-----------|-------------|
| Shell | `POST /exec`, `POST /exec/batch` | `windows_exec`, `windows_exec_batch` |
| Files | `GET /file`, `GET /file/read`, `PUT /file`, `POST /file/delete` | `windows_file_read`, `windows_file_write`, `windows_file_delete` |
| Mouse | `POST /mouse/{move,click,doubleclick,scroll}`, `GET /mouse/position` | `windows_mouse_move`, `windows_mouse_click`, `windows_mouse_scroll` |
| Keyboard | `POST /keyboard/{type,press,hotkey}` | `windows_keyboard_type`, `windows_keyboard_press`, `windows_keyboard_hotkey` |
| Windows | `GET /window/{active,list}`, `POST /window/{focus,resize}` | `windows_window_active`, `windows_window_list`, `windows_window_focus` |
| App launch | — | `windows_open_app` (launch + focus) |
| Screenshot | `GET /screenshot` | `windows_screenshot` |
| System | `GET /system`, `GET /processes`, `POST /process/kill` | `windows_system`, `windows_processes` |
| **ACP Bridge** | `POST /acp/tasks`, `GET /acp/tasks/{id}`, `DELETE /acp/tasks/{id}`, `GET /acp/status`, `GET /acp/sessions`, `GET /acp/diagnostics` | `windows_acp` |
| Dashboard | `GET /dashboard`, `GET /dashboard/{logs,errors,exec}` | — |
| API logs | `GET /api/logs`, `GET /api/stats`, `GET /api/logs/export` | — |

Mouse, keyboard, and window endpoints are optional — they depend on `pyautogui` and `pygetwindow`. The agent works without them.

---

## ACP Bridge

The `/acp` bridge relays coding tasks to OpenCode (ACP-compatible AI coding agent) running on the same machine. It handles the full lifecycle automatically — Hermes just sends a prompt and gets a final result.

### How it works

```
Hermes Agent              ACP Bridge (internal)          OpenCode
   │                              │                         │
   │  POST /acp/tasks             │                         │
   │  { prompt, model? }          │                         │
   ├─────────────────────────────►│                         │
   │                              │  auto-spawn if needed   │
   │                              ├────────────────────────►│  opencode serve
   │                              │                         │
   │                              │  POST /session          │
   │                              ├────────────────────────►│
   │                              │  POST /session/{id}/msg │
   │                              ├────────────────────────►│
   │                              │  ← AI response          │
   │                              │◄────────────────────────┤
   │  202 { task_id, status }     │                         │
   │◄─────────────────────────────┤                         │
   │                              │                         │
   │  GET /acp/tasks/{id}         │  (poll loop)            │
   │◄─────────────────────────────┤                         │
   │  { status, result }         │                         │
```

### Key concepts

- **Auto-spawn**: No manual setup. The bridge launches OpenCode on a free port when first needed, manages the process lifecycle, and cleans up stale runtimes on restart.
- **Session reuse**: Active sessions are reused across tasks — no repeated startup overhead.
- **Provider auto-detection**: When you pass `model: "deepseek-chat"`, the bridge infers the provider (`deepseek`), validates the model against available models, and falls back to discovery.
- **Async polling (transparent to Hermes)**: The Hermes plugin (`windows_acp`) handles polling internally. Hermes submits once and gets the final result — no manual polling needed.

### Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/acp/tasks` | Submit a task — returns `task_id` immediately, worker processes in background |
| `GET` | `/acp/tasks/{task_id}` | Poll task status and result |
| `DELETE` | `/acp/tasks/{task_id}` | Cancel a running task |
| `GET` | `/acp/status` | System-level status: managed runtimes, running tasks |
| `GET` | `/acp/sessions` | List active ACP sessions (PID, port, status) |
| `GET` | `/acp/diagnostics` | Inspect agent binary, config, available models, health (supports JSONC config parsing) |

### Provider inference

| Model pattern | → providerID |
|---|---|
| `deepseek-*` | `deepseek` |
| `claude-*` | `anthropic` |
| `gpt-*` | `openai` |
| `gemini-*` | `google` |

### Examples

```bash
# Submit a task (auto-spawns, returns task_id)
curl -X POST http://localhost:8765/acp/tasks \
  -H "X-Agent-Token: YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"explain this codebase","model":"deepseek-chat","timeout":120}'

# Poll task result
curl http://localhost:8765/acp/tasks/{task_id} -H "X-Agent-Token: YOUR_TOKEN"

# List active sessions
curl http://localhost:8765/acp/sessions -H "X-Agent-Token: YOUR_TOKEN"

# Run diagnostics (models, binary, config, health)
curl http://localhost:8765/acp/diagnostics -H "X-Agent-Token: YOUR_TOKEN"

# System status
curl http://localhost:8765/acp/status -H "X-Agent-Token: YOUR_TOKEN"
```

---

## Prerequisites

- Python 3.10+
- [uv](https://docs.astral.sh/uv/) — `pip install uv`

## Installation

### Option A — From source (all OS)

```bash
git clone https://github.com/scwall/hermes-client-agent.git
cd hermes-client-agent
cp .env.example .env    # edit your token
uv sync
uv run python agent.py
```

### Option B — Standalone executable (Windows)

Download `hermes-agent.exe` from the [Releases](https://github.com/scwall/hermes-client-agent/releases) page and run it. No Python required.

### Option C — Windows installer

```powershell
# Build the executable first, then:
.\scripts\installer.ps1                          # install + auto-start on login
.\scripts\installer.ps1 -InstallService          # also register as Windows service
.\scripts\installer.ps1 -Uninstall               # remove everything
```

---

## Hermes plugin

The `windows_control/` directory contains a native Hermes plugin that registers **25 tools** (including `windows_health`, `windows_capabilities`, `windows_acp`, `windows_exec_batch`, and `windows_open_app` in addition to the core shell/file/mouse/keyboard/screenshot tools).

```bash
cp -r windows_control/ <hermes-plugins-dir>/windows_control/
```

### Multi-agent configuration

Configure agents in Hermes' `config.yaml`:

```yaml
windows_control:
  agents:
    laptop:
      url: "http://192.168.1.4:8765"
      token: "${LAPTOP_TOKEN}"
      timeout: 30
    framework:
      url: "http://192.168.1.10:8765"
      token: "${FRAMEWORK_TOKEN}"
      timeout: 15
  default_agent: "laptop"
```

Set tokens in Hermes' `.env`:

```bash
LAPTOP_TOKEN=hermes-windows-agent-secret-change-me
FRAMEWORK_TOKEN=token-pour-framework
```

### Usage

```text
windows_exec {command: "hostname"}              → targets default_agent
windows_exec {command: "hostname", agent: "fw"} → targets framework
```

Restart Hermes after configuration. The plugin logs loaded agents on startup.

---

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `HERMES_AGENT_TOKEN` | *(required)* | Shared authentication token for API endpoints |
| `HERMES_DASHBOARD_TOKEN` | `HERMES_AGENT_TOKEN` | Optional separate token for dashboard access |
| `HERMES_AGENT_HOST` | `0.0.0.0` | Listen interface |
| `HERMES_AGENT_PORT` | `8765` | Listen port |
| `HERMES_ALLOWED_PATHS` | `~` + `/tmp` (Linux), `~` + `D:\` (Windows) | File access whitelist |
| `HERMES_DEBUG` | `false` | Enable debug logging |
| `ACP_TASK_TIMEOUT` | `600` | Default ACP task timeout (seconds) |
| `ACP_MAX_TIMEOUT` | `3600` | Maximum allowed ACP task timeout |

---

## Security

- Token required in `X-Agent-Token` header — invalid token → 401
- Dashboard protected remotely (localhost bypass) via `HERMES_DASHBOARD_TOKEN`
- File paths restricted to `HERMES_ALLOWED_PATHS` — path traversal → 403
- Rate limiting: 60 req/min per IP
- Audit logging: structured JSON Lines log (`logs/audit.jsonl`) with full request/response capture
- Sensitive fields (`password`, `token`, `secret`) masked in console logs
- **Recommended**: LAN or VPN only (Tailscale is free)
- No built-in HTTPS → use a reverse proxy (nginx, Caddy) if exposing externally

---

## Linux support

The agent is fully cross-platform. Linux-specific behaviour:

- **Shell mapping** — `cmd` and `powershell` shells are automatically mapped to `/bin/bash -c`. Use `shell: "cmd"` in your requests on any OS — the agent adapts.
- **Screenshot** — falls back through PIL ImageGrab → ImageMagick `import` → `grim` → `scrot`. On headless systems, returns 503 instead of crashing.
- **File paths** — default `ALLOWED_PATHS` includes `/tmp` on Linux, `D:\` on Windows.
- **Mouse/keyboard** — require `pyautogui` which works on X11.
- **System tray** — `pystray` with X11/Wayland support.

---

## Examples

```bash
# Health check
curl http://localhost:8765/health -H "X-Agent-Token: YOUR_TOKEN"

# Run a command (Windows)
curl -X POST http://agent:8765/exec \
  -H "X-Agent-Token: YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"dir C:\\Users","shell":"cmd"}'

# Run a command (Linux — shell is auto-mapped to bash)
curl -X POST http://agent:8765/exec \
  -H "X-Agent-Token: YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"ps aux | head -20","shell":"cmd"}'

# Take a screenshot (Win32 GDI / PIL ImageGrab / grim / ImageMagick import)
curl http://agent:8765/screenshot \
  -H "X-Agent-Token: YOUR_TOKEN" \
  -o screen.png

# Read dashboard stats
curl http://agent:8765/api/stats -H "X-Agent-Token: YOUR_TOKEN"

# Export audit logs as CSV
curl "http://agent:8765/api/logs/export?format=csv" -H "X-Agent-Token: YOUR_TOKEN" -o logs.csv
```

---

## Development

```bash
uv run pytest tests/ -v       # 149 tests
python scripts/build_exe.py   # → dist/hermes-agent.exe (23.5 MiB)
uv run ruff check .           # lint
uv run ruff format .          # format
```

Run the full endpoint test suite:

```powershell
.\tools\test_endpoints.ps1
```

---

## Roadmap

- [x] Windows agent (PowerShell, files, screenshot, mouse, keyboard)
- [x] Native Hermes plugin — `windows_control` (25 tools)
- [x] Built-in web dashboard with Jinja2 templates and audit logging
- [x] System tray icon — pystray (green/yellow/red status)
- [x] Standalone executable — PyInstaller (23.5 MiB)
- [x] Structured audit log (JSON Lines) with console output
- [x] CSV/JSON log export
- [x] PEP8 clean (ruff, line-length 360)
- [x] ACP Bridge — async task submission, auto-spawn, session reuse, provider auto-detection, diagnostics with JSONC parsing
- [x] ACP runtime broker — lifecycle management, health checks, stale runtime cleanup
- [x] ACP provider inference — automatic model→provider mapping via `/models` and `/config` endpoints
- [x] ACP database models — Peewee ORM for runtimes, conversations, tasks
- [x] Debug logging — configurable via `HERMES_DEBUG` env var
- [x] Linux compatibility — screenshot and exec support for Linux targets
- [ ] Claude Code / Junie adapters for ACP Bridge (currently OpenCode only)
- [x] Native Linux agent (bash exec, PIL/ImageMagick screenshot, cross-platform paths)
- [ ] Native macOS agent (launchd, CoreGraphics screenshot)
- [ ] Multi-agent dashboard (unified view of all agents)
- [ ] Ed25519 key-based auth (stronger than bearer token)
- [ ] WebSocket streaming for long-running commands
- [ ] Packaging: `.deb`, `.rpm`, `.pkg`

---

## License

MIT — Pascal de Sélys ([@scwall](https://github.com/scwall))
