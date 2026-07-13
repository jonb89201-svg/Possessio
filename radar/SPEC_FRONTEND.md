# POSSESSIO Radar — Frontend Design Spec

*One self-contained, self-polling web page (`feed.ts` → `FEED_HTML`) served at
`/feed`. Zero build step, zero framework, zero dependencies — a single HTML
document with inline CSS + vanilla JS. Styled to match the POSSESSIO console so
the two read as one product.*

---

## 1. Architecture

- **Delivery.** The whole UI is one template string (`FEED_HTML`) returned by
  the worker. No bundler, no npm, no external JS. It loads only Google Fonts.
- **Data flow.** On load and every **5 seconds**, it `fetch`es
  `/radar/candidates` (cache: no-store), stashes the JSON in `lastData`, and
  calls `render(d)`. The server holds all state; the page is a pure view.
- **Payload shape.** `{ live[], early[], recent[], earlyPlay[], tally[],
  ticks{tokenAddr: [{ms, mc, sol, v5}]} }`. Every oscillator is computed
  **client-side from `ticks`** — the server ships raw series, the page derives
  sparklines, rate-of-change, and net flow.
- **Interaction re-render.** The "hide SKIPs" toggle re-renders instantly from
  `lastData` instead of waiting for the next poll.

---

## 2. Design system (matched to `public/index.html`)

**Type.**
- `Inter` — body, labels, names.
- `Space Grotesk` — the H1, section heads, and the big stat numbers.
- `IBM Plex Mono` — every number: MC, %, flow, ages, sparklines. Monospace keeps
  the columns readable like a real terminal readout.

**Palette (light, console tokens).** White surfaces (`--bg`/`--surface-2/3`),
soft-slate lines (`--line`), dark-slate ink scale (`--ink`/`--dim`/`--faint`),
and the console's semantic accents:

| Token | Hex | Meaning in the radar |
|---|---|---|
| `--oxide` | `#1d4ed8` | live / links / oscillators / primary accent |
| `--council` | `#16a34a` | up · FLOW IN · target · win |
| `--danger` | `#dc2626` | down · SKIP · stop · loss |
| `--treasury` | `#0891b2` | DEX / graduated / on-chain boundary |
| `--open` | `#7c3aed` | early / pre-qualify |

Each has a `-dim` and a `-faint`; badges use the **faint fill + dim text** pill
style from the console's `.tag`. Radius `12px` (cards) / `9999px` (pills). The
render JS's inline color vars (`--green/--red/--blue/--gold/--dim`) are **aliased**
to these tokens so no JS needed touching on the restyle.

---

## 3. Page layout (top → bottom = the decision, in order)

1. **Header** — pulsing dot + `POSSESSIO RADAR — AI LIVE SELECTION`, one-line
   subtitle.
2. **Method frame** — the honest framing card ("most picks fail by design…
   you're watching a discipline, not hot buys") + the live tally stats
   (`live now · hit target · stopped · graduated · timed out`).
3. **§0 ledger line** — `full ladders · bell exits (avg Nx) · ladder rate`.
4. **Flow-gate bar** — the proven-screen explainer, a **`hide SKIPs`** checkbox,
   and a live counter: `N IN · N weak · N skip · N reading`.
5. **Early radar** — *live/unresolved only*. The flow-gated shortlist you'd
   actually enter.
6. **Live — in the entry window now** — the §1 candidates being tracked.
7. **Recently Closed** — concluded §0 trades **merged** with §1 closes,
   newest-close first.
8. **Promo** — "the eye is free, the hand is x402Core" — and the honest footer.

The ordering *is* the information architecture: **what to screen → what you're
holding → what already closed.** Every row lives in the section that matches what
you'd do with it.

---

## 4. Row anatomy

Each row is a two-column flex: identity/oscillators on the left, verdict/price on
the right.

- **Launch image** (`img`) — 36px rounded thumbnail from pump.fun's `image_uri`.
  Coins are recognizable by face, not just ticker. Hides itself if the IPFS
  image is broken.
- **Symbol + name + links** — `pump ↗` / `chart ↗`.
- **Age line** — `hit $3.5k at Ns old · Nm ago`.
- **WS flow-quality line** (`flowQ`, when trade data exists) — `⚡ Ns to $3.5k ·
  N buyers · B/S · +N SOL · N% top wallet`.
- **Oscillator row** (`spark` `roc` `flow`) — the sparkline, per-tick rate of
  change, and the net **SOL/min** flow readout with the `⚡steady` badge.
- **Right column** — the gate tag (live) or the settled badge (closed), then the
  MC line `entry → now/exit (±%)` and a `peak` line.
- **Post-grad line** (`postGrad`) — for graduated coins: `🚀 RAN ON DEX · peak
  $X · Nx past exit` — the run *after* the paper exit (the DAYNA/WANSEM story).

---

## 5. Client-computed oscillators (from `ticks`)

- **`spark(ticks)`** — a min-max-normalized unicode block sparkline (`▁▂▃▄▅▆▇█`)
  of the last ~14 MC samples.
- **`roc(ticks)`** — last-tick % rate of change.
- **`flow(ticks)`** — net **SOL/min** over the last ~1min of `sol_reserves`
  deltas + a `⚡steady` badge when 3+ of the last 4 deltas are positive.
- **`flowRate(ticks)`** — the numeric net SOL/min (drives the gate). `null` until
  ~2 ticks (~45s) exist — honest about the read latency.

---

## 6. The Flow Gate (the headline UX)

Every live early is classified by `flowRate` and the row is styled to match — the
proven "don't play the 78%" screen made visual:

| Class | Rule | Visual |
|---|---|---|
| **FLOW IN** | `> 2 SOL/min` | green left-border, council-faint tint, green pill — *the 1.37× / 84%-green movers* |
| **weak +** | `0–2` | teal left-border, teal pill |
| **SKIP** | `≤ 0` (net selling) | **dimmed to 40% opacity**, red pill — *the 0.74× duds recede* |
| **reading…** | `< ~45s of tape` | grey pill, direction not yet known |

Plus the **`hide SKIPs`** toggle to collapse the duds entirely, and the live
`IN / weak / skip / reading` counter. A dud that **concludes** without profit and
never graduated simply vanishes (it's not in the live set and doesn't clutter
Recently Closed); a `die` CSS animation is staged for the fade-off.

---

## 7. Badges

Pill style throughout (faint fill + dim text):
- Live/§1: `live`, `graduated`.
- §0 settled (`playBadge`): `ladder ✓ (L<n> ×<compound>)` for full ladders/cycles;
  `sell +/−%` green/red by P/L; `gap`; `late`.
- §1 settled (`sellBadge`): `sell +/−%` colored by exit-vs-entry (a stop is a
  *sell*, colored by whether it made money — not a red "failure").

---

## 8. Responsive / mobile

Built mobile-first (it is used from a phone terminal + browser): `max-width:760px`
centered column, `viewport-fit=cover`, `theme-color:#fff`, flex rows that wrap,
thumbnails and pills sized for thumb-glanceability. The whole feed is meant to be
read in one downward scroll and acted on in a second.

---

## 9. Design principle

**Organize around the decision, not the data.** The page never makes you hunt for
the actionable thing — the flow-gated live shortlist is the top of the screen, the
duds dim out of the way, and a concluded trade moves to where concluded trades
live. The backend retrieves the truth; the frontend's only job is to translate it
into a decision fast enough to act on.
