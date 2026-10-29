# The possessio.io landing page (not served)

Drafted in PR #198, then set aside on 2026-10-29: possessio.io forwards to Taproot (taproot.possessio.io), the app on
Google Play. The Architect may give the landing page a subdomain of its own; it needs no mini app.

To serve it there, copy this folder with `icon-1024.png` from `public/` beside it. The page already links its images
relatively, and its preview image points at `https://possessio.io/og.png`, which possessio.io still serves.

Before serving it, drop its `fc:miniapp` tag: it still points at the retired console, and the mini app is Taproot's now.
