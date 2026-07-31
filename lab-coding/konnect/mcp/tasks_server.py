#!/usr/bin/env python3
"""A tiny stdio MCP server for testing MCP tool calls through Kong.
Claude Code launches it (see mcp-config.json); its tools appear on the wire as
mcp__tasks__<tool>, which the straiker-coding plugin captures as PreToolUse."""
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("tasks")

@mcp.tool()
def add_task(title: str, priority: str = "normal") -> str:
    """Add a task to the team task list."""
    return f"Task added: '{title}' (priority={priority}), id=T-42"

@mcp.tool()
def list_tasks() -> str:
    """List the current tasks."""
    return "T-1 Review PR (high)\nT-2 Deploy staging (normal)\nT-3 Rotate token (high)"

@mcp.tool()
def get_project_config(project: str) -> str:
    """Get the deployment config for a project."""
    return f"project={project} env=staging quota=1000 autotrigger=true"

if __name__ == "__main__":
    mcp.run(transport="stdio")
