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

def clean_summary(value, limit=360):
    value = unescape(value or "")
    value = re.sub(r"<[^>]+>", " ", value)
    value = re.sub(r"\\s+", " ", value).strip()
    if len(value) > limit:
        value = value[:limit].rsplit(" ", 1)[0].rstrip(" ,;:") + "…"
    return value

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
                    "summary": clean_summary(description),
                })
        except Exception as exc:
            print(f"Flux indisponible pour {query!r}: {exc}")

    items.sort(key=lambda item: item["date"], reverse=True)
    items = items[:MAX_ITEMS]
    generated = datetime.now(timezone.utc).strftime("%d/%m/%Y à %H:%M UTC")

    cards = []
    fragment_cards = []
    categories = {
        "Supervision": ("supervision", "monitoring", "observabilité", "observabilite", "zabbix", "nagios", "prometheus"),
        "AIOps": ("aiops", "automatisation", "automatisé", "automatisée", "agent ia", "agents ia"),
        "Cybersécurité": ("cyber", "sécurité", "securite", "attaque", "vulnérabilité", "vulnerabilite", "détection", "detection"),
        "Réseau": ("réseau", "reseau", "trafic", "routeur", "infrastructure", "nginx", "dns", "tcp", "ip"),
    }

    def classify(item):
        text_value = (item.get("title", "") + " " + item.get("summary", "")).lower()
        for category, keywords in categories.items():
            if any(keyword in text_value for keyword in keywords):
                return category
        return "IA"

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
        summary = escape(item.get("summary") or "Article lié à la supervision réseau et à l’intelligence artificielle.")
        topic = classify(item)
        card = f"""
        <article class="veille-card" data-topic="{escape(topic, quote=True)}" data-search="{escape((item['title']+' '+item.get('source','')+' '+item.get('summary','')).lower(), quote=True)}" data-date="{escape(item.get('date',''), quote=True)}">
          <div class="card-meta"><span class="veille-cat">{escape(topic)} · IA réseau</span><time>{date}</time></div>
          <h3><a href="{link}" target="_blank" rel="noopener noreferrer">{title}</a></h3>
          <p class="veille-source">Source : {source_link}</p>
          <p class="veille-summary">{summary}</p>
          <p class="veille-actions"><a href="{link}" target="_blank" rel="noopener noreferrer">Lire l’article complet ↗</a></p>
        </article>"""
        cards.append(card)
        fragment_cards.append(card)

    fragment_content = "\n".join(fragment_cards) if fragment_cards else """
      <article class="veille-card empty">
        <h3>Aucun article français pertinent pour le moment</h3>
        <p>La prochaine mise à jour réessaiera automatiquement.</p>
      </article>"""
    with open("veille-fragment.html", "w", encoding="utf-8") as fragment_file:
        fragment_file.write(fragment_content)

    content = "\n".join(cards) if cards else """
      <article class="veille-card empty"><h3>Aucun article français pertinent n’a été récupéré.</h3>
      <p>La prochaine mise à jour réessaiera automatiquement.</p></article>"""
    generated = datetime.now(timezone.utc).strftime("%d/%m/%Y à %H:%M UTC")
    page = f"""<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>Veille interactive — IA et réseau</title>
<style>
:root{{font-family:Inter,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#e8eef8;background:#080b12}}
*{{box-sizing:border-box}}body{{margin:0;padding:18px;background:transparent}}
.wrap{{max-width:1250px;margin:auto}}
.hero{{padding:22px;border:1px solid #302347;border-radius:18px;background:linear-gradient(135deg,#1c1630,#10121b);margin-bottom:16px}}
.eyebrow{{color:#bb7cff;text-transform:uppercase;letter-spacing:.13em;font-size:.72rem;font-weight:850}}
h1{{font-size:clamp(1.35rem,2.8vw,2rem);line-height:1.25;margin:10px 0}}
.lead{{color:#bcb8c9;line-height:1.7;margin:0;max-width:1000px}}
.pills{{display:flex;flex-wrap:wrap;gap:8px;margin-top:14px}}.pill{{font-size:.75rem;padding:6px 10px;border-radius:999px;background:#292039;color:#e9d9ff;border:1px solid #3c2d56}}
.toolbar{{display:grid;grid-template-columns:minmax(0,1fr) minmax(150px,220px) auto;gap:10px;margin:14px 0}}
.toolbar input,.toolbar select{{width:100%;min-height:44px;border:1px solid #393044;border-radius:10px;background:#111018;color:#f1eaff;padding:10px 12px;font:inherit}}
.toolbar button,.more{{border:1px solid #69439a;background:#2b1b42;color:#e9d9ff;border-radius:10px;padding:10px 15px;font:inherit;font-weight:800;cursor:pointer}}
.toolbar button:hover,.more:hover{{background:#3b2457}}
.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,310px),1fr));gap:14px}}
.veille-card{{padding:19px;border:1px solid #2b2733;border-radius:16px;background:#111014;display:flex;flex-direction:column;min-height:280px}}
.card-meta{{display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap}}
.veille-cat{{font-size:.68rem;text-transform:uppercase;letter-spacing:.08em;color:#bb7cff;font-weight:850}}
time{{font-size:.73rem;color:#91899f}}
h3{{font-size:1rem;line-height:1.5;margin:13px 0 9px}}h3 a{{color:#f5f1fa;text-decoration:none}}h3 a:hover{{color:#c994ff}}
.veille-source{{font-size:.75rem;color:#938ba0;line-height:1.5;margin:0 0 10px}}.veille-source a{{color:#c18bff;text-underline-offset:3px}}
.veille-summary{{font-size:.87rem;line-height:1.7;color:#c8c1d2;margin:0 0 15px}}
.veille-actions{{margin-top:auto}}.veille-actions a{{display:inline-block;color:#c18bff;text-decoration:none;font-size:.83rem;font-weight:850;border:1px solid #453153;padding:8px 11px;border-radius:9px}}
.veille-actions a:hover{{background:#20162c}}
.empty{{color:#c8c1d2;min-height:auto}}.bottom{{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;margin:16px 0}}
#result-count{{font-size:.8rem;color:#9d95aa}}.footer{{font-size:.72rem;color:#80788e;text-align:center;margin:16px 0 4px}}
@media(max-width:650px){{body{{padding:10px}}.toolbar{{grid-template-columns:1fr}}.hero{{padding:17px}}.veille-card{{padding:16px}}}}
</style>
</head>
<body><main class="wrap">
<header class="hero">
<div class="eyebrow">Veille technologique · BTS SIO SISR</div>
<h1>L’intelligence artificielle au service de la supervision et de la détection des anomalies réseau</h1>
<p class="lead">Articles récents en français sur la supervision intelligente, l’analyse du trafic, la détection d’anomalies, l’observabilité, l’AIOps et la cybersécurité. Recherche, filtres thématiques et accès direct aux sources.</p>
<div class="pills"><span class="pill">{len(items)} articles</span><span class="pill">Dernière mise à jour : {generated}</span><span class="pill">RSS français · Google Actualités</span></div>
</header>
<div class="toolbar" role="search" aria-label="Recherche dans la veille">
<input id="search" type="search" placeholder="Rechercher un article, une source, un mot-clé…" aria-label="Rechercher">
<select id="category" aria-label="Filtrer par thème"><option value="all">Tous les thèmes</option><option>Supervision</option><option>AIOps</option><option>Cybersécurité</option><option>Réseau</option><option>IA</option></select>
<button id="reset" type="button">Réinitialiser</button>
</div>
<section id="article-grid" class="grid" aria-label="Articles de veille">{content}</section>
<div class="bottom"><span id="result-count" aria-live="polite">Articles affichés</span><button id="more" class="more" type="button">Afficher plus</button></div>
<p class="footer">Chaque carte contient un résumé et un lien vers l’article original. Les nouvelles publications sont récupérées par GitHub Actions selon son calendrier.</p>
</main>
<script>
(function() {{
 const cards = Array.from(document.querySelectorAll(".veille-card"));
 const search = document.getElementById("search");
 const category = document.getElementById("category");
 const reset = document.getElementById("reset");
 const more = document.getElementById("more");
 const count = document.getElementById("result-count");
 let visibleLimit = 6;
 function update() {{
   const term = search.value.trim().toLowerCase();
   const selected = category.value;
   const filtered = cards.filter(card => {{
     const text = (card.dataset.search || card.innerText).toLowerCase();
     return (!term || text.includes(term)) && (selected === "all" || card.dataset.topic === selected);
   }});
   cards.forEach(card => card.hidden = true);
   filtered.slice(0, visibleLimit).forEach(card => card.hidden = false);
   count.textContent = filtered.length + " article(s) trouvé(s) · " + Math.min(filtered.length, visibleLimit) + " affiché(s)";
   more.hidden = filtered.length <= visibleLimit;
 }}
 search.addEventListener("input", () => {{visibleLimit=6;update();}});
 category.addEventListener("change", () => {{visibleLimit=6;update();}});
 reset.addEventListener("click", () => {{search.value="";category.value="all";visibleLimit=6;update();search.focus();}});
 more.addEventListener("click", () => {{visibleLimit += 6;update();}});
 update();
}})();
</script>
</body></html>"""
    with open("veille.html", "w", encoding="utf-8") as file:
        file.write(page)
    print(f"veille.html généré : {len(items)} articles français (maximum {MAX_ITEMS})")

if __name__ == "__main__":
    main()
