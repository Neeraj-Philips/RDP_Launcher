# RDP Launcher

Automated RDP launcher with UI Automation. Dismisses security warnings and auto-types login credentials.

## Two-Tier Setup (Jump Server)

```
Your Laptop                    Jump Server (192.168.58.23)         Target Servers
+-----------+    RDP           +-------------------------+   RDP   +----------------+
| launch-   | -------->        | RDP Launcher (copy 2)   | ------> | 172.17.35.49   |
| rdp.bat   |  auto-login      | launch-grid.bat         |         | 10.0.0.50      |
+-----------+                  | (dual monitor grid)     |         | 10.0.0.51      |
                               +-------------------------+         +----------------+
```

**Step 1: On your laptop**
- `config/servers.txt` contains ONLY the jump server IP
- Run `launch-rdp.bat` to connect to the jump server

**Step 2: On the jump server**
- Copy this entire folder to the jump server
- Edit `config/servers.txt` with the target server IPs
- Run `launch-grid.bat` to launch all targets in a grid layout

## Project Structure

```
RDP_Launcher/
+-- config/
|   +-- servers.txt                # Server list (edit per machine)
|   +-- credentials.txt            # Login credentials
|   +-- jumpserver-servers.txt     # Reference: target servers for jump server
|   +-- servers.example.txt        # Template
|   +-- credentials.example.txt    # Template
+-- scripts/
|   +-- rdp-gui.ps1                # GUI dashboard
|   +-- rdp-auto.ps1               # Headless launcher (Task Scheduler)
|   +-- rdp-grid.ps1               # Dual-monitor grid launcher
|   +-- lib/
|       +-- RdpUIAutomation.cs     # .NET UI Automation helper
+-- logs/                          # Runtime logs (gitignored)
+-- rdp_sessions/                  # Generated .rdp files (gitignored)
+-- launch-rdp.bat                 # GUI launcher
+-- launch-grid.bat                # Grid launcher
+-- .gitignore
+-- README.md
```

## Quick Start

1. Copy the example configs:
   ```
   copy config\servers.example.txt config\servers.txt
   copy config\credentials.example.txt config\credentials.txt
   ```
2. Edit `config\servers.txt` - add server IPs (one per line)
3. Edit `config\credentials.txt` - set username and password
4. Double-click `launch-rdp.bat` (GUI) or `launch-grid.bat` (grid)

## Scripts

| Script | Purpose | Use on |
|--------|---------|--------|
| `rdp-gui.ps1` | GUI with server list + credential fields | Laptop |
| `rdp-auto.ps1` | Headless, for Task Scheduler | Either |
| `rdp-grid.ps1` | Auto-arrange across monitors | Jump server |

### rdp-grid.ps1 - Grid Layout

Detects all monitors and arranges RDP sessions in a grid:

```
Single Monitor          Dual Monitor
+-------------+        Monitor 1       Monitor 2
|  Server 1   |        +-----------+   +-----------+
+-------------+        | Server 1  |   | Server 3  |
|  Server 2   |        +-----------+   +-----------+
+-------------+        | Server 2  |   | Server 4  |
                       +-----------+   +-----------+
```

### Task Scheduler (rdp-auto.ps1)

| Setting   | Value |
|-----------|-------|
| Program   | `powershell.exe` |
| Arguments | `-ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\path\to\scripts\rdp-auto.ps1"` |
| Trigger   | At log on |

## How It Works

1. Reads `config/servers.txt` and `config/credentials.txt`
2. For each server:
   - Stores credentials via `cmdkey`
   - Generates `.rdp` file
   - Launches `mstsc.exe`
   - UI Automation clicks "Connect" on security warning
   - Detects remote Windows login screen
   - SendKeys types username + password + Enter
3. Grid mode: positions windows using Win32 MoveWindow API

## Security Notes

- `config/credentials.txt` and `config/servers.txt` are gitignored
- Passwords stored in plain text - keep config directory secure
- `.example.txt` files are safe to commit as templates

## Requirements

- Windows 10/11 or Windows Server 2016+
- PowerShell 5.1+
- mstsc.exe (Remote Desktop Connection)
