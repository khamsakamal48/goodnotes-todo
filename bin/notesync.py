#!/usr/bin/env python3
"""GoodNotes page tracker. No AI in here: it only finds pages that need reading.

  notesync.py pending            pull PDFs from Drive, render pages, print new/changed pages as JSON
  notesync.py done NB PAGE FILE  mark a page processed; FILE = JSON {"transcript": str, "tasks": [titles]}
  notesync.py status             show tracked pages

A page is "changed" when its rendered image differs from the one last processed.
For changed pages the previous transcript and task titles are included, so the
reader can emit only what is new.
"""
import hashlib, json, os, subprocess, sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INBOX = ROOT / "inbox"
PAGES = ROOT / "pages"
STATE = ROOT / "state" / "pages.json"
_CFG = ROOT / "state" / "config.json"
_cfg = json.loads(_CFG.read_text()) if _CFG.exists() else {}
# Precedence: environment variable > state/config.json (written by install.sh) > default.
REMOTE = os.environ.get("NOTESYNC_REMOTE") or _cfg.get("remote", "gdrive:GoodNotes")
DPI = str(os.environ.get("NOTESYNC_DPI") or _cfg.get("dpi", 110))


def load():
    return json.loads(STATE.read_text()) if STATE.exists() else {}


def save(state):
    STATE.parent.mkdir(exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, ensure_ascii=False))
    tmp.replace(STATE)


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"command failed: {' '.join(cmd)}\n{r.stderr.strip()}")
    return r.stdout


def pending():
    INBOX.mkdir(exist_ok=True)
    # sync, not copy: a notebook deleted in GoodNotes/Drive disappears here too.
    # Its entry in state/pages.json is kept, so re-adding it doesn't duplicate tasks.
    run(["rclone", "sync", REMOTE, str(INBOX), "--include", "*.pdf"])
    live = {p.stem for p in INBOX.glob("*.pdf")}
    if PAGES.exists():
        for d in PAGES.iterdir():
            if d.is_dir() and d.name not in live:
                for f in d.glob("p-*.png"):
                    f.unlink()
                d.rmdir()
    state, out = load(), []
    for pdf in sorted(INBOX.glob("*.pdf")):
        nb = pdf.stem
        d = PAGES / nb
        d.mkdir(parents=True, exist_ok=True)
        for old in d.glob("p-*.png"):
            old.unlink()
        run(["pdftoppm", "-r", DPI, "-png", str(pdf), str(d / "p")])
        for img in sorted(d.glob("p-*.png")):
            page = int(img.stem.split("-")[-1])
            digest = hashlib.sha256(img.read_bytes()).hexdigest()
            prev = state.get(nb, {}).get(str(page))
            if prev and prev["hash"] == digest:
                continue
            out.append({
                "notebook": nb, "page": page, "image": str(img), "hash": digest,
                "status": "changed" if prev else "new",
                "previous_transcript": prev.get("transcript") if prev else None,
                "existing_tasks": prev.get("tasks", []) if prev else [],
            })
    print(json.dumps(out, indent=2, ensure_ascii=False))


def done(nb, page, file):
    data = json.loads(Path(file).read_text())
    img = PAGES / nb / f"p-{int(page)}.png"
    if not img.exists():  # pdftoppm zero-pads when a PDF has 10+ pages
        img = next((p for p in (PAGES / nb).glob("p-*.png") if int(p.stem.split("-")[-1]) == int(page)), None)
        if img is None:
            sys.exit(f"no rendered image for {nb} page {page}; run 'pending' first")
    state = load()
    prev = state.get(nb, {}).get(str(page), {})
    state.setdefault(nb, {})[str(page)] = {
        "hash": hashlib.sha256(img.read_bytes()).hexdigest(),
        "transcript": data.get("transcript", ""),
        "tasks": prev.get("tasks", []) + [t for t in data.get("tasks", []) if t not in prev.get("tasks", [])],
        "processed_at": datetime.now().isoformat(timespec="seconds"),
    }
    save(state)
    print(f"marked {nb} p{page} processed")


def status():
    for nb, pages in load().items():
        for p, v in sorted(pages.items(), key=lambda x: int(x[0])):
            print(f"{nb} p{p}: {len(v['tasks'])} tasks, processed {v['processed_at']}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["pending"]:
        pending()
    elif a[:1] == ["done"] and len(a) == 4:
        done(*a[1:])
    elif a[:1] == ["status"]:
        status()
    else:
        sys.exit(__doc__)
