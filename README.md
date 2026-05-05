# RDP Launcher

Automated RDP session launcher with grid layout and secure credential management via Windows Credential Manager.

## Features

- **Secure credentials** — uses Windows Credential Manager (`cmdkey`), no plaintext files
- **Multi-monitor grid** — auto-arranges sessions across all monitors
- **Input validation** — validates all server IPs/hostnames before connecting
- **Retry logic** — automatic retries on launch failures
- **Structured logging** — timestamped logs with severity levels
- **Two-tier deployment** — laptop → jump server → target servers

## Two-Tier Setup (Jump Server)

```
Your Laptop                    Jump Server (192.168.58.23)         Target Servers
+-----------+    RDP           +-------------------------+   RDP   +----------------+
| launch-   | -------->        | RDP Launcher (copy)     | ------> | 172.17.35.49   |
| rdp.bat   |  auto-login      | launch-grid.bat         |         | 10.0.0.50      |
+-----------+                  | (multi-monitor grid)    |         | 10.0.0.51      |
                               +-------------------------+         +----------------+
```

**Step 1: On your laptop**
- `config/servers.txt` contains ONLY the jump server IP
- Run `launch-rdp.bat` to connect to the jump server

**Step 2: On the jump server**
- Run `deploy.bat` to copy the tool automatically, OR copy manually
- Edit `config/servers.txt` with the target server IPs
- Run `launch-grid.bat` to launch all targets in a grid layout

## Project Structure

```
RDP_Launcher/
├── config/
│   ├── servers.txt              # Server list (edit per machine) [gitignored]
│   ├── servers.example.txt      # Template
│   ├── user.txt                 # Username (domain\user) [gitignored]
│   ├── user.example.txt         # Template
│   └── jumpserver-servers.txt   # Target servers for jump server deploy
├── scripts/
│   ├── rdp-gui.ps1              # GUI dashboard
│   ├── rdp-auto.ps1             # Headless launcher (Task Scheduler)
│   ├── rdp-grid.ps1             # Multi-monitor grid launcher
│   ├── deploy-to-jumpserver.ps1 # Deployment orchestrator
│   └── lib/
│       ├── Config.ps1           # Shared configuration module
│       └── RdpUIAutomation.cs   # .NET UI Automation helper
├── logs/                        # Runtime logs [gitignored]
├── rdp_sessions/                # Generated .rdp files [gitignored]
├── launch-rdp.bat               # GUI launcher
├── launch-grid.bat              # Grid launcher
├── deploy.bat                   # Deploy to jump server
├── .gitignore
└── README.md
```

## Quick Start

1. Copy the example configs:
   ```
   copy config\servers.example.txt config\servers.txt
   copy config\user.example.txt config\user.txt
   ```
2. Edit `config\user.txt` — set your `domain\username`
3. Edit `config\servers.txt` — add server IPs (one per line)
4. Double-click `launch-rdp.bat` (GUI) or `launch-grid.bat` (grid)
5. On first connect, you'll be prompted for credentials (stored securely in Windows Credential Manager)

## Scripts

| Script | Purpose | Use on |
|--------|---------|--------|
| `rdp-gui.ps1` | GUI with server list + credential management | Laptop |
| `rdp-auto.ps1` | Headless, for Task Scheduler | Either |
| `rdp-grid.ps1` | Auto-arrange across monitors | Jump server |
| `deploy-to-jumpserver.ps1` | Deploy tool to jump server | Laptop |

### rdp-grid.ps1 - Grid Layout

Detects all monitors and arranges RDP sessions in an optimal grid:

```
Single Monitor          Dual Monitor
+-------------+        Monitor 1       Monitor 2
|  Server 1   |        +-----------+   +-----------+
+-------------+        | Server 1  |   | Server 3  |
|  Server 2   |        +-----------+   +-----------+
+-------------+        | Server 2  |   | Server 4  |
                       +-----------+   +-----------+
```

## Configuration

### config/user.txt
Single line with your domain username:
```
DOMAIN\username
```

### config/servers.txt
One server IP or hostname per line. Comments start with `#`:
```
# Production servers
192.168.1.100
10.0.0.50
myserver.domain.com
```

Supported formats:
- IPv4: `192.168.1.100`
- Hostname: `server.domain.com`
- With port: `192.168.1.100:3390`

## Security

- **No plaintext passwords** — credentials stored in Windows Credential Manager
- **Input validation** — server entries validated against IP/hostname patterns
- **Gitignored secrets** — `user.txt`, `servers.txt`, and `credentials.txt` never committed
- **Secure prompts** — deployment uses `Get-Credential` (masked input)
- **No credential files deployed** — jump server uses same Credential Manager approach

## Logging

All scripts write structured logs to `logs/`:
- `rdp-gui.log` — GUI launcher events
- `rdp-auto.log` — Headless launcher events
- `rdp-grid.log` — Grid launcher events
- `deploy.log` — Deployment events

Log format: `[2026-05-04 13:57:12] [INFO] Message`

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "No username in config/user.txt" | Create `config/user.txt` with your `domain\user` |
| "No valid servers" | Check `config/servers.txt` has valid IPs/hostnames |
| Credential prompt keeps appearing | Run `cmdkey /list` to verify stored credentials |
| Grid windows not positioning | Increase wait time or check if mstsc launched |
| Deploy fails to connect | Verify admin share access: `net use \\server\C$` |
