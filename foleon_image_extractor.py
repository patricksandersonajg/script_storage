#!/usr/bin/env python3
"""
Image extractor for Woodruff Sawyer Foleon type sites. To use as a basis for rebuilding them as Core Bedrocc sites.

What it does
- Crawls starting from a given URL (stays within that URL prefix).
- Finds images referenced via HTML, CSS (including nested @import), and JS bundles.
- Strips the `?ext=webp` parameter to prefer the original asset variant when present.
- Skips auto-generated preview files like 16-char IDs with _d/_fb/_o/_tw suffixes.
- De-duplicates by content hash; for same filename, keeps the larger file (prefers higher-resolution) and overwrites smaller ones; keeps original file formats (no conversion).

How to run
- Basic crawl (default max 100 pages):
    python3 script_storage/foleon_image_extractor.py https://www.myexample.com/some/prefix

- With a custom max pages limit (e.g., 200):
    python3 script_storage/foleon_image_extractor.py https://www.myexample.com/some/prefix 200

Output location
- The script creates an output folder next to this script, derived from the URL and prefixed with 'assets_of_', e.g.:
    https://www.mybenefitsnow.com/calix-candidate/home  ->  assets_of_www_mybenefitsnow_com_calix-candidate_home
  Files are saved into: <this_script_dir>/<derived_folder>


Next steps
  There's a Ruby script foleon_image_resizer.rb (I know, this is Python...but Ruby is easier for image manipulation on my mac) which will take the output of this process and resize them to the expected Bedrocc dimensions.

"""

import os
import re
import ssl
import sys
import hashlib
import urllib.parse
import urllib.request
from html.parser import HTMLParser

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/125.0.0.0 Safari/537.36"
)

# The target sites may present certificate chains that fail strict validation in some environments.
CTX = ssl._create_unverified_context()


def fetch(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, context=CTX, timeout=30) as r:
        return r.read(), r.geturl(), r.headers.get("Content-Type", "")


class LinkCSSParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.css_links = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() == "link":
            amap = dict(attrs)
            rel = (amap.get("rel") or "").lower()
            as_attr = (amap.get("as") or "").lower()
            href = amap.get("href")
            # Standard stylesheets
            if "stylesheet" in rel and href:
                self.css_links.append(href)
            # Preloaded styles commonly used by Foleon and similar platforms
            elif "preload" in rel and as_attr == "style" and href:
                self.css_links.append(href)
            # Fallback: any <link> that clearly points to a CSS file
            elif href and href.strip().lower().split("?")[0].endswith(".css"):
                self.css_links.append(href)


def collect_css_urls(home_html: str, base_url: str):
    parser = LinkCSSParser()
    parser.feed(home_html)
    css_hrefs = set(parser.css_links)

    # Also scan inline <style> tags for @import rules
    for m in re.finditer(r"<style[^>]*>(.*?)</style>", home_html, re.I | re.S):
        block = m.group(1)
        for imp in re.findall(r"@import\s+url\(([^)]+)\)|@import\s+['\"]([^'\"]+)['\"]", block):
            u = next((x for x in imp if x), None)
            if u:
                css_hrefs.add(u.strip(' "\''))

    abs_css = set()
    for href in css_hrefs:
        href = (href or "").strip(' "\'')
        if not href:
            continue
        abs_css.add(urllib.parse.urljoin(base_url, href))
    return abs_css


def collect_image_urls_from_html(html: str, base_url: str) -> set[str]:
    urls: set[str] = set()
    # Extract from <img src="...">
    for m in re.finditer(r"<img[^>]+src=\"([^\"]+)\"", html, re.I):
        u = m.group(1).strip()
        if not u:
            continue
        urls.add(urllib.parse.urljoin(base_url, u))
    # Extract from inline style background-image: url(...)
    for m in re.finditer(r"background-image\s*:\s*url\(([^)]+)\)", html, re.I):
        u = m.group(1).strip().strip('"\'')
        if not u or u.startswith('data:'):
            continue
        urls.add(urllib.parse.urljoin(base_url, u))
    # Generic url(...) fallbacks anywhere in HTML
    for m in re.finditer(r"url\(([^)]+)\)", html, re.I):
        u = m.group(1).strip().strip('"\'')
        if not u or u.startswith('data:'):
            continue
        urls.add(urllib.parse.urljoin(base_url, u))

    # Additionally, capture fully-qualified image URLs that may appear inside inline JSON/script blocks
    # (e.g., Foleon embeds), even when not wrapped in CSS url(...)
    raw_img_pattern = re.compile(
        r"https?://[^\s\"'<>]+\.(?:jpg|jpeg|png|gif|webp|svg|avif|bmp|jfif|pjpeg|pjp)(?:\?[^\"'<>\s]*)?",
        re.I,
    )
    for m in raw_img_pattern.finditer(html):
        u = m.group(0)
        if u:
            urls.add(u)

    # Normalize: strip ?ext=webp and keep only likely images
    norm_urls: set[str] = set()
    for u in urls:
        parsed = urllib.parse.urlsplit(u)
        if parsed.query:
            q = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
            q = [(k, v) for (k, v) in q if not (k.lower() == "ext" and v.lower() == "webp")]
            parsed = parsed._replace(query=urllib.parse.urlencode(q))
            u = urllib.parse.urlunsplit(parsed)
        if any(u.lower().split("?")[0].endswith(ext) for ext in (
            ".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".avif", ".bmp", ".jfif", ".pjpeg", ".pjp"
        )):
            norm_urls.add(u)
    return norm_urls


def collect_image_urls_from_css(css_urls: set[str]):
    image_urls: set[str] = set()
    seen_css: set[str] = set()
    queue = list(css_urls)

    css_url_pattern = re.compile(r"url\(([^)]+)\)", re.I)
    import_pattern = re.compile(r"@import\s+(?:url\(([^)]+)\)|['\"]([^'\"]+)['\"])", re.I)

    while queue:
        css_url = queue.pop(0)
        if css_url in seen_css:
            continue
        seen_css.add(css_url)
        try:
            data, final_css_url, _ = fetch(css_url)
        except Exception:
            continue
        text = data.decode("utf-8", errors="ignore")

        # Discover nested @import
        for imp in import_pattern.findall(text):
            u = next((x for x in imp if x), None)
            if u:
                u = u.strip(' "\'')
                absu = urllib.parse.urljoin(final_css_url, u)
                if absu not in seen_css:
                    queue.append(absu)

        # Extract all url(...)
        for m in css_url_pattern.finditer(text):
            raw = (m.group(1) or "").strip().strip('"\'')
            if not raw or raw.startswith("data:"):
                continue

            # Remove ?ext=webp if present
            parsed = urllib.parse.urlsplit(raw)
            if parsed.query:
                q = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
                q = [(k, v) for (k, v) in q if not (k.lower() == "ext" and v.lower() == "webp")]
                parsed = parsed._replace(query=urllib.parse.urlencode(q))
                raw = urllib.parse.urlunsplit(parsed)

            absu = urllib.parse.urljoin(final_css_url, raw)
            # Filter only likely images
            if any(absu.lower().split("?")[0].endswith(ext) for ext in (
                ".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".avif", ".bmp", ".jfif", ".pjpeg", ".pjp"
            )):
                image_urls.add(absu)

    return image_urls


def extract_allowed_links(html: str, base_url: str, allowed_prefix: str) -> set[str]:
    """Extract absolute links from <a href> that start with the allowed_prefix.
    Skips mailto:, tel:, javascript:, and fragments.
    """
    hrefs: set[str] = set()
    # Basic anchor extraction
    for m in re.finditer(r"<a[^>]+href=\"([^\"]+)\"", html, re.I):
        u = (m.group(1) or "").strip()
        if not u or u.startswith(("#", "mailto:", "tel:", "javascript:")):
            continue
        absu = urllib.parse.urljoin(base_url, u)
        # Normalize by removing fragment
        pu = urllib.parse.urlsplit(absu)
        pu = pu._replace(fragment="")
        absu = urllib.parse.urlunsplit(pu)
        if absu.startswith(allowed_prefix):
            hrefs.add(absu)
    return hrefs


def crawl_and_collect(start_url: str, allowed_prefix: str, max_pages: int = 50):
    """BFS crawl starting at start_url, constrained to URLs that start with allowed_prefix.
    Returns: (visited_urls: list[str], all_css_urls: set[str], all_image_urls_from_html: set[str])
    """
    visited: set[str] = set()
    visit_order: list[str] = []
    queue: list[str] = [start_url]
    page_html: dict[str, str] = {}
    all_css_urls: set[str] = set()
    all_img_urls_html: set[str] = set()

    while queue and len(visited) < max_pages:
        url = queue.pop(0)
        if url in visited:
            continue
        visited.add(url)
        try:
            data, final_url, _ = fetch(url)
        except Exception:
            continue
        html = data.decode("utf-8", errors="ignore")
        page_html[final_url] = html
        visit_order.append(final_url)

        # Collect CSS and images from this page
        all_css_urls |= collect_css_urls(html, final_url)
        all_img_urls_html |= collect_image_urls_from_html(html, final_url)

        # Enqueue allowed links from this page (still constrained to prefix)
        for link in extract_allowed_links(html, final_url, allowed_prefix):
            if link not in visited and link not in queue:
                queue.append(link)

    return visit_order, all_css_urls, all_img_urls_html


def collect_js_urls(html: str, base_url: str) -> set[str]:
    js_urls: set[str] = set()
    for m in re.finditer(r"<script[^>]+src=\"([^\"]+)\"", html, re.I):
        u = (m.group(1) or "").strip().strip('"\'')
        if not u or u.startswith(("data:", "javascript:")):
            continue
        # Support protocol-relative URLs like //assets.foleon.com/...
        if u.startswith("//"):
            u = "https:" + u
        js_urls.add(urllib.parse.urljoin(base_url, u))
    return js_urls


def collect_image_urls_from_text_resources(urls: set[str]) -> set[str]:
    """Fetch arbitrary text resources (e.g., JS bundles) and extract image URLs.
    Looks for both CSS-style url(...) and raw fully-qualified image URLs.
    """
    image_urls: set[str] = set()
    css_url_pattern = re.compile(r"url\(([^)]+)\)", re.I)
    raw_img_pattern = re.compile(
        r"https?://[^\s\"'<>]+\.(?:jpg|jpeg|png|gif|webp|svg|avif|bmp|jfif|pjpeg|pjp)(?:\?[^\"'<>\s]*)?",
        re.I,
    )
    for u in sorted(urls):
        try:
            data, final_url, _ = fetch(u)
        except Exception:
            continue
        text = data.decode("utf-8", errors="ignore")

        # url(...) matches
        for m in css_url_pattern.finditer(text):
            raw = (m.group(1) or "").strip().strip('"\'')
            if not raw or raw.startswith("data:"):
                continue
            absu = urllib.parse.urljoin(final_url, raw)
            # Normalize: strip ?ext=webp if present
            pu = urllib.parse.urlsplit(absu)
            if pu.query:
                q = urllib.parse.parse_qsl(pu.query, keep_blank_values=True)
                q = [(k, v) for (k, v) in q if not (k.lower() == "ext" and v.lower() == "webp")]
                pu = pu._replace(query=urllib.parse.urlencode(q))
                absu = urllib.parse.urlunsplit(pu)
            if any(absu.lower().split("?")[0].endswith(ext) for ext in (
                ".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".avif", ".bmp", ".jfif", ".pjpeg", ".pjp"
            )):
                image_urls.add(absu)

        # Raw fully-qualified image URLs
        for m in raw_img_pattern.finditer(text):
            absu = m.group(0)
            # Normalize: strip ?ext=webp if present
            pu = urllib.parse.urlsplit(absu)
            if pu.query:
                q = urllib.parse.parse_qsl(pu.query, keep_blank_values=True)
                q = [(k, v) for (k, v) in q if not (k.lower() == "ext" and v.lower() == "webp")]
                pu = pu._replace(query=urllib.parse.urlencode(q))
                absu = urllib.parse.urlunsplit(pu)
            if any(absu.lower().split("?")[0].endswith(ext) for ext in (
                ".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".avif", ".bmp", ".jfif", ".pjpeg", ".pjp"
            )):
                image_urls.add(absu)

    return image_urls


def ensure_unique_path(out_dir: str, filename: str) -> str:
    base, ext = os.path.splitext(filename)
    if not base:
        base = "image"
    if not ext:
        ext = ""
    target = os.path.join(out_dir, base + ext)
    idx = 1
    while os.path.exists(target):
        target = os.path.join(out_dir, f"{base}-{idx}{ext}")
        idx += 1
    return target


def guess_ext_from_ctype(ctype: str) -> str:
    ctype = (ctype or "").lower()
    if "jpeg" in ctype:
        return ".jpg"
    if "png" in ctype:
        return ".png"
    if "gif" in ctype:
        return ".gif"
    if "webp" in ctype:
        return ".webp"
    if "svg" in ctype:
        return ".svg"
    return ""


def _hash_bytes(data: bytes) -> str:
    h = hashlib.sha256()
    h.update(data)
    return h.hexdigest()


def _index_existing_hashes(out_dir: str) -> set[str]:
    hashes: set[str] = set()
    if not os.path.isdir(out_dir):
        return hashes
    for name in os.listdir(out_dir):
        p = os.path.join(out_dir, name)
        if not os.path.isfile(p):
            continue
        try:
            with open(p, "rb") as f:
                data = f.read()
            hashes.add(_hash_bytes(data))
        except Exception:
            # Ignore unreadable files
            continue
    return hashes


_PREVIEW_NAME_RE = re.compile(
    r"^[a-z0-9]{16}_(?:d|fb|o|tw)\.(?:png|jpe?g|webp)$",
    re.I,
)


def _is_unwanted_preview_filename(name: str) -> bool:
    """Return True if filename matches auto-generated preview image pattern
    like 0ylqv1un29xt5wro_{d,fb,o,tw}.png (not genuine site assets).
    """
    return bool(_PREVIEW_NAME_RE.match(name.strip()))


def download_images(image_urls: set[str], out_dir: str) -> int:
    os.makedirs(out_dir, exist_ok=True)
    saved = 0
    seen_hashes: set[str] = _index_existing_hashes(out_dir)
    for url in sorted(image_urls):
        try:
            data, final_url, ctype = fetch(url)
        except Exception:
            # fallback: try without query string if present
            pu = urllib.parse.urlsplit(url)
            if pu.query:
                try:
                    data, final_url, ctype = fetch(urllib.parse.urlunsplit(pu._replace(query="")))
                except Exception:
                    continue
            else:
                continue

        # Deduplicate by content hash to avoid saving duplicates or creating -1 suffixed files
        try:
            chash = _hash_bytes(data)
        except Exception:
            chash = None
        if chash and chash in seen_hashes:
            # Duplicate content already present, skip saving
            continue

        # filename
        name = os.path.basename(urllib.parse.urlsplit(final_url).path) or "image"
        base, ext = os.path.splitext(name)
        if not ext:
            ext = guess_ext_from_ctype(ctype)
            name = base + ext if ext else base

        # Skip unwanted preview filenames (auto-generated page previews)
        if _is_unwanted_preview_filename(name):
            continue

        # If a file with the same name already exists, prefer the larger file size.
        # - If the new file is larger than the existing one, overwrite it.
        # - If the new file is smaller or equal, skip saving.
        target_path = os.path.join(out_dir, name)
        if os.path.exists(target_path):
            try:
                existing_size = os.path.getsize(target_path)
            except Exception:
                existing_size = 0
            new_size = len(data)
            if new_size <= existing_size:
                # Keep the larger (existing) file
                continue
            # Overwrite with the larger file
            try:
                with open(target_path, "wb") as f:
                    f.write(data)
                # Count as a save/upgrade
                saved += 1
                if chash:
                    seen_hashes.add(chash)
            except Exception:
                continue
            # Done handling this URL
            continue
        try:
            with open(target_path, "wb") as f:
                f.write(data)
            saved += 1
            if chash:
                seen_hashes.add(chash)
        except Exception:
            continue
    return saved


def _derive_output_dir_name(from_url: str) -> str:
    """Derive a filesystem-friendly folder name from a URL.
    Example: https://www.mybenefitsnow.com/calix-candidate/home ->
             www_mybenefitsnow_com_calix-candidate_home
    """
    try:
        pu = urllib.parse.urlsplit(from_url)
    except Exception:
        pu = urllib.parse.urlsplit(urllib.parse.quote(from_url, safe=":/_?&=#"))
    host = (pu.netloc or "site").lower()
    path = (pu.path or "/").strip("/")
    host_part = re.sub(r"[^a-z0-9]+", "_", host)
    if path:
        path_part = re.sub(r"[^a-z0-9\-_/]+", "_", path.lower())
        path_part = path_part.replace("/", "_")
    else:
        path_part = "root"
    name = f"{host_part}_{path_part}" if path_part else host_part
    # Collapse multiple underscores and trim
    name = re.sub(r"_+", "_", name).strip("_") or "output"
    # Always prefix with assets_of_
    return f"assets_of_{name}"


def main():
    if len(sys.argv) < 2:
        print(
            "Usage: python3 script_storage/download_mybenefitsnow_backgrounds.py <start_url> [max_pages]",
            file=sys.stderr,
        )
        sys.exit(2)

    start_url = sys.argv[1]
    # Optional second arg: max pages (int)
    max_pages = 100
    if len(sys.argv) >= 3:
        try:
            max_pages = int(sys.argv[2])
        except Exception:
            pass

    # Output directory next to this script, derived from the URL
    script_dir = os.path.abspath(os.path.dirname(__file__))
    out_dir = os.path.join(script_dir, _derive_output_dir_name(start_url))
    os.makedirs(out_dir, exist_ok=True)

    # Crawl is always constrained to the normalized start URL prefix
    normalized_prefix = start_url.rstrip("/") + "/"

    image_urls: set[str] = set()

    # Crawl from the start URL within its own prefix
    visited_urls, css_urls, html_img_urls = crawl_and_collect(
        start_url, normalized_prefix, max_pages=max_pages
    )
    image_urls |= html_img_urls
    image_urls |= collect_image_urls_from_css(css_urls)

    # Also scan external JS bundles for image references (Foleon, etc.)
    js_to_scan: set[str] = set()
    for url in visited_urls:
        try:
            data, final_url, _ = fetch(url)
        except Exception:
            continue
        html = data.decode("utf-8", errors="ignore")
        js_to_scan |= collect_js_urls(html, final_url)
    image_urls |= collect_image_urls_from_text_resources(js_to_scan)
    saved = download_images(image_urls, out_dir)

    print(f"Start URL: {start_url}")
    print(f"Crawl prefix: {normalized_prefix}")
    print(f"Max pages: {max_pages}")
    print(f"Output directory: {out_dir}\n")
    print("Pages found (visited in order):")
    for u in visited_urls:
        print(f" - {u}")
    print(f"Saved {saved} images to {out_dir}")

    print(f"If you want to now resize these to the likely dimensions needed for Bedrocc, run:")
    print(f"ruby foleon_image_resizer.rb {out_dir}")

if __name__ == "__main__":
    main()
