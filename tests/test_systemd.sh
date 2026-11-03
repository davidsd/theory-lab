#!/usr/bin/env bash
# End-to-end test of AGENT_RUNNER=systemd: a sandbox lab and project, stub claude/gh/scancel/squeue, and a real
# `systemd-run --user` service in a test slice of its own. Needs a user systemd manager (a login session or
# linger, as the installer sets up for the lab accounts). Run as a lab account: bash tests/test_systemd.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
pass=0 fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1${2:+: $2}"; fail=$((fail + 1)); }
# Its own unit names and slice, so it never touches the real lab's agents or pool.
export AGENT_UNIT_PREFIX=labtest-agent AGENT_SLICE=labtest-agents.slice
cleanup() { XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user stop 'labtest-agent-a*' labtest-agents.slice 2>/dev/null; rm -rf "$t"; }
trap cleanup EXIT

mkdir -p "$t/lab/state/usage" "$t/lab/roles" "$t/projects" "$t/home/.local/bin" "$t/share" "$t/bin"
cp "$here/share/lib.sh" "$t/share/"
cp "$here/bin/lab" "$here/bin/lab-worker" "$here/bin/lab-run" "$t/bin/"
cp "$here/templates/lab/roles/worker.md" "$t/lab/roles/worker.md"   # the kit's role text
cat > "$t/lab/registry.json" <<EOF
{"projects": {"p1": {"account": "$(id -un)", "status": "active", "limit": 2}}}
EOF
cat > "$t/lab.conf" <<'EOF'
ORG=example-org
PI_GITHUB=someone
CLAUDE_LAB_STOP_PERCENT=80
CLAUDE_LAB_RUNS_PER_WEEK=1000
EOF
printf 'AGENT_RUNNER=systemd\nAGENT_POOL_CPUS=2\n' > "$t/lab/limits.conf"
s=$t/home/.local/bin
# claude stub: records its prompt and environment, then sleeps (so the test can see it running) unless told to exit.
cat > "$s/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$2" > "$t/prompt.txt"
env | grep -E '^LAB_' | sort > "$t/env.txt"
for i in \$(seq 60); do [[ -e "$t/finish" ]] && break; sleep 1; done
echo '{"result": "stub done"}'
EOF
printf '#!/usr/bin/env bash\necho "gh $*" >> %q/gh.calls\ncase "$*" in *"api user"*) echo lab-bot ;; *"issue view"*) ;; *) echo "[]" ;; esac\n' "$t" > "$s/gh"
printf '#!/usr/bin/env bash\necho "scancel $*" >> %q/scancel.calls\n' "$t" > "$s/scancel"
printf '#!/usr/bin/env bash\nexit 0\n' > "$s/squeue"
chmod +x "$s"/* "$t/bin"/*
git init -q --bare "$t/origin.git"
git init -q -b main "$t/projects/p1" && git -C "$t/projects/p1" remote add origin "$t/origin.git"
git -C "$t/projects/p1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init && git -C "$t/projects/p1" push -q origin main
git -C "$t/projects/p1" branch -q -u origin/main

export HOME=$t/home PATH="$s:$t/bin:$PATH" LAB_DIR=$t/lab LAB_CONF=$t/lab.conf PROJECTS_DIR=$t/projects AGENTBOX_SHARE=$t/share
L() { bash "$t/bin/lab" "$@"; }

echo "== spawn"
out=$(L spawn p1 worker --issue 7 --model claude --cpus 1 --mem 2G --hours 1 2>&1)
grep -q "as agent a1" <<<"$out" && ok "spawn starts agent a1" || bad "spawn" "$out"
for _ in $(seq 20); do [[ -s $t/prompt.txt ]] && break; sleep 1; done
[[ -s $t/prompt.txt ]] && ok "the agent ran" || bad "the agent ran" "$(tail -5 "$t"/projects/p1/logs/*.out 2>/dev/null)"
grep -q "outside Slurm" "$t/prompt.txt" && grep -q "lab-run --alloc" "$t/prompt.txt" && ok "prompt explains lab-run (real role text)" || bad "prompt" "$(cat "$t/prompt.txt")"
! grep -q "Slurm job a1" "$t/prompt.txt" && ok "the role text says where it runs ({{WHERE}})" || bad "prompt names a Slurm job" "$(head -5 "$t/prompt.txt")"
grep -q "LAB_AGENT_ID=a1" "$t/env.txt" && grep -q "LAB_ISSUE=7" "$t/env.txt" && ok "agent env (LAB_AGENT_ID, LAB_ISSUE)" || bad "env" "$(cat "$t/env.txt")"
jobs=$(bash -c "source $t/share/lib.sh; lab_jobs p1")
grep -qE '^a1 lab:p1:worker:7 RUNNING [0-9]' <<<"$jobs" && ok "lab_jobs lists it" || bad "lab_jobs" "$jobs"
st=$(L status 2>&1); grep -qE '^p1 .* 1 ' <<<"$st" && ok "lab status counts it" || bad "status" "$st"
out=$(L spawn p1 worker --issue 7 --model claude 2>&1); grep -q "already working" <<<"$out" && ok "no duplicate on the same issue" || bad "duplicate" "$out"
cg=$(XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user show labtest-agent-a1 -p ControlGroup --value)
[[ $cg == */labtest-agents.slice/labtest-agent-a1.service ]] && ok "runs in its slice" || bad "slice" "$cg"
um=$(XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user show labtest-agent-a1 -p UMask --value)
[[ $um == 0002 ]] && ok "umask 0002" || bad "umask" "$um"
q=$(XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user show labtest-agents.slice -p CPUQuotaPerSecUSec --value)
[[ $q == 2s ]] && ok "pool capped at AGENT_POOL_CPUS" || bad "pool quota" "$q"

echo "== stale and forged registrations"
printf '{"id":"a99","name":"lab:p1:worker:99","pid":%s,"start":%s}\n' $$ "$(date +%s)" > "$t/lab/state/agents/a99.json"
j=$(bash -c "source $t/share/lib.sh; lab_jobs p1")
! grep -q a99 <<<"$j" && ok "a pid that isn't the agent's service is not counted" || bad "forged pid counted" "$j"
[[ ! -e $t/lab/state/agents/a99.json ]] && ok "stale registration removed" || bad "stale left"
out=$(L spawn p1 worker --issue 7 --model claude --mem 16000 --hours 0 2>&1); grep -q "at least 1" <<<"$out" && ok "--hours 0 refused" || bad "hours" "$out"

echo "== lab-run guards"
out=$(env -u LAB_AGENT_ID LAB_PROJECT=p1 LAB_ISSUE=7 bash "$t/bin/lab-run" -- true 2>&1); grep -q "unset" <<<"$out" && ok "lab-run refuses outside an agent" || bad "lab-run guard" "$out"

echo "== stop"
L _stop-agent a1 && ok "_stop-agent" || bad "_stop-agent"
for _ in $(seq 30); do [[ -e $t/lab/state/agents/a1.json ]] || break; sleep 1; done
[[ ! -e $t/lab/state/agents/a1.json ]] && ok "registration removed" || bad "registration left"
grep -q 'scancel --name=lab:p1:run:7:a1' "$t/scancel.calls" 2>/dev/null && ok "lab-run helpers cancelled" || bad "helper cancel" "$(cat "$t/scancel.calls" 2>/dev/null)"
grep -q "ended because it was cancelled" "$t/gh.calls" && ok "says on the issue it was cancelled" || bad "end comment" "$(grep 'issue comment' "$t/gh.calls" | tail -2)"
[[ -z $(bash -c "source $t/share/lib.sh; lab_jobs p1") ]] && ok "lab_jobs empty after stop" || bad "lab_jobs after"

echo "== normal finish"
touch "$t/finish"; rm -f "$t/prompt.txt"
L spawn p1 worker --issue 8 --model claude --hours 1 > /dev/null 2>&1
for _ in $(seq 30); do [[ -e $t/lab/state/agents/a2.json || -s $t/prompt.txt ]] && break; sleep 1; done
for _ in $(seq 30); do [[ -e $t/lab/state/agents/a2.json ]] || break; sleep 1; done
grep -q "worker job a2 (claude) ended, exit code 0" "$t/gh.calls" && ok "finishes, exit 0, says so" || bad "finish" "$(grep 'issue comment' "$t/gh.calls" | tail -1)"

echo "== counter that can't be written"
chmod 444 "$t/lab/state/agents/next.lock" "$t/lab/state/agents/next"
out=$(L spawn p1 worker --issue 10 --model claude 2>&1); grep -q "Can't take an agent id" <<<"$out" && ok "unwritable counter refused, not id 'a'" || bad "counter" "$out"
chmod 664 "$t/lab/state/agents/next.lock" "$t/lab/state/agents/next"

echo "== slurm runner still works"
printf 'AGENT_RUNNER=slurm\n' > "$t/lab/limits.conf"
printf '#!/usr/bin/env bash\necho 4242\n' > "$s/sbatch"; chmod +x "$s/sbatch"
out=$(L spawn p1 worker --issue 9 --model claude 2>&1); grep -q "Slurm job 4242" <<<"$out" && ok "AGENT_RUNNER=slurm uses sbatch" || bad "slurm runner" "$out"

echo
echo "$pass passed, $fail failed"
exit $(( fail > 0 ))
