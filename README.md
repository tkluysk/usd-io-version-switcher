# USD IO Version Switcher

Swap which version of the SkpXyz USD Exporter/Importer plugin is installed
into one or more SketchUp apps. Builds can come from a local `builds/`
folder or from the JCube `Deliverables` folder on Google Drive.

## Layout

| File                   | What it does                                                             |
| ---------------------- | ------------------------------------------------------------------------ |
| `switch-version.ps1`   | Windows switcher. Requires Admin (writes under `C:\Program Files\`).     |
| `switch-version.sh`    | macOS switcher.                                                          |
| `Launch Switcher.bat`  | Windows entry point — UAC-elevates and runs the PS1.                     |
| `USD IO Switcher.app/` | macOS entry point — Finder-launchable wrapper around `switch-version.sh`. |
| `sync-releases.py`     | Mirrors new SkpXyz zips from the GitLab wiki into the Drive Deliverables folder; also uploads generated plugin-only packages (`--upload-plugin`). |

## Using the switcher

### Windows

After cloning, run once to install a Start Menu entry:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Shortcut.ps1
```

That puts `USD IO Switcher.lnk` in `%APPDATA%\Microsoft\Windows\Start Menu\Programs\`
(no Desktop clutter). The shortcut launches `switch-version.ps1` with the
"Run as administrator" bit set, so a UAC prompt appears on use.

**Pin to taskbar:** open Start, search "USD IO Switcher", right-click the
result → Pin to taskbar.

To run the switcher: click the Start Menu / taskbar entry (or
double-click `Launch Switcher.bat` for the same effect). Approve the UAC
prompt, pick a SketchUp install and a version. There's no source to choose —
the switcher merges every available source (see below) into one deduplicated,
newest-first version list. The script removes the previously installed plugin
files first, then copies the new ones.

The switcher auto-detects:

- **Drive letter** — scans all ready drives for
  `<drive>\My Drive\Projects & Clients\JCube\Deliverables`. Works with G:,
  H:, or wherever Google Drive for Desktop is mounted.
- **SketchUp installs** under `C:\Program Files\SketchUp\` — supports both
  the SketchUp 2024 layout (`<ver>\Exporters`, `<ver>\Importers`) and the
  2026+ nested layout (`<ver>\SketchUp\Exporters`, `<ver>\SketchUp\Importers`).

When sourcing from Drive, zips are extracted on demand to `.drive-cache\`
inside the repo.

Versions just pulled by the sync step are staged under
`.drive-cache\incoming\` and count as a source on their own — so a
freshly-synced build is usable immediately even when Google Drive for Desktop
isn't mounted (or hasn't surfaced the file yet).

**The version list is the union of every available source, deduped by version
(a `.drive-cache\incoming\` copy shadows an older one on the slow mount) and
sorted newest-first.** Resolving the *selected* build then follows three lines
of defence, cheapest first:

1. **Local cache** — an already-extracted build in `.drive-cache\`, or a zip
   staged in `.drive-cache\incoming\` (extracted on demand).
2. **Drive mount** — the Google Drive for Desktop mount, when present.
3. **Drive API** — versions on Drive that aren't visible locally are listed
   over the Drive API (tagged `(Drive)` in the menu) and the selected one is
   downloaded straight into `.drive-cache\incoming\` on demand. The API is
   consulted *even when the mount is present*, because Drive for Desktop
   routinely leaves a folder present-but-empty and would otherwise hide
   brand-new builds. It needs the same OAuth setup as the sync step; if it's
   unavailable (offline / no creds) the switcher silently uses whatever is
   local.

### macOS

Run `switch-version.sh` (or double-click `USD IO Switcher.app`). SketchUp
installs are auto-discovered under `/Applications` (and one level down), each
identified by its bundle id (`com.sketchup.SketchUp.<year>`) rather than by app
or folder name, so unconventional installer layouts are still found.

## Per-SketchUp builds (1.0.0 and later)

From **1.0.0**, JCube ships one build **per SketchUp API version** instead of
one per platform. The target is encoded in the artifact name, between the commit
hash and the platform:

```
SkpXyz-1.0.0-b116e5b-202602-Darwin-Release.zip   -> SketchUp 26 (built against 26.2)
SkpXyz-1.0.0-b116e5b-202700-Darwin-Release.zip   -> SketchUp 27 (built against 27.0)
```

So a single release is 6 artifacts (4 Release + 2 Debug) rather than 3.

**Builds are not interchangeable across release years** — each links against
that year's SketchUp API — so the switcher resolves the build **per install**,
not once per run. Selecting "all" installs a different build into each SketchUp
in the same pass:

```
>>> SketchUp 26.2.app
    Build: SkpXyz-1.0.0-b116e5b-202602-Darwin-Release
>>> SketchUp Labs.app
    Build: SkpXyz-1.0.0-b116e5b-202700-Darwin-Release
```

**The minor in a tag is what the build was compiled against, not a strict
requirement.** The SketchUp API is stable within a release year, so the `202602`
build installs into **any** SketchUp 26 — 26.0, 26.1, 26.2. Matching is
therefore:

1. exact tag (`202602` install → `202602` build);
2. otherwise the highest build of the **same year** (`202600` install → `202602`
   build);
3. otherwise an untagged/universal build.

Only a mismatched **year** is refused, so a SketchUp 25 install gets no 1.0.0
build at all.

How the target tag is derived:

- **macOS** — bundle id gives the year, `CFBundleShortVersionString` the minor
  (26.2 → `202602`).
- **Windows** — the install folder gives the year, `SketchUp.exe`'s file version
  the minor.
- **SketchUp Labs / internal builds** (bundle id `com.sketchup.SketchUp.2096`,
  e.g. "SketchUp 96.8") track the *next* release, so they map to `202700`. Their
  bundle version counts the Labs build, not the API minor, so it is ignored.

Versions with **no build for the selected install** are hidden from the menu;
the prompt offers `a` to list them anyway. Even when forced, an install is
skipped rather than given a build from a different SketchUp year. Releases up to
**0.8.3** carry no tag, are treated as universal, and still install everywhere.

## Plugin-only packages (optional)

After installing a version, the switcher offers to build **plugin-only zip
packages** for it:

```
Also generate plugin-only zip package(s) for <version> (Windows + macOS)? [y/N]
```

These packages contain only what's needed to install the SketchUp USD (TUSD)
import/export plugin — the `lib/Exporters`, `lib/Importers`, runtime libraries
and `usd/` resources the switcher itself installs — plus a generated
`INSTALL.md`. The standalone command-line **Converter** (`bin/`) and all dev
artefacts (`include/`, `src/`, `doc/`, `cmake/`, the bundled `SketchUpAPI`,
import libs) are deliberately excluded, so a plugin-only package cannot run
conversions outside SketchUp.

- Both `win64-Release` and `Darwin-Release` are packaged regardless of which OS
  you run the switcher on; Debug builds are ignored.
- **Every** build is packaged, not just one per platform: from 1.0.0 that means
  one package per SketchUp target per platform (so 1.0.0 yields 4 packages —
  `202602` and `202700` × Windows and macOS).
- Output goes to `packages/` in the repo (gitignored), named
  `SkpXyz-<ver>-<hash>[-<sketchup>]-<platform>-Release-plugin-only.zip`.
- File contents are copied byte-for-byte, so existing macOS code signatures
  stay intact. When the macOS package is built on Windows, Unix exec bits are
  not reproduced (harmless — SketchUp loads the plugin binaries via `dlopen`,
  and `INSTALL.md` covers codesigning); build it on macOS for full permissions.

The switcher then offers to **upload** the generated zips to Drive:

```
Upload the plugin-only package(s) to the Drive Deliverables subfolder? [y/N]
```

Upload uses the same Drive API path as the sync step below (so the one-time
setup there is required), placing each zip in its matching
`Exporter & Importer <version>` Deliverables subfolder. Re-runs are idempotent —
a zip already present on Drive is skipped.

## sync-releases.py (optional)

Pulls new `SkpXyz-*-win64-Release.zip` / `*-Darwin*.zip` from the
`jcube/t-support` GitLab wiki and uploads any that aren't already in the
Drive `Deliverables` folder (creating per-version subfolders).

The switcher can run this for you: answer `y` at the **"Check GitLab for
new versions"** prompt on startup, and it syncs to Drive before listing
versions. The setup below is required for that to work.

### One-time setup

1. **Install Python 3.12+** and the Google client libs into a repo-local
   virtualenv (keeps them out of the system/Homebrew Python, which avoids
   PEP 668 "externally managed" errors and cross-project clobbering). The
   switcher auto-detects `.venv/` and prefers it over the system Python.

   macOS:

   ```bash
   python3 -m venv .venv
   ./.venv/bin/python -m pip install google-api-python-client google-auth google-auth-oauthlib
   ```

   Windows:

   ```powershell
   winget install --id Python.Python.3.12 --scope user
   python -m venv .venv
   .\.venv\Scripts\python -m pip install google-api-python-client google-auth google-auth-oauthlib
   ```

2. **Google OAuth client secret.** The OAuth client is hosted on the
   **Mergence Google Cloud account** (sign in there to manage it). To
   re-download or rotate: console.cloud.google.com → APIs & Services
   → Credentials → the "USD Switcher" Desktop OAuth 2.0 Client ID →
   Download JSON.

3. **GitLab personal access token** — scopes `read_api` +
   `read_repository`. Save the single-line token to
   `~/.config/usd-switcher/gitlab-token` (or set `$env:GITLAB_WIKI_TOKEN`).

4. **Run the auth flow** once, **in a real PowerShell window** (not
   through Claude Code or any other tool that wraps it in
   `-EncodedCommand` — Trimble's Bitdefender will silently kill that):

   ```powershell
   .\.venv\Scripts\python sync-releases.py --auth --client-secret <path-to-client_secret_*.json>
   ```

   A browser opens; sign in as `tom_kluyskens@trimble.com`. After
   success the credentials are written to:

   - `~/.config/usd-switcher/gdrive-credentials.json` — the OAuth user
     token (refreshable).
   - `~/.config/usd-switcher/gdrive-client-secret.json` — a copy of the
     client secret for future token refreshes.

   These file names are the canonical location — other repos read the
   same files; keep the names intact when copying between machines.

### Re-auth cadence

The Mergence GCP OAuth client is currently in **"Testing"** status,
and Google caps refresh tokens for Testing-status clients at **7 days**
— after that, any refresh call fails with `invalid_grant: Token has
been expired or revoked.`

`sync-releases.py` self-heals: when it sees `invalid_grant` it
automatically re-launches the browser auth flow, then continues the
sync. You'll see a one-line `[auth] Refresh token revoked or expired
— re-running browser auth.` message in the terminal and a browser
window will pop up; sign in again and it carries on. The 7-day cadence
is therefore expected, not a bug.

To make it stop: publish the OAuth app on Mergence GCP (console
→ APIs & Services → OAuth consent screen → Publish app). Drive is a
sensitive scope so Google will ask for verification — that's the only
way to remove the 7-day cap.

### Daily use

Easiest is to answer `y` at the switcher's startup prompt. To run it
directly:

```bash
./.venv/bin/python sync-releases.py          # macOS
.\.venv\Scripts\python sync-releases.py      # Windows
```

Sparse-clones (or fast-forwards) the wiki to `~/.cache/usd-switcher/wiki/`,
parses `Installation.md` for the **Latest Package** section, and uploads
any zips not already in Drive.
