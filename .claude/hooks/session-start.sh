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

# ── 2. forge — REPORTED, NOT INSTALLED. Measured 2026-08-01: this
#       environment's egress policy returns 403 for BOTH api.github.com and
#       github.com, and foundryup needs the first to resolve a release tag and
#       the second to download. So foundry cannot be installed here at all.
#       /root/.ccr/README.md is explicit: a 403 is an org policy denial —
#       "Do not retry or route around it — report the blocked host."
#
#       Attempting it anyway would burn ~30s of every session start to fail the
#       same way, so this checks and STATES THE BOUND instead. A seat that knows
#       at second zero that the Solidity suite is unrunnable will route it to
#       the Architect's terminal; a seat that does not will reason from the diff
#       and call it verified. That happened on 2026-08-01.
if [ -f foundry.toml ]; then
  export PATH="$HOME/.foundry/bin:$PATH"
  if command -v forge >/dev/null 2>&1; then
    echo "forge     $(forge --version 2>/dev/null | head -1)"
    echo "export PATH=\"\$HOME/.foundry/bin:\$PATH\"" >> "${CLAUDE_ENV_FILE:-/dev/null}" 2>/dev/null
  else
    SUITES=$(ls test/*.t.sol 2>/dev/null | wc -l | tr -d ' ')
    echo "forge     UNAVAILABLE — github.com is 403 under this egress policy, so"
    echo "          foundry cannot be installed. The $SUITES .t.sol suites CANNOT be"
    echo "          run in this session. Solidity changes are UNVERIFIED here and"
    echo "          must be built and tested in the Architect's terminal."
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
echo "CLAUDE.md is the job listing. laws/MIB.md is Codebyte Law."
echo "laws/PHYSICS_of_execution.md maps THIS environment — read it early."
echo "Merging to main is a production deploy. Migrations, deploys, board posts"
echo "and outward-facing sends need Architect ratification."
echo "───────────────────────────────────────────────────────────────────"
