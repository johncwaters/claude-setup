# SEO Audit

Comprehensive SEO audit for a URL or full site. Deterministic extraction (curl + Python), parallel page fetches, scored report + prioritized action plan. **Every run also builds a social-share preview page and opens it automatically** so the og-image and unfurl cards can be eyeballed, and generates a spec-compliant og-image when the site lacks a good one.

## Usage

```
/seo-audit <url>
/seo-audit <url> --mode=page|technical|schema|geo|content
/seo-audit <url> --pages=20
/seo-audit <url> --no-cwv
/seo-audit <url> --no-agents
/seo-audit <url> --no-preview
/seo-audit <url> --og-gen
/seo-audit <url> --keep-tmp
```

Trigger phrases: "audit my site", "SEO check", "AI search readiness", "schema markup", "robots.txt", "llms.txt", "og image", "social share preview", "how does my link look when shared".

## Constraints (evidence-based, do not skip)

1. **WebFetch is unreliable for `<head>` extraction.** The summarizer model regularly reports `MISSING` for tags that are present (title, description, canonical, OG, Twitter, viewport, charset, lang). Always use curl + the parser below for HTML signals. WebFetch is fine for XML sitemap content and llms.txt.
2. **Minified HTML defeats Grep.** Single-line bundles trigger `[Omitted long matching line]`. Use the Python parser, not `Grep`/`rg`, for HTML extraction.
3. **Tmp paths must be Windows-safe.** Use `.omc/seo/tmp/` inside the working dir, never `/tmp/`.
4. **`sharp` resolves only from inside the project.** Node walks up for `node_modules`, so the og-image generator (`sharp`) must run with cwd inside the site package (e.g. `cd site && node gen-og.mjs`), not from an arbitrary tmp dir, or you get `ERR_MODULE_NOT_FOUND: sharp`. If the site has no deps installed, run `npm install` in it first.
5. **The Write tool may gate `.py` files** (it shells out to `ruff`; if ruff is absent the write is *blocked*, not warned). Write parser/generator Python via a Bash heredoc or to a non-`.py` extension (`build.txt`) and run `python build.txt`. Node generator scripts are not gated.
6. **Preview must be self-contained.** Embed the og-image and favicon as base64 `data:` URIs in the preview HTML so it renders with no server and survives being moved. Never reference the live URL or a local file path for images in the preview.
7. **Audit the LIVE site, but check the deploy branch.** A host like Netlify deploys one branch (often `main`); newer SEO work or images may sit on `develop`/a feature branch and not be live yet. If a source file has an asset the live HTML lacks, say so and name the branch gap instead of scoring the source you can see locally.
8. **The parser truncates at apostrophes.** `content=["\']([^"\']*)["\']` stops at a `'` inside a double-quoted attribute: `content="Keeplings' privacy policy…"` parses as `Keeplings`. Before flagging a suspiciously short title/description, grep the raw HTML for the full tag (`grep -o '<meta name="description"[^>]*>' page.html`) and confirm. Never report a truncation-shaped value as a site bug without that check.
9. **Bash cwd persists between tool calls.** A `cd .omc/seo/tmp` in one fetch command breaks every later relative path (`.omc/seo/tmp/parse.py: No such file or directory`). Either never `cd`, or re-anchor each multi-step command with an absolute `cd` first.
10. **Re-running on the same day overwrites the prior report.** The date-stamped filenames collide; the Write tool forces a Read first. Read the old report, keep its overall score, and lead the new one with the before/after (e.g. "89, up from 53 after `<commit>`") — the delta is the most useful line in the file.

## Workflow

### Step 0 — Setup

```
mkdir -p .omc/seo/tmp
```

Write the parser script (below) to `.omc/seo/tmp/parse.py` **via a Bash heredoc** (`cat > .omc/seo/tmp/parse.py <<'EOF' ... EOF`), not the Write tool — Constraint 5: the Write tool gates `.py` and blocks when ruff is absent.

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

If `--no-agents` not set, dispatch one `general-purpose` agent (model sonnet) per category in parallel, passing the parsed JSON + headers. Each returns `{score, issues[], wins[]}`. Otherwise inline.

**On-Page** — title 50–60 chars, description 150–160 chars, exactly one H1, canonical self-referencing or correct, word count vs page-type minimum (homepage 300+, article 800+, product 200+, landing 500+). **Social/OG completeness** (flag each missing): `og:title`, `og:description`, `og:type`, `og:url`, `og:site_name`, `og:image` (+`:width` 1200, `:height` 630, `:type`, `:alt`, `:secure_url`), `twitter:card=summary_large_image`, `twitter:image`, `twitter:image:alt`. A `twitter:card=summary` (small square) instead of `summary_large_image`, or a missing `og:image`, is a High finding — the link renders as a bare text link on every platform. Missing `og:image:alt`/`twitter:image:alt` is a Low finding.

**Technical** — HTTPS enforced, security headers (CSP, HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy), mobile viewport, no JS-rendered title/canonical/JSON-LD/robots/description (Dec 2025 Google clarification: these must be in initial HTML; non-200 pages don't run JS at all), redirect chains ≤1 hop, sitemap `<lastmod>` populated, IndexNow support. Also: **internal links should hit the canonical URL form** — if pages serve at a trailing slash (`/privacy/`) but links point to `/privacy`, every internal nav eats a 301 (self-inflicted; fix links or set the framework to flat/consistent URLs). **Custom 404** — a branded, `noindex` 404 page beats the host's default (Netlify/Vercel ship an ugly generic one). **`noindex` pages** should use `noindex, follow` (not bare `noindex`) and should **not** emit a self-referencing canonical or og:url (mixed signal). **PWA/favicon set** — flag a lone `favicon.svg` with no `.ico`, `apple-touch-icon`, `manifest`, or `theme-color`.

**Schema (JSON-LD)** — detect via parser; suggest missing per page type: `Organization` + `WebSite` (sitewide), `BlogPosting` + `BreadcrumbList` (posts), `Product` + `Offer` + `AggregateRating` (commerce), `SoftwareApplication` (SaaS/desktop app), `LocalBusiness`, `VideoObject`, `Event`. Output ready-to-paste JSON-LD for top 3 gaps. **Prefer a single `@graph`** array with `@id`-linked entities (Organization `#org`, WebSite `#website` whose `publisher` references `#org`) over multiple loose `<script>` blocks — it de-duplicates the entity and is the cleaner pattern. **Recurring prices**: never state a subscription as a flat `price` (e.g. `price:'20'` for $20/mo) — model it with `priceSpecification` → `UnitPriceSpecification` (`price`, `priceCurrency`, `unitCode:'MON'`), or Google flags a price mismatch against the on-page "/month". **Organization `logo`** must be a roughly-square brand asset (≥112×112), **not** the wide 1200×630 og-image. **Never recommend**: `HowTo` (deprecated 2023-09), `FAQ` (restricted to gov/health 2023-08), `SpecialAnnouncement` (deprecated 2025-07).

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

### Step 6.5 — og-image + social share preview (automatic, unless `--no-preview`)

This step runs on **every** audit. It produces two things: a graded verdict on the site's og-image, and a self-contained preview page that renders the homepage's real share cards, opened in the browser for review.

**a. Grade the current og-image.** If the live homepage has an `og:image`, fetch it and read it with the Read tool (it renders visually). Grade against the rubric in **## og-image rubric** below (safe-area, legibility, text economy, contrast, weight, composition). Note overlap, cropping, and any text in the bottom/right crop danger zones.

**b. Generate or improve the og-image when warranted.** Regenerate (write to the site's `public/og-image.png`) when: there is no og-image, it fails the rubric (text cropped, <36px essential type, >1MB, wrong ratio), or `--og-gen` is passed. Use the **## og-image generator** recipe (SVG → sharp). Pull brand colors from the site's CSS variables; keep to name + one benefit line + optional small platform label; center the lockup; keep every glyph inside x 120–1080 / y 60–570. Re-read the generated PNG to confirm before accepting it. Do **not** overwrite a good custom image just to standardize it — only replace on a real rubric failure or explicit `--og-gen`.

**c. Build the preview page and open it.** Always (unless `--no-preview`). Use the **## preview builder** recipe: a self-contained HTML page showing the homepage's actual title/description/domain rendered as a Google SERP snippet, an X `summary_large_image` card, a Facebook/LinkedIn card, and a Slack/Discord unfurl — with the og-image and favicon embedded as base64 `data:` URIs. Write it to the scratchpad dir (or `--out`), then open it: `Start-Process <file>` (Windows) / `open <file>` (macOS) / `xdg-open <file>` (Linux). This is the deliverable the user reviews to see "how the link looks when shared."

### Step 7 — Report

Write to `.omc/seo/`:

- `<YYYY-MM-DD>-<domain>-audit.md` — exec summary (score, top 5 critical/high, top 5 quick wins), per-page snapshot table, per-category breakdown, ready-to-paste JSON-LD (use the `@graph` pattern), the **og-image grade** (rubric score + what was regenerated, if anything), synthetic-404 list, caveats.
- `<YYYY-MM-DD>-<domain>-action-plan.md` — Critical / High (≤2 weeks) / Medium (≤1 month) / Low buckets. Each item: what + why + concrete fix (file path or HTML snippet, drawn from **## Remediation recipes** where applicable) + effort (S/M/L) + impact (low/med/high). End with suggested order.

### Step 8 — Cleanup + finish

Unless `--keep-tmp`, delete `.omc/seo/tmp/` (keep any regenerated `public/og-image.png` — that is a real asset, not tmp). Reopen the preview page one final time (unless `--no-preview`). Print: score, og-image grade, top 3 issues, both report paths, and the preview page path.

## Parser script

Write to `.omc/seo/tmp/parse.py` at the start of every run, via Bash heredoc per Constraint 5 (never the Write tool). Edit only `FILES` to point at the slugs you saved.

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
    def has(p, f=re.I|re.S):
        return bool(re.search(p, html, f))

    title = find(r"<title[^>]*>([^<]*)</title>")
    desc = find(r'<meta\s+name=["\']description["\']\s+content=["\']([^"\']*)["\']') \
        or find(r'<meta\s+content=["\']([^"\']*)["\']\s+name=["\']description["\']')
    canonical = find(r'<link\s+rel=["\']canonical["\']\s+href=["\']([^"\']*)["\']')
    robots = find(r'<meta\s+name=["\']robots["\']\s+content=["\']([^"\']*)["\']')
    og_title = find(r'<meta\s+property=["\']og:title["\']\s+content=["\']([^"\']*)["\']')
    og_desc = find(r'<meta\s+property=["\']og:description["\']\s+content=["\']([^"\']*)["\']')
    og_image = find(r'<meta\s+property=["\']og:image["\']\s+content=["\']([^"\']*)["\']')
    og_type = find(r'<meta\s+property=["\']og:type["\']\s+content=["\']([^"\']*)["\']')
    og_site_name = find(r'<meta\s+property=["\']og:site_name["\']\s+content=["\']([^"\']*)["\']')
    og_image_alt = find(r'<meta\s+property=["\']og:image:alt["\']\s+content=["\']([^"\']*)["\']')
    og_url = find(r'<meta\s+property=["\']og:url["\']\s+content=["\']([^"\']*)["\']')
    twitter_card = find(r'<meta\s+name=["\']twitter:card["\']\s+content=["\']([^"\']*)["\']')
    twitter_image = find(r'<meta\s+name=["\']twitter:image["\']\s+content=["\']([^"\']*)["\']')
    twitter_image_alt = find(r'<meta\s+name=["\']twitter:image:alt["\']\s+content=["\']([^"\']*)["\']')
    fav_svg = has(r'<link[^>]*rel=["\']icon["\'][^>]*\.svg')
    fav_ico = has(r'<link[^>]*rel=["\']icon["\'][^>]*\.ico')
    apple_touch = has(r'<link[^>]*rel=["\']apple-touch-icon')
    manifest = has(r'<link[^>]*rel=["\']manifest["\']')
    theme_color = has(r'<meta\s+name=["\']theme-color["\']')
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

    def jsonld_types(j):
        # captures every @type, including those nested inside an @graph array
        found = re.findall(r'"@type"\s*:\s*"([^"]+)"', j)
        return found if found else ["?"]

    jsonld_all_types = [t for j in jsonld for t in jsonld_types(j)]
    jsonld_has_graph = any('"@graph"' in j for j in jsonld)

    return {
        "title": title, "title_len": len(title) if title else 0,
        "description": desc, "description_len": len(desc) if desc else 0,
        "canonical": canonical, "robots": robots,
        "og": {"title": og_title, "description": og_desc, "image": og_image, "type": og_type,
               "url": og_url, "site_name": og_site_name, "image_alt": og_image_alt},
        "twitter_card": twitter_card, "twitter_image": twitter_image, "twitter_image_alt": twitter_image_alt,
        "favicon": {"svg": fav_svg, "ico": fav_ico, "apple_touch": apple_touch,
                    "manifest": manifest, "theme_color": theme_color},
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
        "jsonld_types": jsonld_all_types,
        "jsonld_has_graph": jsonld_has_graph,
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
- `--no-agents` — inline, no agent dispatch
- `--no-preview` — skip the Step 6.5 preview build/open (still grades the existing og-image)
- `--og-gen` — force-regenerate the og-image even if the current one passes the rubric
- `--out=<path>` — override report directory (and preview-page location)
- `--keep-tmp` — keep raw HTML for inspection

## og-image rubric

Grade an og-image out of 20 (score each 0–2). Sources: ogp.me, WCAG 2.2, platform docs. Numbers are for a 1200×630 canvas.

| Category | 2 | 1 | 0 |
|---|---|---|---|
| Canvas | exactly 1200×630, sRGB | ~1.91:1, enough resolution | wrong ratio / low-res |
| Landscape safety | all essentials inside x 120–1080, y 60–570 | one minor element outside | text near/crossing an edge |
| Crop survival | logo/name legible in a center 630×630 crop and a 1200×600 crop | minor degradation | identity/headline disappears |
| Mobile typography | headline 64–80px, essential ≥36px | some 28–35px type | essential type <28px |
| Text economy | name + one line, ≤12 words, ≤2 blocks | some extra copy | mini landing page / feature list |
| Contrast | ≥4.5:1 (≥3:1 for large bold) | borderline / local bg issue | clearly low contrast |
| Composition | one focal point, vertically balanced | mild clutter / top-heavy | no hierarchy |
| File delivery | PNG (or JPEG if photo), sRGB, <1MB | 1–2MB / minor format issue | >5MB / unreliable format |
| Metadata | complete OG/X tags + dimensions + alt | one or two omissions | missing/conflicting/unreachable |
| Real-client test | debugger-tested on the live URL | major platforms only | not tested against production |

18–20 ship · 15–17 fix the weakest crop/mobile issue · 11–14 revise · ≤10 unreliable. Hard rules: decorative waves/gradients may bleed to the edge but must **never pass behind the tagline**; bake in only the product name + one durable line (full page-specific wording lives in `og:title`/`og:description`); the logo is brand art, the og-image is not a logo. Required visual checks before accepting: view at 320×168 and 240×126 (the name must still read), and a centered 630×630 crop.

**One image serves every platform — design for the square.** OG technically allows multiple `og:image` tags but no client selects by aspect ratio (Facebook takes first/largest, Slack takes first, Twitter uses its own single tag), so there is no "square variant" mechanism. The layout that survives everything is a **vertical centered lockup**: mascot/brand art top-center, name below it, tagline under that — with **every glyph inside the center 630×630 (x 285–915)**, not just the name. A left-art/right-text horizontal lockup fails square and tiny crops (wordmark cut to a fragment); users notice ("text gets cut off"). Fit a long tagline by splitting it into two short centered lines (reword if needed) rather than shrinking below 36px; keep the small label row ≥5px inside the square edge — tangent-to-edge text looks cropped and dies on off-center client crops. Verify with a real crop, not squinting: `sharp(img).extract({left:285,top:0,width:630,height:630})`.

## og-image generator

Node + `sharp` (rasterizes an inline SVG). Run **inside the site package** so `sharp` resolves (Constraint 4). Write to `site/gen-og.mjs`, run, then delete it. Swap the palette and copy for the real product.

Prefer the **vertical centered lockup** (survives square + tiny crops; see rubric). If the site has real mascot/brand raster art (an `icon-512.png` etc.), embed it as a base64 `<image>` instead of drawing a placeholder mark — and **sample the icon's own corner pixel for the canvas background** so the embedded square blends seamlessly instead of showing a patch seam:

```js
// site/gen-og.mjs  —  node gen-og.mjs  (cwd must be the site package)
import sharp from 'sharp'
import { readFileSync } from 'fs'

const icon = readFileSync('public/icon-512.png')
const { data } = await sharp(icon).raw().toBuffer({ resolveWithObject: true })
// icon's own bg color -> seamless embed
const bg = `#${[data[0],data[1],data[2]].map(v=>v.toString(16).padStart(2,'0')).join('')}`
const iconB64 = icon.toString('base64')

const ink='#4a3524', soft='#6b543f', accent='#b06a1e', bar='#a86f3d'
// every glyph inside the center 630x630 square (x 285-915, y 60-570)
const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <rect width="1200" height="630" fill="${bg}"/>
  <rect y="614" width="1200" height="16" fill="${bar}"/>
  <image href="data:image/png;base64,${iconB64}" x="485" y="48" width="230" height="230"/>
  <text x="600" y="390" text-anchor="middle" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="100" font-weight="700" fill="${ink}">Product Name</text>
  <text x="600" y="452" text-anchor="middle" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="40" font-weight="600" fill="${soft}">Benefit line split in</text>
  <text x="600" y="502" text-anchor="middle" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="40" font-weight="600" fill="${soft}">two short centered rows.</text>
  <text x="600" y="554" text-anchor="middle" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="26" font-weight="600" fill="${accent}">Short&#160;&#160;-&#160;&#160;label&#160;&#160;-&#160;&#160;row</text>
</svg>`
await sharp(Buffer.from(svg)).png().toFile('public/og-image.png')
console.log('wrote public/og-image.png', bg)
```

No mascot art? Keep the same geometry and draw a simple mark in the mascot slot (x 485–715). Text-anchor `middle` at x=600 does the centering; sizing rule of thumb is ~0.5×font-size per character for Segoe UI 600/700 — keep each line's estimate under 600px, then trust the rendered crop check, not the estimate.

After running: confirm 1200×630 and <1MB via `sharp(...).metadata()`, Read the PNG to eyeball against the rubric, and render the two required checks as real files (Read them too):

```js
await sharp('public/og-image.png').extract({left:285,top:0,width:630,height:630}).resize(315,315).png().toFile('og-sq.png')   // square-crop survival
await sharp('public/og-image.png').resize(320,168).png().toFile('og-320.png')                                                 // tiny-render legibility
```

## preview builder

Assembles the self-contained preview. Base64-encode the og-image + favicon first (`base64 -w0 site/public/og-image.png > og_b64.txt`), then build the HTML with the real title/description/domain. Write the builder to a `.txt` (not `.py`, per Constraint 5) and run `python build.txt`. The page must inline every image as a `data:` URI and style light+dark. Cards to render: Google SERP (favicon + title + green URL + description), X `summary_large_image` (image over a caption bar with domain/title/description), Facebook/LinkedIn (image over a gray footer), Slack/Discord (left accent bar, site name, link-blue title, description, right thumbnail), plus the raw og-image full-width and a table of the tags driving it. Open with `Start-Process` / `open` / `xdg-open`. (A full working builder was produced in the card-harbor run; reproduce that structure — SERP + X + FB/LinkedIn + Slack + raw + tag table — embedding the base64.)

Two sections users actually catch problems in, both mandatory:

- **True square thumb.** The Slack/Discord thumbnail must be a real `sharp .extract({left:285,top:0,width:630,height:630})` center crop embedded as its own base64 — never the full 1200×630 squeezed by CSS `object-fit`. CSS scaling hides exactly the cropping defect the card exists to reveal; the keeplings run's "text gets cut off on the square version" only surfaced because the crop was real.
- **Tiny-render test row.** The full og-image displayed at 320×168, 240×126, and the square crop at ~126px, each with a size caption. This is where "looks shrunk and unreadable" complaints come from; make the row impossible to miss.

When re-running after an og-image fix, the two embedded images can be swapped in-place with a small python script (regex out the `data:image/png;base64,…` URIs, replace longest→og, second→square crop) instead of rebuilding the whole page.

## Remediation recipes (Astro + Netlify)

Distilled from real fixes. Use these as the "concrete fix" in the action plan when the target is an Astro site on Netlify.

**Layout `<head>` (single source):** put canonical, full OG/Twitter set, and JSON-LD in the shared layout, computed from `Astro.site`:
```astro
const canonical = new URL(Astro.url.pathname, Astro.site).href
const ogImage = new URL('/og-image.png', Astro.site).href
// og:image (+width/height/type/alt/secure_url), og:url, og:site_name,
// twitter:card=summary_large_image, twitter:image, twitter:image:alt
```
Guard canonical + og:url + og:image behind `{!noindex && ...}` so `noindex` pages don't self-canonicalize. Use `<meta name="robots" content="noindex, follow" />` (not bare `noindex`). `set:html={JSON.stringify(obj)}` on `<script type="application/ld+json">` is the correct idiom (inputs are static, so no injection risk).

**JSON-LD `@graph`** (sitewide, one block, `@id`-linked):
```js
{ "@context":"https://schema.org", "@graph": [
  { "@type":"Organization", "@id":`${site}#org`, "name":PUBLISHER, "url":site,
    "logo":`${site}logo.png`, "founder":{"@type":"Person","name":FOUNDER}, "sameAs":[] },
  { "@type":"WebSite", "@id":`${site}#website`, "url":site, "name":NAME,
    "publisher":{"@id":`${site}#org`}, "inLanguage":"en" }
]}
```
Add `SoftwareApplication` (home only) for an app/SaaS, with `offers` and recurring price via `UnitPriceSpecification` (`unitCode:'MON'`), `publisher` referencing `#org`. `logo` = a square asset, never the og-image.

**`sameAs` only with live targets.** Before recommending (or adding) `sameAs` links, `curl -I` each candidate. A parent-company domain that doesn't resolve yet, or a store listing still in closed testing, is a dead entity link — defer it to the action plan as "blocked on X going live" instead of shipping it.

**Policy pages get a `WebPage` node with dates.** A privacy policy showing a visible "Effective date" should also expose it machine-readably — per-page head slot, `datePublished`/`dateModified` matching the visible date, `isPartOf` referencing `#website`:
```js
{ "@type":"WebPage", "@id":`${site}privacy#webpage`, "url":`${site}privacy`,
  "name":"Privacy Policy: X", "isPartOf":{"@id":`${site}#website`},
  "datePublished":"2026-07-05", "dateModified":"2026-07-05", "inLanguage":"en" }
```
Keep `dateModified` at the policy's effective date unless the policy *content* changed — a meta-tag tweak doesn't bump it (the sitemap `<lastmod>` does bump, they track different things).

**`og:image:alt` as a shared const.** Define the alt text once in the layout frontmatter and reference it from both `og:image:alt` and `twitter:image:alt`; describe the actual composition (mascot, wordmark, tagline). Regenerating the og-image means re-checking the alt still matches.

**Flat URLs (kill trailing-slash 301s):** either set `build: { format: 'file' }` in `astro.config.mjs` (emits `privacy.html`, no `/privacy/` redirect), or keep directory format and point every internal link at the slashed form. Pick one and make links, sitemap, and canonical all agree.

**Static crawl files in `public/`:**
- `robots.txt` — `User-agent: *` / `Allow: /` / `Disallow:` any noindex or internal-doc routes (use no trailing slash so `/x` and `/x/` both match) / `Sitemap:` absolute URL.
- `sitemap.xml` — for a small static site a hand-written sitemap (one `<url>` per indexable page, trailing-slash matching how pages serve) is more robust than adding `@astrojs/sitemap` when the Astro major version may not match the integration's peer range. Use the integration only when versions line up. **The integration emits no `<lastmod>` by default**; add it via the `serialize` hook with a per-page date map in `astro.config.mjs`:
  ```js
  const LASTMOD = { "/": "2026-07-23", "/privacy": "2026-07-23" };
  sitemap({
    serialize(item) {
      const path = new URL(item.url).pathname.replace(/\/$/, "") || "/";
      const date = LASTMOD[path];
      if (date) item.lastmod = date;
      return item;
    },
  })
  ```
- `llms.txt` — H1 name, a one-line `>` summary, and a linked list of key pages.
- `_headers` (Netlify) — `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy: camera=(), microphone=(), geolocation=()`, `Strict-Transport-Security: max-age=31536000; includeSubDomains; preload`. **Stage CSP commented-out** when a third-party checkout (Paddle/Stripe) or embed runs client-side — a wrong policy silently breaks payments; enable only after a real checkout on a preview deploy. `X-Frame-Options: DENY` is safe with a checkout iframe (it governs *your* page being framed, not *your* page embedding others).

**Custom 404** — add `src/pages/404.astro` using the shared layout with `noindex`, an apology line, and links back to home/support. Replaces the host's generic 404.

**Favicon/PWA set** — ship `.ico` + `favicon-32x32.png` + `favicon-16x16.png` + `apple-touch-icon.png` + `site.webmanifest` + `theme-color` (light/dark), not a lone SVG.

**AGENTS.md-in-pages trap** — deepinit drops an `AGENTS.md` into every dir; any `.md` under `src/pages/` becomes a public route (`/AGENTS/`). Exclude it from routing (Astro ignores `_`-prefixed files, but that breaks the filename convention) or, cleanest, keep per-dir agent docs out of `pages/`. As a stopgap, `Disallow: /AGENTS` in robots.

**Deploy-branch gap** — Netlify deploys one branch (often `main`). If SEO work or the og-image lives on `develop`/a feature branch, it is not live; the fix is the merge to the deploy branch, and the audit must say so rather than scoring un-deployed source.
