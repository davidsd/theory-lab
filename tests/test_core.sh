#!/usr/bin/env bash
# Sandbox test of the core scripts (share/lib.sh, bin/lab, bin/lab-loop): a temporary lab folder, lab.conf and
# limits.conf, and stub claude/codex/gh/squeue/sbatch, so nothing real is touched. Run from anywhere:
#   bash tests/test_core.sh
# Covers: settings layers and ceilings, lab set / lab model, default model and fallback, the loops' model
# choice, Claude usage credits, OpenAI API credits (cost ledger, budget, --api), CHANGE-ME placeholders.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
pass=0 fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1${2:+: $2}"; fail=$((fail + 1)); }
check() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
has() { if grep -q -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "no '$3' in: $2"; fi; }

# --- Sandbox
mkdir -p "$t/lab/state/usage" "$t/lab/roles" "$t/projects/p1/notebook" "$t/home/.local/bin" "$t/share"
ln -s "$t/home/.local/bin" "$t/stub"   # lib.sh puts $HOME/.local/bin first on PATH, so the stubs live there
cp "$here/share/lib.sh" "$t/share/"
echo 'You are the lead of {{PROJECT}}.' > "$t/lab/roles/lead.md"
echo 'You are the director.' > "$t/lab/roles/director.md"
cat > "$t/lab/registry.json" <<EOF
{"projects": {"p1": {"account": "$(id -un)", "status": "active", "limit": 2, "lead_model": "claude"},
              "p2": {"account": "$(id -un)", "status": "active", "limit": 1}}}
EOF
cat > "$t/lab.conf" <<'EOF'
ORG=example-org
PI_GITHUB=someone
AGENT_RUNNER=slurm
CLAUDE_LAB_STOP_PERCENT=80
CLAUDE_LAB_STOP_PERCENT_MAX=98
CLAUDE_LAB_RUNS_PER_WEEK=1000
CODEX_AHEAD_PERCENT=15
EOF
for c in claude codex; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> %q/calls\necho "{\\"result\\": \\"done\\"}"\n' "$c" "$t" > "$t/stub/$c"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$t/stub/squeue"
printf '#!/usr/bin/env bash\ncase "$*" in *"api user"*) echo lab-bot ;; *"issue view"*) ;; *) echo "[]" ;; esac\n' > "$t/stub/gh"
printf '#!/usr/bin/env bash\necho "sbatch $*" >> %q/calls\necho 4242\n' "$t" > "$t/stub/sbatch"
printf '#!/usr/bin/env bash\nexit 0\n' > "$t/stub/lab-worker"
chmod +x "$t/stub/"*
export HOME=$t/home PATH="$t/stub:$here/bin:$PATH" LAB_DIR=$t/lab LAB_CONF=$t/lab.conf PROJECTS_DIR=$t/projects AGENTBOX_SHARE=$t/share
claude_week() { :; }
set_claude_used() {  # set_claude_used <percent>: the plan's weekly usage, as the status line records it
  printf '{"seven_day": {"used_percentage": %s, "resets_at": %s}}\n' "$1" "$(( $(date +%s) + 86400 ))" > "$t/lab/state/usage/claude-limits.json"
}
set_codex() {  # set_codex <used percent>
  printf '{"codex": {"windows": [{"used_percent": %s, "window_minutes": 10080, "resets_at": %s, "elapsed_percent": 50}], "credits": "0"}}\n' \
    "$1" "$(( $(date +%s) + 86400 ))" > "$t/lab/state/usage/summary.json"
}
val() { bash -c "source $t/share/lib.sh; echo \"\${$1}\""; }
src() { bash -c "source $t/share/lib.sh; echo \"\${CONF_SRC[$1]}\""; }

echo "== syntax"
for f in "$here"/bin/* "$here"/hpc/* "$here"/slack/lab-slack* "$here"/settings/lab-settings-apply "$here/dashboard/serve.py" \
         "$here/share/lib.sh" "$here/share/user-setup.sh" "$here/install/install.sh"; do
  case $(head -1 "$f") in
    *python*) if python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$f"; then ok "python syntax $(basename "$f")"; else bad "python syntax $f"; fi ;;
    *bash*|"# Shared"*) if bash -n "$f"; then ok "bash -n $(basename "$f")"; else bad "bash -n $f"; fi ;;
  esac
done

echo "== ceilings"
cat > "$t/lab/limits.conf" <<'EOF'
CLAUDE_LAB_STOP_PERCENT=99
CODEX_AHEAD_PERCENT=30
LEAD_INTERVAL_MIN=2
HPC_AUTO_SUS_PER_JOB=5000
DEFAULT_MODEL=claude
CLAUDE_FALLBACK=bogus
NTFY_URL=https://evil.example
EOF
check "above its _MAX ceiling: capped at 98" "$(val CLAUDE_LAB_STOP_PERCENT)" 98
has "  ... and the source says so" "$(src CLAUDE_LAB_STOP_PERCENT)" "capped at 98"
check "no _MAX: lab.conf's value is the ceiling (30 -> 15)" "$(val CODEX_AHEAD_PERCENT)" 15
check "lowering is always allowed (LEAD_INTERVAL_MIN 2)" "$(val LEAD_INTERVAL_MIN)" 2
check "not in lab.conf: the default is the ceiling (5000 -> 2000)" "$(val HPC_AUTO_SUS_PER_JOB)" 2000
check "policy key read (DEFAULT_MODEL)" "$(val DEFAULT_MODEL)" claude
check "bad policy value ignored (CLAUDE_FALLBACK stays codex)" "$(val CLAUDE_FALLBACK)" codex
check "limits.conf can't set other keys (NTFY_URL)" "$(val NTFY_URL)" ""
check "lab.conf values unaffected (ORG)" "$(val ORG)" example-org
check "reload recomputes from scratch" "$(bash -c "source $t/share/lib.sh; CLAUDE_LAB_STOP_PERCENT=5; load_conf; load_conf; echo \$CLAUDE_LAB_STOP_PERCENT")" 98
rm "$t/lab/limits.conf"
check "no limits.conf: lab.conf value" "$(val CLAUDE_LAB_STOP_PERCENT)" 80

echo "== lab set"
git -C "$t/lab" init -q && git -C "$t/lab" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
out=$(lab set NOPE 1 --reason x 2>&1); has "unknown key refused" "$out" "Unknown key"
out=$(lab set CLAUDE_LAB_STOP_PERCENT ninety --reason x 2>&1); has "non-numeric refused" "$out" "whole number"
out=$(lab set CLAUDE_LAB_STOP_PERCENT 99 --reason x 2>&1); has "above ceiling refused" "$out" "above its ceiling 98"
out=$(lab set CLAUDE_LAB_STOP_PERCENT 95 2>&1); has "reason required" "$out" "Usage"
out=$(lab set DEFAULT_MODEL gpt --reason x 2>&1); has "bad model refused" "$out" "one of"
out=$(git -C "$t/lab" -c user.name=t -c user.email=t@t lab set CLAUDE_LAB_STOP_PERCENT 95 --reason "PI: burn it" 2>&1)
out=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t lab set CLAUDE_LAB_STOP_PERCENT 95 --reason "PI: burn it" 2>&1)
has "valid value set" "$out" "is now 95"
check "  ... effective" "$(val CLAUDE_LAB_STOP_PERCENT)" 95
has "  ... logged" "$(cat "$t/lab/state/limits-log.tsv")" "CLAUDE_LAB_STOP_PERCENT	80	95	PI: burn it"
has "  ... committed" "$(git -C "$t/lab" log --oneline -1)" "set CLAUDE_LAB_STOP_PERCENT=95"
out=$(lab set CLAUDE_LAB_STOP_PERCENT - --reason "back to lab.conf" 2>&1); has "remove with -" "$out" "is now 80"
out=$(lab set 2>&1); has "table lists keys with source and ceiling" "$out" "CLAUDE_LAB_STOP_PERCENT *80 *lab.conf *98"

echo "== lab model"
out=$(lab model p2 claude 2>&1); has "project lead model" "$out" "p2's lead now runs on claude"
check "  ... in the registry" "$(jq -r '.projects.p2.lead_model' "$t/lab/registry.json")" claude
out=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t lab model director claude 2>&1); has "director model" "$out" "DIRECTOR_MODEL is now claude"
out=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t lab model default claude 2>&1); has "default model" "$out" "DEFAULT_MODEL is now claude"
out=$(lab model nosuch claude 2>&1); has "unknown project refused" "$out" "No project named"
out=$(lab model p1 gpt 2>&1); has "bad model refused" "$out" "Usage"

echo "== spawn default model"
set_codex 10; set_claude_used 50
out=$(lab spawn p1 worker --issue 7 2>&1); has "spawn without --model uses DEFAULT_MODEL" "$out" "(claude"
out=$(lab spawn p1 worker --issue 8 --model codex 2>&1); has "--model overrides" "$out" "(codex"
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t lab set CLAUDE_FALLBACK codex --reason t > /dev/null 2>&1
set_claude_used 90
out=$(lab spawn p1 worker --issue 9 2>&1); has "no Claude room + fallback codex: default falls back" "$out" "(codex"
out=$(lab spawn p1 worker --issue 10 --model claude 2>&1); has "explicit --model claude with no room refused" "$out" "allowance"

echo "== effective_model"
em() { bash -c "source $t/share/lib.sh; effective_model $1"; }
set_claude_used 50; check "claude with room" "$(em claude)" claude
set_claude_used 90; check "claude, no room, fallback codex" "$(em claude)" codex
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t lab set CLAUDE_FALLBACK wait --reason t > /dev/null 2>&1
check "claude, no room, fallback wait" "$(em claude)" wait
check "codex is codex" "$(em codex)" codex
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t lab set CLAUDE_LAB_STOP_PERCENT 95 --reason t > /dev/null 2>&1
check "raising the stop percent gives room again (90 < 95)" "$(em claude)" claude

echo "== loops (stub agents; LEAD_INTERVAL_MIN=0 so a loop spins; each run cut off after 4 s)"
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t lab set LEAD_INTERVAL_MIN 0 --reason t > /dev/null 2>&1
loop() { : > "$t/calls"; timeout 4 lab-loop "$@" > "$t/loop.out" 2>&1; cp "$t/loop.out" "$t/loop-$1-${2:-}.out"; }
set_codex 100; set_claude_used 50   # Codex at its limit, Claude has room
loop lead p1
has "Claude lead runs although Codex is at stop" "$(cat "$t/calls")" "^claude -p"
jq '.projects.p2.lead_model = "codex"' "$t/lab/registry.json" > "$t/r" && mv "$t/r" "$t/lab/registry.json"
loop lead p2
has "Codex lead waits when Codex is at stop" "$(cat "$t/loop.out")" "Codex is at its limit"
set_codex 10; set_claude_used 99   # Claude share used up; fallback is wait
loop lead p1
has "Claude lead, no room, fallback wait: waits" "$(cat "$t/loop.out")" "CLAUDE_FALLBACK=wait"
check "  ... and runs nothing" "$(cat "$t/calls")" ""
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t lab set CLAUDE_FALLBACK codex --reason t > /dev/null 2>&1
loop lead p1
has "Claude lead, no room, fallback codex: runs codex" "$(cat "$t/calls")" "^codex exec"
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t lab set DIRECTOR_INTERVAL_MIN 0 --reason t > /dev/null 2>&1
echo 9999-01-01 > "$t/lab/state/last-digest"
set_claude_used 50
loop director
has "director on DIRECTOR_MODEL=claude" "$(cat "$t/calls")" "^claude -p"
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t lab model director codex > /dev/null 2>&1
loop director
has "director on DIRECTOR_MODEL=codex" "$(cat "$t/calls")" "^codex exec"

echo "== lab-usage settings line"
out=$(bash -c "source $t/share/lib.sh; echo \"- Settings: Claude stop \${CLAUDE_LAB_STOP_PERCENT}% (\${CONF_SRC[CLAUDE_LAB_STOP_PERCENT]}, ceiling \${CONF_CEIL[CLAUDE_LAB_STOP_PERCENT]}%)\"")
has "effective stop percent with source and ceiling" "$out" "Claude stop 95% (limits.conf, ceiling 98%)"
has "lab-usage prints that line" "$(grep -c 'Settings (' "$here/bin/lab-usage")" 1

echo "== Claude usage credits"
set_claude_used 99
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t lab set CLAUDE_LAB_STOP_PERCENT 80 --reason t > /dev/null 2>&1
room() { bash -c "source $t/share/lib.sh; claude_room && echo yes || echo no"; }
check "credits off: no room past the stop percent" "$(room)" no
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t lab set CLAUDE_CREDITS on --reason t > /dev/null 2>&1
check "credits on: room past the stop percent" "$(room)" yes
# A run that fails for lack of credits pauses Claude for 6 h (run_agent writes claude-credits-out).
printf '#!/usr/bin/env bash\necho "{\\"result\\": \\"Credit balance is too low\\"}"\nexit 1\n' > "$t/stub/claude"
bash -c "source $t/share/lib.sh; run_agent claude $t/projects/p1 hi $t/r.json $t/r.md" > /dev/null 2>&1
[[ -e $t/lab/state/usage/claude-credits-out ]] && ok "a credit failure is recorded" || bad "a credit failure is recorded"
check "  ... and pauses new Claude runs" "$(room)" no
touch -d '7 hours ago' "$t/lab/state/usage/claude-credits-out"
check "  ... for 6 hours only" "$(room)" yes
printf '#!/usr/bin/env bash\necho "{\\"result\\": \\"some other error\\"}"\nexit 1\n' > "$t/stub/claude"
rm -f "$t/lab/state/usage/claude-credits-out"
bash -c "source $t/share/lib.sh; run_agent claude $t/projects/p1 hi $t/r.json $t/r.md" > /dev/null 2>&1
[[ ! -e $t/lab/state/usage/claude-credits-out ]] && ok "another failure doesn't pause Claude" || bad "another failure doesn't pause Claude"
printf '#!/usr/bin/env bash\necho "%s $*" >> %q/calls\necho "{\\"result\\": \\"done\\"}"\n' claude "$t" > "$t/stub/claude"

echo "== OpenAI API credits"
mkdir -p "$t/home/.codex-api"
api() { bash -c "source $t/share/lib.sh; $1"; }
check "no API login: no room" "$(rm -f "$t/home/.codex-api/auth.json"; api 'codex_api_room && echo yes || echo no')" no
echo '{}' > "$t/home/.codex-api/auth.json"
check "login but budget 0 (the default): no room" "$(api 'codex_api_room && echo yes || echo no')" no
printf 'CODEX_API_BUDGET_USD=50\n' >> "$t/lab.conf"
check "budget but no price table: no room (costs would read 0)" "$(api 'codex_api_room && echo yes || echo no')" no
printf '# model\tinput\tcached\toutput\ndefault-model\t2\t0.5\t10\nbig-model\t10\t1\t50\n' > "$t/lab/codex-api-prices.tsv"
check "budget and prices: room" "$(api 'codex_api_room && echo yes || echo no')" yes
# A rollout record whose turn_context names the model; 1M input of which 0.2M cached, 0.1M output.
printf '{"type":"turn_context","payload":{"model":"big-model"}}\n' > "$t/rollout.jsonl"
LAB_CODEX_API="chosen: test" api "record_api_run $t/rollout.jsonl '1000000 200000 100000' p1 worker 7"
check "cost at the model's prices: 0.8*10 + 0.2*1 + 0.1*50 = 13.2" "$(cut -f11 "$t/lab/state/usage/codex-api-runs.tsv")" 13.2000
check "  ... with the reason" "$(cut -f7 "$t/lab/state/usage/codex-api-runs.tsv")" "chosen: test"
printf '{"type":"turn_context","payload":{"model":"unknown"}}\n' > "$t/rollout.jsonl"
LAB_CODEX_API="overflow: x" api "record_api_run $t/rollout.jsonl '1000000 0 0' p1 lead -"
check "unknown model: the first row's prices" "$(tail -1 "$t/lab/state/usage/codex-api-runs.tsv" | cut -f11)" 2.0000
check "spent so far" "$(api codex_api_spent)" 15.20
printf '1\tp1\tworker\t8\ta9\tbig-model\tchosen: y\t0\t0\t0\t40\n' >> "$t/lab/state/usage/codex-api-runs.tsv"
check "budget spent (55.20 of 50): no room" "$(api 'codex_api_room && echo yes || echo no')" no
sed -i '$d' "$t/lab/state/usage/codex-api-runs.tsv"
set_codex 100
check "plan used up, CODEX_API=off: stop" "$(api codex_pressure)" stop
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t lab set CODEX_API on --reason t > /dev/null 2>&1
check "plan used up, CODEX_API=on, budget left: api" "$(api codex_pressure)" api
: > "$t/calls"
out=$(lab spawn p1 explorer --issue 11 --model codex 2>&1); has "overflow: an explorer starts on the API" "$out" "Started explorer"
has "  ... with LAB_CODEX_API set" "$(cat "$t/calls")" "LAB_CODEX_API=overflow"
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t lab set CODEX_API off --reason t > /dev/null 2>&1
out=$(lab spawn p1 explorer --issue 12 --model codex 2>&1); has "overflow off: explorers don't start at stop" "$out" "only verifiers"
: > "$t/calls"
out=$(lab spawn p1 explorer --issue 13 --model codex --api "hard derivation" 2>&1); has "--api starts whatever the pace" "$out" "Started explorer"
has "  ... marked as chosen" "$(cat "$t/calls")" "LAB_CODEX_API=chosen: hard derivation"
out=$(lab spawn p1 explorer --issue 14 --model claude --api "x" 2>&1); has "--api is for Codex only" "$out" "for Codex agents"
check "codex_home on the API" "$(LAB_CODEX_API=x api codex_home)" "$t/home/.codex-api"
check "codex_home otherwise" "$(api codex_home)" "$t/home/.codex"

echo "== CHANGE-ME placeholders"
printf 'NTFY_URL=https://ntfy.sh/CHANGE-ME-topic\n' >> "$t/lab.conf"
check "a CHANGE-ME value counts as unset" "$(val NTFY_URL)" ""
has "  ... and is listed" "$(bash -c "source $t/share/lib.sh; echo \"\$CONF_PLACEHOLDERS\"")" NTFY_URL

for f in "$t"/loop-*.out; do echo "--- $(basename "$f")"; head -5 "$f"; done
echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
