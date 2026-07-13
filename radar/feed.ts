// possessio-radar — feed.ts: the public live-selection page.
// Polls /radar/candidates and renders. No data lives in this HTML; it's a
// shell. Honest framing is load-bearing: most picks fail BY DESIGN (§1's
// asymmetry), so the page says so — which is also the x402Core sales argument.

export const FEED_HTML = `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#ffffff">
<title>POSSESSIO Radar — AI Live Selection</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500;600&family=Space+Grotesk:wght@600;700&display=swap">
<style>
  /* Matched to the POSSESSIO console design system (public/index.html): white
     surfaces, soft-slate lines, oxide-blue accent, Inter + IBM Plex Mono. */
  :root{
    --bg:#ffffff;--surface:#ffffff;--surface-2:#f8fafc;--surface-3:#f1f5f9;
    --line:#e2e8f0;--line-2:#cbd5e1;
    --ink:#0f172a;--dim:#475569;--faint:#94a3b8;
    --oxide:#1d4ed8;--oxide-dim:#1e40af;--oxide-faint:#dbeafe;
    --danger:#dc2626;--danger-dim:#b91c1c;--danger-faint:#fef2f2;
    --council:#16a34a;--council-dim:#15803d;--council-faint:#dcfce7;
    --treasury:#0891b2;--treasury-dim:#0e7490;--treasury-faint:#cffafe;
    --open:#7c3aed;--open-dim:#6d28d9;--open-faint:#ede9fe;
    /* aliases the render JS references inline */
    --green:var(--council);--red:var(--danger);--blue:var(--oxide);--gold:var(--treasury-dim);
    --radius:12px;--radius-pill:9999px;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--bg);color:var(--ink);letter-spacing:-0.005em;-webkit-font-smoothing:antialiased;
    font-family:'Inter',system-ui,-apple-system,sans-serif;font-size:14px;line-height:1.55}
  .wrap{max-width:760px;margin:0 auto;padding:16px 14px 60px}
  h1{font-family:'Space Grotesk',system-ui,sans-serif;font-size:19px;font-weight:700;letter-spacing:-.01em;
    margin:0 0 3px;color:var(--ink);display:flex;align-items:center}
  .sub{color:var(--dim);font-size:12.5px;margin:0 0 14px}
  .frame{border:1px solid var(--line);border-radius:var(--radius);padding:14px 16px;margin-bottom:14px;background:var(--surface-2)}
  .frame .k{color:var(--faint);font-size:11px;text-transform:uppercase;letter-spacing:.06em;font-weight:600}
  .stats{display:flex;flex-wrap:wrap;gap:18px;margin-top:10px}
  .stat{font-size:11px;color:var(--dim);text-transform:uppercase;letter-spacing:.03em}
  .stat b{font-size:22px;display:block;font-family:'Space Grotesk',sans-serif;font-weight:700;letter-spacing:-.02em}
  .note{color:var(--oxide-dim);font-size:12px;margin-top:10px;line-height:1.5;
    background:var(--oxide-faint);border-left:3px solid var(--oxide);border-radius:0 8px 8px 0;padding:9px 11px}
  h2{font-family:'Space Grotesk',sans-serif;font-size:12px;text-transform:uppercase;letter-spacing:.07em;color:var(--dim);
    font-weight:600;margin:20px 0 8px;border-bottom:1px solid var(--line);padding-bottom:7px}
  .row{display:flex;justify-content:space-between;align-items:flex-start;gap:10px;
    padding:11px 4px;border-bottom:1px solid var(--line)}
  .sym{font-weight:700;color:var(--ink)}.name{color:var(--faint);font-size:12px}
  .coinimg{width:36px;height:36px;border-radius:8px;object-fit:cover;vertical-align:middle;
    margin-right:8px;background:var(--surface-3);border:1px solid var(--line)}
  .row.dying{animation:die .8s ease forwards}
  @keyframes die{from{opacity:.4}to{opacity:0;transform:translateX(-12px)}}
  .mc{white-space:nowrap;font-family:'IBM Plex Mono',monospace;font-size:12.5px;font-weight:500}
  .mc .now{color:var(--ink);font-weight:600}.mc .arw{color:var(--faint)}
  .age{color:var(--faint);font-size:11px;font-family:'IBM Plex Mono',monospace}
  .badge{font-size:10px;font-weight:600;padding:3px 9px;border-radius:var(--radius-pill);
    text-transform:uppercase;letter-spacing:.03em;white-space:nowrap;display:inline-block}
  .b-live{background:var(--oxide-faint);color:var(--oxide-dim)}
  .b-target{background:var(--council-faint);color:var(--council-dim)}
  .b-stop{background:var(--danger-faint);color:var(--danger-dim)}
  .b-graduated{background:var(--treasury-faint);color:var(--treasury-dim)}
  .b-timestop{background:var(--surface-3);color:var(--dim)}
  .b-early{background:var(--open-faint);color:var(--open-dim)}
  .pulse{width:8px;height:8px;border-radius:50%;background:var(--council);display:inline-block;
    margin-right:8px;animation:p 1.6s infinite}
  @keyframes p{0%,100%{opacity:1}50%{opacity:.3}}
  .pct{font-weight:600;font-size:12px;font-family:'IBM Plex Mono',monospace}
  .pct.up{color:var(--council)}.pct.down{color:var(--danger)}
  .osc{color:var(--oxide);font-size:13px;letter-spacing:1px;line-height:1;font-family:'IBM Plex Mono',monospace}
  .dex{color:var(--oxide);font-size:11px;text-decoration:none;white-space:nowrap;font-weight:500}
  .dex:hover{text-decoration:underline}
  .dexline{margin:4px 2px 4px;padding:7px 10px;background:var(--treasury-faint);border-left:3px solid var(--treasury);
    border-radius:0 8px 8px 0;color:var(--treasury-dim);font-size:11px;line-height:1.5;font-family:'IBM Plex Mono',monospace}
  .dexline b{color:var(--council-dim)}
  .empty{color:var(--faint);padding:14px 4px;font-size:13px}
  /* FLOW GATE (proven entry screen: net-flow-positive = 1.37x/84%-green movers;
     net-flow<=0 = 0.74x duds). Duds recede, movers get flagged. */
  .row.gate-dud{opacity:.4}
  .row.gate-hot{border-left:3px solid var(--council);padding-left:9px;background:var(--council-faint)}
  .row.gate-ok{border-left:3px solid var(--treasury);padding-left:9px}
  .gatetag{font-size:10px;font-weight:600;padding:2px 8px;border-radius:var(--radius-pill);letter-spacing:.03em;white-space:nowrap;display:inline-block}
  .g-in{background:var(--council-faint);color:var(--council-dim)}
  .g-weak{background:var(--treasury-faint);color:var(--treasury-dim)}
  .g-skip{background:var(--danger-faint);color:var(--danger-dim)}
  .g-wait{background:var(--surface-3);color:var(--faint)}
  /* CONVICTION TAG — a TRACKED HYPOTHESIS (not a proven edge), scored live at
     the ~$8k crossing. "bucket C" = reserves >=22 SOL + fill-velocity 10-16
     (reserves / ticks-since-first-seen). In 5.7d of tape it hit 20k 18.5% of
     the time vs ~6.5% base (Wilson 95% CI [10.4%, 30.8%]) and held ~4x the
     field's rate in BOTH chronological halves. Small n (54); the forward ledger
     is the real judge — same "kill or confirm it" law as §1. NOTE: there is NO
     leading exit signal. The "reserves roll over before price" divergence is
     mechanically impossible on a constant-product curve (price is a monotonic
     function of reserves) — the apparent lead was a DexScreener-MC vs curve-
     reserve feed-latency artifact. Exit is the §1 rules + the flow gate. */
  .pb{font-size:10px;font-weight:700;padding:2px 8px;border-radius:var(--radius-pill);letter-spacing:.03em;white-space:nowrap;display:inline-block}
  .pb-go{background:var(--council);color:#fff}
  .pb-slow{background:var(--surface-3);color:var(--dim)}
  .pb-bot{background:var(--oxide-faint);color:var(--oxide-dim)}
  .pb-thin{background:var(--danger-faint);color:var(--danger-dim)}
  .row.pb-c-go{border-left:3px solid var(--council);padding-left:9px;background:var(--council-faint)}
  .gatebar{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin:2px 0 8px;font-size:11px;color:var(--dim);
    background:var(--surface-2);border:1px solid var(--line);border-radius:10px;padding:8px 12px}
  .gatebar label{cursor:pointer;user-select:none}.gatebar b{color:var(--ink)}
  .promo{margin-top:22px;border:1px solid var(--council);border-radius:var(--radius);padding:16px;background:var(--council-faint)}
  .promo b{color:var(--council-dim)}
  .foot{color:var(--faint);font-size:11px;margin-top:18px;line-height:1.5}
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
  <p class="sub" style="margin:-2px 0 8px">
    <span class="pb pb-go">&#9670; GO</span> = a <b>tracked entry hypothesis</b> — deep curve reserves (&ge;22 SOL) plus a deliberate ~2-tick climb into the band. Beat the field ~4&times; in-sample and in the unseen later half, but small sample — <b>the forward ledger judges it, not this label.</b> No magic exit exists: target / stop / time-stop only.
  </p>
  <div id="convscore" class="sub" style="margin:-2px 0 10px"></div>
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
  // CONVICTION — the tracked-hypothesis entry read at the ~$8k crossing.
  // depth = curve SOL reserves at the first tick to reach the band; velocity =
  // depth / ticks-since-first-seen (how deliberately it climbed). Both come from
  // the SAME curve source (sol_reserves), so no cross-feed artifact. Returns null
  // until the coin reaches the band. GO = the backtested bucket C; the rest are
  // the buckets that under-performed it (floor/thin, slow grind, bot-spike).
  function conviction(tk){
    if(!tk||!tk.length) return null;
    var i8=-1;
    for(var i=0;i<tk.length;i++){ if(tk[i].mc>=7500){ i8=i; break; } }
    if(i8<0) return null;                       // hasn't reached the band yet
    var depth=null;
    for(var j=i8;j<tk.length;j++){ if(tk[j].sol!=null){ depth=tk[j].sol; break; } }
    if(depth==null) return null;                // no reserve read at the crossing
    var vel=depth/(i8+1);
    if(depth<22) return {t:"thin",cls:"",       h:'<span class="pb pb-thin">THIN &middot; skip</span>'};
    if(vel>=16)  return {t:"bot", cls:"",       h:'<span class="pb pb-bot">too fast</span>'};
    if(vel>=10)  return {t:"go",  cls:"pb-c-go",h:'<span class="pb pb-go">&#9670; GO</span>'};
    return         {t:"slow",cls:"",            h:'<span class="pb pb-slow">slow grind</span>'};
  }
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
  // POST-GRADUATION line for earlies — the run AFTER we exited. Shows the DEX
  // peak and how far past our exit it went (the DAYNA "$10.6k -> $26k" story).
  function postGrad(c, exitMc){ if(c.dex_last_ms==null && c.graduated_ms==null) return "";
    var peak=(c.dex_peak_mc!=null)?c.dex_peak_mc:c.dex_mc, run="";
    if(peak!=null && exitMc) run=' &middot; <b>'+(peak/exitMc).toFixed(1)+'x past exit</b>';
    return '<div class="dexline">&#128640; RAN ON DEX &middot; peak '+fmt(peak)+
      ' &middot; now '+fmt(c.dex_mc)+run+'</div>'; }

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
    var cv=live?conviction(tk):null;            // only once it has reached the ~$8k band
    return '<div class="row '+g.cls+'"><div>'+img(c.img)+'<span class="sym">'+esc(c.symbol||"?")+'</span> '+
      '<span class="name">'+esc((c.name||"").slice(0,22))+'</span> '+pf(c.token_address)+'<br>'+
      '<span class="age">hit $3.5k at '+Math.round(c.age_sec_at_hit)+'s old &middot; '+ago(c.first_hit_ms)+' ago</span>'+
      flowQ(c)+'<br>'+
      spark(tk)+' '+roc(tk)+' '+flow(tk)+'</div>'+
      '<div style="text-align:right">'+(live?(g.tag+(cv?' '+cv.h:'')+'<br>'):playBadge(c)+'<br>')+
      '<span class="mc">'+fmt(c.first_hit_mc)+' <span class="arw">&#8594;</span> <span class="now">'+fmt(lastMc)+'</span> '+pct(c.first_hit_mc,lastMc)+'</span>'+
      (c.peak_mc?('<br><span class="age">peak '+fmt(c.peak_mc)+' '+pct(c.first_hit_mc,c.peak_mc)+'</span>'):'')+'</div></div>'+
      postGrad(c, c.play_exit_mc||c.first_hit_mc);
  }
  function liveRow(c,tk){
    var cv=conviction(tk);
    return '<div class="row '+(cv?cv.cls:'')+'"><div>'+img(c.img)+'<span class="sym">'+esc(c.symbol||"?")+'</span> '+
      '<span class="name">'+esc((c.name||"").slice(0,22))+'</span> '+dex(c.token_address)+' '+pf(c.token_address)+'<br>'+
      '<span class="age">qualified '+ago(c.qualified_ms)+' ago</span><br>'+
      spark(tk)+' '+roc(tk)+' '+flow(tk)+'</div>'+
      '<div style="text-align:right">'+(cv?cv.h+' ':'')+'<span class="badge b-live">live</span><br>'+
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
    return '<div class="row"><div>'+img(c.img)+'<span class="sym">'+esc(c.symbol||"?")+'</span> '+
      '<span class="name">'+esc((c.name||"").slice(0,20))+'</span> '+dex(c.token_address)+'<br>'+
      '<span class="age">'+fmt(c.entry_mc)+' <span class="arw">&#8594;</span> peak '+fmt(c.peak_mc)+' '+pct(c.entry_mc,c.peak_mc)+'</span></div>'+
      '<div>'+sellBadge(c)+'</div></div>'+dexLine(c);
  }
  // A CONCLUDED §0 trade, formatted for Recently Closed: entry -> peak + the
  // settled ladder badge (which agrees with the numbers now), plus the
  // post-exit run line if it kept going. Belongs here, not in the live radar.
  function earlyClosedRow(c){
    return '<div class="row"><div>'+img(c.img)+'<span class="sym">'+esc(c.symbol||"?")+'</span> '+
      '<span class="name">'+esc((c.name||"").slice(0,20))+'</span> '+pf(c.token_address)+'<br>'+
      '<span class="age">'+fmt(c.first_hit_mc)+' <span class="arw">&#8594;</span> peak '+fmt(c.peak_mc)+' '+pct(c.first_hit_mc,c.peak_mc)+'</span></div>'+
      '<div>'+playBadge(c)+'</div></div>'+postGrad(c, c.play_exit_mc||c.first_hit_mc);
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
    // CONVICTION FORWARD SCORECARD — the radar grading its own GO tag on coins
    // the thresholds never saw (resolved only). GO vs the pooled field
    // (slow+bot+thin). This is the honest out-of-sample the backtest owed.
    var sc={}; (d.scorecard||[]).forEach(function(r){ sc[r.tag]=r; });
    var go=sc.go||{n:0,win20:0}, fN=0, fW=0;
    ["slow","bot","thin"].forEach(function(k){ if(sc[k]){ fN+=sc[k].n; fW+=sc[k].win20; } });
    var goPct=go.n? Math.round(100*go.win20/go.n):null, fPct=fN? Math.round(100*fW/fN):null;
    document.getElementById("convscore").innerHTML = (go.n||fN)?
      ('<b>Forward ledger</b> &middot; frozen thresholds on coins the backtest never saw: '+
       '<span class="pb pb-go">&#9670; GO</span> '+go.win20+'/'+go.n+
       (goPct!=null?(' <span class="pct '+(goPct>=(fPct||0)?"up":"down")+'">'+goPct+'% hit 20k</span>'):'')+
       ' &nbsp;vs field '+fW+'/'+fN+(fPct!=null?(' &middot; '+fPct+'%'):'')+
       (go.n<10?' &middot; <span style="color:var(--faint)">building sample…</span>':''))
      : '<span style="color:var(--faint)">Forward ledger: no conviction-tagged coins have resolved yet — accumulating.</span>';
    var tk=d.ticks||{};
    // EARLY RADAR = live/unresolved only — what you'd actually enter. A trade
    // that has CONCLUDED graduates down to Recently Closed (below), where a
    // done trade belongs — no more settled-vs-live number clashes up here.
    var hideSkip=document.getElementById("hideSkip").checked;
    var gc={in:0,weak:0,skip:0,wait:0};
    var shown=(d.early||[]).filter(function(c){
      if(c.play_outcome!=null) return false;           // concluded -> Recently Closed
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
    // RECENTLY CLOSED = concluded §0 trades (notable: won, graduated, or ran)
    // merged with §1 closes, newest-close first. Flat dead duds don't clutter it.
    var closed=(d.early||[])
      .filter(function(c){ return c.play_outcome!=null &&
        (c.play_exit_mc>c.first_hit_mc || c.graduated_ms!=null || c.dex_last_ms!=null); })
      .map(function(c){ return {t:c.play_outcome_ms||c.first_hit_ms, h:earlyClosedRow(c)}; })
      .concat((d.recent||[]).map(function(c){ return {t:c.outcome_ms||c.qualified_ms, h:recentRow(c)}; }))
      .sort(function(a,b){ return (b.t||0)-(a.t||0); });
    var R=document.getElementById("recent");
    R.innerHTML=closed.length? closed.map(function(x){ return x.h; }).join("") : '<div class="empty">—</div>';
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
