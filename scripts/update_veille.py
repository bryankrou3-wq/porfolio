#!/usr/bin/env python3
"""Génère une veille courte en français sur l'IA et la supervision réseau."""
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from html import escape, unescape
from urllib.parse import quote
from urllib.request import Request, urlopen
import re
import xml.etree.ElementTree as ET

# Recherches en français uniquement : Google Actualités RSS configuré sur France/français.
QUERIES = [
    '"intelligence artificielle" supervision réseau when:30d',
    '"IA" détection anomalies réseau when:30d',
    '"AIOps" réseau observabilité when:30d',
    '"intelligence artificielle" trafic réseau automatisation when:30d',
]
MAX_ITEMS = 8
RSS_BASE = "https://news.google.com/rss/search?q={query}&hl=fr&gl=FR&ceid=FR:fr"

FRENCH_WORDS = {
    "le", "la", "les", "des", "une", "un", "dans", "pour", "sur", "avec",
    "et", "est", "sont", "du", "de", "au", "aux", "par", "qui", "que",
    "réseau", "réseaux", "détection", "supervision", "intelligence", "artificielle",
    "analyse", "sécurité", "cybersécurité", "trafic", "anomalies", "l'ia", "l’intelligence"
}
ENGLISH_WORDS = {
    "the", "and", "for", "with", "from", "how", "what", "when", "new",
    "network", "networks", "monitoring", "detection", "artificial", "intelligence",
    "machine", "learning", "security", "traffic", "anomaly", "anomalies"
}

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

def is_french(title, description):
    # La langue du titre est prioritaire : une description traduite ne doit pas
    # faire passer un titre anglais dans la sélection.
    title_plain = re.sub(r"<[^>]+>", " ", unescape(title)).lower()
    combined = re.sub(r"<[^>]+>", " ", unescape(title + " " + description)).lower()
    title_words = set(re.findall(r"[a-zà-ÿ’']+", title_plain))
    combined_words = set(re.findall(r"[a-zà-ÿ’']+", combined))
    title_fr = len(title_words & FRENCH_WORDS)
    combined_fr = len(combined_words & FRENCH_WORDS)
    title_en = len(title_words & ENGLISH_WORDS)
    # Un titre doit présenter des marqueurs français, ou être clairement
    # français par ses accents et sa description. On rejette les titres anglais.
    title_has_accent = any(c in title_plain for c in "àâçéèêëîïôùûüÿœ")
    return title_en == 0 and (title_fr >= 2 or (title_has_accent and combined_fr >= 2))

def main():
    items, seen = [], set()
    for query in QUERIES:
        try:
            for item in fetch_feed(query):
                link = text(item, "link")
                title = text(item, "title")
                description = text(item, "description")
                if not link or not title or link in seen or not is_french(title, description):
                    continue
                seen.add(link)
                source_node = item.find("source")
                source_url = source_node.attrib.get("url", "").strip() if source_node is not None else ""
                items.append({
                    "title": title,
                    "link": link,
                    "source": text(item, "source"),
                    "source_url": source_url,
                    "date": parse_date(text(item, "pubDate")),
                })
        except Exception as exc:
            print(f"Flux indisponible pour {query!r}: {exc}")

    items.sort(key=lambda item: item["date"], reverse=True)
    items = items[:MAX_ITEMS]
    generated = datetime.now(timezone.utc).strftime("%d/%m/%Y à %H:%M UTC")

    cards = []
    for item in items:
        title = escape(item["title"])
        link = escape(item["link"], quote=True)
        source = escape(item["source"] or "Source de l’article")
        source_url = item.get("source_url", "")
        source_link = (
            f"<a href=\"{escape(source_url, quote=True)}\" target=\"_blank\" rel=\"noopener noreferrer\">{source}</a>"
            if source_url.startswith(("https://", "http://")) else source
        )
        date = escape(item["date"] or "Date non précisée")
        source_action = (
            f"<a href=\"{escape(source_url, quote=True)}\" target=\"_blank\" rel=\"noopener noreferrer\">Voir le site de la source ↗</a>"
            if source_url.startswith(("https://", "http://")) else ""
        )
        cards.append(f"""
        <article class="veille-card">
          <div class="veille-cat">IA · Supervision réseau</div>
          <h3><a href="{link}" target="_blank" rel="noopener noreferrer" style="color:var(--text);text-decoration:none">{title}</a></h3>
          <p class="veille-source">Source : {source_link} · {date}</p>
          <p class="veille-actions"><a href="{link}" target="_blank" rel="noopener noreferrer" style="color:var(--accent);text-decoration:none;font-weight:700">Lire l’article sélectionné ↗</a></p>
        </article>""")
    # Publie aussi les cartes seules : le portfolio les charge dans sa rubrique sans iframe.
    fragment_content = "\n".join(cards) if cards else """
      <article class="veille-card">
        <div class="veille-cat">Veille automatisée</div>
        <h3>Aucun article français pertinent pour le moment</h3>
        <p>La veille sera actualisée automatiquement lors du prochain passage.</p>
      </article>"""
    with open("veille-fragment.html", "w", encoding="utf-8") as fragment_file:
        fragment_file.write(fragment_content)

    content = "\n".join(cards) if cards else """
      <div class="empty"><strong>Aucun article français pertinent n’a été récupéré.</strong>
      <p>La prochaine mise à jour réessaiera automatiquement.</p></div>"""

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
<p class="intro">Une sélection courte d’articles en français sur la supervision intelligente, l’analyse du trafic, la détection d’anomalies et l’AIOps.</p>
<div class="status"><span class="pill">{len(items)} articles (maximum {MAX_ITEMS})</span><span class="pill">Mise à jour : {generated}</span><span class="pill">Flux RSS en français</span></div>
</header>
<section class="grid" aria-label="Articles de veille">{content}
</section>
<p class="footer">Articles issus de Google Actualités RSS · Sélection en français · Ouvre un titre pour lire la source.</p>
</main></body></html>"""
    with open("veille.html", "w", encoding="utf-8") as file:
        file.write(page)
    print(f"veille.html généré : {len(items)} articles français (maximum {MAX_ITEMS})")

if __name__ == "__main__":
    main()
