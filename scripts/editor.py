#!/usr/bin/env python3
"""davinchi-cloud editor: a Claude Agent SDK agent that edits in DaVinci Resolve.

Runs on the box with an Anthropic API key (not Claude Code / a subscription):

    export ANTHROPIC_API_KEY=sk-ant-...
    editor                                  # chat
    editor "import /mnt/media/footage and build a rough cut"   # one task, then exit

Tools: the davinci-resolve MCP (stdio, same server Claude Code uses) plus
read-only file tools to look at /mnt/media. Anything else is refused, not prompted.
Env: EDITOR_MODEL (default: SDK default), EDITOR_MAX_TURNS (default 60).
"""
import asyncio
import os
import pathlib
import sys

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    ResultMessage,
    TextBlock,
    ToolUseBlock,
)

BOX_NOTES = pathlib.Path.home() / ".claude" / "CLAUDE.md"


def options() -> ClaudeAgentOptions:
    notes = BOX_NOTES.read_text() if BOX_NOTES.exists() else ""
    return ClaudeAgentOptions(
        mcp_servers={
            "davinci-resolve": {
                "type": "stdio",
                "command": "/opt/scripts/start-mcp.sh",
                "env": {"MCP_TRANSPORT": "stdio"},
            }
        },
        strict_mcp_config=True,
        tools=["Read", "Glob", "Grep"],
        allowed_tools=["mcp__davinci-resolve", "Read", "Glob", "Grep"],
        permission_mode="dontAsk",
        system_prompt={
            "type": "preset",
            "preset": "claude_code",
            "append": "You are a video editor working in DaVinci Resolve through the "
                      "davinci-resolve MCP tools.\n\n" + notes,
        },
        cwd="/mnt/media" if os.path.isdir("/mnt/media") else str(pathlib.Path.home()),
        model=os.environ.get("EDITOR_MODEL") or None,
        max_turns=int(os.environ.get("EDITOR_MAX_TURNS", "60")),
        # Subscription tokens are for Claude Code; this agent bills the API key.
        env={"CLAUDE_CODE_OAUTH_TOKEN": ""},
    )


async def run_turn(client: ClaudeSDKClient, prompt: str) -> None:
    await client.query(prompt)
    async for msg in client.receive_response():
        if isinstance(msg, AssistantMessage):
            for block in msg.content:
                if isinstance(block, TextBlock):
                    print(block.text, flush=True)
                elif isinstance(block, ToolUseBlock):
                    action = block.input.get("action") if isinstance(block.input, dict) else None
                    name = block.name.removeprefix("mcp__davinci-resolve__")
                    print(f"  · {name}" + (f" {action}" if action else ""), flush=True)
        elif isinstance(msg, ResultMessage):
            cost = f"${msg.total_cost_usd:.3f}" if msg.total_cost_usd else ""
            print(f"  [{msg.num_turns} turns {cost}]".replace(" ]", "]"), flush=True)


async def main() -> int:
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("ANTHROPIC_API_KEY is not set (export it, or start the box with `up --anthropic-key`).",
              file=sys.stderr)
        return 2
    async with ClaudeSDKClient(options=options()) as client:
        if len(sys.argv) > 1:
            await run_turn(client, " ".join(sys.argv[1:]))
            return 0
        print("davinchi-cloud editor. Ask for an edit; empty line or Ctrl-D quits.")
        while True:
            try:
                prompt = input("\n> ").strip()
            except (EOFError, KeyboardInterrupt):
                break
            if not prompt:
                break
            await run_turn(client, prompt)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
