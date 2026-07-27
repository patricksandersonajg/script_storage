#!/usr/bin/env python3
"""
PDF extractor/downloader for MyBenefitsNow-style sites.

What it does
- Crawls starting from a given URL (stays within that URL prefix for HTML pages).
- On each visited page, finds <a> tags that link to PDFs and downloads them.
- Files are saved under: <this_script_dir>/<assets_of_...>/pdfs/<page_subpath>/
  where <assets_of_...> is derived from the start URL (same scheme as the image extractor),
  and <page_subpath> reflects the URL they were found on per the requirement.
  Example: PDFs first found on
    https://www.mybenefitsnow.com/redwoodtrust/home/medical
  ->
    <...>/assets_of_www_mybenefitsnow_com_redwoodtrust_home/pdfs/home/medical

Naming & duplicates
- Each PDF keeps the original URL filename (snake_cased if necessary).
- Fingerprint tags appended by Foleon are stripped from the filename (e.g.,
  ca_n_redwood_trust_jan2026__sold_df_hmo_604219.b08b188bc618.pdf ->
  ca_n_redwood_trust_jan2026__sold_df_hmo_604219.pdf).
- Duplicate PDFs are detected by content hash. The first one to be downloaded is kept; later
  duplicates (by hash) are ignored. We index existing hashes recursively under the pdfs/ tree so
  reruns maintain the first-kept behavior.

How to run
  python3 script_storage/foleon_pdf_extractor.py https://www.mybenefitsnow.com/redwoodtrust/home 100

"""

import os
import re
import ssl
import sys
import html
import hashlib
import urllib.parse
import urllib.request
from typing import Dict, List, Set, Tuple

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


def _hash_bytes(data: bytes) -> str:
    h = hashlib.sha256()
    h.update(data)
    return h.hexdigest()


def _snake_case(text: str) -> str:
    # Unescape HTML entities, collapse whitespace, keep alnum and underscores
    t = html.unescape(text or "").strip().lower()
    # Replace non-alphanumeric with underscores
    t = re.sub(r"[^a-z0-9]+", "_", t)
    t = re.sub(r"_+", "_", t).strip("_")
    return t or "document"


_FINGERPRINT_STEM_RE = re.compile(r"^(?P<base>.*)\.[0-9a-fA-F]{8,}$")


def _clean_filename_from_url(url: str) -> str:
    """Derive a snake_cased PDF filename from the URL, stripping Foleon-style
    fingerprint tags that appear as a final dot + hex chunk before the extension.
    Always ends with .pdf.
    """
    path = urllib.parse.urlsplit(url).path
    raw_name = os.path.basename(path) or "document.pdf"
    stem, ext = os.path.splitext(raw_name)
    # Ensure extension is .pdf regardless of case or missing
    ext = ".pdf"
    # Strip fingerprint like ".b08b188bc618" at end of stem
    m = _FINGERPRINT_STEM_RE.match(stem)
    if m:
        stem = m.group("base")
    # Snake_case the stem while preserving numbers/letters
    stem_sc = _snake_case(stem)
    if not stem_sc:
        stem_sc = "document"
    return f"{stem_sc}{ext}"


def _derive_output_dir_name(from_url: str) -> str:
    """Derive a filesystem-friendly folder name from a URL.
    Example: https://www.mybenefitsnow.com/calix-candidate/home ->
             assets_of_www_mybenefitsnow_com_calix-candidate_home
    """
    try:
        pu = urllib.parse.urlsplit(from_url)
    except Exception:
        pu = urllib.parse.urlsplit(urllib.parse.quote(from_url, safe=":/_?&=#"))
    host = (pu.netloc or "site").lower()
    path = (pu.path or "/").strip("/")
    host_part = re.sub(r"[^a-z0-9]+", "_", host)
    if path:
        path_part = re.sub(r"[^a-z0-9\-_/]+", "_", path.lower()).replace("/", "_")
    else:
        path_part = "root"
    name = f"{host_part}_{path_part}" if path_part else host_part
    name = re.sub(r"_+", "_", name).strip("_") or "output"
    return f"assets_of_{name}"


def _extract_allowed_links(html_text: str, base_url: str, allowed_prefix: str) -> Set[str]:
    hrefs: Set[str] = set()
    for m in re.finditer(r"<a[^>]+href=\"([^\"]+)\"", html_text, re.I):
        u = (m.group(1) or "").strip()
        if not u or u.startswith(("#", "mailto:", "tel:", "javascript:")):
            continue
        absu = urllib.parse.urljoin(base_url, u)
        pu = urllib.parse.urlsplit(absu)
        pu = pu._replace(fragment="")
        absu = urllib.parse.urlunsplit(pu)
        if absu.startswith(allowed_prefix):
            hrefs.add(absu)
    return hrefs


def crawl_pages(start_url: str, allowed_prefix: str, max_pages: int = 50) -> Tuple[List[str], Dict[str, str]]:
    visited: Set[str] = set()
    visit_order: List[str] = []
    queue: List[str] = [start_url]
    page_html: Dict[str, str] = {}

    while queue and len(visited) < max_pages:
        url = queue.pop(0)
        if url in visited:
            continue
        visited.add(url)
        try:
            data, final_url, _ = fetch(url)
        except Exception:
            continue
        html_text = data.decode("utf-8", errors="ignore")
        page_html[final_url] = html_text
        visit_order.append(final_url)

        for link in _extract_allowed_links(html_text, final_url, allowed_prefix):
            if link not in visited and link not in queue:
                queue.append(link)

    return visit_order, page_html


def _index_existing_hashes_recursively(base_dir: str) -> Set[str]:
    hashes: Set[str] = set()
    if not os.path.isdir(base_dir):
        return hashes
    for root, _dirs, files in os.walk(base_dir):
        for fname in files:
            p = os.path.join(root, fname)
            try:
                with open(p, "rb") as f:
                    data = f.read()
                hashes.add(_hash_bytes(data))
            except Exception:
                continue
    return hashes


def _extract_pdf_links_with_text(html_text: str, base_url: str) -> List[Tuple[str, str]]:
    # Find <a ... href="...pdf...">anchor text</a>
    results: List[Tuple[str, str]] = []
    for m in re.finditer(r"<a\b([^>]*)>(.*?)</a>", html_text, re.I | re.S):
        attrs = m.group(1) or ""
        inner = m.group(2) or ""
        href_m = re.search(r"href=\"([^\"]+)\"", attrs, re.I)
        if not href_m:
            href_m = re.search(r"href='([^']+)'", attrs, re.I)
        if not href_m:
            continue
        href = href_m.group(1).strip()
        absu = urllib.parse.urljoin(base_url, href)
        if not absu.lower().split("?")[0].endswith(".pdf"):
            continue
        # Strip HTML from inner text and normalize
        text_only = re.sub(r"<[^>]+>", " ", inner)
        text_only = re.sub(r"\s+", " ", text_only).strip()
        results.append((absu, text_only))
    return results


def _page_subpath_for_pdfs(start_url: str, page_url: str) -> str:
    """Return the desired subpath under pdfs/ that mirrors the page URL per requirement.
    Example per requirement:
      start: https://www.mybenefitsnow.com/redwoodtrust/home
      page:  https://www.mybenefitsnow.com/redwoodtrust/home/medical
      ->     pdfs/home/medical

    Heuristic: remove the first path segment of the site's area (e.g., 'redwoodtrust') and
    keep the remainder. If removal would leave empty, fall back to the last segment or 'root'.
    """
    try:
        ps = urllib.parse.urlsplit(start_url)
        pp = urllib.parse.urlsplit(page_url)
    except Exception:
        return "root"

    start_parts = [p for p in (ps.path or "/").strip("/").split("/") if p]
    page_parts = [p for p in (pp.path or "/").strip("/").split("/") if p]

    # Remove leading segment if shared (e.g., 'redwoodtrust')
    if start_parts:
        lead = start_parts[0]
        if page_parts and page_parts[0] == lead:
            page_parts = page_parts[1:]

    # If nothing left, try to use the last segment of start or 'root'
    if not page_parts:
        if start_parts:
            page_parts = [start_parts[-1]]
        else:
            page_parts = ["root"]

    return "/".join(page_parts)


def download_pdfs(start_url: str, visited_pages: List[str], page_html_map: Dict[str, str], out_root: str) -> int:
    pdf_root = os.path.join(out_root, "pdfs")
    os.makedirs(pdf_root, exist_ok=True)
    seen_hashes: Set[str] = _index_existing_hashes_recursively(pdf_root)

    saved = 0
    for page_url in visited_pages:
        html_text = page_html_map.get(page_url, "")
        links = _extract_pdf_links_with_text(html_text, page_url)
        if not links:
            continue

        subpath = _page_subpath_for_pdfs(start_url, page_url)
        target_dir = os.path.join(pdf_root, *([p for p in subpath.split("/") if p]))
        os.makedirs(target_dir, exist_ok=True)

        for abs_pdf_url, anchor_text in links:
            # Fetch the PDF
            try:
                data, final_url, ctype = fetch(abs_pdf_url)
            except Exception:
                # Try without query string as a fallback
                pu = urllib.parse.urlsplit(abs_pdf_url)
                if pu.query:
                    try:
                        data, final_url, ctype = fetch(urllib.parse.urlunsplit(pu._replace(query="")))
                    except Exception:
                        continue
                else:
                    continue

            # Hash for dedupe
            try:
                chash = _hash_bytes(data)
            except Exception:
                chash = None
            if chash and chash in seen_hashes:
                # Duplicate content already saved somewhere under pdfs/
                continue

            # Build filename from the original URL filename (snake_cased) and strip fingerprint
            filename = _clean_filename_from_url(final_url)
            target_path = os.path.join(target_dir, filename)

            # If exists with same content, skip; if exists different, append numeric suffix
            if os.path.exists(target_path):
                try:
                    with open(target_path, "rb") as f:
                        existing = f.read()
                    if _hash_bytes(existing) == chash:
                        # Same content already under same name (rare given global set), skip
                        continue
                except Exception:
                    pass
                # Find a unique name
                i = 2
                while True:
                    stem, _ = os.path.splitext(filename)
                    alt = os.path.join(target_dir, f"{stem}-{i}.pdf")
                    if not os.path.exists(alt):
                        target_path = alt
                        break
                    i += 1

            try:
                with open(target_path, "wb") as f:
                    f.write(data)
                saved += 1
                if chash:
                    seen_hashes.add(chash)
            except Exception:
                continue

    return saved


def main():
    if len(sys.argv) < 2:
        print(
            "Usage: python3 script_storage/foleon_pdf_extractor.py <start_url> [max_pages]",
            file=sys.stderr,
        )
        sys.exit(2)

    start_url = sys.argv[1]
    max_pages = 100
    if len(sys.argv) >= 3:
        try:
            max_pages = int(sys.argv[2])
        except Exception:
            pass

    script_dir = os.path.abspath(os.path.dirname(__file__))
    out_dir = os.path.join(script_dir, _derive_output_dir_name(start_url))
    os.makedirs(out_dir, exist_ok=True)

    normalized_prefix = start_url.rstrip("/") + "/"

    visited_urls, page_html_map = crawl_pages(start_url, normalized_prefix, max_pages=max_pages)
    saved = download_pdfs(start_url, visited_urls, page_html_map, out_dir)

    print(f"Start URL: {start_url}")
    print(f"Crawl prefix: {normalized_prefix}")
    print(f"Max pages: {max_pages}")
    print(f"Output directory: {out_dir}\n")
    print("Pages found (visited in order):")
    for u in visited_urls:
        print(f" - {u}")
    print(f"Saved {saved} PDFs under {os.path.join(out_dir, 'pdfs')}")


if __name__ == "__main__":
    main()
