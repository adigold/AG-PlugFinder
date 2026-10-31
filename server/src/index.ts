import { createHash } from "node:crypto";
import { Hono } from "hono";
import { Pool } from "pg";
import { attachDatabasePool } from "@neon/functions";

// The shared plugin database's API (BL-71). The Mac app sends plugin pictures here; they
// wait in `submissions` until Adi approves them. Every request must carry the app's upload
// key; uploads are size- and type-checked and limited per sender per day.
const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 5 });
attachDatabasePool(pool);

const MAX_PICTURE = 2_000_000;     // bytes
const MAX_PER_DAY = 400;           // uploads per sender address per day
const ID = /^[A-Za-z0-9]{4}-[A-Za-z0-9 ._]{1,4}-[A-Za-z0-9 ._]{1,4}$/;

const app = new Hono();

app.use("/v1/*", async (c, next) => {
  const key = process.env.UPLOAD_KEY;
  if (!key || c.req.header("x-agpf-key") !== key) return c.json({ error: "unauthorized" }, 401);
  await next();
});

app.get("/", (c) => c.text("AG PlugFinder"));

app.post("/v1/pictures", async (c) => {
  const length = Number(c.req.header("content-length") ?? 0);
  if (!length || length > MAX_PICTURE * 1.4 + 4096) return c.json({ error: "too large" }, 413);

  let body: Record<string, unknown>;
  try { body = await c.req.json(); } catch { return c.json({ error: "bad json" }, 400); }
  const text = (k: string, max: number) => {
    const v = body[k];
    return typeof v === "string" && v.trim() && v.length <= max ? v.trim() : null;
  };
  const pluginId = text("pluginId", 20);
  const name = text("name", 200);
  const manufacturer = text("manufacturer", 200);
  const installId = text("installId", 64);
  const pictureB64 = typeof body.picture === "string" ? body.picture : null;
  if (!pluginId || !ID.test(pluginId) || !name || !manufacturer || !installId || !pictureB64) {
    return c.json({ error: "missing fields" }, 400);
  }
  const picture = Buffer.from(pictureB64, "base64");
  const type = picture.subarray(0, 4).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47])) ? "image/png"
    : picture.subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff])) ? "image/jpeg" : null;
  if (!type || picture.length > MAX_PICTURE || picture.length < 200) return c.json({ error: "not a picture" }, 400);

  // The sender's address is kept only as a one-way hash, for the daily limit.
  const ip = c.req.header("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
  const ipHash = createHash("sha256").update(ip + (process.env.UPLOAD_KEY ?? "")).digest("hex").slice(0, 32);
  const { rows: [{ n }] } = await pool.query(
    "select count(*)::int as n from submissions where ip_hash = $1 and created_at > now() - interval '1 day'", [ipHash]);
  if (n >= MAX_PER_DAY) return c.json({ error: "slow down" }, 429);

  await pool.query(
    `insert into submissions (plugin_id, name, manufacturer, version, category, picture, picture_type,
                              install_id, ip_hash, app_version)
     values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
     on conflict (plugin_id, install_id) do update
       set picture = excluded.picture, picture_type = excluded.picture_type, version = excluded.version,
           created_at = now(), status = 'waiting'
       where submissions.status <> 'approved'`,
    [pluginId, name, manufacturer, text("version", 40), text("category", 60), picture, type,
     installId, ipHash, text("appVersion", 20)]);
  return c.json({ ok: true }, 201);
});

// A crash report or error log the user chose to send to Goldi (BL-73).
app.post("/v1/reports", async (c) => {
  const length = Number(c.req.header("content-length") ?? 0);
  if (!length || length > 3_000_000) return c.json({ error: "too large" }, 413);
  let body: Record<string, unknown>;
  try { body = await c.req.json(); } catch { return c.json({ error: "bad json" }, 400); }
  const str = (k: string, max: number) => (typeof body[k] === "string" ? (body[k] as string).slice(0, max) : null);
  const kind = body.kind === "crash" ? "crash" : "log";
  const installId = str("installId", 64);
  if (!installId) return c.json({ error: "missing fields" }, 400);
  const ip = c.req.header("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
  const ipHash = createHash("sha256").update(ip + (process.env.UPLOAD_KEY ?? "")).digest("hex").slice(0, 32);
  const { rows: [{ n }] } = await pool.query(
    "select count(*)::int as n from reports where ip_hash = $1 and created_at > now() - interval '1 day'", [ipHash]);
  if (n >= 20) return c.json({ error: "slow down" }, 429);
  await pool.query(
    `insert into reports (kind, install_id, app_version, macos, note, report, log, ip_hash)
     values ($1, $2, $3, $4, $5, $6, $7, $8)`,
    [kind, installId, str("appVersion", 20), str("macOS", 100), str("note", 2000),
     str("report", 1_600_000), str("log", 400_000), ipHash]);
  return c.json({ ok: true }, 201);
});

// Which of these plugins already have an approved picture (so the app need not take one).
app.post("/v1/lookup", async (c) => {
  let ids: unknown;
  try { ids = (await c.req.json()).ids; } catch { return c.json({ error: "bad json" }, 400); }
  if (!Array.isArray(ids) || ids.length > 2000) return c.json({ error: "bad ids" }, 400);
  const clean = ids.filter((i): i is string => typeof i === "string" && ID.test(i));
  const { rows } = await pool.query(
    "select plugin_id, version, category from plugins where plugin_id = any($1)", [clean]);
  return c.json({ available: rows });
});

app.get("/v1/pictures/:id", async (c) => {
  const id = c.req.param("id");
  if (!ID.test(id)) return c.json({ error: "bad id" }, 400);
  const { rows } = await pool.query("select picture, picture_type from plugins where plugin_id = $1", [id]);
  if (!rows[0]) return c.json({ error: "not found" }, 404);
  return c.body(rows[0].picture, 200, { "content-type": rows[0].picture_type, "cache-control": "public, max-age=86400" });
});

export default app;
