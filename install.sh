#!/usr/bin/env bash
# goodnotes-todo installer: handwritten GoodNotes pages -> Microsoft To Do, run by Hermes.
#
# Run it from inside the cloned repo; the repo folder becomes the project folder.
#   ./install.sh                 friendly, asks for everything (with sensible defaults)
#   ./install.sh --help          all options
# Safe to re-run: it keeps existing settings as defaults and never duplicates the cron job.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
CONFIG="$PROJECT_DIR/state/config.json"
JOB_NAME="GoodNotes to To Do"

# ---------- options (flags > environment > existing config > defaults) ----------
ASSUME_YES=0; SKIP_LOGIN=0; SKIP_CRON=0; SKIP_TOOLCHECK=0
OPT_REMOTE="${GNTD_REMOTE:-}"; OPT_CLIENT_ID="${GNTD_CLIENT_ID:-}"; OPT_TENANT="${GNTD_TENANT:-}"
OPT_TZ="${GNTD_TIMEZONE:-}"; OPT_OWNER="${GNTD_OWNER:-}"; OPT_NAMES="${GNTD_KNOWN_NAMES:-}"
OPT_SCHEDULE="${GNTD_SCHEDULE:-}"; OPT_DELIVER="${GNTD_DELIVER:-}"

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

  --remote REMOTE:FOLDER   rclone path of the GoodNotes backup folder   (e.g. gdrive:GoodNotes)
  --client-id ID           Microsoft Entra Application (client) ID
  --tenant ID|DOMAIN       Microsoft Entra Directory (tenant) ID, or your work domain
  --timezone NAME          Windows time zone for due dates (e.g. "India Standard Time", "UTC")
  --owner NAME             Your first name, used in Hermes's instructions
  --known-names "A, B"     Optional names/terms that appear in your notes (helps reading)
  --schedule SPEC          Hermes schedule for the job (default: "every 1h")
  --deliver TARGET         Where Hermes sends questions/failures (default: telegram)
  --yes                    Don't ask; use flags, existing config and defaults
  --skip-login             Don't run the Microsoft sign-in
  --skip-cron              Don't create the Hermes cron job
  --skip-toolcheck         Don't test that Hermes's model can use tools
  -h, --help               This help

Every option can also be given as an environment variable: GNTD_REMOTE, GNTD_CLIENT_ID,
GNTD_TENANT, GNTD_TIMEZONE, GNTD_OWNER, GNTD_KNOWN_NAMES, GNTD_SCHEDULE, GNTD_DELIVER.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --remote) OPT_REMOTE="$2"; shift 2 ;;
    --client-id) OPT_CLIENT_ID="$2"; shift 2 ;;
    --tenant) OPT_TENANT="$2"; shift 2 ;;
    --timezone) OPT_TZ="$2"; shift 2 ;;
    --owner) OPT_OWNER="$2"; shift 2 ;;
    --known-names) OPT_NAMES="$2"; shift 2 ;;
    --schedule) OPT_SCHEDULE="$2"; shift 2 ;;
    --deliver) OPT_DELIVER="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --skip-login) SKIP_LOGIN=1; shift ;;
    --skip-cron) SKIP_CRON=1; shift ;;
    --skip-toolcheck) SKIP_TOOLCHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

# ---------- friendly output ----------
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'; else B= G= Y= R= D= N=; fi
STEP=0
step() { STEP=$((STEP+1)); printf '\n%s[%d] %s%s\n' "$B" "$STEP" "$1" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$1"; }
info() { printf '  %s%s%s\n' "$D" "$1" "$N"; }
die()  { printf '\n%s✗ %s%s\n' "$R" "$1" "$N" >&2; exit 1; }

# ask VAR "Question" "default"  -> reads from the terminal, empty answer keeps the default
ask() {
  local __var="$1" __q="$2" __def="${3:-}" __ans=""
  if [ "$ASSUME_YES" = 1 ] || [ ! -r /dev/tty ]; then __ans="$__def"
  else
    if [ -n "$__def" ]; then printf '  %s %s[%s]%s: ' "$__q" "$D" "$__def" "$N" > /dev/tty
    else printf '  %s: ' "$__q" > /dev/tty; fi
    IFS= read -r __ans < /dev/tty || true
    [ -z "$__ans" ] && __ans="$__def"
  fi
  printf -v "$__var" '%s' "$__ans"
}
confirm() {  # confirm "Question" Y|N
  local a; ask a "$1 (y/n)" "${2:-Y}"
  case "$a" in [Yy]*) return 0 ;; *) return 1 ;; esac
}
cfg_get() {  # cfg_get key -> value from existing state/config.json (or empty)
  [ -f "$CONFIG" ] || return 0
  python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$CONFIG" "$1" 2>/dev/null || true
}

cat <<EOF
${B}GoodNotes → Microsoft To Do${N}
Handwritten notes become To Do tasks; Hermes reads the pages and asks you on Telegram
when something is unclear.

Project folder: $PROJECT_DIR
Hermes home:    $HERMES_HOME
EOF

# ---------- 1. prerequisites ----------
step "Checking prerequisites"
missing=0
need() {  # need cmd "install hint"
  if command -v "$1" >/dev/null 2>&1; then ok "$1"; else warn "$1 not found. $2"; missing=1; fi
}
need hermes   "Install Hermes and run 'hermes setup' first (model + Telegram gateway)."
need rclone   "Arch: sudo pacman -S rclone · Debian/Ubuntu: sudo apt install rclone · macOS: brew install rclone"
need pdftoppm "Arch: sudo pacman -S poppler · Debian/Ubuntu: sudo apt install poppler-utils · macOS: brew install poppler"
need python3  "Install Python 3.9 or newer."
[ "$missing" = 0 ] || die "Install the missing tools above, then run ./install.sh again."
python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' || die "Python 3.9+ is required (found $(python3 --version))."
python3 -c 'import venv, ensurepip' 2>/dev/null || die "Python's venv module is missing. Debian/Ubuntu: sudo apt install python3-venv"
ok "Python $(python3 -c 'import platform; print(platform.python_version())')"

# ---------- 2. Google Drive via rclone ----------
step "Google Drive (where GoodNotes backs up your notebooks)"
info "In GoodNotes: Settings → Backup → Google Drive, PDF format. It creates a 'GoodNotes' folder."
remotes="$(rclone listremotes 2>/dev/null || true)"
if [ -z "$remotes" ]; then
  warn "rclone has no remotes yet. Run 'rclone config' and add a Google Drive remote."
  info "Tip: use your own Google client ID (https://rclone.org/drive/#making-your-own-client-id);"
  info "rclone's shared one is being retired."
  die "Then run ./install.sh again."
fi
info "rclone remotes on this machine: $(echo $remotes)"
def_remote="${OPT_REMOTE:-$(cfg_get remote)}"
if [ -z "$def_remote" ]; then
  first_drive="$(echo "$remotes" | head -n1)"
  def_remote="${first_drive}GoodNotes"
fi
while :; do
  ask REMOTE "rclone path of the GoodNotes folder" "$def_remote"
  case "$REMOTE" in *:*) ;; *) warn "Use the form remote:folder, e.g. gdrive:GoodNotes"; [ "$ASSUME_YES" = 1 ] && die "Bad --remote"; continue ;; esac
  if out="$(rclone lsf "$REMOTE" --include '*.pdf' 2>&1)"; then
    n=$(printf '%s' "$out" | grep -c . || true)
    ok "Reached $REMOTE ($n PDF notebook(s))"
    if printf '%s' "$out" | grep -qi "shared.*client_id\|client_id.*retired"; then
      warn "This remote uses rclone's shared Google client ID, which is being retired. See the tip above."
    fi
    break
  fi
  warn "Couldn't read $REMOTE: $(printf '%s' "$out" | tail -n1)"
  [ "$ASSUME_YES" = 1 ] && die "Fix --remote or the rclone remote, then retry."
done

# ---------- 3. Microsoft To Do ----------
step "Microsoft To Do (your work or school account)"
def_client="${OPT_CLIENT_ID:-$(cfg_get client_id)}"
def_tenant="${OPT_TENANT:-$(cfg_get tenant)}"
if [ -z "$def_client" ]; then
  cat <<'EOF'
  You need a one-time app registration (about 5 minutes) at https://entra.microsoft.com
    1. App registrations → New registration. Name: "Notes Sync".
       Supported accounts: "Accounts in this organizational directory only". No redirect URI.
    2. Authentication → Advanced settings → Allow public client flows: Yes → Save.
       (Without this, sign-in fails with AADSTS7000218.)
    3. API permissions → Add → Microsoft Graph → Delegated → Tasks.ReadWrite.
    4. From the Overview page copy the Application (client) ID and Directory (tenant) ID.
  Neither ID is a secret. If the portal says you lack permission, ask IT to do these steps.
EOF
fi
GUID='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
while :; do
  ask CLIENT_ID "Application (client) ID" "$def_client"
  [[ "$CLIENT_ID" =~ $GUID ]] && break
  warn "That doesn't look like a GUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)."
  [ "$ASSUME_YES" = 1 ] && die "Provide --client-id."
done
while :; do
  ask TENANT "Directory (tenant) ID, or your work domain" "$def_tenant"
  [[ "$TENANT" =~ $GUID || "$TENANT" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
  warn "Enter the tenant GUID or a domain like yourcompany.com."
  [ "$ASSUME_YES" = 1 ] && die "Provide --tenant."
done

# time zone for due dates: Graph wants a Windows zone name; map the common ones
iana="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
[ -z "$iana" ] && iana="$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##' || true)"
guess_tz="$(python3 - "$iana" <<'EOF'
import sys
m = {"Asia/Kolkata": "India Standard Time", "Asia/Calcutta": "India Standard Time",
     "Europe/London": "GMT Standard Time", "Europe/Dublin": "GMT Standard Time",
     "Europe/Berlin": "W. Europe Standard Time", "Europe/Amsterdam": "W. Europe Standard Time",
     "Europe/Paris": "Romance Standard Time", "Europe/Madrid": "Romance Standard Time",
     "America/New_York": "Eastern Standard Time", "America/Toronto": "Eastern Standard Time",
     "America/Chicago": "Central Standard Time", "America/Denver": "Mountain Standard Time",
     "America/Los_Angeles": "Pacific Standard Time", "Asia/Dubai": "Arabian Standard Time",
     "Asia/Singapore": "Singapore Standard Time", "Asia/Tokyo": "Tokyo Standard Time",
     "Australia/Sydney": "AUS Eastern Standard Time", "UTC": "UTC", "Etc/UTC": "UTC"}
print(m.get(sys.argv[1], "UTC"))
EOF
)"
def_tz="${OPT_TZ:-$(cfg_get timezone)}"
ask TIMEZONE "Time zone for due dates (Windows name)" "${def_tz:-$guess_tz}"
[ -n "$TIMEZONE" ] || TIMEZONE="UTC"

# ---------- 4. about you ----------
step "About you (used in Hermes's instructions)"
gecos_first="$(getent passwd "$USER" 2>/dev/null | cut -d: -f5 | cut -d, -f1 | awk '{print $1}')"
def_owner="${OPT_OWNER:-$(cfg_get owner)}"
ask OWNER "Your first name" "${def_owner:-${gecos_first:-$USER}}"
info "Optional: names, companies or project terms that appear in your notes. It helps Hermes read"
info "messy handwriting. These stay on this machine (state/config.json), never in the repo."
ask KNOWN_NAMES "Known names (comma-separated, or leave empty)" "${OPT_NAMES:-$(cfg_get known_names)}"

# ---------- 5. Python environment ----------
step "Python environment"
if [ ! -x "$PROJECT_DIR/.venv/bin/python" ]; then
  python3 -m venv "$PROJECT_DIR/.venv"
  ok "Created .venv"
fi
VPY="$PROJECT_DIR/.venv/bin/python"
if command -v uv >/dev/null 2>&1 && ! "$VPY" -m pip --version >/dev/null 2>&1; then
  uv pip install --quiet --python "$VPY" -r "$PROJECT_DIR/requirements.txt"   # venv made by uv: no pip inside
else
  "$VPY" -m pip --version >/dev/null 2>&1 || "$VPY" -m ensurepip --upgrade >/dev/null
  "$VPY" -m pip install --quiet --disable-pip-version-check -r "$PROJECT_DIR/requirements.txt"
fi
ok "Installed $(tr '\n' ' ' < "$PROJECT_DIR/requirements.txt")"

# ---------- 6. write config ----------
step "Saving settings"
mkdir -p "$PROJECT_DIR/state"
CLIENT_ID="$CLIENT_ID" TENANT="$TENANT" REMOTE="$REMOTE" TIMEZONE="$TIMEZONE" OWNER="$OWNER" \
KNOWN_NAMES="$KNOWN_NAMES" python3 - "$CONFIG" <<'EOF'
import json, os, sys
p = sys.argv[1]
c = json.load(open(p)) if os.path.exists(p) else {}
e = os.environ
c.update({"client_id": e["CLIENT_ID"], "tenant": e["TENANT"], "remote": e["REMOTE"],
          "timezone": e["TIMEZONE"], "owner": e["OWNER"], "known_names": e["KNOWN_NAMES"]})
c.setdefault("dpi", 110)
json.dump(c, open(p, "w"), indent=2, ensure_ascii=False)
EOF
chmod 600 "$CONFIG"
ok "state/config.json (private to you; ignored by git)"

# ---------- 7. Hermes skill + monitor ----------
step "Installing the Hermes skill and the hourly check"
SKILL_DIR="$HERMES_HOME/skills/productivity/goodnotes-todo"
SCRIPTS_DIR="$HERMES_HOME/scripts"
mkdir -p "$SKILL_DIR" "$SCRIPTS_DIR"
render() {  # render template out
  python3 - "$1" "$2" "$CONFIG" "$PROJECT_DIR" <<'EOF'
import json, os, shutil, sys, time
tmpl, out, cfg, proj = sys.argv[1:5]
c = json.load(open(cfg))
names = c.get("known_names", "").strip()
vals = {"{{PROJECT_DIR}}": proj, "{{OWNER}}": c.get("owner") or "the user",
        "{{REMOTE}}": c["remote"],
        "{{KNOWN_NAMES_LINE}}": f"- Names seen in past notes (for disambiguation): {names}." if names else ""}
s = open(tmpl).read()
for k, v in vals.items():
    s = s.replace(k, v)
if os.path.exists(out) and open(out).read() != s:
    bak = f"{out}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(out, bak)
    print(f"  backed up previous version to {bak}")
open(out, "w").write(s)
EOF
}
render "$PROJECT_DIR/hermes/SKILL.md.tmpl" "$SKILL_DIR/SKILL.md"
ok "Skill: $SKILL_DIR/SKILL.md"
render "$PROJECT_DIR/hermes/goodnotes-pending.sh.tmpl" "$SCRIPTS_DIR/goodnotes-pending.sh"
chmod +x "$SCRIPTS_DIR/goodnotes-pending.sh"
ok "Check script: $SCRIPTS_DIR/goodnotes-pending.sh"
if out="$("$SCRIPTS_DIR/goodnotes-pending.sh" 2>&1)"; then
  n=$(printf '%s' "$out" | grep -c . || true)
  ok "Check script works ($n page(s) waiting to be read)"
else
  warn "Check script failed: $(printf '%s' "$out" | tail -n2)"
fi

# ---------- 8. Microsoft sign-in ----------
step "Signing in to Microsoft"
PY="$PROJECT_DIR/.venv/bin/python"
if "$PY" "$PROJECT_DIR/bin/todo.py" lists >/dev/null 2>&1; then
  ok "Already signed in"
elif [ "$SKIP_LOGIN" = 1 ]; then
  warn "Skipped. Later, run: \"$PY\" \"$PROJECT_DIR/bin/todo.py\" login"
else
  info "A code will appear. Open the link, enter the code, sign in with your work account and accept."
  "$PY" "$PROJECT_DIR/bin/todo.py" login || die "Sign-in failed. AADSTS7000218 means 'Allow public client flows' is still off."
  "$PY" "$PROJECT_DIR/bin/todo.py" lists >/dev/null && ok "Signed in; To Do is reachable"
fi

# ---------- 9. Hermes checks ----------
step "Checking Hermes"
if [ "$SKIP_TOOLCHECK" = 1 ]; then
  info "Tool check skipped."
elif confirm "Test that Hermes's model can run tools (one short model call)?" Y; then
  reply="$(cd /tmp && timeout 180 hermes -z "Use your terminal tool to run exactly: echo gntd-pong. Reply with only the command's output. If you have no terminal tool, reply exactly: NO-TOOLS" 2>&1 | tail -n 3 || true)"
  if printf '%s' "$reply" | grep -q "gntd-pong"; then ok "Hermes can use tools"
  else
    warn "Hermes's model could not use tools (got: $(printf '%s' "$reply" | tail -n1))."
    info "Fix with 'hermes model': pick a provider that supports tool calling (e.g. Anthropic with an API key)."
  fi
fi
if [ -f "$HERMES_HOME/.env" ] && grep -q '^TELEGRAM_BOT_TOKEN=.' "$HERMES_HOME/.env"; then
  ok "Telegram is configured"
else
  warn "Telegram isn't configured in Hermes; questions can't reach you. Run 'hermes setup' (Telegram gateway)."
fi
if [[ "$(hermes cron status 2>/dev/null || true)" == *[Rr]unning* ]]; then ok "Hermes scheduler is running"
else warn "Hermes scheduler isn't running. Start the gateway: 'hermes gateway install' or 'hermes gateway run'."; fi

# ---------- 10. cron job ----------
step "Hourly job"
SCHEDULE="${OPT_SCHEDULE:-every 1h}"; DELIVER="${OPT_DELIVER:-telegram}"
PROMPT="Process ${OWNER}'s new GoodNotes pages into Microsoft To Do by following the goodnotes-todo skill exactly. The monitor output above lists the pages to read (notebook|page|hash). Run notesync.py pending to get the image paths, read each page, add tasks with todo.py, then mark each page done. Send a Telegram message only when you created Clarify items or something failed (for example, a sign-in that expired). If the pending list is empty, finish silently."
if hermes cron list 2>/dev/null | grep -c "Name: *$JOB_NAME" >/dev/null; then
  ok "'$JOB_NAME' already exists. Left unchanged."
elif [ "$SKIP_CRON" = 1 ]; then
  warn "Skipped. Re-run without --skip-cron to create it."
elif confirm "Create the Hermes job '$JOB_NAME' ($SCHEDULE, messages to $DELIVER)?" Y; then
  hermes cron create "$SCHEDULE" "$PROMPT" --name "$JOB_NAME" --skill goodnotes-todo \
    --monitor-script goodnotes-pending.sh --workdir "$PROJECT_DIR" --deliver "$DELIVER" >/dev/null
  ok "Created. Check it with: hermes cron list"
else
  warn "Not created. Re-run ./install.sh when you're ready."
fi

cat <<EOF

${G}${B}All set.${N}
Write in GoodNotes as usual. When the backup reaches Drive, the next run turns new lines into
tasks in My Actions / Waiting On / Clarify, and Hermes asks about unclear ones on Telegram.

  Status of processed pages:  "$PY" "$PROJECT_DIR/bin/notesync.py" status
  Your To Do lists:           "$PY" "$PROJECT_DIR/bin/todo.py" lists
  Job health:                 hermes cron doctor
EOF
