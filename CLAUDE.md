# Pipeline Kit

This is a Discord + Linear + Multi-Agent CI pipeline kit. See README.md for full docs.

## Quick Context

- `bot/` — Discord bot that creates Linear tickets from `/report` command and posts status updates to a forum channel
- `scripts/` — Standalone scripts for polling Linear and dispatching AI agents (Gas Town polecats)
- `.env.example` — All configuration. User must copy to `.env` and fill in credentials
- `setup.sh` — VPS deployment script (systemd, certbot, python venv)

## If the user asks for help setting up

1. Read `.env.example` — it documents every required variable with instructions
2. Walk them through creating a Discord bot, Linear API key, and workflow states
3. Help them fill in `.env`
4. Run `setup.sh` for VPS deployment, or `bot/run.sh` for local testing
