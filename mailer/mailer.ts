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
  store_name: string;
  town: string | null;
  contact_email: string;
  contact_name: string | null;
}

function pitchEmail(lead: Lead, fromName: string) {
  const owner = lead.contact_name || "there";
  const subject = `A working weekly-ad app for ${lead.store_name} — built, live, ready to show you`;
  const text = `Hi ${owner},

I'm a local developer, and I recently built a real, working app for an independent grocery store — not a mockup, an actual installable app people can put on their phone right now:

- This week's real prices and photos, synced straight from the store's own data
- Works like a native app (installs to the home screen, works offline)
- The weekly printed ad shown as its own section, alongside the full current inventory
- No extra work on your end — I handle the setup and the weekly update

I'd like to show you the real thing running, not just describe it. Takes five minutes, and there's no cost or commitment to just take a look.

Would you have a few minutes this week for me to send over the link or stop by?

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
