# theory-lab

A startup kit for running a research lab of AI agents on a cloud machine.

## Usage (for humans)

Paste the url of this repo into Claude code or Codex and tell it you want something like this. Discuss the setup you want and let it walk you through the steps.

## What is a "theory lab"?

A lab consists of a director that looks after all projects, a lead per project, and workers, explorers and
verifiers that each take one task. The agents are Claude Code and OpenAI Codex sessions. They coordinate
through GitHub issues and files, check each other's results, pace themselves to your subscriptions' limits,
and can use an HPC cluster within budgets you set. You (the PI) steer from your phone or laptop: you approve
charters, answer questions in your GitHub inbox, and get a push notification only when something really needs you.

It was built for theoretical physics (derivations, numerics, high-precision optimization, cluster runs),
but nothing in it is specific to one field.

**Not for wide-scale or untrusted use.** This kit is for one PI with a few trusted collaborators, on adedicated machine. Read [Security model and limits](#security-model-and-limits) before setting it up.

**To set one up, follow [SETUP.md](SETUP.md).** To change providers (another cloud, GitLab, other
models, another scheduler), see [docs/ADAPTING.md](docs/ADAPTING.md); it is written so that an AI agent
can do the adaptation for you.

**Disclaimer:** This kit is entirely vibe-coded.

## Security model and limits

The kit is built for a single PI who trusts their collaborators. It is **not** hardened for many users, open
collaboration, or anyone you wouldn't give a shell on the machine.

**What the agents can do.** Agents run as the lab accounts (`hpc`, `agent`) with full access to them: Codex in
`danger-full-access`, Claude in auto mode. They need this to build code, run jobs and manage repos. It means an
agent *can* read those accounts' GitHub and Slack tokens, use the open cluster connection (including calling
`sbatch` directly), and edit the lab's own files (ledger, registry, role prompts). The budgets, the job ledger,
the approval flow, the scoped cancel/delete tools and the "instructions come only from the PI" rule keep
well-behaved agents from making expensive mistakes. They do **not** stop an agent that has been subverted.

**How an agent could be subverted.** By text it reads and treats as instructions (prompt injection):
- Slack messages and threads from people in connected channels (including guests and external
  organizations). For people who aren't listed collaborators, the responder runs Claude with only Read,
  Grep, Glob and read-only `gh issue`/`gh pr view` on the project's own repo, no user or project settings
  (so no allow rules or hooks), and reads of home, the lab folder, other projects and `/proc` denied. That
  narrows what a hostile message can do, but it still runs as `hpc` with the bot token available to `gh`, and it
  rests on Claude Code's permission checks. A stronger setup runs strangers' turns as a separate Unix user
  holding only a read-only token. Listed collaborators' messages, and any thread text, reach agents with
  full access.
- GitHub issues and comments by collaborators or their own agents on shared repos.
- Web pages, papers, datasets and code the agents fetch.
- Anything a compromised collaborator account writes.

**Mitigations, in order of value.**
1. Use a dedicated machine, cloud project and GitHub organization for the lab, holding nothing else you care
   about. Keep the repos private. One lab per machine.
2. Add only collaborators you trust as you would with a shell account; connect only Slack channels whose
   members you know.
3. Give the bot a fine-grained token limited to the lab's repos, without Administration (repo deletion) or
   workflow rights if you can create repos yourself (SETUP.md, step 3).
4. For the cluster, get hard limits on the cluster side (a separate allocation, or Slurm QOS/account limits);
   the lab's budgets are its own rules.
5. Protect the Claude, OpenAI, GitHub and Tailscale accounts with two-factor login: the remote-control session
   and the dashboard are reachable through them.
6. Watch the daily digest and the ledger; rotate the bot token if anything looks wrong.

**Root and agent-owned files.** Agents running as `hpc` own `/srv/lab` and its `state/` folders, so a subverted
agent can replace a file or folder there with a symlink. The installer refuses to chown or chmod through
symlinks; when you run anything as root yourself (sudo), don't point it at agent-writable paths without the same
check, and review files under `/srv/lab/state/` before installing them as root.

## How it works

```
                  you (the PI): phone / laptop
     GitHub inbox · push notifications (ntfy) · dashboard · Claude remote control · Slack (optional)
                                   │
 ┌─────────────────────────────────┼──────────────────────── agentbox (one cloud VM, on Tailscale) ─┐
 │                                 ▼                                                                │
 │  director (one pass an hour) ── reads every project, relays your requests, writes the daily digest│
 │      │                                                                                           │
 │      ├── lead of project A (a pass when something changed) ── plans, reviews, merges, reports     │
 │      │      ├── worker  #12   (Slurm job: own clone, one issue, then stops)                        │
 │      │      ├── explorer #15  (open-ended, with a budget)                                         │
 │      │      └── verifier #12  (independent check of #12's claim)                                  │
 │      └── lead of project B ...                                                                   │
 │                                                                                                  │
 │  watchdog (every 5 min, no model) ── pushes interrupts, applies your approve/cancel, measures usage│
 │  Slurm (one node) ── every agent and every sizable run is a job, so the machine never overloads  │
 └───────────────────────────────────────────┬──────────────────────────────────────────────────────┘
                                             │ one shared ssh connection you open (TOTP)
                                             ▼
                               HPC cluster (optional): hpc-submit holds
                               jobs over budget for your approval
```

- **The board is GitHub.** Each project is a repo in your lab's organization (`<org>/<project>`) with a
  charter, a short STATUS.md, a dated notebook, DECISIONS.md (your binding steers, quoted) and issues.
  Lab-wide matters live in `<org>/lab`, which is also the lab's own folder (`/srv/lab`) on the machine.
- **Roles** (`templates/lab/roles/`): the director (portfolio, resources, your requests), leads (plan,
  assign, review, merge to the project's main, report, step back every ~8 hours to check direction),
  workers (one task, one branch, then stop), explorers (open-ended with a budget), verifiers (check a
  claimed result independently). Each pass of a director or lead is a fresh, non-interactive session that
  reads the files and the board, so nothing depends on an agent's memory.
- **Verification standard.** A result counts only after a check that could have failed: an independent
  method, higher precision, a special case with a known answer. Claims carry tags: (P) published,
  (V) independently verified, (D) derived once, (I) inference, (W) unverified claim from another agent.
  Speedups must name their baseline (your real production setup, or a lab-built one).
- **What reaches you** (`templates/lab/PRIORITIES.md`): four levels. *log* (notebook only), *digest*
  (one daily issue, two minutes on a phone), *ask* (an inbox issue with the default the lab follows
  meanwhile; nobody waits), *interrupt* (pushed to your phone; rare). The director tunes these from your
  reactions.
- **Finite resources.** `lab usage` and the dashboard show Codex's weekly window (and optional purchased
  credits), the lab's share of your Claude plan, and cluster SUs per project. The lab paces itself: when
  Codex runs ahead of the week, no new explorers start; at the limit only verifiers start. Claude is
  kept to a small share because you use it too. Cluster jobs within the per-job, per-day and monthly
  budgets start at once; bigger ones wait, held, for your `approve`.
- **Your controls are plain.** Comment `approve` or `cancel` on an issue; comment on any issue from your
  own GitHub account to instruct (agents count only your login, and the lab's own relays); `lab limit|pause|resume|budget`; talk to the director (`lab chat lab`, Claude
  remote control, or a Slack DM); attach to a working agent (`talk <project> <issue>`).
- **Rails against mistakes** (not a security boundary; see "Security model and limits"). The settings that
  bound the agents (`/etc/agentbox/lab.conf`) and the scripts that apply them are root-owned. Agents are told
  never to read or print tokens, and the tools never pass tokens to them. Only your own GitHub account's
  unedited comments approve anything. Agents cancel and delete only through scoped tools (`hpc-cancel`, `lab-cancel`, `lab-rm`) that
  refuse anything outside their project. Collaborators' agents follow the same per-project protocol
  (`templates/project/AGENTS.md`), and only humans make decisions.

## What's in the kit

| Path | What |
|---|---|
| `SETUP.md` | The human's steps, in order, with a check after each |
| `install/install.sh` | Root installer for Ubuntu 24.04: packages, accounts, folders, Slurm, scripts |
| `bin/` | `lab` (the command), `lab-loop` (director/lead cycles), `lab-worker` (one agent job), `watchdog`, `lab-usage`, `talk`, `lab-cancel`, `lab-rm`, tmux helpers, Claude hooks |
| `share/` | `lib.sh` (settings, pacing, helpers), `user-setup.sh` (per account), config templates incl. `lab.conf.example` |
| `templates/lab/` | The lab folder: LAB-RULES.md (every agent reads it), PRIORITIES.md, roles, models.conf |
| `templates/project/` | A new project's repo: AGENTS.md protocol, CHARTER/STATUS/DECISIONS, notebook, notes, calc |
| `dashboard/` | A small web page: agents, jobs, models, limits, alerts, with buttons that file requests |
| `slack/` | Optional Slack bot: channel mirrors, posting with approval, a responder for mentions and DMs |
| `hpc/` | Optional cluster tools: `hpc-connect`, `hpc-check`, `hpc-submit` (budgets and ledger), `hpc-cancel` |
| `tests/` | Offline tests (e.g. `python3 tests/test_hpc_submit.py`) |
| `docs/ADAPTING.md` | Notes for other providers |

## Status

This kit was extracted from a lab that has run for a while, and its scripts are the ones that lab runs,
generalized. The installer was reconstructed from that machine rather than replayed on a fresh one, so
expect to fix small things on the first install (SETUP.md flags the likely spots). Model names in
`templates/lab/models.conf` will date; set them to the current best models.

## How it is used in practice

The human co-author's usual way of working with the lab: ssh in, start a Claude Code chat on the lab
machine that stays open, and use Claude's remote control to talk to it from a phone or any laptop. That
one long-running chat is the director for day-to-day conversation; the scheduled director passes, leads and workers
run on their own around it. SETUP.md ("Daily use") shows how to set this up.

## Credits

Human co-author: David Simmons-Duffin.
AI co-author: Claude (Anthropic), which wrote most of the code and documentation.

License: MIT (see [LICENSE](LICENSE)).
