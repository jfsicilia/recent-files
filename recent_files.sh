#!/usr/bin/env bash
# recent-files.sh — Interactive file manager for recently modified/created files.
# Uses rofi for UI and fd for fast file discovery. Designed to run from
# hotkey managers (e.g. kanata) or directly from a terminal.

# ── Environment ──────────────────────────────────────────────────────────────
# Ensure Wayland/KDE/D-Bus variables are set so the script works correctly
# when launched from minimal environments (e.g. kanata) that don't inherit
# the full desktop session.
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-wayland}"
export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-KDE}"
export XDG_SESSION_DESKTOP="${XDG_SESSION_DESKTOP:-KDE}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

# ── Config ───────────────────────────────────────────────────────────────────
# PERIOD: time window for recent file discovery (fd syntax: e.g. 1d, 12h, 2w).
#         Passed as first argument or defaults to 1 day.
PERIOD="${1:-1d}"
# MAX_DEPTH: maximum directory depth for fd searches under $HOME.
MAX_DEPTH=5
# ROFI_ARGS: extra arguments passed to every rofi invocation.
ROFI_ARGS=()
# EXCLUDE_DIRS: directory names to exclude from all fd searches.
EXCLUDE_DIRS=('mnt' '.cache' '.venv')

# Build fd-compatible exclude flags (-E dir) from EXCLUDE_DIRS.
FD_EXCLUDE=()
for dir in "${EXCLUDE_DIRS[@]}"; do
    FD_EXCLUDE+=(-E "$dir")
done

# ── Helpers ──────────────────────────────────────────────────────────────────

# rofi_menu — Display a rofi dmenu with a given prompt.
# Parameters:
#   $1      — prompt string shown in rofi
#   $@      — additional flags forwarded to rofi (e.g. -i, -multi-select)
# Input:    piped list of options (one per line)
# Output:   selected option(s) to stdout, empty if cancelled
rofi_menu() {
    local prompt="$1"
    shift
    rofi -dmenu -p "$prompt" "${ROFI_ARGS[@]}" "$@"
}

# notify — Show a desktop notification, falling back to echo if notify-send
#           is not available.
# Parameters:
#   $1 — notification message text
notify() {
    command -v notify-send &>/dev/null && notify-send "recent-files" "$1" || echo "$1"
}

# list_folders — List all directories and symlinks under $HOME, sorted by
#                depth (shallowest first). Respects MAX_DEPTH and EXCLUDE_DIRS.
# Output: one directory path per line
list_folders() {
    fd --max-depth "$MAX_DEPTH" --type d --type l . "${FD_EXCLUDE[@]}" ~ |
        awk '{print gsub("/","/")" "$0}' | # prefix each line with its depth (slash count)
        sort -n |                           # sort by depth ascending
        cut -d' ' -f2-                      # strip the depth prefix
}

# period_to_seconds — Convert a human-readable period string to seconds.
# Parameters:
#   $1 — period string (e.g. "30s", "5m", "12h", "2d", "1w")
# Output: integer seconds to stdout
period_to_seconds() {
    local val="${1%?}"    # strip trailing unit character
    local unit="${1: -1}" # extract unit character
    case "$unit" in
    s) echo "$val" ;;
    m) echo "$((val * 60))" ;;
    h) echo "$((val * 3600))" ;;
    d) echo "$((val * 86400))" ;;
    w) echo "$((val * 604800))" ;;
    esac
}

# recent_files — List files recently modified OR created under $HOME.
#   Two-pass approach to catch both cases:
#     1. fd --changed-within: finds files by modification time (mtime) — fast
#     2. fd + stat + awk: finds files by metadata change time (ctime), which
#        updates on creation, copy, and move even when mtime is preserved.
#        This second pass is depth-limited for performance.
#   Results are deduplicated with sort -u.
# Parameters:
#   $1 — period string (e.g. "1d", "12h")
# Output: one file path per line (unsorted)
recent_files() {
    local period="$1"
    local cutoff_epoch
    cutoff_epoch=$(($(date +%s) - $(period_to_seconds "$period")))

    {
        # Pass 1: files modified within the period (fast, uses fd's built-in mtime filter)
        fd --max-depth "$MAX_DEPTH" --changed-within="$period" -tf '.*' "${FD_EXCLUDE[@]}" ~
        # Pass 2: files with recent ctime (catches copies/moves with preserved old mtime).
        # Lists all files up to MAX_DEPTH, batches stat calls via xargs, then filters
        # by ctime >= cutoff using awk.
        fd --max-depth "$MAX_DEPTH" -tf '.*' "${FD_EXCLUDE[@]}" ~ |
            xargs -d '\n' stat --format='%Z %n' 2>/dev/null |
            awk -v cutoff="$cutoff_epoch" '$1 >= cutoff {print substr($0, index($0," ")+1)}'
    } | sort -u
}

# transfer_files — Move or copy files to a target directory with collision handling.
#   When a file already exists at the destination, prompts the user via rofi to
#   choose: overwrite, rename (append _copy suffix), or skip. Each choice has
#   an "all" variant that applies to subsequent collisions without re-prompting.
# Parameters:
#   $1 — action: "move" or "copy"
#   $2 — target directory path
#   $3 — newline-separated list of source file paths
# Output: desktop notification with summary (count, skipped, errors)
transfer_files() {
    local action="$1" # "move" or "copy"
    local target="$2"
    local files="$3"

    local count=0 errors=0 skipped=0 collision_policy=""

    while IFS= read -r f; do
        local basename dest final_dest
        basename="$(basename -- "$f")"
        dest="$target/$basename"
        final_dest="$dest"

        # ── Collision handling ────────────────────────────────────────────
        if [[ -e "$dest" ]]; then
            local choice
            if [[ -n "$collision_policy" ]]; then
                # Reuse previously selected "all" policy
                choice="$collision_policy"
            else
                choice=$(printf 'overwrite\nnew name\nskip\noverwrite all\nnew name all\nskip all' |
                    rofi_menu "'$basename' already exists")
            fi

            # If an "all" variant was chosen, store the policy and normalize
            # the choice to its single-file equivalent
            case "$choice" in
            "overwrite all")
                collision_policy="overwrite all"
                choice="overwrite"
                ;;
            "new name all")
                collision_policy="new name all"
                choice="new name"
                ;;
            "skip all")
                collision_policy="skip all"
                choice="skip"
                ;;
            esac

            case "$choice" in
            overwrite)
                final_dest="$target/$basename"
                ;;
            "new name")
                # Generate a unique name by appending _copy, _copy2, _copy3, etc.
                local name ext candidate n
                name="${basename%.*}"
                ext="${basename##*.}"
                [[ "$basename" == "$ext" ]] && ext="" || ext=".$ext"
                candidate="${name}_copy${ext}"
                n=2
                while [[ -e "$target/$candidate" ]]; do
                    candidate="${name}_copy${n}${ext}"
                    n=$((n + 1))
                done
                final_dest="$target/$candidate"
                ;;
            *) # skip (or cancelled)
                skipped=$((skipped + 1))
                continue
                ;;
            esac
        fi

        # ── Execute transfer ──────────────────────────────────────────────
        if [[ "$action" == "move" ]]; then
            if mv -- "$f" "$final_dest"; then
                count=$((count + 1))
            else
                errors=$((errors + 1))
            fi
        else
            if cp -r -- "$f" "$final_dest"; then
                count=$((count + 1))
            else
                errors=$((errors + 1))
            fi
        fi
    done <<<"$files"

    # ── Summary notification ──────────────────────────────────────────────
    local msg="${action^}: $count file(s) → $target"
    [[ $skipped -gt 0 ]] && msg+=" ($skipped skipped)"
    [[ $errors -gt 0 ]] && msg+=" ($errors failed)"
    notify "$msg"
}

# ── Step 1: File selection ───────────────────────────────────────────────────
# Present recent files in a rofi multi-select menu, sorted newest-first.
# The user can also type special commands instead of selecting files:
#   #<period>  — change the time window (e.g. #3d, #1w)
#   ^<depth>   — change the search depth (e.g. ^3, ^10)
# Both re-launch the menu with updated parameters.

while true; do
    selected=$(
        recent_files "$PERIOD" |
            xargs -d '\n' stat --format='%Y %n' | # prefix each path with mtime epoch
            sort -rn |                             # sort newest first
            cut -d' ' -f2- |                       # strip the mtime prefix
            rofi_menu "$PERIOD recent files, depth $MAX_DEPTH (#<period> ^<depth>)" -i -multi-select
    )

    # Empty selection (Escape pressed) — exit
    [[ -z "$selected" ]] && exit 0

    # Check for period change command (e.g. "#2d")
    if [[ "$selected" =~ ^#[0-9]+[smhdw]$ ]]; then
        PERIOD="${selected#\#}"
        continue
    fi

    # Check for depth change command (e.g. "^5")
    if [[ "$selected" =~ ^\^[0-9]+$ ]]; then
        MAX_DEPTH="${selected#\^}"
        continue
    fi

    break
done

# ── Step 2: Action selection ─────────────────────────────────────────────────
# Present available actions with single-letter prefixes for quick selection.
# Uses -matching prefix so rofi only matches from the start of each line,
# and -auto-select to confirm immediately when only one match remains.
# This allows single-keystroke action selection (e.g. just press 'o' to open).

while true; do

    action=$(printf 'o. open\nm. move\nc. copy\nM. Move to new folder\nC. Copy to new folder\nd. delete' |
        rofi_menu "Action" -matching prefix -auto-select)

    [[ -z "$action" ]] && exit 0

    action="${action#*. }" # strip letter prefix (e.g. "o. open" → "open")

    case "$action" in

    open)
        # Open each selected file with the default KDE application.
        # Uses kde-open instead of xdg-open because xdg-open fails to detect
        # the KDE desktop when launched from minimal environments like kanata.
        while IFS= read -r f; do
            kde-open "$f"
        done <<<"$selected"
        break
        ;;

    move | copy)
        file_count=$(echo "$selected" | wc -l)
        target=$(list_folders | rofi_menu "Select folder to $action $file_count file(s)" -i)
        [[ -z "$target" ]] && continue
        [[ ! -d "$target" ]] && notify "Not a valid directory: $target" && continue

        transfer_files "$action" "$target" "$selected"
        break
        ;;

    "Move to new folder" | "Copy to new folder")
        file_count=$(echo "$selected" | wc -l)
        op="${action%% *}" # extract "Move" or "Copy"
        # First, pick the parent directory where the new subfolder will be created
        parent=$(list_folders | rofi_menu "Create new subfolder and ${op,,} $file_count file(s)" -i)
        [[ -z "$parent" ]] && continue
        [[ ! -d "$parent" ]] && notify "Not a valid directory: $parent" && continue

        # Prompt for the new subfolder name via KDE dialog
        folder_name=$(kdialog --inputbox "New folder name in $parent:" "" --title "New Folder")
        [[ $? -ne 0 || -z "$folder_name" ]] && continue

        target="$parent$folder_name"
        if mkdir -p "$target"; then
            op="${action%% *}"
            transfer_files "${op,,}" "$target" "$selected"
        else
            notify "Failed to create: $target"
        fi
        break
        ;;

    delete)
        # Show a confirmation prompt with a preview of files to delete.
        # Uses prefix matching + auto-select for single-keystroke y/n.
        file_count=$(echo "$selected" | wc -l)
        preview=$(echo "$selected" | head -5 | xargs -I{} basename {})
        [[ $file_count -gt 5 ]] && preview+=$'\n'"... and $((file_count - 5)) more"

        confirm=$(
            printf 'n. No\ny. Yes' |
                rofi_menu "Delete $file_count file(s)? ($(echo "$preview" | tr '\n' ' '))" -matching prefix -auto-select
        )
        [[ "$confirm" != "y. Yes" ]] && continue

        count=0
        errors=0
        while IFS= read -r f; do
            if rm -- "$f"; then
                count=$((count + 1))
            else
                errors=$((errors + 1))
            fi
        done <<<"$selected"

        msg="Deleted $count file(s)"
        [[ $errors -gt 0 ]] && msg+=" ($errors failed)"
        notify "$msg"
        break
        ;;
    esac

done
