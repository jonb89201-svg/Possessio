// possessio-mailer — sends real outreach emails via Resend, entirely on
// Cloudflare's side (cron-triggered, same pattern as possessio-radar). Leads
// are found and inserted by the repo seat via the D1 MCP connector (WebSearch
// for real, verifiable businesses -- never fabricated addresses); this worker
// only sends to whatever's already sitting in the leads table as 'pending'.
//
// Deliberately paced: sends a small batch per tick, not everything at once --
// this is outreach to real people, not a blast list.

export interface MailerEnv {
  LEADS_DB: D1Database;
  RESEND_API_KEY: string;
  FROM_EMAIL: string;   // e.g. "jon@possessio.io"
  FROM_NAME: string;    // e.g. "Jon Solo"
  MAX_PER_TICK: string; // small batch size per cron run
}

interface Lead {
  id: number;
  store_name: string; // holds the company/entity name generically, not grocery-specific
  town: string | null;
  contact_email: string;
  contact_name: string | null;
}

function pitchEmail(lead: Lead, fromName: string) {
  const owner = lead.contact_name || "there";
  const subject = `Available for contract work / collaboration — real, live proof of what I build`;
  const text = `Hi ${owner},

I'm a systems architect and developer open to collaborating or taking on contract work if the scope and price line up. Rather than describe what I do, here's shipped, verifiable proof:

Live on Base mainnet (verifiable on BaseScan):
- PossessioPayments (0x1c0F7299BA395955C1bb23D4fC316bfC1d78AB91) — non-custodial merchant payment processor
- LSTExchangeRate (0xDDb75e974d99FcF95E241adbFD376861c47a8548) — fail-closed cbETH valuation guard

Both are part of POSSESSIO, a non-custodial DeFi protocol on Base: Uniswap V4 hooks, Chainlink automation, 690 passing tests. I architected it and directed a multi-model AI build through rigorous verification — built mobile-only.

And a live consumer app built solo end-to-end: https://superfoods-logan.jonb89201.workers.dev — installable, live inventory sync from a real vendor feed, Play Store pipeline, its own backend.

Solidity/Foundry, Cloudflare Workers, PWAs, real-time data integration, and AI-orchestrated builds. Not demos — deployed.

Background: Cloudflare Workers / serverless architecture, PWA development, real-time data integration from third-party platforms, crypto/payment protocol integration (x402).

If you've got overflow work, a project that needs another set of hands, or something specific in mind, I'd like to hear about it.

Thanks,
${fromName}`;
  return { subject, text };
}

async function sendOne(lead: Lead, env: MailerEnv): Promise<{ ok: boolean; error?: string }> {
  const { subject, text } = pitchEmail(lead, env.FROM_NAME);
  const resp = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: `${env.FROM_NAME} <${env.FROM_EMAIL}>`,
      to: [lead.contact_email],
      subject,
      text,
    }),
  });
  if (!resp.ok) {
    const body = await resp.text();
    return { ok: false, error: `Resend ${resp.status}: ${body.slice(0, 500)}` };
  }
  return { ok: true };
}

export async function runMailerTick(env: MailerEnv): Promise<{ sent: number; failed: number }> {
  const limit = parseInt(env.MAX_PER_TICK || "3", 10);
  const { results } = await env.LEADS_DB.prepare(
    `SELECT id, store_name, town, contact_email, contact_name FROM leads
      WHERE status = 'pending' ORDER BY created_ms ASC LIMIT ?1`
  ).bind(limit).all<Lead>();

  let sent = 0, failed = 0;
  for (const lead of results) {
    const result = await sendOne(lead, env);
    const now = Date.now();
    if (result.ok) {
      await env.LEADS_DB.prepare(
        `UPDATE leads SET status='sent', sent_ms=?1 WHERE id=?2`
      ).bind(now, lead.id).run();
      sent++;
    } else {
      await env.LEADS_DB.prepare(
        `UPDATE leads SET status='failed', error=?1 WHERE id=?2`
      ).bind(result.error || "unknown error", lead.id).run();
      failed++;
    }
  }
  return { sent, failed };
}

export default {
  async fetch(request: Request, env: MailerEnv): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/status") {
      const counts = await env.LEADS_DB.prepare(
        `SELECT status, COUNT(*) as n FROM leads GROUP BY status`
      ).all();
      return Response.json({ counts: counts.results });
    }
    return new Response("possessio-mailer: see /status", { status: 200 });
  },

  async scheduled(_event: ScheduledEvent, env: MailerEnv, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(runMailerTick(env).then((r) => console.log(`mailer tick: sent=${r.sent} failed=${r.failed}`)));
  },
};
