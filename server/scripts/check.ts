import { readFileSync } from "node:fs";
import { neon } from "@neondatabase/serverless";

// End-to-end check of the deployed function: wrong key refused, a real picture uploaded,
// approved, found by lookup and downloaded byte for byte, then everything removed again.
const base = process.env.NEON_FUNCTION_PLUGDB_BASE_URL!.replace(/\/$/, "");
const key = process.env.UPLOAD_KEY!;
const sql = neon(process.env.DATABASE_URL!);
const id = "aufx-TEST-AGPF";
const picture = readFileSync(process.argv[2]);
const headers = { "content-type": "application/json", "x-agpf-key": key };

const say = (label: string, value: unknown) => console.log(label.padEnd(26), value);
say("home", (await fetch(base + "/")).status);
say("upload with wrong key", (await fetch(base + "/v1/pictures", { method: "POST", headers: { ...headers, "x-agpf-key": "nope" }, body: "{}" })).status);
say("upload not a picture", (await fetch(base + "/v1/pictures", { method: "POST", headers,
  body: JSON.stringify({ pluginId: id, name: "Check", manufacturer: "AG", installId: "check", picture: Buffer.from("hello world".repeat(30)).toString("base64") }) })).status);
const up = await fetch(base + "/v1/pictures", { method: "POST", headers,
  body: JSON.stringify({ pluginId: id, name: "Check Plugin", manufacturer: "AG", version: "1.0", installId: "check",
                         appVersion: "test", picture: picture.toString("base64") }) });
say("upload real picture", `${up.status} ${await up.text()}`);
const [w] = await sql`select id, status, length(picture) as bytes from submissions where plugin_id = ${id}`;
say("waiting in database", w);
const before = await (await fetch(base + "/v1/lookup", { method: "POST", headers, body: JSON.stringify({ ids: [id] }) })).json();
say("lookup before approval", JSON.stringify(before));
await sql`update submissions set status = 'approved' where id = ${w.id}`;
await sql`insert into plugins (plugin_id, name, manufacturer, version, picture, picture_type, submission_id)
          select plugin_id, name, manufacturer, version, picture, picture_type, id from submissions where id = ${w.id}`;
const after = await (await fetch(base + "/v1/lookup", { method: "POST", headers, body: JSON.stringify({ ids: [id] }) })).json();
say("lookup after approval", JSON.stringify(after));
const got = Buffer.from(await (await fetch(`${base}/v1/pictures/${id}`, { headers })).arrayBuffer());
say("download matches upload", got.equals(picture) ? `yes (${got.length} bytes)` : "NO");
await sql`delete from plugins where plugin_id = ${id}`;
await sql`delete from submissions where plugin_id = ${id}`;
const [{ n }] = await sql`select (select count(*) from plugins) + (select count(*) from submissions) as n`;
say("cleaned up, rows left", n);
