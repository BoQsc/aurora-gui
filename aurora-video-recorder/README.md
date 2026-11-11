# Aurora Video Recorder

Quick MP4 screen recording for Windows, built with
[Aurora-D](../vendor/aurora-d-0.4.5). One window, one **Record** button: pick
what to record, press Record, press Stop, and the file is ready to play.

## Run

```
RUN-WINDOWS.bat
```

or

```
dub run --build=release
```

Options:

- `--folder=PATH` - start with PATH as the recording folder.

## Requirements

`ffmpeg.exe` (H.264 + MP4). The recorder looks for it in this order:

1. the `AURORA_RECORDER_FFMPEG` environment variable (full path to `ffmpeg.exe`),
2. `ffmpeg.exe` next to `aurora-video-recorder.exe` (portable drop-in),
3. `ffmpeg.exe` on `PATH` - e.g. `winget install Gyan.FFmpeg`.

If none is found the Record button stays disabled and the status line says so.

## Controls

- **Record / Stop** - start and stop. The timer shows the recorded length.
- **Capture** - *All monitors* records the whole virtual desktop as one video;
  *Primary monitor* records only the primary display. The line below shows the
  exact video size.
- **Frame rate** - 15 / 24 / 30 / 60 fps.
- **Quality** - High (CRF 18), Balanced (23) or Small (28).
- **Draw the mouse cursor in the video** - on by default.
- **Change...** - choose the recording folder (default
  `<Videos>\Aurora Recorder`).
- **Open folder** / **Play last** - open the folder, or the last finished file.

Files are named `Recording-YYYY-MM-DD_HH-MM-SS.mp4`; a second recording in the
same second gets a ` (2)` suffix instead of overwriting.

## How it records

Video only (no audio), H.264 in MP4 with `yuv420p` and a fast-start index.

- **Cursor off** - the app captures the screen itself, 32-bit BGRA frames from
  a GDI `BitBlt`, on a worker thread and pipes them into ffmpeg's stdin. The
  frame rate is paced on a monotonic clock; a late frame is skipped rather than
  duplicated, so audio-free timing stays correct.
- **Cursor on** (default) - the pointer cannot be captured with `BitBlt`, so
  ffmpeg captures the desktop with its `gdigrab` input and `draw_mouse 1`.
  Stopping ends that capture; ffmpeg then writes the MP4 trailer.

Both paths run ffmpeg in a Windows job object with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so ffmpeg cannot outlive the recorder and
keep writing a file. ffmpeg's diagnostics go to `<recording>.mp4.log`.

## Test

```
RUN-HEADLESS-SMOKE.bat
```

Checks the pure logic (capture geometry, even dimensions for `yuv420p`, naming,
command-line quoting, both ffmpeg argument sets) and then, when ffmpeg is
available, records two short clips - one through each capture path - and verifies
with `ffprobe` that each is an H.264 MP4 of the expected size, then decodes it
end to end. Pass `--require-live` to fail instead of skipping when ffmpeg is
missing.

## Limitations

- Windows only.
- Whole-desktop capture records a single image of every monitor, so monitors
  with different heights are padded rather than recorded separately.
- No audio, no region selector; this is meant to be the fastest path to an MP4.
- The recorder's own window is not hidden during a recording; minimise it to keep
  it out of the frames.
