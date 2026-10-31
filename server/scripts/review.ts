import { neon } from "@neondatabase/serverless";
import { writeFileSync, mkdirSync } from "node:fs";

// Adi's approval list (BL-71).
//   npm run review                 list what is waiting, save the pictures to review/ to look at
//   npm run review approve 12 15   approve those submissions (the newest per plugin wins)
//   npm run review approve-all     approve everything waiting
//   npm run review reject 13       reject one
const sql = neon(process.env.DATABASE_URL!);
const [cmd, ...ids] = process.argv.slice(2);

async function approve(where: string, params: unknown[]) {
  const rows = await sql.query(
    `update submissions set status = 'approved' where status = 'waiting' and ${where} returning *`, params);
  for (const s of rows as any[]) {
    await sql.query(
      `insert into plugins (plugin_id, name, manufacturer, version, category, picture, picture_type, submission_id)
       values ($1, $2, $3, $4, $5, $6, $7, $8)
       on conflict (plugin_id) do update set name = excluded.name, manufacturer = excluded.manufacturer,
         version = excluded.version, category = excluded.category, picture = excluded.picture,
         picture_type = excluded.picture_type, submission_id = excluded.submission_id, approved_at = now()`,
      [s.plugin_id, s.name, s.manufacturer, s.version, s.category, s.picture, s.picture_type, s.id]);
  }
  console.log(`approved ${rows.length}`);
}

if (cmd === "approve") await approve("id = any($1)", [ids.map(Number)]);
else if (cmd === "approve-all") await approve("true", []);
else if (cmd === "reject") {
  const rows = await sql.query(`update submissions set status = 'rejected' where id = any($1) returning id`, [ids.map(Number)]);
  console.log(`rejected ${rows.length}`);
} else {
  const rows = await sql`select id, plugin_id, name, manufacturer, version, picture, picture_type, created_at
                         from submissions where status = 'waiting' order by plugin_id, created_at desc`;
  mkdirSync("review", { recursive: true });
  for (const r of rows as any[]) {
    writeFileSync(`review/${r.id}-${r.plugin_id}.${r.picture_type === "image/png" ? "png" : "jpg"}`, r.picture);
    console.log(`${r.id}\t${r.name} (${r.manufacturer}) ${r.version ?? ""}\t${r.created_at.toISOString?.() ?? r.created_at}`);
  }
  console.log(`${rows.length} waiting. Pictures saved in server/review/.`);
}
