#!/bin/bash
# POSSESSIO — SessionStart hook.
#
# TWO JOBS, and the second is the reason it exists.
#
# 1. Make the suites runnable. A fresh container has no node_modules and no
#    forge, so the repo's PRIMARY test suite (54 .t.sol files) is unrunnable
#    until this runs. A seat that cannot run the tests cannot obey the Prime
#    Directive, and will reason from the diff instead — which is what happened
#    on 2026-08-01 and is recorded in laws/PHYSICS_of_execution.md.
#
# 2. PROPRIOCEPTION. CLAUDE.md is instruction: it loads, and then depends on the
#    occupant honouring it. This hook EXECUTES. It cannot stop a bad action, but
#    it puts the true state into context BEFORE the first action, so no seat can
#    claim it did not know. That is a gate on ignorance rather than on the act —
#    the only mechanical tier available at session start.
#
# NOT -e on purpose: a red suite or a missing tool must be REPORTED, never
# allowed to abort the hook. A hook that dies on a failing test hides the
# failing test, which is the exact defect class this protocol keeps closing.
set -uo pipefail

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}" || exit 0

echo "─── POSSESSIO session start ───────────────────────────────────────"

# ── 1. node deps — required by `npm test` ─────────────────────────────
if [ -f package.json ]; then
  npm install --no-audit --no-fund --silent >/dev/null 2>&1 \
    && echo "deps      node_modules ready" \
    || echo "deps      npm install FAILED — 'npm test' will not run"
fi

# ── 2. forge — REPORTED, NOT INSTALLED. foundryup fetches foundry.paradigm.xyz
#       (NOT allowlisted) so the INSTALLER fails here — but that is the front
#       door, not the tool. Board row 87 (Tare, MEASURED 2026-08-09): Foundry
#       and solc ship their binaries as github.com release assets, which ARE
#       allowlisted, so a CLEAN chat seat can install and run the OFFLINE
#       suites. The hook does not auto-install (untested per session, and a
#       seat that has handled key material has its bash blocked) — it states
#       the bound and points at the sequence. A seat that knows at second zero
#       whether Solidity is judgeable here will route correctly; a seat that
#       reasons from the diff and calls it verified is the 2026-08-01 defect.
if [ -f foundry.toml ]; then
  export PATH="$HOME/.foundry/bin:/tmp/fbin:$PATH"
  if command -v forge >/dev/null 2>&1; then
    echo "forge     $(forge --version 2>/dev/null | head -1)"
    echo "export PATH=\"\$HOME/.foundry/bin:/tmp/fbin:\$PATH\"" >> "${CLAUDE_ENV_FILE:-/dev/null}" 2>/dev/null
  else
    SUITES=$(ls test/*.t.sol 2>/dev/null | wc -l | tr -d ' ')
    echo "forge     not preinstalled. foundryup's CDN (foundry.paradigm.xyz) is"
    echo "          blocked here, but the BINARIES are reachable: github.com release"
    echo "          assets are allowlisted (board row 87, Tare, MEASURED 2026-08-09)."
    echo "          A CLEAN seat can install forge+solc from GitHub releases and run"
    echo "          the $SUITES .t.sol OFFLINE suites here; fork tests + broadcast still"
    echo "          need the Architect's terminal (RPC egress blocked), and nothing in"
    echo "          a chat seat CERTIFIES. Until installed, Solidity here is UNJUDGED —"
    echo "          see board row 87 for the exact sequence."
  fi
fi

# ── 3. WHERE YOU ACTUALLY ARE ─────────────────────────────────────────
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
HEAD=$(git log --oneline -1 2>/dev/null || echo "?")
DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
AHEAD=$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo "?")

echo "branch    $BRANCH"
echo "head      $HEAD"
[ "$DIRTY" != "0" ] && echo "tree      $DIRTY uncommitted file(s) — nothing is finished until it is pushed"
[ "$AHEAD" != "0" ] && [ "$AHEAD" != "?" ] && echo "unpushed  $AHEAD commit(s) ahead of origin"

# ── 4. THE SUITE — reported, never assumed ────────────────────────────
if [ -f package.json ] && grep -q '"test"' package.json 2>/dev/null; then
  OUT=$(npm test 2>&1)
  if [ $? -eq 0 ]; then
    echo "npm test  $(echo "$OUT" | grep -cE '^  PASS') passed, exit 0"
  else
    echo "npm test  *** FAILING *** — a red suite cannot distinguish a new break from the old one"
    echo "$OUT" | grep -E '^  FAIL' | head -5
  fi
fi

echo
echo "FIRST MOVE — READ THE BOARD. The Possessio Council connector is the only"
echo "wall-less memory: any instance, any session, no repo checkout required."
echo "Before you touch anything: council_read_feed for the latest, council_search"
echo "for a topic ('forge', 'keeper', an address). The board is a SELF-CORRECTING"
echo "canon — a row's corrections hang off it by ref, so council_read_thread on a"
echo "status row returns current truth with supersessions included. The repo is"
echo "doctrine + code; the BOARD is what is true right now. Trust a repo file only"
echo "after the board has not corrected it. (This hook itself was wrong about forge"
echo "until board row 87 — check the board before repeating anything it prints.)"
echo
echo "CLAUDE.md is the job listing. laws/MIB.md is Codebyte Law."
echo "laws/CANON_of_the_terminal.md is the rule of practice for AI seats."
echo "laws/PHYSICS_of_execution.md maps THIS environment — read it early."
echo "Merging to main is a production deploy. Migrations, deploys, board posts"
echo "and outward-facing sends need Architect ratification."
echo "───────────────────────────────────────────────────────────────────"
