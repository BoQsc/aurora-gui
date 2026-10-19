# Unicode 17.0.0 conformance record

**Package:** `aurora-standard` 1.0.0  
**Recorded:** 2026-10-19  
**Toolchain:** DMD 2.113.0, Windows 10 x86_64  
**Data:** official Unicode 17.0.0 Character Database and conformance files under `spec/unicode/17.0.0`

## Results

| Corpus | Cases | Boundaries |
|---|---:|---:|
| `GraphemeBreakTest.txt` | 766 / 766 | 2,756 / 2,756 |
| `LineBreakTest.txt` | 19,338 / 19,338 | 79,825 / 79,825 |
| `BidiCharacterTest.txt` | 91,707 / 91,707 | 717,503 / 717,503 |
| `BidiTest.txt` | 770,241 / 770,241 | 3,049,617 / 3,049,617 |
| **Total** | **882,052 / 882,052** | **3,849,701 / 3,849,701** |

The runner exits nonzero if any case or boundary differs. All four corpora
passed before this package was sealed.

## What is proven

- Extended grapheme-cluster boundaries match the official UAX #29 corpus.
- Default line-break opportunities match the official UAX #14 corpus.
- Bidi character resolution matches the official UAX #9 character corpus.
- Bidi class resolution and visual ordering match the official `BidiTest`
  corpus.
- The generated property table reproduces from the official inputs. The
  verifier regenerates it and compares canonical LF-normalized bytes.

## What is not proven by these corpora

- Exhaustive verification of every individual property lookup. The property
  table is generated from the official Unicode Character Database and covered
  by representative unit assertions, but the four corpora above are the
  behavioral oracles for segmentation and bidi.
- Word or sentence segmentation, locale tailoring, dictionary line breaking,
  hyphenation, justification, shaping, font loading, or rendering. Those are
  outside this standard.
- Memory safety under adversarial input. No exception is claimed beyond the
  documented pure API behavior.

## Reproduction

From this package directory:

```text
python tools/verify_standard.py
```

The verifier performs, in order:

1. Manifest coverage and hash verification.
2. `VERSION` and `dub.json` agreement.
3. Unicode table regeneration and canonical byte comparison.
4. API surface comparison against compiler-generated public symbols.
5. Consumer acceptance compilation and execution.
6. Compilation and execution of the official conformance runner.

The individual conformance executable can also be built and run directly:

```text
dmd -Ivendor/aurora-standard/source -i -of=<temp>/aurora-standard-conformance.exe vendor/aurora-standard/tests/unicode_conformance.d
<temp>/aurora-standard-conformance.exe vendor/aurora-standard/spec/unicode/17.0.0
```

## Determinism note

The Python generator uses the platform's default text newline. On Windows it
writes CRLF; the checked-in table uses LF. The verifier normalizes CRLF to LF
before comparing and before manifest sealing. This makes the artifact
deterministic across platforms without changing the documented bytes of the
checked-in table.

## Provenance

The implementation was extracted from the Unicode layer of the vendored
Aurora-D 0.4.5 tree, moved to `aurora.standard.text.unicode.*`, and otherwise
kept unchanged. The official inputs and conformance files are included under
`spec/unicode/17.0.0` and covered by `LICENSE-UNICODE.txt`.
