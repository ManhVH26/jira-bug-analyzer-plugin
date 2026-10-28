"""PreToolUse hook for A/B sandboxes run with claude.ai connectors: allow ONLY the read-only Confluence tools.

Real use reads specs through the claude.ai "Confluence MCP" connector, so measuring spec reading needs it; but the
same connector carries Jira tools on the REAL Jira, and other connectors reach mail, chat and drives. Hooks run even
under bypassPermissions, so this is the backstop for run.sh's --disallowedTools (names known today): any other
claude.ai connector tool — including one a connector adds later — is refused before it runs."""
import json
import sys

KEEP = {"confluence_get_page", "confluence_search", "confluence_get_page_children"}

name = json.load(sys.stdin).get("tool_name", "")
if name.startswith("mcp__claude_ai_"):
    if not (name.startswith("mcp__claude_ai_Confluence_MCP__") and name.rsplit("__", 1)[-1] in KEEP):
        print(f"A/B sandbox: {name} is blocked — only Confluence reads are allowed here", file=sys.stderr)
        sys.exit(2)
sys.exit(0)
