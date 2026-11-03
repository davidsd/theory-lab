# Adapting the kit

Notes for changing providers. They are written for an AI agent doing the adaptation on the PI's behalf:
each section names the files involved and what to keep invariant. Read README.md first, then the
scripts named here. Keep the invariants in the last section whatever you change.

## Where the provider-specific parts are

| Concern | Files |
|---|---|
| Cloud VM, OS packages | `install/install.sh` (apt, Ubuntu 24.04), SETUP.md steps 1–2 |
| Private network | Tailscale: SETUP.md step 2, `dashboard/serve.py` (`tailscale ip -4`, listens there) |
| Code host and board | GitHub via `gh`: `bin/lab` (repo create/clone/archive, labels, issues), `share/lib.sh` (`ensure_labels`, `pi_decision`, `agents_login`), `bin/watchdog`, `bin/lab-worker`, `hpc/hpc-submit`, `slack/*`, all role files (`gh issue ...`) |
| AI agents | `share/lib.sh` `run_agent` and `agent_flags`, `templates/lab/models.conf`, `bin/lab-worker` (interactive Codex in tmux, transcript paths), `bin/lab-usage` (reads rate-limit records from Codex rollouts and Claude's status line), `bin/claude-statusline`, `bin/agent-status-hook`, `share/config/*` |
| Local scheduler | Slurm (with slurmdbd accounting) for computations: `bin/lab-run`, `bin/lab` (`sbatch`, `squeue`, `scancel`, `sinfo`), `bin/lab-cancel`, `install/install.sh`; systemd user services for the agents themselves: `share/lib.sh` (`lab_agents`, `agent_pool`, `new_agent_id`), `bin/lab` (`systemd-run --user`), `bin/lab-worker`, `dashboard/serve.py` (cgroups) |
| Cluster | `hpc/*`, `bin/lab-usage` (`sacct`), `bin/lab-rm` (`hpc:` paths), lab.conf `HPC_*` |
| Notifications | ntfy: `share/lib.sh` `notify` (one `curl` POST) |
| Root settings from a phone | `settings/lab-settings-apply` (GitHub REST with a read-only token), `bin/lab-settings-propose`, `bin/watchdog` (posts results) |
| Chat | Slack: `slack/lab-slack` (sync, post, outbox), `slack/lab-slack-listen` (Socket Mode responder) |

## Another cloud

Any Linux VM with outbound internet works. On non-Ubuntu systems, translate the package names in
`install/install.sh` (Slurm and munge are packaged on most distributions; on macOS there is no Slurm, so
use a Linux VM). Disk: the lab expects a few hundred GB for builds, clones and working data. A bare-metal
workstation is fine too; skip the cloud steps.

## Another private network

Tailscale is used for three things: reaching the machine without an open ssh port, letting phones open the
dashboard, and ssh from new laptops. WireGuard, ZeroTier or a cloud provider's identity-aware proxy work as
well. If you drop Tailscale, make `dashboard/serve.py` listen only on localhost (it already does if
`tailscale` is missing) and reach it with `ssh -L`. Never expose the dashboard or the machine's ssh to the
open internet: the dashboard shows the agents' work, and the lab accounts hold tokens.

## GitLab or another forge instead of GitHub

The board is the hardest part to swap, because the agents use `gh` directly in their instructions. Options:

1. Keep GitHub as the board and use GitLab only for code repos (the lab already supports clones from any
   host under a project's `code/`, and people's handles may be written `gitlab:<handle>` in AGENTS.md).
2. Port to GitLab with `glab`: replace `gh issue|label|repo|api` calls in `bin/`, `share/lib.sh`, `hpc/`,
   `slack/` and in the role files' examples; labels map one to one; "assigned to the PI" becomes an
   assignee; `pi_decision` must read notes on an issue and check that the author is the PI and that the
   note was not edited. Keep the approve/cancel rule: only the PI's own unedited comment counts.

## Other models

`run_agent` in `share/lib.sh` is the one place an agent is started: a non-interactive session in a folder,
with a prompt, writing a JSON log and the final message to a file. Any agent CLI that can do this and run
shell commands without asking (inside the Unix account as its sandbox) fits. Add a model name to the
`--model` choices in `bin/lab`, its flags to `agent_flags`, and a column pair to `models.conf`.

Pacing reads usage windows: `bin/lab-usage` takes Codex's from its session records (`rate_limits` in
`~/.codex/sessions/**/rollout-*.jsonl`) and Claude's from what Claude Code hands its status line
(`bin/claude-statusline` saves it). Spend-based pacing already exists for Codex on the OpenAI API
(`CODEX_API`, `CODEX_API_BUDGET_USD`): `record_api_run` prices each API run from `codex-api-prices.tsv` into
`state/usage/codex-api-runs.tsv`, and `codex_api_room` compares the total with the budget. For an API-only
setup, make `codex_pressure` return `api` always (or mark every run with `LAB_CODEX_API`), and do the same for
Claude in `claude_room` (Claude's `-p` result already reports `total_cost_usd`; the dashboard sums it).

`bin/lab-worker` runs Codex workers interactively in a tmux session inside the Slurm job so the PI can
type to them (`talk`); other CLIs may run non-interactively there instead (Claude workers already do).

## Another local scheduler, or none

Two mechanisms share the machine. The agents themselves (`AGENT_RUNNER=systemd`) are systemd user services
in one capped slice per account (`lab-agents.slice`, `AGENT_POOL_CPUS`/`AGENT_POOL_MEM_GB`); each registers
in `state/agents/a<N>.json`, and counts as alive only while its pid's cgroup names its own unit, so a reused
pid or a forged file doesn't count. Their computations go to Slurm, which keeps the machine from being
overloaded and names jobs `lab:<project>:...` so the lab can count and cancel them (`lab-run` jobs are
`lab:<project>:run:<issue>:<agent>`, cancelled when the agent ends). Slurm needs accounting (slurmdbd), or
jobs that have to queue are rejected. Without systemd user services, use `AGENT_RUNNER=slurm` (each agent is
a Slurm job). Without Slurm, any queue with names, CPU limits and cancel works; replace
`sbatch/srun/salloc/squeue/scancel/sinfo` in `bin/lab`, `bin/lab-run`, `bin/lab-worker` (it traps `USR1` five
minutes before the time limit and `TERM` on cancel), `bin/lab-cancel` and the dashboard.

## Another cluster or scheduler on the cluster

`hpc/hpc-submit` assumes Slurm on the cluster (`sbatch --hold`, `scontrol show job -o`, `scontrol release`).
For PBS or LSF, translate those three calls and the fields it reads (partition/queue, nodes, CPUs, time
limit). The cost model is in lab.conf (`HPC_WHOLE_NODE_PARTITIONS`, `HPC_CORES_PER_NODE`); centers that
charge GPUs differently need a line in the `sus=` computation. Keep: jobs are submitted held, priced, and
released only within the budgets; everything goes in `state/hpc-ledger.tsv`.

The single shared ssh connection (`hpc-connect`, ControlMaster, a ProxyCommand that refuses when the
connection is down) protects the PI's account from agents retrying logins. Keep it for any center with
two-factor login or connection-rate limits.

## Other notification or chat services

`notify` in `share/lib.sh` is one HTTP POST; Pushover, Telegram bots or email are a few lines. Slack is
optional; the same outbox design (agents write requests, one root-or-hpc-owned sync process holding the
token checks them against a config and sends) carries over to Discord, Zulip or Matrix.

## Invariants to keep

- **Agents never hold or print secrets.** Tokens live in files only the owning account (or root) reads;
  tools that use them check requests against a config the agents can't edit.
- **Limits are root-owned.** lab.conf and the scripts that enforce budgets live where agents can't write.
- **Only the PI approves.** Approvals are the PI's own unedited comments (or the PI's own Slack user),
  never text an agent could write. Root-applied settings are read with the PI's own read-only token and
  checked against root-owned maxima.
- **Scoped destruction.** Agents cancel and delete only through tools that check the project's own jobs and
  folders and log every action.
- **Files over memory.** Every pass starts fresh from the repo and the board.
- **Verification that could fail.** Keep the claim tags and the rule that a result counts only after an
  independent check.
