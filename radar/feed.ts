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
  .coinimg{width:34px;height:34px;border-radius:7px;object-fit:cover;vertical-align:middle;
    margin-right:7px;background:#1a2420;border:1px solid var(--line)}
  .row.dying{animation:die .8s ease forwards}
  @keyframes die{from{opacity:.34}to{opacity:0;transform:translateX(-12px)}}
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
  /* FLOW GATE (proven entry screen: net-flow-positive = the 1.37x/84%-green
     movers; net-flow<=0 = the 0.74x duds). Duds recede, movers get flagged. */
  .row.gate-dud{opacity:.34}
  .row.gate-hot{border-left:3px solid var(--green);padding-left:9px;background:#0e1712}
  .row.gate-ok{border-left:3px solid var(--gold);padding-left:9px}
  .gatetag{font-size:10px;font-weight:700;padding:1px 6px;border-radius:20px;letter-spacing:.04em;white-space:nowrap}
  .g-in{color:var(--green);border:1px solid var(--green)}
  .g-weak{color:var(--gold);border:1px solid var(--gold)}
  .g-skip{color:var(--red);border:1px solid var(--red)}
  .g-wait{color:var(--dim);border:1px solid var(--dim)}
  .gatebar{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin:2px 0 6px;font-size:11px;color:var(--dim)}
  .gatebar label{cursor:pointer;user-select:none}
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

  <h2>Early radar &middot; §0 ladder (paper): in $3.5k &middot; out 50%@6k 25%@8k 12.5%@10k 12.5%@12k &middot; dip re-buy &#8594; next ladder up</h2>
  <div id="epstats" class="sub"></div>
  <div class="gatebar">
    <span><b>FLOW GATE</b> — net-buy screen (proven: <span class="pct up">FLOW IN &rarr; 1.37x, 84% green</span> vs <span class="pct down">SKIP &rarr; 0.74x</span>)</span>
    <label><input type="checkbox" id="hideSkip"> hide SKIPs</label>
    <span id="gatecount"></span>
  </div>
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
  // the coin's launch image (pump.fun image_uri). Hidden if missing/broken.
  function img(u){ if(!u) return "";
    return '<img class="coinimg" loading="lazy" src="'+esc(u)+'" onerror="this.style.display=&quot;none&quot;">'; }
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
  // THE FLOW GATE — the proven entry screen. Net SOL/min over the last ~1min
  // of tape: >2 = strong buy flow (the 1.37x / 84%-green movers), >0 = weak
  // positive, <=0 = net selling/flat (the 0.74x duds). null until ~2 ticks
  // exist (the ~45s the 15s tape needs to read direction).
  function flowRate(tk){ if(!tk) return null;
    var s=tk.filter(function(x){ return x.sol!=null; });
    if(s.length<2) return null;
    var a=s[Math.max(0,s.length-5)], b=s[s.length-1];
    var mins=(b.ms-a.ms)/60000; if(mins<=0) return null;
    return (b.sol-a.sol)/mins; }
  function gate(tk){ var r=flowRate(tk);
    if(r==null) return {cls:"",tag:'<span class="gatetag g-wait">reading…</span>'};
    if(r>2)  return {cls:"gate-hot",tag:'<span class="gatetag g-in">&#9679; FLOW IN</span>'};
    if(r>0)  return {cls:"gate-ok", tag:'<span class="gatetag g-weak">weak +</span>'};
    return {cls:"gate-dud",tag:'<span class="gatetag g-skip">&#9679; SKIP</span>'}; }
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
    var cm=(c.compound_mult!=null&&c.levels>1)?(' L'+c.levels+' &times;'+c.compound_mult):'';
    if(c.play_outcome==="target") return '<span class="badge b-target">ladder &#10003;'+cm+'</span>';
    if(c.play_outcome==="exit2m"){
      var up=c.play_exit_mc!=null&&c.first_hit_mc&&c.play_exit_mc>=c.first_hit_mc;
      return '<span class="badge '+(up?'b-target':'b-stop')+'">sell '+pct(c.first_hit_mc,c.play_exit_mc)+'</span>'; }
    if(c.play_outcome==="gap")    return '<span class="badge b-graduated">gap</span>';
    if(c.play_outcome==="late")   return '<span class="badge b-timestop">late</span>';
    return '<span class="badge b-early">early</span>';
  }
  // WS-detected earlies carry the flow-quality read from trade-level data:
  // distinct buyers vs whale concentration is the runner-vs-trap hypothesis.
  function flowQ(c){ if(!c.ws||c.uniq_buyers_hit==null) return "";
    var top=c.top_buyer_share!=null? Math.round(c.top_buyer_share*100)+'% top wallet' : '';
    return '<br><span class="age">&#9889;'+(c.t4k_ms!=null?(c.t4k_ms/1000).toFixed(1)+'s to $3.5k &middot; ':'')+
      c.uniq_buyers_hit+' buyers &middot; '+(c.buys_hit||0)+'B/'+(c.sells_hit||0)+'S &middot; '+
      (c.sol_net_hit!=null?('+'+c.sol_net_hit+' SOL &middot; '):'')+top+'</span>'; }
  function earlyRow(c,tk){
    var lastMc=(tk&&tk.length)? tk[tk.length-1].mc : c.first_hit_mc;
    // gate only live (unresolved) earlies — that's what you'd actually enter
    var live=(c.play_outcome==null), g=live?gate(tk):{cls:"",tag:""};
    return '<div class="row '+g.cls+'"><div>'+img(c.img)+'<span class="sym">'+esc(c.symbol||"?")+'</span> '+
      '<span class="name">'+esc((c.name||"").slice(0,22))+'</span> '+pf(c.token_address)+'<br>'+
      '<span class="age">hit $3.5k at '+Math.round(c.age_sec_at_hit)+'s old &middot; '+ago(c.first_hit_ms)+' ago</span>'+
      flowQ(c)+'<br>'+
      spark(tk)+' '+roc(tk)+' '+flow(tk)+'</div>'+
      '<div style="text-align:right">'+(live?g.tag+'<br>':playBadge(c)+'<br>')+
      '<span class="mc">'+fmt(c.first_hit_mc)+' <span class="arw">&#8594;</span> <span class="now">'+fmt(lastMc)+'</span> '+pct(c.first_hit_mc,lastMc)+'</span>'+
      (c.peak_mc?('<br><span class="age">peak '+fmt(c.peak_mc)+' '+pct(c.first_hit_mc,c.peak_mc)+'</span>'):'')+'</div></div>';
  }
  function liveRow(c,tk){
    return '<div class="row"><div>'+img(c.img)+'<span class="sym">'+esc(c.symbol||"?")+'</span> '+
      '<span class="name">'+esc((c.name||"").slice(0,22))+'</span> '+dex(c.token_address)+' '+pf(c.token_address)+'<br>'+
      '<span class="age">qualified '+ago(c.qualified_ms)+' ago</span><br>'+
      spark(tk)+' '+roc(tk)+' '+flow(tk)+'</div>'+
      '<div style="text-align:right"><span class="badge b-live">live</span><br>'+
      '<span class="mc">'+fmt(c.entry_mc)+' <span class="arw">&#8594;</span> <span class="now">'+fmt(c.last_mc)+'</span> '+pct(c.entry_mc,c.last_mc)+'</span><br>'+
      '<span class="age">peak '+fmt(c.peak_mc)+' '+pct(c.entry_mc,c.peak_mc)+'</span></div></div>'+dexLine(c);
  }
  // Closed §1 trades read as SELLS, colored by P/L vs our entry: green if the
  // exit was above the buy, red if below. 'graduated' keeps its own badge (the
  // coin left for the DEX — the dexline below tells that story).
  function sellBadge(c){
    if(c.outcome==="graduated") return '<span class="badge b-graduated">graduated</span>';
    var ex=(c.last_mc!=null)?c.last_mc:null;
    if(ex==null||!c.entry_mc) return '<span class="badge b-timestop">'+esc(c.outcome)+'</span>';
    var up=ex>=c.entry_mc;
    return '<span class="badge '+(up?'b-target':'b-stop')+'">sell '+pct(c.entry_mc,ex)+'</span>';
  }
  function recentRow(c){
    return '<div class="row"><div><span class="sym">'+esc(c.symbol||"?")+'</span> '+
      '<span class="name">'+esc((c.name||"").slice(0,20))+'</span> '+dex(c.token_address)+'<br>'+
      '<span class="age">'+fmt(c.entry_mc)+' <span class="arw">&#8594;</span> peak '+fmt(c.peak_mc)+' '+pct(c.entry_mc,c.peak_mc)+'</span></div>'+
      '<div>'+sellBadge(c)+'</div></div>'+dexLine(c);
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
      '§0 ledger: <span class="pct up">'+nT+' full ladders</span> &middot; '+
      '<span class="pct '+((ep.exit2m&&ep.exit2m.avg_mult>=1)?'up':'down')+'">'+nX+' bell exits'+xm+'</span>'+
      (nT+nX>0?(' &middot; ladder rate '+Math.round(100*nT/(nT+nX))+'%'):' &middot; accumulating…');
    var tk=d.ticks||{};
    // FLOW GATE: classify live earlies, count them, and (optionally) hide SKIPs.
    var hideSkip=document.getElementById("hideSkip").checked;
    var gc={in:0,weak:0,skip:0,wait:0};
    var shown=(d.early||[]).filter(function(c){
      if(c.play_outcome!=null){
        // DROP THE DEAD: a resolved coin that never turned a profit is done and
        // won't come back — it falls off the map, freeing the space. You still
        // watched it die live (dimmed) while it was unresolved above. Winners
        // (exit above entry) stay visible.
        return c.play_exit_mc>c.first_hit_mc;
      }
      var r=flowRate(tk[c.token_address]);
      if(r==null){gc.wait++; return true;}
      if(r>2){gc.in++; return true;}
      if(r>0){gc.weak++; return true;}
      gc.skip++; return !hideSkip;                     // SKIP: hidden if toggled
    });
    document.getElementById("gatecount").innerHTML=
      '<span class="pct up">'+gc.in+' IN</span> &middot; <span class="pct" style="color:var(--gold)">'+gc.weak+' weak</span> &middot; '+
      '<span class="pct down">'+gc.skip+' skip</span> &middot; <span style="color:var(--dim)">'+gc.wait+' reading</span>';
    var E=document.getElementById("early");
    E.innerHTML=shown.length? shown.map(function(c){ return earlyRow(c,tk[c.token_address]); }).join("") : '<div class="empty">scanning newborns…</div>';
    var L=document.getElementById("live");
    L.innerHTML=(d.live&&d.live.length)? d.live.map(function(c){ return liveRow(c,tk[c.token_address]); }).join("") : '<div class="empty">waiting for the next qualifier…</div>';
    var R=document.getElementById("recent");
    R.innerHTML=(d.recent&&d.recent.length)? d.recent.map(recentRow).join("") : '<div class="empty">—</div>';
  }
  var lastData=null;
  function poll(){
    fetch("/radar/candidates",{cache:"no-store"}).then(function(r){return r.json();})
      .then(function(d){ lastData=d; render(d); }).catch(function(){});
  }
  document.getElementById("hideSkip").addEventListener("change",function(){ if(lastData) render(lastData); });
  poll(); setInterval(poll,5000);
})();
</script>
</body></html>`;
