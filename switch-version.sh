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
# Output folder for generated plugin-only zip packages (gitignored).
PACKAGES_DIR="$SCRIPT_DIR/packages"
MADE_PKGS=()  # plugin-only zips produced by generate_packages, for upload

# Discovered build source roots, in priority order (newest/most-local first).
# Each entry pairs a directory with its kind: "dir" = folders hold an
# already-extracted *Darwin* root; "zip" = folders hold a *Darwin*.zip to
# extract on demand into .drive-cache/.
SOURCE_DIRS=()
SOURCE_KINDS=()

SKETCHUP_APPS=()
SKETCHUP_TARGETS=()

# Versions filtered out of the menu because they have no build for the selected
# SketchUp install(s); set SHOW_ALL_VERSIONS=1 (or 'a' at the prompt) to list them.
HIDDEN_VERSIONS=0
SHOW_ALL_VERSIONS="${SHOW_ALL_VERSIONS:-0}"

# True if $1 is a SketchUp application bundle. Identity comes from the bundle's
# CFBundleIdentifier (com.sketchup.SketchUp.<year>), never from the folder or
# app name: installers vary those freely (SketchUp.app, "SketchUp 26.2.app",
# SketchUpPro-2027-0-258-13762/), and name matching silently missed installs.
# This also excludes the LayOut.app that ships alongside every SketchUp.
is_sketchup_app() {
    local app="$1" bundle_id
    [[ -d "$app/Contents" ]] || return 1
    bundle_id=$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null) || return 1
    [[ "$bundle_id" == com.sketchup.SketchUp.* ]]
}

# Bundle version (CFBundleShortVersionString), for disambiguating the menu when
# several installs are all named SketchUp.app. Echoes nothing if unreadable.
sketchup_app_version() {
    defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || true
}

# ── SketchUp build targeting ─────────────────────────────────────────────────
# From 1.0.0 on, JCube ships one build per SketchUp API version rather than one
# build per platform: the artifact name carries a target tag between the commit
# hash and the platform, e.g.
#   SkpXyz-1.0.0-b116e5b-202602-Darwin-Release.zip   (SketchUp 2026.2)
#   SkpXyz-1.0.0-b116e5b-202700-Darwin-Release.zip   (SketchUp 2027)
# Builds are NOT interchangeable — the plugin links against that release's
# SketchUp API — so each install must get the build matching its own version.
# Releases up to 0.8.3 have no tag and are treated as universal (see below).

# The SketchUp release year an app belongs to, from its bundle id
# (com.sketchup.SketchUp.<year>). Echoes the bare year, or nothing if unreadable.
sketchup_app_year() {
    local bundle_id
    bundle_id=$(defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null) || return 0
    echo "${bundle_id##*.}"
}

# The build tag an install needs, derived from its bundle-id year and bundle
# version. Echoes e.g. "202602" or "202700"; empty if it can't be determined.
#
# The tag is <year><minor-as-2-digits>: SketchUp 26.2 -> 202602, and a ".0"
# release gives <year>00 -> 202600.
#
# The 2096 bundle id is the Labs/internal channel, which tracks the NEXT
# release, so it maps to year 2027 (confirmed: "2096 is 27", and SketchUp 96.8
# likewise). Its bundle version counts the Labs build (96.8, 96.10), NOT the
# SketchUp API minor — feeding that through would invent tags like 202708 that
# match no artifact. Labs therefore always pins to <year>00, which is what JCube
# ships for a not-yet-released version; a real 2027 beta installed alongside it
# reports bundle id .2027 and resolves through the normal path.
sketchup_build_tag() {
    local app="$1" year minor
    year=$(sketchup_app_year "$app")
    [[ -n "$year" ]] || return 0
    if [[ "$year" == "2096" ]]; then
        echo "202700"; return 0
    fi
    # Minor comes from the bundle version (26.2 -> 2), defaulting to 0.
    minor=$(sketchup_app_version "$app")
    minor="${minor#*.}"
    [[ "$minor" =~ ^[0-9]+$ ]] || minor=0
    printf '%s%02d' "$year" "$minor"
}

# The build tag carried by a build root/zip name, or empty for untagged
# (pre-1.0.0) builds, which were built against a single SketchUp API and are
# offered for every install.
build_tag_of() {
    local name
    name=$(basename "$1")
    if [[ "$name" =~ SkpXyz-[0-9.]+-[0-9a-f]+-([0-9]{6})- ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

discover_sketchup_apps() {
    # Use if/then (not `[[ ]] && cmd`) — under bash 3.2 + `set -e`, a failing
    # `&&` compound at the top of a function aborts the script.
    local app
    # Scan /Applications and one level down, so both layouts are covered:
    #   flat      /Applications/SketchUp 25.0.app
    #   nested    /Applications/SketchUp 2026/SketchUp 26.2.app
    #             /Applications/SketchUpPro-2027-0-258-13762/SketchUp.app
    # Every .app is tested by bundle id rather than by name (see above), so
    # unconventional installer layouts are picked up without new glob patterns.
    for app in /Applications/*.app /Applications/*/*.app; do
        if is_sketchup_app "$app"; then
            SKETCHUP_APPS+=("$app")
        fi
    done
}

# ── helpers ──────────────────────────────────────────────────────────────────

VERSIONS=()
VERSION_ROOTS=()
VERSION_KINDS=()  # "dir" (extracted root) or "zip" (folder w/ Darwin zip), per entry

PLUGINS_DIR=""
FRAMEWORKS_DIR=""

die() { echo "ERROR: $*" >&2; exit 1; }

# Locate the Python interpreter for sync-releases.py: prefer the repo-local
# venv, else whatever python is on PATH. Echoes the path; returns 1 if none.
find_python() {
    if [[ -x "$SCRIPT_DIR/.venv/bin/python" ]]; then
        echo "$SCRIPT_DIR/.venv/bin/python"; return 0
    elif command -v python3 >/dev/null 2>&1; then
        echo python3; return 0
    elif command -v python >/dev/null 2>&1; then
        echo python; return 0
    fi
    return 1
}

# ── Drive API fallback ─────────────────────────────────────────────────────────
# Last resort, used only when there is no Drive mount and a build isn't already
# staged locally: sync-releases.py lists and downloads builds straight from the
# Deliverables folder over the Drive API.

drive_api_available() {
    [[ -f "$SCRIPT_DIR/sync-releases.py" ]] || return 1
    find_python >/dev/null 2>&1 || return 1
    return 0
}

# Echo raw "label<TAB>win64_zip<TAB>darwin_zip" lines for every Deliverables
# version, or return non-zero on failure (offline, no creds, ...).
# This runs silently in the background of the version listing and its stderr is
# discarded, so it must never start an interactive browser auth — the user would
# see an unexplained hang. NO_INTERACTIVE_AUTH makes an expired token a clean
# failure; the "Check GitLab for new versions" prompt re-auths visibly instead.
get_drive_api_versions() {
    local py
    py=$(find_python) || return 1
    USD_SWITCHER_NO_INTERACTIVE_AUTH=1 \
        "$py" "$SCRIPT_DIR/sync-releases.py" --list-deliverables 2>/dev/null || return 1
}

# Download a version's platform ('win64'|'Darwin') Release zip into
# .drive-cache/incoming/<label>/. Echoes that folder on success (progress goes
# to stderr so it stays off stdout), returns non-zero on failure.
drive_api_download() {
    local label="$1" platform="$2" py dest
    py=$(find_python) || return 1
    dest="$INCOMING_DIR/$label"
    echo "  downloading $label ($platform) from Drive..." >&2
    if ! "$py" "$SCRIPT_DIR/sync-releases.py" --download "$label" "$platform" "$dest" >&2; then
        echo "  (Drive download failed for $label / $platform)" >&2
        return 1
    fi
    echo "$dest"
}

# Optionally pull new SkpXyz releases from the GitLab wiki into Drive so the
# version list below is up to date. Never aborts the switcher on failure.
maybe_sync() {
    local sync_script="$SCRIPT_DIR/sync-releases.py"
    [[ -f "$sync_script" ]] || return 0

    local ans
    read -rp "Check GitLab for new versions and sync to Drive? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || return 0

    local py
    if ! py=$(find_python); then
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
    local i=1 ver tag desc
    for app in "${available[@]}"; do
        ver=$(sketchup_app_version "$app")
        tag=$(sketchup_build_tag "$app")
        desc=""
        [[ -n "$ver" ]] && desc="v$ver"
        # Show which build an install will take, so a mismatch is visible before
        # anything is written.
        [[ -n "$tag" ]] && desc="${desc:+$desc, }build $tag"
        if [[ -n "$desc" ]]; then
            echo "  $i) $app  ($desc)"
        else
            echo "  $i) $app"
        fi
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

# Gather every place a build might live, in priority order (newest/most-local
# first): freshly-synced staging, the checked-in builds/ folder, then the live
# Drive mount as a fallback. list_versions dedups by label across all of them,
# so there's no source to pick — the union is the source. list_versions also
# consults the Drive API as a last resort for versions not visible locally.
discover_sources() {
    if [[ -d "$INCOMING_DIR" ]]; then
        SOURCE_DIRS+=("$INCOMING_DIR");       SOURCE_KINDS+=("zip")
    fi
    if [[ -d "$LOCAL_BUILDS_DIR" ]]; then
        # Resolve symlinks so find works correctly.
        SOURCE_DIRS+=("$(cd "$LOCAL_BUILDS_DIR" && pwd -P)"); SOURCE_KINDS+=("dir")
    fi
    DRIVE_BUILDS_DIR="$(find_drive_builds_dir || true)"
    if [[ -n "$DRIVE_BUILDS_DIR" ]]; then
        SOURCE_DIRS+=("$DRIVE_BUILDS_DIR");   SOURCE_KINDS+=("zip")
    fi

    # The Drive API can surface versions even with no local source at all, so
    # don't die yet if it's available — list_versions will try it.
    (( ${#SOURCE_DIRS[@]} > 0 )) || drive_api_available || \
        die "No build sources found (looked in $LOCAL_BUILDS_DIR, $INCOMING_DIR, and Google Drive)."
}

# Pick the build matching a tag out of newline-separated candidates on stdin.
# Preference order:
#   1. exact tag match          (202602 install -> 202602 build)
#   2. same SketchUp YEAR       (202600 install -> 202602 build)
#   3. untagged/universal build (every release up to 0.8.3)
#
# The minor in a build tag is the SketchUp version the build was compiled
# against, NOT a requirement to match exactly: the SketchUp API is stable across
# a release year, so the 202602 build installs into ANY SketchUp 26 (26.0, 26.1,
# 26.2...). Matching the minor strictly would leave 26.0 with no installable
# 1.0.0 build even though the 202602 one works there.
#
# Echoes nothing only when every candidate is tagged for a different YEAR: that
# stays a hard failure, since a build linked against another release's SketchUp
# API is exactly what this function exists to keep out.
select_by_tag() {
    local want="$1" cand untagged="" same_year="" tag
    while IFS= read -r cand; do
        [[ -n "$cand" ]] || continue
        tag=$(build_tag_of "$cand")
        if [[ -n "$want" && "$tag" == "$want" ]]; then
            echo "$cand"; return 0
        fi
        # Same release year, different minor — usable, but keep looking for an
        # exact match first. Prefer the highest such build.
        if [[ -n "$want" && -n "$tag" && "${tag:0:4}" == "${want:0:4}" ]]; then
            if [[ -z "$same_year" || "$tag" > "$(build_tag_of "$same_year")" ]]; then
                same_year="$cand"
            fi
        fi
        [[ -z "$tag" && -z "$untagged" ]] && untagged="$cand"
    done
    [[ -n "$same_year" ]] && { echo "$same_year"; return 0; }
    # Otherwise fall back to a universal (untagged) build if there is one.
    [[ -n "$untagged" ]] && { echo "$untagged"; return 0; }
    return 1
}

# Returns a Darwin root directory for the given version folder, selecting the
# build that matches $2 (a build tag such as 202602; empty = untagged/universal).
# If the folder already holds a matching extracted *Darwin* root, that's returned
# as-is; otherwise the matching *Darwin*.zip is extracted on demand into
# .drive-cache/. Since 1.0.0 a version folder holds several Darwin builds, one
# per SketchUp API, so every lookup here is tag-filtered.
resolve_darwin_root() {
    local dir="$1" want="${2-}"
    local darwin_root
    darwin_root=$(find "$dir" -maxdepth 1 -type d -name "*Darwin*" 2>/dev/null | select_by_tag "$want")
    if [[ -n "$darwin_root" ]]; then
        echo "$darwin_root"; return 0
    fi

    local zip
    zip=$(find "$dir" -maxdepth 1 -type f -name "*Darwin*.zip" 2>/dev/null | select_by_tag "$want")
    [[ -z "$zip" ]] && return 1

    local label cache
    # Use the dir path relative to its source root as a stable cache key.
    # Staged dirs live under $INCOMING_DIR; Drive-mount dirs under $DRIVE_BUILDS_DIR.
    if [[ "$dir" == "$INCOMING_DIR"/* ]]; then
        label="${dir#$INCOMING_DIR/}"
    elif [[ -n "$DRIVE_BUILDS_DIR" && "$dir" == "$DRIVE_BUILDS_DIR"/* ]]; then
        label="${dir#$DRIVE_BUILDS_DIR/}"
    else
        label="$(basename "$dir")"
    fi
    cache="$DRIVE_CACHE_DIR/${label//\//__}"
    # A 1.0.0+ version folder yields several Darwin roots into the same cache
    # dir (one per SketchUp API), so these lookups filter by tag too — taking
    # the first would hand back a build for the wrong SketchUp.
    darwin_root=$(find "$cache" -maxdepth 1 -type d -name "*Darwin*" 2>/dev/null | select_by_tag "$want")
    if [[ -z "$darwin_root" ]]; then
        mkdir -p "$cache"
        echo "  extracting $(basename "$zip") -> .drive-cache/$label/" >&2
        unzip -q -o "$zip" -d "$cache" >&2 || return 1
        darwin_root=$(find "$cache" -maxdepth 1 -type d -name "*Darwin*" 2>/dev/null | select_by_tag "$want")
    fi
    [[ -n "$darwin_root" ]] && echo "$darwin_root" && return 0
    return 1
}

# True if a folder directly contains an extracted *Darwin* root or a
# *Darwin*.zip — i.e. it's an installable version folder.
has_darwin_build() {
    find "$1" -maxdepth 1 \( -type d -name "*Darwin*" -o -type f -name "*Darwin*.zip" \) 2>/dev/null | grep -q .
}

# Record a version entry. kind is "dir" (folder holds an extracted Darwin root)
# or "zip" (folder holds a Darwin zip, extracted lazily at install time).
add_version() {
    VERSIONS+=("$1")
    VERSION_ROOTS+=("$2")
    VERSION_KINDS+=("$3")
}

# Collect one installable entry into the pending buffer, unless its label was
# already claimed by a higher-priority source. Each buffer line is:
#   <label>\t<kind>\t<root>
# with the label first so the whole buffer can be `sort -Vr`'d by version.
_collect_entry() {
    local label="$1" dir="$2" srckind="$3" root n
    case "$_seen" in *"|$label|"*) return ;; esac
    if [[ "$srckind" == "dir" ]]; then
        # `grep -c` exits 1 on a zero count, which would abort the script under
        # `set -e`; count with wc instead.
        n=$(find "$dir" -maxdepth 1 -type d -name "*Darwin*" 2>/dev/null | wc -l | tr -d ' ')
        if (( n == 0 )); then
            # No extracted root — the folder holds zips, so treat it as a "zip"
            # entry and let resolve_darwin_root extract the right one per app.
            srckind="zip"; root="$dir"
            _pending+=("$label"$'\t'"$srckind"$'\t'"$root")
            _seen="$_seen|$label|"
            return
        fi
        if (( n > 1 )); then
            # 1.0.0+ ships one Darwin root per SketchUp API in the same folder.
            # Which one to install depends on the target app, which isn't known
            # until install time, so record the folder and let resolve_darwin_root
            # pick per app — same as a "zip" entry.
            srckind="zip"; root="$dir"
        else
            root=$(find "$dir" -maxdepth 1 -type d -name "*Darwin*" | head -1)
        fi
    else
        root="$dir"
    fi
    _pending+=("$label"$'\t'"$srckind"$'\t'"$root")
    _seen="$_seen|$label|"
}

# Report whether a version has a build for every selected install. Echoes the
# literal "INCOMPATIBLE" when none of the targets can be served, empty otherwise
# (usable), or a note when only some targets are covered.
#
# Only local entries can be judged: an "api" entry hasn't been downloaded yet,
# so its builds are unknown and it's always treated as usable — the per-app
# resolve at install time is the real gate.
version_compat_note() {
    local kind="$1" root="$2" app tag ok=0 bad=0
    [[ "$kind" == "api" ]] && return 0
    for app in "${SKETCHUP_TARGETS[@]}"; do
        tag=$(sketchup_build_tag "$app")
        if version_has_build_for "$kind" "$root" "$tag"; then
            ok=$((ok + 1))
        else
            bad=$((bad + 1))
        fi
    done
    if (( ok == 0 )); then echo "INCOMPATIBLE"; return 0; fi
    (( bad > 0 )) && echo "  (not for all selected installs)"
    return 0
}

# True if the version at $2 (kind $1) provides a build for tag $3. Purely a name
# check — no extraction — so listing stays cheap.
version_has_build_for() {
    local kind="$1" root="$2" want="$3" dir
    if [[ "$kind" == "dir" ]]; then
        # Single extracted root: it IS the build.
        [[ -n "$(printf '%s\n' "$root" | select_by_tag "$want")" ]] && return 0
        return 1
    fi
    dir="$root"
    [[ -d "$dir" ]] || return 0   # unknown -> don't hide it
    if find "$dir" -maxdepth 1 \( -type d -name "*Darwin*" -o -type f -name "*Darwin*.zip" \) 2>/dev/null \
        | select_by_tag "$want" | grep -q .; then
        return 0
    fi
    return 1
}

# Build a single deduplicated version list across every source in SOURCE_DIRS,
# then sort it strictly newest-first regardless of source. On a duplicate label
# the first (highest-priority) source wins — so a freshly-synced build in
# incoming/ shadows an older copy on the slow Drive mount — but the final list
# is ordered purely by version.
list_versions() {
    local i src srckind dir label sublabel idx=1
    # bash 3.2: no associative arrays, so dedup via a "|label|" token string.
    local _seen="" _pending=()

    for i in "${!SOURCE_DIRS[@]}"; do
        src="${SOURCE_DIRS[$i]}"; srckind="${SOURCE_KINDS[$i]}"
        [[ -d "$src" ]] || continue

        while IFS= read -r -d '' dir; do
            label=$(basename "$dir")
            # Skip anything older than 0.4.0.
            if [[ "$label" =~ [[:space:]]0\.([0-3])\. ]] || [[ "$label" =~ [[:space:]]0\.[0-3]$ ]]; then
                continue
            fi
            if has_darwin_build "$dir"; then
                _collect_entry "$label" "$dir" "$srckind"
            else
                # Descend one level for variant subfolders (e.g. "Using SketchUp libs").
                while IFS= read -r -d '' sub; do
                    has_darwin_build "$sub" || continue
                    sublabel="$label / $(basename "$sub")"
                    _collect_entry "$sublabel" "$sub" "$srckind"
                done < <(find "$dir" -maxdepth 1 -mindepth 1 -type d | tr '\n' '\0')
            fi
        done < <(find "$src" -maxdepth 1 -mindepth 1 -type d | tr '\n' '\0')
    done

    # Drive API fallback (last resort): surface versions that exist on Drive but
    # aren't visible locally. This runs even with a mount present, because Drive
    # for Desktop routinely leaves the folder materialised-but-empty (the path
    # exists but find sees nothing inside) — which would otherwise hide
    # brand-new builds. Anything already found locally is dropped
    # by the _seen dedup, so the API only ADDS missing versions. Buffered like
    # any other entry (kind "api", root "API::<label>") so they sort in by
    # version; the download happens on demand only if one is selected.
    if drive_api_available; then
        echo "  checking Drive for more versions..."
        local lbl win dar
        while IFS=$'\t' read -r lbl win dar; do
            [[ -z "$lbl" ]] && continue
            # Only accept well-formed "<label><TAB><win><TAB><darwin>" rows.
            # Anything else on stdout is not version data — e.g. an OAuth
            # "Please visit this URL to authorize..." prompt, which the auth
            # flow can emit from inside any command when a refresh token has
            # expired. Without this guard such a line became a menu entry.
            [[ -z "$win" || -z "$dar" ]] && continue
            [[ "$lbl" =~ [0-9]+\.[0-9]+ ]] || continue
            case "$_seen" in *"|$lbl|"*) continue ;; esac
            [[ "$dar" == "-" ]] && continue   # need a macOS build to install here
            if [[ "$lbl" =~ [[:space:]]0\.([0-3])\. ]] || [[ "$lbl" =~ [[:space:]]0\.[0-3]$ ]]; then
                continue
            fi
            _pending+=("$lbl"$'\t'"api"$'\t'"API::$lbl")
            _seen="$_seen|$lbl|"
        done < <(get_drive_api_versions | sort -Vr)
    fi

    # Sort the merged buffer newest-first by label (version), then publish.
    # Each entry is annotated with whether it has a build for the selected
    # install(s); unless SHOW_ALL_VERSIONS=1, incompatible ones are hidden.
    local line l_label l_kind l_root note
    while IFS=$'\t' read -r l_label l_kind l_root; do
        [[ -z "$l_label" ]] && continue
        note=$(version_compat_note "$l_kind" "$l_root")
        if [[ "$note" == "INCOMPATIBLE" ]]; then
            if [[ "${SHOW_ALL_VERSIONS:-0}" != "1" ]]; then
                HIDDEN_VERSIONS=$((HIDDEN_VERSIONS + 1))
                continue
            fi
            note="  (no build for this SketchUp)"
        fi
        add_version "$l_label" "$l_root" "$l_kind"
        if [[ "$l_kind" == "api" ]]; then
            echo "  $idx) $l_label  (Drive)$note"
        else
            echo "  $idx) $l_label$note"
        fi
        ((idx++))
    done < <(printf '%s\n' "${_pending[@]}" | sort -Vr)
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
    local path="$1" src
    # Strip whichever source root this path lives under.
    for src in "${SOURCE_DIRS[@]}"; do
        path="${path/#$src\//}"
    done
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
        # -L as well as -e: a symlink whose target was removed earlier in the
        # same pass (the tbb SONAME links) is dangling and fails -e alone.
        if [[ -e "$f" || -L "$f" ]]; then
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

    # The JCube zips lose symlinks, so lib/ carries only the fully-versioned
    # libtbb.12.12.dylib / libtbbmalloc.2.12.dylib — but UsdExporter.plugin and
    # UsdImporter.plugin link against the SONAME (@rpath/libtbb.12.dylib). With no
    # file of that name in Frameworks, dyld refuses to load both plugins and
    # SketchUp silently drops the USD entries from its Import/Export menus.
    # Recreate each dylib's install-name symlink where it is missing.
    local id
    while IFS= read -r f; do
        id=$(otool -D "$f" 2>/dev/null | tail -n 1)
        id=${id##*/}
        [[ -n "$id" && "$id" != "$(basename "$f")" ]] || continue
        [[ -L "$FRAMEWORKS_DIR/$id" && ! -e "$FRAMEWORKS_DIR/$id" ]] && rm -f "$FRAMEWORKS_DIR/$id"
        if [[ ! -e "$FRAMEWORKS_DIR/$id" ]]; then
            echo "  ln -s $(basename "$f") -> $(shorten "$FRAMEWORKS_DIR/$id")"
            ln -s "$(basename "$f")" "$FRAMEWORKS_DIR/$id"
        fi
    done < <(find "$FRAMEWORKS_DIR" -maxdepth 1 -type f -name "libtbb*.dylib")

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

# ── plugin-only packaging ───────────────────────────────────────────────────────
# Builds zip packages that contain ONLY the files needed to install the
# Importer/Exporter plugin into SketchUp. The standalone Converter (bin/) and
# all dev artefacts (include/, src/, doc/, cmake/, SketchUpAPI, import libs) are
# deliberately excluded, so these packages cannot run conversions outside
# SketchUp.

# True if a runtime library living directly under lib/ is a plugin file.
keep_flat_lib() {
    case "$1" in
        SkpXyz.dll|su_usd_ms.dll|skp_usd_ms.dll|tbb12.dll|tbbmalloc.dll) return 0 ;;
        libSkpXyz.dylib|libsu_usd_ms.dylib|libskp_usd_ms.dylib) return 0 ;;
        libtbb*.dylib) return 0 ;;
        *) return 1 ;;
    esac
}

write_install_md() {
    local platform="$1" version="$2"
    if [[ "$platform" == "Windows" ]]; then
        echo "# SkpXyz USD Plugin for SketchUp — $version (Windows)"
        cat <<'EOF'

This package contains ONLY the SketchUp USD (TUSD) import/export plugin and
its runtime libraries. The standalone command-line Converter is deliberately
NOT included; this package cannot run conversions outside SketchUp.

## Install

Copy the plugin DLLs:

    lib\Exporters\UsdExporter.dll
    lib\Importers\UsdImporter.dll

and the runtime files:

    lib\SkpXyz.dll
    lib\su_usd_ms.dll
    lib\tbb12.dll
    lib\tbbmalloc.dll
    lib\usd\          (the whole folder)

into BOTH the Exporters and Importers folders of your SketchUp install, e.g.:

    C:\Program Files\SketchUp\SketchUp 2026\SketchUp\Exporters
    C:\Program Files\SketchUp\SketchUp 2026\SketchUp\Importers

(Older layouts put these directly under the version dir:
 ...\SketchUp 2024\Exporters and ...\SketchUp 2024\Importers.)

Then launch SketchUp and use File -> Import / Export; choose the TUSD format.
EOF
    else
        echo "# SkpXyz USD Plugin for SketchUp — $version (macOS)"
        cat <<'EOF'

This package contains ONLY the SketchUp USD (TUSD) import/export plugin and
its runtime libraries. The standalone command-line Converter is deliberately
NOT included; this package cannot run conversions outside SketchUp.

## Install

Copy the plugin bundles:

    lib/Exporters/UsdExporter.plugin
    lib/Importers/UsdImporter.plugin

into:

    <SketchUp.app>/Contents/PlugIns

and the runtime libraries:

    lib/libSkpXyz.dylib
    lib/libsu_usd_ms.dylib
    lib/libtbb*.dylib

into:

    <SketchUp.app>/Contents/Frameworks

then, in Contents/Frameworks, recreate the SONAME symlinks the zip does not carry
(the plugins link against these names; without them SketchUp silently shows no
USD import/export option):

    ln -s libtbb.12.12.dylib      libtbb.12.dylib
    ln -s libtbbmalloc.2.12.dylib libtbbmalloc.2.dylib

(`otool -D lib/libtbb*.dylib` prints the exact names a given build expects.)

The Frameworks/usd entry in the SketchUp bundle is a symlink to Resources/usd.
Back up the existing Resources/usd folder (e.g. to Resources/usd-simlab), then
copy this package's

    lib/usd

into <SketchUp.app>/Contents/Resources.

You may need to disable macOS security or codesign the copied binaries. Then
launch SketchUp and use File -> Import / Export; choose the TUSD format.
EOF
    fi
}

# Echo a usable build root dir for a platform, extracting a release zip into a
# temp dir on demand. Temp dirs are recorded in PKG_TMP_DIRS for cleanup.
# Echo EVERY platform root in a version folder, one per line — a 1.0.0+ folder
# holds one per SketchUp API. Extracted dirs are preferred; otherwise each
# matching zip is extracted to its own temp dir (so same-named roots from
# different zips don't collide).
all_platform_roots() {
    local folder="$1" dir_pat="$2" zip_pat="$3" d z tmp found=0
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        echo "$d"; found=1
    done < <(find "$folder" -maxdepth 1 -type d -name "$dir_pat" 2>/dev/null | sort)
    (( found )) && return 0

    while IFS= read -r z; do
        [[ -n "$z" ]] || continue
        tmp=$(mktemp -d)
        PKG_TMP_DIRS+=("$tmp")
        unzip -q -o "$z" -d "$tmp" >/dev/null 2>&1 || continue
        while IFS= read -r d; do
            [[ -n "$d" ]] && echo "$d"
        done < <(find "$tmp" -maxdepth 1 -type d -name "$dir_pat" 2>/dev/null | sort)
    done < <(find "$folder" -maxdepth 1 -type f -name "$zip_pat" 2>/dev/null | sort)
    return 0
}

get_platform_root() {
    local folder="$1" dir_pat="$2" zip_pat="$3" d z tmp
    d=$(find "$folder" -maxdepth 1 -type d -name "$dir_pat" 2>/dev/null | head -1)
    if [[ -n "$d" ]]; then echo "$d"; return 0; fi
    z=$(find "$folder" -maxdepth 1 -type f -name "$zip_pat" 2>/dev/null | head -1)
    if [[ -n "$z" ]]; then
        tmp=$(mktemp -d)
        PKG_TMP_DIRS+=("$tmp")
        unzip -q -o "$z" -d "$tmp" >/dev/null 2>&1 || return 1
        d=$(find "$tmp" -maxdepth 1 -type d -name "$dir_pat" 2>/dev/null | head -1)
        if [[ -n "$d" ]]; then echo "$d"; return 0; fi
    fi
    return 1
}

# Copy the allow-listed plugin files out of a build root and zip them. cp -R and
# zip -y preserve permissions and symlinks, so macOS bundles stay valid. Echoes
# the number of plugin items copied.
build_plugin_package() {
    local platform="$1" root="$2" top="$3" out="$4" version="$5"
    local stage dst kept=0 f base sub
    stage=$(mktemp -d)
    dst="$stage/$top/lib"
    mkdir -p "$dst"

    for sub in Exporters Importers usd su_usd skp_usd; do
        if [[ -e "$root/lib/$sub" ]]; then
            cp -R "$root/lib/$sub" "$dst/"
            kept=$((kept + 1))
        fi
    done
    for f in "$root"/lib/*; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f")
        if keep_flat_lib "$base"; then
            cp "$f" "$dst/"
            kept=$((kept + 1))
        fi
    done

    [[ -f "$root/CHANGELOG.md" ]] && cp "$root/CHANGELOG.md" "$stage/$top/"
    write_install_md "$platform" "$version" > "$stage/$top/INSTALL.md"

    if (( kept > 0 )); then
        ( cd "$stage" && zip -ry "$out" "$top" >/dev/null )
    fi
    rm -rf "$stage"
    echo "$kept"
}

generate_packages() {
    local label="$1" version_root="$2" kind="$3" folder
    # "zip" entries point at the version folder (holds the platform zips);
    # "dir" entries point at the extracted Darwin root, so step up one level.
    if [[ "$kind" == "zip" ]]; then
        folder="$version_root"
    else
        folder="$(dirname "$version_root")"
    fi

    mkdir -p "$PACKAGES_DIR"
    PKG_TMP_DIRS=()
    MADE_PKGS=()
    local made=0 spec pname dpat zpat apiplat root top out kept t dl

    # name | extracted-dir glob | release-zip glob | Drive-API platform token
    local specs=(
        "Windows|*win64-Release*|*win64-Release*.zip|win64"
        "macOS|*Darwin-Release*|*Darwin-Release*.zip|Darwin"
    )
    for spec in "${specs[@]}"; do
        IFS='|' read -r pname dpat zpat apiplat <<<"$spec"
        # Since 1.0.0 a version holds one build per SketchUp API per platform, so
        # package EVERY matching source, not just the first — otherwise only one
        # SketchUp target would get a package.
        local srcdir="$folder" roots=() r
        if ! get_platform_root "$folder" "$dpat" "$zpat" >/dev/null 2>&1; then
            # Drive API fallback: a platform missing locally (e.g. an API-only
            # version fetched for the other platform's install) is downloaded now.
            if drive_api_available && dl=$(drive_api_download "$(basename "$folder")" "$apiplat"); then
                srcdir="$dl"
            fi
        fi
        while IFS= read -r r; do
            [[ -n "$r" ]] && roots+=("$r")
        done < <(all_platform_roots "$srcdir" "$dpat" "$zpat")

        if (( ${#roots[@]} == 0 )); then
            echo "  ($pname: no source found — skipped)"
            continue
        fi
        for root in "${roots[@]}"; do
            top="$(basename "$root")-plugin-only"
            out="$PACKAGES_DIR/$top.zip"
            echo "  building $pname plugin-only package from $(basename "$root")..."
            rm -f "$out"
            kept=$(build_plugin_package "$pname" "$root" "$top" "$out" "$label")
            if (( kept > 0 )); then
                made=$((made + 1))
                MADE_PKGS+=("$out")
                echo "    -> packages/$top.zip  ($kept plugin items)"
            else
                echo "    ($pname: no plugin files found — skipped)"
                rm -f "$out"
            fi
        done
    done

    for t in "${PKG_TMP_DIRS[@]:-}"; do
        [[ -n "$t" ]] && rm -rf "$t"
    done

    if (( made == 0 )); then
        echo "No plugin-only packages were generated."
    else
        echo ""
        echo "Generated $made plugin-only package(s) in $PACKAGES_DIR"
    fi
}

# Push generated plugin-only zips to their per-version Deliverables subfolder on
# Drive (via sync-releases.py's Drive API path). Never aborts on failure.
maybe_upload() {
    local sync_script="$SCRIPT_DIR/sync-releases.py" ans py
    [[ ${#MADE_PKGS[@]} -eq 0 ]] && return 0
    [[ -f "$sync_script" ]] || return 0

    echo ""
    read -rp "Upload the plugin-only package(s) to the Drive Deliverables subfolder? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || return 0

    if ! py=$(find_python); then
        echo "  python not found — skipping upload." >&2
        return 0
    fi

    echo "Uploading to Drive..."
    if ! "$py" "$sync_script" --upload-plugin "${MADE_PKGS[@]}"; then
        echo "  (upload failed — packages are still available in $PACKAGES_DIR)" >&2
    fi
}

maybe_package() {
    local label="$1" version_root="$2" kind="$3" ans
    echo ""
    read -rp "Also generate plugin-only zip package(s) for $label (Windows + macOS)? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || return 0
    echo ""
    echo "Generating plugin-only packages (Converter excluded)..."
    generate_packages "$label" "$version_root" "$kind"
    maybe_upload
}

# ── main ──────────────────────────────────────────────────────────────────────

echo ""
echo "USD IO Version Switcher"
echo "========================"
echo ""

maybe_sync
echo ""

discover_sources

echo ""
pick_sketchup

echo ""
echo "Available versions:"
list_versions
echo ""

# Versions with no build for the selected install(s) are hidden by default.
# Offer them explicitly rather than silently pretending they don't exist.
if (( HIDDEN_VERSIONS > 0 )); then
    echo "  ($HIDDEN_VERSIONS version(s) hidden: no build for the selected SketchUp — enter 'a' to show them)"
    echo ""
fi

[[ ${#VERSIONS[@]} -eq 0 && $HIDDEN_VERSIONS -eq 0 ]] && die "No build versions found."

read -rp "Select version [1-${#VERSIONS[@]}${HIDDEN_VERSIONS:+/a}]: " choice

# 'a' re-lists with incompatible versions included, so one can be forced.
if [[ "$choice" == "a" ]]; then
    SHOW_ALL_VERSIONS=1
    VERSIONS=(); VERSION_ROOTS=(); VERSION_KINDS=(); HIDDEN_VERSIONS=0
    echo ""
    echo "All versions:"
    list_versions
    echo ""
    read -rp "Select version [1-${#VERSIONS[@]}]: " choice
fi

[[ ${#VERSIONS[@]} -eq 0 ]] && die "No build versions found."

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#VERSIONS[@]} )); then
    die "Invalid selection: $choice"
fi

idx=$(( choice - 1 ))

# An "api" selection has no local copy: download it into incoming/ first, which
# turns it into an ordinary "zip" entry pointing at the staged folder. Done once,
# up front, so both the install loop and packaging reuse the same download.
if [[ "${VERSION_KINDS[$idx]}" == "api" ]]; then
    api_label="${VERSION_ROOTS[$idx]#API::}"
    echo ""
    echo "Fetching $api_label from Drive (no local copy found)..."
    if ! dl=$(drive_api_download "$api_label" "Darwin"); then
        die "Could not download $api_label from Drive."
    fi
    VERSION_ROOTS[$idx]="$dl"
    VERSION_KINDS[$idx]="zip"
fi

# Resolution happens per app, not once: since 1.0.0 a version carries one build
# per SketchUp API, so the right one depends on which app is being written to.
# "dir" entries still point straight at a single extracted root (pre-1.0.0
# layout); everything else resolves by the target app's build tag.
installed_any=0
for SKETCHUP_APP in "${SKETCHUP_TARGETS[@]}"; do
    PLUGINS_DIR="$SKETCHUP_APP/Contents/PlugIns"
    FRAMEWORKS_DIR="$SKETCHUP_APP/Contents/Frameworks"
    echo ""
    echo ">>> $(basename "$SKETCHUP_APP")"
    echo "    Currently installed: $(current_version)"

    app_tag=$(sketchup_build_tag "$SKETCHUP_APP")
    darwin_root="${VERSION_ROOTS[$idx]}"
    if [[ "${VERSION_KINDS[$idx]}" == "zip" ]]; then
        if ! darwin_root=$(resolve_darwin_root "$darwin_root" "$app_tag"); then
            # A tagged install with no matching build must not fall back to a
            # build for another SketchUp API — skip it and keep going, so the
            # other selected apps still get installed.
            echo "    SKIPPED: ${VERSIONS[$idx]} has no build for SketchUp ${app_tag:-(unknown)}." >&2
            continue
        fi
    fi

    echo "    Build: $(basename "$darwin_root")"
    install_version "${VERSIONS[$idx]}" "$darwin_root"
    installed_any=1
done

if (( installed_any == 0 )); then
    die "${VERSIONS[$idx]} has no build matching any of the selected SketchUp installs."
fi

maybe_package "${VERSIONS[$idx]}" "${VERSION_ROOTS[$idx]}" "${VERSION_KINDS[$idx]}"
