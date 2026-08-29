# malandr

Personal tooling and agent environment configs.

## What’s here

| Path | Purpose |
|------|---------|
| `tmux/tmux.conf` | tmux: mouse, history, splits, status |
| `cursor/statusline.sh` | Cursor Agent CLI status line (usage, ctx, **workspace path**) |
| `cursor/cli-config.json` | Cursor CLI preferences (no auth secrets) |
| `cursor/mcp.json` | MCP servers (env-based OAuth) |
| `claude/statusline-command.sh` | Claude Code status line |
| `claude/settings.json` | Claude Code settings |
| `codex/config.toml` | Codex TUI status line (model, cwd, git, ctx, rate limits) |
| `agents/skills/` | Custom Cursor / agent skills |
| `bin/` | agent-browser handoff + desktop helpers |
| `shell/bashrc-agents.sh` | tmux picker (local + SSH), PATH |
| `install.sh` | Symlink (or copy) into `$HOME` |

## Install on a new machine

```bash
git clone git@github.com:malandr/malandr.git ~/projects/malandr
~/projects/malandr/install.sh        # symlinks
# or: ~/projects/malandr/install.sh copy
```

Edit `~/.agent-browser/handoff.env` for VNC/noVNC display settings.

## Notes

- Auth tokens are **not** stored in this repo. Sign in to Cursor / Claude / providers on each host.
- `FreeHeroku` and `links` are legacy files kept for history.
