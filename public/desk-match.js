// Desk position matching — the ONE place a screen card is tied to an armed
// position.
//
// The key is the MINT ADDRESS, never the symbol. pump.fun symbols collide
// routinely — two live TOADs on different mints, GORT IV twice in one capture
// (board row 90) — and a symbol match lit Force Sell on every card sharing the
// name. A user tapping the wrong sibling would be acting on a control the
// interface told them applied to their position.
//
// Fallback is the exact card id, and only when one side carries no mint
// (preview/demo rows). The symbol is not consulted on any path.
//
// Loaded by public/index.html as a plain script (window.DeskMatch) and by
// keeper/test/desk-match.test.js under node (module.exports) so the test
// exercises this exact code, not a copy of it.
(function (root, factory) {
  var api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.DeskMatch = api;
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  function mintOf(x) { return String((x && x.mint) || "").toLowerCase(); }
  function addrOf(c) { return String((c && c.addr) || "").toLowerCase(); }

  // True when armed position p belongs to screen card `coin` (or, when the
  // card has already left the screen, to the tapped card id).
  function armedMatch(p, coin, tappedId) {
    if (!p || p.state !== "armed") return false;
    var pk = mintOf(p), ck = addrOf(coin);
    if (pk && ck) return pk === ck;          // both sides carry a mint: it decides
    if (coin) return p.id === coin.id;       // no mint on a side: exact id only
    return tappedId != null && p.id === tappedId;
  }

  return {
    armedMatch: armedMatch,
    hasPos: function (positions, coin) {
      return (positions || []).some(function (p) { return armedMatch(p, coin, null); });
    },
    findArmed: function (positions, coin, tappedId) {
      return (positions || []).filter(function (p) { return armedMatch(p, coin, tappedId); })[0] || null;
    }
  };
});
