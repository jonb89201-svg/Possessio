#!/usr/bin/env node
// THE SCRUBBER — refuses to let a credential become permanent.
//
// WHY THIS EXISTS. Git is append-only in practice. A secret committed and then
// "removed" in a later commit is still in history, still fetchable by SHA after
// a force-push until GitHub garbage-collects, and still present in every fork,
// clone and CI cache that ever pulled it. Private visibility does not change
// this: private is an access-control setting, not a property of the data, and it
// flips with one click, one collaborator, one OAuth grant. So the only moment
// that matters is BEFORE the write.
//
// The precedent is not hypothetical. Claude share links were "protected" by
// robots.txt Disallow — which prevents crawling, not indexing — and Google
// indexed them anyway from inbound links. Medical records and children's phone
// numbers ended up in search results. The boundary was a polite request
// addressed to well-behaved participants. This tool is not that: it fails
// closed, and it is enforced in CI where nothing can skip it.
//
// THE HARD PART, and it is specific to this repo. POSSESSIO is FULL of
// high-entropy strings that are NOT secrets: mined CREATE3 salts, keccak
// digests, tx hashes, contract addresses, initcode blobs, PUSH4 selectors. A
// naive entropy scanner flags every one of them, you add exclusions daily, and
// within a week you are typing --no-verify by reflex. A scanner that cries wolf
// is worse than no scanner, because it trains the bypass.
//
// So detection is two-tier, and leans on one discriminator that happens to be
// almost perfect here:
//
//   THE PUBLISHED ARTIFACTS IN THIS REPO ARE 0x-PREFIXED.
//   THE SECRETS IN THIS STACK ARE NOT.
//
// QuickNode tokens are bare hex in a URL path. Solana keys are base58 or int
// arrays. Every 64-hex value this protocol publishes on purpose carries 0x.
// That single distinction separates nearly the whole true-positive set from
// nearly the whole false-positive set; contextual rules clean up the rest.
//
// THE KNOWN GAP, stated rather than papered over: an EVM private key is 64 hex
// and may be 0x-prefixed, which is byte-identical to a tx hash. Nothing can tell
// those apart by shape. That case is caught only by variable name (RULE
// named-secret-assignment) and, properly, by never letting a seat key near a
// file at all. This tool is the backstop for accidents, not a substitute for
// keeping secrets out of files.
//
// USAGE
//   node tools/scrub.mjs --check              scan every tracked file
//   node tools/scrub.mjs --check --staged     scan STAGED content (pre-commit)
//   node tools/scrub.mjs --check <paths...>   scan specific paths
//   node tools/scrub.mjs --redact <file>      write a redacted copy to stdout
//
// Exit 0 clean, 1 on any BLOCK finding, 0 on WARN-only (warnings are printed).

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const ALLOW_FILE = path.join(ROOT, "tools", "scrub-allow.txt");

// ---------------------------------------------------------------------------
// Paths never scanned. Vendored code, build output and lockfiles are not places
// this protocol writes secrets, and scanning them is pure noise. lib/ is six git
// submodules.
// ---------------------------------------------------------------------------
const SKIP_DIRS = ["node_modules/", "lib/", "out/", "cache/", "dist/", ".git/", "broadcast/"];
// foundry.lock is a list of 40-hex git SHAs — and a QuickNode token is ALSO
// bare 40-hex, which is why bare-high-entropy-hex is a warning and not a block.
const SKIP_FILES = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "foundry.lock"];
// Prose. Where measured evidence gets published, not where secrets get assigned.
const PROSE_EXT = new Set([".md", ".txt", ".rst"]);
const SKIP_EXT = [".hex", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".woff", ".woff2", ".tar", ".gz", ".wasm"];

// ---------------------------------------------------------------------------
// A value that is obviously a stand-in is never a finding. Without this the
// tool fires on its own documentation — `<STORE_ID>`, `your-key-here`,
// `wrangler secret put SOLANA_RPC` — and teaches the bypass on day one.
// ---------------------------------------------------------------------------
const PLACEHOLDER = /^(?:[<${].*|x{3,}|0+|a{8,}|(?:your|my|the)[-_ ].*|example.*|placeholder.*|redacted.*|changeme.*|dummy.*|fake.*|test[-_]?(?:key|token|secret)?.*|\.{3}.*|null|undefined|none|unset|TODO.*)$/i;

// Templating is unambiguous and applies to EVERY rule: `<STORE_ID>`, `${VAR}`,
// an already-redacted marker. None of these can be a live credential.
const isTemplated = (s) => s.includes("<") || s.includes("${") || s.includes("REDACTED");

// The word heuristic is much weaker and is deliberately NOT applied to rules
// whose match shape is itself the evidence.
//
// MEASURED, by running the end-to-end hook test: a probe URL hosted at
// `fake-owl.quiknode.pro/<40 hex>` was silently exempted, because the word list
// matched `fake.*` against the WHOLE matched URL — hostname included. QuickNode
// generates hostnames from an English word list, so a real endpoint can be
// named anything; a token was one lucky hostname away from being waved through.
//
// Structural rules do not need this heuristic anyway: documentation writes the
// token position as `<TOKEN>` or `your-key-here`, and neither can match a
// `{16,}` hex/base58 class. So the word list is confined to rules whose value is
// free text (an assignment) or a bare entropy run.
const isPlaceholderWord = (s) => PLACEHOLDER.test(s.trim());

// ---------------------------------------------------------------------------
// RULES. `block` refuses the commit. `warn` reports and lets it through — used
// only where a false positive is plausible, so that BLOCK stays trustworthy.
// ---------------------------------------------------------------------------
const RULES = [
  {
    id: "quicknode-url",
    severity: "block",
    re: /\b[a-z0-9-]+\.(?:quiknode|quicknode)\.pro\/[0-9a-zA-Z_-]{16,}/g,
    why: "QuickNode auth is the URL path. Possession of this string IS authentication — there is no second factor and no separate key to rotate.",
  },
  {
    id: "rpc-url-embedded-key",
    severity: "block",
    re: /\b(?:[a-z0-9-]+\.)?(?:alchemy\.com\/v2|infura\.io\/v3|blastapi\.io|getblock\.io|nodereal\.io\/v1)\/[0-9a-zA-Z_-]{16,}/g,
    why: "RPC provider key embedded in a URL path — a bearer credential wearing a URL costume.",
  },
  {
    id: "url-api-key-param",
    severity: "block",
    re: /[?&](?:api[-_]?key|apikey|access[-_]?token|auth[-_]?token)=[A-Za-z0-9._~-]{16,}/gi,
    why: "Credential in a query string. URLs leak through referrers, proxy logs, browser history and crawlers.",
  },
  {
    id: "solana-keypair-json",
    severity: "block",
    // A Solana secret key serialises as exactly 64 bytes. 48+ entries cannot be
    // anything else in this repo.
    re: /\[\s*(?:\d{1,3}\s*,\s*){47,}\d{1,3}\s*\]/g,
    why: "This is the shape of a serialised Solana keypair (64 bytes). A signing key must never reach a file in this repo.",
  },
  {
    id: "solana-base58-secret",
    severity: "block",
    // 87-88 base58 chars is a 64-byte secret key. A PUBKEY is 43-44 and is
    // deliberately not matched — public addresses are published constantly here.
    re: /\b[1-9A-HJ-NP-Za-km-z]{87,88}\b/g,
    why: "88-char base58 is a Solana SECRET key (a public address is 44 and is not flagged).",
    // SECOND KNOWN SHAPE COLLISION, and it is exact: a Solana TRANSACTION
    // SIGNATURE is also 64 bytes, so it is also 87-88 base58 characters. There
    // is no way to tell a signature from a secret key by shape alone — only by
    // context.
    //
    // This protocol publishes tx signatures constantly: they are the evidence
    // that a measurement happened, and laws/STATEMENT_nonce_burn_measured.md
    // exists to carry one. Blocking on prose would make the scrubber refuse the
    // repo's own proof artifacts, which is precisely how a tool teaches people
    // to bypass it. So in prose it WARNS and in code it BLOCKS — a key gets
    // assigned to something, evidence gets written down.
    proseIsWarn: true,
  },
  {
    id: "pem-private-key",
    severity: "block",
    re: /-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----/g,
    why: "PEM private key block.",
  },
  {
    id: "bearer-token",
    severity: "block",
    re: /\bBearer\s+[A-Za-z0-9._~+/-]{24,}=*/g,
    why: "Literal bearer token.",
  },
  {
    id: "named-secret-assignment",
    severity: "block",
    // The only rule that catches an EVM private key, because 0x + 64 hex is
    // byte-identical to a tx hash and the NAME is the sole discriminator.
    // `(` is excluded from the value class deliberately. A literal secret never
    // contains one, but documentation is full of `privKey = keccak256(phrase)`
    // — and AUDIT_20260723.md:311 is exactly that sentence. Without this the
    // tool blocks the repo's own security write-ups for describing an attack.
    re: /\b([A-Z0-9_]*(?:PRIVATE_KEY|PRIVKEY|SEAT_KEY|SIGNER_KEY|SECRET_KEY|MNEMONIC|SEED_PHRASE|API_KEY|ACCESS_KEY|AUTH_TOKEN|PASSWORD)[A-Z0-9_]*)\s*[:=]\s*["'`]?([^\s"'`,;)(}\]]{12,})/gi,
    why: "A secret-named identifier assigned a literal value. Reference secrets by name and store the value outside the repo.",
    wordPlaceholders: true,   // the value is free text, so `your-key-here` must not fire
    // Report the VALUE, not the whole match, so the identifier can be shown
    // while the value is masked.
    capture: 2,
  },
  {
    id: "bare-high-entropy-hex",
    severity: "warn",
    // Deliberately WARN. In this repo a bare (non-0x) 40+ hex run is usually an
    // API token, but it is also how some fixtures and digests get written, and a
    // false BLOCK here would poison the whole tool's credibility.
    // Two exclusions, both learned by running this against the repo:
    //
    //   (?=[0-9a-f]*[a-f])  requires at least one LETTER. Without it the rule
    //   fires on long DECIMAL constants, because 0-9 are also hex digits —
    //   src/PLATE.sol's MAX_SQRT_RATIO (a 49-digit uint160) matched. A real
    //   token of 40+ hex chars without a single a-f is vanishingly unlikely.
    //
    //   @ in the lookbehind  drops `forge install pkg@<40-hex>`, which is a git
    //   SHA. Note a QuickNode token is ALSO bare 40-hex — that exact collision
    //   is why this rule warns instead of blocking, and why the token is caught
    //   by its URL context in quicknode-url instead.
    re: /(?<![0-9a-fx@])(?<!0x)\b(?=[0-9a-f]*[a-f])[0-9a-f]{40,}\b/g,
    wordPlaceholders: true,
    why: "Bare high-entropy hex with no 0x prefix. Published artifacts here are 0x-prefixed; tokens are not. Confirm, then allowlist it if benign.",
  },
];

// ---------------------------------------------------------------------------
function loadAllow() {
  const literals = new Set();
  const globs = [];
  if (!existsSync(ALLOW_FILE)) return { literals, globs };
  for (const raw of readFileSync(ALLOW_FILE, "utf8").split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.startsWith("path:")) globs.push(line.slice(5).trim());
    else literals.add(line);
  }
  return { literals, globs };
}

const skipPath = (f, globs) =>
  SKIP_DIRS.some((d) => f.startsWith(d) || f.includes("/" + d)) ||
  SKIP_FILES.includes(path.basename(f)) ||
  SKIP_EXT.includes(path.extname(f).toLowerCase()) ||
  globs.some((g) => f === g || f.startsWith(g.replace(/\*$/, "")));

const mask = (s) =>
  s.length <= 12 ? "*".repeat(s.length) : `${s.slice(0, 4)}…${"*".repeat(8)}…${s.slice(-2)} (${s.length} chars)`;

/// Scan one blob. Returns findings; never returns the secret itself unmasked.
export function scan(text, file, allow = { literals: new Set() }) {
  const found = [];
  const lines = text.split("\n");
  for (const rule of RULES) {
    for (let n = 0; n < lines.length; n++) {
      const line = lines[n];
      // A line that opts out explicitly, with the rule named. Auditable in the
      // diff; a bare "ignore me" comment would not be.
      if (line.includes(`scrub-allow:${rule.id}`)) continue;
      rule.re.lastIndex = 0;
      let m;
      while ((m = rule.re.exec(line)) !== null) {
        const value = rule.capture ? m[rule.capture] : m[0];
        if (!value || isTemplated(value)) continue;
        if (rule.wordPlaceholders && isPlaceholderWord(value)) continue;
        // An allowlist entry exempts the exact matched value, OR any value
        // CONTAINED IN a longer allowlisted literal. Without the second half
        // the file is a usability trap: a rule reports the substring it
        // matched (`host.quiknode.pro/<hex>`), but a human allowlisting a URL
        // will paste the whole thing (`https://host.quiknode.pro/<hex>/`) and
        // it would silently keep firing. Containment only widens in the
        // direction the human already explicitly wrote down.
        if (allow.literals.has(value)) continue;
        if ([...allow.literals].some((a) => a.length > value.length && a.includes(value))) continue;
        const severity =
          rule.proseIsWarn && PROSE_EXT.has(path.extname(file).toLowerCase())
            ? "warn" : rule.severity;
        found.push({
          file, line: n + 1, rule: rule.id, severity,
          why: rule.why, masked: mask(value),
          label: rule.capture ? m[1] : undefined,
        });
        if (!rule.re.global) break;
      }
    }
  }
  return found;
}

/// Rewrite matches to <REDACTED:rule-id>. For turning a transcript into a
/// record: produces a usable artifact instead of a blocked write.
export function redact(text) {
  let out = text;
  for (const rule of RULES) {
    if (rule.severity !== "block") continue;
    out = out.replace(new RegExp(rule.re.source, rule.re.flags), (m, ...g) => {
      const v = rule.capture ? g[rule.capture - 1] : m;
      if (!v || isTemplated(v)) return m;
      if (rule.wordPlaceholders && isPlaceholderWord(v)) return m;
      return rule.capture ? m.replace(v, `<REDACTED:${rule.id}>`) : `<REDACTED:${rule.id}>`;
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
const git = (args) => execFileSync("git", args, { cwd: ROOT, encoding: "utf8", maxBuffer: 1 << 28 });

function main(argv) {
  const staged = argv.includes("--staged");
  const redactMode = argv.includes("--redact");
  const explicit = argv.filter((a) => !a.startsWith("--"));
  const allow = loadAllow();

  if (redactMode) {
    if (!explicit.length) { console.error("--redact needs a file"); return 2; }
    process.stdout.write(redact(readFileSync(explicit[0], "utf8")));
    return 0;
  }

  let files;
  if (explicit.length) files = explicit;
  else if (staged) files = git(["diff", "--cached", "--name-only", "--diff-filter=ACM"]).split("\n").filter(Boolean);
  else files = git(["ls-files"]).split("\n").filter(Boolean);

  files = files.filter((f) => !skipPath(f, allow.globs));

  const findings = [];
  for (const f of files) {
    let text;
    try {
      // Staged mode reads the INDEX, not the worktree. Scanning the worktree
      // would miss a secret that is staged and then edited out of the file, and
      // it is the staged bytes that become the commit.
      text = staged && !explicit.length ? git(["show", `:${f}`]) : readFileSync(path.join(ROOT, f), "utf8");
    } catch { continue; }
    if (text.includes("\0")) continue; // binary: a NUL byte, not a space
    findings.push(...scan(text, f, allow));
  }

  const blocks = findings.filter((x) => x.severity === "block");
  const warns = findings.filter((x) => x.severity === "warn");

  for (const w of warns) {
    console.log(`  WARN   ${w.file}:${w.line}  [${w.rule}]  ${w.masked}`);
  }
  for (const b of blocks) {
    console.error(`  BLOCK  ${b.file}:${b.line}  [${b.rule}]${b.label ? `  ${b.label}` : ""}  ${b.masked}`);
    console.error(`         ${b.why}`);
  }

  console.log(`\nscrub: ${files.length} files, ${blocks.length} blocking, ${warns.length} warnings`);
  if (blocks.length) {
    console.error(
      "\nREFUSED. A secret in a commit is permanent — later deletion does not\n" +
      "remove it from history, forks, or caches. Move the value out of the file\n" +
      "and reference it by name. If a finding is genuinely benign, add the exact\n" +
      "literal to tools/scrub-allow.txt, or annotate the line with\n" +
      "`scrub-allow:<rule-id>` so the exemption is visible in the diff.\n" +
      "\nIf a real secret already reached a commit, ROTATE IT. Removing it from\n" +
      "the file is not revocation.");
  }
  return blocks.length ? 1 : 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  process.exit(main(process.argv.slice(2)));
}
