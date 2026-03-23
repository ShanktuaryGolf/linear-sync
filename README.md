# Pipeline Kit — Discord + Linear + Multi-Agent CI

An automated development pipeline that connects Discord bug reports to Linear
issue tracking to AI-powered code agents. Users report bugs in Discord, agents
investigate and implement fixes, and you approve from your phone.

## How it works

```
User reports bug in Discord (/report)
    ↓
Linear ticket created automatically
    ↓
Discord forum post created for tracking
    ↓
Sync timer picks up ticket (every 5 min)
    ↓
AI agent investigates → posts findings → Human Review
    ↓
You approve in Linear (move to Gate Approved)
    ↓
AI agent implements fix → pushes branch → Human Review
    ↓
You approve → AI agent reviews code → Human Review
    ↓
You approve → AI agent merges → Done
    ↓
Discord thread updated at every status change
```

## Components

| Component | What it does |
|-----------|-------------|
| **Discord Bot** | `/report` command, forum posts, webhook status updates |
| **Linear Sync Timer** | Polls Linear every 5 min, dispatches AI agents |
| **Linear Status Script** | Shows pipeline status from terminal |
| **Gas Town** | Multi-agent workspace manager (polecats = worker agents) |

## Prerequisites

- **Claude Code** subscription (drives the AI agents)
- **Linear** account (free tier works)
- **Discord** server with a bot
- **VPS** with a domain (for webhook — optional, bot works without it)
- **Gas Town** installed ([github.com/anthropics/gas-town](https://github.com/anthropics/gas-town))

Optional agents (for code review rotation):
- Gemini CLI (`npm i -g @anthropic-ai/gemini-cli` or similar)
- Codex CLI
- OpenCode with z.ai provider

## Quick Start

### 1. Copy and configure

```bash
cp .env.example .env
# Edit .env with your credentials
```

### 2. Set up Linear workflow states

In Linear → Settings → Teams → your team → Workflow, create these custom states
(type: "started"):
- **Human Review**
- **Gate Approved**
- **Rework**

Then look up all state IDs and fill them in `.env`:
```bash
curl -s https://api.linear.app/graphql \
  -H "Authorization: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ workflowStates(filter: { team: { id: { eq: \"YOUR_TEAM_ID\" } } }) { nodes { id name } } }"}' \
  | python3 -m json.tool
```

### 3. Create a Discord bot

1. Go to https://discord.com/developers/applications
2. Create application → Bot → copy token to `.env`
3. OAuth2 → URL Generator → select `bot` + `applications.commands`
4. Permissions: Send Messages, Embed Links, Create Public Threads,
   Send Messages in Threads, Use Application Commands
5. Invite bot to your server with the generated URL
6. Create a **forum channel** for issue tracking, copy its ID to `.env`

### 4. Deploy the bot

**Local testing:**
```bash
cd bot
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp ../.env .env
python bot.py
```

**VPS deployment:**
```bash
# On your local machine
scp -r pipeline-kit user@vps:~/

# On the VPS
cd ~/pipeline-kit
bash setup.sh
```

### 5. Set up Linear webhook (for Discord status updates)

After the bot is deployed with a public URL:
1. Linear → Settings → API → Webhooks → New webhook
2. URL: `https://your-domain:8080/webhook`
3. Events: **Issue**
4. Save

### 6. Set up Gas Town (for AI agent dispatch)

```bash
# Install Gas Town
# See: https://github.com/anthropics/gas-town

# Add your project as a rig
gt rig add myproject git@github.com:you/repo.git --prefix mp

# Start the rig
gt rig undock myproject
gt rig start myproject
```

### 7. Set up the sync timer

```bash
# Edit the service file with your paths
vim scripts/linear-sync.service

# Install
sudo cp scripts/linear-sync.service /etc/systemd/system/
sudo cp scripts/linear-sync.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now linear-sync.timer
```

### 8. Add status alias

```bash
echo 'alias lsp="/path/to/pipeline-kit/scripts/linear-status.sh"' >> ~/.bashrc
```

## Pipeline Stages

| Stage | What happens | Agent |
|-------|-------------|-------|
| **investigate** | Read code, find root cause, post findings | claude |
| **implement** | Write code, run tests, push branch | claude / codex / gemini |
| **code-review** | Independent adversarial review | Rotates: gemini → opencode → codex → claude |
| **merge** | Merge approved branch to main | claude |

Between each stage, the issue moves to **Human Review**. You approve by moving
it to **Gate Approved** in Linear. If you want changes, move to **Rework** with
a comment explaining what needs fixing.

## Customization

### Categories

Edit `bot/categories.json` to define your project's issue categories. Each
category needs:
- `name`: Display name
- `label_id`: Linear label UUID (optional — create labels in Linear first)
- `emoji`: Discord emoji
- `description`: Short description for the dropdown

### Agent rotation

Edit `scripts/linear-sync.sh` — the `next_reviewer()` function defines the
code review rotation order. Add or remove agents as needed.

### Agent config

If using Gas Town, edit your `settings/config.json` to configure available agents:
```json
{
  "agents": {
    "codex-impl": { "command": "codex", "args": ["exec", "--sandbox", "workspace-write"] },
    "gemini-review": { "command": "gemini", "args": ["--yolo"] },
    "opencode-review": { "command": "/path/to/opencode", "args": ["run", "-m", "zai-coding-plan/glm-5-turbo"] }
  }
}
```

## Build & Release Pipeline

This kit handles the issue tracking and AI agent pipeline — **not** your build
and release process. Your project's CI/CD is up to you.

What you'll typically want:
1. Push your code to GitHub (or GitLab, etc.)
2. Set up your own CI pipeline (GitHub Actions, etc.) to build, test, and release
3. The **merge stage** polecat merges approved code to your main branch — your CI
   takes it from there

For example, you might set up a GitHub Action triggered on tag pushes (`v*`) that
builds installers, runs tests, and publishes releases. The pipeline kit doesn't
manage this — it manages the issue lifecycle up to the point where code lands on main.

## Files

```
pipeline-kit/
├── .env.example          # All config — copy to .env
├── setup.sh              # VPS deployment script
├── README.md             # This file
├── bot/
│   ├── bot.py            # Discord bot + webhook server
│   ├── categories.json   # Customizable issue categories
│   ├── requirements.txt  # Python dependencies
│   ├── run.sh            # Local run script
│   └── bot.service       # Systemd service file
└── scripts/
    ├── linear-sync.sh    # Polls Linear, dispatches agents
    ├── linear-status.sh  # Shows pipeline status
    ├── linear-sync.service
    └── linear-sync.timer
```
