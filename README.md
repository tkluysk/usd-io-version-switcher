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
prompt. Pick a source (local `builds/` or Google Drive), a SketchUp
install, and a version. The script removes the previously installed
plugin files first, then copies the new ones.

The switcher auto-detects:

- **Drive letter** — scans all ready drives for
  `<drive>\My Drive\Projects & Clients\JCube\Deliverables`. Works with G:,
  H:, or wherever Google Drive for Desktop is mounted.
- **SketchUp installs** under `C:\Program Files\SketchUp\` — supports both
  the SketchUp 2024 layout (`<ver>\Exporters`, `<ver>\Importers`) and the
  2026+ nested layout (`<ver>\SketchUp\Exporters`, `<ver>\SketchUp\Importers`).

When sourcing from Drive, zips are extracted on demand to `.drive-cache\`
inside the repo.

### macOS

Run `switch-version.sh` (or double-click `USD IO Switcher.app`). The
script targets the SketchUp apps hard-coded near the top of the file.

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
- Output goes to `packages/` in the repo (gitignored), named
  `SkpXyz-<ver>-<hash>-<platform>-Release-plugin-only.zip`.
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
