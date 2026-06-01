#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_BUILDS_DIR="$SCRIPT_DIR/builds"
DRIVE_REL_PATH="My Drive/Projects & Clients/JCube/Deliverables"
DRIVE_BUILDS_DIR=""  # discovered at runtime by find_drive_builds_dir
DRIVE_CACHE_DIR="$SCRIPT_DIR/.drive-cache"
# Newly-synced Release zips that Drive for Desktop may not have surfaced on
# the local mount yet — staged by sync-releases.py so the switcher can use
# them immediately. Treated as additional drive-mode entries below.
INCOMING_DIR="$DRIVE_CACHE_DIR/incoming"

BUILDS_DIR=""
SOURCE_MODE=""  # "local" or "drive"

SKETCHUP_APPS=()
SKETCHUP_TARGETS=()

discover_sketchup_apps() {
    # Use if/then (not `[[ ]] && cmd`) — under bash 3.2 + `set -e`, a failing
    # `&&` compound at the top of a function aborts the script.
    local dir app
    # Nested layout (2026+): /Applications/SketchUp <year>/SketchUp.app
    for dir in /Applications/SketchUp\ */; do
        if [[ -d "${dir}SketchUp.app/Contents" ]]; then
            SKETCHUP_APPS+=("${dir%/}/SketchUp.app")
        fi
    done
    # Flat layout (older releases / dev builds): /Applications/SketchUp <ver>.app
    for app in /Applications/SketchUp\ *.app; do
        if [[ -d "$app/Contents" ]]; then
            SKETCHUP_APPS+=("$app")
        fi
    done
}

# ── helpers ──────────────────────────────────────────────────────────────────

VERSIONS=()
VERSION_ROOTS=()

PLUGINS_DIR=""
FRAMEWORKS_DIR=""

die() { echo "ERROR: $*" >&2; exit 1; }

# Optionally pull new SkpXyz releases from the GitLab wiki into Drive so the
# version list below is up to date. Never aborts the switcher on failure.
maybe_sync() {
    local sync_script="$SCRIPT_DIR/sync-releases.py"
    [[ -f "$sync_script" ]] || return 0

    local ans
    read -rp "Check GitLab for new versions and sync to Drive? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || return 0

    local py=""
    if [[ -x "$SCRIPT_DIR/.venv/bin/python" ]]; then
        py="$SCRIPT_DIR/.venv/bin/python"
    elif command -v python3 >/dev/null 2>&1; then
        py=python3
    elif command -v python >/dev/null 2>&1; then
        py=python
    else
        echo "  python not found — skipping version check." >&2
        return 0
    fi

    echo "Checking GitLab for new releases..."
    if ! "$py" "$sync_script"; then
        echo "  (version check failed — continuing with versions already in Drive)" >&2
    fi
}

pick_sketchup() {
    discover_sketchup_apps
    local available=("${SKETCHUP_APPS[@]}")

    [[ ${#available[@]} -eq 0 ]] && die "No SketchUp installation found."

    if [[ ${#available[@]} -eq 1 ]]; then
        SKETCHUP_TARGETS=("${available[0]}")
        return
    fi

    echo "Select SketchUp installation:"
    local i=1
    for app in "${available[@]}"; do
        echo "  $i) $app"
        ((i++))
    done
    echo "  a) All of the above"
    echo ""
    read -rp "Select app [1-${#available[@]}/a]: " choice
    if [[ "$choice" == "a" ]]; then
        SKETCHUP_TARGETS=("${available[@]}")
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#available[@]} )); then
        SKETCHUP_TARGETS=("${available[$(( choice - 1 ))]}")
    else
        die "Invalid selection: $choice"
    fi
}

# Scan Google Drive for Desktop mounts for the Deliverables folder, so the
# switcher isn't pinned to one user's CloudStorage path. Echoes the path on
# success. (if/then form to avoid the bash 3.2 + `set -e` && abort.)
find_drive_builds_dir() {
    local base
    for base in "$HOME/Library/CloudStorage"/GoogleDrive-*; do
        if [[ -d "$base/$DRIVE_REL_PATH" ]]; then
            echo "$base/$DRIVE_REL_PATH"
            return 0
        fi
    done
    return 1
}

pick_source() {
    local local_ok=0 drive_ok=0
    [[ -d "$LOCAL_BUILDS_DIR" ]] && local_ok=1
    DRIVE_BUILDS_DIR="$(find_drive_builds_dir || true)"
    [[ -n "$DRIVE_BUILDS_DIR" ]] && drive_ok=1

    # Resolve symlinks so find works correctly
    (( local_ok )) && LOCAL_BUILDS_DIR="$(cd "$LOCAL_BUILDS_DIR" && pwd -P)"

    if (( local_ok && ! drive_ok )); then
        SOURCE_MODE="local"; BUILDS_DIR="$LOCAL_BUILDS_DIR"; return
    fi
    if (( drive_ok && ! local_ok )); then
        SOURCE_MODE="drive"; BUILDS_DIR="$DRIVE_BUILDS_DIR"; return
    fi
    (( local_ok || drive_ok )) || die "Neither local builds dir ($LOCAL_BUILDS_DIR) nor Drive dir ($DRIVE_BUILDS_DIR) found."

    echo "Select source:"
    echo "  1) Local builds folder ($LOCAL_BUILDS_DIR)"
    echo "  2) Google Drive ($DRIVE_BUILDS_DIR)"
    echo ""
    read -rp "Select source [1-2]: " choice
    case "$choice" in
        1) SOURCE_MODE="local"; BUILDS_DIR="$LOCAL_BUILDS_DIR" ;;
        2) SOURCE_MODE="drive"; BUILDS_DIR="$DRIVE_BUILDS_DIR" ;;
        *) die "Invalid selection: $choice" ;;
    esac
}

# Returns a Darwin root directory for the given version folder, extracting from
# a zip into the drive cache on demand when in drive mode.
resolve_darwin_root() {
    local dir="$1"
    local darwin_root
    darwin_root=$(find "$dir" -maxdepth 1 -type d -name "*Darwin*" 2>/dev/null | head -1)
    if [[ -n "$darwin_root" ]]; then
        echo "$darwin_root"; return 0
    fi

    if [[ "$SOURCE_MODE" == "drive" ]]; then
        local zip
        zip=$(find "$dir" -maxdepth 1 -type f -name "*Darwin*.zip" 2>/dev/null | head -1)
        [[ -z "$zip" ]] && return 1

        local label cache
        # Use the dir path relative to its source root as a stable cache key.
        # Staged dirs live under $INCOMING_DIR; Drive-mount dirs under $DRIVE_BUILDS_DIR.
        if [[ "$dir" == "$INCOMING_DIR"/* ]]; then
            label="${dir#$INCOMING_DIR/}"
        else
            label="${dir#$DRIVE_BUILDS_DIR/}"
        fi
        cache="$DRIVE_CACHE_DIR/${label//\//__}"
        darwin_root=$(find "$cache" -maxdepth 1 -type d -name "*Darwin*" 2>/dev/null | head -1)
        if [[ -z "$darwin_root" ]]; then
            mkdir -p "$cache"
            echo "  extracting $(basename "$zip") -> .drive-cache/$label/" >&2
            unzip -q -o "$zip" -d "$cache" >&2 || return 1
            darwin_root=$(find "$cache" -maxdepth 1 -type d -name "*Darwin*" 2>/dev/null | head -1)
        fi
        [[ -n "$darwin_root" ]] && echo "$darwin_root" && return 0
    fi
    return 1
}

list_drive_entry() {
    local dir="$1" label="$2"
    if find "$dir" -maxdepth 1 \( -type d -name "*Darwin*" -o -type f -name "*Darwin*.zip" \) 2>/dev/null | grep -q .; then
        VERSIONS+=("$label")
        VERSION_ROOTS+=("$dir")
        return 0
    fi
    return 1
}

list_versions() {
    local idx=1 added
    # Plain string of "|label|" tokens; bash 3.2 has no associative arrays.
    local seen=""

    # Pre-pass: list staged versions (newly-synced zips that Drive for Desktop
    # may not have surfaced on the local mount yet). Drive mode only.
    if [[ "$SOURCE_MODE" == "drive" && -d "$INCOMING_DIR" ]]; then
        while IFS= read -r -d '' dir; do
            local label
            label=$(basename "$dir")
            if list_drive_entry "$dir" "$label"; then
                echo "  $idx) $label"
                seen="$seen|$label|"
                ((idx++))
            fi
        done < <(find "$INCOMING_DIR" -maxdepth 1 -mindepth 1 -type d | sort -Vr | tr '\n' '\0')
    fi

    while IFS= read -r -d '' dir; do
        local label
        label=$(basename "$dir")
        # Already added from the staging pre-pass — don't list again.
        case "$seen" in *"|$label|"*) continue ;; esac

        if [[ "$SOURCE_MODE" == "drive" ]]; then
            # Skip anything older than 0.4.0
            if [[ "$label" =~ [[:space:]]0\.([0-3])\. ]] || [[ "$label" =~ [[:space:]]0\.[0-3]$ ]]; then
                continue
            fi
            added=0
            if list_drive_entry "$dir" "$label"; then
                echo "  $idx) $label"
                ((idx++)); added=1
            fi
            if (( ! added )); then
                # Descend one level for variant subfolders (e.g. "Using SketchUp libs")
                while IFS= read -r -d '' sub; do
                    local sublabel="$label / $(basename "$sub")"
                    if list_drive_entry "$sub" "$sublabel"; then
                        echo "  $idx) $sublabel"
                        ((idx++))
                    fi
                done < <(find "$dir" -maxdepth 1 -mindepth 1 -type d | sort -V | tr '\n' '\0')
            fi
        else
            if [[ "$label" =~ [[:space:]]0\.([0-3])\. ]] || [[ "$label" =~ [[:space:]]0\.[0-3]$ ]]; then
                continue
            fi
            local darwin_root
            darwin_root=$(find "$dir" -maxdepth 1 -type d -name "*Darwin*" | head -1)
            [[ -z "$darwin_root" ]] && continue
            VERSIONS+=("$label")
            VERSION_ROOTS+=("$darwin_root")
            echo "  $idx) $label"
            ((idx++))
        fi
    done < <(find "$BUILDS_DIR" -maxdepth 1 -mindepth 1 -type d | sort -Vr | tr '\n' '\0')
}

current_version() {
    local marker="$PLUGINS_DIR/.usd_version"
    if [[ -f "$marker" ]]; then
        cat "$marker"
    else
        echo "(none)"
    fi
}

# ── removal ───────────────────────────────────────────────────────────────────

shorten() {
    local path="$1"
    path="${path/#$BUILDS_DIR\//}"
    path="${path/#$DRIVE_CACHE_DIR\//.drive-cache/}"
    path="${path/#$HOME\//~/}"
    if [[ "$path" =~ (SkpXyz-[^/]+/.+) ]]; then
        path=".../${BASH_REMATCH[1]}"
    fi
    # Shorten any SketchUp app path to just the app name + suffix
    if [[ "$path" =~ (.+\.app)/Contents/(.+) ]]; then
        path="...$(basename "${BASH_REMATCH[1]}")/Contents/${BASH_REMATCH[2]}"
    fi
    echo "$path"
}

safe_rm() {
    local flag="$1"; shift
    for f in "$@"; do
        if [[ -e "$f" ]]; then
            echo "  rm $(shorten "$f")"
            rm "$flag" "$f"
        fi
    done
}

remove_installed() {
    echo "Removing previously installed USD plugin files..."

    safe_rm -rf \
        "$PLUGINS_DIR/UsdExporter.plugin" \
        "$PLUGINS_DIR/UsdImporter.plugin"

    safe_rm -f \
        "$FRAMEWORKS_DIR/libSkpIO.dylib" \
        "$FRAMEWORKS_DIR/libSkpI0.dylib" \
        "$FRAMEWORKS_DIR/libSkpXyz.dylib" \
        "$FRAMEWORKS_DIR/libskp_usd_ms.dylib" \
        "$FRAMEWORKS_DIR/libsu_usd_ms.dylib"

    while IFS= read -r f; do
        safe_rm -f "$f"
    done < <(find "$FRAMEWORKS_DIR" -maxdepth 1 -name "libtbb*" 2>/dev/null)

    safe_rm -rf \
        "$FRAMEWORKS_DIR/skp_usd" \
        "$FRAMEWORKS_DIR/su_usd" \
        "$FRAMEWORKS_DIR/usd"

    safe_rm -f "$PLUGINS_DIR/.usd_version"

    echo "Done removing."
}

# ── installation ──────────────────────────────────────────────────────────────

log_cp() {
    local flag="$1" src="$2" dst="$3"
    echo "  cp $(shorten "$src") -> $(shorten "$dst")"
    local err
    if [[ -n "$flag" ]]; then
        err=$(cp "$flag" "$src" "$dst" 2>&1) || { echo "ERROR: copy failed: $err" >&2; exit 1; }
    else
        err=$(cp "$src" "$dst" 2>&1) || { echo "ERROR: copy failed: $err" >&2; exit 1; }
    fi
}

install_04x() {
    local root="$1"
    echo "Installing v0.4.x+ (Exporter & Importer)..."

    log_cp -R "$root/lib/Exporters/UsdExporter.plugin" "$PLUGINS_DIR/"
    log_cp -R "$root/lib/Importers/UsdImporter.plugin" "$PLUGINS_DIR/"

    log_cp "" "$root/lib/libSkpXyz.dylib"    "$FRAMEWORKS_DIR/"
    log_cp "" "$root/lib/libsu_usd_ms.dylib" "$FRAMEWORKS_DIR/"

    while IFS= read -r f; do
        log_cp "" "$f" "$FRAMEWORKS_DIR/"
    done < <(find "$root/lib" -maxdepth 1 -name "libtbb*")

    local usd_dir
    usd_dir=$(find "$root/lib" -maxdepth 1 -type d \( -name "su_usd" -o -name "usd" \) | head -1)
    [[ -n "$usd_dir" ]] && log_cp -R "$usd_dir" "$FRAMEWORKS_DIR/"
}

install_version() {
    local label="$1"
    local root="$2"

    remove_installed
    install_04x "$root"

    echo "$label" > "$PLUGINS_DIR/.usd_version"

    echo ""
    echo "Installed: $label -> $(basename "$SKETCHUP_APP")"
}

# ── main ──────────────────────────────────────────────────────────────────────

echo ""
echo "USD IO Version Switcher"
echo "========================"
echo ""

maybe_sync
echo ""

pick_source
[[ -d "$BUILDS_DIR" ]] || die "Builds directory not found at: $BUILDS_DIR"

echo ""
pick_sketchup

echo ""
echo "Available versions (source: $SOURCE_MODE):"
list_versions
echo ""

[[ ${#VERSIONS[@]} -eq 0 ]] && die "No build versions found in $BUILDS_DIR"

read -rp "Select version [1-${#VERSIONS[@]}]: " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#VERSIONS[@]} )); then
    die "Invalid selection: $choice"
fi

idx=$(( choice - 1 ))

for SKETCHUP_APP in "${SKETCHUP_TARGETS[@]}"; do
    PLUGINS_DIR="$SKETCHUP_APP/Contents/PlugIns"
    FRAMEWORKS_DIR="$SKETCHUP_APP/Contents/Frameworks"
    echo ""
    echo ">>> $(basename "$SKETCHUP_APP")"
    echo "    Currently installed: $(current_version)"
    root="${VERSION_ROOTS[$idx]}"
    if [[ "$SOURCE_MODE" == "drive" ]]; then
        root=$(resolve_darwin_root "$root") || die "Could not extract Darwin build for ${VERSIONS[$idx]}"
    fi
    install_version "${VERSIONS[$idx]}" "$root"
done
