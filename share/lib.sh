# Shared settings and helpers for the lab scripts (lab, lab-loop, lab-worker, watchdog, hpc-submit).
# Sourced, not run.

LAB=${LAB_DIR:-/srv/lab}
PROJECTS=${PROJECTS_DIR:-/srv/projects}
SHARE=${AGENTBOX_SHARE:-/usr/local/share/agentbox}
AGENT_STATUS=${AGENT_STATUS_DIR:-/srv/agents/status}
export PATH="$HOME/.local/bin:$PATH"

# Settings the PI fills in, in /etc/agentbox/lab.conf (root-owned, so agents can't change them; the
# example explains each). Read as KEY=value lines, never run as code; numbers must be digits. A value still
# containing CHANGE-ME counts as unset (listed in CONF_PLACEHOLDERS): an unchanged ntfy topic would be shared
# with everyone who skipped that step, and CHANGE-ME is a valid GitHub login.
LAB_CONF=${LAB_CONF:-/etc/agentbox/lab.conf}
CONF_PLACEHOLDERS=""
load_conf() {
  local line key value
  [[ -r $LAB_CONF ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    [[ $line =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=([^[:space:]]*)[[:space:]]*$ ]] || continue
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    if [[ $value == *CHANGE-ME* ]]; then CONF_PLACEHOLDERS+=" $key"; continue; fi
    case $key in
      ORG|PI_GITHUB|NTFY_URL|WATCH_HPC|HPC_NAME|HPC_LOGIN_HOST|HPC_USER|HPC_SCRATCH_ROOT|HPC_HOME_ROOT|HPC_WHOLE_NODE_PARTITIONS|HPC_BALANCE_CMD) ;;
      DIGEST_HOUR|HPC_*|CODEX_*|CLAUDE_*|LEAD_*|DIRECTOR_*) [[ $value =~ ^[0-9]+$ ]] || continue ;;
      *) continue ;;
    esac
    printf -v "$key" '%s' "$value"
  done < "$LAB_CONF"
}
load_conf
LEAD_INTERVAL_MIN=${LEAD_INTERVAL_MIN:-20}
LEAD_MAX_IDLE_HOURS=${LEAD_MAX_IDLE_HOURS:-3}
DIRECTOR_INTERVAL_MIN=${DIRECTOR_INTERVAL_MIN:-60}
DIGEST_HOUR=${DIGEST_HOUR:-7}
HPC_AUTO_SUS_PER_JOB=${HPC_AUTO_SUS_PER_JOB:-2000}
HPC_AUTO_SUS_PER_DAY=${HPC_AUTO_SUS_PER_DAY:-10000}
HPC_LAB_SUS_PER_MONTH=${HPC_LAB_SUS_PER_MONTH:-50000}
HPC_CORES_PER_NODE=${HPC_CORES_PER_NODE:-0}
HPC_NAME=${HPC_NAME:-the cluster}
CODEX_AHEAD_PERCENT=${CODEX_AHEAD_PERCENT:-15}
# Codex credits: once the plan's window is used up, Codex keeps running on the account's
# credits. The lab spends at most CODEX_CREDITS_PER_WINDOW of them per 7-day window, spread evenly over what is
# left of the window, and never goes below CODEX_CREDITS_FLOOR (kept for the PI's own use). 0 turns credit use off.
CODEX_CREDITS_PER_WINDOW=${CODEX_CREDITS_PER_WINDOW:-0}
CODEX_CREDITS_FLOOR=${CODEX_CREDITS_FLOOR:-5000}
CLAUDE_LAB_RUNS_PER_WEEK=${CLAUDE_LAB_RUNS_PER_WEEK:-30}
CLAUDE_LAB_STOP_PERCENT=${CLAUDE_LAB_STOP_PERCENT:-60}
USAGE=$LAB/state/usage

die() { echo "$*" >&2; exit 1; }
now() { date +%Y-%m-%dT%H:%M:%S%z; }

shared_append() {  # shared_append <file> <line>: append to a file that both accounts write
  [[ -e $1 ]] || { : > "$1"; chmod 664 "$1"; }
  printf '%s\n' "$2" >> "$1"
}

# --- Registry: registry.json holds one entry per project: account, status, limit, description, created.

project_field() { jq -r --arg p "$1" ".projects[\$p].$2 // empty" "$LAB/registry.json"; }
project_exists() { [[ -n $(project_field "$1" account) ]]; }
projects_where() { jq -r --arg k "$1" --arg v "$2" '.projects | to_entries[] | select(.value[$k] == $v) | .key' "$LAB/registry.json"; }

registry_update() {  # registry_update <jq filter> [jq options...], under a lock
  local filter=$1; shift
  (
    flock 9
    jq "$@" "$filter" "$LAB/registry.json" > "$LAB/registry.json.tmp" && mv "$LAB/registry.json.tmp" "$LAB/registry.json"
  ) 9>"$LAB/state/registry.lock"
}

# --- Slurm: the lab's jobs are named lab:<project>:<role>:<issue>.

lab_jobs() {  # lab_jobs [project]: one line per job: id name state elapsed
  local prefix="lab:"
  [[ -n ${1:-} ]] && prefix="lab:$1:"
  squeue -h -o '%i %j %T %M' | awk -v p="$prefix" 'index($2, p) == 1'
}

# --- Agents

render_role() {  # render_role <role> KEY=value...: the role's instructions with {{KEY}} filled in
  local text pair
  text=$(cat "$LAB/roles/$1.md")
  shift
  for pair in "$@"; do
    text=${text//"{{${pair%%=*}}}"/"${pair#*=}"}   # quoted, so an & in the value stays an &
  done
  printf '%s\n' "$text"
}

# agent_flags <codex|claude> <role>: the model and effort flags for that kind of agent, one per
# line, from $LAB/models.conf, which the PI (or the director, on their decision) edits without sudo.
# Values are checked against fixed patterns, never run. LAB_EFFORT (lab spawn --effort) overrides
# the effort for one job.
agent_flags() {
  local tool=$1 role=$2 conf=$LAB/models.conf r cm ce lm le rest model="" effort=""
  [[ -r $conf ]] || return 0
  while read -r r cm ce lm le rest; do
    [[ $r == "$role" ]] || continue
    if [[ $tool == codex ]]; then model=$cm effort=$ce; else model=$lm effort=$le; fi
  done < <(grep -v '^[[:space:]]*#' "$conf")
  [[ -n ${LAB_EFFORT:-} ]] && effort=$LAB_EFFORT
  [[ $model =~ ^[a-z0-9][a-z0-9.-]*$ ]] || model=""
  [[ $effort =~ ^(low|medium|high|xhigh|max)$ ]] || effort=""
  if [[ $tool == codex ]]; then
    [[ -n $model ]] && printf '%s\n' -m "$model"
    [[ -n $effort ]] && printf '%s\n' -c "model_reasoning_effort=\"$effort\""
  else
    [[ -n $model ]] && printf '%s\n' --model "$model"
    [[ -n $effort ]] && printf '%s\n' --effort "$effort"
  fi
  return 0
}

# run_agent <codex|claude> <folder> <prompt> <log file> <last-message file>
# One non-interactive session that never stops to ask for permission. The Unix account is the sandbox:
# Codex's own sandbox would block package caches, Haskell builds and MPI's shared memory.
run_agent() {
  local model=$1 folder=$2 prompt=$3 log=$4 last=$5 flags
  # Workers have LAB_ROLE; lead and director passes are named by their log (lead-*, director-*).
  local role=${LAB_ROLE:-$(basename "$log" | cut -d- -f1)}
  mapfile -t flags < <(agent_flags "$model" "$role")
  case $model in
    codex)
      codex exec --json --skip-git-repo-check -C "$folder" -s danger-full-access \
        -c approval_policy=never "${flags[@]}" -o "$last" "$prompt" > "$log" 2> "${log%.*}.err" ;;
    claude)
      local code
      (cd "$folder" && claude -p "$prompt" --permission-mode auto --output-format json "${flags[@]}") > "$log" 2> "${log%.*}.err"
      code=$?
      jq -r '.result // empty' "$log" > "$last" 2> /dev/null
      return $code ;;
    *)
      echo "Unknown model: $model" >&2
      return 2 ;;
  esac
}

# --- Finite resources (lab-usage measures them; these read its summary)

codex_thread() {  # codex_thread <log>: the session (thread) id of a codex exec run, for `codex resume`
  jq -r 'select(.type == "thread.started") | .thread_id' "$1" 2> /dev/null | head -1
}

# record_run <model> <log> <project> <role> <issue>: add a run's tokens to usage/<model>-runs.tsv
# (epoch, project, role, issue, Slurm job, input tokens, cached input tokens, output tokens).
record_run() {
  local model=$1 log=$2 tokens="" thread record
  case $model in
    codex)
      thread=$(codex_thread "$log")
      record=$(find "${CODEX_HOME:-$HOME/.codex}/sessions" -name "rollout-*$thread.jsonl" 2> /dev/null | head -1)
      if [[ -n $thread && -n $record ]]; then
        tokens=$(grep '"token_count"' "$record" | tail -1 |
          jq -r '.payload.info.total_token_usage | [.input_tokens, .cached_input_tokens, .output_tokens] | @tsv' 2> /dev/null)
      fi ;;
    claude)
      tokens=$(jq -r '.usage | [.input_tokens, .cache_read_input_tokens, .output_tokens] | @tsv' "$log" 2> /dev/null) ;;
  esac
  [[ -n $tokens ]] || tokens=$'0\t0\t0'
  mkdir -p "$USAGE"
  shared_append "$USAGE/$model-runs.tsv" "$(date +%s)"$'\t'"$3"$'\t'"$4"$'\t'"$5"$'\t'"${SLURM_JOB_ID:--}"$'\t'"$tokens"
}

# codex_pressure: "ok"; "ahead" when the lab uses Codex faster than a window of at least a day
# allows (used % more than CODEX_AHEAD_PERCENT above elapsed %); "stop" when any window is 95% used,
# unless credits can carry on (codex_credit_pace).
codex_pressure() {
  [[ -f $USAGE/summary.json ]] || { echo ok; return; }
  local p
  p=$(codex_plan_pressure)
  [[ $p == stop ]] && p=$(codex_credit_pace)
  echo "$p"
}

# codex_credit_pace: with the plan's window used up, "ahead" (leads and workers run, no new explorers) while
# the credits spent in this window stay within an even share of CODEX_CREDITS_PER_WINDOW (plus 10%), else "stop".
# Records (time, window reset, balance) in credit-samples.tsv; the first sample of a window is its baseline.
codex_credit_pace() {
  local now reset balance first t0 b0
  now=$(date +%s)
  read -r reset balance < <(jq -r '[([.codex.windows[]?.resets_at] | max // 0), (.codex.credits // 0 | tonumber)] | @tsv' \
    "$USAGE/summary.json" 2> /dev/null) || { echo stop; return; }
  [[ -n $balance ]] && (( CODEX_CREDITS_PER_WINDOW > 0 )) || { echo stop; return; }
  shared_append "$USAGE/credit-samples.tsv" "$now"$'\t'"$reset"$'\t'"$balance"
  first=$(awk -F'\t' -v r="$reset" '$2 == r' "$USAGE/credit-samples.tsv" | head -1)
  t0=$(cut -f1 <<< "$first"); b0=$(cut -f3 <<< "$first")
  awk -v now="$now" -v reset="$reset" -v t0="$t0" -v b0="$b0" -v b="$balance" \
      -v w="$CODEX_CREDITS_PER_WINDOW" -v floor="$CODEX_CREDITS_FLOOR" 'BEGIN {
    if (b <= floor || reset <= now) { print "stop"; exit }
    span = reset - t0; frac = span > 0 ? (now - t0) / span : 1
    print ((b0 - b) <= w * frac + 0.1 * w ? "ahead" : "stop") }'
}

codex_plan_pressure() {
  # A window whose reset time has passed counts as empty until the next measurement.
  jq -r --argjson ahead "$CODEX_AHEAD_PERCENT" --argjson now "$(date +%s)" '[.codex.windows[]? | select(.resets_at > $now)] as $w
    | if any($w[]; .used_percent >= 95) then "stop"
      elif any($w[]; .window_minutes >= 1440 and .used_percent > .elapsed_percent + $ahead) then "ahead"
      else "ok" end' "$USAGE/summary.json"
}

# claude_week: the Claude plan's 7-day usage in percent, as last seen by a status line; 0 if that
# reading is from before the window's reset.
claude_week() {
  jq -r --argjson now "$(date +%s)" 'if (.seven_day.resets_at // 0) > $now then .seven_day.used_percentage else 0 end' \
    "$USAGE/claude-limits.json" 2> /dev/null || echo 0
}

# claude_room: succeeds if the lab may start another Claude run: fewer than CLAUDE_LAB_RUNS_PER_WEEK
# this week, and the plan's 7-day usage under CLAUDE_LAB_STOP_PERCENT. The rest of the plan is the PI's.
claude_room() {
  local runs week
  runs=$(awk -F'\t' -v t="$(( $(date +%s) - 7 * 86400 ))" '$1 >= t' "$USAGE/claude-runs.tsv" 2> /dev/null | grep -c . || true)
  week=$(claude_week)
  (( runs < CLAUDE_LAB_RUNS_PER_WEEK )) && awk -v w="${week:-0}" -v s="$CLAUDE_LAB_STOP_PERCENT" 'BEGIN {exit !(w < s)}'
}

# --- GitHub

agents_login() {  # the GitHub account the lab's agents use (cached for this process)
  [[ -n ${AGENTS_LOGIN:-} ]] || AGENTS_LOGIN=$(timeout 60 gh api user --jq .login < /dev/null 2> /dev/null)
  echo "$AGENTS_LOGIN"
}

LABELS=(
  "task|0e8a16|Work for a worker"
  "explore|5319e7|Open-ended exploration with a budget"
  "verify|fbca04|Independent check of a claimed result"
  "verified|0e8a16|Confirmed by a verifier"
  "verification-failed|b60205|A verifier could not confirm it"
  "inbox|d93f0b|For the PI"
  "ask|f9d0c4|For the PI; nobody waits for the answer"
  "interrupt|b60205|Pushed to the PI's phone"
  "notified|cccccc|Push notification sent"
  "charter-approval|0052cc|A new project waits for the PI's approval"
  "hpc-approval|0052cc|A held HPC job waits for the PI's approval"
  "proposal|bfd4f2|Proposed new project"
  "request|1d76db|the PI's request to the director"
  "digest|c5def5|Daily digest"
)

ensure_labels() {  # ensure_labels <owner/repo>
  local entry name color description
  for entry in "${LABELS[@]}"; do
    IFS='|' read -r name color description <<<"$entry"
    gh label create "$name" -R "$1" --color "$color" --description "$description" --force > /dev/null
  done
}

# pi_decision <owner/repo> <issue>: "approve" or "cancel" if the PI's latest comment starts with that
# word, nothing otherwise. Only unedited comments from the PI's own GitHub account count: the agents'
# account can't approve anything, and can't edit the PI's words into an approval.
pi_decision() {
  local body
  body=$(timeout 60 gh issue view "$2" -R "$1" --json comments \
    --jq "[.comments[] | select(.author.login == \"$PI_GITHUB\" and (.includesCreatedEdit | not)) | .body] | last // \"\"" < /dev/null)
  body=$(tr '[:upper:]' '[:lower:]' <<<"$body")
  if [[ $body =~ ^[[:space:]]*(approve|approved)([^[:alnum:]]|$) ]]; then
    echo approve
  elif [[ $body =~ ^[[:space:]]*(cancel|cancelled)([^[:alnum:]]|$) ]]; then
    echo cancel
  fi
}

# notify <title> <message> [url]: push a notification to the PI's phone through ntfy.
notify() {
  if [[ -z ${NTFY_URL:-} ]]; then
    echo "NTFY_URL isn't set in $LAB_CONF; not sent: $1: $2" >&2
    return 0
  fi
  local args=(-fsS -H "Title: $1")
  [[ -n ${3:-} ]] && args+=(-H "Click: $3")
  curl "${args[@]}" --data-raw "$2" "$NTFY_URL" > /dev/null
}
