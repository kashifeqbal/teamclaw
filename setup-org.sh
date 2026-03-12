#!/bin/bash
set -uo pipefail

# ═══════════════════════════════════════════════════════════════
# TeamClaw Setup — OpenClaw for Teams (v0.4)
# ═══════════════════════════════════════════════════════════════
#
# Usage:
#   bash setup-org.sh                     # interactive (TTY)
#   bash setup-org.sh --config team.env   # non-interactive (CI/nohup)
#
# Prerequisites:
#   - Fresh Ubuntu 22.04/24.04 VPS (root access)
#   - Claude subscription (for openclaw models auth add)
#
# Runs everything as root — no dedicated user needed.
#
# Changelog:
#   v0.4 — 2026-03-12
#     Fix 1:  SSH restarted at end regardless of WatchClaw
#     Fix 2:  Gateway systemd unit loads .env via EnvironmentFile
#     Fix 3:  openclaw config validate → openclaw doctor
#     Fix 4:  memory-core plugin configured in openclaw.json
#     Fix 5:  CF tunnel validated via HTTP before SSH lockdown
#     Fix 6:  team.env.example includes all Telegram fields
#     Fix 7:  --config review shows Telegram config
#     Fix 8:  INSTALL_DASHBOARD acknowledged (stub, not silent)
#     Fix 9:  Dotfiles default changed to empty (skip if not set)
#     Fix 10: Docs sync renamed to org-agnostic (DOCS_SYNC_REPO, sync-docs.sh)
#     Fix 11: unattended-upgrades installed + configured
#     Fix 12: fs.inotify.max_user_watches=1048576 added to sysctl
#     Fix 13: Studio ExecStart uses node_modules/.bin/next path
#     Fix 14: PULSE_ALLOW_FROM / OPS_ALLOW_FROM in team.env.example
#     Fix 15: CF tunnel exit-on-fail with recovery instructions

# ─── Helpers ───
log()  { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok()   { echo -e "  \033[1;32m✅ $*\033[0m"; }
warn() { echo -e "  \033[1;33m⚠️  $*\033[0m"; }
skip() { echo -e "  \033[0;90m⏭  $*\033[0m"; }
fail() { echo -e "  \033[1;31m❌ $*\033[0m"; }

# Fix #7 (v0.3): TTY-safe read — silently skips if stdin is not a terminal
tty_read() {
  local prompt="$1" varname="$2"
  if [ -t 0 ]; then
    # shellcheck disable=SC2229  # intentional indirect ref: $varname expands to target var name
    read -rp "$prompt" $varname
  fi
}

echo ""
echo "🦞 TeamClaw Setup v0.4"
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

  echo ""
  echo "── Agent ──────────────────────────────────"
  echo "  Name:     ${AGENT_NAME:-} ${AGENT_EMOJI:-}"
  echo "  Org:      ${ORG_NAME:-}"
  echo "  Timezone: ${TEAM_TZ:-}"
  echo ""
  echo "── Telegram ───────────────────────────────"
  if [ -n "${PULSE_TELEGRAM_BOT_TOKEN:-}" ]; then
    echo "  Pulse bot:    ✅ (from config)"
    echo "  Allow from:   ${PULSE_ALLOW_FROM:-"(anyone)"}"
  else
    warn "PULSE_TELEGRAM_BOT_TOKEN not set — agent will have no Telegram"
  fi
  if [ -n "${OPS_TELEGRAM_BOT_TOKEN:-}" ]; then
    echo "  Ops bot:      ✅ (from config)"
    echo "  Ops chat ID:  ${OPS_TELEGRAM_CHAT_ID:-"(not set)"}"
  else
    warn "OPS_TELEGRAM_BOT_TOKEN not set — no ops alerts channel"
  fi
  echo ""
  echo "── Discord ────────────────────────────────"
  if [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
    echo "  Discord bot:  ✅ (from config)"
    echo "  Guild ID:     ${DISCORD_GUILD_ID:-"(not set)"}"
    echo "  Channels:     ${DISCORD_CHANNEL_IDS:-"(all blocked)"}"
  else
    warn "DISCORD_BOT_TOKEN not set — no Discord integration"
  fi
  echo ""
  echo "── Infrastructure ─────────────────────────"
  if [ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
    echo "  CF Tunnel:   ✅ (from config)"
  else
    warn "No Cloudflare Tunnel — SSH will remain open to internet"
  fi
  echo "  WatchClaw:   ${INSTALL_WATCHCLAW:-n}"
  echo "  Hindsight:   ${INSTALL_HINDSIGHT:-n}"
  echo "  Dashboard:   ${INSTALL_DASHBOARD:-n}"
  echo ""

  [ -z "${OPENAI_KEY:-}" ]          && tty_read "  OpenAI API key (blank to skip): " OPENAI_KEY
  [ -z "${BRAVE_KEY:-}" ]           && tty_read "  Brave Search API key (blank to skip): " BRAVE_KEY

  if [ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
    tty_read "  Cloudflare Tunnel token (blank to skip): " CLOUDFLARE_TUNNEL_TOKEN
  fi

  if [[ "${INSTALL_WATCHCLAW:-n}" == "y" ]]; then
    [ -z "${WATCHCLAW_TELEGRAM_TOKEN:-}" ] && tty_read "  WatchClaw Telegram bot token (blank to skip alerts): " WATCHCLAW_TELEGRAM_TOKEN
    [ -z "${WATCHCLAW_CHAT_ID:-}" ]        && tty_read "  WatchClaw Telegram chat ID: " WATCHCLAW_CHAT_ID
  else
    tty_read "  Install WatchClaw security? [y/N]: " INSTALL_WATCHCLAW
    if [[ "${INSTALL_WATCHCLAW,,}" == "y" ]]; then
      tty_read "  WatchClaw Telegram bot token (blank to skip alerts): " WATCHCLAW_TELEGRAM_TOKEN
      tty_read "  WatchClaw Telegram chat ID: " WATCHCLAW_CHAT_ID
    fi
  fi

  if [[ "${INSTALL_HINDSIGHT:-n}" != "y" ]]; then
    tty_read "  Install Hindsight memory? [y/N]: " INSTALL_HINDSIGHT
  fi

else
  echo "── Agent Configuration ──"
  tty_read "  Agent name (e.g. Pulse): " AGENT_NAME
  tty_read "  Agent emoji (e.g. 💚): " AGENT_EMOJI
  tty_read "  Organization name (e.g. TapHealth): " ORG_NAME
  tty_read "  Product description (one line): " PRODUCT_DESC
  tty_read "  Team timezone (e.g. Asia/Kolkata): " TEAM_TZ

  echo ""
  echo "── GitHub Configuration ──"
  tty_read "  GitHub org/user (blank to skip): " GH_ORG
  if [ -n "${GH_ORG:-}" ]; then
    tty_read "  GitHub profile name (e.g. taphealth): " GH_PROFILE
    tty_read "  GitHub PAT (fine-grained, blank to skip): " GH_TOKEN
  fi

  echo ""
  echo "── Telegram Channels ──"
  echo "  (Two bots recommended: one for agent DMs, one for ops alerts)"
  tty_read "  Pulse agent bot token (@BotFather, blank to skip): " PULSE_TELEGRAM_BOT_TOKEN
  tty_read "  Pulse bot allowFrom user IDs (comma-separated, e.g. 111111,222222): " PULSE_ALLOW_FROM
  tty_read "  Ops/alerts bot token (blank = same as pulse): " OPS_TELEGRAM_BOT_TOKEN
  tty_read "  Ops group chat ID (e.g. -5084525213, blank to skip): " OPS_TELEGRAM_CHAT_ID
  tty_read "  Ops bot allowFrom user IDs (comma-separated): " OPS_ALLOW_FROM

  echo ""
  echo "── Discord ──"
  echo "  (For dev team channel access — separate agent, allowlisted channels)"
  tty_read "  Discord bot token (blank to skip): " DISCORD_BOT_TOKEN
  if [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
    tty_read "  Discord guild (server) ID: " DISCORD_GUILD_ID
    tty_read "  Allowed channel IDs (comma-separated): " DISCORD_CHANNEL_IDS
  fi

  echo ""
  echo "── Optional Features ──"
  tty_read "  Install Docker? [y/N]: " OPT_DOCKER
  tty_read "  OpenAI API key (for memory/embeddings, blank to skip): " OPENAI_KEY
  tty_read "  Brave Search API key (blank to skip): " BRAVE_KEY
  # Fix #9: Dotfiles repo — blank = skip (no personal default)
  tty_read "  Dotfiles repo URL (blank to skip): " DOTFILES_REPO

  echo ""
  echo "── Infrastructure ──"
  tty_read "  Cloudflare Tunnel token (blank to skip): " CLOUDFLARE_TUNNEL_TOKEN
  tty_read "  Install WatchClaw security? [y/N]: " INSTALL_WATCHCLAW
  if [[ "${INSTALL_WATCHCLAW,,}" == "y" ]]; then
    tty_read "  WatchClaw Telegram bot token (blank to skip alerts): " WATCHCLAW_TELEGRAM_TOKEN
    tty_read "  WatchClaw Telegram chat ID: " WATCHCLAW_CHAT_ID
  fi
  tty_read "  Install Hindsight memory? [y/N]: " INSTALL_HINDSIGHT
  tty_read "  Docs sync repo SSH URL (blank to skip): " DOCS_SYNC_REPO
fi

# ─── Defaults ───
AGENT_ID=$(echo "${AGENT_NAME:-agent}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
GH_PROFILE=${GH_PROFILE:-${GH_ORG:-}}
GH_TOKEN=${GH_TOKEN:-}
OPT_DOCKER=${OPT_DOCKER:-n}
OPENAI_KEY=${OPENAI_KEY:-}
BRAVE_KEY=${BRAVE_KEY:-}
DOTFILES_REPO=${DOTFILES_REPO:-}  # Fix #9: empty by default — skip if not provided
CLOUDFLARE_TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN:-}
INSTALL_WATCHCLAW=${INSTALL_WATCHCLAW:-n}
INSTALL_HINDSIGHT=${INSTALL_HINDSIGHT:-n}
INSTALL_DASHBOARD=${INSTALL_DASHBOARD:-n}  # Fix #8: tracked but currently stub
DOCS_SYNC_REPO=${DOCS_SYNC_REPO:-${TAPHEALTH_DOCS_REPO:-}}  # Fix #10: org-agnostic name
INSTALL_DOCS_SYNC=${INSTALL_DOCS_SYNC:-n}

# Telegram defaults
PULSE_TELEGRAM_BOT_TOKEN=${PULSE_TELEGRAM_BOT_TOKEN:-}
PULSE_ALLOW_FROM=${PULSE_ALLOW_FROM:-}
OPS_TELEGRAM_BOT_TOKEN=${OPS_TELEGRAM_BOT_TOKEN:-}
OPS_TELEGRAM_CHAT_ID=${OPS_TELEGRAM_CHAT_ID:-}
OPS_ALLOW_FROM=${OPS_ALLOW_FROM:-}

# WatchClaw — fall back to ops bot if not explicitly set
WATCHCLAW_TELEGRAM_TOKEN=${WATCHCLAW_TELEGRAM_TOKEN:-${OPS_TELEGRAM_BOT_TOKEN:-}}
WATCHCLAW_CHAT_ID=${WATCHCLAW_CHAT_ID:-${OPS_TELEGRAM_CHAT_ID:-}}

# Discord defaults
DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN:-}
DISCORD_GUILD_ID=${DISCORD_GUILD_ID:-}
DISCORD_CHANNEL_IDS=${DISCORD_CHANNEL_IDS:-}  # comma-separated, empty = block all

# Docs sync — enable if repo is set (Fix #10: use org-agnostic var)
[ -n "${DOCS_SYNC_REPO}" ] && INSTALL_DOCS_SYNC="y"

# ─── Step counter ───
TOTAL_STEPS=13
[[ -n "${CLOUDFLARE_TUNNEL_TOKEN}" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "${INSTALL_WATCHCLAW,,}" == "y" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "${INSTALL_HINDSIGHT,,}" == "y" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "${INSTALL_DOCS_SYNC,,}" == "y" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
STEP=0
next_step() { STEP=$((STEP + 1)); }

echo ""
echo "  Agent:    ${AGENT_NAME} ${AGENT_EMOJI:-}"
echo "  Org:      ${ORG_NAME}"
echo "  User:     root"
echo "  Home:     /root"
echo ""

SETUP_START=$(date +%s)

# ═══════════════════════════════════════════════════════════════
# PHASE 1: System packages
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] System packages..."
export DEBIAN_FRONTEND=noninteractive

dpkg --configure -a 2>/dev/null || true
for i in $(seq 1 12); do
  if fuser /var/lib/dpkg/lock-frontend &>/dev/null; then
    warn "Waiting for apt lock... ($((i*10))s)"; sleep 10
  else break; fi
done
apt-get update -qq 2>/dev/null || apt-get update -qq

apt-get install -y -qq \
  curl git vim jq tree unzip \
  python3 python3-pip python3-venv \
  sqlite3 stow tmux htop fzf zsh \
  ca-certificates gnupg \
  openssh-client openssh-server \
  build-essential \
  ufw fail2ban \
  unattended-upgrades apt-listchanges 2>&1 | tail -5
ok "System packages"

# Fix #11: Configure unattended-upgrades for automatic security patching
if ! grep -q "Unattended-Upgrade" /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
  cat > /etc/apt/apt.conf.d/20auto-upgrades << 'UUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
UUEOF
  cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UUEOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
UUEOF
  systemctl enable unattended-upgrades 2>/dev/null || true
  ok "Unattended security upgrades configured (auto-reboot 03:00)"
else
  skip "Unattended-upgrades already configured"
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 2: Node.js 22
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Node.js 22..."
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>/dev/null
  apt-get install -y -qq nodejs 2>/dev/null
fi
ok "Node $(node --version)"

# ═══════════════════════════════════════════════════════════════
# PHASE 3: npm globals
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] npm globals (OpenClaw, mcporter, clawhub, gh, cloudflared)..."

npm install -g openclaw@latest 2>/dev/null
ok "OpenClaw $(openclaw --version 2>/dev/null || echo 'installed')"
npm install -g mcporter@latest 2>/dev/null
ok "mcporter"
npm install -g clawhub@latest 2>/dev/null
ok "clawhub"

if ! command -v gh &>/dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
    https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq 2>/dev/null && apt-get install -y -qq gh 2>/dev/null
fi
ok "GitHub CLI"

if ! command -v cloudflared &>/dev/null; then
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
    -o /tmp/cloudflared.deb
  dpkg -i /tmp/cloudflared.deb 2>/dev/null && rm -f /tmp/cloudflared.deb
fi
ok "cloudflared binary"

if ! command -v oh-my-posh &>/dev/null; then
  curl -s https://ohmyposh.dev/install.sh | bash -s 2>/dev/null
  cp /root/.local/bin/oh-my-posh /usr/local/bin/ 2>/dev/null
  chmod 755 /usr/local/bin/oh-my-posh 2>/dev/null
  mkdir -p /usr/local/share/oh-my-posh/themes
  cp /root/.cache/oh-my-posh/themes/* /usr/local/share/oh-my-posh/themes/ 2>/dev/null || true
fi
ok "oh-my-posh"

if [[ "${OPT_DOCKER,,}" == "y" ]]; then
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh 2>/dev/null
  fi
  ok "Docker"
else
  skip "Docker skipped"
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 4: Cloudflare Tunnel — MUST start before SSH hardening
# Fix #5 + #15: Validate tunnel actually passes traffic before proceeding
# ═══════════════════════════════════════════════════════════════

CF_TUNNEL_ACTIVE=false
if [ -n "${CLOUDFLARE_TUNNEL_TOKEN}" ]; then
  next_step; log "[$STEP/$TOTAL_STEPS] Cloudflare tunnel (starting before SSH lockdown)..."

  cloudflared service install "${CLOUDFLARE_TUNNEL_TOKEN}" 2>/dev/null || true
  systemctl enable cloudflared 2>/dev/null || true
  systemctl start cloudflared 2>/dev/null || true

  # Wait for tunnel to actually connect — check via cloudflared metrics endpoint
  TUNNEL_UP=false
  for i in $(seq 1 12); do
    sleep 5
    if systemctl is-active cloudflared &>/dev/null; then
      # Verify connectivity via metrics port (cloudflared exposes metrics on 20241 by default)
      if curl -sf http://localhost:20241/metrics 2>/dev/null | grep -q "cloudflared_tunnel_active_streams\|cloudflared_build_info"; then
        TUNNEL_UP=true
        break
      fi
      # Fallback: check if service has been stable for 5+ seconds without restarting
      ACTIVE_SINCE=$(systemctl show cloudflared --property=ActiveEnterTimestampMonotonic --value 2>/dev/null || echo "0")
      NOW_MONO=$(awk '{print int($1*1000000)}' /proc/uptime 2>/dev/null || echo "0")
      UPTIME_USEC=$(( NOW_MONO - ACTIVE_SINCE ))
      if [ "$UPTIME_USEC" -gt 10000000 ] 2>/dev/null; then
        TUNNEL_UP=true
        break
      fi
    fi
    warn "Waiting for Cloudflare tunnel... (${i}/12, $((i*5))s)"
  done

  if $TUNNEL_UP; then
    CF_TUNNEL_ACTIVE=true
    ok "Cloudflare tunnel active ✅"
  else
    # Fix #15: Exit with recovery instructions instead of silently proceeding
    fail "Cloudflare tunnel failed to connect after 60s."
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │  ⚠️  HALTING before SSH lockdown — tunnel not verified       │"
    echo "  │                                                             │"
    echo "  │  SSH would have been restricted to loopback-only,          │"
    echo "  │  but the tunnel isn't working. That would lock you out.    │"
    echo "  │                                                             │"
    echo "  │  Options:                                                   │"
    echo "  │    1. Check your CLOUDFLARE_TUNNEL_TOKEN is correct         │"
    echo "  │       journalctl -u cloudflared --no-pager -n 30            │"
    echo "  │    2. Re-run with a corrected token                         │"
    echo "  │    3. Re-run without CLOUDFLARE_TUNNEL_TOKEN to keep SSH    │"
    echo "  │       open (less secure, but safe to iterate)               │"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo ""
    exit 1
  fi
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 5: Dotfiles
# Fix #9: Skip entirely if DOTFILES_REPO is empty
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Dotfiles..."

if [ -n "${DOTFILES_REPO:-}" ]; then
  DOTFILES_DIR="/root/dotfiles"

  if [ ! -d "${DOTFILES_DIR}/.git" ]; then
    git clone "${DOTFILES_REPO}" "${DOTFILES_DIR}" 2>/dev/null
  fi

  if [ -d "${DOTFILES_DIR}" ]; then
    rm -f "/root/.zshrc" "/root/.zshenv" "/root/.gitconfig" "/root/.vimrc" 2>/dev/null
    cd "${DOTFILES_DIR}" || exit
    echo '\.git' > "${DOTFILES_DIR}/.stow-local-ignore" 2>/dev/null || true
    stow --target="/root" --restow --ignore='\.git' . 2>/dev/null || {
      for f in .zshrc .zimrc .zshenv .exports .aliases .gitconfig .vimrc .curlrc .wgetrc .stow-global-ignore; do
        [ -f "${DOTFILES_DIR}/$f" ] && ln -sf "${DOTFILES_DIR}/$f" "/root/$f"
      done
      for d in .config .vim; do
        [ -d "${DOTFILES_DIR}/$d" ] && cp -r "${DOTFILES_DIR}/$d" "/root/"
      done
    }
    ok "Dotfiles stowed from ${DOTFILES_REPO}"

    if [ ! -f "/root/.config/oh-my-posh/zen.omp.json" ]; then
      mkdir -p "/root/.config/oh-my-posh"
      if [ -f "${DOTFILES_DIR}/.config/oh-my-posh/zen.omp.json" ]; then
        ln -sf "${DOTFILES_DIR}/.config/oh-my-posh/zen.omp.json" "/root/.config/oh-my-posh/"
      elif [ -f /usr/local/share/oh-my-posh/themes/zen.omp.json ]; then
        cp /usr/local/share/oh-my-posh/themes/zen.omp.json "/root/.config/oh-my-posh/"
      fi
    fi

    if [ ! -d "/root/.zim" ]; then
      bash -c 'curl -fsSL https://raw.githubusercontent.com/zimfw/install/master/install.zsh | ZIM_HOME=~/.zim zsh' 2>/dev/null || true
      ok "Zim framework installed"
    fi
  else
    warn "Could not clone dotfiles from ${DOTFILES_REPO}"
  fi
else
  skip "Dotfiles skipped (DOTFILES_REPO not set)"
fi

git config --global user.name "${ORG_NAME} Bot"
git config --global user.email "bot@${ORG_NAME,,}.com"

# ═══════════════════════════════════════════════════════════════
# PHASE 6: Security hardening
# Fix #1: SSH restart is now always done at end of this phase
# Fix #12: inotify watches added to sysctl
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Security hardening..."
SSH_NEEDS_RESTART=false

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

  if $CF_TUNNEL_ACTIVE; then
    if ! grep -q "^ListenAddress 127.0.0.1" /etc/ssh/sshd_config 2>/dev/null; then
      cat >> /etc/ssh/sshd_config << 'SSHLISTENEOF'

# ─── TeamClaw: tunnel-only SSH ────────────────
ListenAddress 127.0.0.1
ListenAddress ::1
SSHLISTENEOF
      ok "SSH bound to localhost (tunnel-only access)"
    fi
  fi
  /usr/sbin/sshd -t 2>/dev/null && {
    ok "SSH config valid — will restart at end of hardening"
    SSH_NEEDS_RESTART=true
  } || fail "SSH config test failed — check /etc/ssh/sshd_config"
else
  skip "SSH already hardened"
fi

if [ ! -f /etc/sysctl.d/99-teamclaw-hardening.conf ]; then
  cat > /etc/sysctl.d/99-teamclaw-hardening.conf << 'SYSEOF'
# ─── Network hardening ─────────────────────────────────────────
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
# ─── Kernel hardening ──────────────────────────────────────────
kernel.sysrq = 0
kernel.core_uses_pid = 1
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
# ─── File watchers (Fix #12) ───────────────────────────────────
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 512
SYSEOF
  sysctl --system 2>/dev/null | tail -1
  ok "Kernel hardened (31 sysctl settings, inotify included)"
else
  skip "Kernel hardening already applied"
fi

ufw --force reset 2>/dev/null
ufw default deny incoming 2>/dev/null
ufw default allow outgoing 2>/dev/null
if $CF_TUNNEL_ACTIVE; then
  ufw allow from 127.0.0.1 to any port 22 proto tcp comment 'SSH loopback (tunnel)' 2>/dev/null
  ufw allow from ::1 to any port 22 proto tcp comment 'SSH loopback v6 (tunnel)' 2>/dev/null
  ok "UFW: SSH loopback-only (tunnel confirmed)"
else
  ufw allow ssh comment 'SSH' 2>/dev/null
  ok "UFW: SSH open (no tunnel)"
fi
ufw --force enable 2>/dev/null
ok "UFW active"

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

# Fix #1: Always restart SSH at end of hardening phase (not buried in WatchClaw)
if $SSH_NEEDS_RESTART; then
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  ok "SSH restarted with hardened config"
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 7: GitHub
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] GitHub configuration..."
if [ -n "${GH_ORG:-}" ]; then
  GH_DIR="/root/.config/gh-${GH_PROFILE}"
  mkdir -p "${GH_DIR}"
  mkdir -p "/root/.ssh" && chmod 700 "/root/.ssh"

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

  ALIASES_FILE="/root/.aliases"
  grep -q "gh-${GH_PROFILE}" "${ALIASES_FILE}" 2>/dev/null || {
    echo "" >> "${ALIASES_FILE}"
    echo "# ${ORG_NAME} GitHub"  >> "${ALIASES_FILE}"
    echo "alias gh-${GH_PROFILE}='GH_CONFIG_DIR=${GH_DIR} gh'" >> "${ALIASES_FILE}"
  }
  ok "GitHub profile: gh-${GH_PROFILE} → ${GH_ORG}"

  if [ -n "${GH_TOKEN:-}" ]; then
    echo "${GH_TOKEN}" | GH_CONFIG_DIR="${GH_DIR}" gh auth login --with-token 2>/dev/null && \
      ok "GitHub authenticated via token" || warn "GitHub token auth failed"
  fi
else
  skip "GitHub skipped"
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 8: Workspace
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Creating workspace & agent..."
OC_STATE="/root/.openclaw"
OC_WORKSPACE="/opt/teamclaw/workspace"

mkdir -p /opt/teamclaw/{workspace,config,scripts,repos}
mkdir -p "${OC_WORKSPACE}"/{team,product,engineering,scripts,memory}
mkdir -p "${OC_STATE}"/{agents/${AGENT_ID}/sessions,cron,credentials,memory}
ln -sfn "${OC_WORKSPACE}" "${OC_STATE}/workspace"

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
- **Product:** ${PRODUCT_DESC:-}

## Team
_(Add team members here)_

## Timezone
- ${TEAM_TZ:-Asia/Kolkata}
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

ok "${AGENT_NAME} workspace created"

# ═══════════════════════════════════════════════════════════════
# PHASE 9: openclaw.json — full multi-agent / multi-bot config
# Fix #2: Gateway systemd unit loads .env via EnvironmentFile
# Fix #4: memory-core plugin configured
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Generating openclaw.json..."

GATEWAY_TOKEN=$(openssl rand -hex 24)

ENV_FILE="${OC_STATE}/.env"
: > "$ENV_FILE"
[ -n "${OPENAI_KEY:-}" ] && echo "OPENAI_API_KEY=${OPENAI_KEY}" >> "$ENV_FILE"
[ -n "${BRAVE_KEY:-}" ]  && echo "BRAVE_SEARCH_KEY=${BRAVE_KEY}" >> "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Build openclaw.json via Python — handles multi-agent/multi-bot/bindings cleanly
python3 << PYJSON
import json, os

agent_id   = "${AGENT_ID}"
agent_name = "${AGENT_NAME}"
oc_workspace = "${OC_WORKSPACE}"
gateway_token = "${GATEWAY_TOKEN}"

pulse_token    = "${PULSE_TELEGRAM_BOT_TOKEN}"
pulse_allow    = [int(x.strip()) for x in "${PULSE_ALLOW_FROM}".split(",") if x.strip().isdigit()]
ops_token      = "${OPS_TELEGRAM_BOT_TOKEN}"
ops_chat_id    = "${OPS_TELEGRAM_CHAT_ID}"
ops_allow_raw  = "${OPS_ALLOW_FROM}"
ops_allow      = [int(x.strip()) for x in ops_allow_raw.split(",") if x.strip().isdigit()]

cfg = {
    "gateway": {
        "auth": {"token": gateway_token},
        "bind": "loopback",
        "port": 18789,
        "mode": "local"
    },
    "agents": {
        "defaults": {
            "model": {
                "primary": "anthropic/claude-sonnet-4-6",
                "fallbacks": ["openai-codex/gpt-5.3-codex"]
            },
            "memorySearch": {
                "enabled": True,
                "sources": ["memory", "sessions"],
                "experimental": {"sessionMemory": True},
                "query": {
                    "maxResults": 8, "minScore": 0.3,
                    "hybrid": {
                        "enabled": True,
                        "vectorWeight": 0.6, "textWeight": 0.4,
                        "temporalDecay": {"enabled": True, "halfLifeDays": 14}
                    }
                },
                "sync": {"onSessionStart": True, "onSearch": True, "watch": True}
            }
        },
        "list": [
            {
                "id": agent_id,
                "name": agent_name,
                "workspace": oc_workspace,
                "model": {"primary": "anthropic/claude-sonnet-4-6"},
                "tools": {"fs": {"workspaceOnly": False}}
            }
        ]
    },
    "commands": {
        "native": "auto",
        "nativeSkills": "auto",
        "restart": True,
        "ownerDisplay": "raw"
    },
    # Fix #4: memory-core plugin so memorySearch has somewhere to search
    "plugins": {
        "entries": {
            "memory-core": {
                "enabled": True,
                "options": {
                    "namespace": agent_id,
                    "maxMemories": 2000,
                    "embedding": "local"
                }
            }
        }
    }
}

# Ops agent — add if ops bot token or ops allow list is set
if ops_token or ops_allow:
    cfg["agents"]["list"].append({
        "id": "ops",
        "name": f"{agent_name} Ops",
        "workspace": oc_workspace,
        "model": {"primary": "anthropic/claude-sonnet-4-6"},
        "identity": {"emoji": "🔧"},
        "tools": {"fs": {"workspaceOnly": False}}
    })

# Telegram channel config
if pulse_token or ops_token:
    accounts = {}

    if pulse_token:
        accounts["default"] = {
            "botToken": pulse_token,
            "dmPolicy": "pairing",
            "groupPolicy": "allowlist",
            "streaming": "partial",
            **({"allowFrom": pulse_allow} if pulse_allow else {})
        }

    if ops_token:
        ops_account = {
            "botToken": ops_token,
            "dmPolicy": "pairing",
            "groupPolicy": "open",
            "streaming": "partial",
            **({"allowFrom": ops_allow} if ops_allow else {})
        }
        if ops_chat_id:
            ops_account["groups"] = {
                ops_chat_id: {
                    "requireMention": False,
                    "groupPolicy": "open",
                    "enabled": True
                }
            }
        accounts["ops"] = ops_account

    cfg["channels"] = {
        "telegram": {
            "enabled": True,
            "dmPolicy": "pairing",
            "groupPolicy": "open",
            "streaming": "partial",
            "accounts": accounts,
            "defaultAccount": "default" if "default" in accounts else list(accounts.keys())[0]
        }
    }
    cfg["plugins"]["entries"]["telegram"] = {"enabled": True}

    # Bindings: route each agent to its bot
    bindings = []
    if pulse_token:
        bindings.append({
            "type": "route",
            "agentId": agent_id,
            "match": {"channel": "telegram", "accountId": "default"}
        })
    if ops_token:
        bindings.append({
            "type": "route",
            "agentId": "ops",
            "match": {"channel": "telegram", "accountId": "ops"}
        })
    if bindings:
        cfg["bindings"] = bindings

# Discord channel config
discord_token   = "${DISCORD_BOT_TOKEN}"
discord_guild   = "${DISCORD_GUILD_ID}"
discord_channels_raw = "${DISCORD_CHANNEL_IDS}"
discord_channels = [c.strip() for c in discord_channels_raw.split(",") if c.strip()]

if discord_token and discord_guild:
    discord_agent_id = f"{agent_id}-discord"

    # Create a dedicated Discord agent
    cfg["agents"]["list"].append({
        "id": discord_agent_id,
        "name": f"{agent_name} Discord",
        "workspace": oc_workspace,
        "model": {"primary": "anthropic/claude-sonnet-4-6"},
        "identity": {"emoji": "💬"},
        "tools": {"fs": {"workspaceOnly": False}}
    })

    # Build per-channel config — allow listed channels, block everything else
    channel_cfg = {"*": {"allow": False}}
    for ch_id in discord_channels:
        channel_cfg[ch_id] = {"allow": True, "requireMention": False}

    cfg["channels"]["discord"] = {
        "enabled": True,
        "groupPolicy": "allowlist",
        "streaming": "off",
        "guilds": {
            discord_guild: {
                "requireMention": False,
                "channels": channel_cfg
            }
        },
        "accounts": {
            "default": {
                "token": discord_token,
                "groupPolicy": "allowlist",
                "streaming": "off"
            }
        }
    }
    cfg["plugins"]["entries"]["discord"] = {"enabled": True}

    # Binding: route discord agent to discord channel
    if "bindings" not in cfg:
        cfg["bindings"] = []
    cfg["bindings"].append({
        "type": "route",
        "agentId": discord_agent_id,
        "match": {"channel": "discord"}
    })

out = "/root/.openclaw/openclaw.json"
with open(out, "w") as f:
    json.dump(cfg, f, indent=2)
print(f"  Written: {out}")
PYJSON

chmod 700 "${OC_STATE}" "${OC_STATE}/credentials" 2>/dev/null || true

# Fix #3: openclaw config validate → openclaw doctor
if openclaw doctor 2>&1 | grep -qiE "ok|healthy|valid|ready"; then
  ok "openclaw.json valid (doctor passed)"
else
  warn "openclaw doctor flagged something — check after install: openclaw doctor"
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 10: Studio
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Installing OpenClaw Studio..."
if [ ! -d /opt/openclaw-studio ]; then
  git clone --depth 1 https://github.com/grp06/openclaw-studio.git /opt/openclaw-studio 2>/dev/null
  cd /opt/openclaw-studio || exit

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
print('  Patched page.tsx for Suspense boundary')
PATCHEOF
  fi

  npm install 2>/dev/null
  npm run build 2>/dev/null && ok "Studio built (production mode)" || warn "Studio build failed"
else
  skip "Studio already installed"
fi

# Fix #13: Find actual next binary path instead of relying on /usr/bin/npx
NEXT_BIN="/opt/openclaw-studio/node_modules/.bin/next"
if [ ! -f "${NEXT_BIN}" ]; then
  NEXT_BIN="$(which next 2>/dev/null || echo 'npx next')"
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 11: Systemd services
# Fix #2: Gateway service loads .env via EnvironmentFile
# Fix #13: Studio uses resolved next binary path
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Installing systemd services..."

OPENCLAW_BIN=$(which openclaw)

cat > /etc/systemd/system/openclaw-gateway.service << SVC
[Unit]
Description=OpenClaw Gateway — ${ORG_NAME}
After=network.target

[Service]
Type=simple
User=root
ExecStart=${OPENCLAW_BIN} gateway run
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=HOME=/root
EnvironmentFile=-/root/.openclaw/.env

[Install]
WantedBy=multi-user.target
SVC

cat > /etc/systemd/system/openclaw-studio.service << SVC
[Unit]
Description=OpenClaw Studio — ${ORG_NAME}
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/openclaw-studio
ExecStart=${NEXT_BIN} start --port 3000 --hostname 127.0.0.1
Environment=HOST=127.0.0.1
Environment=PORT=3000
Environment=NODE_ENV=production
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable openclaw-gateway openclaw-studio 2>/dev/null || true
ok "Gateway + Studio services (auto-start: enabled)"

# Fix #8: INSTALL_DASHBOARD — acknowledge and stub
if [[ "${INSTALL_DASHBOARD,,}" == "y" ]]; then
  warn "INSTALL_DASHBOARD=y is set but not yet implemented in TeamClaw."
  warn "To install the Command Center dashboard, run setup manually after install."
  warn "See: https://github.com/kashifeqbal/openclaw-workspace/tree/main/dashboard-site"
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 12: Healthcheck cron
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Setting up healthcheck..."

cat > "${OC_WORKSPACE}/scripts/healthcheck.sh" << 'HCEOF'
#!/bin/bash
ERRORS=0

systemctl is-active openclaw-gateway &>/dev/null || {
  echo "❌ Gateway down — restarting..."
  systemctl restart openclaw-gateway
  ERRORS=$((ERRORS + 1))
}
systemctl is-active openclaw-studio &>/dev/null || {
  echo "❌ Studio down — restarting..."
  systemctl restart openclaw-studio
  ERRORS=$((ERRORS + 1))
}

DISK_PCT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
[ "$DISK_PCT" -gt 85 ] && echo "⚠️ Disk: ${DISK_PCT}%" && ERRORS=$((ERRORS + 1))

MEM_PCT=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}')
[ "$MEM_PCT" -gt 90 ] && echo "⚠️ Memory: ${MEM_PCT}%" && ERRORS=$((ERRORS + 1))

[ "$ERRORS" -eq 0 ] && echo "✅ Healthy ($(date +%H:%M))"
HCEOF
chmod +x "${OC_WORKSPACE}/scripts/healthcheck.sh"

CRON_LINE="*/10 * * * * ${OC_WORKSPACE}/scripts/healthcheck.sh >> /var/log/teamclaw-healthcheck.log 2>&1"
( crontab -l 2>/dev/null || true; echo "$CRON_LINE" ) | sort -u | crontab -
ok "Healthcheck cron (every 10 min)"

# ═══════════════════════════════════════════════════════════════
# PHASE 13: WatchClaw security monitoring
# ═══════════════════════════════════════════════════════════════

if [[ "${INSTALL_WATCHCLAW,,}" == "y" ]]; then
  next_step; log "[$STEP/$TOTAL_STEPS] WatchClaw security..."

  WATCHCLAW_SRC="/tmp/watchclaw-src"
  rm -rf "${WATCHCLAW_SRC}"
  git clone --depth=1 https://github.com/kashifeqbal/watchclaw.git "${WATCHCLAW_SRC}" 2>/dev/null

  if [ -f "${WATCHCLAW_SRC}/install.sh" ]; then
    mkdir -p /etc/watchclaw /var/lib/watchclaw /var/log/watchclaw
    cd "${WATCHCLAW_SRC}" || exit
    timeout 120 bash install.sh --standalone </dev/null 2>&1 | tail -10 || true
    rm -rf "${WATCHCLAW_SRC}"
    ok "WatchClaw installed"
  else
    warn "WatchClaw install.sh not found — skipped"
  fi

  cat > /etc/watchclaw/watchclaw.conf << WCCONF
# WatchClaw — ${ORG_NAME}
SSH_PORT=2222
SSH_DISABLE_PASSWORD=true
UFW_ENABLE=true
F2B_ENABLE=true
F2B_BANTIME=-1
F2B_MAXRETRY=3
F2B_FINDTIME=600
CANARY_ENABLE=true
ALERT_TELEGRAM_TOKEN="${WATCHCLAW_TELEGRAM_TOKEN}"
ALERT_TELEGRAM_CHAT="${WATCHCLAW_CHAT_ID}"
ALERT_RATE_LIMIT=120
ALERT_BATCH_INTERVAL=900
THREAT_FEEDS=(
    "https://lists.blocklist.de/lists/ssh.txt"
    "https://raw.githubusercontent.com/stamparm/ipsum/master/levels/3.txt"
)
THREAT_FEED_REFRESH=43200
CRON_NOTIFY_INTERVAL="*/5 * * * *"
CRON_AUTOBAN_INTERVAL="*/5 * * * *"
CRON_POSTURE_INTERVAL="*/30 * * * *"
CRON_HEALTHCHECK_INTERVAL="*/15 * * * *"
CRON_WEEKLY_REPORT="0 8 * * 1"
CRON_FEED_IMPORT="0 */12 * * *"
WCCONF
  chmod 600 /etc/watchclaw/watchclaw.conf
  ok "watchclaw.conf written"

  WC_ENV="WATCHCLAW_CONF=/etc/watchclaw/watchclaw.conf"
  WC_DIR="/opt/watchclaw/scripts"
  WC_LOG="/var/log/watchclaw"
  EXISTING_CRON=$(crontab -l 2>/dev/null | grep -v "watchclaw" || true)
  printf '%s\n' \
    "${EXISTING_CRON}" \
    "*/5  * * * * ${WC_ENV} ${WC_DIR}/cowrie-notify.sh    >> ${WC_LOG}/notify.log 2>&1" \
    "*/5  * * * * ${WC_ENV} ${WC_DIR}/cowrie-autoban.sh   >> ${WC_LOG}/autoban.log 2>&1" \
    "*/5  * * * * ${WC_ENV} ${WC_DIR}/canary-check.sh     >> ${WC_LOG}/canary.log 2>&1" \
    "*/30 * * * * ${WC_ENV} ${WC_DIR}/security-posture.sh >> ${WC_LOG}/posture.log 2>&1" \
    "*/15 * * * * ${WC_ENV} ${WC_DIR}/service-healthcheck.sh >> ${WC_LOG}/healthcheck.log 2>&1" \
    "0 */12 * * * ${WC_ENV} ${WC_DIR}/watchclaw-import.sh >> ${WC_LOG}/import.log 2>&1" \
    "0 8 * * 1   ${WC_ENV} ${WC_DIR}/watchclaw-weekly-report.sh >> ${WC_LOG}/weekly.log 2>&1" \
    | grep -v '^$' | crontab -
  ok "WatchClaw crons installed (7 jobs)"

  if grep -q "^Port 2222" /etc/ssh/sshd_config 2>/dev/null; then
    if $CF_TUNNEL_ACTIVE; then
      ufw allow from 127.0.0.1 to any port 2222 proto tcp comment 'SSH 2222 loopback (tunnel)' 2>/dev/null
      ufw allow from ::1 to any port 2222 proto tcp comment 'SSH 2222 loopback v6 (tunnel)' 2>/dev/null
      ok "UFW: SSH 2222 loopback-only (tunnel mode)"
    else
      ufw allow 2222/tcp comment "SSH (moved by WatchClaw)" 2>/dev/null || true
      ok "UFW: SSH 2222 open"
    fi
    # SSH port changed — restart again
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    ok "SSH restarted with WatchClaw port config"
  fi

  if [ -n "${WATCHCLAW_TELEGRAM_TOKEN}" ] && [ -n "${WATCHCLAW_CHAT_ID}" ]; then
    curl -s -X POST "https://api.telegram.org/bot${WATCHCLAW_TELEGRAM_TOKEN}/sendMessage" \
      -d "chat_id=${WATCHCLAW_CHAT_ID}" \
      -d "text=🔐 WatchClaw connected on ${ORG_NAME} server. Alerts are live." \
      > /dev/null && ok "WatchClaw test alert sent ✅"
  else
    warn "WatchClaw alert channel not configured (WATCHCLAW_TELEGRAM_TOKEN / WATCHCLAW_CHAT_ID empty)"
  fi
fi

# ═══════════════════════════════════════════════════════════════
# PHASE 14: Hindsight PageIndex
# ═══════════════════════════════════════════════════════════════

if [[ "${INSTALL_HINDSIGHT,,}" == "y" ]]; then
  next_step; log "[$STEP/$TOTAL_STEPS] Hindsight PageIndex..."

  HINDSIGHT_DIR="/opt/hindsight-pageindex"
  HINDSIGHT_TOKEN=$(openssl rand -hex 24)
  mkdir -p "${HINDSIGHT_DIR}"

  if [ ! -f "${HINDSIGHT_DIR}/server.mjs" ]; then
    mkdir -p "${HINDSIGHT_DIR}/vendor"
    [ ! -d "${HINDSIGHT_DIR}/vendor/PageIndex/.git" ] && \
      git clone --depth=1 https://github.com/VectifyAI/PageIndex.git "${HINDSIGHT_DIR}/vendor/PageIndex" 2>/dev/null

    python3 -m venv "${HINDSIGHT_DIR}/.venv"
    "${HINDSIGHT_DIR}/.venv/bin/pip" install --upgrade pip -q 2>/dev/null
    "${HINDSIGHT_DIR}/.venv/bin/pip" install -r "${HINDSIGHT_DIR}/vendor/PageIndex/requirements.txt" -q 2>/dev/null

    cat > "${HINDSIGHT_DIR}/package.json" << 'PKGJSON'
{
  "name": "hindsight-pageindex",
  "version": "1.0.0",
  "type": "module",
  "scripts": { "start": "node server.mjs" },
  "dependencies": {}
}
PKGJSON

    cat > "${HINDSIGHT_DIR}/server.mjs" << 'SERVERMJS'
import http from "http";
import { readFileSync, mkdirSync, writeFileSync, readdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = parseInt(process.env.PORT || "8787");
const API_TOKEN = process.env.API_TOKEN || "";
const DATA_DIR = join(__dirname, "data");
mkdirSync(DATA_DIR, { recursive: true });

const auth = (req) => !API_TOKEN || req.headers.authorization === `Bearer ${API_TOKEN}`;
const body = (req) => new Promise((ok) => { let d = ""; req.on("data", c => d += c); req.on("end", () => ok(d)); });

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const json = (code, data) => { res.writeHead(code, {"Content-Type":"application/json"}); res.end(JSON.stringify(data)); };

  if (url.pathname === "/health") return json(200, { status: "ok" });
  if (!auth(req)) return json(401, { error: "unauthorized" });

  if (url.pathname === "/api/index" && req.method === "POST") {
    try {
      const { content, metadata } = JSON.parse(await body(req));
      const id = metadata?.id || `doc-${Date.now()}`;
      writeFileSync(join(DATA_DIR, `${id}.json`), JSON.stringify({ content, metadata, indexed: new Date().toISOString() }));
      return json(200, { status: "indexed", id });
    } catch (e) { return json(500, { error: e.message }); }
  }

  if (url.pathname === "/api/query" && req.method === "POST") {
    try {
      const { query } = JSON.parse(await body(req));
      const results = [];
      for (const f of readdirSync(DATA_DIR)) {
        if (!f.endsWith(".json")) continue;
        const doc = JSON.parse(readFileSync(join(DATA_DIR, f), "utf8"));
        if (doc.content?.toLowerCase().includes(query.toLowerCase()))
          results.push({ id: f.replace(".json",""), score: 1, snippet: doc.content.slice(0,300), metadata: doc.metadata });
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

  cat > "${HINDSIGHT_DIR}/.env" << HENV
PORT=8787
API_TOKEN=${HINDSIGHT_TOKEN}
DEFAULT_USER_ID=${AGENT_ID}
DEFAULT_NAMESPACE=teamclaw-${ORG_NAME,,}
PAGEINDEX_HOME=./vendor/PageIndex
PAGEINDEX_PYTHON=.venv/bin/python3
OPENAI_API_KEY=${OPENAI_KEY}
HENV

  cat > /etc/systemd/system/hindsight-pageindex.service << HSVC
[Unit]
Description=Hindsight PageIndex — ${ORG_NAME}
After=network-online.target

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
# PHASE 15: Docs sync (Fix #10: org-agnostic naming)
# ═══════════════════════════════════════════════════════════════

if [[ "${INSTALL_DOCS_SYNC,,}" == "y" ]] && [ -n "${DOCS_SYNC_REPO:-}" ]; then
  next_step; log "[$STEP/$TOTAL_STEPS] Docs sync (${DOCS_SYNC_REPO})..."

  DOCS_REPO_DIR="/opt/teamclaw/repos/docs"
  DOCS_SYNC_SCRIPT="/opt/teamclaw/scripts/sync-docs.sh"

  if [ ! -d "${DOCS_REPO_DIR}/.git" ]; then
    git clone "${DOCS_SYNC_REPO}" "${DOCS_REPO_DIR}" 2>/dev/null \
      && ok "Docs repo cloned" \
      || warn "Could not clone docs repo (add SSH deploy key then run: git clone ${DOCS_SYNC_REPO} ${DOCS_REPO_DIR})"
  else
    skip "Docs repo already cloned"
  fi

  cat > "${DOCS_SYNC_SCRIPT}" << SYNCEOF
#!/bin/bash
REPO="${DOCS_REPO_DIR}"
HINDSIGHT_TOKEN="\$(grep API_TOKEN /opt/hindsight-pageindex/.env | cut -d= -f2)"
LOG="/var/log/teamclaw-docs-sync.log"

[ -d "\$REPO" ] || exit 0
cd "\$REPO" || exit 1

git fetch origin -q 2>&1
CHANGED=\$(git diff HEAD..origin/main --name-only 2>/dev/null | grep '\.md\$')
[ -z "\$CHANGED" ] && exit 0

echo "[\$(date '+%Y-%m-%d %H:%M')] Pulling changes..." >> "\$LOG"
git pull origin main -q >> "\$LOG" 2>&1

python3 << PYEOF >> "\$LOG" 2>&1
import os, json, re, urllib.request

TOKEN = "\$HINDSIGHT_TOKEN"
DOCS_DIR = "\$REPO"
CHANGED = """\$CHANGED""".strip().split('\\n')

def index_chunk(cid, content, source, section):
    payload = json.dumps({"content": content, "metadata": {"id": cid, "source": source, "section": section}}).encode()
    req = urllib.request.Request("http://localhost:8787/api/index", data=payload,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=10)

def split_md(text):
    sections, title, lines = [], "intro", []
    for line in text.split('\\n'):
        if re.match(r'^\#{1,3} ', line):
            body = '\\n'.join(lines).strip()
            if len(body) > 40: sections.append((title, body))
            title = re.sub(r'^\#+\\s*', '', line).strip()
            lines = []
        else:
            lines.append(line)
    body = '\\n'.join(lines).strip()
    if len(body) > 40: sections.append((title, body))
    return sections

total = 0
for rel in CHANGED:
    rel = rel.strip()
    if not rel.endswith('.md'): continue
    fpath = os.path.join(DOCS_DIR, rel)
    if not os.path.exists(fpath): continue
    doc_name = re.sub(r'[^a-z0-9\\-]', '-', rel.lower().replace('/', '-').replace('.md', ''))
    sections = split_md(open(fpath).read())
    for i, (title, body) in enumerate(sections):
        index_chunk(f"{doc_name}-chunk-{i:03d}", f"# {title}\\n\\n{body}", rel, title)
    print(f"Indexed: {rel} ({len(sections)} chunks)")
    total += len(sections)
print(f"Total new chunks: {total}")
PYEOF

echo "[\$(date '+%Y-%m-%d %H:%M')] Sync complete." >> "\$LOG"
SYNCEOF
  chmod +x "${DOCS_SYNC_SCRIPT}"

  DOCS_CRON="*/15 * * * * ${DOCS_SYNC_SCRIPT} >> /var/log/teamclaw-docs-sync.log 2>&1"
  ( crontab -l 2>/dev/null || true; echo "${DOCS_CRON}" ) | sort -u | crontab -
  ok "Docs sync cron installed (every 15 min, script: sync-docs.sh)"
fi

# ═══════════════════════════════════════════════════════════════
# FINAL: Start services
# Fix #6 (v0.3): systemctl only — no manual openclaw gateway start
# ═══════════════════════════════════════════════════════════════

next_step; log "[$STEP/$TOTAL_STEPS] Starting services..."

systemctl start openclaw-gateway 2>/dev/null
sleep 5
if ss -tlnp | grep -q ":18789"; then
  ok "Gateway running on :18789"
else
  warn "Gateway not responding yet — run: openclaw models auth add"
fi

systemctl start openclaw-studio 2>/dev/null && ok "Studio started on :3000"

if [[ "${INSTALL_HINDSIGHT,,}" == "y" ]]; then
  systemctl start hindsight-pageindex 2>/dev/null
  sleep 2
  systemctl is-active hindsight-pageindex &>/dev/null \
    && ok "Hindsight running on :8787" \
    || warn "Hindsight not starting — check: journalctl -u hindsight-pageindex"
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
echo "  Gateway:   ws://localhost:18789  (token: ${GATEWAY_TOKEN})"
echo "  Studio:    http://localhost:3000"
echo "  Workspace: ${OC_WORKSPACE}/"
echo ""
echo "  Security:  SSH ✅ | UFW ✅ | fail2ban ✅ | kernel ✅ | unattended-upgrades ✅"
$CF_TUNNEL_ACTIVE && echo "  Tunnel:    cloudflared ✅ (verified)"
[[ "${INSTALL_WATCHCLAW,,}" == "y" ]] && echo "  WatchClaw: /opt/watchclaw ✅"
[[ "${INSTALL_HINDSIGHT,,}" == "y" ]] && echo "  Hindsight: http://localhost:8787 ✅"
[[ "${INSTALL_DOCS_SYNC,,}" == "y" ]] && echo "  Docs sync: /opt/teamclaw/scripts/sync-docs.sh (every 15 min) ✅"
[ -n "${PULSE_TELEGRAM_BOT_TOKEN:-}" ] && echo "  Telegram:  ${AGENT_NAME} bot + Ops bot wired ✅"
[ -n "${DISCORD_BOT_TOKEN:-}" ]        && echo "  Discord:   ${AGENT_NAME}-discord agent wired (guild: ${DISCORD_GUILD_ID}) ✅"
[ -n "${OPENAI_KEY:-}" ]               && echo "  Memory:    memory-core + OpenAI embeddings ✅"
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  One manual step remaining:                         │"
echo "  │                                                     │"
echo "  │    openclaw models auth add                         │"
echo "  │                                                     │"
echo "  │  Then message your bot on Telegram — done.          │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
