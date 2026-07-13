#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync_optimizer_pool.sh — the optimizer pool's engine.
#
# Compiles every contract in public/optimizer_pool.json under ITS profile
# (default / hot / l1 — each to its own out dir), then records:
#   · init_codehash      = keccak256(creation bytecode)  ← the value a codehash
#                          factory (PossessioFactory) pins as templateCodehash
#   · deployed_codehash  = keccak256(runtime bytecode)
#   · runtime_bytes      = deployed size (vs the 24576 EIP-170 wall)
#
# This is what keeps (optimizer runs ↔ artifact ↔ codehash) from ever drifting
# by hand. Change a profile → re-run this → the codehash updates → re-pin any
# factory that references it. Requires: forge, cast, jq.
# Run from repo root:  bash deploy/sync_optimizer_pool.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

MANIFEST="public/optimizer_pool.json"
LIMIT=$(jq -r '.eip170_limit_bytes' "$MANIFEST")

command -v forge >/dev/null || { echo "forge not found — install Foundry (foundryup)"; exit 1; }
command -v cast  >/dev/null || { echo "cast not found — it ships with Foundry (run: foundryup). Needed to keccak256 the bytecode."; exit 1; }
command -v jq    >/dev/null || { echo "jq not found — apt-get install jq / brew install jq"; exit 1; }

# 1. Build each profile once — each writes to its own out dir.
for prof in $(jq -r '.profiles | keys[]' "$MANIFEST"); do
  echo "▸ building profile '$prof' ($(jq -r ".profiles.\"$prof\".runs" "$MANIFEST") runs)…"
  FOUNDRY_PROFILE="$prof" forge build >/dev/null
done

# 2. Hash each contract's bytecode from the right out dir; write back.
tmp="$(mktemp)"; cp "$MANIFEST" "$tmp"
n=$(jq '.contracts | length' "$tmp")
echo ""
printf "%-22s %-9s %-8s %-10s %s\n" "CONTRACT" "PROFILE" "CHAIN" "RUNTIME" "INIT_CODEHASH (pin this)"
printf "%-22s %-9s %-8s %-10s %s\n" "────────" "───────" "─────" "───────" "────────────────────────"

for i in $(seq 0 $((n-1))); do
  name=$(jq -r ".contracts[$i].name"    "$tmp")
  file=$(jq -r ".contracts[$i].file"    "$tmp")
  prof=$(jq -r ".contracts[$i].profile" "$tmp")
  out=$(jq -r  ".profiles.\"$prof\".out" "$tmp")
  art="$out/$(basename "$file")/$name.json"

  if [ ! -f "$art" ]; then
    printf "%-22s %-9s %-8s %-10s %s\n" "$name" "$prof" "-" "-" "⚠ MISSING $art"
    continue
  fi

  init=$(jq -r '.bytecode.object'          "$art")
  run=$(jq  -r '.deployedBytecode.object'  "$art")
  # Empty object (e.g. abstract/interface) → skip hashing.
  if [ "$init" = "null" ] || [ -z "$init" ] || [ "$init" = "0x" ]; then
    printf "%-22s %-9s %-8s %-10s %s\n" "$name" "$prof" "-" "-" "⚠ no bytecode (abstract/interface?)"
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

  printf "%-22s %-9s %-8s %-10s %s%s\n" "$name" "$prof" "$chain" "${bytes}B" "${ih:0:18}…" "$warn"
done

mv "$tmp" "$MANIFEST"
echo ""
echo "✓ optimizer pool synced → $MANIFEST"
echo "  headroom vs EIP-170: 24576 B. Anything flagged OVER must drop to a lower-runs profile."
echo "  Codehash-pattern factories pin the init_codehash — freeze the template's profile before deploying its factory."
