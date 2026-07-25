#!/usr/bin/env python3
"""Source-level guardrails for Aurora Cut's live-title architecture.

This is intentionally standard-library only. It does not replace DMD/DUB; it
prevents the old double-render/frame-swap design from silently returning.
"""
from __future__ import annotations

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    preview = read("source/auroracut/preview.d")
    editor = read("source/auroracut/editor.d")
    exporter = read("source/auroracut/exporter.d")
    title_layer = read("source/auroracut/titlelayer.d")
    text_editor = read(
        "vendor/aurora-d-0.4.5/source/aurora/widgets/texteditor.d"
    )
    title_paint = read(
        "vendor/aurora-d-0.4.5/source/aurora/text/titlepaint.d"
    )
    all_runtime = "\n".join((preview, editor, exporter, title_layer, text_editor))

    for obsolete in (
        "PreviewFrameRole",
        "PreviewInlineTextField",
        "expectInlineBackground",
        "inlineCommitPending",
        "drawtext=",
    ):
        require(obsolete not in all_runtime, f"obsolete dual-title path returned: {obsolete}")

    require("PreviewTitleEditor[ulong] _titleLayers" in preview,
            "Preview does not own persistent title layers")
    require("titleEditorForTesting" in preview and "during is before" in preview,
            "persistent-object title regression is missing")
    require("setCanvasTextMode(true)" in preview,
            "live title still behaves like a scrolling field")
    require("paintTitleBackdrop" in text_editor and "paintTitleForeground" in text_editor,
            "caret/selection no longer share title paint layout")
    require("request.renderTitles = false" in editor,
            "interactive frame request can burn titles into RGB background")
    require("if (clip.isText())" in editor and "continue;" in editor,
            "interactive background does not skip text clips")
    require("renderTitlePam" in exporter and "prepareTitleRasters" in exporter,
            "final export no longer consumes Aurora title rasters")
    require("paintTitleLayout" in title_layer and "paintTitleLayout" in title_paint,
            "preview/export shared title paint path is missing")
    require("std.algorithm.comparison : max" in title_paint,
            "title underline renderer is missing its max import")
    require("if (!value && hasSelection()) selectNone();" in preview,
            "live title does not clear character selection on focus loss")
    require("hasSelection() && (!_canvasTextMode || focused())" in text_editor,
            "inactive canvas titles can still paint stale character selection")
    require("_inlineText.clearTextSelection();" in preview and
            "A stale character selection remained painted" in preview,
            "title-edit completion does not guard against stale selection paint")
    require("savePam" in title_layer,
            "transparent RGBA title export is missing")
    require("double layerOpacity = 1.0" in title_paint,
            "title paint style has no final layer opacity")
    require("distributedLayerColor" in title_paint and
            "1.0 - pow(1.0 - target" in title_paint,
            "multi-pass title effects can accumulate opacity again")
    require("setTitleLayerOpacity" in text_editor and
            "titleStyle.layerOpacity = _titleLayerOpacity" in text_editor,
            "live title editor does not apply final layer opacity")
    require("style.layerOpacity = visual.opacity" in title_layer and
            "style.layerOpacity = 1.0" in title_layer,
            "preview/export title layer opacity split is missing")

    print("Aurora Cut live-title architecture source checks passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
