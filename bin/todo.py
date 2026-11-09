#!/usr/bin/env python3
"""Microsoft To Do via Microsoft Graph (delegated: signs in as you, touches only your tasks).

  todo.py login                    one-time device-code sign-in (token cached in state/)
  todo.py lists                    show your To Do lists
  todo.py add [--dry-run] < items.json
  todo.py done LIST TASK_ID        mark a task completed
  todo.py update LIST TASK_ID < patch.json   e.g. {"title": "...", "body": "..."}

items.json is a list of:
  {"list": "My Actions" | "Waiting On" | "Clarify",
   "title": str, "notes": str, "due": "YYYY-MM-DD" | null,
   "importance": "high" | "normal" | "low",
   "notebook": str, "page": int}

Duplicates (same notebook + page + list + title) are skipped, so re-running is safe.
Config: state/config.json (written by install.sh): client_id, tenant, timezone.
Environment overrides: NOTESYNC_CLIENT_ID, NOTESYNC_TENANT, NOTESYNC_TZ.
"""
import hashlib, json, os, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STATE = ROOT / "state"
CACHE = STATE / "msal_cache.json"
SEEN = STATE / "tasks.json"
GRAPH = "https://graph.microsoft.com/v1.0"
SCOPES = ["Tasks.ReadWrite"]
LISTS = ["My Actions", "Waiting On", "Clarify"]
_CFG = STATE / "config.json"
# Time zone for due dates (Windows name, e.g. "India Standard Time", or "UTC").
TZ = os.environ.get("NOTESYNC_TZ") or (json.loads(_CFG.read_text()) if _CFG.exists() else {}).get("timezone", "UTC")


def config():
    f = STATE / "config.json"
    c = json.loads(f.read_text()) if f.exists() else {}
    cid = os.environ.get("NOTESYNC_CLIENT_ID") or c.get("client_id")
    if not cid:
        sys.exit("No client id. Set NOTESYNC_CLIENT_ID or put {\"client_id\": ...} in state/config.json")
    return cid, os.environ.get("NOTESYNC_TENANT") or c.get("tenant", "organizations")


def app():
    import msal
    cache = msal.SerializableTokenCache()
    if CACHE.exists():
        cache.deserialize(CACHE.read_text())
    cid, tenant = config()
    return msal.PublicClientApplication(cid, authority=f"https://login.microsoftonline.com/{tenant}",
                                        token_cache=cache), cache


def persist(cache):
    if cache.has_state_changed:
        STATE.mkdir(exist_ok=True)
        CACHE.write_text(cache.serialize())
        CACHE.chmod(0o600)


def token(interactive=False):
    a, cache = app()
    accts = a.get_accounts()
    res = a.acquire_token_silent(SCOPES, account=accts[0]) if accts else None
    if not res and interactive:
        flow = a.initiate_device_flow(scopes=SCOPES)
        if "user_code" not in flow:
            sys.exit(f"device flow failed: {flow}")
        print(flow["message"], flush=True)
        res = a.acquire_token_by_device_flow(flow)
    persist(cache)
    if not res or "access_token" not in res:
        sys.exit("Not signed in (or sign-in expired). Run: todo.py login\n" + str((res or {}).get("error_description", "")))
    return res["access_token"]


def api(method, path, body=None):
    import requests
    r = requests.request(method, GRAPH + path, json=body, timeout=30,
                         headers={"Authorization": f"Bearer {token()}"})
    if r.status_code >= 400:
        sys.exit(f"Graph {method} {path} -> {r.status_code}: {r.text[:500]}")
    return r.json() if r.content else {}


def list_ids(create=True):
    have = {l["displayName"]: l["id"] for l in api("GET", "/me/todo/lists").get("value", [])}
    for name in LISTS:
        if name not in have and create:
            have[name] = api("POST", "/me/todo/lists", {"displayName": name})["id"]
    return have


def key(it):
    norm = re.sub(r"\W+", " ", it["title"].lower()).strip()
    return hashlib.sha1(f'{it.get("notebook")}|{it.get("page")}|{it["list"]}|{norm}'.encode()).hexdigest()[:16]


def add(dry):
    items = json.load(sys.stdin)
    seen = json.loads(SEEN.read_text()) if SEEN.exists() else {}
    ids = None if dry else list_ids()
    for it in items:
        if it["list"] not in LISTS:
            sys.exit(f'unknown list {it["list"]!r}; use one of {LISTS}')
        k = key(it)
        if k in seen:
            print(f'skip (already added): [{it["list"]}] {it["title"]}')
            continue
        src = f'From GoodNotes: {it.get("notebook")}, page {it.get("page")}'
        task = {"title": it["title"], "importance": it.get("importance", "normal"),
                "body": {"contentType": "text", "content": f'{it.get("notes", "").strip()}\n\n{src}'.strip()}}
        if it.get("due"):
            task["dueDateTime"] = {"dateTime": f'{it["due"]}T09:00:00', "timeZone": TZ}
        if dry:
            print(f'[dry-run] would add to {it["list"]}: {json.dumps(task, ensure_ascii=False)}')
            continue
        t = api("POST", f'/me/todo/lists/{ids[it["list"]]}/tasks', task)
        seen[k] = {"list": it["list"], "id": t["id"], "title": it["title"]}
        SEEN.write_text(json.dumps(seen, indent=2, ensure_ascii=False))
        print(f'added [{it["list"]}] {it["title"]}  (id {t["id"]})')


def main(a):
    if a[:1] == ["login"]:
        token(interactive=True); print("signed in")
    elif a[:1] == ["lists"]:
        for name, i in list_ids(create=False).items():
            print(f"{name}\t{i}")
    elif a[:1] == ["add"]:
        add("--dry-run" in a)
    elif a[:1] == ["done"] and len(a) == 3:
        api("PATCH", f"/me/todo/lists/{list_ids()[a[1]]}/tasks/{a[2]}", {"status": "completed"}); print("completed")
    elif a[:1] == ["update"] and len(a) == 3:
        p = json.load(sys.stdin)
        body = {k: v for k, v in p.items() if k in ("title", "importance")}
        if "body" in p:
            body["body"] = {"contentType": "text", "content": p["body"]}
        api("PATCH", f"/me/todo/lists/{list_ids()[a[1]]}/tasks/{a[2]}", body); print("updated")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
