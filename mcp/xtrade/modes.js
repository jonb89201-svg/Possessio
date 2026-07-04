// RULEBOOK Sec4 - execution model. build is always on; hot needs 3 gates.
"use strict";

// Resolve the effective execution mode for a call. NEVER throws on a
// hot request - it DOWNGRADES to build (the safe payload), because the
// rulebook's rule is "missing any gate -> return the build payload".
function resolveMode(requested, rt, confirm) {
  if (requested !== "hot") return { mode: "build" };

  const gates = {
    allowHot: rt.allowHot === true,     // gate 1: ALLOW_HOT=1
    hasSigner: rt.hasSigner === true,   // gate 2: signer key configured
    confirmed: confirm === true,        // gate 3: explicit confirm on THIS call
  };
  const missing = Object.entries(gates)
    .filter(([, ok]) => !ok)
    .map(([k]) => k);

  if (missing.length === 0) return { mode: "hot", gates };
  return {
    mode: "build",
    downgraded: true,
    missing,
    reason:
      "hot mode refused (missing: " + missing.join(", ") +
      "). Returning unsigned build payload - the Architect signs.",
  };
}

module.exports = { resolveMode };
