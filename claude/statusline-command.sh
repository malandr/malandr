#!/usr/bin/env bash
# Comprehensive Claude Code status line.
# Reads the hook JSON payload from stdin and renders a multi-line status line
# covering location/git, model/session info, context-window usage, and
# rate-limit / cost details.

input=$(cat)

# ---- Colors (terminal already dims the status line, so keep it simple) ----
RESET=$'\033[0m'
BLUE=$'\033[34m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'
RED=$'\033[31m'
GRAY=$'\033[90m'

get() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Basic session / model fields
# ---------------------------------------------------------------------------
model_name=$(get '.model.display_name')
cwd=$(get '.workspace.current_dir')
output_style=$(get '.output_style.name')
effort=$(get '.effort.level')
thinking_enabled=$(get '.thinking.enabled')
vim_mode=$(get '.vim.mode')
agent_name=$(get '.agent.name')
worktree_name=$(get '.worktree.name')
worktree_branch=$(get '.worktree.branch')
pr_number=$(get '.pr.number')
pr_state=$(get '.pr.review_state')
pr_kind=$(get '.pr.kind')
repo_owner=$(get '.workspace.repo.owner')
repo_name=$(get '.workspace.repo.name')

dir_display="${cwd/#$HOME/\~}"

# ---------------------------------------------------------------------------
# Git info (branch, dirty state, ahead/behind) — locks skipped for safety
# ---------------------------------------------------------------------------
git_info=""
if [ -n "$cwd" ] && git --no-optional-locks -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git --no-optional-locks -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
  [ -z "$branch" ] && branch=$(git --no-optional-locks -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  dirty_count=$(git --no-optional-locks -C "$cwd" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  dirty_mark=""
  case "${dirty_count:-0}" in
    0|'') ;;
    *) dirty_mark="*" ;;
  esac
  ab=$(git --no-optional-locks -C "$cwd" rev-list --left-right --count 'HEAD...@{u}' 2>/dev/null)
  ab_str=""
  if [ -n "$ab" ]; then
    ahead=$(printf '%s' "$ab" | awk '{print $1}')
    behind=$(printf '%s' "$ab" | awk '{print $2}')
    [ "$ahead" != "0" ] && ab_str="${ab_str}+${ahead}"
    [ "$behind" != "0" ] && ab_str="${ab_str}-${behind}"
  fi
  git_info="${branch}${dirty_mark}"
  [ -n "$ab_str" ] && git_info="${git_info} ${ab_str}"
fi

# ---------------------------------------------------------------------------
# Context window usage
# ---------------------------------------------------------------------------
total_input_tokens=$(get '.context_window.total_input_tokens')
total_output_tokens=$(get '.context_window.total_output_tokens')
window_size=$(get '.context_window.context_window_size')
used_pct=$(get '.context_window.used_percentage')
remaining_pct=$(get '.context_window.remaining_percentage')

cur_input=$(get '.context_window.current_usage.input_tokens')
cur_output=$(get '.context_window.current_usage.output_tokens')
cache_write=$(get '.context_window.current_usage.cache_creation_input_tokens')
cache_read=$(get '.context_window.current_usage.cache_read_input_tokens')

# ---------------------------------------------------------------------------
# Rate limits — both the 5-hour session window and the 7-day weekly window
# ---------------------------------------------------------------------------
five_pct=$(get '.rate_limits.five_hour.used_percentage')
five_reset=$(get '.rate_limits.five_hour.resets_at')
week_pct=$(get '.rate_limits.seven_day.used_percentage')
week_reset=$(get '.rate_limits.seven_day.resets_at')

fmt_reset() {
  local epoch="$1"
  [ -z "$epoch" ] && return
  date -d "@$epoch" '+%a %H:%M' 2>/dev/null || date -r "$epoch" '+%a %H:%M' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Cost / lines changed (only present on some Claude Code versions; degrades
# gracefully to nothing if absent)
# ---------------------------------------------------------------------------
cost=$(get '.cost.total_cost_usd')
lines_added=$(get '.cost.total_lines_added')
lines_removed=$(get '.cost.total_lines_removed')

# ============================================================================
# Line 1: location, git, model, mode/session details
# ============================================================================
line1="${BLUE}${dir_display}${RESET}"
[ -n "$git_info" ] && line1="${line1} ${GREEN}(${git_info})${RESET}"
if [ -n "$repo_owner" ] && [ -n "$repo_name" ]; then
  line1="${line1} ${GRAY}${repo_owner}/${repo_name}${RESET}"
fi
[ -n "$model_name" ] && line1="${line1}  ${MAGENTA}${model_name}${RESET}"
[ -n "$output_style" ] && [ "$output_style" != "default" ] && line1="${line1} ${GRAY}[${output_style}]${RESET}"
[ -n "$effort" ] && line1="${line1} ${GRAY}eff:${effort}${RESET}"
[ "$thinking_enabled" = "true" ] && line1="${line1} ${GRAY}thinking${RESET}"
[ -n "$vim_mode" ] && line1="${line1} ${CYAN}${vim_mode}${RESET}"
[ -n "$agent_name" ] && line1="${line1} ${GRAY}agent:${agent_name}${RESET}"
if [ -n "$worktree_name" ]; then
  wt="${worktree_name}"
  [ -n "$worktree_branch" ] && wt="${wt}:${worktree_branch}"
  line1="${line1} ${YELLOW}wt:${wt}${RESET}"
fi
if [ -n "$pr_number" ]; then
  if [ "$pr_kind" = "mr" ]; then pr_label="MR !${pr_number}"; else pr_label="PR #${pr_number}"; fi
  line1="${line1} ${CYAN}${pr_label}(${pr_state:-open})${RESET}"
fi

# ============================================================================
# Line 2: context-window token usage
# ============================================================================
line2=""
if [ -n "$window_size" ] && [ "$window_size" != "0" ]; then
  used_fmt=$(printf '%.0f' "${used_pct:-0}")
  rem_fmt=$(printf '%.0f' "${remaining_pct:-0}")
  line2="${YELLOW}ctx${RESET} ${total_input_tokens:-0}+${total_output_tokens:-0}/${window_size} tok (${used_fmt}% used, ${rem_fmt}% left)"
  detail=""
  [ -n "$cur_input" ] && detail="${detail}in:${cur_input} "
  [ -n "$cur_output" ] && detail="${detail}out:${cur_output} "
  [ -n "$cache_write" ] && detail="${detail}cache-w:${cache_write} "
  [ -n "$cache_read" ] && detail="${detail}cache-r:${cache_read}"
  detail="${detail% }"
  [ -n "$detail" ] && line2="${line2} ${GRAY}[${detail}]${RESET}"
fi

# ============================================================================
# Line 3: rate limits — 5-hour window AND 7-day window, each with
# used %, remaining %, and reset time — plus session cost if available.
# ============================================================================
line3=""
if [ -n "$five_pct" ]; then
  five_used=$(printf '%.0f' "$five_pct")
  five_left=$((100 - five_used))
  five_reset_str=$(fmt_reset "$five_reset")
  line3="${RED}5h-limit${RESET}: ${five_used}% used / ${five_left}% left"
  [ -n "$five_reset_str" ] && line3="${line3} (resets ${five_reset_str})"
fi
if [ -n "$week_pct" ]; then
  week_used=$(printf '%.0f' "$week_pct")
  week_left=$((100 - week_used))
  week_reset_str=$(fmt_reset "$week_reset")
  [ -n "$line3" ] && line3="${line3}  |  "
  line3="${line3}${RED}7d-limit${RESET}: ${week_used}% used / ${week_left}% left"
  [ -n "$week_reset_str" ] && line3="${line3} (resets ${week_reset_str})"
fi
if [ -n "$cost" ]; then
  cost_fmt=$(printf '%.4f' "$cost")
  [ -n "$line3" ] && line3="${line3}  |  "
  line3="${line3}${GREEN}cost:\$${cost_fmt}${RESET}"
  if [ -n "$lines_added" ] || [ -n "$lines_removed" ]; then
    line3="${line3} ${GREEN}+${lines_added:-0}${RESET}/${RED}-${lines_removed:-0}${RESET}"
  fi
fi

printf '%s\n' "$line1"
[ -n "$line2" ] && printf '%s\n' "$line2"
[ -n "$line3" ] && printf '%s\n' "$line3"
exit 0
