// Adds the pictures of Ableton Live's own devices to the shared database (BL-166).
// Reads the app's catalog (AbletonCatalog.swift) for names and categories, and the pictures that
// ship with the app (Bundled/LogicScreenshots/ableton-*.jpg). Only adds: a device that already
// has a picture is left as it is.
// Usage: npx tsx --env-file=.env.local scripts/add-builtin-pictures.ts [--dry]
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import pg from "pg";

const root = join(import.meta.dirname, "..", "..");
const swift = readFileSync(join(root, "AGPlugFinder/Ableton/AbletonCatalog.swift"), "utf8");
const devices: { id: string; name: string; category: string }[] = [];
const slug = (n: string) => n.toLowerCase().replace(/[^a-z0-9]/g, "");
for (const m of swift.matchAll(/all \+= (?:fx|inst)\("([^"]+)", \[([^\]]+)\]\)/g)) {
  for (const n of m[2].matchAll(/"([^"]+)"/g)) devices.push({ id: "ableton-" + slug(n[1]), name: n[1], category: m[1] });
}
const midi = swift.match(/all \+= \[([^\]]+)\]\.map \{ \(\$0, "MIDI FX"/);
if (midi) for (const n of midi[1].matchAll(/"([^"]+)"/g)) devices.push({ id: "ableton-" + slug(n[1]) + "-midi", name: n[1], category: "MIDI FX" });

const dry = process.argv.includes("--dry");
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL_UNPOOLED });
let added = 0, kept = 0, missing: string[] = [];
for (const d of devices) {
  const file = join(root, "Bundled/LogicScreenshots", d.id + ".jpg");
  if (!existsSync(file)) { missing.push(d.name); continue; }
  if (dry) { added++; continue; }
  const res = await pool.query(
    `insert into plugins (plugin_id, name, manufacturer, version, category, picture, picture_type)
     values ($1, $2, 'Ableton', null, $3, $4, 'image/jpeg') on conflict (plugin_id) do nothing`,
    [d.id, d.name, d.category, readFileSync(file)]);
  if (res.rowCount) added++; else kept++;
}
console.log(`${devices.length} devices: ${dry ? "would add" : "added"} ${added}, already there ${kept}, no picture ${missing.length}${missing.length ? ": " + missing.join(", ") : ""}`);
await pool.end();
