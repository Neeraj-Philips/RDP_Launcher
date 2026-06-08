# RDP Launcher

Automated RDP session launcher with dynamic grid layout, auto-login, and a dashboard for managing sessions on a two-tier jump server setup.

## How It Works

```
Your Laptop                    Jump Server (192.168.226.2)         Target Servers
+-----------+    RDP           +-------------------------+   RDP   +----------------+
| launch-   | -------->        | Dashboard.ps1           | ------> | 192.168.58.7   |
| rdp.bat   |  dual monitor    | rdp-grid.ps1            |         | 192.168.58.9   |
+-----------+                  | (auto-login + grid)     |         | 192.168.58.10  |
                               +-------------------------+         +----------------+
```

1. **Laptop** runs `launch-rdp.bat` → connects to jump server via RDP (dual monitor)
2. **Jump server** runs `launch-dashboard.bat` → manage and launch target sessions

## Features

- **Dashboard GUI** — launch, stop (all or selected), and monitor sessions
- **Fullscreen button** — relaunch a selected session in fullscreen across all monitors
- **Dynamic grid layout** — auto-detects monitors, calculates optimal window tiling
- **Capture & Apply Layout** — arrange windows manually once, save positions, reuse forever
- **Add/Remove servers** — manage IPs directly from the dashboard
- **Selective launch/stop** — check individual servers to launch or stop them
- **Position verification** — auto-fixes misplaced windows after launch
- **Smart maximize** — grid windows use full monitor resolution, maximize fills the screen
- **Auto-login** — credentials typed via SendKeys + UI Automation
- **Auto-dismiss warnings** — certificate/security dialogs handled automatically

## Quick Start (Step by Step)

### Step 1: Download and extract

Place the `RDP_Launcher` folder anywhere on your laptop (e.g. `C:\Users\YourUser\Downloads\RDP_Launcher`).

### Step 2: Configure your jump server connection (laptop side)

Edit `config/servers.txt` — put your jump server IP:
```
192.168.226.2
```

Edit `config/user.txt` — put your jump server credentials:
```
Username = devopsdom\fse_admin
Password = Philips@123
```

### Step 3: Configure target servers (jump server side)

Edit `config/jumpserver-servers.txt` — list all target machine IPs:
```
192.168.58.7
192.168.58.9
192.168.58.10
192.168.58.15
```

Edit `config/jumpserver-user.txt` — credentials for target machines:
```
Username = devopsdom\fse_admin
Password = Philips1!
```

### Step 4: Deploy to jump server

Double-click `deploy.bat` (or run from cmd):
```
deploy.bat
```
This copies all scripts and configs to `C:\RDP_Launcher` on the jump server.

### Step 5: Connect to jump server from laptop

Double-click `launch-rdp.bat`:
```
launch-rdp.bat
```
This opens an RDP session to the jump server in dual-monitor fullscreen.

### Step 6: Launch target sessions from jump server

Once inside the jump server, open `C:\RDP_Launcher` and either:

**Option A — Dashboard (recommended):**
```
launch-dashboard.bat
```
- Check the servers you want to connect to
- Click **Launch Selected** or **Launch All**
- Sessions open in a grid layout across monitors
- Use **Fullscreen** button to expand one session to all monitors
- Use **Stop All** or **Stop Selected** to disconnect

**Option B — Grid directly:**
```
launch-grid.bat
```
Launches all configured servers in a grid layout with auto-login.

### Step 7: Arrange windows (optional)

1. After grid launch, drag/resize windows to your preferred positions
2. Open Dashboard → click **Capture Layout**
3. Next time you launch, windows will use your saved positions

### Step 8: Fullscreen a single session

1. In Dashboard, check the server you want
2. Click **Fullscreen**
3. That session relaunches spanning all monitors
4. Press `Ctrl+Alt+Break` to exit back to windowed mode

---

## Setup

### 1. Configure files

```
config/servers.txt            # Jump server IP (laptop) / Target IPs (jump server)
config/user.txt               # Credentials for connections
config/jumpserver-servers.txt # Target server IPs (deployed to jump server)
config/jumpserver-user.txt    # Target credentials (deployed as user.txt)
```

### 2. Credential format (user.txt)

```
Username = domain\user
Password = yourpassword
```

### 3. Server list format (servers.txt)

One IP per line. `#` comments out a server (disabled but visible in dashboard).

```
192.168.58.7
# 192.168.58.9
```

### 4. Deploy to jump server

```
deploy.bat
```

Copies scripts and configs to `C:\RDP_Launcher` on the jump server via admin share.

### 5. Run

- **Laptop**: `launch-rdp.bat` (connects to jump server, dual monitor)
- **Jump server**: `launch-dashboard.bat` (opens Dashboard)
- **Jump server**: `launch-grid.bat` (launches grid directly)

## Dashboard

| Feature | Description |
|---------|-------------|
| Server list | All servers shown; checked = enabled, unchecked = disabled |
| Add / Del | Add new IPs or remove existing ones |
| Launch Selected | Launch only checked servers |
| Launch All | Launch all checked servers |
| Stop All | Kill all RDP sessions |
| Stop Selected | Kill only checked servers' sessions |
| **Fullscreen** | Relaunch checked server in fullscreen across all monitors |
| Capture Layout | Save current window positions after manual arrangement |
| Apply Layout | Restore windows to captured positions |
| Session Status | Live connected/disconnected status (auto-refreshes) |
| Live Logs | Tail of rdp-grid.log |

### Fullscreen (All Monitors)

1. Check a server in the server list
2. Click **Fullscreen**
3. Existing windowed session is closed
4. New session launches in fullscreen spanning all monitors (`/f /multimon`)
5. Certificate warnings are auto-dismissed
6. Press `Ctrl+Alt+Break` to exit fullscreen

### Capture Layout Workflow

1. Launch sessions (auto-grid on first run)
2. Drag/resize each window to your preferred spot
3. Click **Capture Layout** — positions saved to `config/layout.txt`
4. Next launch uses saved positions automatically

## Project Structure

```
RDP_Launcher/
├── config/
│   ├── servers.txt              # Server IPs (checked = active, # = disabled)
│   ├── jumpserver-servers.txt   # Target IPs (deployed to jump server)
│   ├── user.txt                 # Credentials
│   ├── jumpserver-user.txt      # Target credentials
│   ├── layout.txt               # Saved window positions (auto-generated)
│   ├── servers.example.txt      # Template
│   └── user.example.txt         # Template
├── scripts/
│   ├── Dashboard.ps1            # Session management GUI
│   ├── rdp-gui.ps1              # Laptop launcher (dual monitor to jump server)
│   ├── rdp-grid.ps1             # Grid launcher with auto-login
│   ├── deploy-to-jumpserver.ps1 # Deployment script
│   └── lib/
│       ├── Config.ps1           # Shared config module
│       └── RdpUIAutomation.cs   # UI Automation for auto-login
├── logs/                        # Runtime logs (gitignored)
├── rdp_sessions/                # Generated .rdp files (gitignored)
├── launch-rdp.bat               # Laptop entry point
├── launch-grid.bat              # Jump server: grid directly
├── launch-dashboard.bat         # Jump server: Dashboard GUI
└── deploy.bat                   # Deploy to jump server
```

## Dynamic Grid

On launch, `rdp-grid.ps1`:
1. Checks for saved layout (`config/layout.txt`) — uses it if found
2. Otherwise detects all monitors via `[System.Windows.Forms.Screen]::AllScreens`
3. Distributes servers evenly across monitors
4. Calculates optimal grid per monitor
5. Uses full monitor resolution with smart sizing for proper maximize behavior

## Auto-Login Flow

1. Store credentials via `cmdkey`
2. Launch mstsc with `.rdp` file
3. Dismiss security warnings (UI Automation)
4. Focus window → SendKeys: TAB → password → ENTER
5. Sequential launch (required for SendKeys focus)

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Deploy error 1219 | Run `net use \\server\C$ /delete /y` then retry |
| Deploy error 86 | Wrong password in `config/user.txt` |
| Windows stacking | Delete `config/layout.txt` to reset to dynamic grid |
| Auto-login failing | Check credentials in user.txt |
| Single screen only | Ensure jump server RDP uses `use multimon:i:1` |
| New server not positioned | Capture layout again to include it |
| Fullscreen not spanning | Use Dashboard Fullscreen button or `Ctrl+Alt+Break` |
