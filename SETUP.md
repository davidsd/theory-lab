# Setting up a lab

About two hours, most of it waiting for installs. You need: a Google Cloud account (or another cloud;
see docs/ADAPTING.md), a GitHub account, a Claude subscription (Max is best), an OpenAI ChatGPT plan with
Codex (Pro is best), and a phone. Optional: a second pair of subscriptions (for the second lab account),
an HPC allocation with ssh access, a Slack workspace.

Each step ends with a **Check**. Don't go on until it passes.

> **Read first: who this is for.** The kit is meant for one PI and a few *trusted* collaborators, on a
> machine used for nothing else. It is not hardened for wide use or untrusted people. The agents run with
> full access as the lab accounts, so they can read those accounts' tokens and use the open cluster
> connection; the budgets, approvals and "From the PI" conventions guard against mistakes, not against a
> hostile agent or a prompt injection. Read "Security model and limits" in README.md before you start, and
> keep its mitigations in mind at each step below.

Words used below: the **machine** (the cloud VM, called `agentbox` here); **your login** (your own user
on it, with sudo); the **lab accounts** `hpc` and `agent` (Unix users the agents run as); the **bot** (a
GitHub account the agents use).

---

## 1. Create the machine (Google Cloud)

1. In the Cloud console, create a project (billing on). Compute Engine → VM instances → Create instance:
   - Name `agentbox`; a region near you.
   - Machine type: `n2d-standard-16` (16 vCPUs, 64 GB) is comfortable for ~6–10 agents at once; 8 vCPUs
     works for a small lab. Agents mostly wait on the models, so CPUs matter for builds and numerics.
   - Boot disk: Ubuntu 24.04 LTS (x86/64), 500 GB balanced persistent disk (SSD if you can).
   - Firewall: leave "Allow HTTP/HTTPS" unchecked. Keep the external IP (the machine needs outbound
     internet); inbound access will be through Tailscale only.
2. Open it with the console's **SSH** button. That makes your login (your Google username).
3. Optional, recommended: set the time zone the digest uses: `sudo timedatectl set-timezone <Area/City>`.

**Check:** in the SSH window, `nproc` and `df -h /` show the CPUs and disk you chose.

## 2. Tailscale (private network for your devices)

Tailscale puts the machine, your phone and your laptops on a private network, so nothing on the machine
is exposed to the internet.

1. Make a Tailscale account (https://tailscale.com, free for personal use). Install the app on your
   phone and laptop(s), and sign in to the same account on each.
2. On the machine: `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up --ssh`
   and open the link it prints to add the machine. (`--ssh` lets your devices ssh in with your Tailscale
   identity, so you don't need to manage ssh keys.)
3. In the Tailscale admin console, note the machine's name, e.g. `agentbox.<tailnet>.ts.net`, and turn
   on MagicDNS if it is off.
4. Now close the internet-facing door: in Google Cloud, VPC network → Firewall, delete or disable the
   default rule allowing SSH (`default-allow-ssh`) from 0.0.0.0/0.

**Check:** from your laptop, `ssh <your-login>@agentbox` works (via Tailscale), and the cloud console's
SSH button no longer connects.

## 3. GitHub: an organization and a bot account

1. Create a GitHub organization used only for the lab (free plan is fine), e.g. `mylab-org`. You are its
   owner. Keep its repos private; a separate org means a leaked bot token reaches nothing else of yours.
2. Create a second GitHub account for the agents, e.g. `mylab-agents` (GitHub allows one machine
   account per person; use another email address). Invite it to the organization as a **member, not an
   owner**, and accept. Give it Write access on the lab's repos.
3. Signed in as the bot, create a **fine-grained** token: Settings → Developer settings → Personal access
   tokens → Fine-grained. Resource owner: the organization. Permissions: Contents, Issues and Pull requests
   (read/write), Metadata (read). Don't add Actions or Workflows: agents have no need to edit CI.
   - **Creating project repos.** `lab new` creates a repo per project, which needs Administration
     (read/write) on the token and "members can create private repositories" in the org's settings.
     **Administration write also allows deleting and renaming repos**, so the safer choice is to leave it
     off and create each project's empty repo yourself (`gh repo create <org>/<project> --private`); then
     `lab new` uses it. Either way, "Only select repositories" keeps the token to the lab's repos, but you
     must add each new repo to the token by hand; "All repositories" is acceptable in an org that holds only
     the lab.
   - A classic token (`repo`, `read:org`) works too but reaches every repo the bot can see; prefer
     fine-grained.
   Give it an expiry (e.g. 90 days) and put a reminder in your calendar. Keep the token at hand for step 6;
   don't paste it into any agent or chat.

**Check:** the organization lists the bot as a member, and you have the token.

## 4. Run the installer

On the machine, from your login:

```bash
git clone https://github.com/<where-you-got-this>/theory-lab.git && cd theory-lab
sudo bash install/install.sh --pi "$USER"            # add --no-second-account if you have one set of subscriptions
```

It installs packages, Slurm with its accounting database (slurmdbd and MariaDB: without accounting, Slurm
rejects jobs that have to wait in the queue), the `hpc` (and `agent`) accounts with user services that run
without a login (the agents' pool), `/srv/lab`, `/srv/projects`, the scripts in `/usr/local/bin`, and
`/etc/agentbox/lab.conf`. Log out and back in afterwards (you joined group `agents`).

Know what it sets up:
- Third-party installers are fetched and run unpinned (`curl ... | sh`: Tailscale here, Claude Code, Codex and
  uv in `share/user-setup.sh`), as their vendors recommend. Read them first if that matters to you.
- A sudoers rule lets `hpc` run `lab` as `agent` without a password, so the director can manage projects on
  the second account. Since `hpc` also writes the lab's files that `agent`'s runs read, treat the two accounts
  as one trust domain: whoever controls `hpc` controls `agent`.

**Check:** `sinfo` shows one node `idle`; `sacctmgr show assoc` lists account `lab` with users `hpc` (and
`agent`); `loginctl show-user hpc -p Linger` says `yes`; `lab help` prints the commands; `ls /srv/lab` shows
LAB-RULES.md.
If Slurm's node shows `down` or `drain`: `sudo scontrol update nodename=$(hostname -s) state=resume`, and
read `/var/log/slurm/slurmd.log` (a RealMemory larger than the machine has is the usual cause).

## 5. Settings: /etc/agentbox/lab.conf

`sudo nano /etc/agentbox/lab.conf` and set at least:

- `ORG` (the organization) and `PI_GITHUB` (your own GitHub username: only your comments approve things).
- `NTFY_URL`: install the **ntfy** app on your phone, pick a long random topic (e.g. the output of
  `openssl rand -hex 16`), subscribe to it in the app, and write `https://ntfy.sh/<topic>`. Anyone who
  knows the topic can read your notifications, so keep it secret.
- The Claude share (`CLAUDE_LAB_RUNS_PER_WEEK`, `CLAUDE_LAB_STOP_PERCENT`): how much of your Claude plan
  the lab may use. Start small (e.g. 30 runs, 60%) and raise it once you see the lab's habits. If you buy
  Claude usage credits and want the lab to keep going past the stop percent, set `CLAUDE_CREDITS=on` (a run
  that fails for lack of credits pauses Claude for 6 hours). The dashboard estimates the balance from the
  balances you report: append tab-separated `<epoch> <USD> <note>` lines to `/srv/lab/state/usage/claude-credits.tsv`, or
  tell the director what the account page shows.
- The agents' pool (`AGENT_POOL_CPUS`, `AGENT_POOL_MEM_GB`): how many CPUs and GB all of one account's agents
  share for thinking, git and quick checks. Their computations run in Slurm on the rest of the machine. On a
  16-CPU machine, 4 CPUs and 24 GB is a reasonable start; `lab-capacity` shows later whether to change it.
- The ceilings (`<KEY>_MAX` at the end): how far the director may raise a working value on your instruction
  (`lab set`) without sudo.
- Leave the HPC section for step 9, and the OpenAI API lines unless you have an API budget for the lab (step 6).

**Check:** `lab notify test "hello"` (as your login) makes your phone buzz.

## 6. Log the lab accounts in

For each lab account (`hpc`, then `agent` if you have it):

```bash
sudo -iu hpc
bash /usr/local/share/agentbox/user-setup.sh       # asks for the bot's GitHub token (hidden input)
exit; sudo -iu hpc                                 # a fresh login, so the new PATH applies
claude                                             # log in with your Claude subscription, then /exit
codex login                                        # log in with your ChatGPT account (follow the link it prints)
```

The second account should log in to a **second** set of subscriptions; that is its whole point (twice the
usage limits). With one set, skip it (`--no-second-account` in step 4).

API keys instead of subscriptions also work (Claude Code reads `ANTHROPIC_API_KEY`, Codex can use an
OpenAI API key), but pacing in this kit reads the subscription windows; see docs/ADAPTING.md. If you use
keys, save them to a file yourself (`install -m 600 /dev/null ~/.config/lab/<name>.key` then edit it), and
never paste them into an agent.

**Optional: OpenAI API credits on top of the Codex plan.** As each lab account, run
`bash /usr/local/share/agentbox/user-setup.sh --codex-api` (it asks for the key, hidden, and logs Codex in to the
API in `~/.codex-api`, separate from the plan's login). Then set `CODEX_API_BUDGET_USD` in lab.conf, fill in
`/srv/lab/codex-api-prices.tsv` from OpenAI's pricing page (until it has prices the lab doesn't use the API),
and decide in LAB-RULES.md ("Finite resources") which projects may use it. `CODEX_API=on` lets Codex runs go on
the API when the plan's window is used up; leads can also put a chosen hard task on it with
`lab spawn ... --api "<why>"`. `lab usage` and the dashboard show the spend.

**Check:** as each account, `gh api user --jq .login` prints the bot's name; `claude -p "say ok"` and
`codex exec "say ok"` both answer.

## 7. Start the lab

As `hpc`:

```bash
lab init        # makes <org>/lab from /srv/lab and creates the labels
lab up          # starts the director, watchdog, dashboard and Claude remote control in tmux
lab status
```

**Check:** `https://github.com/<org>/lab` exists; `tmux attach -t agents` (as hpc) shows windows
`director`, `watchdog`, `dashboard`, `rc` (detach with Ctrl-b d); within an hour the director's first pass
commits to `<org>/lab`.

## 8. Your phone and laptops

- **Dashboard:** `http://agentbox.<tailnet>.ts.net:8765` on any device in your tailnet: agents, jobs,
  models, usage, alerts. Its buttons open pre-filled GitHub issues for the director. It has no login:
  every device in your tailnet can read it (agent messages, issue titles), so share the tailnet with no one
  else, or restrict port 8765 to your own devices with a Tailscale ACL.
- **GitHub mobile app:** your inbox is the issues assigned to you with label `inbox`; turn on its
  notifications for assigned issues.
- **ntfy app:** interrupts and machine alerts (step 5).
- **Claude:** https://claude.ai/code (or the Claude app) lists the machine's remote-control session; you can
  talk to Claude on the machine from your phone. The kit turns remote control on for every Claude session
  on the lab accounts (`remoteControlAtStartup` in `share/config/claude-settings.json`), so anyone signed in
  to that Claude account can drive them: protect it with a strong password and two-factor login, or turn the
  setting off and enable `/remote-control` only in the session you keep open. `lab chat lab` (as hpc, in a terminal) starts a direct
  conversation with the director.
- **ssh from a new laptop:** install Tailscale there and sign in; with `tailscale up --ssh` on the machine
  (step 2) nothing else is needed: `ssh hpc@agentbox`.

**Check:** the dashboard loads on your phone.

## 9. Optional: an HPC cluster

The lab reaches the cluster through **one** ssh connection that you open, with your password or key and a
one-time code, on the `hpc` account. Agents don't log in themselves, so they don't trip the center's rate
limits or lock your account. But while the connection is open, anything running as `hpc` can use it, including
running `sbatch` directly instead of through `hpc-submit`: the budgets are the agents' rules, not enforced by
the cluster. For hard limits, ask your center for a separate allocation/account for the lab, or Slurm QOS or
account limits on it.

**The ssh key.** `hpc-connect` creates `~/.ssh/cluster_ed25519` without a passphrase so the connection can be
reopened with only the one-time code. Agents run as `hpc` and can read that key. Whether a key *alone* can log
in depends on your center: if it also always asks for a one-time code, the key is of little use to anyone
else; if it accepts keys alone, give the key a passphrase (`ssh-keygen -p -f ~/.ssh/cluster_ed25519`) and load it
into an ssh-agent only while you run `hpc-connect`, or don't install the key and type your password each time.

1. In lab.conf set `WATCH_HPC=yes`, `HPC_LOGIN_HOST`, `HPC_USER`, `HPC_SCRATCH_ROOT`, `HPC_HOME_ROOT`, the
   cost model (`HPC_WHOLE_NODE_PARTITIONS`, `HPC_CORES_PER_NODE`; for shared partitions that charge memory,
   `HPC_GB_PER_CORE`, or `HPC_BILLING_PER_SU` if the center's Slurm reports SUs in its billing TRES) and the
   budgets (`HPC_AUTO_SUS_PER_JOB`, `HPC_AUTO_SUS_PER_DAY`, `HPC_LAB_SUS_PER_MONTH`). Jobs within all of them
   start at once. A job over only the daily limit is queued quietly (an issue labeled `hpc-queued`, assigned to
   no one) and released by the watchdog as soon as it fits. Bigger ones are held and appear in your inbox;
   comment `approve` or `cancel`. Optional, for the dashboard: `HPC_BALANCE_CMD` (a command on the cluster that
   prints the allocation's balance) and, on a Lustre scratch, `HPC_SCRATCH_FS` and `HPC_SCRATCH_GROUP` (many
   centers' scratch quota that matters is the group's, shared with everyone in your allocation).
2. As hpc: `bash /usr/local/share/agentbox/user-setup.sh --hpc` (adds the ssh settings), then `hpc-connect`.
   The first time it asks for your password and code and installs a key; later only the code.
3. Per project: `lab budget <project> <SUs per month>`.
4. Write down in LAB-RULES.md anything specific to your center: quotas (bytes and file counts) on scratch
   and home, partitions, typical failures. The rules already say how agents triage failures and keep
   small files off parallel filesystems.
5. Optional: to let a project's queued jobs skip the daily limit for a while (e.g. a planned burst), tell the
   director; it writes `/srv/lab/state/hpc-standing.json` (`{"<project>": {"until": <epoch>, "why": "<your
   words>"}}`). The per-job, monthly and project budgets still apply.

The connection drops now and then (network, login-node reboots). The watchdog pushes "not connected" to your
phone; run `hpc-connect` again (if it says "already connected" but nothing works, first
`ssh -O exit cluster-login`).

**Check:** as hpc, `hpc-check` says connected and `ssh cluster hostname` answers. A test:
`hpc-submit --project <p> --issue 1 --reason test -- 'sbatch -p <test-partition> -t 5 --wrap hostname'`.

## 10. Optional: Slack

1. https://api.slack.com/apps → Create New App → From a manifest → paste `slack/manifest.yaml` (rename
   the bot if you like, and set `SLACK_BOT_NAME` in lab.conf to match). Install it to the workspace.
2. Under Basic Information → App-Level Tokens, make one with scope `connections:write`.
3. Save both tokens as hpc, yourself, so they never pass through an agent's conversation. (Agents running as
   hpc could still read the files; they are told not to. See README, "Security model and limits".)
   ```bash
   sudo -iu hpc
   umask 077 && mkdir -p ~/.config/lab
   read -rs t && printf '%s\n' "$t" > ~/.config/lab/slack-<workspace>.token       # the xoxb- bot token
   read -rs t && printf '%s\n' "$t" > ~/.config/lab/slack-<workspace>.apptoken    # the xapp- token
   ```
4. As hpc, `cp /srv/lab/slack.conf.example /srv/lab/slack.conf` and fill in the workspace, your own
   Slack member id (`pi` line), and channels with their projects and modes. Invite the bot to each channel.
5. Rerun the installer with `--slack` (adds the cron jobs and the Python environment).
6. Project summaries: with the `pi` line in slack.conf, leads send you each summary as a DM with the PDF
   attached (the app needs the `files:write` scope; the manifest has it). To have a project's summaries
   shared in a channel when you reply `post`, list that channel in slack.conf for the project (mode `draft` or
   `post`) and write the mapping in LAB-RULES.md ("Project summaries"). Summaries may quote their own channel
   and use the project's own private data, so map each project only to a channel its collaborators share.
   For people whose Slack accounts can't be linked by `link github`, add `person` lines (Slack user ids).

**Check:** DM the bot `whoami`; then `link github <your-handle>` and follow its instructions.

## 11. Your first project

Talk to the director (`lab chat lab` as hpc, or via Claude remote control): describe the project, its
goal, what you want to hear about, budgets, and code repos. The director drafts a charter and runs
`lab new <name>`, which creates `<org>/<name>` and an issue "Approve the charter". Read it on GitHub, edit
it if you like, and comment `approve`. The project's lead starts within minutes and fills its job slots
(`lab limit <name> <n>`).

To bring in an existing repo: transfer it to the organization and use `lab adopt <name>`.

Collaborators: add them to the project repo on GitHub and to the People table in its AGENTS.md. Their own
agents can then work in the repo under the same protocol.

**Check:** within an hour the project's board has issues and `lab status` shows its agents (ids a1, a2, ...).

## 12. Optional: approve settings from your phone

Changes to `/etc/agentbox/lab.conf` need sudo, which a phone doesn't have. This installs a root timer that
applies changes you approve on a GitHub issue:

1. As hpc: `gh issue create -R <org>/lab --title "Settings changes for the PI" --body "Proposals from
   lab-settings-propose; reply approve P<n> or cancel P<n>."` and note its number.
2. From **your own** GitHub account, make a fine-grained token: resource owner the organization, repository
   `lab` only, permission Issues: Read-only. Root reads the issue with it, never with the bot's token.
3. `sudo bash install/install.sh --settings <issue number>` (from the kit's folder): it asks for the token
   (hidden), installs `lab-settings-apply` with its timer (every 3 minutes) and the list of keys you may change
   this way with their hard maxima, `/etc/agentbox/settings-max.conf`. Edit that list now (`sudo nano`).

From then on, ask the director in plain words ("raise the daily SU limit to 20000"); it posts a proposal
`P<n>` with the old and new values; you comment `approve P<n>`. Only your account's comment counts, only for
listed keys up to their maxima, only if lab.conf still has the old value, and never for an edited proposal.
The watchdog posts the result on the issue (and with Slack, in your DM).

**Check:** `systemctl list-timers lab-settings.timer` shows it; `sudo /usr/local/sbin/lab-settings-apply`
exits without an error.

## Daily use

**The simplest way to work with the lab:** ssh into the machine as `hpc`, start a Claude Code chat in
`/srv/lab` (`cd /srv/lab && claude`) and leave it running in tmux, with remote control on (`/remote-control`,
or `"remoteControlAtStartup": true` in `~/.claude/settings.json`). That chat is your director: ask it
anything about the lab, give it instructions, have it relay decisions to the boards. From then on you can
talk to the same chat from the Claude app on your phone or from claude.ai/code on any laptop, without ssh.
Keep it open; when its context fills up it summarizes itself and carries on.

- Read the project summaries (twice a day, when something happened), the daily digest (an issue in
  `<org>/lab`: one line per project, and every open question with its default) and your inbox. Answer `ask`s
  when convenient; the lab follows the stated default meanwhile. Interrupts come to your phone.
- Steer by commenting on any issue (your comments come first), or through the director.
- `lab limit|pause|resume|retire|budget`, `lab usage`, `lab status`, `talk <project> <issue>` (attach to a
  running Codex worker), `tmux attach -t agents` (all windows). Tell the director to change a working value or
  a model (`lab set`, `lab model`; `lab set` alone shows them all). A paused project's lead still looks in every
  72 hours if something changed, and reports only significant progress.
- After updating the kit's scripts (rerun the installer), `lab-reload-loops` as hpc restarts the director and
  lead loops between passes; running agents and jobs are not touched (don't use `lab _stop` for this: it
  cancels the project's jobs).
- Things only you can do: sudo (system packages, raising Slurm's CPUs for oversubscription), reconnecting
  the cluster, approving charters and held jobs, adding collaborators, editing lab.conf.

## Troubleshooting

- **Nothing starts:** `lab usage`. "stop" means Codex's weekly window is used up (or the Claude share). A
  `lab spawn` that says "systemd-run failed" means the account's user manager isn't running:
  `sudo loginctl enable-linger hpc agent`.
- **Slurm jobs stay pending with reason InvalidAccount:** Slurm has no accounting associations. Check
  `systemctl status slurmdbd` and `sacctmgr show assoc`; rerunning the installer sets them up.
- **A Claude session waits at a permission prompt:** the watchdog pushes it after 10 minutes. The lab runs
  agents with `--permission-mode auto`; allow rules for the lab's own tools are in
  `/usr/local/share/agentbox/config/claude-settings.json`.
- **After a reboot:** the installer adds `@reboot lab up` to hpc's crontab. If that doesn't work on your
  machine, run `lab up` as hpc by hand.
- **Disk:** keep `data/` for working sets; big finished data goes to the cluster's scratch or a bucket.
