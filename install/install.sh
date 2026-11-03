#!/usr/bin/env bash
# install.sh: set up a lab machine from this kit. Run as root on a fresh Ubuntu 24.04 VM, from the kit's folder:
#   sudo bash install/install.sh [--pi <your-login>] [--no-second-account] [--no-latex] [--slack]
#                                [--settings <issue number>]
# Safe to run again: it only creates what is missing, and it refreshes the installed scripts and templates
# (never your settings, registry, notes or projects).
#
# What it does:
#   1. system packages (git, jq, tmux, gh, Slurm, munge, Tailscale, Python, optional LaTeX)
#   2. accounts: `hpc` (the main lab account; it also holds the cluster connection, if any) and, unless
#      --no-second-account, `agent` (a second account logged in to a second set of AI subscriptions, so
#      its usage limits are separate); a shared group `agents`, which your own login joins too
#   3. folders: /srv/lab (lab files), /srv/projects (one per project), /srv/agents/status (dashboard)
#   4. the kit's scripts in /usr/local/bin, shared files and templates in /usr/local/share/agentbox,
#      settings in /etc/agentbox/lab.conf (root-owned, so agents can't change their own limits)
#   5. a one-node Slurm that schedules by CPU, so computations queue instead of overloading the machine, with
#      an accounting database (slurmdbd + MariaDB): without one, Slurm rejects jobs that have to wait in the queue
#   6. user services for the lab accounts without a login (linger), so agents run as services in a capped
#      pool outside Slurm (AGENT_RUNNER=systemd), and their registry folder /srv/lab/state/agents
#   7. sudo rule: hpc may run `lab` as agent (lab switches accounts by itself)
#   8. hpc's crontab: start the lab after a reboot, the reset watcher; with --slack, the Slack sync and listener
#   9. with --settings <n>: root's lab-settings-apply on a timer, so you can approve changes to lab.conf from
#      your phone on issue <n> of <ORG>/lab (it asks for a read-only GitHub token; SETUP.md, step 12)
#
# RECONSTRUCTED: this script was written from a working lab machine, not replayed on a fresh one. Steps
# marked "unverified" below were inferred; check them on the first install (SETUP.md says how).
set -euo pipefail

kit=$(cd "$(dirname "$0")/.." && pwd)
pi=${SUDO_USER:-}
second=yes latex=yes slack=no settings=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --settings) settings=${2:-}; [[ $settings =~ ^[0-9]+$ ]] || { echo "--settings takes the settings issue's number" >&2; exit 1; }; shift 2 ;;
    --pi) pi=$2; shift 2 ;;
    --no-second-account) second=no; shift ;;
    --no-latex) latex=no; shift ;;
    --slack) slack=yes; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
[[ $(id -u) == 0 ]] || { echo "Run as root: sudo bash $0" >&2; exit 1; }
[[ -n $pi && $pi != root ]] || { echo "Say which login is yours: --pi <login>" >&2; exit 1; }
id "$pi" > /dev/null || { echo "No user $pi." >&2; exit 1; }
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || echo "Warning: written for Ubuntu 24.04; this is ${PRETTY_NAME:-unknown}. See docs/ADAPTING.md." >&2

step() { printf '\n== %s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# lab_dir <owner> <group> <mode> <dir>...: create or fix lab folders as root without following symlinks.
# The lab accounts own /srv/lab, so on a rerun any path in it may have been replaced by a symlink; chown or
# chmod through one would hand its target (e.g. /usr/local/bin) to them. Refuse instead.
lab_dir() {
  local owner=$1 group=$2 mode=$3 d; shift 3
  for d in "$@"; do
    [[ $(realpath -m -- "$d") == "$d" ]] || die "$d is or goes through a symlink; refusing to change it as root."
    [[ ! -e $d || ( -d $d && ! -L $d ) ]] || die "$d exists and is not a plain folder; refusing."
    install -d -o "$owner" -g "$group" -m "$mode" -- "$d"
  done
}

step "System packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q git jq tmux curl ca-certificates ripgrep build-essential python3 python3-venv \
  munge slurm-wlm slurm-client slurmdbd mariadb-server openssl acl emacs-nox
if [[ $latex == yes ]]; then
  apt-get install -y -q latexmk texlive-latex-base texlive-latex-recommended texlive-latex-extra \
    texlive-fonts-recommended texlive-science texlive-pictures
fi
if ! command -v gh > /dev/null; then   # GitHub CLI, from GitHub's apt repository
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod 644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -q && apt-get install -y -q gh
fi
command -v tailscale > /dev/null || curl -fsSL https://tailscale.com/install.sh | sh

step "Accounts and group"
getent group agents > /dev/null || groupadd agents
accounts=(hpc)
[[ $second == yes ]] && accounts+=(agent)
for a in "${accounts[@]}"; do
  id "$a" > /dev/null 2>&1 || useradd -m -s /bin/bash "$a"
  usermod -aG agents,users "$a"
done
usermod -aG agents "$pi"
if [[ $second == yes ]]; then
  # The dashboard (run by hpc) shows a running Claude agent's latest message from its live transcript, which
  # the agent account writes in its own home: let hpc read just that folder. (The accounts are one trust
  # domain anyway; README, "Security model and limits".)
  # Done as agent, not root: the folder is agent's, so a link planted there must not steer a root chown/setfacl.
  sudo -u agent -H bash -c 'install -d -m 700 ~/.claude ~/.claude/projects && setfacl -m u:hpc:x ~ ~/.claude &&
    setfacl -P -R -m u:hpc:rX -m d:u:hpc:rX ~/.claude/projects'
fi

step "Folders"
lab_dir root root 755 /srv /srv/agents
lab_dir root agents 3775 /srv/agents/status /srv/projects   # shared, setgid, sticky
lab_dir hpc agents 2755 /srv/lab
lab_dir hpc agents 3775 /srv/lab/state /srv/lab/state/usage /srv/lab/state/logs /srv/lab/state/agents
# The agents' id counter, shared by both accounts (lib.sh new_agent_id). Made as hpc, so root never writes there.
sudo -u hpc bash -c 'umask 002; cd /srv/lab/state/agents && for f in next next.lock; do [[ -e $f ]] || : > "$f"; done; chmod 664 next next.lock'

step "Scripts, shared files and templates"
install -m 755 "$kit"/bin/* "$kit"/hpc/hpc-connect "$kit"/hpc/hpc-check "$kit"/hpc/hpc-submit \
  "$kit"/hpc/hpc-cancel "$kit"/hpc/hpc-release-queued "$kit"/slack/lab-slack "$kit"/slack/lab-slack-listen /usr/local/bin/
share=/usr/local/share/agentbox
install -d -m 755 "$share" "$share/config"
install -m 644 "$kit/share/lib.sh" "$share/"
install -m 755 "$kit/share/user-setup.sh" "$share/"
install -m 644 "$kit"/share/config/* "$share/config/"
install -m 644 "$kit/hpc/ssh-config.example" "$share/config/hpc-ssh-config"
rm -rf "$share/lab-template" "$share/project-template" "$share/dashboard" "$share/tests"
cp -r "$kit/templates/lab" "$share/lab-template"
cp -r "$kit/templates/project" "$share/project-template"
cp -r "$kit/dashboard" "$share/dashboard"
cp -r "$kit/tests" "$share/tests"
install -m 644 "$kit/slack/slack.conf.example" "$share/config/slack.conf.example"
chmod -R a+rX "$share"

step "Settings: /etc/agentbox/lab.conf"
install -d -m 755 /etc/agentbox
[[ -f /etc/agentbox/lab.conf ]] || install -m 644 "$kit/share/config/lab.conf.example" /etc/agentbox/lab.conf

step "The lab folder"
# Copies run as hpc, so nothing in the agent-owned tree is written or chowned by root.
if [[ ! -f /srv/lab/registry.json ]]; then
  sudo -u hpc cp -r "$share/lab-template/." /srv/lab/
  sudo -u hpc cp "$share/config/slack.conf.example" /srv/lab/slack.conf.example
fi
for f in limits.conf arxiv-topics.json codex-api-prices.tsv; do   # newer template files, for labs made before them
  [[ -e /srv/lab/$f || -L /srv/lab/$f ]] || sudo -u hpc cp "$share/lab-template/$f" "/srv/lab/$f"
done
for d in dashboard tests; do              # these two come from the kit; refresh them
  [[ ! -L /srv/lab/$d ]] || die "/srv/lab/$d is a symlink; refusing."
  sudo -u hpc rm -rf "/srv/lab/$d"
  sudo -u hpc cp -r "$share/$d" "/srv/lab/$d"
done

step "tmux defaults for everyone"
[[ -f /etc/tmux.conf ]] || cat > /etc/tmux.conf <<'EOF'
# tmux settings for everyone on this machine.
set -g mouse on                  # scroll and switch windows by mouse or touch
set -g history-limit 50000
set -g allow-rename off          # keep the window names that new-agent and lab set
set -g default-terminal "tmux-256color"
EOF

step "Slurm (one node, scheduling by CPU)"
host=$(hostname -s)
cpus=$(nproc --all)
mem_mb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 * 85 / 100 ))   # leave ~15% for the system
threads=$(lscpu | awk -F: '/Thread\(s\) per core/ {gsub(/ /, "", $2); print $2}'); threads=${threads:-1}
sockets=$(lscpu | awk -F: '/Socket\(s\)/ {gsub(/ /, "", $2); print $2}'); sockets=${sockets:-1}
cores=$(( cpus / threads / sockets ))
if [[ ! -f /etc/slurm/slurm.conf ]]; then
  install -d -m 755 /etc/slurm
  cat > /etc/slurm/slurm.conf <<EOF
ClusterName=$host
SlurmctldHost=$host
AuthType=auth/munge
SlurmUser=slurm
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
JobCompType=jobcomp/filetxt
JobCompLoc=/var/log/slurm/jobcomp.log
ProctrackType=proctrack/cgroup
TaskPlugin=task/cgroup,task/affinity
SelectType=select/cons_tres
SelectTypeParameters=CR_Core
SchedulerType=sched/backfill
ReturnToService=2
DefMemPerCPU=$(( mem_mb / cpus ))
NodeName=$host CPUs=$cpus Boards=1 SocketsPerBoard=$sockets CoresPerSocket=$cores ThreadsPerCore=$threads RealMemory=$mem_mb State=UNKNOWN
PartitionName=main Nodes=$host Default=YES MaxTime=INFINITE State=UP
EOF
  # Agents mostly wait on models, not CPUs. To let more agents run than there are cores, raise CPUs= above
  # the real count (oversubscription) and restart slurmctld and slurmd; the lab's own limits still apply.
fi
[[ -f /etc/slurm/cgroup.conf ]] || printf 'ConstrainCores=yes\nConstrainRAMSpace=yes\n' > /etc/slurm/cgroup.conf
install -d -o slurm -g slurm -m 755 /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
[[ -s /etc/munge/munge.key ]] || { /usr/sbin/mungekey -c 2> /dev/null || dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key; }
chown munge:munge /etc/munge/munge.key && chmod 400 /etc/munge/munge.key
systemctl enable --now munge
systemctl enable slurmctld slurmd
systemctl restart slurmctld slurmd
sleep 2
scontrol update nodename="$host" state=resume 2> /dev/null || true

# Accounting. Slurm without slurmdbd has no associations; its scheduler then rejects any job that has to wait in
# the queue ("invalid account", reason InvalidAccount), so only jobs that start at once ever run.
systemctl enable --now mariadb
dbconf=/etc/slurm/slurmdbd.conf
if [[ ! -f $dbconf ]]; then
  pass=$(openssl rand -hex 24)
  mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS slurm_acct_db;
CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY '$pass';
ALTER USER 'slurm'@'localhost' IDENTIFIED BY '$pass';
GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost';
FLUSH PRIVILEGES;
SQL
  (umask 077; cat > "$dbconf" <<EOF
AuthType=auth/munge
DbdHost=localhost
SlurmUser=slurm
StorageType=accounting_storage/mysql
StorageHost=localhost
StorageUser=slurm
StoragePass=$pass
StorageLoc=slurm_acct_db
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/run/slurmdbd.pid
EOF
  )
  unset pass
  chown slurm:slurm "$dbconf"; chmod 600 "$dbconf"   # the password is only in this file, never printed
fi
systemctl enable slurmdbd
systemctl is-active -q slurmdbd || systemctl restart slurmdbd
for _ in $(seq 30); do ss -ltn | grep -q ':6819 ' && break; sleep 2; done
ss -ltn | grep -q ':6819 ' || die "slurmdbd did not come up; see /var/log/slurm/slurmdbd.log"
if ! grep -q '^AccountingStorageType=accounting_storage/slurmdbd' /etc/slurm/slurm.conf; then
  sed -i '/^AccountingStorageType=/d; /^AccountingStorageHost=/d' /etc/slurm/slurm.conf
  sed -i "/^SchedulerType=/a AccountingStorageType=accounting_storage/slurmdbd\nAccountingStorageHost=localhost" /etc/slurm/slurm.conf
  systemctl restart slurmctld
fi
for _ in $(seq 30); do sacctmgr -n show cluster > /dev/null 2>&1 && break; sleep 2; done
sacctmgr -i add cluster "$host" > /dev/null 2>&1 || true
sacctmgr -i add account lab Cluster="$host" Description="lab agents" Organization=lab > /dev/null 2>&1 || true
for a in "${accounts[@]}"; do
  sacctmgr -i add user "$a" Account=lab DefaultAccount=lab Cluster="$host" > /dev/null 2>&1 || true
done
systemctl restart slurmctld
sleep 3
sinfo
sacctmgr -n show assoc format=cluster,account,user

step "User services without a login (agents outside Slurm)"
# lab spawn starts workers, explorers and verifiers as user services (systemd-run --user) in lab-agents.slice,
# capped at AGENT_POOL_CPUS / AGENT_POOL_MEM_GB per account; they need the accounts' user managers running.
loginctl enable-linger "${accounts[@]}"

step "sudo rule: hpc runs lab as agent"
if [[ $second == yes ]]; then
  echo 'hpc ALL=(agent) NOPASSWD: /usr/local/bin/lab' > /etc/sudoers.d/theory-lab
  chmod 440 /etc/sudoers.d/theory-lab
  visudo -cf /etc/sudoers.d/theory-lab
fi

step "hpc's crontab"
cron=$(crontab -u hpc -l 2> /dev/null || true)
add_cron() { grep -qF -- "$1" <<<"$cron" || cron+=$'\n'"$1"; }
add_cron '@reboot sleep 60 && /usr/local/bin/lab up > /srv/lab/state/logs/lab-up.log 2>&1'   # unverified: the source machine was restarted by hand with `lab up`
add_cron '*/10 * * * * /usr/local/bin/lab-reset-watch >> /srv/lab/state/logs/reset-watch.log 2>&1'
if [[ $slack == yes ]]; then
  add_cron '*/10 * * * * /usr/local/bin/lab-slack sync >> /srv/lab/state/slack/sync.log 2>&1'
  add_cron '*/5 * * * * flock -n /srv/lab/state/slack/listen.lock /usr/local/bin/lab-slack-listen >> /srv/lab/state/slack/listen.log 2>&1'
  # Only hpc's sync and listener write lab-slack's state (approved posts, offers, replay queue); the agent account
  # only queues requests in outbox/ (sticky: it can't remove or rename what hpc keeps there).
  lab_dir hpc agents 2750 /srv/lab/state/slack
  lab_dir hpc agents 3770 /srv/lab/state/slack/outbox
  sudo -u hpc -H bash -c '[[ -x ~/opt/slack-venv/bin/python ]] || { python3 -m venv ~/opt/slack-venv && ~/opt/slack-venv/bin/pip install -q slack_sdk; }'
fi
printf '%s\n' "$cron" | sed '/^$/d' | crontab -u hpc -

if [[ -n $settings ]]; then
  step "Settings the PI approves from a phone (lab-settings-apply)"
  org=$(sed -nE 's/^[[:space:]]*ORG=([^[:space:]#]*).*/\1/p' /etc/agentbox/lab.conf | head -1)
  [[ -n $org && $org != *CHANGE-ME* ]] || die "Set ORG in /etc/agentbox/lab.conf first."
  install -m 755 "$kit/settings/lab-settings-apply" /usr/local/sbin/lab-settings-apply
  [[ -f /etc/agentbox/settings-max.conf ]] || install -m 644 "$kit/settings/settings-max.conf.example" /etc/agentbox/settings-max.conf
  install -m 644 "$kit/settings/lab-settings.service" "$kit/settings/lab-settings.timer" /etc/systemd/system/
  echo "$org/lab $settings" > /etc/agentbox/settings-issue; chmod 644 /etc/agentbox/settings-issue
  install -d -m 755 /var/lib/lab-settings
  if [[ ! -s /etc/agentbox/settings-gh-token ]]; then
    echo "Paste a read-only GitHub token (fine-grained: resource owner $org, repository 'lab' only, permission"
    echo "Issues: Read-only), made from YOUR account, not the bot's. Nothing is shown; press Enter when done."
    read -rs tok; echo
    [[ -n $tok ]] || die "No token given; run again with --settings when you have one."
    (umask 077; printf '%s\n' "$tok" > /etc/agentbox/settings-gh-token); unset tok
  fi
  chmod 600 /etc/agentbox/settings-gh-token; chown root:root /etc/agentbox/settings-gh-token
  /usr/local/sbin/lab-settings-apply && echo "First check OK (read $org/lab#$settings)."
  systemctl daemon-reload && systemctl enable --now lab-settings.timer
  echo "Review the keys and hard maxima in /etc/agentbox/settings-max.conf (sudo nano)."
fi

step "Done"
cat <<EOF
Installed. Next (SETUP.md, step 5 on):
  1. sudo nano /etc/agentbox/lab.conf     (ORG, PI_GITHUB, NTFY_URL at least)
  2. sudo -iu hpc   then: bash $share/user-setup.sh [--hpc]   (and log in to claude and codex)
$( [[ $second == yes ]] && echo "  3. sudo -iu agent then: bash $share/user-setup.sh" )
  4. as hpc: lab init && lab up
Your login ($pi) is in group agents; log out and in again for that to apply.
EOF
