#!/usr/bin/env bash
# Per-account setup, run once as each agent account:
#   bash /usr/local/share/agentbox/user-setup.sh             # as agent
#   bash /usr/local/share/agentbox/user-setup.sh --hpc   # as hpc: also the HPC connection
#   bash /usr/local/share/agentbox/user-setup.sh --codex-api   # only: log this account's Codex in to the OpenAI
#                                                             # API in ~/.codex-api (CODEX_API, lab spawn --api)
# Installs Claude Code, Codex and uv, a Python environment with common scientific packages, Claude
# hooks that report each session's state, the lab rules for every agent, and the GitHub login
# (it asks for the agents' GitHub token).
set -euo pipefail

share=/usr/local/share/agentbox
with_hpc=false
[[ ${1:-} == --hpc ]] && with_hpc=true
export PATH="$HOME/.local/bin:$PATH"

if [[ ${1:-} == --codex-api ]]; then
  # A second Codex home for API runs: the plan's login stays in ~/.codex, the API key's in ~/.codex-api.
  # lib.sh uses it for runs marked LAB_CODEX_API (overflow, or lab spawn --api) while the lab's budget lasts.
  install -d -m 700 ~/.codex-api
  [[ -f ~/.codex-api/config.toml ]] || cp ~/.codex/config.toml ~/.codex-api/config.toml 2> /dev/null ||
    cp "$share/config/codex-config.toml" ~/.codex-api/config.toml
  ln -sf /srv/lab/LAB-RULES.md ~/.codex-api/AGENTS.md
  read -rsp "Paste the OpenAI API key for the lab (it won't be shown): " key
  echo
  printf '%s' "$key" | CODEX_HOME=~/.codex-api codex login --with-api-key; unset key
  CODEX_HOME=~/.codex-api codex login status
  echo "Now set CODEX_API_BUDGET_USD in lab.conf (sudo) and fill in /srv/lab/codex-api-prices.tsv."
  exit 0
fi

echo "== Claude Code"
curl -fsSL https://claude.ai/install.sh | bash

echo "== Codex"
curl -fsSL https://chatgpt.com/codex/install.sh | sh

echo "== uv and a Python environment (~/.venvs/sci)"
curl -LsSf https://astral.sh/uv/install.sh | sh
[[ -d ~/.venvs/sci ]] || uv venv ~/.venvs/sci
uv pip install --python ~/.venvs/sci numpy scipy sympy mpmath matplotlib pandas

echo "== Claude settings: Remote Control for every session, status hooks"
mkdir -p ~/.claude
if [[ -f ~/.claude/settings.json ]]; then
  jq -s '.[0] * .[1]' ~/.claude/settings.json "$share/config/claude-settings.json" > ~/.claude/settings.json.new
  mv ~/.claude/settings.json.new ~/.claude/settings.json
else
  cp "$share/config/claude-settings.json" ~/.claude/settings.json
fi

echo "== Codex settings (for sessions you start yourself; the lab's agents pass their own)"
mkdir -p ~/.codex
[[ -f ~/.codex/config.toml ]] || cp "$share/config/codex-config.toml" ~/.codex/config.toml

echo "== The lab rules, read by every Claude and Codex session on this account"
ln -sf /srv/lab/LAB-RULES.md ~/.codex/AGENTS.md
[[ -f ~/.claude/CLAUDE.md ]] || printf '@/srv/lab/LAB-RULES.md\n' > ~/.claude/CLAUDE.md

echo "== GitHub, as the agents' account"
if ! gh auth status > /dev/null 2>&1; then
  read -rsp "Paste the agents' GitHub token (it won't be shown): " token
  echo
  printf '%s\n' "$token" | gh auth login --with-token
fi
gh auth setup-git
login=$(gh api user --jq .login)
git config --global user.name "$login"
git config --global user.email "$(gh api user --jq .id)+$login@users.noreply.github.com"

mkdir -p ~/work

if $with_hpc; then
  echo "== HPC ssh settings"
  mkdir -p ~/.ssh && touch ~/.ssh/config && chmod 600 ~/.ssh/config
  source "$share/lib.sh"   # reads HPC_LOGIN_HOST and HPC_USER from lab.conf
  [[ -n ${HPC_LOGIN_HOST:-} && -n ${HPC_USER:-} ]] || { echo "Set HPC_LOGIN_HOST and HPC_USER in $LAB_CONF first." >&2; exit 1; }
  grep -q cm-cluster.sock ~/.ssh/config || sed -e "s/CLUSTER_LOGIN_HOST/$HPC_LOGIN_HOST/; s/CLUSTER_USER/$HPC_USER/" \
    "$share/config/hpc-ssh-config" >> ~/.ssh/config
fi

echo
echo "Installed: $(claude --version 2>/dev/null || echo 'claude: not found'), $(codex --version 2>/dev/null || echo 'codex: not on PATH yet')"
echo "Next: log out and back in (so the new PATH applies), then continue with SETUP.md."
