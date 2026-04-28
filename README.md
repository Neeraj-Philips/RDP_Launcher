# RDP Launcher

Simple RDP launcher that reads from an editable server list file.

## Files

| File | Purpose |
|------|---------|
| `servers.txt` | Your server list — edit this to add/remove IPs |
| `rdp-gui.ps1` | GUI dashboard — shows list, launches all, edit button |
| `rdp-auto.ps1` | Headless auto-launcher for Task Scheduler |
| `launch-rdp.bat` | Double-click shortcut to open the GUI |

## How It Works

1. Edit `servers.txt` — one IP per line, `#` for comments
2. Double-click `launch-rdp.bat` (or run `rdp-gui.ps1`)
3. Click **Launch All** → connects to every server in the file

The GUI also has:
- **Edit servers.txt** button — opens Notepad to add/remove IPs
- **Refresh List** button — reloads after you save changes

## Task Scheduler (Auto-Run at Login)

Point Task Scheduler at `rdp-auto.ps1`:
- Program: `powershell.exe`
- Arguments: `-ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\full\path\to\rdp-auto.ps1"`
- Trigger: At log on

It reads the same `servers.txt` file — no hardcoded IPs anywhere.
