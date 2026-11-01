// Stores what find-urls found (BL-119, BL-120), after Adi reviewed it.
//   npm run apply-urls            dry run: what would change
//   npm run apply-urls -- --apply  writes, in one transaction
// Links and kinds go into plugins; a changed category goes in as one shared category vote
// (install "maker-site"), so users' own votes and choices still win.
import fs from "node:fs";
import pg from "pg";

type Found = { maker: string; name: string; ids: string[]; current?: string; url?: string; note?: string; category?: string; type?: string };
const apply = process.argv.includes("--apply");
const found = JSON.parse(fs.readFileSync("reports/urls-all.json", "utf8")) as Found[];
const withUrl = found.filter((f) => f.url && !f.note);
const changes = withUrl.filter((f) => f.category && f.category !== f.current);
console.log(`${found.length} products: ${withUrl.length} with a page, ${changes.length} with a new category`);
console.log(`plugins touched: links ${withUrl.reduce((n, f) => n + f.ids.length, 0)}, categories ${changes.reduce((n, f) => n + f.ids.length, 0)}`);
if (!apply) { console.log("dry run, nothing written"); process.exit(0); }

const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED || process.env.DATABASE_URL });
await db.connect();
try {
  await db.query("begin");
  for (const f of withUrl) {
    await db.query("update plugins set product_url = $1, kind = $2 where plugin_id = any($3)", [f.url, f.type ?? null, f.ids]);
  }
  for (const f of changes) {
    for (const id of f.ids) {
      await db.query(
        `insert into category_votes (plugin_id, name, manufacturer, category, install_id, ip_hash)
         values ($1, $2, $3, $4, 'maker-site', 'maker-site')
         on conflict (plugin_id, install_id) do update set category = excluded.category, created_at = now()`,
        [id, f.name, f.maker, f.category]);
    }
  }
  await db.query("commit");
  console.log("written");
} catch (e) {
  await db.query("rollback");
  throw e;
} finally {
  await db.end();
}
