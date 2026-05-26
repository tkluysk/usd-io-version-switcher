#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_BUILDS_DIR="$SCRIPT_DIR/builds"
DRIVE_BUILDS_DIR="/Users/tkluysk/Library/CloudStorage/GoogleDrive-tom_kluyskens@trimble.com/My Drive/Projects & Clients/JCube/Deliverables"
DRIVE_CACHE_DIR="$SCRIPT_DIR/.drive-cache"

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

pick_source() {
    local local_ok=0 drive_ok=0
    [[ -d "$LOCAL_BUILDS_DIR" ]] && local_ok=1
    [[ -d "$DRIVE_BUILDS_DIR" ]] && drive_ok=1

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
    echo "  2) Google Drive (OEM • USD IO/Deliverables)"
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
        # Use the dir path relative to the drive root as a stable cache key
        label="${dir#$DRIVE_BUILDS_DIR/}"
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
    while IFS= read -r -d '' dir; do
        local label
        label=$(basename "$dir")
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

install_035() {
    local root="$1"
    echo "Installing v0.3.5 (Exporter only)..."

    log_cp -R "$root/lib/PlugIns/UsdExporter.plugin" "$PLUGINS_DIR/"

    log_cp "" "$root/lib/libSkpIO.dylib"            "$FRAMEWORKS_DIR/"
    log_cp "" "$root/lib/libskp_usd_ms.dylib"       "$FRAMEWORKS_DIR/"
    log_cp "" "$root/lib/libtbb12-202190.dylib"     "$FRAMEWORKS_DIR/"
    log_cp "" "$root/lib/libtbbmalloc-202190.dylib" "$FRAMEWORKS_DIR/"
    log_cp -R "$root/lib/skp_usd"                   "$FRAMEWORKS_DIR/"
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

    if [[ "$label" == *"0.3.5"* ]]; then
        install_035 "$root"
    else
        install_04x "$root"
    fi

    echo "$label" > "$PLUGINS_DIR/.usd_version"

    echo ""
    echo "Installed: $label -> $(basename "$SKETCHUP_APP")"
}

# ── main ──────────────────────────────────────────────────────────────────────

echo ""
echo "USD IO Version Switcher"
echo "========================"
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
