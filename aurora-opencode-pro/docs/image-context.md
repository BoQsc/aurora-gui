# Image context and reply latency

Aurora now uses one image policy for file attachments, clipboard images, and
`view_image`. Normal reads preserve the original in the attachment store and
send a derivative capped at 1600 pixels on its longest edge and 512 KiB. Small
images that already fit are kept unchanged. Resizing preserves the aspect ratio.
JPEG orientation is applied before resizing or cropping. GIF inspection uses its
first frame. PNG, JPEG and GIF use the Windows decoder; WebP conversion depends on an installed
codec. A small WebP can pass through, while an oversized unsupported image returns
an error instead of silently sending a large payload.

Normal requests carry at most eight images and 3 MiB of base64 image data. An
explicit original-detail read can use a larger single-image allowance. Labels
identify each image, its original and transmitted dimensions, whether pixels are
included, and the archived original to use for reinspection. Omitted images stay
available; the agent can inspect them individually.

## Later replies

**Settings → Options → Retire images after a successful answer** is enabled by
default. With Tools enabled, a successful completed answer archives earlier image
references from later requests. The answer remains as text context. Originals and
transcript attachments are preserved. Images omitted by a request budget also stay
archived, so they cannot unexpectedly rotate into later text requests.

Cancelled, failed, truncated and ongoing answers retain visual context. Generated
computer-use frames continue to use their existing separate lifetime. Turning the
setting off retains images between subsequent answers; previously archived images
can still be reopened.

The agent can also call `retire_images` during a long task, supplying image IDs and
a useful summary. Retirement follows the active conversation branch and survives
save/reload. Regenerating from before the retirement retains that branch's pixels.

Recorded text is not a substitute for unseen visual details. When a new question
requires those details, the agent should reopen the archived original with
`view_image`, optionally using a crop or explicit original detail.

## Precise inspection

`view_image` accepts exactly one of `filePath` or `attachmentBlob`:

```json
{"attachmentBlob":"<original ID from an image label>","crop":{"x":100,"y":200,"width":800,"height":400},"detail":"original"}
```

Crop coordinates refer to the original dimensions printed in the label. Normal
inputs are limited to 32 MiB and decoded images to 64 megapixels. Explicit original
detail is limited to 4 MiB; larger originals can be inspected through crops.

## Verification

`image_latency_contracts` covers shared normalization, proportional resizing,
original preservation, crop validation, helper IPC, message and byte budgets,
manual and automatic retirement, follow-up requests, persistence, branch scope,
failed/cancelled/truncated answers, and the automatic-retirement opt-out.

An isolated live test on the configured DeepSeek endpoint read the word in a
generated image correctly. The initial request carried 277,660 base64 image bytes;
the following text question carried zero image bytes and answered correctly from
the recorded answer. Observed time to first output was 2.66 seconds initially and
1.14 seconds for the follow-up. These are individual observations, not guaranteed
latency across providers or images. The earlier original-PNG comparison measured
17.12 seconds across two samples; the shared normalization now applies to the tool
path that previously bypassed it.

Run focused checks with:

```text
python tests/run_architecture_checks.py --release image_latency_contracts vision_image_url_check screenshot_history_test flow_resilience_contracts history_preservation_contracts
python tests/test_latency_transport.py --delivery --release
```
