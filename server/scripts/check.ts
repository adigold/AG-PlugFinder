import { db } from "../src/db.js";

// End-to-end check: write a test submission, read it back, delete it.
const sql = db();
const [{ now }] = await sql`select now()`;
console.log("connected, server time", now);
const picture = Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
const [row] = await sql`
  insert into submissions (au_type, au_subtype, au_maker, name, manufacturer, picture, picture_type)
  values ('aufx', 'test', 'AGPF', 'Check Plugin', 'AG', ${picture}, 'image/jpeg')
  returning id, status`;
console.log("inserted submission", row);
const [back] = await sql`select name, length(picture) as bytes from submissions where id = ${row.id}`;
console.log("read back", back);
await sql`delete from submissions where id = ${row.id}`;
const [{ count }] = await sql`select count(*)::int as count from submissions where id = ${row.id}`;
console.log("deleted, remaining", count);
const tables = await sql`select table_name from information_schema.tables where table_schema = 'public' order by 1`;
console.log("tables", tables.map((t) => t.table_name).join(", "));
