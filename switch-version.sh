#!/usr/bin/env bash
set -euo pipefail

BUILDS_DIR="$(cd "$(dirname "$0")/builds" && pwd)"
SKETCHUP_APP="/Applications/SketchUp 26.0.app/Contents"
PLUGINS_DIR="$SKETCHUP_APP/PlugIns"
FRAMEWORKS_DIR="$SKETCHUP_APP/Frameworks"

# ── helpers ──────────────────────────────────────────────────────────────────

VERSIONS=()
VERSION_ROOTS=()

die() { echo "ERROR: $*" >&2; exit 1; }

list_versions() {
    local i=1
    while IFS= read -r -d '' dir; do
        local darwin_root
        darwin_root=$(find "$dir" -maxdepth 1 -type d -name "*Darwin*" | head -1)
        [[ -z "$darwin_root" ]] && continue
        local label
        label=$(basename "$dir")
        VERSIONS+=("$label")
        VERSION_ROOTS+=("$darwin_root")
        echo "  $i) $label"
        ((i++))
    done < <(find "$BUILDS_DIR" -maxdepth 1 -mindepth 1 -type d | sort -Vr | tr '\n' '\0')
}

current_version() {
    # Look for a marker file we write on install
    local marker="$PLUGINS_DIR/.usd_version"
    if [[ -f "$marker" ]]; then
        cat "$marker"
    else
        echo "(none)"
    fi
}

# ── removal ───────────────────────────────────────────────────────────────────

safe_rm() {
    local flag="$1"; shift
    for f in "$@"; do
        if [[ -e "$f" ]]; then
            echo "  rm $f"
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
        "$FRAMEWORKS_DIR/libsu_usd_ms.dylib" \
        "$FRAMEWORKS_DIR/libtbb12-202190.dylib" \
        "$FRAMEWORKS_DIR/libtbbmalloc-202190.dylib"

    safe_rm -rf \
        "$FRAMEWORKS_DIR/skp_usd" \
        "$FRAMEWORKS_DIR/su_usd"

    safe_rm -f "$PLUGINS_DIR/.usd_version"

    echo "Done removing."
}

# ── installation ──────────────────────────────────────────────────────────────

log_cp() {
    local flag="$1" src="$2" dst="$3"
    echo "  cp $src -> $dst"
    if [[ -n "$flag" ]]; then
        cp "$flag" "$src" "$dst"
    else
        cp "$src" "$dst"
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
    echo "Installing v0.4.x (Exporter & Importer)..."

    log_cp -R "$root/lib/Exporters/UsdExporter.plugin" "$PLUGINS_DIR/"
    log_cp -R "$root/lib/Importers/UsdImporter.plugin" "$PLUGINS_DIR/"

    log_cp "" "$root/lib/libSkpXyz.dylib"            "$FRAMEWORKS_DIR/"
    log_cp "" "$root/lib/libsu_usd_ms.dylib"         "$FRAMEWORKS_DIR/"
    log_cp "" "$root/lib/libtbb12-202190.dylib"      "$FRAMEWORKS_DIR/"
    log_cp "" "$root/lib/libtbbmalloc-202190.dylib"  "$FRAMEWORKS_DIR/"
    log_cp -R "$root/lib/su_usd"                     "$FRAMEWORKS_DIR/"
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

    # Write marker
    echo "$label" > "$PLUGINS_DIR/.usd_version"

    echo ""
    echo "Installed: $label"
    # echo ""
    # echo "Next step: codesign or disable SIP, then launch SketchUp."
    # echo "  sudo codesign --force --deep --sign - \"$PLUGINS_DIR/UsdExporter.plugin\""
    # [[ -d "$PLUGINS_DIR/UsdImporter.plugin" ]] && \
    # echo "  sudo codesign --force --deep --sign - \"$PLUGINS_DIR/UsdImporter.plugin\""
}

# ── main ──────────────────────────────────────────────────────────────────────

[[ -d "$SKETCHUP_APP" ]] || die "SketchUp not found at: $SKETCHUP_APP"
[[ -d "$BUILDS_DIR"   ]] || die "Builds directory not found at: $BUILDS_DIR"

echo ""
echo "USD IO Version Switcher"
echo "========================"
echo "SketchUp: $SKETCHUP_APP"
echo "Currently installed: $(current_version)"
echo ""
echo "Available versions:"
list_versions
echo ""

[[ ${#VERSIONS[@]} -eq 0 ]] && die "No build versions found in $BUILDS_DIR"

read -rp "Select version [1-${#VERSIONS[@]}]: " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#VERSIONS[@]} )); then
    die "Invalid selection: $choice"
fi

idx=$(( choice - 1 ))
install_version "${VERSIONS[$idx]}" "${VERSION_ROOTS[$idx]}"
