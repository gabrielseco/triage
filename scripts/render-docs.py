#!/usr/bin/env python3
"""Render docs/HOW_IT_WORKS.md into a standalone docs/HOW_IT_WORKS.html (markdown stays the source).

The markdown is embedded as a JSON string and rendered in the browser by `marked`; a table of
contents is built from the h2/h3 headings. Needs internet on first open for the two CDN scripts.
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "docs" / "HOW_IT_WORKS.md"
OUT = ROOT / "docs" / "HOW_IT_WORKS.html"

TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Triage — How it works</title>
<link rel="icon" href="../Resources/AppIcon.svg">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
  :root {
    --bg: #fbfbfe; --panel: #ffffff; --text: #1d1c3b; --muted: #62618a; --border: #e4e4f2;
    --accent: #5b5cf0; --hot: #f0364a; --code-bg: #f3f3fb; --pre-bg: #1e1d4a; --pre-text: #e8e8ff;
    --row: #f7f7fd;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #12112b; --panel: #1a1940; --text: #e9e9fb; --muted: #a3a2c9; --border: #2d2c5e;
      --accent: #8f90ff; --hot: #ff7a6b; --code-bg: #25245a; --pre-bg: #0c0b22; --pre-text: #e8e8ff;
      --row: #1f1e4a;
    }
  }
  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; scroll-padding-top: 24px; }
  body { margin: 0; background: var(--bg); color: var(--text); font: 16px/1.65 Inter, system-ui, sans-serif; }
  .layout { display: grid; grid-template-columns: 280px minmax(0, 1fr); max-width: 1280px; margin: 0 auto; }
  nav { position: sticky; top: 0; height: 100vh; overflow-y: auto; padding: 32px 20px 32px 24px; border-right: 1px solid var(--border); }
  nav .brand { display: flex; align-items: center; gap: 10px; font-weight: 700; font-size: 18px; margin-bottom: 20px; }
  nav .brand img { width: 36px; height: 36px; }
  nav a { display: block; color: var(--muted); text-decoration: none; font-size: 14px; padding: 4px 8px; border-radius: 6px; }
  nav a.h3 { padding-left: 22px; font-size: 13px; }
  nav a:hover { color: var(--text); background: var(--row); }
  nav a.active { color: var(--accent); background: var(--row); font-weight: 600; }
  main { padding: 40px 56px 120px; min-width: 0; }
  h1 { font-size: 40px; line-height: 1.15; margin: 0 0 8px; letter-spacing: -0.02em; }
  h2 { font-size: 26px; margin: 56px 0 12px; padding-top: 8px; letter-spacing: -0.01em; }
  h3 { font-size: 19px; margin: 32px 0 8px; }
  hr { border: 0; border-top: 1px solid var(--border); margin: 40px 0; }
  a { color: var(--accent); }
  p, li { max-width: 78ch; }
  strong { font-weight: 600; }
  code { font-family: "JetBrains Mono", ui-monospace, monospace; font-size: 0.86em; background: var(--code-bg); padding: 2px 6px; border-radius: 5px; }
  pre { background: var(--pre-bg); color: var(--pre-text); padding: 18px 20px; border-radius: 12px; overflow-x: auto; line-height: 1.5; }
  pre code { background: none; padding: 0; font-size: 13px; color: inherit; }
  table { border-collapse: collapse; width: 100%; margin: 16px 0 24px; font-size: 14px; display: block; overflow-x: auto; }
  th, td { text-align: left; padding: 9px 12px; border-bottom: 1px solid var(--border); vertical-align: top; }
  th { font-weight: 600; background: var(--row); white-space: nowrap; }
  tr:hover td { background: var(--row); }
  blockquote { margin: 16px 0; padding: 4px 16px; border-left: 3px solid var(--accent); color: var(--muted); }
  @media (max-width: 900px) {
    .layout { grid-template-columns: 1fr; }
    nav { position: static; height: auto; border-right: 0; border-bottom: 1px solid var(--border); }
    main { padding: 24px 16px 80px; }
    h1 { font-size: 30px; }
  }
</style>
</head>
<body>
<div class="layout">
  <nav id="toc"><div class="brand"><img src="../Resources/AppIcon.svg" alt="">Triage</div></nav>
  <main id="content">Loading…</main>
</div>
<script src="https://cdn.jsdelivr.net/npm/marked@12/marked.min.js"></script>
<script>
  const md = __MARKDOWN__;
  const main = document.getElementById("content");
  main.innerHTML = marked.parse(md);

  const slug = (s) => s.toLowerCase().replace(/[^\w\s-]/g, "").trim().replace(/\s+/g, "-");
  const toc = document.getElementById("toc");
  const links = [];
  main.querySelectorAll("h2, h3").forEach((h) => {
    h.id = slug(h.textContent);
    const a = document.createElement("a");
    a.href = "#" + h.id;
    a.textContent = h.textContent;
    a.className = h.tagName.toLowerCase();
    toc.appendChild(a);
    links.push([h, a]);
  });

  const observer = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (!e.isIntersecting) return;
      links.forEach(([, a]) => a.classList.remove("active"));
      const hit = links.find(([h]) => h === e.target);
      if (hit) hit[1].classList.add("active");
    });
  }, { rootMargin: "0px 0px -75% 0px" });
  links.forEach(([h]) => observer.observe(h));
</script>
</body>
</html>
"""

md = SRC.read_text()
# JSON-encode, and break up "</" so the markdown can never close the <script> tag early.
payload = json.dumps(md).replace("</", "<\\/")
OUT.write_text(TEMPLATE.replace("__MARKDOWN__", payload))
print(OUT)
