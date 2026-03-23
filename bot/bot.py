"""
Discord → Linear Issue Pipeline Bot

Users run /report in Discord, pick a category and severity, fill out a
structured form, and a Linear ticket is created automatically. A forum post
is created for tracking, and Linear webhook updates are posted to the thread
as the issue moves through the pipeline.

Configure categories in categories.json. All credentials via .env.
"""

from __future__ import annotations

import json
import os
import logging
import ssl
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import discord
from discord import app_commands
import httpx
from aiohttp import web

# ---------------------------------------------------------------------------
# Config from environment
# ---------------------------------------------------------------------------
DISCORD_TOKEN = os.environ["DISCORD_BOT_TOKEN"]
LINEAR_API_KEY = os.environ["LINEAR_API_KEY"]
LINEAR_TEAM_ID = os.environ.get("LINEAR_TEAM_ID", "")
LINEAR_PROJECT_ID = os.environ.get("LINEAR_PROJECT_ID", "")

ADMIN_USER_ID = int(os.environ.get("ADMIN_USER_ID", "0"))
FORUM_CHANNEL_ID = int(os.environ.get("FORUM_CHANNEL_ID", "0"))
WEBHOOK_PORT = int(os.environ.get("WEBHOOK_PORT", "8080"))
SSL_CERT = os.environ.get("SSL_CERT", "")
SSL_KEY = os.environ.get("SSL_KEY", "")

LINEAR_API = "https://api.linear.app/graphql"

THREAD_MAP_FILE = Path(__file__).parent / "thread_map.json"
CATEGORIES_FILE = Path(__file__).parent / "categories.json"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("pipeline-bot")

# ---------------------------------------------------------------------------
# Discord setup
# ---------------------------------------------------------------------------
intents = discord.Intents.default()
client = discord.Client(intents=intents)
tree = app_commands.CommandTree(client)

# ---------------------------------------------------------------------------
# Load categories from JSON
# ---------------------------------------------------------------------------
def _load_categories() -> dict:
    if CATEGORIES_FILE.exists():
        return json.loads(CATEGORIES_FILE.read_text())
    return {
        "bug": {"name": "Bug", "label_id": "", "emoji": "🐛", "description": "Something isn't working correctly"},
        "feature": {"name": "Feature Request", "label_id": "", "emoji": "💡", "description": "New feature or improvement"},
    }

CATEGORIES = _load_categories()

SEVERITIES = {
    "crash": {"name": "Crash / Data Loss", "priority": 1, "emoji": "🔴", "description": "App crashes, freezes, or data is lost"},
    "bug": {"name": "Bug", "priority": 2, "emoji": "🟠", "description": "Something isn't working correctly"},
    "visual_glitch": {"name": "Visual Glitch", "priority": 3, "emoji": "🟡", "description": "Display issue, layout problem, cosmetic"},
    "feature_request": {"name": "Feature Request", "priority": 4, "emoji": "🟢", "description": "Suggestion for a new feature"},
}

STATUS_EMOJI = {
    "Backlog": "📋", "Todo": "📝", "In Progress": "🔧", "Human Review": "👀",
    "Gate Approved": "✅", "Rework": "🔄", "Done": "🎉", "Canceled": "❌",
    "Cancelled": "❌", "Duplicate": "♻️", "In Review": "🔍",
}

# ---------------------------------------------------------------------------
# Thread map persistence
# ---------------------------------------------------------------------------
_thread_map: dict[str, int] = {}

def _load_thread_map() -> None:
    global _thread_map
    if THREAD_MAP_FILE.exists():
        try:
            _thread_map = json.loads(THREAD_MAP_FILE.read_text())
        except Exception:
            _thread_map = {}

def _save_thread_map() -> None:
    THREAD_MAP_FILE.write_text(json.dumps(_thread_map, indent=2))

def _store_thread(linear_issue_id: str, thread_id: int) -> None:
    _thread_map[linear_issue_id] = thread_id
    _save_thread_map()

def _get_thread_id(linear_issue_id: str) -> Optional[int]:
    return _thread_map.get(linear_issue_id)

# ---------------------------------------------------------------------------
# Linear GraphQL helpers
# ---------------------------------------------------------------------------
async def linear_request(query: str, variables: Optional[dict] = None) -> dict:
    async with httpx.AsyncClient() as http:
        resp = await http.post(
            LINEAR_API,
            json={"query": query, "variables": variables or {}},
            headers={"Authorization": LINEAR_API_KEY, "Content-Type": "application/json"},
            timeout=30,
        )
        resp.raise_for_status()
        data = resp.json()
        if "errors" in data:
            raise RuntimeError(f"Linear API error: {data['errors']}")
        return data["data"]

async def create_linear_issue(title: str, description: str, priority: int, label_ids: list) -> dict:
    mutation = """
    mutation CreateIssue($input: IssueCreateInput!) {
        issueCreate(input: $input) {
            success
            issue { id identifier url title }
        }
    }
    """
    input_data = {
        "title": title, "description": description,
        "priority": priority, "teamId": LINEAR_TEAM_ID,
        "labelIds": [lid for lid in label_ids if lid],
    }
    if LINEAR_PROJECT_ID:
        input_data["projectId"] = LINEAR_PROJECT_ID
    data = await linear_request(mutation, {"input": input_data})
    result = data["issueCreate"]
    if not result["success"]:
        raise RuntimeError("Linear issue creation failed")
    return result["issue"]

# ---------------------------------------------------------------------------
# Forum post helpers
# ---------------------------------------------------------------------------
async def create_forum_post(issue, category, severity, reporter) -> Optional[discord.Thread]:
    if not FORUM_CHANNEL_ID:
        return None
    forum = client.get_channel(FORUM_CHANNEL_ID)
    if forum is None:
        try:
            forum = await client.fetch_channel(FORUM_CHANNEL_ID)
        except Exception:
            return None
    if not isinstance(forum, discord.ForumChannel):
        return None

    admin_ping = f"<@{ADMIN_USER_ID}>" if ADMIN_USER_ID else ""
    content = (
        f"**{severity['emoji']} {issue['identifier']}: {issue['title']}**\n\n"
        f"**Category:** {category['emoji']} {category['name']}\n"
        f"**Severity:** {severity['emoji']} {severity['name']}\n"
        f"**Reported by:** {reporter.mention}\n"
        f"**Linear:** {issue['url']}\n\n{admin_ping}\n\n"
        f"Status updates will be posted here as the issue moves through the pipeline."
    )
    try:
        result = await forum.create_thread(name=f"{issue['identifier']}: {issue['title'][:80]}", content=content)
        log.info("Forum post created for %s", issue["identifier"])
        return result.thread
    except Exception as e:
        log.error("Failed to create forum post for %s: %s", issue["identifier"], e)
        return None

async def _create_forum_post_from_webhook(issue_id, identifier, title, url, state) -> Optional[discord.Thread]:
    if not FORUM_CHANNEL_ID:
        return None
    forum = client.get_channel(FORUM_CHANNEL_ID)
    if forum is None:
        try:
            forum = await client.fetch_channel(FORUM_CHANNEL_ID)
        except Exception:
            return None
    if not isinstance(forum, discord.ForumChannel):
        return None

    emoji = STATUS_EMOJI.get(state, "📌")
    admin_ping = f"<@{ADMIN_USER_ID}>" if ADMIN_USER_ID else ""
    content = (
        f"**{emoji} {identifier}: {title}**\n\n"
        f"**Current status:** {state}\n"
        f"**Linear:** {url}\n\n{admin_ping}\n\n"
        f"Status updates will be posted here as the issue moves through the pipeline."
    )
    try:
        result = await forum.create_thread(name=f"{identifier}: {title[:80]}", content=content)
        return result.thread
    except Exception as e:
        log.error("Failed to create forum post from webhook for %s: %s", identifier, e)
        return None

# ---------------------------------------------------------------------------
# Report form
# ---------------------------------------------------------------------------
class ReportModal(discord.ui.Modal, title="Issue Report"):
    issue_title = discord.ui.TextInput(label="Issue Title", placeholder="Short summary", style=discord.TextStyle.short, required=True, max_length=200)
    description = discord.ui.TextInput(label="What's happening?", placeholder="What were you doing? What did you expect?", style=discord.TextStyle.paragraph, required=True, max_length=2000)
    steps_to_reproduce = discord.ui.TextInput(label="Steps to reproduce", placeholder="1. Open app\n2. Do X\n3. See error", style=discord.TextStyle.paragraph, required=False, max_length=1500)
    troubleshooting = discord.ui.TextInput(label="What have you already tried?", placeholder="e.g. Restarted, reconnected, checked logs...", style=discord.TextStyle.paragraph, required=False, max_length=1000)
    logs_info = discord.ui.TextInput(label="Logs / extra info", placeholder="Error messages, version number, log snippet", style=discord.TextStyle.paragraph, required=False, max_length=1500)

    def __init__(self, category_key: str, severity_key: str):
        super().__init__()
        self.category_key = category_key
        self.severity_key = severity_key

    def _build_description(self, interaction):
        cat = CATEGORIES[self.category_key]
        sev = SEVERITIES[self.severity_key]
        sections = [
            f"**Reported by:** {interaction.user.display_name} (Discord)",
            f"**Category:** {cat['emoji']} {cat['name']}",
            f"**Severity:** {sev['emoji']} {sev['name']}",
            f"**Date:** {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}",
            "", "## Description", self.description.value,
        ]
        if self.steps_to_reproduce.value:
            sections += ["", "## Steps to Reproduce", self.steps_to_reproduce.value]
        if self.troubleshooting.value:
            sections += ["", "## Troubleshooting Already Tried", self.troubleshooting.value]
        if self.logs_info.value:
            sections += ["", "## Logs / Extra Info", f"```\n{self.logs_info.value}\n```"]
        return sections

    async def on_submit(self, interaction):
        await interaction.response.defer(thinking=True)
        cat = CATEGORIES[self.category_key]
        sev = SEVERITIES[self.severity_key]
        sections = self._build_description(interaction)
        sections += ["", "---", f"*Category: {cat['name']}*"]
        label_ids = [cat.get("label_id", "")]

        try:
            issue = await create_linear_issue(self.issue_title.value, "\n".join(sections), sev["priority"], label_ids)
            embed = discord.Embed(
                title=f"{sev['emoji']} {issue['identifier']}: {issue['title']}",
                color=discord.Color.green(), description="Issue created. Our team will investigate.",
            )
            embed.add_field(name="Category", value=f"{cat['emoji']} {cat['name']}", inline=True)
            embed.add_field(name="Severity", value=f"{sev['emoji']} {sev['name']}", inline=True)
            embed.add_field(name="Ticket", value=issue["identifier"], inline=True)
            embed.set_footer(text=f"Submitted by {interaction.user.display_name}")
            await interaction.followup.send(content="Thanks for the report!", embed=embed)
            log.info("Issue created: %s '%s' by %s", issue["identifier"], issue["title"], interaction.user.display_name)

            try:
                thread = await create_forum_post(issue=issue, category=cat, severity=sev, reporter=interaction.user)
                if thread:
                    _store_thread(issue["id"], thread.id)
            except Exception as e:
                log.warning("Forum post creation failed for %s: %s", issue["identifier"], e)
        except Exception as e:
            log.error("Failed to create issue: %s", e)
            await interaction.followup.send(f"Sorry, something went wrong. Error: {e}", ephemeral=True)

# ---------------------------------------------------------------------------
# Selectors
# ---------------------------------------------------------------------------
class SeveritySelect(discord.ui.Select):
    def __init__(self, category_key):
        self.category_key = category_key
        options = [discord.SelectOption(label=s["name"], value=k, description=s["description"], emoji=s["emoji"]) for k, s in SEVERITIES.items()]
        super().__init__(placeholder="How severe is the issue?", options=options, min_values=1, max_values=1)
    async def callback(self, interaction):
        await interaction.response.send_modal(ReportModal(self.category_key, self.values[0]))

class SeverityView(discord.ui.View):
    def __init__(self, category_key):
        super().__init__(timeout=120)
        self.add_item(SeveritySelect(category_key))

class CategorySelect(discord.ui.Select):
    def __init__(self):
        options = [discord.SelectOption(label=c["name"], value=k, description=c.get("description", ""), emoji=c["emoji"]) for k, c in CATEGORIES.items()]
        super().__init__(placeholder="Which area is this about?", options=options, min_values=1, max_values=1)
    async def callback(self, interaction):
        cat = CATEGORIES[self.values[0]]
        await interaction.response.edit_message(content=f"**Category:** {cat['emoji']} {cat['name']}\n\n**Now select the severity:**", view=SeverityView(self.values[0]))

class CategoryView(discord.ui.View):
    def __init__(self):
        super().__init__(timeout=120)
        self.add_item(CategorySelect())

@tree.command(name="report", description="Report a bug, crash, or feature request")
async def report_command(interaction):
    await interaction.response.send_message("**Issue Report**\n\nWhich area is this about?", view=CategoryView(), ephemeral=True)

# ---------------------------------------------------------------------------
# Webhook server
# ---------------------------------------------------------------------------
async def handle_webhook(request):
    try:
        payload = await request.json()
    except Exception:
        return web.Response(status=400, text="Invalid JSON")
    if payload.get("type") != "Issue":
        return web.Response(status=200, text="OK")

    issue_data = payload.get("data", {})
    issue_id = issue_data.get("id")
    identifier = issue_data.get("identifier", "?")
    title = issue_data.get("title", "")
    url = issue_data.get("url", "")
    if "stateId" not in payload.get("updatedFrom", {}):
        return web.Response(status=200, text="OK")

    new_state = issue_data.get("state", {}).get("name", "Unknown")
    emoji = STATUS_EMOJI.get(new_state, "📌")

    thread_id = _get_thread_id(issue_id)
    if not thread_id:
        try:
            thread = await _create_forum_post_from_webhook(issue_id, identifier, title, url, new_state)
            if thread:
                _store_thread(issue_id, thread.id)
                thread_id = thread.id
            else:
                return web.Response(status=200, text="OK")
        except Exception:
            return web.Response(status=200, text="OK")

    try:
        thread = client.get_channel(thread_id) or await client.fetch_channel(thread_id)
        msg = f"{emoji} **Status: {new_state}**\n*{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}*"
        if new_state == "Done":
            msg += "\n\n🎉 This issue has been resolved!"
        elif new_state in ("Canceled", "Cancelled"):
            msg += "\n\n❌ This issue has been cancelled."
        await thread.send(msg)
    except Exception as e:
        log.error("Failed to post status update for %s: %s", identifier, e)
    return web.Response(status=200, text="OK")

async def handle_health(request):
    return web.Response(status=200, text="OK")

async def start_webhook_server():
    app = web.Application()
    app.router.add_post("/webhook", handle_webhook)
    app.router.add_get("/health", handle_health)
    runner = web.AppRunner(app)
    await runner.setup()
    ssl_context = None
    if SSL_CERT and SSL_KEY and Path(SSL_CERT).exists() and Path(SSL_KEY).exists():
        ssl_context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ssl_context.load_cert_chain(SSL_CERT, SSL_KEY)
        log.info("SSL enabled with cert %s", SSL_CERT)
    site = web.TCPSite(runner, "0.0.0.0", WEBHOOK_PORT, ssl_context=ssl_context)
    await site.start()
    log.info("Webhook server listening on %s://0.0.0.0:%s", "https" if ssl_context else "http", WEBHOOK_PORT)

@client.event
async def on_ready():
    await tree.sync()
    log.info("Bot ready as %s — /report command synced", client.user)
    await start_webhook_server()

def main():
    for var in ("DISCORD_BOT_TOKEN", "LINEAR_API_KEY", "LINEAR_TEAM_ID"):
        if not os.environ.get(var):
            raise SystemExit(f"{var} not set")
    _load_thread_map()
    client.run(DISCORD_TOKEN)

if __name__ == "__main__":
    main()
