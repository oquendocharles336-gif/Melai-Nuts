// deno test supabase/functions/push-dispatch/handler_test.ts
import { isDeadToken, makeHandler } from "./handler.ts";

function eq(a: unknown, b: unknown, msg = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${msg} expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}

const SECRET = "s".repeat(32);
const env = (k: string) => ({ PUSH_DISPATCH_SECRET: SECRET, FIREBASE_PROJECT_ID: "test-project" } as Record<string, string>)[k];

function setup(rows: unknown[], fcm: (token: string) => Response) {
  const reports: unknown[] = [];
  const sentTo: string[] = [];
  const handler = makeHandler({
    env,
    rpc: (fn, args) => {
      if (fn === "push_outbox_claim") return Promise.resolve({ data: rows, error: null });
      reports.push(args.p_result);
      return Promise.resolve({ data: null, error: null });
    },
    accessToken: () => Promise.resolve("access"),
    fetchFn: (_url, init) => {
      const token = JSON.parse(String((init as RequestInit).body)).message.token;
      sentTo.push(token);
      return Promise.resolve(fcm(token));
    },
  });
  return { handler, reports, sentTo };
}

const req = (secret = SECRET) => new Request("http://fn.test", { method: "POST", headers: { "x-dispatch-secret": secret } });
const row = (id: number, tokens: string[]) => ({ id, firebase_uid: "u", kind: "customer.order", title: "T", body: "B", data: { order_id: "ORD-1" }, tokens });

Deno.test("only the scheduler (with the secret) may run it", async () => {
  const { handler, sentTo } = setup([row(1, ["a"])], () => new Response("{}"));
  eq((await handler(req("wrong"))).status, 403);
  eq(sentTo, []);
});

Deno.test("each row goes to every device of its recipient and is reported sent", async () => {
  const { handler, reports, sentTo } = setup([row(1, ["a", "b"])], () => new Response("{}"));
  const res = await handler(req());
  eq(await res.json(), { sent: 1, failed: 0 });
  eq(sentTo, ["a", "b"]);
  eq(reports, [[{ id: 1, ok: true, dead_tokens: [] }]]);
});

Deno.test("an uninstalled app's token is reported dead; a temporary error is retried later", async () => {
  const { handler, reports } = setup([row(1, ["dead"]), row(2, ["busy"])], (t) =>
    t === "dead"
      ? new Response('{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}', { status: 404 })
      : new Response('{"error":{"status":"UNAVAILABLE"}}', { status: 503 }));
  eq(await (await handler(req())).json(), { sent: 1, failed: 1 });
  const r = reports[0] as Array<Record<string, unknown>>;
  eq(r[0].ok, true, "all tokens dead = finished");
  eq(r[0].dead_tokens, ["dead"]);
  eq(r[1].ok, false, "503 = try again on the next run");
});

Deno.test("a recipient without devices is finished without calling FCM", async () => {
  const { handler, sentTo, reports } = setup([row(9, [])], () => new Response("{}"));
  await handler(req());
  eq(sentTo, []);
  eq(reports, [[{ id: 9, ok: true }]]);
});

Deno.test("dead-token detection", () => {
  eq(isDeadToken(404, ""), true);
  eq(isDeadToken(400, '{"error":{"status":"INVALID_ARGUMENT","message":"The registration token is not a valid FCM registration token"}}'), true);
  eq(isDeadToken(500, "internal"), false);
});
