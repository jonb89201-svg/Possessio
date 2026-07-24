#!/usr/bin/env bash
# Council Signer — remote MCP deploy runner (SPEC_CouncilSigner_v3).
#
# Run this from a terminal on the HOST that will hold the seat (a GitHub
# Codespace, a VPS, anywhere with Node >= 20). It preflights the secrets
# fail-closed, installs deps, and starts the bearer-gated remote server. In a
# Codespace it also prints the exact public HTTPS URL to paste into claude.ai.
#
# It NEVER echoes the seat key. It reads every secret from the environment — put
# nothing secret in this file, and never commit a filled-in one.
#
#   export COUNCIL_SEAT_KEY=0x...        # this seat's 32-byte key (host env ONLY)
#   export COUNCIL_HOOK_ADDRESS=0x...    # the bound PossessioHook / V3 address
#   export COUNCIL_MCP_TOKEN=$(openssl rand -hex 32)   # the bearer (different secret)
#   ./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"

# Defaults for the non-secret knobs. Base mainnet, the live ledger, loopback bind.
export COUNCIL_CHAIN_ID="${COUNCIL_CHAIN_ID:-8453}"
export COUNCIL_RPC_URL="${COUNCIL_RPC_URL:-https://mainnet.base.org}"
export COUNCIL_LEDGER_URL="${COUNCIL_LEDGER_URL:-https://possessio.io/api/council/ledger}"
export COUNCIL_MCP_PATH="${COUNCIL_MCP_PATH:-/mcp}"
PORT="${PORT:-${COUNCIL_MCP_PORT:-8787}}"
export PORT

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── Preflight: fail closed on any missing secret, mirroring auth.js/config.js ──
say "Preflight — checking the three secrets (values are never printed)…"
missing=()
[ -n "${COUNCIL_SEAT_KEY:-}" ]     || missing+=("COUNCIL_SEAT_KEY   (this seat's 0x… 32-byte key)")
[ -n "${COUNCIL_HOOK_ADDRESS:-}" ] || missing+=("COUNCIL_HOOK_ADDRESS (the bound hook / V3 address)")
[ -n "${COUNCIL_MCP_TOKEN:-}" ]    || missing+=("COUNCIL_MCP_TOKEN   (the bearer; \`openssl rand -hex 32\`)")
if [ "${#missing[@]}" -gt 0 ]; then
  printf 'Set these first, then re-run:\n'; for m in "${missing[@]}"; do printf '  • %s\n' "$m"; done
  fail "missing environment ($(( ${#missing[@]} )) unset)"
fi
# Shape checks that don't reveal the value.
[[ "$COUNCIL_SEAT_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] || fail "COUNCIL_SEAT_KEY must be 0x + 64 hex chars."
[[ "$COUNCIL_HOOK_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail "COUNCIL_HOOK_ADDRESS must be a 0x address."
[ "${#COUNCIL_MCP_TOKEN}" -ge 32 ] || fail "COUNCIL_MCP_TOKEN must be ≥ 32 chars (use \`openssl rand -hex 32\`)."
printf '  ✓ all three present and well-formed\n'

# ── Node + deps ──
command -v node >/dev/null 2>&1 || fail "Node.js not found — install Node ≥ 20."
node_major="$(node -p 'process.versions.node.split(".")[0]')"
[ "$node_major" -ge 20 ] || fail "Node ≥ 20 required (found $(node -v))."
say "Installing dependencies (npm ci if a lockfile exists, else npm install)…"
if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; else npm install --no-audit --no-fund; fi

# ── Where claude.ai will reach it ──
if [ -n "${CODESPACE_NAME:-}" ] && [ -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]; then
  URL="https://${CODESPACE_NAME}-${PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}${COUNCIL_MCP_PATH}"
  say "Codespace detected. Your connector URL will be:"
  printf '  %s\n' "$URL"
  printf '\n  IMPORTANT: in the PORTS tab, set port %s visibility to PUBLIC, or\n' "$PORT"
  printf '  claude.ai will get a GitHub login page instead of your server.\n'
  printf '  (CLI: gh codespace ports visibility %s:public -c "$CODESPACE_NAME")\n' "$PORT"
else
  say "Not a Codespace. Front this with TLS (reverse proxy / tunnel); the public URL is:"
  printf '  https://<your-host>%s\n' "$COUNCIL_MCP_PATH"
fi
printf '\nIn claude.ai → Settings → Connectors → Add custom connector:\n'
printf '  • URL:    the https URL above\n'
printf '  • Header: Authorization: Bearer <your COUNCIL_MCP_TOKEN>\n'
printf '\nLiveness (no token, returns {ok:true} only):  curl -s http://127.0.0.1:%s/healthz\n' "$PORT"
printf 'Which seat (bearer-gated):  curl -s -H "Authorization: Bearer $COUNCIL_MCP_TOKEN" http://127.0.0.1:%s/whoami\n' "$PORT"

say "Starting the bearer-gated remote server (Ctrl-C to stop)…"
exec node remote.js
