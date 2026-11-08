// Photon Spectrum sidecar. The Python backend calls POST /send; inbound replies reach the backend
// through Photon's signed webhook (POST {PUBLIC_BASE_URL}/messaging/webhook), not through here.
import dotenv from "dotenv";
dotenv.config({ path: new URL("../../.env", import.meta.url).pathname });
import http from "node:http";
import { existsSync } from "node:fs";
import { timingSafeEqual } from "node:crypto";
import { Spectrum, attachment } from "spectrum-ts";
import { imessage } from "spectrum-ts/providers/imessage";

const PORT = Number(process.env.MESSENGER_PORT ?? 8790);
const KEY = process.env.INTERNAL_API_KEY ?? "";
const EVENTS = new Set(["check1_prompt", "needs_user", "confirmed", "failed", "expiry_reminder", "resident_request"]);
const BACKEND_URL = (process.env.BACKEND_URL ?? "http://localhost:8000").replace(/\/$/, "");
const INBOUND = (process.env.PHOTON_INBOUND ?? "stream") !== "off";

let appPromise: ReturnType<typeof start> | null = null;
function start() {
  return Spectrum({
    projectId: process.env.PHOTON_PROJECT_ID!,
    projectSecret: process.env.PHOTON_PROJECT_SECRET!,
    providers: [imessage.config()],
  });
}
const getApp = () => (appPromise ??= start());

function authorized(header: string | undefined): boolean {
  if (!KEY || !header) return false;
  const a = Buffer.from(header), b = Buffer.from(KEY);
  return a.length === b.length && timingSafeEqual(a, b);
}

async function readJson(req: http.IncomingMessage): Promise<any> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const c of req) {
    size += (c as Buffer).length;
    if (size > 64_000) throw new Error("too large");
    chunks.push(c as Buffer);
  }
  return JSON.parse(Buffer.concat(chunks).toString() || "{}");
}

function reply(res: http.ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "GET" && req.url === "/health") return reply(res, 200, { status: "ok" });
    if (req.method === "POST" && req.url === "/send") {
      if (!authorized(req.headers["x-internal-key"] as string | undefined))
        return reply(res, 401, { error: { code: "validation_error", message: "Missing or bad X-Internal-Key." } });
      const { to_phone, text, event, attachment_path } = await readJson(req);
      if (!/^\+[1-9]\d{6,14}$/.test(to_phone ?? "") || typeof text !== "string" || !EVENTS.has(event))
        return reply(res, 422, { error: { code: "validation_error", message: "to_phone, text and event are required." } });
      const app = await getApp();
      const im = imessage(app);
      const space = await im.space.create(await im.user(to_phone));
      await space.send(text);
      if (attachment_path && existsSync(attachment_path)) await space.send(attachment(attachment_path));
      console.log(`sent event=${event}`); // never log message text or numbers
      return reply(res, 200, { ok: true });
    }
    reply(res, 404, { error: { code: "not_found", message: "Not found." } });
  } catch (e) {
    console.error("send failed:", (e as Error).name);
    reply(res, 502, { error: { code: "validation_error", message: "Message could not be sent." } });
  }
});

// Replies arrive over Spectrum's own connection, so no public webhook URL is needed. Each text goes to the
// backend, which decides what it means (YES/NO from the visitor, or a resident's unit and last name).
async function listen() {
  for (;;) {
    try {
      const app = await getApp();
      console.log("listening for replies");
      for await (const [, message] of app.messages) {
        if (message.direction === "outbound" || message.content.type !== "text") continue;
        const from = message.sender?.id;
        if (!from || !/^\+[1-9]\d{6,14}$/.test(from)) continue;
        try {
          await fetch(`${BACKEND_URL}/messaging/inbound`, {
            method: "POST",
            headers: { "Content-Type": "application/json", "X-Internal-Key": KEY },
            body: JSON.stringify({ message_id: message.id, from_phone: from, text: message.content.text }),
          });
          console.log("forwarded a reply"); // never log the text or the number
        } catch (e) {
          console.error("forward failed:", (e as Error).name);
        }
      }
    } catch (e) {
      console.error("listen failed, retrying in 5s:", (e as Error).name);
    }
    await new Promise((r) => setTimeout(r, 5000));
  }
}

server.listen(PORT, () => {
  console.log(`messenger listening on :${PORT}`);
  if (INBOUND && process.env.PHOTON_PROJECT_ID && process.env.PHOTON_PROJECT_SECRET && KEY) void listen();
  else if (INBOUND) console.warn("inbound listening is off: PHOTON_PROJECT_ID, PHOTON_PROJECT_SECRET and INTERNAL_API_KEY are needed");
});
process.on("SIGTERM", async () => { server.close(); try { await (await appPromise)?.stop(); } catch {} process.exit(0); });
