// Act approval: a human approves ONE described act with a wallet signature, reading
// what they sign in plain words first.
//
// Why it exists (test drive 2026-10-10): the Architect approved an act by signing
// a bare 32-byte hash on the RRC signer page, and the page rightly warned "you
// would be signing a bare hash". The person signing must see the act, not a hash.
//
// How it holds without trusting this server:
//   - A seat (token-gated) files a request: the act's 32-byte id, a title, and
//     label/value lines describing it, the approver's address and a deadline.
//   - possessio.io/approve.html shows those lines, then asks the wallet to sign
//     EIP-712 typed data carrying the SAME title and summary text. The wallet
//     renders those fields itself, so what the human sees in the wallet is what
//     is signed, whatever this page or this database say.
//   - The system that executes the act rebuilds the summary from its OWN record
//     of the act and accepts the signature only if (act id, summary, deadline)
//     match and it recovers to the approver. A record altered here cannot buy a
//     different act: the executor rejects any summary it did not write.
//   - This worker holds no signing key. It stores requests and signatures, and
//     checks a signature recovers to the named approver before storing it.
//
// The act id is opaque here: how the executor derives it is not this file's
// business and is not needed to verify anything below.
import { recoverTypedDataAddress, getAddress, isAddress } from "viem";

export const APPROVAL_DOMAIN_NAME = "Possessio Act Approval";
export const APPROVAL_DOMAIN_VERSION = "1";
export const APPROVAL_TYPES = {
  ActApproval: [
    { name: "act", type: "bytes32" },
    { name: "title", type: "string" },
    { name: "summary", type: "string" },
    { name: "validUntil", type: "uint256" },
  ],
};
export const LIMITS = { title: 120, lines: 20, label: 40, value: 200, ttlMaxS: 7 * 86400 };

const HEX32 = /^0x[0-9a-f]{64}$/;
// Printable text only: no control characters (a newline inside a value could
// forge an extra "label: value" line in the summary), no bidi overrides (could
// make a wallet show text in a different order than it is signed).
const UNSAFE = /[\u0000-\u001f\u007f-\u009f‪-‮⁦-⁩]/;

function cleanText(s, max, what) {
  if (typeof s !== "string") throw new Error(what + " must be a string");
  const t = s.trim();
  if (!t) throw new Error(what + " is empty");
  if (t.length > max) throw new Error(what + " too long (max " + max + ")");
  if (UNSAFE.test(t)) throw new Error(what + " contains a control or direction character");
  return t;
}

/** The one place the summary text is built. The executor builds the same text from its own record. */
export function summaryOf(lines) {
  return lines.map(([label, value]) => label + ": " + value).join("\n");
}

/** Validate and normalise a request filed by a seat. Throws with a reason on anything malformed. */
export function normaliseRequest(args, nowS, chainId) {
  const act = String(args?.act ?? "").toLowerCase();
  if (!HEX32.test(act)) throw new Error("act must be 0x + 64 hex characters");
  const title = cleanText(args?.title, LIMITS.title, "title");
  const raw = args?.lines;
  if (!Array.isArray(raw) || raw.length === 0) throw new Error("lines must be a non-empty array of [label, value]");
  if (raw.length > LIMITS.lines) throw new Error("too many lines (max " + LIMITS.lines + ")");
  const lines = raw.map((l, i) => {
    if (!Array.isArray(l) || l.length !== 2) throw new Error("line " + i + " must be [label, value]");
    const label = cleanText(l[0], LIMITS.label, "line " + i + " label");
    if (label.includes(":")) throw new Error("line " + i + " label must not contain ':'");
    return [label, cleanText(l[1], LIMITS.value, "line " + i + " value")];
  });
  const approverRaw = String(args?.approver ?? "");
  if (!isAddress(approverRaw, { strict: false })) throw new Error("approver must be an address");
  const approver = getAddress(approverRaw);
  const validUntil = Number(args?.valid_until);
  if (!Number.isSafeInteger(validUntil)) throw new Error("valid_until must be a unix time in seconds");
  if (validUntil <= nowS) throw new Error("valid_until is in the past");
  if (validUntil > nowS + LIMITS.ttlMaxS) throw new Error("valid_until is more than 7 days away");
  return { act, title, lines, summary: summaryOf(lines), approver, validUntil, chainId: Number(chainId) };
}

/** The exact typed data the wallet is asked to sign for a record. */
export function typedDataFor(rec) {
  return {
    domain: { name: APPROVAL_DOMAIN_NAME, version: APPROVAL_DOMAIN_VERSION, chainId: rec.chainId },
    types: APPROVAL_TYPES,
    primaryType: "ActApproval",
    message: { act: rec.act, title: rec.title, summary: rec.summary, validUntil: BigInt(rec.validUntil) },
  };
}

/** Check a signature for a stored record. Returns the recovered address; throws with a reason otherwise. */
export async function checkSignature(rec, signature, nowS) {
  if (typeof signature !== "string" || !/^0x[0-9a-fA-F]{130}$/.test(signature))
    throw new Error("signature must be 0x + 130 hex characters (65 bytes)");
  if (nowS > rec.validUntil) throw new Error("the approval window has closed");
  const recovered = await recoverTypedDataAddress({ ...typedDataFor(rec), signature });
  if (getAddress(recovered) !== getAddress(rec.approver))
    throw new Error("signature recovers to " + recovered + ", not the approver " + rec.approver);
  return getAddress(recovered);
}
