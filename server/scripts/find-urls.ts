// Finds each plugin's product page on its maker's own website (BL-119), with Exa search.
// Read only on the database: it writes a JSON file and a review page, nothing else.
//
//   npm run find-urls -- --sample 30      a sample spread across makers
//   npm run find-urls -- --all            every plugin
//
// The key comes from ~/.claude/exa.ag-plugfinder.env (EXA_API_KEY) and is never printed.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import pg from "pg";

const args = process.argv.slice(2);
const sample = args.includes("--sample") ? Number(args[args.indexOf("--sample") + 1] || 30) : 0;
const all = args.includes("--all");
if (!sample && !all) { console.error("Use --sample N or --all"); process.exit(1); }
const outDir = path.resolve("reports");
fs.mkdirSync(outDir, { recursive: true });

function exaKey(): string {
  if (process.env.EXA_API_KEY) return process.env.EXA_API_KEY;
  const f = path.join(os.homedir(), ".claude/exa.ag-plugfinder.env");
  const m = fs.readFileSync(f, "utf8").match(/^EXA_API_KEY=(.+)$/m);
  if (!m) throw new Error("No EXA_API_KEY in " + f);
  return m[1].trim();
}
const KEY = exaKey();

// The app's own maker → site list, read from the Swift file so there is one list.
const swift = fs.readFileSync(path.resolve("../AGPlugFinder/Info/MakerSites.swift"), "utf8");
const sites = [...swift.matchAll(/\("([^"]+)", "([^"]+)"\)/g)].map((m) => [m[1], m[2]] as [string, string]);
const siteFor = (maker: string) => sites.find(([k]) => maker.toLowerCase().includes(k))?.[1];

// "API-550A (m)" and "API-550A (s)" are one product.
const baseName = (n: string) => n.replace(/\s*\((m|s|m>s|m->s|mono|stereo)\)\s*$/i, "").replace(/\s+(mono|stereo)$/i, "").trim();
const words = (s: string) => s.toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length >= 2);
const badPath = /\/(blog|news|forum|forums|community|press|faq|kb|knowledge|tutorials?|videos?|cart|checkout|login|account|search|tag|category|artists?|download|downloads|legal|privacy|terms|manuals?|user-manuals?|docs?|documentation|support|help|release-notes|changelog|reviews?|industry-reviews)\b/i;

// The exact type decides the category, so the same kind always lands in the same place.
const TYPE_CATEGORY: Record<string, string> = {
  "Compressor": "Dynamics", "Limiter": "Dynamics", "Maximizer": "Dynamics", "Gate": "Dynamics", "Expander": "Dynamics",
  "De-esser": "Dynamics", "Transient Shaper": "Dynamics", "Multiband Dynamics": "Dynamics", "Dynamic EQ": "EQ", "EQ": "EQ",
  "Channel Strip": "Multi Effects", "Saturation": "Distortion", "Tape": "Distortion", "Distortion": "Distortion",
  "Bitcrusher": "Distortion", "Amp Simulator": "Amps and Pedals", "Cabinet": "Amps and Pedals", "Pedal": "Amps and Pedals",
  "Reverb": "Reverb", "Delay": "Delay", "Chorus": "Modulation", "Flanger": "Modulation", "Phaser": "Modulation",
  "Tremolo": "Modulation", "Rotary": "Modulation", "Filter": "Filter", "Pitch Correction": "Pitch", "Pitch Shifter": "Pitch",
  "Harmonizer": "Pitch", "Vocoder": "Modulation", "Stereo Imager": "Imaging", "Panner": "Imaging", "Meter": "Metering",
  "Analyzer": "Metering", "Noise Reduction": "Utility", "Restoration": "Utility", "Mastering Suite": "Multi Effects",
  "Mixing Suite": "Multi Effects", "Multi Effect": "Multi Effects", "Synth": "Synth", "Sampler": "Sampler",
  "Drum Machine": "Drums", "Drums": "Drums", "Piano": "Keys", "Electric Piano": "Keys", "Organ": "Keys", "Bass": "Bass",
  "Strings": "Orchestral", "Brass": "Orchestral", "Woodwinds": "Orchestral", "Choir": "Orchestral", "Orchestral": "Orchestral",
  "Arpeggiator": "MIDI FX", "MIDI Tool": "MIDI FX", "Utility": "Utility",
};

type Group = { maker: string; name: string; ids: string[]; current?: string };
type Found = Group & { site?: string; url?: string; title?: string; score: number; status?: number; note?: string;
  category?: string; type?: string };

// The app's categories (PluginCategories.all) and the exact kinds inside them (BL-120).
const CATEGORIES = ["Amps and Pedals", "Delay", "Distortion", "Dynamics", "EQ", "Filter", "Imaging", "Metering", "Modulation",
  "Multi Effects", "Pitch", "Reverb", "Utility", "Effects", "Synth", "Sampler", "Drums", "Keys", "Bass", "Orchestral", "MIDI FX"];
const TYPES = ["Compressor", "Limiter", "Maximizer", "Gate", "Expander", "De-esser", "Transient Shaper", "Multiband Dynamics",
  "Dynamic EQ", "EQ", "Channel Strip", "Saturation", "Tape", "Distortion", "Bitcrusher", "Amp Simulator", "Cabinet", "Pedal",
  "Reverb", "Delay", "Chorus", "Flanger", "Phaser", "Tremolo", "Rotary", "Filter", "Pitch Correction", "Pitch Shifter",
  "Harmonizer", "Vocoder", "Stereo Imager", "Panner", "Meter", "Analyzer", "Noise Reduction", "Restoration", "Mastering Suite",
  "Mixing Suite", "Multi Effect", "Synth", "Sampler", "Drum Machine", "Drums", "Piano", "Electric Piano", "Organ", "Bass",
  "Strings", "Brass", "Woodwinds", "Choir", "Orchestral", "Arpeggiator", "MIDI Tool", "Utility", "Other"];

const SYSTEM = `You classify one audio plugin from its maker's own product page.
Return the URL of the product page for exactly this plugin, not a bundle, news post or manual. If no page for this exact plugin is found, return url as an empty string.
category: the single best fit from the given list, by what the plugin mainly does.
type: the most precise kind from the given list. A limiter is Limiter, never Compressor; a loudness maximizer is Maximizer; a compressor that also limits is Compressor only if the page calls it a compressor first.
A virtual instrument's type is what it sounds like: a flute is Woodwinds, a violin section is Strings, a piano is Piano, a drum kit is Drums; Synth only for synthesizers.
A collection of guitar or bass pedal or amp models is Pedal or Amp Simulator, not Multi Effect.
Never guess: if the page does not say, use Other for type.`;
const SCHEMA = {
  type: "object",
  properties: {
    url: { type: "string" },
    category: { type: "string", enum: CATEGORIES },
    type: { type: "string", enum: TYPES },
  },
  required: ["url", "category", "type"],
};

let cost = 0;

async function search(query: string, site?: string) {
  const body: Record<string, unknown> = { query, type: "auto", systemPrompt: SYSTEM, outputSchema: SCHEMA,
    contents: { highlights: true } };
  // Adi asked for the maker's own website: the maker's domain is the allowlist.
  if (site) body.includeDomains = [site];
  const r = await fetch("https://api.exa.ai/search", {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": KEY },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`Exa ${r.status}: ${(await r.text()).slice(0, 200)}`);
  const j = (await r.json()) as { results: { url: string; title?: string }[]; costDollars?: { total?: number };
    output?: { content?: unknown } };
  cost += j.costDollars?.total ?? 0;
  let out = j.output?.content as { url?: string; category?: string; type?: string } | string | undefined;
  if (typeof out === "string") { try { out = JSON.parse(out); } catch { out = undefined; } }
  return { results: j.results ?? [], out: out as { url?: string; category?: string; type?: string } | undefined };
}

async function opens(url: string): Promise<number> {
  try {
    const r = await fetch(url, { redirect: "follow", signal: AbortSignal.timeout(12000),
      headers: { "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 Safari/605.1.15" } });
    return r.status;
  } catch { return 0; }
}

async function find(g: Group): Promise<Found> {
  const site = siteFor(g.maker);
  let results: { url: string; title?: string }[] = [];
  let out: { url?: string; category?: string; type?: string } | undefined;
  try {
    ({ results, out } = await search(`${g.maker} ${g.name} plugin`, site));
    // Nothing on the maker's domain (a second brand site, a shop): search the web, and below only
    // a site carrying the maker's name counts.
    if (site && !results.some((r) => { try { return new URL(r.url).hostname.endsWith(site); } catch { return false; } })) {
      ({ results, out } = await search(`${g.maker} ${g.name} audio plugin`));
    }
  } catch (e) { return { ...g, site, score: 0, note: String(e) }; }
  // The page the answer named comes first, then the other results.
  if (out?.url) results = [{ url: out.url, title: results.find((x) => x.url === out!.url)?.title }, ...results.filter((x) => x.url !== out!.url)];
  const want = words(g.name);
  const makerWords = words(g.maker).filter((w) => !["audio", "music", "the", "inc", "llc", "software", "technology", "records", "dsp"].includes(w));
  const type = out?.type && TYPES.includes(out.type) && out.type !== "Other" ? out.type : undefined;
  const category = (type && TYPE_CATEGORY[type]) || (out?.category && CATEGORIES.includes(out.category) ? out.category : undefined);
  let best: Found = { ...g, site, score: 0, category, type };
  for (const res of results) {
    let u: URL;
    try { u = new URL(res.url); } catch { continue; }
    const host = u.hostname.toLowerCase();
    if (!(site && host.endsWith(site.replace(/^www\./, ""))) && !makerWords.some((w) => host.includes(w))) continue;
    if (badPath.test(u.pathname) && !(site === "support.apple.com" && u.pathname.includes("/guide/"))) continue;
    if (/\.pdf$|\/wp-content\/uploads\//i.test(u.pathname) || host.startsWith("files.")) continue;
    const hay = (u.pathname + " " + (res.title ?? "")).toLowerCase().replace(/[^a-z0-9]+/g, " ");
    const score = want.filter((w) => hay.includes(w)).length / Math.max(1, want.length);
    if (score > best.score) best = { ...g, site, url: res.url, title: res.title, score, category, type };
  }
  if (best.url && best.score >= 0.5) {
    // Only a page that is really gone is dropped; sites that block checks or a slow network are not.
    best.status = await opens(best.url);
    if (best.status === 404 || best.status === 410) best.note = `page is gone (${best.status})`;
  } else {
    best.note = best.url ? "weak match, left empty" : "nothing on the maker's site";
    best.url = undefined;
  }
  // A category only from the plugin's own page, never a guess.
  if (!best.url || best.note) { best.category = undefined; best.type = undefined; }
  return best;
}

async function main() {
  const db = new pg.Client({ connectionString: process.env.DATABASE_URL_UNPOOLED || process.env.DATABASE_URL });
  await db.connect();
  await db.query("begin read only");
  const rows = (await db.query("select plugin_id, name, manufacturer, category from plugins order by manufacturer, name")).rows as
    { plugin_id: string; name: string; manufacturer: string; category: string | null }[];
  await db.query("commit");
  await db.end();

  const groups = new Map<string, Group>();
  for (const r of rows) {
    const name = baseName(r.name);
    const k = r.manufacturer + "|" + name.toLowerCase();
    const g = groups.get(k) ?? { maker: r.manufacturer, name, ids: [], current: r.category ?? undefined };
    g.ids.push(r.plugin_id);
    groups.set(k, g);
  }
  let list = [...groups.values()];
  if (sample) {
    // Spread across makers: one from each maker in turn, biggest makers first.
    const byMaker = new Map<string, Group[]>();
    for (const g of list) byMaker.set(g.maker, [...(byMaker.get(g.maker) ?? []), g]);
    const makers = [...byMaker.keys()].sort((a, b) => byMaker.get(b)!.length - byMaker.get(a)!.length);
    const picked: Group[] = [];
    for (let round = 0; picked.length < sample && round < 50; round++) {
      for (const m of makers) {
        const g = byMaker.get(m)![round * 7];
        if (g && picked.length < sample) picked.push(g);
      }
    }
    list = picked;
  }
  console.log(`${rows.length} plugins, ${groups.size} products, looking up ${list.length}`);

  const found: Found[] = [];
  let i = 0;
  async function worker() {
    while (i < list.length) {
      const g = list[i++];
      const f = await find(g);
      found.push(f);
      if (found.length % 25 === 0 || found.length === list.length) {
        console.log(`${found.length}/${list.length}  found ${found.filter((x) => x.url && !x.note).length}  cost $${cost.toFixed(3)}`);
      }
    }
  }
  await Promise.all(Array.from({ length: 4 }, worker));

  const stamp = sample ? `sample-${sample}` : "all";
  fs.writeFileSync(path.join(outDir, `urls-${stamp}.json`), JSON.stringify(found, null, 2));
  fs.writeFileSync(path.join(outDir, `urls-${stamp}.html`), page(found));
  const ok = found.filter((x) => x.url && !x.note).length;
  console.log(`done: ${ok} of ${found.length} with a page, Exa cost $${cost.toFixed(3)}`);
  console.log(path.join(outDir, `urls-${stamp}.html`));
}

function esc(s = "") { return s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!)); }

function page(found: Found[]) {
  const sorted = [...found].sort((a, b) => a.maker.localeCompare(b.maker) || a.name.localeCompare(b.name));
  const ok = found.filter((x) => x.url && !x.note).length;
  const rows = sorted.map((f) => `<tr class="${f.url && !f.note ? "ok" : "no"}">
    <td>${esc(f.maker)}</td><td>${esc(f.name)}${f.ids.length > 1 ? ` <span class=n>${f.ids.length} versions</span>` : ""}</td>
    <td class=${f.category && f.category !== f.current ? "chg" : ""}>${esc(f.current ?? "")}${f.category && f.category !== f.current ? ` → <b>${esc(f.category)}</b>` : ""}<div class=t>${esc(f.type ?? "")}</div></td>
    <td>${f.url && !f.note ? `<a href="${esc(f.url)}" target="_blank">${esc(f.url.replace(/^https?:\/\/(www\.)?/, ""))}</a><div class=t>${esc(f.title)}</div>` : `<span class=empty>${esc(f.note)}</span>`}</td></tr>`).join("\n");
  return `<!doctype html><meta charset=utf-8><title>Plugin website links</title>
<style>
:root{--bg:#0b0b0c;--card:#151517;--text:#f2f2f2;--muted:#9a9aa0;--line:#26262a;--accent:#f59e3d;--ok:#5bcf74}
body{margin:0;background:var(--bg);color:var(--text);font:14px -apple-system,system-ui,sans-serif}
main{max-width:1100px;margin:0 auto;padding:28px 16px}
h1{font-size:22px;margin:0 0 4px}.sub{color:var(--muted);margin-bottom:20px}
table{width:100%;border-collapse:collapse;background:var(--card);border-radius:14px;overflow:hidden}
td{padding:10px 12px;border-top:1px solid var(--line);vertical-align:top}
td:first-child{color:var(--muted);white-space:nowrap}a{color:var(--accent);text-decoration:none;word-break:break-all}
.t{color:var(--muted);font-size:12px;margin-top:2px}.empty{color:#e0605a;font-size:12px}.n{color:var(--muted);font-size:11px}.chg b{color:var(--ok)}
</style><main><h1>Plugin website links</h1>
<div class=sub>${ok} of ${found.length} products got a page on their maker's site. ${found.filter((f) => f.category && f.category !== f.current).length} would change category (green). The small grey word is the exact type. Click a few links to check they open the right plugin.</div>
<table>${rows}</table></main>`;
}

main().catch((e) => { console.error("FAILED", e?.stack || e); process.exit(1); });
