# High-DPI rendering

Aurora uses a two-space model:

- **logical coordinates** are the integer widget, layout, hit-test, and text-layout units used at 96 DPI;
- **framebuffer coordinates** are the physical pixels consumed by Vulkan or the software presenter.

`DisplayScale` is the conversion boundary. At 150%, for example, a logical
`800 × 600` client becomes a `1200 × 900` framebuffer. Widgets continue to see
`800 × 600`; render geometry, scissor rectangles, glyph bitmaps, and the native
presentation surface use `1200 × 900`.

```d
import aurora;

WindowOptions options;
options.width = 800;
options.height = 600;
auto window = new GuiWindow(options);

const scale = window.displayScale();
const logical = window.logicalClientSize();
const framebuffer = window.framebufferSize();
```

## Windows Per-Monitor-V2 path

The Win32 adapter performs the following work before and during a window's
lifetime:

1. A shared module constructor requests
   `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2` before application code reaches
   `main`.
2. Older systems fall back to `SetProcessDpiAwareness` and then
   `SetProcessDPIAware` when the newer entry point is unavailable.
3. Initial client dimensions are converted from logical units to monitor
   pixels, and `AdjustWindowRectExForDpi` is used when available.
4. `GetDpiForWindow` establishes the actual scale of the window after creation.
5. `WM_DPICHANGED` adopts the new X/Y DPI and applies the suggested window
   rectangle with `SetWindowPos`.
6. `WM_SIZE` reports both the logical client size and physical framebuffer
   extent to `GuiWindow`.
7. Mouse coordinates are converted from physical Win32 client pixels back to
   logical Aurora coordinates before hit testing.
8. The Vulkan swapchain or software surface is rebuilt at the physical extent.
9. Software frames use `SetDIBitsToDevice` for a 1:1 copy rather than asking GDI
   to stretch the completed framebuffer.

The resulting frame path is:

```text
logical widget tree
    → physical DrawList
    → physical glyph atlas quads
    → Vulkan swapchain or ARGB surface
    → 1:1 native presentation
```

Windows therefore does not need to bitmap-enlarge a 96-DPI Aurora frame at
125%, 150%, 175%, or 200% scaling.

## Standalone builds, portable CRT, and optional manifest embedding

Aurora's default DUB configurations deliberately do **not** pass
`/manifest:embed` or `/manifestinput`. DMD's bundled `lld-link` can delegate
that operation to the Windows SDK Manifest Tool (`mt.exe`). The normal local
link does not invoke `mt.exe` and works with standalone DMD:

```powershell
dub run --config=desktop
```

Normal local builds use DMD's bundled dynamic runtime. To create a standalone
distributable executable, use the `portable-release` build type:

```powershell
dub build --config=desktop --build=portable-release --compiler=dmd --root=.
```

That build uses `-mscrtlib=libcmt` and needs the MSVC x64/x86 tools and
Universal CRT SDK individual components. The complete Visual Studio C++
workload is not required.

Per-Monitor-V2 remains active because the Win32 module constructor calls
`SetProcessDpiAwarenessContext` before `main`, with older API fallbacks. This
keeps logical coordinates, physical framebuffers, and 1:1 presentation active
without a linked manifest, provided no earlier component has already fixed the
process to another DPI-awareness mode.

The supplied manifest is still useful for final applications that want the DPI
policy recorded in the PE image before any runtime module loads. That path is
explicitly opt-in and requires the Windows SDK. After building an executable,
run:

```powershell
.\scripts\embed-windows-manifest.ps1 .\aurora-desktop.exe
```

DUB normally places build outputs in its cache. To create a conveniently named
local executable first, use:

```powershell
dub build --config=desktop --build=portable-release --compiler=dmd --root=.
.\scripts\embed-windows-manifest.ps1 .\aurora-desktop.exe
```

Alternatively, compile the supplied resource script with `rc.exe` and pass the
resulting `.res` file to your own final link:

```powershell
rc /nologo /fo build\aurora-dpi.res resources\windows\aurora.rc
```

The optional deployment sources are:

- [`resources/windows/aurora.manifest`](../resources/windows/aurora.manifest)
- [`resources/windows/aurora.rc`](../resources/windows/aurora.rc)
- [`scripts/embed-windows-manifest.ps1`](../scripts/embed-windows-manifest.ps1)

### Recovering an extracted 0.3.2 tree

Version 0.3.2 can be repaired locally by deleting every `lflags-windows` block
from `dub.json`, then clearing DUB's cached graph:

```powershell
dub clean
dub run --config=desktop --force
```

Version 0.4.2 already contains that correction.

## Text sharpness

A DPI-correct framebuffer prevents whole-window scaling, but small grayscale
text can still look softer than DirectWrite/ClearType because Aurora does not
execute TrueType bytecode or use LCD-subpixel rendering.

Aurora 0.4.2 provides two portable modes:

```d
WindowOptions options;
options.fontRenderMode = FontRenderMode.sharp; // default
```

```d
window.setFontRenderMode(FontRenderMode.smooth);
```

- `sharp` keeps grayscale antialiasing while increasing intermediate coverage
  contrast;
- `smooth` preserves the original 4×4 supersampled outline coverage.

Both modes rasterize glyphs at the monitor's physical pixel size and submit
integer-aligned atlas quads. Vulkan and software use nearest-neighbor coverage
sampling at that 1:1 size, avoiding a second filtering pass.

The deployment override is:

```text
AURORA_FONT_RENDER_MODE=sharp
AURORA_FONT_RENDER_MODE=smooth
```

## Regression coverage

`tests/dpi_rendering.d` checks:

- 125%, 150%, and 200% logical-to-physical conversion;
- scaled geometry and physical scissor rectangles;
- physical-size glyph atlas entries;
- pixel-snapped text quads;
- physical software-framebuffer dimensions;
- stronger intermediate grayscale contrast in `sharp` mode.

Run it directly with:

```sh
dub run --config=dpi-rendering-test
```

The release matrix also cross-compiles the complete Win32 application graphs.
Native Windows execution remains a separate validation boundary and should
cover mixed-DPI monitor transitions, maximize/restore, and both renderer modes.

## Primary Windows references

- [High DPI desktop application development on Windows](https://learn.microsoft.com/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows)
- [Setting the default DPI awareness for a process](https://learn.microsoft.com/windows/win32/hidpi/setting-the-default-dpi-awareness-for-a-process)
- [`WM_DPICHANGED`](https://learn.microsoft.com/windows/win32/hidpi/wm-dpichanged)
- [`SetProcessDpiAwarenessContext`](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-setprocessdpiawarenesscontext)
