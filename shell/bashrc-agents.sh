# Sourced from ~/.bashrc — agent / tmux helpers (from malandr/dotfiles)
export PATH="$HOME/.local/bin:$PATH"

# Auto-attach / create tmux on any new interactive shell (local or SSH)
if [[ -z "$TMUX" && $- == *i* ]]; then
    sessions=$(tmux list-sessions -F '#S' 2>/dev/null)
    if [[ -n "$sessions" ]]; then
        session=$(
            {
                echo "➕ New session"
                echo "$sessions"
            } | fzf --prompt="tmux > " --height=40% --reverse --border
        )
        if [[ "$session" == "➕ New session" ]]; then
            read -rp "Session name: " session
            [[ -n "$session" ]] && exec tmux new-session -s "$session"
        elif [[ -n "$session" ]]; then
            exec tmux attach-session -t "$session"
        fi
    else
        read -rp "No tmux sessions. New session name [main]: " session
        session=${session:-main}
        exec tmux new-session -s "$session"
    fi
fi

# SSH agent for GitHub (optional)
if [ -z "${SSH_AUTH_SOCK:-}" ] && [ -f "$HOME/.ssh/id_ed25519" ]; then
  eval "$(ssh-agent -s)" >/dev/null
  ssh-add "$HOME/.ssh/id_ed25519" 2>/dev/null
fi
