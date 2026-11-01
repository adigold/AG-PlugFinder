// The category changes the lookup found, as a page to review (BL-120). Read only.
import fs from "node:fs";

type Found = { maker: string; name: string; ids: string[]; current?: string; url?: string; note?: string; category?: string; type?: string };
const src = fs.existsSync("reports/urls-all.json") ? "reports/urls-all.json" : "reports/urls-all.partial.jsonl";
const all: Found[] = src.endsWith(".json") ? JSON.parse(fs.readFileSync(src, "utf8"))
  : fs.readFileSync(src, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
const esc = (s = "") => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
// What the app will show: Dynamics splits by the exact kind (BL-121).
const shown = (f: Found) => f.category === "Dynamics"
  ? (f.type === "Compressor" ? "Compressor" : f.type === "Limiter" || f.type === "Maximizer" ? "Limiter" : "Dynamics") : f.category!;
// Database labels that say nothing ("Effect", "Instrument"); anything else is a real category.
const VAGUE = new Set(["Effect", "Effects", "Instrument", "Music Effect", "Generator", "MIDI Effect", ""]);
// Never from a real category to plain "Effects".
const isChange = (f: Found) => !!f.category && !f.note && !!f.url && f.category !== f.current
  && !(f.category === "Effects" && !VAGUE.has(f.current ?? ""));
const changes = all.filter(isChange)
  .sort((a, b) => shown(a).localeCompare(shown(b)) || a.maker.localeCompare(b.maker) || a.name.localeCompare(b.name));
const same = all.filter((f) => f.category && !f.note && f.url && f.category === f.current).length;
const counts = new Map<string, number>();
for (const f of changes) counts.set(shown(f), (counts.get(shown(f)) ?? 0) + 1);
const chips = [...counts].sort((a, b) => b[1] - a[1]).map(([c, n]) => `<button data-c="${esc(c)}">${esc(c)} <span>${n}</span></button>`).join("");
const rows = changes.map((f) => `<tr data-c="${esc(shown(f))}"><td class=m>${esc(f.maker)}</td><td><b>${esc(f.name)}</b>${f.ids.length > 1 ? ` <span class=v>${f.ids.length} versions</span>` : ""}</td>
<td class=old>${esc(f.current || "none")}</td><td class=arrow>→</td><td class=new>${esc(shown(f))}</td><td class=k>${esc(f.type ?? "")}</td>
<td><a href="${esc(f.url)}" target=_blank>maker's page ↗</a></td></tr>`).join("\n");
fs.writeFileSync("reports/category-changes.html", `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>Category changes</title><style>
:root{--bg:#0b0b0c;--card:#151517;--raised:#232327;--text:#f2f2f2;--muted:#9a9aa0;--line:#26262a;--accent:#f59e3d;--ok:#5bcf74;--old:#e0605a}
body{margin:0;background:var(--bg);color:var(--text);font:14px -apple-system,system-ui,sans-serif}
main{max-width:1180px;margin:0 auto;padding:28px 16px}h1{font-size:24px;margin:0 0 6px}
.sub{color:var(--muted);margin-bottom:16px;line-height:1.5}.stats{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:16px}
.stat{background:var(--card);border-radius:14px;padding:12px 16px}.stat b{display:block;font-size:22px}.stat span{color:var(--muted);font-size:12px}
.chips{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:12px}button{background:var(--raised);color:var(--text);border:0;border-radius:99px;padding:7px 12px;font:13px inherit;cursor:pointer}
button span{opacity:.55}button.on{background:#fff;color:#000}input{width:100%;box-sizing:border-box;background:var(--raised);border:0;border-radius:99px;padding:10px 16px;color:var(--text);font:14px inherit;margin-bottom:14px}
.wrap{overflow-x:auto}table{width:100%;border-collapse:collapse;background:var(--card);border-radius:14px;overflow:hidden}
td{padding:9px 12px;border-top:1px solid var(--line);white-space:nowrap}.m{color:var(--muted)}.v{color:var(--muted);font-size:11px}
.old{color:var(--old);text-decoration:line-through}.arrow{color:var(--muted)}.new{color:var(--ok);font-weight:600}.k{color:var(--muted);font-size:12px}
a{color:var(--accent);text-decoration:none}</style><main>
<h1>Category changes</h1>
<div class=sub>From each plugin's own page on its maker's website. Old category in red, new in green, the exact kind in grey. Click "maker's page" to check any of them. Nothing is applied until you say so.</div>
<div class=stats><div class=stat><b>${all.length}</b><span>products checked</span></div><div class=stat><b>${changes.filter((f) => VAGUE.has(f.current ?? "")).length}</b><span>vague label gets a real category</span></div><div class=stat><b>${changes.filter((f) => !VAGUE.has(f.current ?? "")).length}</b><span>real category corrected</span></div><div class=stat><b>${same}</b><span>already right</span></div><div class=stat><b>${all.filter((f) => !f.url || f.note).length}</b><span>no maker page found, unchanged</span></div></div>
<div class=chips><button class=on data-c="">All <span>${changes.length}</span></button>${chips}</div>
<input id=q placeholder="Find a plugin or maker">
<div class=wrap><table>${rows}</table></div></main>
<script>
let cat="";const q=document.getElementById("q");
function f(){const t=q.value.toLowerCase();for(const r of document.querySelectorAll("tr")){const ok=(!cat||r.dataset.c===cat)&&(!t||r.textContent.toLowerCase().includes(t));r.style.display=ok?"":"none"}}
for(const b of document.querySelectorAll("button")){b.onclick=()=>{cat=b.dataset.c;document.querySelectorAll("button").forEach(x=>x.classList.toggle("on",x===b));f()}}
q.oninput=f;
</script>`);
console.log(`${all.length} checked, ${changes.length} changes, ${same} already right -> reports/category-changes.html`);
