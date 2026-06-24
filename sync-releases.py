#!/usr/bin/env python3
"""Sync the latest SkpXyz release zips from the t-support GitLab wiki
to the Google Drive Deliverables folder (via the Drive REST API).

Setup (one-time):
  python3 sync-releases.py --auth --client-secret ~/Downloads/client_secret_*.json
  Sign in as tom_kluyskens@trimble.com in the browser. Credentials stored at
  ~/.config/usd-switcher/gdrive-credentials.json

GitLab token (needs read_api + read_repository scope):
  File:    ~/.config/usd-switcher/gitlab-token  (one line)
  Env var: GITLAB_WIKI_TOKEN

Wiki is sparse-cloned at ~/.cache/usd-switcher/wiki/
"""
from __future__ import annotations

import argparse
import io
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# ── paths & constants ─────────────────────────────────────────────────────────

WIKI_URL       = "https://oauth2:{token}@gitlab.com/jcube/t-support.wiki.git"
WIKI_DIR       = Path.home() / ".cache" / "usd-switcher" / "wiki"
GITLAB_TOKEN_FILE = Path.home() / ".config" / "usd-switcher" / "gitlab-token"
GDRIVE_CREDS_FILE = Path.home() / ".config" / "usd-switcher" / "gdrive-credentials.json"

# Repo-local staging dir for just-uploaded Release zips, so the switcher
# can use a new version immediately instead of waiting for Drive for Desktop
# to surface it in the local CloudStorage mount.
SCRIPT_DIR    = Path(__file__).resolve().parent
INCOMING_DIR  = SCRIPT_DIR / ".drive-cache" / "incoming"

# Drive folder ID for the Deliverables folder
DELIVERABLES_FOLDER_ID = "1uh930UJISCCTwvV1Xk2Fdgo7Y_I-D8zH"

SCOPES = ["https://www.googleapis.com/auth/drive"]

CLIENT_SECRET_FILE = Path.home() / ".config" / "usd-switcher" / "gdrive-client-secret.json"


# ── Drive auth ────────────────────────────────────────────────────────────────

def _gdrive_service():
    from google.auth.exceptions import RefreshError
    from google.oauth2.credentials import Credentials
    from googleapiclient.discovery import build

    if not GDRIVE_CREDS_FILE.exists():
        raise RuntimeError(
            "Not authenticated. Run:  python3 sync-releases.py --auth"
        )

    # Load whatever scopes the file already has rather than forcing SCOPES,
    # so a token broadened by another tool (e.g. a sibling repo that also
    # needs Sheets) doesn't get narrowed back to Drive-only on refresh.
    creds = Credentials.from_authorized_user_file(str(GDRIVE_CREDS_FILE))
    if not creds.valid and creds.expired and creds.refresh_token:
        from google.auth.transport.requests import Request
        try:
            creds.refresh(Request())
            _save_creds(creds)
        except RefreshError as e:
            # Refresh tokens for OAuth clients still in "Testing" status are
            # revoked by Google after 7 days, surfacing as invalid_grant here.
            # Self-heal by re-running the browser auth flow.
            if "invalid_grant" not in str(e):
                raise
            print(
                "[auth] Refresh token revoked or expired - re-running browser auth.\n"
                "       (Google caps refresh tokens at 7 days for Testing-status OAuth\n"
                "        clients. Publish the OAuth app on Mergence GCP to remove the cap.)",
                file=sys.stderr,
            )
            do_auth()
            creds = Credentials.from_authorized_user_file(str(GDRIVE_CREDS_FILE))
    return build("drive", "v3", credentials=creds)


def _save_creds(creds):
    GDRIVE_CREDS_FILE.parent.mkdir(parents=True, exist_ok=True)
    GDRIVE_CREDS_FILE.write_text(creds.to_json())
    GDRIVE_CREDS_FILE.chmod(0o600)


def do_auth(client_secret_path: Path | None = None):
    from google_auth_oauthlib.flow import InstalledAppFlow

    src = client_secret_path or CLIENT_SECRET_FILE
    if not src.exists():
        print(
            f"Client secret file not found: {src}\n"
            "Pass it with:  python3 sync-releases.py --auth --client-secret <path>\n"
            "Download it from: https://console.cloud.google.com/ → APIs & Services → Credentials"
        )
        sys.exit(1)

    flow = InstalledAppFlow.from_client_secrets_file(str(src), SCOPES)
    creds = flow.run_local_server(port=0)
    _save_creds(creds)
    # Copy the client secret to its canonical location for future refreshes,
    # unless src already IS the canonical location (Windows shutil.copy2 of a
    # file onto itself raises a sharing violation).
    if src.resolve() != CLIENT_SECRET_FILE.resolve():
        import shutil
        CLIENT_SECRET_FILE.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, CLIENT_SECRET_FILE)
    print(f"Credentials saved to {GDRIVE_CREDS_FILE}")


# ── Drive helpers ─────────────────────────────────────────────────────────────

def _list_folder(service, folder_id: str) -> list[dict]:
    items, page_token = [], None
    while True:
        resp = service.files().list(
            q=f"'{folder_id}' in parents and trashed = false",
            fields="nextPageToken, files(id, name, mimeType)",
            pageToken=page_token,
            supportsAllDrives=True,
            includeItemsFromAllDrives=True,
        ).execute()
        items.extend(resp.get("files", []))
        page_token = resp.get("nextPageToken")
        if not page_token:
            break
    return items


def _get_or_create_folder(service, parent_id: str, name: str) -> str:
    items = _list_folder(service, parent_id)
    for item in items:
        if item["name"] == name and item["mimeType"] == "application/vnd.google-apps.folder":
            return item["id"]
    meta = {"name": name, "mimeType": "application/vnd.google-apps.folder",
            "parents": [parent_id]}
    folder = service.files().create(
        body=meta, fields="id",
        supportsAllDrives=True,
    ).execute()
    return folder["id"]


def _existing_zip_names(service, folder_id: str) -> set[str]:
    """All zip filenames already present anywhere under folder_id."""
    names = set()
    for item in _list_folder(service, folder_id):
        if item["mimeType"] == "application/vnd.google-apps.folder":
            for child in _list_folder(service, item["id"]):
                if child["name"].endswith(".zip"):
                    names.add(child["name"])
        elif item["name"].endswith(".zip"):
            names.add(item["name"])
    return names


def _upload_zip(service, parent_folder_id: str, name: str, data: bytes):
    from googleapiclient.http import MediaIoBaseUpload
    media = MediaIoBaseUpload(io.BytesIO(data), mimetype="application/zip",
                              resumable=True, chunksize=8 * 1024 * 1024)
    meta = {"name": name, "parents": [parent_folder_id]}
    request = service.files().create(
        body=meta, media_body=media, fields="id",
        supportsAllDrives=True,
    )
    response = None
    while response is None:
        status, response = request.next_chunk()
        if status:
            pct = int(status.progress() * 100)
            print(f"\r  {pct}%", end="", flush=True)
    print()
    return response["id"]


# ── GitLab wiki ───────────────────────────────────────────────────────────────

def _read_gitlab_token() -> str:
    tok = os.environ.get("GITLAB_WIKI_TOKEN", "").strip()
    if tok:
        return tok
    if GITLAB_TOKEN_FILE.exists():
        tok = GITLAB_TOKEN_FILE.read_text().strip()
        if tok:
            return tok
    raise RuntimeError(
        f"No GitLab token. Set $GITLAB_WIKI_TOKEN or write it to {GITLAB_TOKEN_FILE}"
    )


def _git(args: list[str], cwd: Path, check: bool = True):
    return subprocess.run(
        ["git"] + args, cwd=cwd,
        env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
        check=check, text=True, capture_output=True,
    )


def ensure_wiki(token: str) -> Path:
    url = WIKI_URL.format(token=token)
    if not (WIKI_DIR / ".git").exists():
        print("[sync] cloning wiki (sparse, no blobs)...")
        WIKI_DIR.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["git", "clone", "--depth=1", "--filter=blob:none", "--sparse",
             url, str(WIKI_DIR)],
            env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
            check=True, text=True,
        )
    else:
        _git(["remote", "set-url", "origin", url], cwd=WIKI_DIR)
        print("[sync] updating wiki...")
        _git(["fetch", "--depth=1", "origin"], cwd=WIKI_DIR)
        _git(["reset", "--hard", "FETCH_HEAD"], cwd=WIKI_DIR)
    return WIKI_DIR


def parse_latest_zips(md_text: str) -> list[tuple[str, str, str]]:
    """Return (version, zip_filename, git_path) for all non-struck-through zips
    in the Latest Package section."""
    m = re.search(r'^#+\s*Latest Package', md_text, re.MULTILINE | re.IGNORECASE)
    if not m:
        return []
    section = md_text[m.start():]
    cut = re.search(r'\n(---+|#{1,2}\s+Older)', section[1:])
    if cut:
        section = section[: cut.start() + 1]

    results = []
    for lm in re.finditer(
        r'(?<!~)\[([^\]]+\.zip)\]\((uploads/[^)]+\.zip)\)(?!~)',
        section,
    ):
        zip_name = lm.group(1)
        git_path = lm.group(2)
        ver_m = re.search(r'SkpXyz-(\d+\.\d+(?:\.\d+)*)-', zip_name)
        version = ver_m.group(1) if ver_m else "unknown"
        results.append((version, zip_name, git_path))
    return results


def fetch_zip_bytes(wiki_dir: Path, git_path: str) -> bytes:
    r = subprocess.run(
        ["git", "show", f"HEAD:{git_path}"],
        cwd=wiki_dir,
        env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
        capture_output=True, check=True,
    )
    return r.stdout


def _upload_local_file(service, parent_folder_id: str, path: Path) -> str:
    """Upload an on-disk file to a Drive folder (resumable)."""
    from googleapiclient.http import MediaFileUpload
    media = MediaFileUpload(str(path), mimetype="application/zip",
                            resumable=True, chunksize=8 * 1024 * 1024)
    meta = {"name": path.name, "parents": [parent_folder_id]}
    request = service.files().create(
        body=meta, media_body=media, fields="id",
        supportsAllDrives=True,
    )
    response = None
    while response is None:
        status, response = request.next_chunk()
        if status:
            print(f"\r  {int(status.progress() * 100)}%", end="", flush=True)
    print()
    return response["id"]


def upload_plugins(paths: list[Path]) -> None:
    """Upload generated plugin-only zips into their matching per-version
    subfolder under Deliverables (creating the subfolder if needed). Skips any
    zip already present in that subfolder, so re-runs are idempotent."""
    service = _gdrive_service()
    folder_cache: dict[str, str] = {}

    for path in paths:
        if not path.exists():
            print(f"[upload] missing: {path}", file=sys.stderr)
            continue
        ver_m = re.search(r'SkpXyz-(\d+\.\d+(?:\.\d+)*)-', path.name)
        if not ver_m:
            print(f"[upload] cannot derive version from {path.name} - skipped",
                  file=sys.stderr)
            continue
        label = f"Exporter & Importer {ver_m.group(1)}"

        if label not in folder_cache:
            folder_cache[label] = _get_or_create_folder(
                service, DELIVERABLES_FOLDER_ID, label)
            print(f"[upload] folder: {label}")
        folder_id = folder_cache[label]

        if any(item["name"] == path.name for item in _list_folder(service, folder_id)):
            print(f"[upload] already on Drive: {path.name}")
            continue

        mb = path.stat().st_size / 1024 / 1024
        print(f"[upload] uploading {path.name} ({mb:.0f} MB) to {label}...")
        _upload_local_file(service, folder_id, path)
        print(f"[upload] done: {path.name}")


def _stage_locally(version_folder: str, zip_name: str, data: bytes) -> None:
    """Mirror a just-uploaded zip into <repo>/.drive-cache/incoming/ so the
    switcher can install it immediately, without waiting for Drive for
    Desktop to surface the new file in the local CloudStorage mount."""
    dest_dir = INCOMING_DIR / version_folder
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / zip_name
    dest.write_bytes(data)
    rel = dest.relative_to(SCRIPT_DIR)
    print(f"[sync] staged: {rel}")


# ── main ──────────────────────────────────────────────────────────────────────

def sync():
    gitlab_token = _read_gitlab_token()
    service = _gdrive_service()

    wiki_dir = ensure_wiki(gitlab_token)
    md_path = wiki_dir / "Installation.md"
    if not md_path.exists():
        print("[sync] Installation.md not found")
        return

    entries = parse_latest_zips(md_path.read_text())
    if not entries:
        print("[sync] no zips found in Latest Package section")
        return

    existing = _existing_zip_names(service, DELIVERABLES_FOLDER_ID)
    version_folder_cache: dict[str, str] = {}
    copied = 0

    for version, zip_name, git_path in entries:
        label = f"Exporter & Importer {version}"
        if zip_name in existing:
            print(f"[sync] already have {zip_name}")
            # If the upload was skipped but local staging is missing for a
            # Release build, fetch from the wiki and stage now. Recovers
            # users from "synced to Drive but not yet on local mount" limbo.
            if "Release" in zip_name and not (INCOMING_DIR / label / zip_name).exists():
                print(f"[sync] staging missing copy from wiki...")
                data = fetch_zip_bytes(wiki_dir, git_path)
                _stage_locally(label, zip_name, data)
            continue
        print(f"[sync] new: {zip_name}")
        if version not in version_folder_cache:
            fid = _get_or_create_folder(service, DELIVERABLES_FOLDER_ID, label)
            version_folder_cache[version] = fid
            print(f"[sync] folder: {label}")
        folder_id = version_folder_cache[version]
        print(f"[sync] downloading from wiki...")
        data = fetch_zip_bytes(wiki_dir, git_path)
        mb = len(data) / 1024 / 1024
        print(f"[sync] uploading {zip_name} ({mb:.0f} MB) to Drive...")
        _upload_zip(service, folder_id, zip_name, data)
        print(f"[sync] done: {zip_name}")
        # Stage Release builds locally so the switcher can use them before
        # Drive for Desktop surfaces them on the local CloudStorage mount.
        # Debug builds aren't installed by the switcher, so skip them.
        if "Release" in zip_name:
            _stage_locally(label, zip_name, data)
        copied += 1

    print(f"[sync] synced {copied} new file(s)." if copied else "[sync] up to date.")


def main():
    ap = argparse.ArgumentParser(description="Sync SkpXyz releases from wiki to Drive.")
    ap.add_argument("--auth", action="store_true",
                    help="Run OAuth flow to store Drive credentials.")
    ap.add_argument("--client-secret", metavar="PATH",
                    help="Path to Google OAuth client secret JSON (only needed for --auth).")
    ap.add_argument("--upload-plugin", metavar="ZIP", nargs="+",
                    help="Upload generated plugin-only zip(s) to their per-version "
                         "Deliverables subfolder, then exit.")
    args = ap.parse_args()

    if args.auth:
        do_auth(Path(args.client_secret) if args.client_secret else None)
        return

    if args.upload_plugin:
        try:
            upload_plugins([Path(p) for p in args.upload_plugin])
        except ImportError:
            print("[upload] Google client libraries not installed.", file=sys.stderr)
            sys.exit(1)
        except RuntimeError as e:
            print(f"[upload] {e}", file=sys.stderr)
            sys.exit(1)
        return

    try:
        sync()
    except ImportError:
        print(
            "[sync] Google client libraries not installed. Install with:\n"
            "  python3 -m pip install --user google-api-python-client "
            "google-auth google-auth-oauthlib",
            file=sys.stderr,
        )
        sys.exit(1)
    except RuntimeError as e:
        print(f"[sync] {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
