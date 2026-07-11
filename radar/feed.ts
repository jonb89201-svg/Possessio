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
  .pct{font-weight:700;font-size:12px}.pct.up{color:var(--green)}.pct.down{color:var(--red)}
  .osc{color:var(--blue);font-size:13px;letter-spacing:1px;line-height:1}
  .b-early{color:#c792ea;border:1px solid #c792ea}
  .dex{color:var(--blue);font-size:11px;text-decoration:none;white-space:nowrap}
  .dex:hover{text-decoration:underline}
  .dexline{margin:-4px 2px 4px;padding:6px 8px;background:#0f1a13;border-left:2px solid var(--green);
    border-radius:0 6px 6px 0;color:var(--dim);font-size:11px;line-height:1.5}
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

  <h2>Early radar — crossed $4k before 4min &middot; §0 paper play: $4k &#8594; $8k by 2:00</h2>
  <div id="epstats" class="sub"></div>
  <div id="early"><div class="empty">scanning newborns…</div></div>

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

  function pct(from,to){ if(from==null||to==null||!from) return "";
    var p=((Number(to)-Number(from))/Number(from))*100;
    return '<span class="pct '+(p>=0?"up":"down")+'">'+(p>=0?"+":"")+p.toFixed(0)+'%</span>'; }
  function chg(v){ if(v==null) return "—"; v=Number(v);
    return '<span class="pct '+(v>=0?"up":"down")+'">'+(v>=0?"+":"")+v.toFixed(0)+'%</span>'; }
  function dex(addr){ if(!addr) return "";
    return '<a class="dex" href="https://dexscreener.com/solana/'+esc(addr)+'" target="_blank" rel="noopener">chart &#8599;</a>'; }
  function pf(addr){ if(!addr) return "";
    return '<a class="dex" href="https://pump.fun/coin/'+esc(addr)+'" target="_blank" rel="noopener">pump &#8599;</a>'; }
  // the oscillators — computed client-side from the 15s MC tape (d.ticks)
  function spark(tk){ if(!tk||tk.length<2) return "";
    var t=tk.slice(-16), lo=Infinity, hi=-Infinity;
    t.forEach(function(x){ lo=Math.min(lo,x.mc); hi=Math.max(hi,x.mc); });
    if(hi<=lo) return '<span class="osc">&#9644;&#9644;flat</span>';
    var bars="\\u2581\\u2582\\u2583\\u2584\\u2585\\u2586\\u2587\\u2588";
    return '<span class="osc">'+t.map(function(x){
      return bars[Math.round((x.mc-lo)/(hi-lo)*7)]; }).join("")+'</span>'; }
  function roc(tk){ if(!tk||tk.length<2) return "";
    var a=tk[tk.length-2].mc, b=tk[tk.length-1].mc;
    if(!a) return "";
    var p=((b-a)/a)*100;
    return '<span class="pct '+(p>=0?"up":"down")+'">'+(p>=0?"&#9650;":"&#9660;")+Math.abs(p).toFixed(1)+'%/tick</span>'; }
  // NET BUY FLOW: delta of the curve's real SOL reserves (buys add, sells
  // drain) over the last ~1min of samples. "steady" = 3+ of the last 4
  // deltas positive — the Architect's steady-volume-increase read.
  function flow(tk){ if(!tk) return "";
    var s=tk.filter(function(x){ return x.sol!=null; });
    if(s.length<2) return "";
    var a=s[Math.max(0,s.length-5)], b=s[s.length-1];
    var mins=(b.ms-a.ms)/60000; if(mins<=0) return "";
    var r=(b.sol-a.sol)/mins, up=0, n=0;
    for(var i=Math.max(1,s.length-4);i<s.length;i++){ n++; if(s[i].sol>s[i-1].sol) up++; }
    return '<span class="pct '+(r>=0?"up":"down")+'">'+(r>=0?"+":"")+r.toFixed(1)+' SOL/min</span>'+
      ((n>=3&&up>=3)?' <span class="osc">&#9889;steady</span>':''); }
  function pf(addr){ if(!addr) return "";
    return '<a class="dex" href="https://pump.fun/coin/'+esc(addr)+'" target="_blank" rel="noopener">pump &#8599;</a>'; }
  // oscillators, computed client-side from the tape (1 sample per cron tick)
  function spark(ticks){ if(!ticks||ticks.length<2) return "";
    var bars="\\u2581\\u2582\\u2583\\u2584\\u2585\\u2586\\u2587\\u2588";
    var t=ticks.slice(-14), lo=Infinity, hi=-Infinity;
    t.forEach(function(x){ lo=Math.min(lo,x.mc); hi=Math.max(hi,x.mc); });
    if(hi<=lo) return '<span class="osc">'+bars[3].repeat(t.length)+'</span>';
    return '<span class="osc">'+t.map(function(x){
      return bars[Math.round((x.mc-lo)/(hi-lo)*7)]; }).join("")+'</span>'; }
  function roc(ticks){ if(!ticks||ticks.length<2) return "";
    var a=ticks[ticks.length-2].mc, b=ticks[ticks.length-1].mc;
    if(!a) return "";
    var p=((b-a)/a)*100;
    return '<span class="pct '+(p>=0?"up":"down")+'">'+(p>=0?"+":"")+p.toFixed(0)+'%/t</span>'; }
  // the post-graduation phase: DexScreener data, only if the coin crossed the DEX boundary
  function dexLine(c){ if(c.dex_last_ms==null) return "";
    return '<div class="dexline">&#128640; ON DEX &middot; MC '+fmt(c.dex_mc)+
      ' &middot; liq '+fmt(c.dex_liq_usd)+' &middot; vol1h '+fmt(c.dex_vol_h1)+
      ' &middot; 5m '+chg(c.dex_chg_m5)+' &middot; 1h '+chg(c.dex_chg_h1)+'</div>'; }

  function playBadge(c){
    if(c.play_outcome==="target") return '<span class="badge b-target">8k &#10003;</span>';
    if(c.play_outcome==="exit2m") return '<span class="badge b-timestop">2:00 exit '+pct(c.first_hit_mc,c.play_exit_mc)+'</span>';
    if(c.play_outcome==="gap")    return '<span class="badge b-graduated">gap</span>';
    if(c.play_outcome==="late")   return '<span class="badge b-timestop">late</span>';
    return '<span class="badge b-early">early</span>';
  }
  // WS-detected earlies carry the flow-quality read from trade-level data:
  // distinct buyers vs whale concentration is the runner-vs-trap hypothesis.
  function flowQ(c){ if(!c.ws||c.uniq_buyers_hit==null) return "";
    var top=c.top_buyer_share!=null? Math.round(c.top_buyer_share*100)+'% top wallet' : '';
    return '<br><span class="age">&#9889;'+(c.t4k_ms!=null?(c.t4k_ms/1000).toFixed(1)+'s to $4k &middot; ':'')+
      c.uniq_buyers_hit+' buyers &middot; '+(c.buys_hit||0)+'B/'+(c.sells_hit||0)+'S &middot; '+
      (c.sol_net_hit!=null?('+'+c.sol_net_hit+' SOL &middot; '):'')+top+'</span>'; }
  function earlyRow(c,tk){
    var lastMc=(tk&&tk.length)? tk[tk.length-1].mc : c.first_hit_mc;
    return '<div class="row"><div><span class="sym">'+esc(c.symbol||"?")+'</span> '+
      '<span class="name">'+esc((c.name||"").slice(0,22))+'</span> '+pf(c.token_address)+'<br>'+
      '<span class="age">hit $4k at '+Math.round(c.age_sec_at_hit)+'s old &middot; '+ago(c.first_hit_ms)+' ago</span>'+
      flowQ(c)+'<br>'+
      spark(tk)+' '+roc(tk)+' '+flow(tk)+'</div>'+
      '<div style="text-align:right">'+playBadge(c)+'<br>'+
      '<span class="mc">'+fmt(c.first_hit_mc)+' <span class="arw">&#8594;</span> <span class="now">'+fmt(lastMc)+'</span> '+pct(c.first_hit_mc,lastMc)+'</span>'+
      (c.peak_mc?('<br><span class="age">peak '+fmt(c.peak_mc)+' '+pct(c.first_hit_mc,c.peak_mc)+'</span>'):'')+'</div></div>';
  }
  function liveRow(c,tk){
    return '<div class="row"><div><span class="sym">'+esc(c.symbol||"?")+'</span> '+
      '<span class="name">'+esc((c.name||"").slice(0,22))+'</span> '+dex(c.token_address)+' '+pf(c.token_address)+'<br>'+
      '<span class="age">qualified '+ago(c.qualified_ms)+' ago</span><br>'+
      spark(tk)+' '+roc(tk)+' '+flow(tk)+'</div>'+
      '<div style="text-align:right"><span class="badge b-live">live</span><br>'+
      '<span class="mc">'+fmt(c.entry_mc)+' <span class="arw">&#8594;</span> <span class="now">'+fmt(c.last_mc)+'</span> '+pct(c.entry_mc,c.last_mc)+'</span><br>'+
      '<span class="age">peak '+fmt(c.peak_mc)+' '+pct(c.entry_mc,c.peak_mc)+'</span></div></div>'+dexLine(c);
  }
  function recentRow(c){
    return '<div class="row"><div><span class="sym">'+esc(c.symbol||"?")+'</span> '+
      '<span class="name">'+esc((c.name||"").slice(0,20))+'</span> '+dex(c.token_address)+'<br>'+
      '<span class="age">'+fmt(c.entry_mc)+' <span class="arw">&#8594;</span> peak '+fmt(c.peak_mc)+' '+pct(c.entry_mc,c.peak_mc)+'</span></div>'+
      '<div><span class="badge b-'+esc(c.outcome)+'">'+esc(c.outcome)+'</span></div></div>'+dexLine(c);
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
    var ep={}; (d.earlyPlay||[]).forEach(function(r){ ep[r.play_outcome]=r; });
    var nT=ep.target?ep.target.n:0, nX=ep.exit2m?ep.exit2m.n:0;
    var xm=ep.exit2m&&ep.exit2m.avg_mult!=null?(' avg '+ep.exit2m.avg_mult+'x'):'';
    document.getElementById("epstats").innerHTML =
      '§0 ledger: <span class="pct up">'+nT+' hit $8k</span> &middot; '+
      '<span class="pct '+((ep.exit2m&&ep.exit2m.avg_mult>=1)?'up':'down')+'">'+nX+' exited at 2:00'+xm+'</span>'+
      (nT+nX>0?(' &middot; win rate '+Math.round(100*nT/(nT+nX))+'%'):' &middot; accumulating…');
    var tk=d.ticks||{};
    var E=document.getElementById("early");
    E.innerHTML=(d.early&&d.early.length)? d.early.map(function(c){ return earlyRow(c,tk[c.token_address]); }).join("") : '<div class="empty">scanning newborns…</div>';
    var L=document.getElementById("live");
    L.innerHTML=(d.live&&d.live.length)? d.live.map(function(c){ return liveRow(c,tk[c.token_address]); }).join("") : '<div class="empty">waiting for the next qualifier…</div>';
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
