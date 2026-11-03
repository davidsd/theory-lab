# Shared settings and helpers for the lab scripts (lab, lab-loop, lab-worker, watchdog, hpc-submit).
# Sourced, not run.

LAB=${LAB_DIR:-/srv/lab}
PROJECTS=${PROJECTS_DIR:-/srv/projects}
SHARE=${AGENTBOX_SHARE:-/usr/local/share/agentbox}
AGENT_STATUS=${AGENT_STATUS_DIR:-/srv/agents/status}
export PATH="$HOME/.local/bin:$PATH"

# Settings, in three layers:
#   1. defaults, below;
#   2. /etc/agentbox/lab.conf: the PI's, root-owned, so agents can't change it (the example explains each
#      key); it also sets ceilings <KEY>_MAX for the working values;
#   3. $LAB/limits.conf: working values, lab-owned; the director edits it only on the PI's instruction,
#      via `lab set`. A value there can lower anything, but raise a key only up to its ceiling (<KEY>_MAX
#      in lab.conf, or lab.conf's own value of the key, or the default, when there is no ceiling).
# All are read as KEY=value lines, never run as code; numbers must be digits. load_conf may be called
# again at any time (the loops do, so changes apply without a restart); it recomputes from scratch.
# A lab.conf value still containing CHANGE-ME counts as unset (listed in CONF_PLACEHOLDERS): an unchanged
# ntfy topic would be shared with everyone who skipped that step, and CHANGE-ME is a valid GitHub login.
LAB_CONF=${LAB_CONF:-/etc/agentbox/lab.conf}
LIMITS_CONF=${LIMITS_CONF:-$LAB/limits.conf}
CONF_DEFAULTS=(LEAD_INTERVAL_MIN=20 LEAD_MAX_IDLE_HOURS=3 DIRECTOR_INTERVAL_MIN=60 DIGEST_HOUR=7
  HPC_AUTO_SUS_PER_JOB=2000 HPC_AUTO_SUS_PER_DAY=10000 HPC_LAB_SUS_PER_MONTH=50000 HPC_CORES_PER_NODE=0 HPC_GB_PER_CORE=0 HPC_BILLING_PER_SU=0
  "HPC_NAME=the cluster"
  CODEX_AHEAD_PERCENT=15
  # Codex credits: once the plan's window is used up, Codex keeps running on the account's credits. The
  # lab spends at most CODEX_CREDITS_PER_WINDOW of them per 7-day window, spread evenly over what is left
  # of the window, and never goes below CODEX_CREDITS_FLOOR (kept for the PI's own use). 0 turns credit use off.
  CODEX_CREDITS_PER_WINDOW=0 CODEX_CREDITS_FLOOR=5000
  CLAUDE_LAB_RUNS_PER_WEEK=30 CLAUDE_LAB_STOP_PERCENT=60
  # Which model runs what: DEFAULT_MODEL for agents `lab spawn` starts without --model, DIRECTOR_MODEL for
  # the director's passes (leads: the registry's lead_model). CLAUDE_FALLBACK: what a Claude pass does
  # when the lab's Claude share is used up: run on codex instead, or wait.
  # CLAUDE_CREDITS=on: past CLAUDE_LAB_STOP_PERCENT the lab keeps running on Claude, so the plan fills and
  # Claude Code continues on the account's usage credits (the PI buys them; "use the plan up to the stop
  # percent, then credits as needed"). The lab waits only once the credits run out (claude_credits_out).
  # AGENT_RUNNER: where workers, explorers and verifiers run. "systemd" (the default): each is a user
  # service in the shared, capped slice lab-agents.slice (AGENT_POOL_CPUS CPUs and AGENT_POOL_MEM_GB GB in
  # all, per account), and its computations go through Slurm (lab-run, srun, sbatch), so CPUs are held
  # only while something computes. "slurm": each agent is a Slurm job holding its CPUs for its whole run.
  # OpenAI API credits: Codex can also run on an OpenAI API key, in ~/.codex-api (each account's own
  # login). CODEX_API=on: once the plan's window is used up (and Codex credits can't carry on), Codex runs
  # go on the API instead of waiting. Leads may also put a chosen hard task on it (lab spawn --api "<why>"),
  # whatever the plan's pace. The lab's API spend stops at CODEX_API_BUDGET_USD (0: no API use).
  CODEX_API=off CODEX_API_BUDGET_USD=0
  DEFAULT_MODEL=codex DIRECTOR_MODEL=codex CLAUDE_FALLBACK=codex CLAUDE_CREDITS=off
  AGENT_RUNNER=systemd AGENT_POOL_CPUS=4 AGENT_POOL_MEM_GB=24)
# The working values limits.conf may set.
LIMIT_KEYS=(CLAUDE_LAB_STOP_PERCENT CLAUDE_LAB_RUNS_PER_WEEK CODEX_AHEAD_PERCENT CODEX_CREDITS_PER_WINDOW
  CODEX_CREDITS_FLOOR HPC_AUTO_SUS_PER_JOB HPC_AUTO_SUS_PER_DAY HPC_LAB_SUS_PER_MONTH
  LEAD_INTERVAL_MIN LEAD_MAX_IDLE_HOURS DIRECTOR_INTERVAL_MIN AGENT_POOL_CPUS AGENT_POOL_MEM_GB CODEX_API_BUDGET_USD)
POLICY_KEYS=(DEFAULT_MODEL DIRECTOR_MODEL CLAUDE_FALLBACK CLAUDE_CREDITS AGENT_RUNNER CODEX_API)
declare -gA CONF_SRC=() CONF_CEIL=()
CONF_PLACEHOLDERS=""

policy_ok() {  # policy_ok <key> <value>
  case $1 in
    DEFAULT_MODEL|DIRECTOR_MODEL) [[ $2 == claude || $2 == codex ]] ;;
    CLAUDE_FALLBACK) [[ $2 == codex || $2 == wait ]] ;;
    CLAUDE_CREDITS|CODEX_API) [[ $2 == on || $2 == off ]] ;;
    AGENT_RUNNER) [[ $2 == slurm || $2 == systemd ]] ;;
    *) return 1 ;;
  esac
}

conf_lines() {  # conf_lines <file>: KEY<TAB>value for each well-formed line
  local line
  [[ -r $1 ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    [[ $line =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=([^[:space:]]*)[[:space:]]*$ ]] || continue
    printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  done < "$1"
}

load_conf() {
  local pair key value ceil
  for pair in "${CONF_DEFAULTS[@]}"; do
    printf -v "${pair%%=*}" '%s' "${pair#*=}"; CONF_SRC[${pair%%=*}]=default
  done
  for key in "${LIMIT_KEYS[@]}"; do unset "${key}_MAX"; done
  CONF_PLACEHOLDERS=""
  while IFS=$'\t' read -r key value; do
    if [[ $value == *CHANGE-ME* ]]; then CONF_PLACEHOLDERS+=" $key"; continue; fi
    case $key in
      ORG|PI_GITHUB|NTFY_URL|WATCH_HPC|HPC_NAME|HPC_LOGIN_HOST|HPC_USER|HPC_SCRATCH_ROOT|HPC_HOME_ROOT|HPC_WHOLE_NODE_PARTITIONS|HPC_BALANCE_CMD|HPC_SCRATCH_FS|HPC_SCRATCH_GROUP) ;;
      DEFAULT_MODEL|DIRECTOR_MODEL|CLAUDE_FALLBACK|CLAUDE_CREDITS|AGENT_RUNNER|CODEX_API) policy_ok "$key" "$value" || continue ;;
      DIGEST_HOUR|HPC_*|CODEX_*|CLAUDE_*|LEAD_*|DIRECTOR_*|AGENT_POOL_*) [[ $value =~ ^[0-9]+$ ]] || continue ;;
      *) continue ;;
    esac
    printf -v "$key" '%s' "$value"; CONF_SRC[$key]=lab.conf
  done < <(conf_lines "$LAB_CONF")
  for key in "${LIMIT_KEYS[@]}"; do   # ceilings: <KEY>_MAX, else the value so far
    ceil=${key}_MAX
    CONF_CEIL[$key]=${!ceil:-${!key}}
  done
  while IFS=$'\t' read -r key value; do
    if [[ " ${LIMIT_KEYS[*]} " == *" $key "* ]]; then
      [[ $value =~ ^[0-9]+$ ]] || continue
      if (( value > CONF_CEIL[$key] )); then
        value=${CONF_CEIL[$key]}; CONF_SRC[$key]="limits.conf (capped at ${CONF_CEIL[$key]})"
      else
        CONF_SRC[$key]=limits.conf
      fi
      printf -v "$key" '%s' "$value"
    elif [[ " ${POLICY_KEYS[*]} " == *" $key "* ]]; then
      policy_ok "$key" "$value" || continue
      printf -v "$key" '%s' "$value"; CONF_SRC[$key]=limits.conf
    fi
  done < <(conf_lines "$LIMITS_CONF")
}
load_conf
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
    # The temporary file goes in state/ (writable by both accounts; /srv/lab itself is hpc's), and the result
    # is copied into registry.json in place (group-writable), so the agent account can update it too.
    local tmp
    tmp=$(mktemp "$LAB/state/registry.json.XXXXXX") || exit 1
    if jq "$@" "$filter" "$LAB/registry.json" > "$tmp" && [[ -s $tmp ]] && jq -e . "$tmp" > /dev/null; then
      cat "$tmp" > "$LAB/registry.json"
    else
      rm -f "$tmp"; exit 1
    fi
    rm -f "$tmp"
  ) 9>"$LAB/state/registry.lock"
}

# --- Slurm: the lab's jobs are named lab:<project>:<role>:<issue>.

lab_jobs() {  # lab_jobs [project]: one line per job: id name state elapsed (Slurm jobs, then agent services)
  local prefix="lab:"
  [[ -n ${1:-} ]] && prefix="lab:$1:"
  squeue -h -o '%i %j %T %M' | awk -v p="$prefix" 'index($2, p) == 1'
  lab_agents "${1:-}"
}

# Agents outside Slurm (AGENT_RUNNER=systemd) register in $AGENTS_DIR/<id>.json while they run:
# {id, name (lab:<project>:<role>:<issue>), user, unit, pid, start}. Ids are a1, a2, ...
AGENTS_DIR=$LAB/state/agents
# Unit names and slice (overridable for tests only; not lab.conf settings).
AGENT_UNIT_PREFIX=${AGENT_UNIT_PREFIX:-lab-agent}
AGENT_SLICE=${AGENT_SLICE:-lab-agents.slice}

agent_alive() {  # agent_alive <id> <pid>: the pid is that agent's service (its cgroup names the unit)
  grep -q "/$AGENT_UNIT_PREFIX-$1\.service\$" "/proc/$2/cgroup" 2> /dev/null
}

lab_agents() {  # lab_agents [project]: id name RUNNING elapsed, for registered agents whose process is alive
  local prefix="lab:" f id name pid start now e
  [[ -n ${1:-} ]] && prefix="lab:$1:"
  now=$(date +%s)
  for f in "$AGENTS_DIR"/a*.json; do
    [[ -e $f ]] || continue
    read -r id name pid start < <(jq -r '[.id, .name, .pid, .start] | @tsv' "$f" 2> /dev/null) || continue
    [[ $id =~ ^a[0-9]+$ ]] || continue
    if ! agent_alive "$id" "$pid"; then   # ended without cleaning up (crash, reboot): drop it if we may
      rm -f "$f" 2> /dev/null
      continue
    fi
    [[ $name == "$prefix"* ]] || continue
    e=$(( now - start ))   # as squeue's %M: M:SS, H:MM:SS, D-HH:MM:SS
    if (( e >= 86400 )); then printf -v e '%d-%02d:%02d:%02d' $((e / 86400)) $((e % 86400 / 3600)) $((e % 3600 / 60)) $((e % 60))
    elif (( e >= 3600 )); then printf -v e '%d:%02d:%02d' $((e / 3600)) $((e % 3600 / 60)) $((e % 60))
    else printf -v e '%d:%02d' $((e / 60)) $((e % 60)); fi
    echo "$id $name RUNNING $e"
  done
}

new_agent_id() {  # the next agent id (a1, a2, ...), from a counter shared by both accounts
  mkdir -p "$AGENTS_DIR"
  local n
  n=$( umask 002; exec 9>> "$AGENTS_DIR/next.lock" || exit 1; flock 9 || exit 1
       n=$(( $(cat "$AGENTS_DIR/next" 2> /dev/null || echo 0) + 1 )); echo "$n" > "$AGENTS_DIR/next" || exit 1; echo "$n" )
  [[ $n =~ ^[0-9]+$ ]] || die "Can't take an agent id from $AGENTS_DIR (next, next.lock: group agents, mode 664)."
  echo "a$n"
}

user_systemctl() {  # systemctl --user for this account, also from sudo or cron (no session environment)
  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} systemctl --user "$@"
}

agent_pool() {  # cap the shared slice all of this account's agents run in
  user_systemctl set-property --runtime "$AGENT_SLICE" CPUQuota="${AGENT_POOL_CPUS}00%" MemoryMax="${AGENT_POOL_MEM_GB}G" \
    > /dev/null 2>&1 || true
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
      CODEX_HOME=$(codex_home) codex exec --json --skip-git-repo-check -C "$folder" -s danger-full-access \
        -c approval_policy=never "${flags[@]}" -o "$last" "$prompt" > "$log" 2> "${log%.*}.err" ;;
    claude)
      local code
      (cd "$folder" && claude -p "$prompt" --permission-mode auto --output-format json "${flags[@]}") > "$log" 2> "${log%.*}.err"
      code=$?
      jq -r '.result // empty' "$log" > "$last" 2> /dev/null
      # Out of plan and usage credits: record it, so claude_room stops new Claude runs for a while.
      if (( code != 0 )) && grep -qiE 'credit balance|out of (extra usage|usage credits|credits)|extra usage (is )?(exhausted|limit)|usage limit|spend limit' \
           "$log" "${log%.*}.err" 2> /dev/null; then
        date +%s > "$USAGE/claude-credits-out" 2> /dev/null
      fi
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
      record=$(find "$(codex_home)/sessions" -name "rollout-*$thread.jsonl" 2> /dev/null | head -1)
      if [[ -n $thread && -n $record ]]; then
        tokens=$(grep '"token_count"' "$record" | tail -1 |
          jq -r '.payload.info.total_token_usage | [.input_tokens, .cached_input_tokens, .output_tokens] | @tsv' 2> /dev/null)
        [[ -n ${LAB_CODEX_API:-} && -n $tokens ]] && record_api_run "$record" "$tokens" "$3" "$4" "$5"
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
# unless credits can carry on (codex_credit_pace); "api" instead of "stop" when the lab may go on on the
# OpenAI API (CODEX_API=on, budget left): everything runs, on the API.
codex_pressure() {
  [[ -f $USAGE/summary.json ]] || { echo ok; return; }
  local p
  p=$(codex_plan_pressure)
  [[ $p == stop ]] && p=$(codex_credit_pace)
  [[ $p == stop && $CODEX_API == on ]] && codex_api_room && p=api
  echo "$p"
}

# --- OpenAI API credits (see CODEX_API above). A run is on the API when LAB_CODEX_API says why
# ("overflow: ..." or "chosen: ..."); it then uses the account's API login in ~/.codex-api.
codex_home() {
  if [[ -n ${LAB_CODEX_API:-} ]]; then echo "$HOME/.codex-api"; else echo "${CODEX_HOME:-$HOME/.codex}"; fi
}

codex_api_spent() {  # USD the lab's API runs cost so far (usage/codex-api-runs.tsv, last column)
  awk -F'\t' '{s += $NF} END {printf "%.2f\n", s + 0}' "$USAGE/codex-api-runs.tsv" 2> /dev/null || echo 0
}

codex_api_room() {  # the API login is installed and the lab's API spend is under CODEX_API_BUDGET_USD
  [[ -f $HOME/.codex-api/auth.json ]] || return 1
  # Without a price row every run would cost 0 and the budget would never stop anything.
  awk '!/^#/ && NF >= 4 && $4 > 0 {ok = 1} END {exit !ok}' "$LAB/codex-api-prices.tsv" 2> /dev/null || return 1
  awk -v s="$(codex_api_spent)" -v b="$CODEX_API_BUDGET_USD" 'BEGIN { exit !(s < b) }'
}

# record_api_run <rollout> <input cached output> <project> <role> <issue>: append the run's cost at API prices
# ($LAB/codex-api-prices.tsv: model, USD per 1M input, cached input, output; the first row is the default)
# to usage/codex-api-runs.tsv (epoch, project, role, issue, job, model, why, input, cached, output, USD).
record_api_run() {
  local model in cached out usd
  model=$(grep -m1 '"turn_context"' "$1" | jq -r '.payload.model // empty' 2> /dev/null)
  read -r in cached out <<< "$2"
  usd=$(awk -v m="$model" -v i="$in" -v c="$cached" -v o="$out" '
    !/^#/ && NF >= 4 { if (!d) { d = 1; pi = $2; pc = $3; po = $4 } if ($1 == m) { pi = $2; pc = $3; po = $4 } }
    END { printf "%.4f", ((i - c) * pi + c * pc + o * po) / 1e6 }' "$LAB/codex-api-prices.tsv" 2> /dev/null)
  shared_append "$USAGE/codex-api-runs.tsv" "$(date +%s)"$'\t'"$3"$'\t'"$4"$'\t'"$5"$'\t'"${LAB_AGENT_ID:-${SLURM_JOB_ID:--}}"$'\t'"${model:-?}"$'\t'"${LAB_CODEX_API//$'\t'/ }"$'\t'"$in"$'\t'"$cached"$'\t'"$out"$'\t'"${usd:-0}"
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
# With CLAUDE_CREDITS=on the stop percent is ignored while the usage credits last (claude_credits_out).
claude_room() {
  local runs week
  runs=$(awk -F'\t' -v t="$(( $(date +%s) - 7 * 86400 ))" '$1 >= t' "$USAGE/claude-runs.tsv" 2> /dev/null | grep -c . || true)
  week=$(claude_week)
  (( runs < CLAUDE_LAB_RUNS_PER_WEEK )) || return 1
  awk -v w="${week:-0}" -v s="$CLAUDE_LAB_STOP_PERCENT" 'BEGIN {exit !(w < s)}' && return 0
  [[ $CLAUDE_CREDITS == on ]] && ! claude_credits_out
}

# claude_credits_out: a Claude run failed for lack of credits in the last 6 hours ($USAGE/claude-credits-out,
# written by run_agent). Remove the file to retry sooner, e.g. after the PI buys more.
claude_credits_out() {
  [[ -n $(find "$USAGE/claude-credits-out" -mmin -360 2> /dev/null) ]]
}

# effective_model <claude|codex>: what a lead or director pass should run on right now: that model, or
# for Claude with the lab's share used up, CLAUDE_FALLBACK (codex, or "wait": skip the pass).
effective_model() {
  if [[ $1 == claude ]] && ! claude_room; then
    [[ $CLAUDE_FALLBACK == wait ]] && echo wait || echo codex
  else
    echo "${1:-codex}"
  fi
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
  "hpc-queued|c2e0c6|An HPC job held only by the daily limit; released automatically"
  "summary|c5def5|The project's summaries for the PI"
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
