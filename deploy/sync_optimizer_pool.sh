#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync_optimizer_pool.sh — the optimizer pool's engine.
#
# The optimizer runs are HARDCODED PER CONTRACT in foundry.toml via
# [[profile.default.compilation_restrictions]], so ONE `forge build` produces
# every contract at its fixed setting. This script builds once, then records
# for each contract in deploy/optimizer_pool.json:
#   · init_codehash      = keccak256(creation bytecode)  ← the value a codehash
#                          factory (PossessioFactory) pins as templateCodehash
#   · deployed_codehash  = keccak256(runtime bytecode)
#   · runtime_bytes      = deployed size (vs the 24576 EIP-170 wall)
#
# This is what keeps (optimizer runs ↔ artifact ↔ codehash) from ever drifting
# by hand. Change a contract's runs in foundry.toml → re-run this → the codehash
# updates → re-pin any factory that references it. Requires: forge, cast, jq.
# Run from repo root:  bash deploy/sync_optimizer_pool.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

MANIFEST="deploy/optimizer_pool.json"   # INTERNAL — never served publicly
LIMIT=$(jq -r '.eip170_limit_bytes' "$MANIFEST")

command -v forge >/dev/null || { echo "forge not found — install Foundry (foundryup)"; exit 1; }
command -v cast  >/dev/null || { echo "cast not found — it ships with Foundry (run: foundryup). Needed to keccak256 the bytecode."; exit 1; }
command -v jq    >/dev/null || { echo "jq not found — apt-get install jq / brew install jq"; exit 1; }

# 1. Build once — compilation_restrictions in foundry.toml pins each contract's
#    optimizer runs automatically, all into out/.
echo "▸ forge build (per-contract optimizer runs hardcoded in foundry.toml)…"
forge build >/dev/null

# 2. Hash each contract's bytecode from out/; write back.
tmp="$(mktemp)"; cp "$MANIFEST" "$tmp"
n=$(jq '.contracts | length' "$tmp")
echo ""
printf "%-22s %-6s %-8s %-10s %s\n" "CONTRACT" "RUNS" "CHAIN" "RUNTIME" "INIT_CODEHASH (pin this)"
printf "%-22s %-6s %-8s %-10s %s\n" "────────" "────" "─────" "───────" "────────────────────────"

for i in $(seq 0 $((n-1))); do
  name=$(jq -r ".contracts[$i].name"          "$tmp")
  file=$(jq -r ".contracts[$i].file"          "$tmp")
  runs=$(jq -r ".contracts[$i].optimizer_runs" "$tmp")
  art="out/$(basename "$file")/$name.json"

  if [ ! -f "$art" ]; then
    printf "%-22s %-6s %-8s %-10s %s\n" "$name" "$runs" "-" "-" "⚠ MISSING $art"
    continue
  fi

  init=$(jq -r '.bytecode.object'          "$art")
  run=$(jq  -r '.deployedBytecode.object'  "$art")
  # Empty object (e.g. abstract/interface) → skip hashing.
  if [ "$init" = "null" ] || [ -z "$init" ] || [ "$init" = "0x" ]; then
    printf "%-22s %-6s %-8s %-10s %s\n" "$name" "$runs" "-" "-" "⚠ no bytecode (abstract/interface?)"
    continue
  fi

  ih=$(cast keccak "$init")
  dh=$(cast keccak "$run")
  bytes=$(( (${#run} - 2) / 2 ))
  chain=$(jq -r ".contracts[$i].chain" "$tmp")

  warn=""
  if [ "$bytes" -gt "$LIMIT" ]; then warn=" ✗ OVER 24KB — WILL NOT DEPLOY"; fi

  jq  ".contracts[$i].init_codehash=\"$ih\" \
     | .contracts[$i].deployed_codehash=\"$dh\" \
     | .contracts[$i].runtime_bytes=$bytes" "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"

  printf "%-22s %-6s %-8s %-10s %s%s\n" "$name" "$runs" "$chain" "${bytes}B" "${ih:0:18}…" "$warn"
done

mv "$tmp" "$MANIFEST"
echo ""
echo "✓ optimizer pool synced → $MANIFEST"
echo "  headroom vs EIP-170: 24576 B. Anything flagged OVER must drop to fewer runs in foundry.toml."
echo "  Codehash-pattern factories pin the init_codehash — freeze the template's runs before deploying its factory."
