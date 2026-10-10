# Delivery latency checks

After implementation, rebuild through Aurora's rebuild helper, verify the new
image and responsive relaunched window, and test the built image:

```powershell
python aurora-opencode-pro/tests/test_provider_roundtrip.py --production
python aurora-opencode-pro/tests/test_latency_transport.py
python aurora-opencode-pro/tests/test_latency_transport.py --delivery
python aurora-opencode-pro/tests/test_latency_transport.py --delivery --release --vulkan
```

Run from the repository root with DMD on PATH. These use a local provider and
isolated state, without credentials or paid model calls. The production check
executes the rebuilt desktop image in headless mode; the delivery fixture runs
the real Windows message loop, HTTP/SSE client, composer and chat widget tree.
`--release` optimizes the fixture while retaining assertions. `--vulkan` requests
Vulkan; the GUI retains its normal renderer fallback behavior.

The provider waits 100 ms before response headers, then separates first text
and completion by 400 ms. All six first paints must occur before completion,
without tokenizer preflight calls, over one reused TCP connection. The native
wake probe samples 40 worker notifications, checks that their median avoids a
frame sleep, verifies bounded idle ticking, and invokes a retained wake delegate
after window shutdown. Painting measures render submission, not display scanout.

Initial measurements on this workstation, 2026-10-10:

| Fixture | Native wake median | First token to render median |
| --- | ---: | ---: |
| Previous scheduler, debug/software | 14.438 ms | 23.200 ms |
| Interruptible wait, debug/software | 0.146 ms | 7.734 ms |
| Final scheduler, optimized/Vulkan requested | 0.323 ms | 4.196 ms |
| Final scheduler, post-rebuild debug/software recheck | 0.133 ms | 11.679 ms |

Compare rows with matching compiler/renderer settings. These are
small local samples, not universal latency guarantees. Provider/model wait,
request preparation, OS scheduling, layout and GPU/display presentation still
contribute. Recheck after relaunch and retain the printed artifact paths: logs
contain individual stage timings and result JSON includes source/executable
hashes. The frame wait now wakes for worker results and native input; ordinary
invalidation traffic remains paced, and early frames retain the existing frame
deadline. QPC ticks are converted to microseconds before rounding the wait to ms.

The final release rebuild succeeded and relaunched a responsive Aurora window.
The rebuilt image passed the four-round production tool/persistence fixture
(`production-roundtrip-xjz0sjix`), binary SHA-256
`f7b3f80f79dd897675130e7cb272ba1fea8673ba84a71fb3b03fc2a1aa83782c`.
All eight default regression fixtures and transport checks passed. Final delivery
source SHA-256: `4101a89e6126582c4f6a1f1fea826bf3bc2866c895b4d74c31c5734742750b5f`.
Artifact folders: baseline `architecture-checks-txkrvpm8`, optimized
`architecture-checks-pu1mi2p8`, post-rebuild `architecture-checks-p8ikr_8r`.
