# goodnotes-todo

Turn handwritten notes in **GoodNotes** (iPad) into tasks in **Microsoft To Do**,
automatically, with **[Hermes](https://github.com/NousResearch/hermes-agent)** reading
the handwriting and asking you on **Telegram** when something is unclear.

```
GoodNotes (iPad) ──auto-backup──► Google Drive /GoodNotes/*.pdf
                                        │  rclone (every hour, no AI)
                                        ▼
                    check script: any new or changed pages?
                         │ no  → stop (costs nothing)
                         │ yes
                         ▼
     Hermes + skill: read page → To Do tasks → mark page done → Telegram if unclear
```

Tasks go into three To Do lists, which are created automatically:

| List | What goes there |
|---|---|
| **My Actions** | Things you have to do |
| **Waiting On** | Things someone owes you ("remind X", "follow up with Y") |
| **Clarify** | Anything Hermes couldn't read or interpret; it asks you on Telegram |

Reply on Telegram and Hermes fixes the task: it renames it, splits it, merges it, or
marks it done. Edited pages are handled incrementally, so only new lines become
new tasks. Ticks in a "% completed" column close tasks.

## Prerequisites

- **Hermes**, set up with `hermes setup`:
  - a model that can **read images and call tools**, for example Claude Opus through the
    Anthropic provider;
  - the **Telegram gateway**, running as a service (`hermes gateway install`).
- **rclone**, with a Google Drive remote. Use your
  [own Google client ID](https://rclone.org/drive/#making-your-own-client-id), because
  rclone's shared one is being retired.
- **poppler** (`pdftoppm`) and **Python 3.9+** with `venv`.
- **GoodNotes**: Settings → Backup → Google Drive, PDF format.
- A **Microsoft 365 work/school account** where you (or IT) can register an app.

## Install

```bash
git clone https://github.com/khamsakamal48/goodnotes-todo.git ~/goodnotes-todo
cd ~/goodnotes-todo
./install.sh
```

The repo folder becomes the project folder, so clone it where you want it to live.
The installer walks you through everything, and it's safe to re-run:

1. Checks prerequisites and tells you how to install anything missing.
2. Asks for the rclone path of your GoodNotes folder (e.g. `gdrive:GoodNotes`), then tests it.
3. Shows the Microsoft Entra app-registration steps and asks for the client ID and tenant ID.
4. Asks your first name, time zone, and optional "known names" (people and projects in your notes).
5. Creates the Python environment.
6. Installs the Hermes skill and the hourly check script, and tests the check script.
7. Signs you in to Microsoft with a device code.
8. Checks that Hermes's model can use tools and that Telegram is configured.
9. Creates the hourly Hermes job (`GoodNotes to To Do`), unless it already exists.

Non-interactive: `./install.sh --yes --remote gdrive:GoodNotes --client-id … --tenant …`
(see `./install.sh --help`; every option also works as a `GNTD_*` environment variable).

### Microsoft Entra app registration (one time, ~5 minutes)

At [entra.microsoft.com](https://entra.microsoft.com):

1. **App registrations → New registration**. Name it `Notes Sync` and choose
   "Accounts in this organizational directory only". Leave the redirect URI empty.
2. **Authentication → Advanced settings → Allow public client flows: Yes**, then **Save**.
   If you skip this, sign-in fails with `AADSTS7000218`.
3. **API permissions → Add → Microsoft Graph → Delegated → `Tasks.ReadWrite`**.
4. Copy the **Application (client) ID** and **Directory (tenant) ID** from the Overview page.
   Neither one is a secret.

The app only ever acts as you, and only on your own tasks. No client secret is involved.

## What's in here

| Path | What it does |
|---|---|
| `install.sh` | Friendly installer and re-configurer |
| `bin/notesync.py` | Mirrors Drive with `rclone sync`, renders pages to PNG, and tracks which pages are new or changed. No AI. |
| `bin/todo.py` | Microsoft Graph client: login, lists, add (skips duplicates), done, update. No AI. |
| `hermes/SKILL.md.tmpl` | Hermes's instructions; rendered to `~/.hermes/skills/productivity/goodnotes-todo/` |
| `hermes/goodnotes-pending.sh.tmpl` | Cheap hourly check; the model runs only when it prints something |

Created at install time and **never committed** (see `.gitignore`):

| Path | Contents |
|---|---|
| `state/config.json` | Your settings (remote, Microsoft IDs, time zone, names) |
| `state/msal_cache.json` | Your Microsoft sign-in token |
| `state/pages.json`, `state/tasks.json` | Processed pages and the tasks they created |
| `inbox/`, `pages/` | Local copies of your notebooks and page images |

## Day to day

```bash
.venv/bin/python bin/notesync.py status    # pages processed so far
.venv/bin/python bin/todo.py lists         # your To Do lists
hermes cron list && hermes cron doctor      # job status and health
```

- **Force a re-read** of a page Hermes already saw: `hermes cron edit <id> --monitor-script ""`,
  then `hermes cron run <id>`, then set `--monitor-script goodnotes-pending.sh` again.
- **Signed out of Microsoft** (Hermes will tell you): `.venv/bin/python bin/todo.py login`.
- **Deleted a notebook in GoodNotes**: it disappears locally too. Its history is kept, so
  restoring it won't create duplicate tasks.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Hermes says it has "no shell or file tools" | Your Hermes model provider doesn't pass tools. Switch it with `hermes model`. Test: `hermes -z "use your terminal tool to run: echo pong"` |
| `AADSTS7000218 … client_secret` | Turn on **Allow public client flows** in the app registration, then Save |
| `AADSTS50059 … tenant-identifying` | Set the tenant ID (re-run `./install.sh`) |
| "Need admin approval" at sign-in | Your organization requires admin consent; ask IT to grant `Tasks.ReadWrite` |
| rclone warns about the shared client_id | Create your own Google client ID and run `rclone config update <remote> client_id … client_secret …` |

## Cost

Pages are read once, and only when they change. With Claude Opus that's roughly
$0.05 per handwritten page (about $15 a month at 10 pages a day). Hours with no
new pages cost nothing.

## License

MIT
