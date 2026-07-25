# Aurora-D typography

Aurora-D 0.4.2 defines interface type by semantic tier. The values are 96-DPI logical EM pixel sizes; the renderer converts them to the monitor's physical pixel density before glyph rasterization. This keeps layout stable while avoiding bitmap enlargement on high-DPI displays.

## Standard type ramp

| Public tier | Integer value | Logical EM size | Intended role |
|---|---:|---:|---|
| `TextScale.caption` | 1 | 13 px | secondary labels, metadata, status text |
| `TextScale.body` | 2 | 17 px | controls, menus, editors, ordinary labels |
| `TextScale.heading` | 3 | 22 px | section headings and prominent content |
| `TextScale.display` | 4 | 30 px | large titles and display samples |

The constants `UiFontSizeCaption`, `UiFontSizeBody`, `UiFontSizeHeading`, and `UiFontSizeDisplay` expose the mapped logical sizes. `UiFontSizeSmall` remains an alias of the caption size and `UiFontSizeLarge` remains an alias of the heading size for source compatibility.

`fontPixelSize(scale)` maps an Aurora integer scale to its logical EM size. Values above the display tier continue in six-pixel increments. `fontScaleForPixelSize(pixelSize)` returns the closest standard or extended tier.

```d
import aurora;

static assert(fontPixelSize(cast(int) TextScale.caption) == 13);
static assert(fontPixelSize(cast(int) TextScale.body) == 17);
static assert(fontPixelSize(cast(int) TextScale.heading) == 22);
static assert(fontPixelSize(cast(int) TextScale.display) == 30);
```

## Themes and widgets

`Theme.fontScale` defaults to `TextScale.body`. A custom theme can select another default without changing the font face or renderer:

```d
Theme theme = Theme.dark();
theme.fontScale = cast(int) TextScale.body;
auto window = new GuiWindow(WindowOptions.init, theme);
```

A label can override the theme tier:

```d
auto caption = new Label("Last saved 10:42");
caption.setScale(cast(int) TextScale.caption);

auto heading = new Label("Documents");
heading.setScale(cast(int) TextScale.heading);
```

Canvas text APIs continue to accept the integer scale for compatibility:

```d
canvas.drawText(Point(16, 16), "Body text"d, theme.text,
    cast(int) TextScale.body);
```

Aurora 0.4.2 also enlarges surrounding UI metrics so the new type ramp is usable rather than clipped:

- standard control and single-line field height: 38 logical pixels;
- default list row: 44 logical pixels;
- floating-window title bar: 40 logical pixels;
- desktop taskbar: 52 logical pixels;
- desktop icons: 96 by 98 logical pixels;
- icon buttons: 40 logical pixels.

Buttons measure their shaped text through the active `FontSystem` and `TextLayout` when calculating preferred width. This accounts for the real font, fallback, shaping, and icon chrome instead of assuming a fixed width per character.

## DPI behavior

Logical type sizes are converted through `DisplayScale`. At common Windows scales, the 17-pixel body EM is rasterized approximately as follows:

| Windows scale | DPI | Physical body EM |
|---|---:|---:|
| 100% | 96 | 17 px |
| 125% | 120 | 21 px |
| 150% | 144 | 26 px |
| 200% | 192 | 34 px |

The exact integer follows Aurora's coordinate rounding. Text layout remains in logical units; glyph bitmaps and atlas quads are produced at physical size and presented 1:1. Changing monitors can therefore rebuild size-dependent glyph entries without changing document text or widget geometry.

## Font rendering and font files

Typography size is independent of rasterization policy. `FontRenderMode.sharp` remains the default cross-platform grayscale mode, while `FontRenderMode.smooth` preserves unmodified supersampled coverage. Applications can load `.ttf`, `.otf`, and collection faces and can configure ordered fallback collections.

Aurora does not yet execute TrueType bytecode hinting or use RGB LCD subpixel rendering, so very small text may still differ from DirectWrite, CoreText, or a hinted FreeType configuration. The larger body default reduces reliance on the least stable small-size rasterization range without changing that documented boundary.
