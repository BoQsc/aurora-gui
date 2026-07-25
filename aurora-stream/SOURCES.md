# Direct technical sources

Aurora Stream's transport presets follow these official specifications and manuals.

## Twitch

- Video broadcast overview, stream keys, RTMP URL format, and ingest discovery:
  https://dev.twitch.tv/docs/video-broadcast/
- Current Twitch ingest endpoint list, including the secure global endpoint:
  https://dev.twitch.tv/docs/video-broadcast/reference/
- Twitch broadcasting guidelines, including 1080p60 at 6000 kbps CBR and two-second keyframes:
  https://help.twitch.tv/s/article/broadcasting-guidelines
- Twitch 2K and Enhanced Broadcasting guidance:
  https://help.twitch.tv/s/article/stream-quality
  https://help.twitch.tv/s/article/enhanced-broadcasting

## YouTube

- Recommended live encoder settings, including 1440p60 at 24 Mbps H.264 and 2160p60 at 35 Mbps H.264:
  https://support.google.com/youtube/answer/2853702
- RTMPS ingestion and Live Control Room endpoint usage:
  https://developers.google.com/youtube/v3/live/guides/rtmps-ingestion
- Ingestion protocol comparison; RTMP/RTMPS use H.264 and HLS/DASH are alternatives for high-resolution delivery:
  https://developers.google.com/youtube/v3/live/guides/ingestion-protocol-comparison

## FFmpeg

- FIFO pseudo-muxer, independent output threads, recovery, and overflow behavior:
  https://ffmpeg.org/ffmpeg-formats.html#fifo
- Filter graph, split/asplit, scaling, mapping, and per-output codec options:
  https://ffmpeg.org/ffmpeg-all.html
- Windows capture devices, including `gdigrab` and DirectShow:
  https://ffmpeg.org/ffmpeg-devices.html
- FFmpeg resampler options, including asynchronous timestamp compensation:
  https://ffmpeg.org/ffmpeg-resampler.html
- FFmpeg input wall-clock timestamping, output interleave buffering, immediate packet flushing, input queues, and per-stream frame-rate mode:
  https://ffmpeg.org/ffmpeg-all.html
- FFmpeg `fps`, `setpts`, and `asetpts` filters used to create exact frame-count and sample-count timelines:
  https://ffmpeg.org/ffmpeg-filters.html

## D

- Standard-library process creation, pipes, termination, and waiting:
  https://dlang.org/phobos/std_process.html
- Standard-library JSON parsing and serialization used for saved settings:
  https://dlang.org/phobos/std_json.html
- Standard-library file operations used for settings replacement and recovery:
  https://dlang.org/phobos/std_file.html

## Windows audio diagnostics

- Windows playback and recording device counts/capabilities through WinMM:
  https://learn.microsoft.com/en-us/windows/win32/api/mmeapi/nf-mmeapi-waveingetnumdevs
  https://learn.microsoft.com/en-us/windows/win32/api/mmeapi/nf-mmeapi-waveoutgetnumdevs
- Windows audio endpoint enumeration through MMDevice API:
  https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/nf-mmdeviceapi-immdeviceenumerator-enumaudioendpoints
- WASAPI loopback capture for recording audio played by a render endpoint:
  https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording
- Opening a shared-mode audio client, applying loopback/event-callback flags, and the requirement that event-driven shared mode use zero buffer duration and periodicity:
  https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-initialize
- Event-driven loopback support on Windows 10 1703 and newer:
  https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording
- Associating the audio engine with a client event handle:
  https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-seteventhandle
- Reading packets from an initialized capture stream:
  https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nn-audioclient-iaudiocaptureclient
- DUB single-file package execution used by the diagnostic launcher:
  https://dub.pm/dub-guide/single/

- Windows Desktop Duplication source (`ddagrab`): returns D3D11 hardware frames intended for on-GPU processing/encoding; `hwdownload` is required only for software processing. The official example encodes `ddagrab` directly with `h264_nvenc`, and the manual warns that `ddagrab` has no background buffering when it is not polled quickly enough:
  - https://ffmpeg.org/ffmpeg-all.html#ddagrab
- FFmpeg UDP input options used by the nonblocking localhost PCM bridge, including receive `buffer_size`, `pkt_size`, `fifo_size`, and `overrun_nonfatal`:
  - https://ffmpeg.org/ffmpeg-protocols.html#udp
- FFmpeg raw PCM inputs contain samples but no embedded timestamp metadata. Aurora Stream applies arrival wall-clock timestamps at the UDP input, bounded drift correction, and then rebuilds the final 48 kHz sample-count timeline:
  - https://ffmpeg.org/ffmpeg-formats.html
  - https://ffmpeg.org/ffmpeg-resampler.html
- Reproduced FFmpeg `gdigrab` cursor-flicker/focus-loss defect and the documented `draw_mouse 0` workaround:
  - https://ffmpeg.org/pipermail/ffmpeg-trac/2025-May/073649.html

## A/V pacing diagnostic

- FFmpeg machine-readable `-progress` output and `-stats_period` update interval:
  https://ffmpeg.org/ffmpeg.html
- FFprobe packet/frame inspection and selective `-show_entries` output:
  https://ffmpeg.org/ffprobe.html
- FFmpeg formats/muxers, including hash/checksum output and FIFO behavior:
  https://ffmpeg.org/ffmpeg-formats.html
