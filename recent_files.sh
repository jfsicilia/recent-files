#!/usr/bin/env bash
# recent-files.sh — browse recent files with rofi and perform actions on them
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-wayland}"
export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-KDE}"
export XDG_SESSION_DESKTOP="${XDG_SESSION_DESKTOP:-KDE}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

# ── Config ────────────────────────────────────────────────────────────────────
PERIOD="${1:-1d}" # default: last 1 day, override with e.g. ./script 2d
ROFI_ARGS=()

# ── Helpers ───────────────────────────────────────────────────────────────────

rofi_menu() {
    local prompt="$1"
    shift
    rofi -dmenu -p "$prompt" "${ROFI_ARGS[@]}" "$@"
}

notify() {
    command -v notify-send &>/dev/null && notify-send "recent-files" "$1" || echo "$1"
}

list_folders() {
    fd --type d --type l . -E 'mnt' -E '.git' -E '.cache' ~ |
        awk '{print gsub("/","/")" "$0}' |
        sort -n |
        cut -d' ' -f2-
}

# ── Helper: transfer files (move or copy) to a target dir with collision handling
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

        if [[ -e "$dest" ]]; then
            local choice
            if [[ -n "$collision_policy" ]]; then
                choice="$collision_policy"
            else
                choice=$(printf 'overwrite\nnew name\nskip\noverwrite all\nnew name all\nskip all' |
                    rofi_menu "'$basename' already exists: ")
            fi

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
            *)
                skipped=$((skipped + 1))
                continue
                ;;
            esac
        fi

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

    local msg="${action^}: $count file(s) → $target"
    [[ $skipped -gt 0 ]] && msg+=" ($skipped skipped)"
    [[ $errors -gt 0 ]] && msg+=" ($errors failed)"
    notify "$msg"
}

# ── Step 1: pick files ────────────────────────────────────────────────────────

selected=$(
    fd --changed-within="$PERIOD" -tf '.*' -E 'mnt' -E '.git' ~ |
        xargs -d '\n' stat --format='%Y %n' |
        sort -rn |
        cut -d' ' -f2- |
        rofi_menu "Recent ($PERIOD) " -multi-select
)

[[ -z "$selected" ]] && exit 0

# ── Step 2: action loop ───────────────────────────────────────────────────────

while true; do

    action=$(printf 'open\nmove\ncopy\nmove to new folder\ncopy to new folder\ndelete' |
        rofi_menu "Action")

    [[ -z "$action" ]] && exit 0

    case "$action" in

    open)
        while IFS= read -r f; do
            xdg-open "$f"
            # kioclient exec "$f"
        done <<<"$selected"
        break
        ;;

    move | copy)
        target=$(list_folders | rofi_menu "Destination folder: ")
        [[ -z "$target" ]] && continue
        [[ ! -d "$target" ]] && notify "Not a valid directory: $target" && continue

        transfer_files "$action" "$target" "$selected"
        break
        ;;

    "move to new folder" | "copy to new folder")
        # pick parent first, then name the new subfolder
        parent=$(list_folders | rofi_menu "Create new folder inside: ")
        [[ -z "$parent" ]] && continue
        [[ ! -d "$parent" ]] && notify "Not a valid directory: $parent" && continue

        folder_name=$(kdialog --inputbox "New folder name:" "" --title "New Folder")
        [[ $? -ne 0 || -z "$folder_name" ]] && continue

        target="$parent$folder_name"
        if mkdir -p "$target"; then
            op="${action%% *}" # extract "move" or "copy" from action string
            transfer_files "$op" "$target" "$selected"
        else
            notify "Failed to create: $target"
        fi
        break
        ;;

    delete)
        file_count=$(echo "$selected" | wc -l)
        preview=$(echo "$selected" | head -5 | xargs -I{} basename {})
        [[ $file_count -gt 5 ]] && preview+=$'\n'"... and $((file_count - 5)) more"

        confirm=$(
            printf 'no\nyes' |
                rofi_menu "Delete $file_count file(s)? ($(echo "$preview" | tr '\n' ' '))"
        )
        [[ "$confirm" != "yes" ]] && continue

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
