// node worker/test/act-approval.test.mjs  -> RESULT: n/n PASS
// Offline: test keys made here, no network, no database.
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { hashTypedData } from "viem";
import { normaliseRequest, typedDataFor, checkSignature, summaryOf } from "../act-approval.mjs";

const NOW = 1_791_646_000;
const ACT = "0x1a9d1dae5381a44edd4cbfa412d2bb5b4be1a337e104331b4060ecc1c7893427";
const approver = privateKeyToAccount(generatePrivateKey());
const stranger = privateKeyToAccount(generatePrivateKey());
const base = () => ({
  act: ACT, title: "Treasury transfer",
  lines: [["Action", "Transfer from treasury"], ["Recipient", "0x6f8d…a618 (preauthorised)"], ["Amount", "250"],
          ["Cost ceiling", "5000"]],
  approver: approver.address, valid_until: NOW + 300,
});

const results = [];
async function test(name, fn) {
  try { await fn(); results.push([name, true]); }
  catch (e) { results.push([name, false, e && e.message]); }
}
const throws = async (fn, re) => {
  try { await fn(); } catch (e) { if (re && !re.test(e.message)) throw new Error("wrong reason: " + e.message); return; }
  throw new Error("did not throw");
};
const sign = (acct, rec) => acct.signTypedData(typedDataFor(rec));

await test("summary is 'label: value' lines in order", () => {
  if (summaryOf([["A", "1"], ["B", "2"]]) !== "A: 1\nB: 2") throw new Error("bad summary");
});
await test("a well-formed request normalises (act lowercased, approver checksummed)", () => {
  const r = normaliseRequest({ ...base(), act: ACT.toUpperCase().replace("0X", "0x") }, NOW, 8453);
  if (r.act !== ACT || r.approver !== approver.address || r.chainId !== 8453) throw new Error(JSON.stringify(r));
});
await test("a newline inside a value is refused (it could forge an extra line)", () =>
  throws(() => normaliseRequest({ ...base(), lines: [["Amount", "250\nRecipient: attacker"]] }, NOW, 8453), /control/));
await test("a bidi override is refused (it could reorder what the wallet shows)", () =>
  throws(() => normaliseRequest({ ...base(), title: "Pay ‮evil" }, NOW, 8453), /direction/));
await test("a ':' in a label is refused (summary lines must split unambiguously)", () =>
  throws(() => normaliseRequest({ ...base(), lines: [["Amount: x", "250"]] }, NOW, 8453), /':'/));
await test("act must be 32 bytes of hex", () =>
  throws(() => normaliseRequest({ ...base(), act: "0x1234" }, NOW, 8453), /64 hex/));
await test("a deadline in the past or beyond 7 days is refused", async () => {
  await throws(() => normaliseRequest({ ...base(), valid_until: NOW }, NOW, 8453), /past/);
  await throws(() => normaliseRequest({ ...base(), valid_until: NOW + 8 * 86400 }, NOW, 8453), /7 days/);
});
await test("too many lines, an empty title, an over-long value are refused", async () => {
  await throws(() => normaliseRequest({ ...base(), lines: Array.from({ length: 21 }, (_, i) => ["L" + i, "v"]) }, NOW, 8453), /too many/);
  await throws(() => normaliseRequest({ ...base(), title: "  " }, NOW, 8453), /empty/);
  await throws(() => normaliseRequest({ ...base(), lines: [["A", "x".repeat(201)]] }, NOW, 8453), /too long/);
});
await test("the approver's signature over the typed data is accepted", async () => {
  const rec = normaliseRequest(base(), NOW, 8453);
  const who = await checkSignature(rec, await sign(approver, rec), NOW);
  if (who !== approver.address) throw new Error(who);
});
await test("a stranger's signature is refused", async () => {
  const rec = normaliseRequest(base(), NOW, 8453);
  await throws(async () => checkSignature(rec, await sign(stranger, rec), NOW), /not the approver/);
});
await test("a signature over a different summary does not verify for this record", async () => {
  const rec = normaliseRequest(base(), NOW, 8453);
  const other = { ...rec, summary: rec.summary.replace("250", "2500") };
  await throws(async () => checkSignature(rec, await sign(approver, other), NOW), /not the approver/);
});
await test("a signature for another chain does not verify here", async () => {
  const rec = normaliseRequest(base(), NOW, 8453);
  await throws(async () => checkSignature(rec, await sign(approver, { ...rec, chainId: 1 }), NOW), /not the approver/);
});
await test("a signature after the deadline is refused", async () => {
  const rec = normaliseRequest(base(), NOW, 8453);
  const sig = await sign(approver, rec);
  await throws(() => checkSignature(rec, sig, NOW + 301), /closed/);
});
await test("a malformed signature is refused before any recovery", () =>
  throws(() => checkSignature(normaliseRequest(base(), NOW, 8453), "0x1234", NOW), /130 hex/));

// Parity vector: the executor recomputes this digest in another language. Fixed inputs, fixed output.
const VECTOR = { act: ACT, title: "Treasury transfer", summary: "Action: Transfer from treasury\nAmount: 250",
                 validUntil: 1791646110, chainId: 8453 };
const DIGEST = hashTypedData(typedDataFor(VECTOR));
const EXPECTED = "0x82981be1f5c38e35d6639623c267e9d70f025d111988ad48a6207bc0459b208e";
await test("parity vector: the typed-data digest is the locked value (an executor in another language must match it)", () => {
  if (DIGEST !== EXPECTED) throw new Error("digest drifted: " + DIGEST);
});

for (const [n, ok, why] of results) console.log(`  [${ok ? "PASS" : "FAIL"}] ${n}${ok ? "" : " — " + why}`);
const n = results.filter((r) => r[1]).length;
console.log(`RESULT: ${n}/${results.length} PASS`);
process.exit(n === results.length ? 0 : 1);
