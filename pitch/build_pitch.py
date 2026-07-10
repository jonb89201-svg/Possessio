#!/usr/bin/env python3
"""Assembles the standalone pitch page, inlining the fetched woff2 fonts."""
import json, pathlib

fonts = json.load(open("/tmp/fonts_pitch.json"))

TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Jon Solo — Systems architect, shipped from a phone</title>
<meta name="description" content="Live Base-mainnet contracts, full-stack apps, a self-running market instrument — architected and shipped entirely from a phone.">
<style>
@font-face{font-family:'Archivo';font-style:normal;font-weight:400 800;font-display:swap;src:url(data:font/woff2;base64,__ARCHIVO__) format('woff2');}
@font-face{font-family:'Plex Mono';font-style:normal;font-weight:400;font-display:swap;src:url(data:font/woff2;base64,__MONO400__) format('woff2');}
@font-face{font-family:'Plex Mono';font-style:normal;font-weight:600;font-display:swap;src:url(data:font/woff2;base64,__MONO600__) format('woff2');}

:root{
  --ground:#0A0D13; --surface:#111621; --surface-2:#161D2A;
  --ink:#EAEDF3; --ink-dim:#96A0B2; --ink-faint:#5C6678;
  --line:rgba(234,237,243,0.09); --line-strong:rgba(234,237,243,0.17);
  --amber:#E6A94A; --amber-deep:#C6862B;
  --verify:#54D6A8; --verify-soft:rgba(84,214,168,0.14);
  --shadow:0 22px 50px -28px rgba(0,0,0,0.75);
  --sans:'Archivo',system-ui,-apple-system,'Segoe UI',sans-serif;
  --mono:'Plex Mono',ui-monospace,SFMono-Regular,Menlo,monospace;
  --maxw:648px;
  color-scheme:dark;
}
@media (prefers-color-scheme:light){
  :root{
    --ground:#F4F6FB; --surface:#FFFFFF; --surface-2:#EDF1F8;
    --ink:#111726; --ink-dim:#515C73; --ink-faint:#8A93A6;
    --line:rgba(17,23,38,0.10); --line-strong:rgba(17,23,38,0.20);
    --amber:#A96C0C; --amber-deep:#835309;
    --verify:#0E8A66; --verify-soft:rgba(14,138,102,0.12);
    --shadow:0 20px 44px -26px rgba(20,32,56,0.28);
    color-scheme:light;
  }
}
:root[data-theme="dark"]{
  --ground:#0A0D13; --surface:#111621; --surface-2:#161D2A;
  --ink:#EAEDF3; --ink-dim:#96A0B2; --ink-faint:#5C6678;
  --line:rgba(234,237,243,0.09); --line-strong:rgba(234,237,243,0.17);
  --amber:#E6A94A; --amber-deep:#C6862B; --verify:#54D6A8; --verify-soft:rgba(84,214,168,0.14);
  --shadow:0 22px 50px -28px rgba(0,0,0,0.75); color-scheme:dark;
}
:root[data-theme="light"]{
  --ground:#F4F6FB; --surface:#FFFFFF; --surface-2:#EDF1F8;
  --ink:#111726; --ink-dim:#515C73; --ink-faint:#8A93A6;
  --line:rgba(17,23,38,0.10); --line-strong:rgba(17,23,38,0.20);
  --amber:#A96C0C; --amber-deep:#835309; --verify:#0E8A66; --verify-soft:rgba(14,138,102,0.12);
  --shadow:0 20px 44px -26px rgba(20,32,56,0.28); color-scheme:light;
}

*{box-sizing:border-box;}
html,body{margin:0;padding:0;}
body{
  background:var(--ground); color:var(--ink);
  font-family:var(--sans); line-height:1.6; -webkit-font-smoothing:antialiased;
  text-rendering:optimizeLegibility;
}
body::before{
  content:""; position:fixed; inset:0; pointer-events:none; z-index:0;
  background:
    radial-gradient(120% 60% at 50% -8%, color-mix(in oklab, var(--amber) 12%, transparent), transparent 60%);
  opacity:0.5;
}
.wrap{position:relative; z-index:1; max-width:var(--maxw); margin:0 auto; padding:0 22px;}

/* ---- header ---- */
header{
  display:flex; align-items:center; justify-content:space-between;
  padding:22px 0 0; max-width:var(--maxw); margin:0 auto; position:relative; z-index:2;
}
.mark{font-family:var(--mono); font-weight:600; font-size:0.82rem; letter-spacing:0.14em; text-transform:uppercase; color:var(--ink);}
.mark .dot{color:var(--amber);}
.toggle{
  font-family:var(--mono); font-size:0.68rem; letter-spacing:0.1em; text-transform:uppercase;
  background:transparent; border:1px solid var(--line-strong); color:var(--ink-dim);
  padding:6px 11px; border-radius:999px; cursor:pointer;
}
.toggle:hover{color:var(--ink); border-color:var(--ink-dim);}
.toggle:focus-visible{outline:2px solid var(--amber); outline-offset:2px;}

/* ---- eyebrow / labels ---- */
.eyebrow{
  font-family:var(--mono); font-size:0.7rem; font-weight:600;
  letter-spacing:0.2em; text-transform:uppercase; color:var(--amber);
}
.k{ font-family:var(--mono); font-size:0.68rem; letter-spacing:0.13em; text-transform:uppercase; color:var(--ink-faint); }

/* ---- hero ---- */
.hero{padding:60px 0 8px;}
.hero h1{
  font-weight:800; font-size:clamp(2.5rem,10.5vw,4rem); line-height:1.02;
  letter-spacing:-0.025em; margin:20px 0 0; text-wrap:balance;
}
.hero h1 .hl{color:var(--amber);}
.hero p.lede{
  font-size:1.12rem; color:var(--ink-dim); margin:22px 0 0; max-width:34em; text-wrap:pretty;
}

/* ---- proof strip ---- */
.proof{margin:34px 0 0; display:flex; flex-direction:column; gap:10px;}
.addr{
  display:block; text-decoration:none; color:inherit;
  background:var(--surface); border:1px solid var(--line); border-radius:14px;
  padding:15px 16px; transition:border-color .18s ease, transform .18s ease;
}
.addr:hover{border-color:var(--line-strong); transform:translateY(-1px);}
.addr:focus-visible{outline:2px solid var(--amber); outline-offset:2px;}
.addr-top{display:flex; align-items:center; gap:10px; margin-bottom:8px;}
.addr-name{font-weight:600; font-size:0.98rem;}
.pill{
  font-family:var(--mono); font-size:0.6rem; font-weight:600; letter-spacing:0.14em; text-transform:uppercase;
  color:var(--verify); background:var(--verify-soft); border:1px solid color-mix(in oklab,var(--verify) 40%,transparent);
  padding:3px 8px; border-radius:999px; display:inline-flex; align-items:center; gap:6px; white-space:nowrap;
}
.pill .live{width:6px; height:6px; border-radius:50%; background:var(--verify); box-shadow:0 0 0 0 var(--verify);}
.addr-desc{color:var(--ink-dim); font-size:0.86rem; margin:0 0 9px;}
.addr-hash{
  font-family:var(--mono); font-size:0.78rem; color:var(--ink); word-break:break-all; letter-spacing:-0.01em;
}
.addr-hash .arrow{color:var(--amber); white-space:nowrap;}
.addr-meta{font-family:var(--mono); font-size:0.66rem; color:var(--ink-faint); margin-top:7px; letter-spacing:0.05em;}

/* ---- section scaffold ---- */
section.block{padding:52px 0 0;}
.block > .eyebrow{margin-bottom:16px;}
h2{font-weight:800; font-size:1.65rem; letter-spacing:-0.02em; margin:0 0 6px; text-wrap:balance;}
.block-sub{color:var(--ink-dim); margin:0 0 22px; font-size:0.98rem;}

/* ---- system cards ---- */
.systems{display:flex; flex-direction:column; gap:12px;}
.card{
  background:var(--surface); border:1px solid var(--line); border-radius:16px; padding:18px;
  transition:border-color .18s ease, transform .18s ease;
}
.card:hover{border-color:var(--line-strong); transform:translateY(-1px);}
.card-top{display:flex; align-items:center; justify-content:space-between; gap:12px; margin-bottom:9px;}
.card-name{font-weight:700; font-size:1.06rem; letter-spacing:-0.01em;}
.pill.run{color:var(--amber); background:color-mix(in oklab,var(--amber) 14%,transparent); border-color:color-mix(in oklab,var(--amber) 38%,transparent);}
.pill.run .live{background:var(--amber);}
.card p{margin:0; color:var(--ink-dim); font-size:0.9rem;}
.card a.link{
  display:inline-block; margin-top:12px; font-family:var(--mono); font-size:0.74rem; font-weight:600;
  letter-spacing:0.04em; color:var(--amber); text-decoration:none; border-bottom:1px solid color-mix(in oklab,var(--amber) 45%,transparent); padding-bottom:1px;
}
.card a.link:hover{border-bottom-color:var(--amber);}
.card a.link:focus-visible{outline:2px solid var(--amber); outline-offset:3px;}
.card .tags{margin-top:12px; display:flex; flex-wrap:wrap; gap:6px;}
.tag{font-family:var(--mono); font-size:0.64rem; letter-spacing:0.06em; color:var(--ink-faint); border:1px solid var(--line); border-radius:6px; padding:3px 7px;}

/* ---- stat readout ---- */
.readout{
  margin-top:4px; border:1px solid var(--line); border-radius:16px; overflow:hidden;
  display:grid; grid-template-columns:repeat(2,1fr); background:var(--surface);
}
.stat{padding:18px 16px; border-right:1px solid var(--line); border-bottom:1px solid var(--line);}
.stat:nth-child(2n){border-right:none;}
.stat .num{font-family:var(--mono); font-weight:600; font-size:1.7rem; letter-spacing:-0.02em; color:var(--ink); font-variant-numeric:tabular-nums;}
.stat .num em{font-style:normal; color:var(--amber);}
.stat .lbl{font-family:var(--mono); font-size:0.64rem; letter-spacing:0.12em; text-transform:uppercase; color:var(--ink-dim); margin-top:4px;}
.stat.wide{grid-column:1 / -1; border-right:none;}
.stat:nth-last-child(1), .stat:nth-last-child(2){border-bottom:none;}

/* ---- quote ---- */
.quote{
  margin-top:26px; padding:24px 22px; border-left:2px solid var(--amber);
  background:var(--surface-2); border-radius:0 14px 14px 0;
}
.quote p{margin:0; font-size:1.14rem; line-height:1.5; font-weight:600; letter-spacing:-0.01em; text-wrap:balance;}
.quote .cite{font-family:var(--mono); font-size:0.66rem; letter-spacing:0.1em; text-transform:uppercase; color:var(--ink-faint); margin-top:12px;}

/* ---- method prose ---- */
.method p{color:var(--ink-dim); font-size:0.98rem; margin:0 0 14px;}
.method p strong{color:var(--ink); font-weight:600;}

/* ---- stack grid ---- */
.stack{display:grid; grid-template-columns:1fr; gap:1px; background:var(--line); border:1px solid var(--line); border-radius:16px; overflow:hidden;}
.slot{background:var(--surface); padding:16px 18px;}
.slot h3{margin:0 0 4px; font-family:var(--mono); font-size:0.74rem; font-weight:600; letter-spacing:0.1em; text-transform:uppercase; color:var(--amber);}
.slot p{margin:0; font-size:0.86rem; color:var(--ink-dim);}

/* ---- cta ---- */
.cta{margin:56px 0 0; padding:34px 24px; text-align:center; background:var(--surface); border:1px solid var(--line-strong); border-radius:20px;}
.cta h2{font-size:1.5rem; margin-bottom:8px;}
.cta p{color:var(--ink-dim); margin:0 auto 20px; max-width:30em; font-size:0.98rem;}
.btn{
  display:inline-block; font-family:var(--mono); font-weight:600; font-size:0.86rem; letter-spacing:0.04em;
  background:var(--amber); color:#0A0D13; text-decoration:none; padding:13px 22px; border-radius:12px;
  transition:transform .16s ease, background .16s ease;
}
.btn:hover{transform:translateY(-2px); background:var(--amber-deep); color:#0A0D13;}
.btn:focus-visible{outline:2px solid var(--ink); outline-offset:3px;}
:root[data-theme="light"] .btn, @media (prefers-color-scheme:light){}
.cta .alt{display:block; margin-top:14px; font-family:var(--mono); font-size:0.72rem; color:var(--ink-faint); letter-spacing:0.05em;}

/* ---- footer ---- */
footer{margin:44px 0 40px; padding-top:22px; border-top:1px solid var(--line); text-align:center;}
footer .line{font-family:var(--mono); font-size:0.66rem; letter-spacing:0.1em; text-transform:uppercase; color:var(--ink-faint);}
footer .line .dot{color:var(--amber);}

/* ---- motion ---- */
@media (prefers-reduced-motion:no-preference){
  .reveal{opacity:0; transform:translateY(14px); animation:rise .7s cubic-bezier(.2,.7,.2,1) forwards;}
  .d1{animation-delay:.05s;} .d2{animation-delay:.14s;} .d3{animation-delay:.24s;}
  .d4{animation-delay:.34s;} .d5{animation-delay:.44s;}
  @keyframes rise{to{opacity:1; transform:none;}}
  .pill .live{animation:breathe 2.6s ease-in-out infinite;}
  @keyframes breathe{0%,100%{box-shadow:0 0 0 0 color-mix(in oklab,var(--verify) 55%,transparent);}50%{box-shadow:0 0 0 5px transparent;}}
  .pill.run .live{animation:breatheA 2.6s ease-in-out infinite;}
  @keyframes breatheA{0%,100%{box-shadow:0 0 0 0 color-mix(in oklab,var(--amber) 55%,transparent);}50%{box-shadow:0 0 0 5px transparent;}}
}

@media (min-width:560px){
  .stack{grid-template-columns:1fr 1fr;}
  .slot:nth-child(odd){border-right:1px solid var(--line);}
}
</style>
</head>
<body>
<header>
  <div class="mark">JON&nbsp;SOLO<span class="dot">.</span></div>
  <button class="toggle" id="themeToggle" aria-label="Toggle light and dark theme">Theme</button>
</header>

<div class="wrap">

  <section class="hero">
    <div class="eyebrow reveal d1">Mobile-origin &middot; Base mainnet &middot; Verifiable</div>
    <h1 class="reveal d2">Production systems, shipped from a <span class="hl">phone</span>.</h1>
    <p class="lede reveal d3">I architect systems and direct multi-model AI builds &mdash; then verify every line to green before it ships. Live smart contracts on Base mainnet right now. No desktop, ever.</p>

    <div class="proof reveal d4">
      <a class="addr" href="https://basescan.org/address/0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91" target="_blank" rel="noopener">
        <div class="addr-top">
          <span class="addr-name">PossessioPayments</span>
          <span class="pill"><span class="live"></span>Live &middot; Base</span>
        </div>
        <p class="addr-desc">Non-custodial merchant payment processor. Zero protocol custody, deployed and owned by the merchant.</p>
        <div class="addr-hash">0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91 <span class="arrow">&rarr; BaseScan</span></div>
        <div class="addr-meta">chain 8453 &middot; verified bytecode &middot; tap to confirm on-chain</div>
      </a>
      <a class="addr" href="https://basescan.org/address/0xDDb75e974d99FcF95E241adbFD376861c47a8548" target="_blank" rel="noopener">
        <div class="addr-top">
          <span class="addr-name">LSTExchangeRate</span>
          <span class="pill"><span class="live"></span>Live &middot; Base</span>
        </div>
        <p class="addr-desc">Fail-closed cbETH valuation guard &mdash; dual-source (Chainlink + AMM TWAP), halts on &gt;2% divergence rather than averaging through it.</p>
        <div class="addr-hash">0xDDb75e974d99FcF95E241adbFD376861c47a8548 <span class="arrow">&rarr; BaseScan</span></div>
        <div class="addr-meta">chain 8453 &middot; verified bytecode &middot; tap to confirm on-chain</div>
      </a>
    </div>
  </section>

  <section class="block">
    <div class="eyebrow">Live systems</div>
    <h2>Shipped, not slideware.</h2>
    <p class="block-sub">Every item here is deployed and running. Two are on-chain and verifiable; one you can install right now.</p>
    <div class="systems">

      <div class="card">
        <div class="card-top">
          <span class="card-name">Superfoods &mdash; grocery app</span>
          <span class="pill"><span class="live"></span>Live</span>
        </div>
        <p>A full-stack installable app I built solo, front to back: live inventory synced from the store's real vendor data feed (~600 items with prices and photos, auto-updating), the weekly ad as its own curated view, offline support, and an Android / Play Store packaging pipeline.</p>
        <div class="tags"><span class="tag">Cloudflare Workers</span><span class="tag">D1</span><span class="tag">PWA</span><span class="tag">reverse-engineered feed</span></div>
        <a class="link" href="https://superfoods-logan.jonb89201.workers.dev" target="_blank" rel="noopener">Open the live app &rarr;</a>
      </div>

      <div class="card">
        <div class="card-top">
          <span class="card-name">POSSESSIO &mdash; DeFi protocol</span>
          <span class="pill"><span class="live"></span>Live &middot; Base</span>
        </div>
        <p>A deterministic, non-custodial protocol spanning <strong>Base and Ethereum L1</strong>: Uniswap V4 hooks (CREATE3 salt-mined, bytecode-independent addresses), Chainlink Automation, and a per-merchant Ethereum-mainnet settlement layer (L1Anchor) architected to route institutional capital into staking and lending venues. Three contracts live on Base mainnet; the rest fork-proven behind a green gate.</p>
        <div class="tags"><span class="tag">Solidity</span><span class="tag">Foundry</span><span class="tag">Uniswap V4</span><span class="tag">Chainlink</span><span class="tag">Ethereum L1</span></div>
      </div>

      <div class="card">
        <div class="card-top">
          <span class="card-name">Radar &mdash; market instrument</span>
          <span class="pill run"><span class="live"></span>Running</span>
        </div>
        <p>A self-running measurement worker on <strong>Solana</strong> that watches new-token births (pump.fun) on a 60-second cadence, tracks each one's price trajectory, and detects graduation to real liquidity. It corrects its own measurement biases and has run unattended for days &mdash; tens of thousands of tokens tracked and counting.</p>
        <div class="tags"><span class="tag">Solana</span><span class="tag">Workers cron</span><span class="tag">D1</span><span class="tag">self-correcting</span></div>
      </div>

    </div>
  </section>

  <section class="block">
    <div class="eyebrow">The receipts</div>
    <h2>Numbers that hold up to inspection.</h2>
    <p class="block-sub">Run <span class="k">forge&nbsp;test</span> yourself. Query the chain yourself. Nothing here is a claim you can't check.</p>
    <div class="readout">
      <div class="stat"><div class="num">690</div><div class="lbl">Passing tests</div></div>
      <div class="stat"><div class="num">33</div><div class="lbl">Test suites</div></div>
      <div class="stat"><div class="num">13</div><div class="lbl">Contracts authored</div></div>
      <div class="stat"><div class="num"><em>3</em></div><div class="lbl">Live on Base mainnet</div></div>
      <div class="stat wide"><div class="num"><em>3</em> chains</div><div class="lbl">Base &amp; Ethereum contracts &middot; a live Solana instrument &middot; 100% built on a phone</div></div>
    </div>
  </section>

  <section class="block method">
    <div class="eyebrow">How the work gets made</div>
    <h2>Architect the system. Direct the build. Verify to green.</h2>
    <p>I don't write every line by hand &mdash; I design the system, then <strong>direct a council of AI models</strong> (Claude, GPT, Gemini, Grok) to build it under tight structural discipline: documented principles, procedural governance, and verification after every single step. The output is real model reasoning held to a hard standard, not vibes.</p>
    <p>And all of it runs on a phone. Mobile-only isn't a limitation I worked around &mdash; it's an operating mode that <strong>forces</strong> discipline desktop development lets you skip: one command at a time, a fresh terminal every session, atomic commits, a verification pass after every push. That rigor shows up directly in the code.</p>

    <div class="quote">
      <p>&ldquo;If it can't be tested it doesn't exist. If it's not in the terminal it's not proven.&rdquo;</p>
      <div class="cite">&mdash; operating principle, in the repo</div>
    </div>
  </section>

  <section class="block">
    <div class="eyebrow">The stack</div>
    <h2>Front-to-back, metal to market.</h2>
    <div class="stack">
      <div class="slot"><h3>Smart contracts</h3><p>Solidity, Foundry, Uniswap V4 hooks, CREATE3, Chainlink feeds &amp; Automation. Adversarial, invariant &amp; fork testing. Live mainnet deploys.</p></div>
      <div class="slot"><h3>Edge &amp; backend</h3><p>Cloudflare Workers, D1, KV, cron-driven pipelines, secrets &amp; infra. Systems that run themselves, unattended.</p></div>
      <div class="slot"><h3>Frontend &amp; mobile</h3><p>PWAs, service workers, offline caching, responsive UI, PWA-to-Play-Store packaging.</p></div>
      <div class="slot"><h3>Data integration</h3><p>Reverse-engineering client-rendered SPAs and undocumented APIs into clean, normalized, usable feeds.</p></div>
      <div class="slot"><h3>AI orchestration</h3><p>Designing and directing multi-model builds that ship verified production code &mdash; a repeatable way to move fast without dropping rigor.</p></div>
      <div class="slot"><h3>Delivery</h3><p>DNS, domains, deployment across services, and the discipline to verify before shipping &mdash; every time.</p></div>
    </div>
  </section>

  <div class="cta">
    <h2>Got something hard to build?</h2>
    <p>Open to contract work, one-off builds, or ongoing collaboration &mdash; if the scope and price line up. Tell me what you're trying to ship.</p>
    <a class="btn" href="mailto:jon@possessio.io?subject=Let%27s%20build%20something">jon@possessio.io</a>
    <span class="alt">Verify anything above before you reply. That's the point.</span>
  </div>

  <footer>
    <div class="line">possessio.io <span class="dot">&middot;</span> built on a phone <span class="dot">&middot;</span> shipped to mainnet</div>
  </footer>

</div>

<script>
(function(){
  var btn=document.getElementById('themeToggle');
  btn.addEventListener('click',function(){
    var root=document.documentElement;
    var cur=root.getAttribute('data-theme');
    var next = cur ? (cur==='dark'?'light':'dark')
                   : (matchMedia('(prefers-color-scheme: dark)').matches ? 'light' : 'dark');
    root.setAttribute('data-theme',next);
  });
})();
</script>
</body>
</html>
"""

html = (TEMPLATE
        .replace("__ARCHIVO__", fonts["archivo"])
        .replace("__MONO400__", fonts["mono400"])
        .replace("__MONO600__", fonts["mono600"]))

out = pathlib.Path("/home/user/Possessio/pitch/index.html")
out.write_text(html)
print("wrote", out, len(html), "bytes")
