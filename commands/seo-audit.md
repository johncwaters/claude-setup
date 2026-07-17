# SEO Audit

Comprehensive SEO audit for a URL or full site. Deterministic extraction (curl + Python), parallel page fetches, scored report + prioritized action plan.

## Usage

```
/seo-audit <url>
/seo-audit <url> --mode=page|technical|schema|geo|content
/seo-audit <url> --pages=20
/seo-audit <url> --no-cwv
/seo-audit <url> --no-agents
/seo-audit <url> --keep-tmp
```

Trigger phrases: "audit my site", "SEO check", "AI search readiness", "schema markup", "robots.txt", "llms.txt".

## Constraints (evidence-based, do not skip)

1. **WebFetch is unreliable for `<head>` extraction.** The summarizer model regularly reports `MISSING` for tags that are present (title, description, canonical, OG, Twitter, viewport, charset, lang). Always use curl + the parser below for HTML signals. WebFetch is fine for XML sitemap content and llms.txt.
2. **Minified HTML defeats Grep.** Single-line bundles trigger `[Omitted long matching line]`. Use the Python parser, not `Grep`/`rg`, for HTML extraction.
3. **Tmp paths must be Windows-safe.** Use `.omc/seo/tmp/` inside the working dir, never `/tmp/`.

## Workflow

### Step 0 — Setup

```
mkdir -p .omc/seo/tmp
```

Write the parser script (below) to `.omc/seo/tmp/parse.py`.

### Step 1 — Discover URLs

1. Fetch `robots.txt`. Extract every `Sitemap:` directive and AI-crawler rule. Abort if `*` is fully disallowed.
2. Follow each `Sitemap:` URL via WebFetch. If it's a `<sitemapindex>`, recurse into each child `<loc>`. Cap recursion at depth 2.
3. Fetch `llms.txt` and `llms-full.txt` at root. Record 200/404 for the GEO score.
4. Build the page list:
   - `--mode=page` → just the input URL.
   - Else: homepage + up to `--pages-1` URLs from the sitemap, preferring path-prefix diversity (one per `/blog/`, `/shop/`, `/docs/`).
   - Sitemap empty/missing → fall back to scraping internal `<a>` from homepage HTML, depth=1.
5. **Synthetic-404 probe.** For each anchor href like `/#pricing`, also `HEAD` the path-form (`/pricing`). Record any 404s as High-priority issues.

### Step 2 — Fetch HTML + headers (parallel)

For every URL in the page list, run in parallel:

```bash
curl -sS -L -A "Mozilla/5.0 (compatible; SEOAudit/1.0)" --max-time 30 \
  -o .omc/seo/tmp/<slug>.html \
  -w "<slug> %{http_code} %{size_download}\n" \
  "<url>"

curl -sS -I -L -A "Mozilla/5.0" --max-time 20 "<url>" \
  > .omc/seo/tmp/<slug>.headers.txt
```

Slug = path with `/` → `-` (`/` → `home`, `/blog/foo` → `blog-foo`).

Capture headers per URL — edge providers (Netlify, Cloudflare) can vary headers per route.

### Step 3 — Parse

```bash
python .omc/seo/tmp/parse.py
```

Outputs JSON of per-page signals. Cross-reference with `.headers.txt` files for security headers.

### Step 4 — CWV (optional)

If chrome-devtools-mcp is active and `--no-cwv` not set: navigate to homepage + one representative content page, capture LCP/INP/CLS + mobile screenshot.

If unavailable: CWV scores as `N/A` and the score is renormalized over the remaining weights. **Never** estimate CWV from HTML — only flag risk factors (render-blocking fonts, missing image dimensions, missing `fetchpriority` on hero).

### Step 5 — Specialist analysis

If `--no-agents` not set, dispatch `oh-my-claudecode:executor` per category in parallel, passing the parsed JSON + headers. Each returns `{score, issues[], wins[]}`. Otherwise inline.

**On-Page** — title 50–60 chars, description 150–160 chars, exactly one H1, canonical self-referencing or correct, OG (title/desc/image ≥1200×630/url), Twitter card, word count vs page-type minimum (homepage 300+, article 800+, product 200+, landing 500+).

**Technical** — HTTPS enforced, security headers (CSP, HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy), mobile viewport, no JS-rendered title/canonical/JSON-LD/robots/description (Dec 2025 Google clarification: these must be in initial HTML; non-200 pages don't run JS at all), redirect chains ≤1 hop, sitemap `<lastmod>` populated, IndexNow support.

**Schema (JSON-LD)** — detect via parser; suggest missing per page type: `Organization` + `WebSite` (sitewide), `BlogPosting` + `BreadcrumbList` (posts), `Product` + `Offer` + `AggregateRating` (commerce), `SoftwareApplication` (SaaS), `LocalBusiness`, `VideoObject`, `Event`. Output ready-to-paste JSON-LD for top 3 gaps. **Never recommend**: `HowTo` (deprecated 2023-09), `FAQ` (restricted to gov/health 2023-08), `SpecialAnnouncement` (deprecated 2025-07).

**Content / E-E-A-T** — author bio + credentials linked from `BlogPosting.author`, visible publish + last-updated dates, citations to authoritative sources, thin content per type minimum, readability estimate from word/sentence ratios.

**GEO / AI search** — llms.txt + llms-full.txt presence; AI-crawler rules intentional. Distinguish: `Google-Extended` blocks Gemini training but **not** Google Search; `GPTBot` blocks OpenAI training but **not** ChatGPT browse (`ChatGPT-User`). Citability: clear claims, definitions, structured data, author attribution. `Organization.sameAs` to authoritative profiles.

**Images** — count, missing alt, missing width/height (CLS), `loading="lazy"` below fold, `fetchpriority="high"` on hero. Caveat in report: HTML-only audit cannot see CSS backgrounds or inline SVG.

### Step 6 — Score

| Category | Weight |
|----------|--------|
| Technical | 22% |
| Content | 23% |
| On-Page | 20% |
| Schema | 10% |
| Performance (CWV) | 10% |
| AI Search (GEO) | 10% |
| Images | 5% |

If any category is `N/A`, renormalize over the remaining weights.

### Step 7 — Report

Write to `.omc/seo/`:

- `<YYYY-MM-DD>-<domain>-audit.md` — exec summary (score, top 5 critical/high, top 5 quick wins), per-page snapshot table, per-category breakdown, ready-to-paste JSON-LD, synthetic-404 list, caveats.
- `<YYYY-MM-DD>-<domain>-action-plan.md` — Critical / High (≤2 weeks) / Medium (≤1 month) / Low buckets. Each item: what + why + concrete fix (file path or HTML snippet) + effort (S/M/L) + impact (low/med/high). End with suggested order.

### Step 8 — Cleanup + finish

Unless `--keep-tmp`, delete `.omc/seo/tmp/`. Print: score, top 3 issues, both report paths.

## Parser script

Write to `.omc/seo/tmp/parse.py` at the start of every run. Edit only `FILES` to point at the slugs you saved.

```python
import re, json, os

FILES = {
    # "slug": ".omc/seo/tmp/<slug>.html"
}

def extract(html):
    def find(p, f=re.I|re.S):
        m = re.search(p, html, f); return m.group(1).strip() if m else None
    def findall(p, f=re.I|re.S):
        return re.findall(p, html, f)

    title = find(r"<title[^>]*>([^<]*)</title>")
    desc = find(r'<meta\s+name=["\']description["\']\s+content=["\']([^"\']*)["\']') \
        or find(r'<meta\s+content=["\']([^"\']*)["\']\s+name=["\']description["\']')
    canonical = find(r'<link\s+rel=["\']canonical["\']\s+href=["\']([^"\']*)["\']')
    robots = find(r'<meta\s+name=["\']robots["\']\s+content=["\']([^"\']*)["\']')
    og_title = find(r'<meta\s+property=["\']og:title["\']\s+content=["\']([^"\']*)["\']')
    og_desc = find(r'<meta\s+property=["\']og:description["\']\s+content=["\']([^"\']*)["\']')
    og_image = find(r'<meta\s+property=["\']og:image["\']\s+content=["\']([^"\']*)["\']')
    og_type = find(r'<meta\s+property=["\']og:type["\']\s+content=["\']([^"\']*)["\']')
    twitter_card = find(r'<meta\s+name=["\']twitter:card["\']\s+content=["\']([^"\']*)["\']')
    viewport = find(r'<meta\s+name=["\']viewport["\']\s+content=["\']([^"\']*)["\']')
    charset = find(r'<meta\s+charset=["\']?([^"\'\s>/]+)')
    lang = find(r'<html[^>]*\blang=["\']([^"\']+)["\']')
    hreflang = findall(r'<link[^>]*rel=["\']alternate["\'][^>]*hreflang=["\']([^"\']+)["\']')
    h1s = findall(r'<h1[^>]*>(.*?)</h1>')
    h2s = findall(r'<h2[^>]*>(.*?)</h2>')
    h3s = findall(r'<h3[^>]*>(.*?)</h3>')
    imgs = findall(r'<img\b[^>]*>')
    img_no_alt = [i for i in imgs if not re.search(r'\balt=', i, re.I)]
    img_no_dim = [i for i in imgs if not (re.search(r'\bwidth=', i, re.I) and re.search(r'\bheight=', i, re.I))]
    img_lazy = [i for i in imgs if re.search(r'loading=["\']lazy["\']', i, re.I)]
    img_priority = [i for i in imgs if re.search(r'fetchpriority=["\']high["\']', i, re.I)]
    jsonld = findall(r'<script[^>]*type=["\']application/ld\+json["\'][^>]*>(.*?)</script>')
    a_internal = len(findall(r'<a\b[^>]*href=["\'](/[^"\'#][^"\']*|/)["\']'))
    a_anchor = len(findall(r'<a\b[^>]*href=["\']/?#[^"\']*["\']'))
    a_external = len(findall(r'<a\b[^>]*href=["\']https?://[^"\']+["\']'))
    body = re.sub(r'<script[^>]*>.*?</script>', ' ', html, flags=re.S|re.I)
    body = re.sub(r'<style[^>]*>.*?</style>', ' ', body, flags=re.S|re.I)
    word_count = len(re.findall(r'\w+', re.sub(r'<[^>]+>', ' ', body)))

    def clean(t):
        return re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', '', t)).strip() if t else None

    def jsonld_type(j):
        m = re.search(r'"@type"\s*:\s*"([^"]+)"', j)
        return m.group(1) if m else "?"

    return {
        "title": title, "title_len": len(title) if title else 0,
        "description": desc, "description_len": len(desc) if desc else 0,
        "canonical": canonical, "robots": robots,
        "og": {"title": og_title, "description": og_desc, "image": og_image, "type": og_type},
        "twitter_card": twitter_card,
        "viewport": viewport, "charset": charset, "lang": lang, "hreflang": hreflang,
        "h1_count": len(h1s), "h1_texts": [clean(x) for x in h1s],
        "h2_count": len(h2s), "h2_texts": [clean(x) for x in h2s][:20],
        "h3_count": len(h3s), "h3_texts": [clean(x) for x in h3s][:20],
        "img_count": len(imgs),
        "img_missing_alt": len(img_no_alt),
        "img_missing_dim": len(img_no_dim),
        "img_lazy": len(img_lazy),
        "img_fetchpriority_high": len(img_priority),
        "jsonld_count": len(jsonld),
        "jsonld_types": [jsonld_type(j) for j in jsonld],
        "links_internal": a_internal,
        "links_anchor": a_anchor,
        "links_external": a_external,
        "word_count": word_count,
    }

results = {}
for name, path in FILES.items():
    if os.path.exists(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            results[name] = extract(f.read())
    else:
        results[name] = {"error": "missing"}

print(json.dumps(results, indent=2, ensure_ascii=False))
```

## Error Handling

| Scenario | Action |
|---|---|
| `robots.txt` blocks `*` | Abort with clear error; recommend allowlisting search bots. |
| JS-rendered (parser → empty title/H1 + word_count<50) | Flag CSR risk. Recommend SSR/prerender. Note results are incomplete. |
| Sitemap empty/missing | Fall back to homepage `<a>` scrape, depth=1, breadth=`--pages`. |
| chrome-devtools-mcp unavailable | CWV = N/A. Renormalize. Note in report. |
| WebFetch returns "MISSING" for tags you suspect exist | Distrust. Verify with curl + parser. |

## Flags

- `--mode=full|page|technical|schema|geo|content` — restrict scope (default `full`)
- `--pages=N` — crawl cap (default 10, max 100)
- `--no-cwv` — skip browser, HTML-only
- `--no-agents` — inline, no executor dispatch
- `--out=<path>` — override report directory
- `--keep-tmp` — keep raw HTML for inspection
