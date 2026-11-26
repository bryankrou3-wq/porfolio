#!/usr/bin/env python3
"""Build a small, accessible French AI/network-monitoring RSS watch page."""
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from html import escape
from urllib.parse import quote
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

QUERIES = [
    '"AI" "network monitoring" anomaly detection',
    '"machine learning" network anomaly detection',
    '"AI" network observability monitoring',
    '"intelligence artificielle" supervision réseau anomalies',
    'AIOps network monitoring',
]
MAX_ITEMS = 30
RSS_BASE = "https://news.google.com/rss/search?q={query}&hl=fr&gl=FR&ceid=FR:fr"

def fetch_feed(query):
    url = RSS_BASE.format(query=quote(query))
    req = Request(url, headers={"User-Agent": "Mozilla/5.0 (compatible; PortfolioTechWatch/1.0)"})
    with urlopen(req, timeout=25) as response:
        data = response.read()
    root = ET.fromstring(data)
    return root.findall("./channel/item")

def text(node, path):
    child = node.find(path)
    return (child.text or "").strip() if child is not None else ""

def parse_date(value):
    try:
        dt = parsedate_to_datetime(value)
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%d")
    except Exception:
        return ""

def main():
    items, seen = [], set()
    for query in QUERIES:
        try:
            for item in fetch_feed(query):
                link = text(item, "link")
                title = text(item, "title")
                if not link or not title or link in seen:
                    continue
                seen.add(link)
                items.append({
                    "title": title,
                    "link": link,
                    "source": text(item, "source"),
                    "date": parse_date(text(item, "pubDate")),
                    "description": text(item, "description"),
                })
        except Exception as exc:
            print(f"Feed unavailable for query {query!r}: {exc}")

    items.sort(key=lambda item: item["date"], reverse=True)
    items = items[:MAX_ITEMS]
    generated = datetime.now(timezone.utc).strftime("%d/%m/%Y à %H:%M UTC")

    cards = []
    for item in items:
        title = escape(item["title"])
        link = escape(item["link"], quote=True)
        source = escape(item["source"] or "Source de l’article")
        date = escape(item["date"] or "Date non précisée")
        cards.append(f"""
        <article class="article">
          <div class="meta"><span>{source}</span><time>{date}</time></div>
          <h3><a href="{link}" target="_blank" rel="noopener noreferrer">{title}</a></h3>
          <a class="read" href="{link}" target="_blank" rel="noopener noreferrer">Lire l’article <span aria-hidden="true">↗</span></a>
        </article>""")

    content = "\n".join(cards) if cards else """
      <div class="empty"><strong>Aucun article n’a été récupéré.</strong>
      <p>La prochaine mise à jour automatique réessaiera. Tu peux aussi lancer le workflow manuellement dans GitHub Actions.</p></div>"""

    page = f"""<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Veille IA — Supervision réseau</title>
<style>
:root{{font-family:Inter,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#e8eef8;background:#0b1220}}
*{{box-sizing:border-box}}body{{margin:0;padding:20px;background:transparent}}
.wrap{{max-width:1100px;margin:auto}}.top{{padding:24px;border:1px solid #26344a;border-radius:20px;background:linear-gradient(135deg,#172943,#101827);margin-bottom:18px}}
.eyebrow{{color:#80b7ff;text-transform:uppercase;letter-spacing:.12em;font-size:.75rem;font-weight:700}}
h1{{font-size:clamp(1.4rem,3vw,2.2rem);line-height:1.2;margin:10px 0}}.intro{{color:#b8c6da;line-height:1.6;margin:0}}
.status{{display:flex;flex-wrap:wrap;gap:8px;margin-top:16px}}.pill{{font-size:.78rem;padding:6px 10px;border-radius:999px;background:#24344c;color:#dbeafe}}
.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,280px),1fr));gap:14px}}
.article{{padding:18px;border:1px solid #25344a;border-radius:16px;background:#111c2d;display:flex;flex-direction:column;min-height:180px}}
.meta{{display:flex;justify-content:space-between;gap:8px;color:#91a5c0;font-size:.75rem}}.meta span{{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
h3{{font-size:1rem;line-height:1.5;margin:14px 0}}h3 a{{color:#f3f7ff;text-decoration:none}}h3 a:hover{{color:#8ec5ff}}
.read{{margin-top:auto;color:#80b7ff;text-decoration:none;font-size:.85rem;font-weight:650}}
.footer{{color:#8192a9;font-size:.75rem;text-align:center;margin:18px 0 4px}}.empty{{padding:24px;border:1px dashed #465770;border-radius:14px;color:#c8d5e7}}
</style>
</head>
<body><main class="wrap">
<header class="top"><div class="eyebrow">Veille technologique · BTS SIO SISR</div>
<h1>L’intelligence artificielle au service de la supervision et de la détection des anomalies réseau</h1>
<p class="intro">Actualités sur la supervision intelligente, l’analyse du trafic, la détection d’anomalies et l’AIOps.</p>
<div class="status"><span class="pill">{len(items)} articles sélectionnés</span><span class="pill">Mise à jour : {generated}</span><span class="pill">Flux RSS automatisés</span></div>
</header>
<section class="grid" aria-label="Articles de veille">{content}
</section>
<p class="footer">Articles provenant de Google Actualités RSS · Ouvre chaque titre pour consulter la source originale.</p>
</main></body></html>"""
    with open("veille.html", "w", encoding="utf-8") as file:
        file.write(page)
    print(f"Generated veille.html with {len(items)} articles")

if __name__ == "__main__":
    main()
