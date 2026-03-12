# recent-files

A rofi-based file manager for recently modified or created files. It discovers files changed within a configurable time window under `$HOME`, presents them in a multi-select menu, and lets you act on them — open, move, copy, or delete.

![Bash](https://img.shields.io/badge/Bash-Script-green)
![License](https://img.shields.io/badge/License-MIT-blue)

## Features

- **Two-pass file discovery** — finds files by both modification time (mtime) and metadata change time (ctime), catching copies and moves that preserve the original mtime
- **Multi-select** — select multiple files at once from the rofi menu
- **Dynamic parameters** — change the time period (`#2d`, `#12h`) or search depth (`^3`, `^10`) directly from the menu without restarting
- **File actions** — open, move, copy, move/copy to a new folder, or delete selected files
- **Collision handling** — when moving or copying, choose to overwrite, rename, or skip conflicting files, with "apply to all" options
- **Desktop notifications** — summary notifications via `notify-send` after each action

## Dependencies

- [rofi](https://github.com/davatorium/rofi) — dmenu-style launcher for all interactive menus
- [fd](https://github.com/sharkdp/fd) — fast file finder
- [kde-open](https://kde.org/) — opens files with default KDE applications
- [kdialog](https://kde.org/) — KDE dialog for text input (new folder name prompt)
- [notify-send](https://gitlab.gnome.org/GNOME/libnotify) — desktop notifications (optional, falls back to echo)

Targets a **KDE/Wayland** environment. Environment variables are defaulted for KDE/Wayland so the script works when launched from minimal environments like hotkey managers.

## Installation

```bash
git clone git@github.com:jfsicilia/recent-files.git
cd recent-files
chmod +x recent_files.sh
```

## Usage

```bash
# Default: files changed in the last 1 day, search depth 5
./recent_files.sh

# Custom period (fd --changed-within syntax)
./recent_files.sh 2d    # last 2 days
./recent_files.sh 12h   # last 12 hours
./recent_files.sh 1w    # last 1 week
```

### In-menu commands

While the file selection menu is open, you can type:

| Command     | Effect                                         |
| ----------- | ---------------------------------------------- |
| `#<period>` | Change time window (e.g. `#3d`, `#1w`, `#30m`) |
| `^<depth>`  | Change search depth (e.g. `^3`, `^10`)         |

### Actions

After selecting files, choose an action with a single keypress:

| Key | Action                        |
| --- | ----------------------------- |
| `o` | Open with default application |
| `m` | Move to an existing folder    |
| `c` | Copy to an existing folder    |
| `M` | Move to a new folder          |
| `C` | Copy to a new folder          |
| `d` | Delete (with confirmation)    |

## Configuration

Edit the variables at the top of `recent_files.sh`:

| Variable       | Default            | Description                               |
| -------------- | ------------------ | ----------------------------------------- |
| `PERIOD`       | `1d`               | Time window for file discovery            |
| `MAX_DEPTH`    | `5`                | Maximum directory depth for searches      |
| `ROFI_ARGS`    | `()`               | Extra arguments passed to every rofi call |
| `EXCLUDE_DIRS` | `mnt .cache .venv` | Directories excluded from all searches    |

## Hotkey integration

The script is designed to be launched from hotkey managers like [kanata](https://github.com/jtroo/kanata). Example kanata configuration:

```lisp
(defcfg process-unmapped-keys yes)
(defsrc)
(deflayermap (base-layer)
  caps (cmd /path/to/recent_files.sh)
)
```
