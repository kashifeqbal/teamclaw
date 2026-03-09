#!/bin/bash
set -uo pipefail
# Trap errors with context
trap 'fail "Script failed at line $LINENO (exit code $?). Last command: $BASH_COMMAND"' ERR

# ═══════════════════════════════════════════════════════════════
# TeamClaw Setup — OpenClaw for Teams (v0.2)
# ═══════════════════════════════════════════════════════════════
#
# Usage:
#   bash setup-org.sh                     # interactive
#   bash setup-org.sh --config team.env   # non-interactive
#
# Prerequisites:
#   - Fresh Ubuntu 22.04/24.04 VPS (root access)
#   - Claude subscription (for openclaw models auth add)
#
# Runs everything as root — no dedicated user needed.

# ─── Helpers ───
log()  { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok()   { echo -e "  \033[1;32m✅ $*\033[0m"; }
warn() { echo -e "  \033[1;33m⚠️  $*\033[0m"; }
skip() { echo -e "  \033[0;90m⏭  $*\033[0m"; }
fail() { echo -e "  \033[1;31m❌ $*\033[0m"; }

echo ""
echo "🦞 TeamClaw Setup v0.2"
echo "═══════════════════════════════════════════"
echo ""

# ─── Sanity ───
[ "$(id -u)" = "0" ] || { echo "Run as root"; exit 1; }
[ -f /etc/os-release ] && . /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || warn "Tested on Ubuntu 22.04/24.04 — proceed with caution"

# ═══════════════════════════════════════════════════════════════
# CONFIG — load from file or prompt interactively
# ═══════════════════════════════════════════════════════════════

CONFIG_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
  echo "Loading config from: $CONFIG_FILE"
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  # Prompt for values not set in config file (secrets & toggles)
  echo ""
  echo "── Review & Complete ──"
  echo "  Agent:  ${AGENT_NAME:-} ${AGENT_EMOJI:-}"
  echo "  Org:    ${ORG_NAME:-}"
  echo ""

  if [ -z "${OPENAI_KEY:-}" ]; then
    read -rp "  OpenAI API key (for memory/embeddings, blank to skip): " OPENAI_KEY
  fi
  if [ -z "${BRAVE_KEY:-}" ]; then
    read -rp "  Brave Search API key (blank to skip): " BRAVE_KEY
  fi

  echo ""
  echo "── Infrastructure ──"
  if [ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
    read -rp "  Cloudflare Tunnel token (blank to skip): " CLOUDFLARE_TUNNEL_TOKEN
  else
    echo "  Cloudflare Tunnel: ✅ (from config)"
  fi

  # Confirm opt-in features
  if [[ "${INSTALL_WATCHCLAW:-n}" == "y" ]]; then
    echo "  WatchClaw: ✅ (from config)"
    if [ -z "${WATCHCLAW_TELEGRAM_TOKEN:-}" ]; then
      read -rp "  WatchClaw Telegram bot token (blank to skip alerts): " WATCHCLAW_TELEGRAM_TOKEN
      read -rp "  WatchClaw Telegram chat ID (e.g. -1001234567890): " WATCHCLAW_CHAT_ID
    fi
  else
    read -rp "  Install WatchClaw security? [y/N]: " INSTALL_WATCHCLAW
    if [[ "${INSTALL_WATCHCLAW,,}" == "y" ]]; then
      read -rp "  WatchClaw Telegram bot token (blank to skip alerts): " WATCHCLAW_TELEGRAM_TOKEN
      read -rp "  WatchClaw Telegram chat ID (e.g. -1001234567890): " WATCHCLAW_CHAT_ID
    fi
  fi

  if [[ "${INSTALL_HINDSIGHT:-n}" == "y" ]]; then
    echo "  Hindsight: ✅ (from config)"
  else
    read -rp "  Install Hindsight memory? [y/N]: " INSTALL_HINDSIGHT
  fi

  echo ""
else
  echo "── Agent Configuration ──"
  read -rp "  Agent name (e.g. Pulse): " AGENT_NAME
  read -rp "  Agent emoji (e.g. 💚): " AGENT_EMOJI
  read -rp "  Organization name (e.g. TapHealth): " ORG_NAME
  read -rp "  Product description (one line): " PRODUCT_DESC
  read -rp "  Team timezone (e.g. Asia/Kolkata): " TEAM_TZ

  echo ""
  echo "── GitHub Configuration ──"
  read -rp "  GitHub org/user (blank to skip): " GH_ORG
  if [ -n "${GH_ORG:-}" ]; then
    read -rp "  GitHub profile name (e.g. taphealth): " GH_PROFILE
    read -rp "  GitHub PAT (fine-grained, blank to skip): " GH_TOKEN
  fi

  echo ""
  echo "── Optional Features ──"
  read -rp "  Install Docker? [y/N]: " OPT_DOCKER
  read -rp "  OpenAI API key (for memory search, blank to skip): " OPENAI_KEY
  read -rp "  Brave Search API key (blank to skip): " BRAVE_KEY

  echo ""
  echo "── Infrastructure ──"
  read -rp "  Cloudflare Tunnel token (blank to skip): " CLOUDFLARE_TUNNEL_TOKEN
  read -rp "  Install WatchClaw security? [y/N]: " INSTALL_WATCHCLAW
  if [[ "${INSTALL_WATCHCLAW,,}" == "y" ]]; then
    read -rp "  WatchClaw Telegram bot token (blank to skip alerts): " WATCHCLAW_TELEGRAM_TOKEN
    read -rp "  WatchClaw Telegram chat ID (e.g. -1001234567890): " WATCHCLAW_CHAT_ID
  fi
  read -rp "  Install Hindsight memory? [y/N]: " INSTALL_HINDSIGHT
fi

# Derive agent ID
AGENT_ID=$(echo "${AGENT_NAME}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
GH_PROFILE=${GH_PROFILE:-${GH_ORG:-}}
GH_TOKEN=${GH_TOKEN:-}
OPT_DOCKER=${OPT_DOCKER:-n}
OPENAI_KEY=${OPENAI_KEY:-}
BRAVE_KEY=${BRAVE_KEY:-}
CLOUDFLARE_TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN:-}
INSTALL_WATCHCLAW=${INSTALL_WATCHCLAW:-n}
WATCHCLAW_TELEGRAM_TOKEN=${WATCHCLAW_TELEGRAM_TOKEN:-}
WATCHCLAW_CHAT_ID=${WATCHCLAW_CHAT_ID:-}
INSTALL_HINDSIGHT=${INSTALL_HINDSIGHT:-n}

# ─── Calculate total steps ───
TOTAL_STEPS=13
[[ -n "${CLOUDFLARE_TUNNEL_TOKEN}" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "${INSTALL_WATCHCLAW,,}" == "y" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "${INSTALL_HINDSIGHT,,}" == "y" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
STEP=0
next_step() { STEP=$((STEP + 1)); }

# Paths
OC_HOME="/root"

echo ""
echo "  Agent:    ${AGENT_NAME} ${AGENT_EMOJI:-}"
echo "  Org:      ${ORG_NAME}"
echo "  User:     root"
echo "  Home:     /root"
echo ""

SETUP_START=$(date +%s)

# ═══════════════════════════════════════════════════════════════
# PHASE 1: System Foundation (as root)
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] System packages..."
export DEBIAN_FRONTEND=noninteractive

# Fix interrupted dpkg and wait for apt lock (common after VPS nuke/reimage)
dpkg --configure -a 2>/dev/null || true
# Wait for unattended-upgrades / other apt to finish (up to 120s)
for i in $(seq 1 12); do
  if fuser /var/lib/dpkg/lock-frontend &>/dev/null; then
    warn "Waiting for apt lock... ($((i*10))s)"
    sleep 10
  else
    break
  fi
done
apt-get update -qq 2>/dev/null || apt-get update -qq

apt-get install -y -qq \
  curl git vim jq tree unzip \
  python3 python3-pip python3-venv \
  sqlite3 stow tmux htop fzf zsh \
  ca-certificates gnupg \
  openssh-client openssh-server \
  build-essential \
  ufw fail2ban 2>&1 | tail -5
ok "System packages"

next_step; log "[$STEP/$TOTAL_STEPS] Node.js 22..."
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>/dev/null
  apt-get install -y -qq nodejs 2>/dev/null
fi
ok "Node $(node --version)"

next_step; log "[$STEP/$TOTAL_STEPS] npm globals (OpenClaw, mcporter, clawhub, gh, cloudflared)..."

npm install -g openclaw@latest 2>/dev/null
ok "OpenClaw $(openclaw --version 2>/dev/null || echo 'installed')"
npm install -g mcporter@latest 2>/dev/null
ok "mcporter"
npm install -g clawhub@latest 2>/dev/null
ok "clawhub"

# GitHub CLI
if ! command -v gh &>/dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
    https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq 2>/dev/null && apt-get install -y -qq gh 2>/dev/null
fi
ok "GitHub CLI"

# cloudflared
if ! command -v cloudflared &>/dev/null; then
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
    -o /tmp/cloudflared.deb
  dpkg -i /tmp/cloudflared.deb 2>/dev/null && rm -f /tmp/cloudflared.deb
fi
ok "cloudflared"

# oh-my-posh (prompt theme)
if ! command -v oh-my-posh &>/dev/null; then
  curl -s https://ohmyposh.dev/install.sh | bash -s 2>/dev/null
  cp /root/.local/bin/oh-my-posh /usr/local/bin/ 2>/dev/null
  chmod 755 /usr/local/bin/oh-my-posh 2>/dev/null
  mkdir -p /usr/local/share/oh-my-posh/themes
  cp /root/.cache/oh-my-posh/themes/* /usr/local/share/oh-my-posh/themes/ 2>/dev/null || true
fi
ok "oh-my-posh"

# Docker (optional)
if [[ "${OPT_DOCKER,,}" == "y" ]]; then
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh 2>/dev/null
  fi
  ok "Docker"
else
  skip "Docker skipped"
fi



# ═══════════════════════════════════════════════════════════════
# PHASE 3: Dotfiles
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Dotfiles (server-dotfiles)..."
DOTFILES_DIR="/root/dotfiles"

if [ ! -d "${DOTFILES_DIR}/.git" ]; then
  git clone https://github.com/kashifeqbal/server-dotfiles.git "${DOTFILES_DIR}" 2>/dev/null
fi

if [ -d "${DOTFILES_DIR}" ]; then
  # Remove conflicting defaults
  rm -f "/root/.zshrc" "/root/.zshenv" "/root/.gitconfig" "/root/.vimrc" 2>/dev/null

  cd "${DOTFILES_DIR}"
  # stow from repo root — ignore .git via .stow-local-ignore
  echo '\.git' > "${DOTFILES_DIR}/.stow-local-ignore" 2>/dev/null || true
  stow --target="/root" --restow --ignore='\.git' . 2>/dev/null || {
    # Fallback: manual symlink
    for f in .zshrc .zimrc .zshenv .exports .aliases .gitconfig .vimrc .curlrc .wgetrc .stow-global-ignore; do
      [ -f "${DOTFILES_DIR}/$f" ] && ln -sf "${DOTFILES_DIR}/$f" "/root/$f"
    done
    for d in .config .vim; do
      if [ -d "${DOTFILES_DIR}/$d" ]; then
        cp -r "${DOTFILES_DIR}/$d" "/root/"
      fi
    done
  }
  ok "Dotfiles stowed"

  # Ensure oh-my-posh theme is in place (only if stow didn't already link it)
  if [ ! -f "/root/.config/oh-my-posh/zen.omp.json" ]; then
    mkdir -p "/root/.config/oh-my-posh"
    if [ -f "${DOTFILES_DIR}/.config/oh-my-posh/zen.omp.json" ]; then
      ln -sf "${DOTFILES_DIR}/.config/oh-my-posh/zen.omp.json" "/root/.config/oh-my-posh/"
    elif [ -f /usr/local/share/oh-my-posh/themes/zen.omp.json ]; then
      cp /usr/local/share/oh-my-posh/themes/zen.omp.json "/root/.config/oh-my-posh/"
    fi
  fi

  # Install Zim framework
  if [ ! -d "/root/.zim" ]; then
    bash -c 'curl -fsSL https://raw.githubusercontent.com/zimfw/install/master/install.zsh | ZIM_HOME=~/.zim zsh' 2>/dev/null || true
    ok "Zim framework installed"
  fi
else
  warn "Could not clone server-dotfiles"
fi

# Set git identity for this org
git config --global user.name "${ORG_NAME} Bot"
git config --global user.email "bot@${ORG_NAME,,}.com"

# ═══════════════════════════════════════════════════════════════
# PHASE 4: Security Hardening (as root)
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Security hardening..."

# SSH hardening
if ! grep -q "TeamClaw hardening" /etc/ssh/sshd_config 2>/dev/null; then
  cat >> /etc/ssh/sshd_config << 'SSHEOF'

# ─── TeamClaw hardening ─────────────────────────────────────────
MaxAuthTries 3
LoginGraceTime 20
MaxStartups 5:50:10
MaxSessions 5
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding no
PasswordAuthentication no
PermitRootLogin prohibit-password
SSHEOF

  # If cloudflared tunnel is set up, bind SSH to localhost only
  if [ -n "${CLOUDFLARE_TUNNEL_TOKEN}" ]; then
    if ! grep -q "^ListenAddress 127.0.0.1" /etc/ssh/sshd_config 2>/dev/null; then
      cat >> /etc/ssh/sshd_config << 'SSHLISTENEOF'

# ─── TeamClaw: tunnel-only SSH (localhost bind) ────────────────
ListenAddress 127.0.0.1
ListenAddress ::1
SSHLISTENEOF
      ok "SSH bound to localhost (tunnel-only access)"
    fi
  fi
  if /usr/sbin/sshd -t 2>/dev/null; then
    ok "SSH hardened (key-only, rate-limited) — restart deferred to end"
  else
    fail "SSH config test failed — check /etc/ssh/sshd_config"
  fi
else
  skip "SSH already hardened"
fi

# Kernel hardening
if [ ! -f /etc/sysctl.d/99-teamclaw-hardening.conf ]; then
  cat > /etc/sysctl.d/99-teamclaw-hardening.conf << 'SYSEOF'
# ─── TeamClaw Kernel Hardening ───────────────────────────────
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
kernel.sysrq = 0
kernel.core_uses_pid = 1
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
SYSEOF
  sysctl --system 2>/dev/null | tail -1
  ok "Kernel hardened (29 sysctl settings)"
else
  skip "Kernel hardening already applied"
fi

# UFW
ufw --force reset 2>/dev/null
ufw default deny incoming 2>/dev/null
ufw default allow outgoing 2>/dev/null
if [ -n "${CLOUDFLARE_TUNNEL_TOKEN}" ]; then
  # Tunnel handles SSH — only allow loopback
  ufw allow from 127.0.0.1 to any port 22 proto tcp comment 'SSH loopback (tunnel)' 2>/dev/null
  ufw allow from ::1 to any port 22 proto tcp comment 'SSH loopback v6 (tunnel)' 2>/dev/null
  ok "UFW: SSH loopback-only (tunnel mode)"
else
  # No tunnel — allow SSH externally
  ufw allow ssh comment 'SSH' 2>/dev/null
  ok "UFW: SSH open (no tunnel)"
fi
ufw --force enable 2>/dev/null
ok "UFW active"

# fail2ban
cat > /etc/fail2ban/jail.local << 'F2BEOF'
[DEFAULT]
bantime  = -1
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
maxretry = 3
findtime = 600
F2BEOF
systemctl enable --now fail2ban 2>/dev/null
ok "fail2ban active"

# ═══════════════════════════════════════════════════════════════
# PHASE 5: GitHub Configuration
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] GitHub configuration..."
if [ -n "${GH_ORG:-}" ]; then
  GH_DIR="/root/.config/gh-${GH_PROFILE}"
  mkdir -p "${GH_DIR}"

  # SSH config
  mkdir -p "/root/.ssh"
  chmod 700 "/root/.ssh"

  SSH_CONFIG="/root/.ssh/config"
  if ! grep -q "Host github-${GH_PROFILE}" "${SSH_CONFIG}" 2>/dev/null; then
    cat >> "${SSH_CONFIG}" << SSHCFG

# ─── ${ORG_NAME} GitHub ───
Host github-${GH_PROFILE}
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519_github_${GH_PROFILE}
  IdentitiesOnly yes
SSHCFG
    chmod 600 "${SSH_CONFIG}"
  fi

  # Add gh alias
  ALIAS_LINE="alias gh-${GH_PROFILE}='GH_CONFIG_DIR=${GH_DIR} gh'"
  ALIASES_FILE="/root/.aliases"
  if ! grep -q "gh-${GH_PROFILE}" "${ALIASES_FILE}" 2>/dev/null; then
    echo "" >> "${ALIASES_FILE}"
    echo "# ${ORG_NAME} GitHub" >> "${ALIASES_FILE}"
    echo "${ALIAS_LINE}" >> "${ALIASES_FILE}"
  fi

  ok "GitHub profile: gh-${GH_PROFILE} → ${GH_ORG}"

  # Auto-authenticate if GH_TOKEN is provided
  if [ -n "${GH_TOKEN:-}" ]; then
    echo "${GH_TOKEN}" | GH_CONFIG_DIR="${GH_DIR}" gh auth login --with-token 2>/dev/null && \
      ok "GitHub authenticated via token" || warn "GitHub token auth failed — authenticate manually"
  else
    echo "    Key: ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_github_${GH_PROFILE} -C '${GH_ORG}'"
    echo "    Auth: GH_CONFIG_DIR=${GH_DIR} gh auth login"
  fi
else
  skip "GitHub skipped"
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 6: OpenClaw Workspace
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Creating workspace & agent..."
OC_STATE="/root/.openclaw"
OC_WORKSPACE="/opt/teamclaw/workspace"

mkdir -p /opt/teamclaw/{workspace,config}
mkdir -p "${OC_WORKSPACE}"/{team,product,engineering,scripts,memory}
mkdir -p "${OC_STATE}"/{agents/${AGENT_ID}/sessions,cron,credentials,memory}

ln -sfn "${OC_WORKSPACE}" "${OC_STATE}/workspace"

# SOUL.md
cat > "${OC_WORKSPACE}/SOUL.md" << SOUL
# SOUL.md — ${AGENT_NAME}

You are **${AGENT_NAME}**, the AI team member for ${ORG_NAME}.

## Who You Are
- Product-aware, dev-fluent, data-driven
- You work alongside the team — not above them
- Short, direct answers. No fluff.

## What You Do
- **Product:** Feature specs, backlog management, sprint tracking
- **Engineering:** PR reviews, CI status, standup reports, code context
- **Data:** Metrics, funnel analysis, user behavior insights
- **Planning:** Sprint summaries, release notes, weekly digests

## How You Talk
- Direct and concise — like a senior team member in Slack
- Use data to back opinions
- Flag blockers and risks proactively

## Boundaries
- Don't make decisions — inform and recommend
- Ask before creating issues or sending external communications
- Private data stays private
SOUL

# AGENTS.md
cat > "${OC_WORKSPACE}/AGENTS.md" << 'AGENTS'
# AGENTS.md

## Every Session
1. Read `SOUL.md` — who you are
2. Read `USER.md` — who you're helping
3. Read `memory/` recent files for context

## Memory
- Daily notes: `memory/YYYY-MM-DD.md`
- Files > mental notes

## Safety
- Don't exfiltrate data
- Ask before destructive actions
AGENTS

cat > "${OC_WORKSPACE}/USER.md" << USER
# USER.md — ${ORG_NAME} Team

## Organization
- **Company:** ${ORG_NAME}
- **Product:** ${PRODUCT_DESC}

## Team
_(Add team members here)_

## Timezone
- ${TEAM_TZ}
USER

cat > "${OC_WORKSPACE}/TOOLS.md" << TOOLS
# TOOLS.md

## GitHub
- Org: ${GH_ORG:-"(not configured)"}
- Profile: gh-${GH_PROFILE:-"default"}
TOOLS

cat > "${OC_WORKSPACE}/IDENTITY.md" << IDENTITY
# IDENTITY.md
- **Name:** ${AGENT_NAME}
- **Emoji:** ${AGENT_EMOJI:-"🦞"}
- **Vibe:** Direct, data-driven, product-aware
IDENTITY

cat > "${OC_WORKSPACE}/HEARTBEAT.md" << 'HB'
# HEARTBEAT.md
# Add periodic checks here.
HB

# Fix ownership

ok "${AGENT_NAME} workspace created"

# ═══════════════════════════════════════════════════════════════
# PHASE 7: OpenClaw Config
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Generating openclaw.json..."

GATEWAY_TOKEN=$(openssl rand -hex 24)

# .env
ENV_FILE="${OC_STATE}/.env"
: > "$ENV_FILE"
[ -n "${OPENAI_KEY:-}" ] && echo "OPENAI_API_KEY=${OPENAI_KEY}" >> "$ENV_FILE"
[ -n "${BRAVE_KEY:-}" ] && echo "BRAVE_SEARCH_KEY=${BRAVE_KEY}" >> "$ENV_FILE"
chmod 600 "$ENV_FILE"

cat > "${OC_STATE}/openclaw.json" << OCJSON
{
  "gateway": {
    "auth": {
      "token": "${GATEWAY_TOKEN}"
    },
    "bind": "loopback",
    "port": 18789,
    "mode": "local"
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-sonnet-4-6",
        "fallbacks": ["anthropic/claude-sonnet-4-6"]
      },
      "memorySearch": {
        "enabled": true,
        "sources": ["memory", "sessions"],
        "experimental": { "sessionMemory": true },
        "query": {
          "maxResults": 8,
          "minScore": 0.3,
          "hybrid": {
            "enabled": true,
            "vectorWeight": 0.6,
            "textWeight": 0.4,
            "temporalDecay": { "enabled": true, "halfLifeDays": 14 }
          }
        },
        "sync": { "onSessionStart": true, "onSearch": true, "watch": true }
      }
    },
    "list": [
      {
        "id": "${AGENT_ID}",
        "name": "${AGENT_NAME}",
        "workspace": "${OC_WORKSPACE}",
        "model": { "primary": "anthropic/claude-sonnet-4-6" },
        "tools": { "fs": { "workspaceOnly": false } }
      }
    ]
  }
}
OCJSON
chmod 700 "${OC_STATE}" "${OC_STATE}/credentials" 2>/dev/null || true

# Validate
if HOME="/root" openclaw config validate 2>&1 | grep -q "valid"; then
  ok "openclaw.json valid"
else
  warn "Config validation issue — run: openclaw config validate"
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 8: Studio
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Installing OpenClaw Studio..."
if [ ! -d /opt/openclaw-studio ]; then
  git clone --depth 1 https://github.com/grp06/openclaw-studio.git /opt/openclaw-studio 2>/dev/null
  cd /opt/openclaw-studio

  # Fix Next.js Suspense bug
  if grep -q "useSearchParams" src/app/page.tsx 2>/dev/null; then
    python3 << 'PATCHEOF'
import re
with open('src/app/page.tsx', 'r') as f:
    content = f.read()
if 'Suspense' not in content:
    content = content.replace("import { useCallback", "import { Suspense, useCallback")
if 'export default' in content and 'Suspense' not in content.split('export default')[-1]:
    content = re.sub(r'export default function Home\(\)', 'function HomeInner()', content)
    content += '\nexport default function Home() {\n  return (\n    <Suspense fallback={null}>\n      <HomeInner />\n    </Suspense>\n  );\n}\n'
with open('src/app/page.tsx', 'w') as f:
    f.write(content)
print('Patched page.tsx')
PATCHEOF
  fi

  npm install 2>/dev/null
  if npm run build 2>/dev/null; then
    ok "Studio built (production mode)"
  else
    warn "Studio build failed"
  fi
else
  skip "Studio already installed"
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 9: Systemd Services
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Installing systemd services..."


# Gateway service (system-level, running as root)
cat > /etc/systemd/system/openclaw-gateway.service << SVC
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
User=root
ExecStart=$(which openclaw) gateway run
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=HOME=/root

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable openclaw-gateway 2>/dev/null || true
ok "Gateway service (system, auto-start: enabled)"

# Studio service (system-level)
cat > /etc/systemd/system/openclaw-studio.service << 'SVC'
[Unit]
Description=OpenClaw Studio Dashboard
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/openclaw-studio
ExecStart=/usr/bin/npx next start --port 3000 --hostname 127.0.0.1
Environment=HOST=127.0.0.1
Environment=PORT=3000
Environment=NODE_ENV=production
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable openclaw-studio 2>/dev/null || true
ok "Studio service (port 3000)"

# ═══════════════════════════════════════════════════════════════
# PHASE 10: Healthcheck
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Setting up healthcheck..."

cat > "${OC_WORKSPACE}/scripts/healthcheck.sh" << HCEOF
#!/bin/bash
# TeamClaw Healthcheck
ERRORS=0

# Gateway
if ! systemctl is-active openclaw-gateway &>/dev/null; then
  echo "❌ Gateway down — restarting..."
  systemctl restart openclaw-gateway
  ERRORS=\$((ERRORS + 1))
fi

# Studio
if ! systemctl is-active openclaw-studio &>/dev/null; then
  echo "❌ Studio down — restarting..."
  systemctl restart openclaw-studio
  ERRORS=\$((ERRORS + 1))
fi

# Disk
DISK_PCT=\$(df / | awk 'NR==2 {print \$5}' | tr -d '%')
[ "\$DISK_PCT" -gt 85 ] && echo "⚠️ Disk: \${DISK_PCT}%" && ERRORS=\$((ERRORS + 1))

# Memory
MEM_PCT=\$(free | awk '/Mem:/ {printf "%.0f", \$3/\$2 * 100}')
[ "\$MEM_PCT" -gt 90 ] && echo "⚠️ Memory: \${MEM_PCT}%" && ERRORS=\$((ERRORS + 1))

[ "\$ERRORS" -eq 0 ] && echo "✅ Healthy (\$(date +%H:%M))"
HCEOF
chmod +x "${OC_WORKSPACE}/scripts/healthcheck.sh"

# Install cron (handle empty crontab gracefully)
CRON_LINE="*/10 * * * * ${OC_WORKSPACE}/scripts/healthcheck.sh >> /var/log/teamclaw-healthcheck.log 2>&1"
( crontab -l 2>/dev/null || true; echo "$CRON_LINE" ) | sort -u | crontab -
ok "Healthcheck cron (every 10 min)"

# ═══════════════════════════════════════════════════════════════
# PHASE 11: Cloudflare Tunnel (optional — MUST come before WatchClaw)
# ═══════════════════════════════════════════════════════════════

if [ -n "${CLOUDFLARE_TUNNEL_TOKEN}" ]; then
  next_step; log "[$STEP/$TOTAL_STEPS] Cloudflare tunnel..."

  # Install tunnel service
  cloudflared service install "${CLOUDFLARE_TUNNEL_TOKEN}" 2>/dev/null || true

  # Start it
  systemctl enable cloudflared 2>/dev/null || true
  systemctl start cloudflared 2>/dev/null || true

  # Verify
  sleep 3
  if systemctl is-active cloudflared &>/dev/null; then
    ok "Cloudflare tunnel active"
  else
    warn "Tunnel service not active — check: journalctl -u cloudflared"
  fi
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 12: Hindsight PageIndex (optional — session memory)
# ═══════════════════════════════════════════════════════════════

if [[ "${INSTALL_HINDSIGHT,,}" == "y" ]]; then
  next_step; log "[$STEP/$TOTAL_STEPS] Hindsight PageIndex..."

  HINDSIGHT_DIR="/opt/hindsight-pageindex"
  HINDSIGHT_TOKEN=$(openssl rand -hex 24)

  mkdir -p "${HINDSIGHT_DIR}"

  # Create server.mjs (minimal PageIndex HTTP wrapper)
  if [ ! -f "${HINDSIGHT_DIR}/server.mjs" ]; then
    # Clone PageIndex vendor
    mkdir -p "${HINDSIGHT_DIR}/vendor"
    if [ ! -d "${HINDSIGHT_DIR}/vendor/PageIndex/.git" ]; then
      git clone --depth=1 https://github.com/VectifyAI/PageIndex.git "${HINDSIGHT_DIR}/vendor/PageIndex" 2>/dev/null
    fi

    # Setup Python venv
    python3 -m venv "${HINDSIGHT_DIR}/.venv"
    "${HINDSIGHT_DIR}/.venv/bin/pip" install --upgrade pip -q 2>/dev/null
    "${HINDSIGHT_DIR}/.venv/bin/pip" install -r "${HINDSIGHT_DIR}/vendor/PageIndex/requirements.txt" -q 2>/dev/null

    # Create package.json
    cat > "${HINDSIGHT_DIR}/package.json" << 'PKGJSON'
{
  "name": "hindsight-pageindex",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "start": "node server.mjs",
    "ingest:workspace": "node scripts/ingest-workspace.mjs"
  },
  "dependencies": {}
}
PKGJSON

    # Create server.mjs
    cat > "${HINDSIGHT_DIR}/server.mjs" << 'SERVERMJS'
import http from "http";
import { spawn } from "child_process";
import { readFileSync, existsSync, mkdirSync, writeFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = parseInt(process.env.PORT || "8787");
const API_TOKEN = process.env.API_TOKEN || "";
const PI_HOME = process.env.PAGEINDEX_HOME || join(__dirname, "vendor/PageIndex");
const PI_PYTHON = process.env.PAGEINDEX_PYTHON || join(__dirname, ".venv/bin/python3");
const DATA_DIR = join(__dirname, "data");
mkdirSync(DATA_DIR, { recursive: true });

function auth(req) {
  if (!API_TOKEN) return true;
  const h = req.headers.authorization || "";
  return h === `Bearer ${API_TOKEN}`;
}

function body(req) {
  return new Promise((ok) => {
    let d = "";
    req.on("data", (c) => (d += c));
    req.on("end", () => ok(d));
  });
}

function runPython(script, args = []) {
  return new Promise((resolve, reject) => {
    const p = spawn(PI_PYTHON, [join(PI_HOME, script), ...args], {
      cwd: PI_HOME, env: { ...process.env, PYTHONPATH: PI_HOME },
    });
    let out = "", err = "";
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (err += d));
    p.on("close", (code) => code === 0 ? resolve(out) : reject(new Error(err || `exit ${code}`)));
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const json = (code, data) => {
    res.writeHead(code, { "Content-Type": "application/json" });
    res.end(JSON.stringify(data));
  };

  if (url.pathname === "/health") return json(200, { status: "ok", docs: 0 });

  if (!auth(req)) return json(401, { error: "unauthorized" });

  if (url.pathname === "/api/index" && req.method === "POST") {
    try {
      const { content, metadata } = JSON.parse(await body(req));
      const id = metadata?.id || `doc-${Date.now()}`;
      const docPath = join(DATA_DIR, `${id}.json`);
      writeFileSync(docPath, JSON.stringify({ content, metadata, indexed: new Date().toISOString() }));
      return json(200, { status: "indexed", id });
    } catch (e) { return json(500, { error: e.message }); }
  }

  if (url.pathname === "/api/query" && req.method === "POST") {
    try {
      const { query } = JSON.parse(await body(req));
      // Simple text search across indexed docs
      const results = [];
      const { readdirSync } = await import("fs");
      for (const f of readdirSync(DATA_DIR)) {
        if (!f.endsWith(".json")) continue;
        const doc = JSON.parse(readFileSync(join(DATA_DIR, f), "utf8"));
        if (doc.content && doc.content.toLowerCase().includes(query.toLowerCase())) {
          results.push({ id: f.replace(".json", ""), score: 1, snippet: doc.content.slice(0, 300), metadata: doc.metadata });
        }
      }
      return json(200, { results: results.slice(0, 10) });
    } catch (e) { return json(500, { error: e.message }); }
  }

  json(404, { error: "not found" });
});

server.listen(PORT, "127.0.0.1", () => console.log(`Hindsight PageIndex on :${PORT}`));
SERVERMJS

    ok "Hindsight server created"
  fi

  # Create .env
  cat > "${HINDSIGHT_DIR}/.env" << HENV
PORT=8787
API_TOKEN=${HINDSIGHT_TOKEN}
DEFAULT_USER_ID=${AGENT_ID}
DEFAULT_NAMESPACE=teamclaw-${ORG_NAME,,}
PAGEINDEX_HOME=./vendor/PageIndex
PAGEINDEX_PYTHON=.venv/bin/python3
OPENAI_API_KEY=${OPENAI_KEY}
PAGEINDEX_MODEL=gpt-4o-2024-11-20
HENV

  # systemd service
  cat > /etc/systemd/system/hindsight-pageindex.service << HSVC
[Unit]
Description=Hindsight Local PageIndex Runtime
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${HINDSIGHT_DIR}
EnvironmentFile=${HINDSIGHT_DIR}/.env
ExecStart=/usr/bin/node ${HINDSIGHT_DIR}/server.mjs
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
HSVC

  systemctl daemon-reload
  systemctl enable hindsight-pageindex 2>/dev/null || true
  ok "Hindsight PageIndex (port 8787, token: ${HINDSIGHT_TOKEN:0:12}...)"
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 13: WatchClaw Security Monitoring (optional)
# ═══════════════════════════════════════════════════════════════

if [[ "${INSTALL_WATCHCLAW,,}" == "y" ]]; then
  next_step; log "[$STEP/$TOTAL_STEPS] WatchClaw security..."

  WATCHCLAW_SRC="/tmp/watchclaw-src"
  WATCHCLAW_DIR="/opt/watchclaw"

  # Clone to temp dir first (install.sh copies into /opt/watchclaw)
  rm -rf "${WATCHCLAW_SRC}"
  git clone --depth=1 https://github.com/kashifeqbal/watchclaw.git "${WATCHCLAW_SRC}" 2>/dev/null

  # Run installer in standalone mode
  if [ -f "${WATCHCLAW_SRC}/install.sh" ]; then
    mkdir -p /etc/watchclaw /var/lib/watchclaw /var/log/watchclaw
    cd "${WATCHCLAW_SRC}"
    bash install.sh 2>&1 | tail -20 || true
    rm -rf "${WATCHCLAW_SRC}"
    ok "WatchClaw installed (standalone)"

    # Update UFW for new SSH port if WatchClaw moved it
    if grep -q "^Port 2222" /etc/ssh/sshd_config 2>/dev/null; then
      if [ -n "${CLOUDFLARE_TUNNEL_TOKEN}" ]; then
        # Tunnel mode: only allow loopback on new port
        ufw allow from 127.0.0.1 to any port 2222 proto tcp comment 'SSH 2222 loopback (tunnel)' 2>/dev/null
        ufw allow from ::1 to any port 2222 proto tcp comment 'SSH 2222 loopback v6 (tunnel)' 2>/dev/null
        ok "UFW: SSH 2222 loopback-only (tunnel mode)"
      else
        ufw allow 2222/tcp comment "SSH (moved by WatchClaw)" 2>/dev/null || true
        ok "UFW: SSH 2222 open"
      fi
    fi
  else
    warn "WatchClaw install.sh not found — skipped"
  fi

  # Restart SSH with new config (port change, hardening) — LAST step
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  ok "SSH restarted with hardened config"

  # Wire alert delivery channel
  if [ -n "${WATCHCLAW_TELEGRAM_TOKEN:-}" ] && [ -n "${WATCHCLAW_CHAT_ID:-}" ]; then
    mkdir -p /etc/watchclaw /opt/watchclaw
    # Write alert env config (watchclaw reads from /etc/watchclaw/.env or /opt/watchclaw/.env)
    cat > /etc/watchclaw/alerts.env << WCENV
TELEGRAM_BOT_TOKEN=${WATCHCLAW_TELEGRAM_TOKEN}
TELEGRAM_CHAT_ID=${WATCHCLAW_CHAT_ID}
WCENV
    chmod 600 /etc/watchclaw/alerts.env
    # Also write to /opt/watchclaw if it exists
    if [ -d /opt/watchclaw ]; then
      cp /etc/watchclaw/alerts.env /opt/watchclaw/alerts.env
      chmod 600 /opt/watchclaw/alerts.env
    fi
    ok "WatchClaw alerts → Telegram chat ${WATCHCLAW_CHAT_ID}"
  else
    warn "WatchClaw alert channel not configured — set WATCHCLAW_TELEGRAM_TOKEN + WATCHCLAW_CHAT_ID to enable"
  fi
fi

# ═══════════════════════════════════════════════════════════════
# FINAL: Start Services
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Starting services..."

# Start gateway
systemctl start openclaw-gateway 2>/dev/null || true
sleep 5

# Check health — gateway serves HTML on /, so check if port is listening
if ss -tlnp | grep -q ":18789"; then
  ok "Gateway running on :18789"
else
  warn "Gateway not responding yet — run: openclaw models auth add"
fi

# Start studio
systemctl start openclaw-studio 2>/dev/null || true
ok "Studio started on :3000"

# Start hindsight
if [[ "${INSTALL_HINDSIGHT,,}" == "y" ]]; then
  systemctl start hindsight-pageindex 2>/dev/null || true
  sleep 2
  if systemctl is-active hindsight-pageindex &>/dev/null; then
    ok "Hindsight running on :8787"
  else
    warn "Hindsight not starting — check: journalctl -u hindsight-pageindex"
  fi
fi

# ═══════════════════════════════════════════════════════════════
# DONE
# ═══════════════════════════════════════════════════════════════

SETUP_END=$(date +%s)
SETUP_DURATION=$((SETUP_END - SETUP_START))

echo ""
echo "════════════════════════════════════════════════════════"
echo "  🦞 TeamClaw Setup Complete! (${SETUP_DURATION}s)"
echo "════════════════════════════════════════════════════════"
echo ""
echo "  Agent:     ${AGENT_NAME} ${AGENT_EMOJI:-}"
echo "  Org:       ${ORG_NAME}"
echo "  User:      root (/root)"
echo "  Gateway:   ws://localhost:18789"
echo "  Token:     ${GATEWAY_TOKEN}"
echo "  Studio:    http://localhost:3000"
echo "  Config:    ${OC_STATE}/openclaw.json"
echo "  Workspace: ${OC_WORKSPACE}/"
echo "  .env:      ${OC_STATE}/.env ($(wc -l < "$ENV_FILE") keys)"
echo ""
echo "  Security:  SSH ✅ | UFW ✅ | fail2ban ✅ | kernel ✅"
[ -n "${CLOUDFLARE_TUNNEL_TOKEN}" ] && echo "  Tunnel:    cloudflared ✅"
[[ "${INSTALL_WATCHCLAW,,}" == "y" ]] && echo "  WatchClaw: /opt/watchclaw ✅"
[[ "${INSTALL_HINDSIGHT,,}" == "y" ]] && echo "  Hindsight: http://localhost:8787"
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  Next steps:                                        │"
echo "  │                                                     │"
echo "  │  1. Authenticate Claude:                            │"
echo "  │     (you are already root)                          │"
echo "  │                                                     │"
echo "  │  2. Authenticate Claude:                            │"
echo "  │     openclaw models auth add                        │"
echo "  │                                                     │"
echo "  │  3. Test:                                           │"
echo "  │     openclaw tui                                    │"
echo "  │                                                     │"
if [ -n "${GH_ORG:-}" ] && [ -z "${GH_TOKEN:-}" ]; then
echo "  │  4. GitHub SSH key:                                 │"
echo "  │     ssh-keygen -t ed25519 \\                         │"
echo "  │       -f ~/.ssh/id_ed25519_github_${GH_PROFILE}     │"
echo "  │     GH_CONFIG_DIR=~/.config/gh-${GH_PROFILE} \\     │"
echo "  │       gh auth login                                 │"
echo "  │                                                     │"
fi
echo "  │  Wire channels:                                     │"
echo "  │  • Telegram: @BotFather → /newbot                   │"
echo "  │    openclaw channels login telegram                 │"
echo "  │  • Discord: discord.com/developers → New App        │"
echo "  │    openclaw channels login discord                  │"
echo "  │                                                     │"
if [ -z "${CLOUDFLARE_TUNNEL_TOKEN}" ]; then
echo "  │  Optional:                                          │"
echo "  │  • cloudflared service install <TUNNEL_TOKEN>       │"
fi
echo "  └─────────────────────────────────────────────────────┘"
echo ""
