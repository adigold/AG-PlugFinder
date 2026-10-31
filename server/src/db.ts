import { neon } from "@neondatabase/serverless";

// Neon's HTTP driver: one query per request, made for serverless functions (Vercel).
// DATABASE_URL is the pooled connection; it never ships inside the Mac app.
export function db() {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is not set");
  return neon(url);
}
