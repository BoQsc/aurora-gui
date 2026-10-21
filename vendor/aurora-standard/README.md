# aurora-standard

**Version 1.0.0 — Unicode 17.0.0**

`aurora-standard` is the frozen text-standard layer for Aurora programs. It owns
the Unicode property tables, extended grapheme-cluster boundaries, the Unicode
Bidirectional Algorithm, and default line-break opportunities for Unicode
17.0.0.

The package is deliberately small. It does not render text, load fonts, shape
OpenType features, lay out widgets, or make application policy decisions.

## Scope

Included:

- Unicode 17.0.0 property lookups and generated tables
- Extended grapheme-cluster segmentation (UAX #29)
- Bidirectional resolution through rule L2 (UAX #9)
- Default line-break opportunities (UAX #14)
- The official Unicode 17.0.0 conformance corpora and a runner
- A consumer acceptance test written against the documented API

Not included:

- Font loading, OpenType shaping, atlas management, or rasterization
- Word or sentence segmentation (UAX #29 word/sentence rules)
- Locale tailoring, dictionary line breaking, justification, or hyphenation
- Bidi paragraph splitting, visual glyph shaping, or rendering
- Widgets, windows, platform adapters, compositors, or application policy

## Quick start

Add the package to a DUB recipe:

```json
"dependencies": {
  "aurora-standard": {
    "path": "../vendor/aurora-standard"
  }
}
```

Import the public modules:

```d
import aurora.standard.text.unicode.grapheme;
import aurora.standard.text.unicode.bidi;
import aurora.standard.text.unicode.linebreak;
import aurora.standard.text.unicode.properties;

void main()
{
    const text = "a\u0301"d;
    assert(graphemeBoundaries(text) == [0UL, 2UL]);

    auto bidi = resolveBidi("\u05D0\u05D1\u05D2"d);
    assert(bidi.paragraphLevel == 1);
    assert(bidi.visualOrder == [2UL, 1UL, 0UL]);

    auto breaks = lineBreakOpportunities("hello world"d);
    assert(breaks[6]);
}
```

The complete API contract is in [docs/api.md](docs/api.md). The machine-readable
surface is [api/surface.json](api/surface.json).

## Verification

Run the complete gate:

```text
python tools/verify_standard.py
```

It verifies:

- the manifest covers every package file and every hash matches;
- `VERSION` and `dub.json` agree;
- the generated property table reproduces from `spec/unicode/17.0.0`;
- the documented API matches the compiler's public symbol set;
- the consumer test compiles and passes using only documented API;
- all four official Unicode 17.0.0 corpora pass.

Run only the Unicode conformance executable:

```text
dub run --config=unicode-conformance -- spec/unicode/17.0.0
```

## Stability

This is a **standard** package: the API and documented behavior are frozen
within major version 1. Changes happen through a new version, never by silently
editing files under this directory. See [docs/compatibility.md](docs/compatibility.md)
for the exact policy.

The Unicode data is pinned to **17.0.0**. A future Unicode release is a new
versioned data set and a new standard version; it does not modify 1.0.0 in
place.

## Provenance and licensing

The implementation was extracted from the verified Unicode layer of the
vendored Aurora-D 0.4.5 tree and moved to the `aurora.standard.*` namespace
without changing the algorithms or generated tables. The original algorithm
bodies and tables remain available under the BSD Zero Clause License (0BSD) in
[LICENSE](LICENSE). The official Unicode data and license are covered by
[LICENSE-UNICODE.txt](LICENSE-UNICODE.txt).

Conformance evidence is recorded in [docs/conformance.md](docs/conformance.md).
