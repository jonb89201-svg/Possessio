// possessio-radar — feed.ts: the public live-selection page.
// Polls /radar/candidates and renders. No data lives in this HTML; it's a
// shell. Honest framing is load-bearing: most picks fail BY DESIGN (§1's
// asymmetry), so the page says so — which is also the x402Core sales argument.

export const FEED_HTML = `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>POSSESSIO Radar — AI Live Selection</title>
<style>
  :root{--bg:#0b0f0c;--panel:#12181400;--ink:#d6e5da;--dim:#7d9488;--line:#1e2a23;
    --green:#3ddc84;--red:#ff5d5d;--gold:#e3a23e;--blue:#5aa9ff}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);
    font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;-webkit-font-smoothing:antialiased}
  .wrap{max-width:760px;margin:0 auto;padding:18px 14px 60px}
  h1{font-size:16px;letter-spacing:.04em;margin:0 0 2px;color:var(--green)}
  .sub{color:var(--dim);font-size:12px;margin:0 0 14px}
  .frame{border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin-bottom:14px;background:#0f1512}
  .frame .k{color:var(--dim);font-size:11px;text-transform:uppercase;letter-spacing:.08em}
  .stats{display:flex;flex-wrap:wrap;gap:16px}
  .stat b{font-size:20px;display:block}
  .note{color:var(--gold);font-size:12px;margin-top:8px;line-height:1.45}
  h2{font-size:12px;text-transform:uppercase;letter-spacing:.1em;color:var(--dim);
    margin:18px 0 8px;border-bottom:1px solid var(--line);padding-bottom:6px}
  .row{display:flex;justify-content:space-between;align-items:baseline;gap:10px;
    padding:9px 2px;border-bottom:1px dashed var(--line)}
  .sym{font-weight:700}.name{color:var(--dim);font-size:12px}
  .mc{white-space:nowrap}.mc .now{color:var(--ink)}.mc .arw{color:var(--dim)}
  .age{color:var(--dim);font-size:11px}
  .badge{font-size:10px;font-weight:700;padding:2px 7px;border-radius:20px;text-transform:uppercase;letter-spacing:.05em}
  .b-live{color:var(--blue);border:1px solid var(--blue)}
  .b-target{color:var(--green);border:1px solid var(--green)}
  .b-stop{color:var(--red);border:1px solid var(--red)}
  .b-graduated{color:var(--gold);border:1px solid var(--gold)}
  .b-timestop{color:var(--dim);border:1px solid var(--dim)}
  .pulse{width:7px;height:7px;border-radius:50%;background:var(--green);display:inline-block;
    margin-right:6px;animation:p 1.6s infinite}
  @keyframes p{0%,100%{opacity:1}50%{opacity:.25}}
  .empty{color:var(--dim);padding:14px 2px;font-size:13px}
  .promo{margin-top:22px;border:1px solid var(--green);border-radius:10px;padding:14px;background:#0f1a13}
  .promo b{color:var(--green)}
  .foot{color:var(--dim);font-size:11px;margin-top:18px;line-height:1.5}
</style></head><body>
<div class="wrap">
  <h1><span class="pulse"></span>POSSESSIO RADAR — AI LIVE SELECTION</h1>
  <p class="sub">What an autonomous trader screens from, in real time. Solana / pump.fun, pre-DEX.</p>

  <div class="frame">
    <div class="k">Screening method — RULEBOOK §1 (paper-only, nothing is bought)</div>
    <div class="stats" id="stats"><span class="stat">…</span></div>
    <div class="note" id="note">Most picks fail by design — the method runs a low win rate on purpose, and the ~2.5:1 asymmetry (up ~2x / down ~40–60%) is what carries it. You are not watching "hot buys." You are watching a discipline.</div>
  </div>

  <h2>Live — in the entry window now</h2>
  <div id="live"><div class="empty">waiting for the next qualifier…</div></div>

  <h2>Recently closed</h2>
  <div id="recent"><div class="empty">—</div></div>

  <div class="promo">
    <b>This is the eye. The hand is x402Core.</b><br>
    A human can't sit on this 24/7 or exit on rule, not feeling. The x402Core
    autonomous trader runs this exact discipline for you — pay-per-call, on-chain,
    no keys handed over. Every call feeds the protocol pool.
  </div>

  <p class="foot" id="foot">
    Pre-DEX only — the edge is buying before DexScreener lists it. Rug &amp; session
    gates are not yet wired (shown as pending, never faked). Numbers are the ratified
    §1 method; the ledger will kill or confirm it. Not financial advice.
  </p>
</div>
<script>
(function(){
  "use strict";
  var fmt=function(n){ if(n==null) return "—"; n=Number(n);
    return "$"+(n>=1000?(n/1000).toFixed(1)+"k":n.toFixed(0)); };
  var ago=function(ms){ if(!ms) return ""; var s=Math.max(0,Math.round((Date.now()-ms)/1000));
    return s<90? s+"s" : Math.round(s/60)+"m"; };
  var esc=function(s){ return (s==null?"":String(s)).replace(/[&<>\"]/g,function(c){
    return {"&":"&amp;","<":"&lt;",">":"&gt;","\\"":"&quot;"}[c]; }); };

  function liveRow(c){
    return '<div class="row"><div><span class="sym">'+esc(c.symbol||"?")+'</span> '+
      '<span class="name">'+esc((c.name||"").slice(0,28))+'</span><br>'+
      '<span class="age">qualified '+ago(c.qualified_ms)+' ago · entry '+fmt(c.entry_mc)+'</span></div>'+
      '<div style="text-align:right"><span class="badge b-live">live</span><br>'+
      '<span class="mc"><span class="now">'+fmt(c.last_mc)+'</span> <span class="arw">peak '+fmt(c.peak_mc)+'</span></span></div></div>';
  }
  function recentRow(c){
    return '<div class="row"><div><span class="sym">'+esc(c.symbol||"?")+'</span> '+
      '<span class="name">'+esc((c.name||"").slice(0,24))+'</span><br>'+
      '<span class="age">'+fmt(c.entry_mc)+' <span class="mc arw">&#8594;</span> peak '+fmt(c.peak_mc)+'</span></div>'+
      '<div><span class="badge b-'+esc(c.outcome)+'">'+esc(c.outcome)+'</span></div></div>';
  }

  function render(d){
    var t={}; (d.tally||[]).forEach(function(r){ t[r.outcome]=r.n; });
    var liveN=(d.live||[]).length;
    document.getElementById("stats").innerHTML=
      '<span class="stat"><b style="color:var(--blue)">'+liveN+'</b>live now</span>'+
      '<span class="stat"><b style="color:var(--green)">'+(t.target||0)+'</b>hit target</span>'+
      '<span class="stat"><b style="color:var(--red)">'+(t.stop||0)+'</b>stopped</span>'+
      '<span class="stat"><b style="color:var(--gold)">'+(t.graduated||0)+'</b>graduated</span>'+
      '<span class="stat"><b style="color:var(--dim)">'+(t.timestop||0)+'</b>timed out</span>';
    var L=document.getElementById("live");
    L.innerHTML=(d.live&&d.live.length)? d.live.map(liveRow).join("") : '<div class="empty">waiting for the next qualifier…</div>';
    var R=document.getElementById("recent");
    R.innerHTML=(d.recent&&d.recent.length)? d.recent.map(recentRow).join("") : '<div class="empty">—</div>';
  }
  function poll(){
    fetch("/radar/candidates",{cache:"no-store"}).then(function(r){return r.json();})
      .then(render).catch(function(){});
  }
  poll(); setInterval(poll,5000);
})();
</script>
</body></html>`;
