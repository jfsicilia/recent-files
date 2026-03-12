# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A single-file Bash script (`recent_files.sh`) that provides a rofi-based UI for browsing and acting on recently modified files. It uses `fd` to find files changed within a configurable time period under `$HOME`, presents them in a rofi multi-select menu, then offers actions: open, move, copy, move/copy to new folder, or delete.

## Dependencies

- **rofi** — dmenu-style launcher used for all interactive menus
- **fd** — fast file finder (used for listing recent files and folders)
- **xdg-open** — opens files with default applications
- **kdialog** — KDE dialog for text input (new folder name prompt)
- **notify-send** — desktop notifications (optional, falls back to echo)
- Targets a **KDE/Wayland** environment (environment variables are defaulted accordingly)

## Running

```bash
# Default: files changed in the last 1 day
./recent_files.sh

# Custom period (fd --changed-within syntax)
./recent_files.sh 2d
./recent_files.sh 12h
```

## Architecture

The script follows a two-step flow:
1. **File selection** — `fd` finds recently modified files, sorted newest-first via `stat`, presented in rofi multi-select
2. **Action loop** — chosen files are acted upon (open/move/copy/delete); on invalid input the loop re-prompts

Key internals:
- `transfer_files()` handles both move and copy with collision resolution (overwrite / rename / skip, with "apply to all" variants)
- `list_folders()` enumerates directories under `$HOME` sorted by depth (excludes `mnt`, `.git`, `.cache`)
