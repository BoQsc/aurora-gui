#!/usr/bin/env python3
"""Create a self-contained local A/B review from captured UI images.

The result is evidence for a decision, not an approval.  The generated manifest
always starts in ``pending-user-review`` state.
"""
from __future__ import annotations

import argparse
import hashlib
from html import escape
import json
from pathlib import Path
import shutil
import sys


SUPPORTED_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def checked_image(value: str) -> Path:
    path = Path(value).resolve()
    if not path.is_file():
        raise argparse.ArgumentTypeError(f"image does not exist: {path}")
    if path.suffix.lower() not in SUPPORTED_SUFFIXES:
        supported = ", ".join(sorted(SUPPORTED_SUFFIXES))
        raise argparse.ArgumentTypeError(
            f"unsupported image type {path.suffix!r}; use {supported}"
        )
    return path


def copy_evidence(source: Path, output: Path, stem: str) -> dict[str, str]:
    target = output / f"{stem}{source.suffix.lower()}"
    shutil.copy2(source, target)
    return {
        "file": target.name,
        "source": str(source),
        "sha256": digest(target),
    }


def review_html(title: str, baseline: dict[str, str], candidate: dict[str, str],
                difference: dict[str, str] | None) -> str:
    safe_title = escape(title)
    baseline_file = escape(baseline["file"], quote=True)
    candidate_file = escape(candidate["file"], quote=True)
    diff_section = ""
    if difference is not None:
        diff_file = escape(difference["file"], quote=True)
        diff_section = f"""
        <section class="diff">
          <h2>Difference</h2>
          <img src="{diff_file}" alt="Pixel difference visualization">
        </section>"""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{safe_title}</title>
<style>
  :root {{ color-scheme: dark; font-family: Segoe UI, sans-serif; }}
  body {{ margin: 0; background: #101318; color: #eef2f7; }}
  header {{ padding: 22px 28px; border-bottom: 1px solid #343b46; }}
  h1, h2 {{ margin: 0 0 10px; }}
  .pending {{ color: #ffd166; }}
  main {{ padding: 24px; display: grid; gap: 24px; }}
  .pair {{ display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }}
  figure, .compare, .diff {{ margin: 0; padding: 14px; background: #191e26;
    border: 1px solid #343b46; border-radius: 10px; }}
  figcaption {{ font-weight: 650; margin-bottom: 10px; }}
  img {{ display: block; width: 100%; height: auto; image-rendering: auto; }}
  .compare {{ overflow: hidden; }}
  .stage {{ position: relative; line-height: 0; }}
  .stage .candidate {{ position: absolute; inset: 0; clip-path: inset(0 50% 0 0); }}
  input[type=range] {{ width: 100%; margin: 14px 0 0; }}
  .controls {{ display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }}
  button {{ padding: 8px 13px; border-radius: 6px; border: 1px solid #566173;
    color: inherit; background: #252c36; cursor: pointer; }}
  .decision {{ padding: 16px; border-left: 4px solid #ffd166; background: #191e26; }}
  @media (max-width: 850px) {{ .pair {{ grid-template-columns: 1fr; }} }}
</style>
</head>
<body>
<header>
  <h1>{safe_title}</h1>
  <div class="pending">Decision pending — neither image is approved as the standard.</div>
</header>
<main>
  <section class="pair">
    <figure><figcaption>A — current standard</figcaption>
      <img src="{baseline_file}" alt="Current standard"></figure>
    <figure><figcaption>B — proposed candidate</figcaption>
      <img src="{candidate_file}" alt="Proposed candidate"></figure>
  </section>
  <section class="compare">
    <h2>Same-position wipe comparison</h2>
    <div class="stage">
      <img src="{baseline_file}" alt="Current standard">
      <img class="candidate" id="candidate" src="{candidate_file}"
        alt="Proposed candidate">
    </div>
    <input id="wipe" type="range" min="0" max="100" value="50"
      aria-label="Candidate reveal percentage">
    <div class="controls">
      <button type="button" id="show-a">Show A</button>
      <button type="button" id="show-b">Show B</button>
      <button type="button" id="blink">Blink A/B</button>
      <span id="amount">50% B</span>
    </div>
  </section>
  {diff_section}
  <section class="decision">
    Final choice belongs to the project owner. Report A, B, neither, or request
    another capture; an agent can then record that decision separately.
  </section>
</main>
<script>
  const wipe = document.getElementById('wipe');
  const candidate = document.getElementById('candidate');
  const amount = document.getElementById('amount');
  let timer = null;
  function show(value) {{
    wipe.value = value;
    candidate.style.clipPath = `inset(0 ${{100 - value}}% 0 0)`;
    amount.textContent = `${{value}}% B`;
  }}
  wipe.addEventListener('input', () => {{ clearInterval(timer); timer = null;
    show(Number(wipe.value)); }});
  document.getElementById('show-a').onclick = () => show(0);
  document.getElementById('show-b').onclick = () => show(100);
  document.getElementById('blink').onclick = () => {{
    if (timer) {{ clearInterval(timer); timer = null; return; }}
    let b = false; show(0);
    timer = setInterval(() => {{ b = !b; show(b ? 100 : 0); }}, 650);
  }};
</script>
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=checked_image)
    parser.add_argument("--candidate", required=True, type=checked_image)
    parser.add_argument("--difference", type=checked_image)
    parser.add_argument("--title", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    output = args.output.resolve()
    try:
        output.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        parser.error(f"output directory already exists: {output}")

    baseline = copy_evidence(args.baseline, output, "baseline")
    candidate = copy_evidence(args.candidate, output, "candidate")
    difference = None
    if args.difference is not None:
        difference = copy_evidence(args.difference, output, "difference")

    manifest = {
        "schema": 1,
        "title": args.title,
        "status": "pending-user-review",
        "baseline": baseline,
        "candidate": candidate,
        "difference": difference,
        "decision": None,
    }
    (output / "review.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    (output / "review.html").write_text(
        review_html(args.title, baseline, candidate, difference), encoding="utf-8"
    )
    print(output / "review.html")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
