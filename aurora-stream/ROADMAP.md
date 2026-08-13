# Aurora Stream roadmap

## Current 0.4.9 quality-validation stage

Do not change the live path again until `RUN-QUALITY-DIAGNOSTIC.bat` identifies a repeated 1080p60 + clean-audio candidate. Encoded 60/1 timestamps and FFmpeg final speed are not acceptance evidence; decoded unique frames, audio continuity, A/V marker drift, and resource headroom are authoritative.

- Process-isolated event-driven WASAPI helper
- Timestamped 20 ms helper-first RTP desktop-audio delivery
- Non-inheritable RTP/RTCP reservations with runtime close-and-reacquire handoff proof
- Bounded FIFO isolation for every live Twitch/YouTube RTMP or RTMPS destination
- Direct FLV reserved for local pacing diagnostics where no network handshake exists
- Independent helper monitor and bounded 12-second FFmpeg startup
- Sanitized single-file live startup diagnostics
- CPU Desktop Duplication compatibility path on the tested GTX 1060 Max-Q system
- Live Twitch/audio acceptance still required before declaring the original stutter fixed

## Historical 0.1 — first complete transport path

- Separate DUB package sharing only Aurora-D
- Common 1080p60 source canvas with optional 1440p60 and 4K60 source modes
- Independent Twitch 1080p60/6000 kbps output
- Independent YouTube 1440p60 default and optional 4K60 output
- Separate scaling, H.264/AAC encoding, FIFO recovery, and endpoint for each destination
- Twitch and YouTube RTMPS fields
- NVENC/QSV/AMF/libx264 selection
- Cursor-safe Windows Desktop Duplication capture with GDI no-cursor fallback
- Separate DirectShow microphone/capture inputs
- Separate Windows Core Audio playback-endpoint enumeration
- Native WASAPI desktop loopback isolated in a helper process and delivered by timestamped RTP
- Standalone D diagnostic comparing DirectShow with Windows playback/recording devices
- Start, stop, live metrics, sanitized diagnostics

## Deliberately out of scope

- Twitch Enhanced Broadcasting and Twitch 2K; Twitch remains fixed to normal 1080p60

## Next — reliable capture and audio

- Windows Graphics Capture for selecting individual monitor/window/game sources
- Extend direct D3D11 handoff to scaled and multi-destination composition without CPU readback
- Native microphone capture owned by D instead of FFmpeg DirectShow
- Bounded video/audio queues
- Clocked audio resampling and drift correction
- Destination reconnect policy
- Independent Twitch and YouTube health reporting
- Bandwidth test mode

## Later — Aurora scene compositor

- Source list and scene list
- Screen/window/game capture, camera, and browser sources
- Position, scale, crop, opacity, visibility, and ordering editors for every source
- Program preview and source selection outlines
- Direct GPU handoff where supported; bounded readback fallback

## Later — practical broadcaster

- Local recording from the same encoded packets
- Per-source gain, mute, meters, and monitoring
- Scene hotkeys and transitions
- Profiles and safe local settings
- Stream-key storage through the Windows credential vault
- Crash recovery and session diagnostics
