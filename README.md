# TeamClaw

OpenClaw for teams — one-command setup for a production-ready agent stack on Ubuntu.

## What it sets up
- OpenClaw Gateway (systemd)
- OpenClaw Studio
- Optional: Hindsight PageIndex
- Optional: WatchClaw security + Telegram alert channel
- Optional: Cloudflare tunnel wiring
- Security baseline: SSH hardening, UFW, fail2ban, kernel sysctl hardening

## Quick start
```bash
curl -fsSL https://raw.githubusercontent.com/kashifeqbal/teamclaw/main/setup-org.sh -o setup-org.sh
bash setup-org.sh
```

## Config mode
```bash
cp team.env.example team.env
# edit values
bash setup-org.sh --config team.env
```

## Notes
- Runs as `root` (no separate openclaw user)
- Gateway bind defaults to `loopback`
- Claude auth is still manual after install:
  - `openclaw models auth add`
