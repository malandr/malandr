#!/usr/bin/env bash
# Install malandr agent/tmux configs into $HOME (symlinks by default).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-link}" # link | copy

link_or_copy() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ -e "$dest" || -L "$dest" ]]; then
    local bak="${dest}.bak.$(date +%Y%m%d-%H%M%S)"
    echo "backup $dest -> $bak"
    mv "$dest" "$bak"
  fi
  if [[ "$MODE" == "copy" ]]; then
    cp -a "$src" "$dest"
    echo "copy  $src -> $dest"
  else
    ln -sfn "$src" "$dest"
    echo "link  $src -> $dest"
  fi
}

echo "Installing from $ROOT (mode=$MODE)"

link_or_copy "$ROOT/tmux/tmux.conf" "$HOME/.tmux.conf"
mkdir -p "$HOME/.cursor" "$HOME/.claude" "$HOME/.agents/skills" "$HOME/.local/bin"

link_or_copy "$ROOT/cursor/statusline.sh" "$HOME/.cursor/statusline.sh"
link_or_copy "$ROOT/cursor/cli-config.json" "$HOME/.cursor/cli-config.json"
link_or_copy "$ROOT/cursor/mcp.json" "$HOME/.cursor/mcp.json"

link_or_copy "$ROOT/claude/statusline-command.sh" "$HOME/.claude/statusline-command.sh"
link_or_copy "$ROOT/claude/settings.json" "$HOME/.claude/settings.json"

if [[ -d "$ROOT/agents/skills/cursor" ]]; then
  mkdir -p "$HOME/.cursor/skills"
  rsync -a "$ROOT/agents/skills/cursor/" "$HOME/.cursor/skills/"
fi
if [[ -d "$ROOT/agents/skills/agents" ]]; then
  mkdir -p "$HOME/.agents/skills"
  rsync -a "$ROOT/agents/skills/agents/" "$HOME/.agents/skills/"
fi
[[ -f "$ROOT/agents/skill-lock.json" ]] && cp "$ROOT/agents/skill-lock.json" "$HOME/.agents/.skill-lock.json"

for f in "$ROOT"/bin/*; do
  [[ -f "$f" ]] || continue
  link_or_copy "$f" "$HOME/.local/bin/$(basename "$f")"
  chmod +x "$HOME/.local/bin/$(basename "$f")"
done

# Optional: agent-browser config
mkdir -p "$HOME/.agent-browser"
if [[ ! -f "$HOME/.agent-browser/config.json" ]]; then
  cp "$ROOT/cursor/agent-browser.config.json" "$HOME/.agent-browser/config.json"
  echo "wrote ~/.agent-browser/config.json"
fi
if [[ ! -f "$HOME/.agent-browser/handoff.env" ]]; then
  cp "$ROOT/cursor/handoff.env.example" "$HOME/.agent-browser/handoff.env"
  echo "wrote ~/.agent-browser/handoff.env (edit me)"
fi

# bashrc snippet once
MARKER="# >>> malandr agents >>>"
if ! grep -qF "$MARKER" "$HOME/.bashrc" 2>/dev/null; then
  {
    echo ""
    echo "$MARKER"
    echo "source \"$ROOT/shell/bashrc-agents.sh\""
    echo "# <<< malandr agents <<<"
  } >> "$HOME/.bashrc"
  echo "appended source to ~/.bashrc"
else
  echo "~/.bashrc already sources malandr snippet"
fi

echo "Done. Reload tmux with: tmux source-file ~/.tmux.conf"
echo "Restart Cursor Agent / Claude Code to pick up status lines."
