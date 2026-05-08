# RDP Launcher

Automated RDP session launcher with grid layout and auto-login for a two-tier jump server setup.

## How It Works

```
Your Laptop                    Jump Server (10.232.170.158)        Target Servers
+-----------+    RDP           +-------------------------+   RDP   +----------------+
| launch-   | -------->        | rdp-grid.ps1            | ------> | 192.168.58.7   |
| rdp.bat   |  multi-monitor   | (auto-login + grid)     |         | 192.168.58.9   |
+-----------+                  +-------------------------+         | 192.168.58.10  |
                                                                   | ...            |
                                                                   +----------------+
```

1. **Laptop** runs `launch-rdp.bat` → connects to jump server via RDP (multi-monitor)
2. **Jump server** runs `launch-grid.bat` → opens all target servers in a tiled grid with auto-login

## Setup

### 1. Configure files

```
config/servers.txt            # Jump server IP (used by your laptop)
config/user.txt               # Credentials for jump server connection
config/jumpserver-servers.txt # Target server IPs (deployed to jump server)
config/jumpserver-user.txt    # Credentials for target servers (deployed to jump server)
```

### 2. Format for user.txt / jumpserver-user.txt

```
Username = domain\user
Password = yourpassword
```

### 3. Format for servers.txt / jumpserver-servers.txt

One IP or hostname per line. Lines starting with `#` are comments.

```
192.168.58.7
192.168.58.9
192.168.58.10
```

### 4. Deploy to jump server

```
deploy.bat
```

This copies scripts and configs to `C:\RDP_Launcher` on the jump server via admin share (`\\server\C$`).

### 5. Run

- **On laptop**: double-click `launch-rdp.bat` (connects to jump server)
- **On jump server**: double-click `launch-grid.bat` (launches all target RDP sessions in grid)

## Project Structure

```
RDP_Launcher/
├── config/
│   ├── servers.txt              # Jump server IP (your laptop)
│   ├── jumpserver-servers.txt   # Target servers (deployed to jump server)
│   ├── user.txt                 # Jump server credentials
│   ├── jumpserver-user.txt      # Target server credentials
│   ├── servers.example.txt      # Template
│   └── user.example.txt         # Template
├── scripts/
│   ├── rdp-gui.ps1              # GUI launcher (laptop)
│   ├── rdp-grid.ps1             # Grid launcher with auto-login (jump server)
│   ├── rdp-auto.ps1             # Headless launcher (Task Scheduler)
│   ├── deploy-to-jumpserver.ps1 # Deployment script
│   └── lib/
│       ├── Config.ps1           # Shared config module
│       └── RdpUIAutomation.cs   # UI Automation helper for auto-login
├── logs/                        # Runtime logs
├── rdp_sessions/                # Generated .rdp files
├── launch-rdp.bat               # Laptop: connect to jump server
├── launch-grid.bat              # Jump server: launch target grid
└── deploy.bat                   # Laptop: deploy to jump server
```

## Scripts

| Script | Purpose | Runs on |
|--------|---------|---------|
| `rdp-gui.ps1` | GUI with server list, connects to jump server | Laptop |
| `rdp-grid.ps1` | Launches targets in grid, auto-login via SendKeys | Jump server |
| `rdp-auto.ps1` | Headless launcher for Task Scheduler | Either |
| `deploy-to-jumpserver.ps1` | Copies files to jump server via admin share | Laptop |

## Grid Layout

`rdp-grid.ps1` uses hardcoded positions matching the jump server's dual monitors. Each monitor gets 3 windows (2 top + 1 bottom):

```
Left Monitor (-1920,0)     Right Monitor (0,0)
+----------+----------+    +----------+----------+
| Server 1 | Server 2 |    | Server 4 | Server 5 |
+----------+----------+    +----------+----------+
| Server 3 |          |    | Server 6 |          |
+----------+----------+    +----------+----------+
```

To adjust positions, edit `Get-GridPositions` in `scripts/rdp-grid.ps1`.

## Auto-Login Flow

1. Store credentials via `cmdkey` (Windows Credential Manager)
2. Launch mstsc with `.rdp` file
3. Dismiss security/certificate warnings via UI Automation
4. Focus the RDP window
5. SendKeys: TAB → password → ENTER

## Logging

Logs are written to `logs/`:
- `rdp-grid.log` — Grid launcher
- `rdp-gui.log` — GUI launcher
- `deploy.log` — Deployment

Format: `[2026-05-08 10:30:00] [INFO] Message`

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Deploy error 1219 | Run `net use \\server\C$ /delete` then retry |
| Deploy error 86 | Wrong password in `config/user.txt` |
| Windows stacking | Check `Get-GridPositions` matches jump server monitor layout |
| Auto-login not working | Verify credentials in `jumpserver-user.txt` |
| Single screen only | Ensure RDP to jump server uses multi-monitor (`use multimon:i:1`) |
