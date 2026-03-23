# Pipeline Kit

This is a Discord + Linear + Multi-Agent CI pipeline kit. See README.md for full docs.

## Quick Context

- `bot/` — Discord bot that creates Linear tickets from `/report` command and posts status updates to a forum channel
- `scripts/` — Standalone scripts for polling Linear and dispatching AI agents (Gas Town polecats)
- `.env.example` — All configuration. User must copy to `.env` and fill in credentials
- `setup.sh` — VPS deployment script (systemd, certbot, python venv)

## Gas Town Dependency

The `scripts/linear-sync.sh` script depends on [Gas Town](https://github.com/steveyegge/gastown) for agent dispatch and lifecycle management. The Discord bot (`bot/`) does **not** require Gas Town — it only talks to Discord and Linear.

**What linear-sync.sh calls:**
- `gt sling <bead> <rig>` — Dispatch work to AI agents (polecats)
- `gt polecat list` / `gt polecat nuke` — Manage worker agents
- `gt rig list` / `gt rig undock` / `gt rig start` / `gt rig dock` — Manage rig lifecycle
- `bd create` / `bd list` / `bd show` — Issue tracking (beads)

**What must be running:**
- Dolt server (`gt dolt start`) — beads data backend
- Gas Town daemon (`gt up`) — manages witness + refinery per rig
- At least one rig configured for your project (`gt rig add <name> <repo-url> --prefix <prefix>`)

**Rig lifecycle:** Rigs are docked (dormant) by default. `linear-sync.sh` auto-undocks when work arrives and auto-docks when idle. The witness monitors polecat health, and the refinery handles the merge queue.

## If the user asks for help setting up

1. Read `.env.example` — it documents every required variable with instructions
2. Walk them through creating a Discord bot, Linear API key, and workflow states
3. Help them fill in `.env`
4. Set up Gas Town: install, `gt dolt start`, `gt rig add`, configure agents
5. Run `setup.sh` for VPS deployment, or `bot/run.sh` for local testing
