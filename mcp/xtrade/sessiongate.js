// RULEBOOK Sec0 - Session Gate. Checked before ANY trade.
// Is right now a day worth playing at all? Relative volume, self-correcting.
"use strict";

// trailingVol: recent Solana meme/DEX volume (1-24h window).
// avg7d:       that window's own trailing 7-day average.
// cutoff:      TUNE.sessionGateCutoff (0.65 start; ~0.60-0.70 band).
// play=false -> sit out entirely, regardless of any single token.
function sessionGate({ trailingVol, avg7d }, cutoff) {
  const v = Number(trailingVol), a = Number(avg7d);
  if (!Number.isFinite(a) || a <= 0)
    return { play: false, reason: "no valid 7-day baseline", ratio: null, cutoff };
  if (!Number.isFinite(v) || v < 0)
    return { play: false, reason: "no valid trailing volume", ratio: null, cutoff };
  const ratio = v / a;
  const play = ratio >= cutoff;
  return {
    play,
    ratio,
    cutoff,
    reason: play
      ? `ambient volume ${(ratio * 100).toFixed(0)}% of 7d avg >= ${(cutoff * 100).toFixed(0)}% - playable`
      : `ambient volume ${(ratio * 100).toFixed(0)}% of 7d avg < ${(cutoff * 100).toFixed(0)}% - sit out`,
  };
}

module.exports = { sessionGate };
