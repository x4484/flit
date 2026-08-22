#!/usr/bin/env python3
from __future__ import annotations

import html
import os
import re
import shutil
from pathlib import Path

try:
    import markdown
except ImportError as error:
    raise SystemExit("Install Python-Markdown: python3 -m pip install Markdown") from error

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
OUTPUT = ROOT / "site"
PAGES = ["index.md", "installation.md", "privacy.md", "terms.md", "support.md"]
SITE_URL = os.environ.get("FLIT_SITE_URL", "").rstrip("/")


def parse_document(path: Path) -> tuple[dict[str, str], str]:
    source = path.read_text(encoding="utf-8")
    metadata: dict[str, str] = {}
    if source.startswith("---\n"):
        _, front_matter, source = source.split("---\n", 2)
        for line in front_matter.splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                metadata[key.strip()] = value.strip().strip('"')
    source = source.replace("{{ site.baseurl }}", "")
    source = re.sub(r"\(([^)]+)\.md\)", r"(\1/)", source)
    return metadata, source


def page_path(filename: str, metadata: dict[str, str]) -> tuple[Path, str]:
    if filename == "index.md":
        return OUTPUT / "index.html", "/"
    permalink = metadata.get("permalink", f"/{Path(filename).stem}/")
    return OUTPUT / permalink.strip("/") / "index.html", permalink


def render_page(title: str, body: str, permalink: str) -> str:
    canonical = f'<link rel="canonical" href="{html.escape(SITE_URL + permalink)}">' if SITE_URL else ""
    document_title = (
        "Flit — Fast and lightweight email for macOS"
        if title == "Flit"
        else f"{title} · Flit"
    )
    social_origin = SITE_URL or "https://www.flit.wtf"
    social_url = html.escape(social_origin + permalink)
    social_image = html.escape(social_origin + "/assets/og.png")
    social_description = "Fast and lightweight email client for your Mac."
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="Flit is a fast, local-first native mail client for macOS.">
  <meta name="theme-color" content="#07101f">
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="Flit">
  <meta property="og:title" content="{html.escape(document_title)}">
  <meta property="og:description" content="{social_description}">
  <meta property="og:url" content="{social_url}">
  <meta property="og:image" content="{social_image}">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta property="og:image:alt" content="Flit — fast and lightweight email client for your Mac">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="{html.escape(document_title)}">
  <meta name="twitter:description" content="{social_description}">
  <meta name="twitter:image" content="{social_image}">
  <meta name="twitter:image:alt" content="Flit — fast and lightweight email client for your Mac">
  {canonical}
  <title>{html.escape(document_title)}</title>
  <link rel="icon" href="/assets/icon.png" type="image/png">
  <link rel="stylesheet" href="/styles.css">
</head>
<body>
  <a class="skip-link" href="#content">Skip to content</a>
  <header class="site-header">
    <a class="brand" href="/" aria-label="Flit home"><img src="/assets/logo.png" alt="Flit"></a>
    <nav aria-label="Primary navigation">
      <a href="/installation/">Installation</a>
      <a href="/privacy/">Privacy</a>
      <a href="/support/">Support</a>
      <a class="github-link" href="https://github.com/x4484/flit">GitHub</a>
    </nav>
  </header>
  <main id="content" class="content">
    {body}
  </main>
  <footer>
    <span>Native, local-first email for macOS.</span>
    <span><a href="/terms/">Terms</a> · <a href="https://github.com/x4484/flit/blob/main/LICENSE">MIT License</a></span>
  </footer>
</body>
</html>
"""


def main() -> None:
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    (OUTPUT / "assets").mkdir(parents=True)

    for filename in PAGES:
        metadata, source = parse_document(DOCS / filename)
        body = markdown.markdown(source, extensions=["fenced_code", "tables"])
        destination, permalink = page_path(filename, metadata)
        destination.parent.mkdir(parents=True, exist_ok=True)
        title = metadata.get("title", "Flit")
        destination.write_text(render_page(title, body, permalink), encoding="utf-8")

    shutil.copy2(ROOT / "assets" / "FLIT-logo.png", OUTPUT / "assets" / "logo.png")
    shutil.copy2(ROOT / "assets" / "Flit-AppIcon-1024.png", OUTPUT / "assets" / "icon.png")
    shutil.copy2(ROOT / "assets" / "Flit-OG-1200x630.png", OUTPUT / "assets" / "og.png")
    shutil.copy2(ROOT / "site-src" / "styles.css", OUTPUT / "styles.css")
    print(f"Built {OUTPUT}")


if __name__ == "__main__":
    main()
