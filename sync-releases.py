#!/usr/bin/env python3
"""Sync the latest SkpXyz Darwin-Release zip from the t-support GitLab wiki
to the local Google Drive Deliverables folder.

Token (needs read_api + read_repository scope):
  File:    ~/.config/bench/gitlab-token  (one line)
  Env var: GITLAB_WIKI_TOKEN

Wiki is sparse-cloned at ~/.bench/wiki/ — only Installation.md is fetched
initially; zip blobs are pulled on demand.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

WIKI_URL = "https://oauth2:{token}@gitlab.com/jcube/t-support.wiki.git"
WIKI_DIR = Path.home() / ".bench" / "wiki"
TOKEN_FILE = Path.home() / ".config" / "bench" / "gitlab-token"

DELIVERABLES_DIR = (
    Path.home()
    / "Library/CloudStorage"
    / "GoogleDrive-tom_kluyskens@trimble.com"
    / "Shared drives"
    / "CDG Projects & Clients"
    / "JCube"
    / "OEM • USD IO"
    / "Deliverables"
)


# ── token ─────────────────────────────────────────────────────────────────────

def read_token() -> str:
    tok = os.environ.get("GITLAB_WIKI_TOKEN", "").strip()
    if tok:
        return tok
    if TOKEN_FILE.exists():
        tok = TOKEN_FILE.read_text().strip()
        if tok:
            return tok
    raise RuntimeError(
        f"No token found. Set $GITLAB_WIKI_TOKEN or write it to {TOKEN_FILE}"
    )


# ── git ───────────────────────────────────────────────────────────────────────

def _git(args: list[str], cwd: Path, check: bool = True) -> subprocess.CompletedProcess:
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



# ── parsing ───────────────────────────────────────────────────────────────────

def parse_latest_darwin(md_text: str) -> list[tuple[str, str, str]]:
    """Return (version, zip_filename, git_path) from the Latest Package section.

    Skips strikethrough links (~~[...]~~).
    """
    m = re.search(r'^#+\s*Latest Package', md_text, re.MULTILINE | re.IGNORECASE)
    if not m:
        return []

    section = md_text[m.start():]
    # Stop at the next horizontal rule or same-level heading that starts a new
    # section (e.g. "# Older Packages" or "---")
    cut = re.search(r'\n(---+|#{1,2}\s+Older)', section[1:])
    if cut:
        section = section[: cut.start() + 1]

    results = []
    # Match only non-strikethrough Darwin-Release zip links
    for lm in re.finditer(
        r'(?<!~)\[([^\]]*Darwin-Release[^\]]*\.zip)\]\((uploads/[^)]+\.zip)\)(?!~)',
        section,
    ):
        zip_name = lm.group(1)
        git_path = lm.group(2)
        ver_m = re.search(r'SkpXyz-(\d+\.\d+(?:\.\d+)*)-', zip_name)
        version = ver_m.group(1) if ver_m else "unknown"
        results.append((version, zip_name, git_path))

    return results


# ── deliverables ──────────────────────────────────────────────────────────────

def existing_darwin_zips(deliverables_dir: Path) -> set[str]:
    if not deliverables_dir.exists():
        return set()
    return {p.name for p in deliverables_dir.rglob("*Darwin*.zip")}


def copy_to_deliverables(
    wiki_dir: Path, git_path: str, zip_name: str,
    version: str, deliverables_dir: Path,
) -> Path:
    dest_dir = deliverables_dir / f"Exporter & Importer {version}"
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / zip_name
    tmp = dest.with_suffix(".zip.tmp")
    print(f"[sync] downloading {zip_name} ({version})...")
    # git show fetches the blob on demand from the partial clone (no sparse-checkout
    # cone restriction) and streams it; write directly to avoid a double-copy.
    r = subprocess.run(
        ["git", "show", f"HEAD:{git_path}"],
        cwd=wiki_dir,
        env={**os.environ, "GIT_TERMINAL_PROMPT": "0"},
        capture_output=True, check=True,
    )
    tmp.write_bytes(r.stdout)
    tmp.replace(dest)
    print(f"[sync] saved {dest.stat().st_size // 1024 // 1024} MB -> {dest_dir.name}/{zip_name}")
    return dest


# ── main ──────────────────────────────────────────────────────────────────────

def sync() -> list[Path]:
    token = read_token()

    if not DELIVERABLES_DIR.exists():
        print(f"[sync] skipped: Deliverables folder not found at {DELIVERABLES_DIR}")
        return []

    wiki_dir = ensure_wiki(token)
    md_path = wiki_dir / "Installation.md"
    if not md_path.exists():
        print("[sync] Installation.md not found")
        return []

    entries = parse_latest_darwin(md_path.read_text())
    if not entries:
        print("[sync] no Darwin-Release zips found in Latest Package section")
        return []

    existing = existing_darwin_zips(DELIVERABLES_DIR)
    copied: list[Path] = []

    for version, zip_name, git_path in entries:
        if zip_name in existing:
            print(f"[sync] already have {zip_name}")
            continue
        print(f"[sync] new release: {version}  ({zip_name})")
        try:
            dest = copy_to_deliverables(wiki_dir, git_path, zip_name, version,
                                        DELIVERABLES_DIR)
            copied.append(dest)
        except Exception as e:
            print(f"[sync] failed: {e}", file=sys.stderr)

    if not copied:
        print("[sync] up to date.")
    else:
        print(f"[sync] synced {len(copied)} new release(s).")
    return copied


if __name__ == "__main__":
    try:
        sync()
    except RuntimeError as e:
        print(f"[sync] {e}", file=sys.stderr)
        sys.exit(1)
