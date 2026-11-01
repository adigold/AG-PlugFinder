#!/usr/bin/env python3
"""Rebuilds the README's Release notes section from release-notes/*.md (BL-134).

The same files feed the app's What's New window, so the README never says something the app
didn't. Only versions from FIRST onward (the first public release). The newest few stay open;
the rest fold into one collapsed list.

Usage: scripts/readme-whatsnew.py   (run from the project root)
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
README = ROOT / "README.md"
NOTES = ROOT / "release-notes"
FIRST = (0, 5, 0)
OPEN = 3
START, END = "<!-- release-notes:start -->", "<!-- release-notes:end -->"


def version(p):
    return tuple(int(x) for x in p.stem.split("."))


def block(p):
    lines = [l.strip() for l in p.read_text().splitlines() if l.strip().startswith("- ")]
    out = []
    for l in lines:
        # "- New: Text" becomes "- **New:** Text"
        m = re.match(r"- (New|Improved|Fixed|Faster):\s*(.*)", l)
        out.append(f"- **{m.group(1)}:** {m.group(2)}" if m else l)
    return f"**{p.stem}**\n\n" + "\n".join(out)


files = sorted((p for p in NOTES.glob("*.md") if re.fullmatch(r"\d+\.\d+\.\d+", p.stem) and version(p) >= FIRST),
               key=version, reverse=True)
recent = "\n\n".join(block(p) for p in files[:OPEN])
older = "\n\n".join(block(p) for p in files[OPEN:])
section = f"""{START}
## Release notes

Everything each version brought, newest first. The same notes appear in the app's What's New window.

{recent}

<details>
<summary><b>Earlier versions</b> ({files[-1].stem} to {files[OPEN].stem})</summary>

{older}

</details>

See every download on the [Releases page](https://github.com/adigold/AG-PlugFinder/releases).
{END}"""

text = README.read_text()
if START in text:
    text = re.sub(re.escape(START) + r".*?" + re.escape(END), lambda _: section, text, flags=re.S)
else:
    raise SystemExit(f"README has no {START} marker")
README.write_text(text)
print(f"Release notes: {len(files)} versions, {files[0].stem} newest")
