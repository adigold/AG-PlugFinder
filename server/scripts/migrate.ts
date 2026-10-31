import { readFileSync, readdirSync } from "node:fs";
import { neon } from "@neondatabase/serverless";

// Applies every migration in order over the direct (unpooled) connection.
const url = process.env.DATABASE_URL_UNPOOLED ?? process.env.DATABASE_URL;
if (!url) throw new Error("DATABASE_URL_UNPOOLED is not set");
const sql = neon(url);
for (const file of readdirSync("migrations").sort()) {
  const text = readFileSync(`migrations/${file}`, "utf8");
  for (const statement of text.split(/;\s*$/m).map((s) => s.trim()).filter((s) => s && !/^(--.*\n?)*$/.test(s))) {
    await sql.query(statement);
  }
  console.log(`applied ${file}`);
}
