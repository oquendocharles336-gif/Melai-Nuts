// Request handler of push-dispatch (see index.ts): sends the database's push
// outbox through Firebase Cloud Messaging (HTTP v1). Pushes are only ever
// created by database triggers (migration 20261021000000_push_notifications.sql).

export type Env = (name: string) => string | undefined;

export interface OutboxRow {
  id: number;
  firebase_uid: string;
  kind: string;
  title: string;
  body: string;
  data: Record<string, unknown>;
  tokens: string[];
}

export interface Deps {
  env: Env;
  /** Calls a service-role SQL function: push_outbox_claim / push_outbox_report. */
  rpc: (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>;
  /** OAuth access token for FCM (from the Firebase service account). */
  accessToken: () => Promise<string>;
  fetchFn?: typeof fetch;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

/** FCM data values must be strings. */
function stringData(kind: string, data: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = { kind };
  for (const [k, v] of Object.entries(data ?? {})) {
    if (v !== null && v !== undefined) out[k] = typeof v === "string" ? v : JSON.stringify(v);
  }
  return out;
}

/** True when FCM says the token will never work again (uninstalled app, bad token). */
export function isDeadToken(status: number, body: string): boolean {
  return status === 404 || /UNREGISTERED|registration-token-not-registered/i.test(body) ||
    (status === 400 && /INVALID_ARGUMENT/.test(body) && /token/i.test(body));
}

export function makeHandler(deps: Deps) {
  const fetchFn = deps.fetchFn ?? fetch;
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);
    const secret = deps.env("PUSH_DISPATCH_SECRET") ?? "";
    if (secret.length < 24 || req.headers.get("x-dispatch-secret") !== secret) {
      return json({ error: "Forbidden." }, 403);
    }
    const projectId = (deps.env("FIREBASE_PROJECT_ID") ?? "").trim();
    if (!projectId) return json({ error: "Not configured." }, 500);

    const { data, error } = await deps.rpc("push_outbox_claim", { p_limit: 100 });
    if (error) return json({ error: "Could not read the outbox." }, 500);
    const rows = (Array.isArray(data) ? data : []) as OutboxRow[];
    if (rows.length === 0) return json({ sent: 0, failed: 0 });

    const token = await deps.accessToken();
    const report: Array<Record<string, unknown>> = [];
    let sent = 0, failed = 0;
    for (const row of rows) {
      if (!row.tokens || row.tokens.length === 0) {
        // Nobody to send to (no device registered): done, nothing to retry.
        report.push({ id: row.id, ok: true });
        continue;
      }
      const dead: string[] = [];
      let delivered = 0;
      let lastError = "";
      for (const t of row.tokens) {
        const res = await fetchFn(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
          method: "POST",
          headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            message: {
              token: t,
              notification: { title: row.title, body: row.body },
              data: stringData(row.kind, row.data),
              android: { priority: "high" },
            },
          }),
        });
        if (res.ok) {
          delivered++;
        } else {
          const text = await res.text();
          lastError = `${res.status} ${text.slice(0, 200)}`;
          if (isDeadToken(res.status, text)) dead.push(t);
        }
      }
      // Delivered to at least one device, or every token is dead: finished.
      const ok = delivered > 0 || dead.length === row.tokens.length;
      ok ? sent++ : failed++;
      report.push({ id: row.id, ok, error: ok ? undefined : lastError, dead_tokens: dead });
    }
    const { error: reportError } = await deps.rpc("push_outbox_report", { p_result: report });
    if (reportError) return json({ error: "Could not record the results." }, 500);
    return json({ sent, failed });
  };
}
