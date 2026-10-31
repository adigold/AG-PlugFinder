import { neon } from "@neondatabase/serverless";
import { mkdirSync, writeFileSync } from "node:fs";

// Crash reports and error logs from users (BL-73).
//   npm run reports            list the new ones (not read yet)
//   npm run reports all        list every report
//   npm run reports show 4     save report 4 to reports/4.txt and mark it read
const sql = neon(process.env.DATABASE_URL!);
const [cmd, id] = process.argv.slice(2);

if (cmd === "show" && id) {
  const [r] = (await sql`select * from reports where id = ${Number(id)}`) as any[];
  if (!r) { console.log("no such report"); process.exit(1); }
  mkdirSync("reports", { recursive: true });
  const text = `Report ${r.id} · ${r.kind} · app ${r.app_version} · ${r.macos} · ${r.created_at}\n` +
    `Mac: ${r.install_id}\nNote: ${r.note || "(none)"}\n\n=== Crash report ===\n${r.report || "(none)"}\n\n=== App log ===\n${r.log || "(none)"}\n`;
  writeFileSync(`reports/${r.id}.txt`, text);
  await sql`update reports set read_at = now() where id = ${r.id}`;
  console.log(`saved server/reports/${r.id}.txt`);
} else {
  const rows = (cmd === "all"
    ? await sql`select id, kind, app_version, note, created_at, read_at from reports order by created_at desc limit 100`
    : await sql`select id, kind, app_version, note, created_at, read_at from reports where read_at is null order by created_at desc`) as any[];
  for (const r of rows) {
    console.log(`${r.id}\t${r.kind}\tv${r.app_version}\t${new Date(r.created_at).toLocaleString()}\t${r.read_at ? "read" : "NEW"}\t${(r.note || "").slice(0, 60)}`);
  }
  console.log(`${rows.length} ${cmd === "all" ? "reports" : "new"}. Read one with: npm run reports show <id>`);
}
