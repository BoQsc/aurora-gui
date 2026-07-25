# Aurora Cut 0.13.5

Aurora Cut is a lightweight multi-track MP4/MP3 editor written in D with the supplied Aurora-D 0.4.5 graphics library and FFmpeg. Aurora draws the desktop interface and RGB timeline monitor. FFmpeg supplies probing, decoding, live composition, effects, audio mixing, and final encoding.

## Windows quick start

Extract the ZIP into a **new folder**. Do not merge it over an older Aurora Cut folder. Open Command Prompt in the inner folder containing `dub.json`, then run:

```bat
BUILD-WINDOWS.bat
```

Later launches:

```bat
RUN-WINDOWS.bat
```

Display-driver fallback:

```bat
RUN-WINDOWS-SOFTWARE.bat
```

Required commands:

```bat
dmd --version
dub --version
ffmpeg -version
ffprobe -version
```

`ffplay` is optional but required for audible Preview output:

```bat
ffplay -version
```

## Timeline-first workflow

- Import MP4 and MP3 using `Ctrl+I`, the Project Media right-click menu, or Windows File Explorer drag-and-drop.
- Drag files **directly from Windows File Explorer onto a V or A timeline track**. Probing remains asynchronous; when a new item finishes importing, it is inserted at the requested track and time.
- Drag Project Media items onto V1/V2… or A1/A2… tracks.
- A video item keeps embedded audio inside its V-track clip by default. Enable **Show embedded audio on matching A track** for a display-only waveform, or right-click the item and choose **Detach audio to separate A track** for a real independently editable audio item.
- Drag a clip horizontally to change sequence time or vertically to move it to another compatible track. Dropping beyond existing lanes creates another track.
- Drag either clip edge to shorten or extend it. Text duration is freely resizable; media clips trim or reveal available source time without crossing neighbors.
- Use `Ctrl+C`, `Ctrl+V`, and `Ctrl+D` to copy, paste, and duplicate selected timeline clips.
- Track heights, the compact V1/A1 label column, the workspace, Sequence panel, and Inspector are resizable.
- A compact scrollbar below the tracks pans the visible time range without changing timeline zoom; its thumb size shows how much of the sequence is currently visible.
- Use Selection for normal editing and Cut to split at a click. With Selection active, double-click empty sequence space, hold the second press, and drag a marquee to select every timeline item touched by the rectangle.
- The Text tool creates nothing from a click alone. Click-drag across an empty video-track span to define the title's exact start and duration; after successful creation it returns to Selection.

The visible Project Media Import and Add-selected buttons were removed. Context menus are compact 22-pixel-row menus rather than oversized panels. Drag-and-drop, `Ctrl+I`, and context commands provide the same operations without permanent toolbar clutter. The transport has one Play/Pause/Resume control; stopping remains available through `Esc` or the Preview context menu rather than a separate Stop button.

## Composition Preview is always the current sequence

Composition Preview is the timeline monitor. Selecting or double-clicking Project Media changes metadata only; it cannot lock the monitor to an isolated source item.

- Play/Pause/Resume, Space, and P control the current sequence.
- The playhead is the single source of timeline time for clicking, dragging, scrubbing, pausing, finishing playback, Inspector evaluation, keyframe placement, and export In/Out.
- A plain unchanged one-video sequence uses direct source decoding for immediate response while preserving sequence timing.
- Layered, transformed, animated, text-based, or separately mixed sequences stream from the real FFmpeg composition graph without waiting for a complete MP4 proxy render.
- Paused frames, scrubbing, active playback, and export use the same transform/effect expressions. Interactive preview may use a lower working resolution, but layout, timing, text scale, effects, and animation remain composition-relative.
- Double-click a title to edit that same live title object directly in Composition Preview. There is no second input-field copy and no title burned into the RGB background. The title's own shaped glyph layout supplies painting, caret placement, per-character selection, word/line selection, hit testing, keyboard input, clipboard operations, and undo. The inline toolbar includes the authoritative checked font dropdown.
- While any text field is focused, Space and other bare timeline shortcuts are suppressed and remain normal text input.

## Effects, properties, defaults, and animation

The scrollable Inspector now shows **only controls that apply to the selected timeline item**. Empty selections no longer leave a wall of inactive sliders, and audio-only items do not show composition or text controls.

Every effect/property uses a compact **labeled numeric value field** rather than a long anonymous slider. Click a value to type it exactly, or click-hold and move horizontally to scrub it; hold Shift for fine adjustment. Each value has a **Reset** button and—when animatable—a clearly labeled **◇ Key** button:

- **Audio:** selected-item gain from −60 dB to +12 dB and mute. Embedded-audio display/detach commands live in the selected timeline item’s context menu rather than polluting the Inspector.
- **Transform / composite:** Position X/Y, Scale, Rotation, Opacity.
- **Style effects:** Blur, Stroke width/color, Drop-shadow opacity/blur/X/Y/color.
- **Edge transitions:** Fade in and Fade out.
- **Text items:** background box, stroke, shadow, and other item effects. Text content and the most-used typography controls live directly over the selected title in Composition Preview rather than duplicating a content field in the Inspector.

**Reset selected item to defaults** restores that item's effect defaults while preserving timing, source, and text content. The timeline item context menu provides the same complete reset.

A **◇ Key** button adds a keyframe for that selected item at the playhead. It becomes **◆ Key** when a key exists at the current time. Once a property is animated, changing it at another sequence time automatically creates or updates the keyframe there. Timeline items display keyframe symbols at their exact times.

Right-click a keyframe symbol to:

- remove the keyframe;
- use Linear interpolation;
- use Bezier interpolation;
- use Hold interpolation.

Keyable properties are audio gain, position X/Y, scale, rotation, opacity, and text size. Clip-edge resizing preserves animation at the same absolute sequence moments and retains interpolation modes.

## Text and canvas editing

- Click an existing visible video/text layer in Composition Preview to select it without changing the monitor away from the sequence.
- Drag the selected layer in Preview to change Position X/Y.
- Double-click a text layer in Preview or on the timeline to edit the text **directly over the composed title**. No duplicate text-content field is shown in Effects / Properties.
- A compact strip appears immediately above the selected title with **B**, **I**, **U**, text size, font family, text color, and Done. Changes update only that selected timeline item and are coalesced into background preview refreshes while typing.
- Common Windows families—including Segoe UI, Arial, Calibri, Consolas, Georgia, Times New Roman, Impact, Tahoma, and Verdana—use explicit files from `C:\Windows\Fonts` so FFmpeg cannot silently render every family with the same fallback face.
- Text items are green on the timeline and show their current text with an ellipsis when the item is too narrow.
- The default 24-pixel track height leaves normal item text fully visible; each track remains independently resizable by dragging its border.

## Responsiveness and caching

- Import and FFprobe work run outside the UI thread. Source-frame preparation starts as soon as media appears in Project Media, not when playback is first requested.
- Source and composition still frames use separate bounded LRU caches.
- Rapid playhead/scrub requests are coalesced; stale FFmpeg jobs are cancelled rather than queued.
- Continuous Inspector and inline-title gestures detach timeline storage once per gesture instead of cloning a large track for every value scrub or text event.
- Property and typography edits update the model immediately. Static-frame requests are coalesced to roughly eight refreshes per second while a control is moving or text is being typed, so the displayed composition catches up continuously without blocking input or launching a full-sequence render.
- Live decoding uses reusable RGB buffers and drops stale queued frames to prioritize current playback over latency.
- Timeline hit-testing, visible-range lookup, snapping, and painting use sorted or binary-searched data and visit only visible clips. Automated coverage includes a 20,000-clip track.
- Import, export, probing, and composition processes are cancellable background work. Mute, gain, transforms, keyframes, copy/paste, clip movement, and edge resizing do not synchronously render a full sequence.

## GPU acceleration—precise scope

At startup Aurora Cut performs a real tiny encode test and selects the first usable H.264 encoder:

- NVIDIA NVENC
- Intel Quick Sync
- AMD AMF
- `libx264` fallback

The status line reports the selected H.264 path. Hardware acceleration currently covers **H.264 encoding**. The FFmpeg overlay/effect graph and Aurora RGB preview presentation remain CPU/software paths. Aurora Cut does not claim full-GPU timeline composition in 0.11.2.

## Project files

- Use the compact **Save** command, `Ctrl+S`, or the Project Media context menu to save an `.auroracut` project.
- `Ctrl+Shift+S` saves under another name, and `Ctrl+O` opens an existing project.
- Project files preserve Project Media metadata, all tracks and track heights, clip timing, text/font/style data, effects, keyframes and interpolation, playhead position, Preview quality, and Export In/Out.
- Media metadata is stored in the project so reopening does not synchronously block the interface on FFprobe.

## Export

Use **Export MP4** or right-click it for Export MP3 and range commands:

- MP4: H.264 video, AAC stereo audio, yuv420p, fast-start metadata.
- MP3: mixed audible sequence audio.
- Set Export In/Out at the playhead to export only a selected sequence range.
- Embedded V-track audio is included unless the clip or track is muted.

## Useful controls

- `Ctrl+S`: save project
- `Ctrl+Shift+S`: save project as
- `Ctrl+O`: open project
- `Ctrl+I`: import media
- `Ctrl+E`: export MP4
- `Ctrl+Shift+E`: export MP3
- `Ctrl+C` / `Ctrl+V`: copy / paste selected timeline clip
- `Ctrl+D`: duplicate selected timeline clip
- `Space` or `P`: play/pause/resume timeline
- `Esc`: stop playback or cancel the current drag
- `Ctrl+Z` / `Ctrl+Y`: undo / redo
- `C`: activate the Cut tool
- `R`: activate the Transition tool
- `V`: return to the Selection tool
- `S`: split selected clip at playhead
- `Delete`: delete selected clip
- `Ctrl+mouse wheel` over timeline: zoom
- `Shift+mouse wheel` over timeline: horizontal scroll
- Drag the compact bar below the timeline: horizontal scroll without changing zoom

## Developer verification

```sh
DC=ldc2 ./scripts/verify-model.sh
DC=ldc2 ./scripts/verify-renderer.sh
DC=ldc2 ./scripts/verify-playback-stress.sh
DC=ldc2 ./scripts/verify-headless.sh
DC=ldc2 ./scripts/verify-export.sh
python3 ./scripts/verify-title-architecture.py
dub clean
dub build --compiler=ldc2 --build=debug
```

See `VALIDATION.md` for tested paths and the Windows validation boundary. Aurora-D 0.4.5 is vendored under `vendor/aurora-d-0.4.5`; no separate Aurora package is required.


## 0.11.0 workflow additions

- Toggleable subtle timeline snapping beside zoom controls.
- Reverse and 0.5x/1x/2x clip speed commands.
- Transition tool (`R`) for setting fade-in/fade-out by clicking a clip region.
- WAV, FLAC, OGG, PNG, JPEG, WebP, BMP and GIF import.
- File Explorer drops continue to work directly on timeline tracks.
- Context menus open upward from the pointer.
- Space controls playback even after clicking a checkbox; Enter toggles focused checkboxes.
- In× and Out× buttons clear export range points.


## 0.11.1 reliability fix

- Project saving sanitizes transient NaN/Infinity values into safe JSON numbers instead of failing.
- The exact invalid field path and any save/open exception are written to `aurora-cut.log`.
- The visible transport button now always uses one-word labels: Play, Pause, Resume, or Replay.

## 0.11.2 uninterrupted-editing and checklist completion

- Moving, resizing, splitting, or changing a timeline item while sequence playback is running no longer stops or restarts the active video decoder or audio process. Playback continues from its immutable current snapshot; Pause/Resume or the next Play adopts the edited timeline at the same playhead position.
- Composition Preview now includes **Add text** in its right-click menu.
- Selection, Cut, Text, and Transition tools show hover tooltips.
- The Effects / Properties panel no longer contains long sliders. Labeled numeric values support exact typing and horizontal drag-scrubbing, with Shift for fine control.
- Regression coverage verifies that moving a clip during playback starts no replacement decoder and leaves playback active.
