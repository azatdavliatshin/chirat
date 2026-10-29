#!/usr/bin/env python3
"""Render a unified git diff (git show / git diff output) as a self-contained HTML page.

usage: diff2html.py <in.diff> <out.html> [title]
"""
import html, re, sys

src, dst = sys.argv[1], sys.argv[2]
title = sys.argv[3] if len(sys.argv) > 3 else "diff"
text = open(src, encoding="utf-8", errors="replace").read().splitlines()

# optional commit header (from `git show`)
header = []
i = 0
while i < len(text) and not text[i].startswith("diff --git"):
    header.append(text[i]); i += 1
body = text[i:]

files = []  # (path, status, hunks:[(hdr, lines:[(kind, old_no, new_no, text)])], adds, dels)
cur = None
old_no = new_no = 0
for line in body:
    if line.startswith("diff --git"):
        m = re.match(r"diff --git a/(.*?) b/(.*)", line)
        cur = {"path": m.group(2) if m else line, "status": "modified", "hunks": [], "adds": 0, "dels": 0}
        files.append(cur); continue
    if cur is None: continue
    if line.startswith("new file mode"): cur["status"] = "added"; continue
    if line.startswith("deleted file mode"): cur["status"] = "deleted"; continue
    if line.startswith(("index ", "--- ", "+++ ", "similarity", "rename ", "old mode", "new mode", "Binary")): continue
    if line.startswith("@@"):
        m = re.match(r"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)", line)
        old_no, new_no = int(m.group(1)), int(m.group(2))
        cur["hunks"].append((line, [])); continue
    if not cur["hunks"]: continue
    lines = cur["hunks"][-1][1]
    if line.startswith("+"):
        lines.append(("add", "", new_no, line[1:])); new_no += 1; cur["adds"] += 1
    elif line.startswith("-"):
        lines.append(("del", old_no, "", line[1:])); old_no += 1; cur["dels"] += 1
    elif line.startswith("\\"):
        lines.append(("meta", "", "", line))
    else:
        lines.append(("ctx", old_no, new_no, line[1:] if line.startswith(" ") else line)); old_no += 1; new_no += 1

e = html.escape
out = [f"""<!DOCTYPE html><html><head><meta charset="utf-8"><title>{e(title)}</title><style>
:root{{--bg:#fff;--fg:#1f2328;--muted:#656d76;--line:#d0d7de;--add:#dafbe1;--addb:#aceebb;--del:#ffebe9;--delb:#ffcecb;--hunk:#ddf4ff;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}}
@media(prefers-color-scheme:dark){{:root{{--bg:#0d1117;--fg:#e6edf3;--muted:#8b949e;--line:#30363d;--add:#12261e;--addb:#1b4721;--del:#2d1214;--delb:#5a1e22;--hunk:#121d2f}}}}
body{{margin:0;padding:16px;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,system-ui,sans-serif}}
h1{{font-size:16px;margin:0 0 4px}} .sub{{color:var(--muted);font-family:var(--mono);font-size:12px;white-space:pre-wrap;margin:0 0 14px}}
.toc{{margin:0 0 16px;padding:0;list-style:none;font-family:var(--mono);font-size:12px}} .toc li{{margin:2px 0}} .toc a{{color:inherit;text-decoration:none}} .toc a:hover{{text-decoration:underline}}
.ad{{color:#1a7f37}} .dl{{color:#cf222e}} .st{{color:var(--muted)}}
details{{border:1px solid var(--line);border-radius:6px;margin:0 0 12px;overflow:hidden}}
summary{{cursor:pointer;padding:8px 12px;font-family:var(--mono);font-size:12px;background:color-mix(in srgb,var(--line) 25%,var(--bg));display:flex;gap:12px;align-items:center}}
summary .p{{font-weight:600;flex:1}}
table{{border-collapse:collapse;width:100%;font-family:var(--mono);font-size:12px;table-layout:fixed}}
td{{padding:0 8px;vertical-align:top;white-space:pre-wrap;word-break:break-all}}
td.n{{width:3.5em;text-align:right;color:var(--muted);user-select:none;border-right:1px solid var(--line)}}
tr.add td{{background:var(--add)}} tr.add td.n{{background:var(--addb)}}
tr.del td{{background:var(--del)}} tr.del td.n{{background:var(--delb)}}
tr.hunk td{{background:var(--hunk);color:var(--muted);padding:4px 8px}}
tr.meta td{{color:var(--muted)}}
</style></head><body>"""]
out.append(f"<h1>{e(title)}</h1>")
if header:
    out.append(f"<p class=sub>{e(chr(10).join(h for h in header if h.strip()))}</p>")
ta = sum(f["adds"] for f in files); td = sum(f["dels"] for f in files)
out.append(f"<p class=sub>{len(files)} files · <span class=ad>+{ta}</span> <span class=dl>−{td}</span></p><ul class=toc>")
for k, f in enumerate(files):
    out.append(f"<li><a href='#f{k}'>{e(f['path'])}</a> <span class=st>{f['status'] if f['status']!='modified' else ''}</span> <span class=ad>+{f['adds']}</span> <span class=dl>−{f['dels']}</span></li>")
out.append("</ul>")
for k, f in enumerate(files):
    out.append(f"<details id='f{k}' open><summary><span class=p>{e(f['path'])}</span><span class=st>{f['status']}</span><span class=ad>+{f['adds']}</span><span class=dl>−{f['dels']}</span></summary><table>")
    for hdr, lines in f["hunks"]:
        out.append(f"<tr class=hunk><td class=n></td><td class=n></td><td>{e(hdr)}</td></tr>")
        for kind, o, n, t in lines:
            out.append(f"<tr class={kind}><td class=n>{o}</td><td class=n>{n}</td><td>{e(t)}</td></tr>")
    out.append("</table></details>")
out.append("</body></html>")
open(dst, "w", encoding="utf-8").write("\n".join(out))
print(dst, len(files), "files", f"+{ta} -{td}")
