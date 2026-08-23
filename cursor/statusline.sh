#!/usr/bin/env bash
set -euo pipefail

payload=$(cat)

# --- helpers ---
pct() {
  local v="${1:-0}"
  if awk "BEGIN {exit !($v > 0 && $v < 1)}"; then
    echo "1"
  else
    printf '%.0f' "$v"
  fi
}

fmt_money_cents() {
  local cents="${1:-0}"
  awk -v c="$cents" 'BEGIN { printf "$%.2f", c/100 }'
}

fmt_duration() {
  local secs="${1:-0}"
  if (( secs < 0 )); then secs=0; fi
  local days=$((secs / 86400))
  local hours=$(((secs % 86400) / 3600))
  local mins=$(((secs % 3600) / 60))
  if (( days > 0 )); then
    printf '%dd %dh' "$days" "$hours"
  elif (( hours > 0 )); then
    printf '%dh %dm' "$hours" "$mins"
  else
    printf '%dm' "$mins"
  fi
}

epoch_from_ms() {
  local ms="${1:-0}"
  awk -v m="$ms" 'BEGIN { if (m > 0) print int(m/1000); else print 0 }'
}

epoch_from_iso() {
  local iso="${1:-}"
  [[ -n "$iso" && "$iso" != "null" ]] || { echo 0; return; }
  date -d "$iso" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S' "${iso%%.*}" +%s 2>/dev/null || echo 0
}

period_stats() {
  local start_epoch="$1" end_epoch="$2" now_epoch="$3"
  if (( start_epoch <= 0 || end_epoch <= 0 || end_epoch <= start_epoch )); then
    echo "0 0 0"
    return
  fi
  local total=$((end_epoch - start_epoch))
  local elapsed=$((now_epoch - start_epoch))
  local remaining=$((end_epoch - now_epoch))
  if (( elapsed < 0 )); then elapsed=0; fi
  if (( remaining < 0 )); then remaining=0; fi
  local elapsed_pct
  elapsed_pct=$(awk -v e="$elapsed" -v t="$total" 'BEGIN { if (t > 0) printf "%.0f", (e/t)*100; else print 0 }')
  echo "$remaining $elapsed_pct $total"
}

bar() {
  local pct="${1:-0}" width="${2:-10}"
  local filled
  filled=$(awk -v p="$pct" -v w="$width" 'BEGIN { v=int(p*w/100); if (v<0) v=0; if (v>w) v=w; print v }')
  local empty=$((width - filled))
  local out=""
  if (( filled > 0 )); then
    printf -v pad '%*s' "$filled" ''
    out="${pad// /▓}"
  fi
  if (( empty > 0 )); then
    printf -v pad '%*s' "$empty" ''
    out="${out}${pad// /░}"
  fi
  printf '%s' "$out"
}

short_path() {
  local p="${1:-}"
  if [[ -z "$p" ]]; then
    echo "?"
    return
  fi
  local home="${HOME:-}"
  if [[ -n "$home" && "$p" == "$home" ]]; then
    echo "~"
  elif [[ -n "$home" && "$p" == "$home"/* ]]; then
    echo "~/${p#"$home"/}"
  else
    echo "$p"
  fi
}

# --- session payload ---
MODEL=$(jq -r '.model.display_name // "?"' <<<"$payload")
MODEL_ID=$(jq -r '.model.id // ""' <<<"$payload")
PARAMS=$(jq -r '.model.param_summary // empty' <<<"$payload")
MAX_MODE=$(jq -r 'if .model.max_mode == true then "max" else empty end' <<<"$payload")
SESSION=$(jq -r '.session_name // .session_id[0:8] // "?"' <<<"$payload")
CWD=$(jq -r '.workspace.current_dir // .cwd // ""' <<<"$payload")
DIR_NAME=$(basename "$CWD")
# Prefer a readable workspace path (~/…); fall back to folder name.
FOLDER=$(short_path "$CWD")
# Keep path compact on narrow terminals: last two components if long.
if [[ ${#FOLDER} -gt 40 && "$FOLDER" == */*/* ]]; then
  FOLDER="…/$(basename "$(dirname "$FOLDER")")/$(basename "$FOLDER")"
fi
[[ -n "$FOLDER" && "$FOLDER" != "?" ]] || FOLDER="${DIR_NAME:-?}"
AUTORUN=$(jq -r 'if .autorun == true then "yolo" else "manual" end' <<<"$payload")
VERSION=$(jq -r '.version // ""' <<<"$payload")
STYLE=$(jq -r '.output_style.name // "default"' <<<"$payload")
WIDTH=$(jq -r '.render_width_chars // 120' <<<"$payload")

CTX_USED=$(jq -r '.context_window.used_percentage // 0' <<<"$payload")
CTX_REM=$(jq -r '.context_window.remaining_percentage // empty' <<<"$payload")
CTX_IN=$(jq -r '.context_window.total_input_tokens // empty' <<<"$payload")
CTX_OUT=$(jq -r '.context_window.total_output_tokens // empty' <<<"$payload")
CTX_SIZE=$(jq -r '.context_window.context_window_size // empty' <<<"$payload")
CUR_IN=$(jq -r '.context_window.current_usage.input_tokens // empty' <<<"$payload")
CUR_OUT=$(jq -r '.context_window.current_usage.output_tokens // empty' <<<"$payload")

VIM=$(jq -r '.vim.mode // empty' <<<"$payload")
WORKTREE=$(jq -r 'if .worktree.name then "\(.worktree.name)" else empty end' <<<"$payload")

# --- local config ---
CLI_CONFIG="${HOME}/.cursor/cli-config.json"
APPROVAL=$(jq -r '.approvalMode // "allowlist"' "$CLI_CONFIG" 2>/dev/null || echo "allowlist")
SANDBOX=$(jq -r '.sandbox.mode // "disabled"' "$CLI_CONFIG" 2>/dev/null || echo "disabled")
NET_ACCESS=$(jq -r '.sandbox.networkAccess // ""' "$CLI_CONFIG" 2>/dev/null || echo "")

# --- git ---
BRANCH=""
if git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
  BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || true)
  if [[ -z "$BRANCH" ]]; then
    BRANCH="(detached)"
  fi
  if [[ -n "$(git -C "$CWD" status --porcelain 2>/dev/null)" ]]; then
    BRANCH="${BRANCH}*"
  fi
fi

# --- usage cache (refresh every 60s) ---
CACHE_FILE="${HOME}/.cursor/statusline-usage-cache.json"
CACHE_TTL=60
NOW=$(date +%s)
fetch_usage() {
  local auth_file="${HOME}/.config/cursor/auth.json"
  [[ -f "$auth_file" ]] || return 1
  local token
  token=$(jq -r '.accessToken // empty' "$auth_file")
  [[ -n "$token" && "$token" != "null" ]] || return 1

  local api="https://api2.cursor.sh/aiserver.v1.DashboardService"
  local headers=(
    -H "Authorization: Bearer ${token}"
    -H "Content-Type: application/json"
    -H "Connect-Protocol-Version: 1"
  )

  local usage plan hard sand
  usage=$(curl -fsS -m 2 -X POST "${api}/GetCurrentPeriodUsage" "${headers[@]}" -d '{}' 2>/dev/null || true)
  plan=$(curl -fsS -m 2 -X POST "${api}/GetPlanInfo" "${headers[@]}" -d '{}' 2>/dev/null || true)
  hard=$(curl -fsS -m 2 -X POST "${api}/GetHardLimit" "${headers[@]}" -d '{}' 2>/dev/null || true)
  sand=$(curl -fsS -m 2 -X POST "${api}/GetSandUsageStatus" "${headers[@]}" -d '{}' 2>/dev/null || true)

  [[ -n "$usage" ]] || return 1
  [[ -n "$plan" ]] || plan='{}'
  [[ -n "$hard" ]] || hard='{}'
  [[ -n "$sand" ]] || sand='{}'
  jq -n \
    --argjson fetched_at "$NOW" \
    --argjson usage "$usage" \
    --argjson plan "$plan" \
    --argjson hard "$hard" \
    --argjson sand "$sand" \
    '{fetched_at: $fetched_at, usage: $usage, plan: $plan, hard: $hard, sand: $sand}'
}

CACHED_AT=0
if [[ -s "$CACHE_FILE" ]]; then
  CACHED_AT=$(jq -r '.fetched_at // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
  [[ "$CACHED_AT" =~ ^[0-9]+$ ]] || CACHED_AT=0
fi
CACHE_AGE=$((NOW - CACHED_AT))

if (( CACHE_AGE >= CACHE_TTL )); then
  if NEW_CACHE=$(fetch_usage); then
    # Write atomically: the statusline runner may kill this process mid-write,
    # and a truncated cache file would break every subsequent invocation.
    printf '%s\n' "$NEW_CACHE" >"${CACHE_FILE}.tmp" && mv -f "${CACHE_FILE}.tmp" "$CACHE_FILE"
  fi
fi

USAGE_JSON='{}'
PLAN_JSON='{}'
HARD_JSON='{}'
SAND_JSON='{}'
if [[ -s "$CACHE_FILE" ]]; then
  USAGE_JSON=$(jq -c '.usage // {}' "$CACHE_FILE" 2>/dev/null || echo '{}')
  PLAN_JSON=$(jq -c '.plan // {}' "$CACHE_FILE" 2>/dev/null || echo '{}')
  HARD_JSON=$(jq -c '.hard // {}' "$CACHE_FILE" 2>/dev/null || echo '{}')
  SAND_JSON=$(jq -c '.sand // {}' "$CACHE_FILE" 2>/dev/null || echo '{}')
  [[ -n "$USAGE_JSON" ]] || USAGE_JSON='{}'
  [[ -n "$PLAN_JSON" ]] || PLAN_JSON='{}'
  [[ -n "$HARD_JSON" ]] || HARD_JSON='{}'
  [[ -n "$SAND_JSON" ]] || SAND_JSON='{}'
fi

PLAN_NAME=$(jq -r '.planInfo.planName // "?"' <<<"$PLAN_JSON")
PLAN_PRICE=$(jq -r '.planInfo.price // ""' <<<"$PLAN_JSON")
INCLUDED_CENTS=$(jq -r '.planInfo.includedAmountCents // 0' <<<"$PLAN_JSON")
BILLING_START_MS=$(jq -r '.billingCycleStart // empty' <<<"$USAGE_JSON")
BILLING_END_MS=$(jq -r '.planInfo.billingCycleEnd // empty' <<<"$PLAN_JSON")
if [[ -z "$BILLING_END_MS" || "$BILLING_END_MS" == "null" ]]; then
  BILLING_END_MS=$(jq -r '.billingCycleEnd // empty' <<<"$USAGE_JSON")
fi

BILLING_START_EPOCH=$(epoch_from_ms "$BILLING_START_MS")
BILLING_END_EPOCH=$(epoch_from_ms "$BILLING_END_MS")
read -r MONTHLY_RESET_SECS MONTHLY_ELAPSED_PCT _ < <(period_stats "$BILLING_START_EPOCH" "$BILLING_END_EPOCH" "$NOW")
MONTHLY_RESET_IN=$(fmt_duration "$MONTHLY_RESET_SECS")

SAND_START_ISO=$(jq -r '.currentPeriodStart // empty' <<<"$SAND_JSON")
SAND_END_ISO=$(jq -r '.nextResetTimestampUtc // empty' <<<"$SAND_JSON")
SAND_PCT=$(jq -r '.usagePercent // empty' <<<"$SAND_JSON")
SAND_LABEL=$(jq -r '.grokPlanLabel // "sand"' <<<"$SAND_JSON")
SAND_START_EPOCH=$(epoch_from_iso "$SAND_START_ISO")
SAND_END_EPOCH=$(epoch_from_iso "$SAND_END_ISO")
read -r SAND_RESET_SECS SAND_ELAPSED_PCT _ < <(period_stats "$SAND_START_EPOCH" "$SAND_END_EPOCH" "$NOW")
SAND_RESET_IN=$(fmt_duration "$SAND_RESET_SECS")

TOTAL_SPEND=$(jq -r '.planUsage.totalSpend // 0' <<<"$USAGE_JSON")
INCLUDED_SPEND=$(jq -r '.planUsage.includedSpend // 0' <<<"$USAGE_JSON")
REMAINING=$(jq -r '.planUsage.remaining // 0' <<<"$USAGE_JSON")
LIMIT=$(jq -r '.planUsage.limit // 0' <<<"$USAGE_JSON")
TOTAL_PCT=$(jq -r '.planUsage.totalPercentUsed // 0' <<<"$USAGE_JSON")
AUTO_PCT=$(jq -r '.planUsage.autoPercentUsed // 0' <<<"$USAGE_JSON")
API_PCT=$(jq -r '.planUsage.apiPercentUsed // 0' <<<"$USAGE_JSON")
DISPLAY_MSG=$(jq -r '.displayMessage // ""' <<<"$USAGE_JSON")
ENABLED=$(jq -r '.enabled // false' <<<"$USAGE_JSON")

NO_ONDEMAND=$(jq -r '.noUsageBasedAllowed // false' <<<"$HARD_JSON")
HARD_LIMIT=$(jq -r '.hardLimit // empty' <<<"$HARD_JSON")

RESET_LABEL=""
if [[ -n "$BILLING_END_MS" && "$BILLING_END_MS" != "null" ]]; then
  RESET_LABEL=$(date -d "@$((BILLING_END_MS / 1000))" '+%b %-d' 2>/dev/null || date -r $((BILLING_END_MS / 1000)) '+%b %-d' 2>/dev/null || true)
fi
SAND_RESET_LABEL=""
if [[ -n "$SAND_END_ISO" && "$SAND_END_ISO" != "null" ]]; then
  SAND_RESET_LABEL=$(date -d "$SAND_END_ISO" '+%b %-d' 2>/dev/null || true)
fi

if [[ "$NO_ONDEMAND" == "true" ]]; then
  ONDEMAND="off"
elif [[ -n "$HARD_LIMIT" && "$HARD_LIMIT" != "null" ]]; then
  if awk -v h="$HARD_LIMIT" 'BEGIN { exit !(h >= 2147483647) }'; then
    ONDEMAND="unlimited"
  elif (( HARD_LIMIT > 0 )); then
    ONDEMAND="$(fmt_money_cents "$((HARD_LIMIT * 100))") cap"
  else
    ONDEMAND="off"
  fi
else
  ONDEMAND="?"
fi

# --- render ---
DIM='\033[90m'
CYAN='\033[36m'
BLUE='\033[34m'
GREEN='\033[32m'
YELLOW='\033[33m'
MAGENTA='\033[35m'
RESET='\033[0m'

MODEL_LINE="${CYAN}${MODEL}${RESET}"
[[ -n "$PARAMS" ]] && MODEL_LINE="${MODEL_LINE} ${DIM}${PARAMS}${RESET}"
[[ -n "$MAX_MODE" ]] && MODEL_LINE="${MODEL_LINE} ${YELLOW}${MAX_MODE}${RESET}"

LINE1="${MODEL_LINE} ${DIM}│${RESET} ${BLUE}${FOLDER}${RESET}"
[[ -n "$BRANCH" ]] && LINE1="${LINE1} ${GREEN}⎇ ${BRANCH}${RESET}"
[[ -n "$WORKTREE" ]] && LINE1="${LINE1} ${MAGENTA}wt:${WORKTREE}${RESET}"
LINE1="${LINE1} ${DIM}│${RESET} ${YELLOW}${AUTORUN}${RESET}/${APPROVAL}"
[[ "$SANDBOX" != "disabled" ]] && LINE1="${LINE1} ${DIM}│${RESET} sandbox:${SANDBOX}"
LINE1="${LINE1} ${DIM}│${RESET} ${PLAN_NAME}"
[[ -n "$PLAN_PRICE" ]] && LINE1="${LINE1} ${DIM}(${PLAN_PRICE})${RESET}"

INCLUDED_USED_PCT=$(pct "$TOTAL_PCT")
AUTO_USED_PCT=$(pct "$AUTO_PCT")
API_USED_PCT=$(pct "$API_PCT")
SPENT=$(fmt_money_cents "$INCLUDED_SPEND")
BUDGET=$(fmt_money_cents "$INCLUDED_CENTS")
LEFT=$(fmt_money_cents "$REMAINING")
LIMIT_MONEY=$(fmt_money_cents "$LIMIT")

INCLUDED_BAR=$(bar "$INCLUDED_USED_PCT" 8)
SAND_USED_PCT=$(pct "$SAND_PCT")
SAND_BAR=$(bar "$SAND_USED_PCT" 8)

LINE2="${BLUE}monthly${RESET} spend ${INCLUDED_USED_PCT}% ${DIM}(${INCLUDED_BAR})${RESET} ${SPENT}/${BUDGET} ${DIM}(${LEFT} left)${RESET}"
LINE2="${LINE2} ${DIM}│${RESET} auto ${AUTO_USED_PCT}% api ${API_USED_PCT}%"
if [[ -n "$MONTHLY_RESET_IN" && "$MONTHLY_RESET_IN" != "0m" ]]; then
  LINE2="${LINE2} ${DIM}│${RESET} reset ${YELLOW}${MONTHLY_RESET_IN}${RESET}"
  [[ -n "$RESET_LABEL" ]] && LINE2="${LINE2} ${DIM}(${RESET_LABEL})${RESET}"
  LINE2="${LINE2} ${DIM}│${RESET} period ${MONTHLY_ELAPSED_PCT}% elapsed"
fi

LINE3=""
if [[ -n "$SAND_PCT" && "$SAND_PCT" != "null" ]]; then
  LINE3="${MAGENTA}$(echo "$SAND_LABEL" | tr '[:upper:]' '[:lower:]')${RESET} spend ${SAND_USED_PCT}% ${DIM}(${SAND_BAR})${RESET}"
  if [[ -n "$SAND_RESET_IN" && "$SAND_RESET_IN" != "0m" ]]; then
    LINE3="${LINE3} ${DIM}│${RESET} reset ${YELLOW}${SAND_RESET_IN}${RESET}"
    [[ -n "$SAND_RESET_LABEL" ]] && LINE3="${LINE3} ${DIM}(${SAND_RESET_LABEL})${RESET}"
    LINE3="${LINE3} ${DIM}│${RESET} period ${SAND_ELAPSED_PCT}% elapsed"
  fi
  LINE3="${LINE3} ${DIM}│${RESET} on-demand ${ONDEMAND}"
else
  [[ -n "$DISPLAY_MSG" && "$ENABLED" == "true" ]] && LINE3="${DIM}${DISPLAY_MSG}${RESET} ${DIM}│${RESET} on-demand ${ONDEMAND}" || LINE3="on-demand ${ONDEMAND}"
fi

CTX_USED_INT=$(pct "$CTX_USED")
CTX_BAR=$(bar "$CTX_USED_INT" 10)
CTX_LINE="ctx ${CTX_USED_INT}% ${DIM}[${CTX_BAR}]${RESET}"
if [[ -n "$CTX_IN" && "$CTX_IN" != "null" ]]; then
  CTX_LINE="${CTX_LINE} in:$(printf "%'d" "$CTX_IN" 2>/dev/null || echo "$CTX_IN")"
fi
if [[ -n "$CTX_OUT" && "$CTX_OUT" != "null" ]]; then
  CTX_LINE="${CTX_LINE} out:$(printf "%'d" "$CTX_OUT" 2>/dev/null || echo "$CTX_OUT")"
fi
if [[ -n "$CTX_SIZE" && "$CTX_SIZE" != "null" ]]; then
  CTX_LINE="${CTX_LINE}/${CTX_SIZE}"
fi
if [[ -n "$CUR_IN" && "$CUR_IN" != "null" ]]; then
  CTX_LINE="${CTX_LINE} ${DIM}last:${CUR_IN}"
  [[ -n "$CUR_OUT" && "$CUR_OUT" != "null" ]] && CTX_LINE="${CTX_LINE}+${CUR_OUT}"
  CTX_LINE="${CTX_LINE}${RESET}"
fi

META="${DIM}${SESSION}"
[[ -n "$VERSION" ]] && META="${META} v${VERSION}"
META="${META} ${STYLE}"
[[ -n "$VIM" ]] && META="${META} vim:${VIM}"
META="${META}${RESET}"

printf '%b\n' "$LINE1"
printf '%b\n' "$LINE2"
[[ -n "$LINE3" ]] && printf '%b\n' "$LINE3"
printf '%b %b\n' "$CTX_LINE" "$META"
