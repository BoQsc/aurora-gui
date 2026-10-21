# Aurora host module contract

Status: experimental, contract version 1. This contract is bound to
`protocolVersion` 9, `schemaVersion` 2, and shared-surface version 2. A change
to required module behavior updates this document and the corresponding
generated version when the control or surface semantics change.

This document is normative for an out-of-process module that integrates with
`aurora-host-experiment`. It does not make the host own application policy.
The host remains a leaf and never loads a module into its process.

## Ownership

The host owns the window, retained scene tree, layout, painting, input routing,
frame clock, DPI scaling, staleness policy, and the control/surface transport.

A module owns its domain state, its scene content, its offscreen rendering, and
its own process lifecycle. A browser, editor, game, or media pipeline is a
module; it must not be added to the host package.

An in-process widget is not a module. New node types remain subject to
[RESPONSIBILITY.md](RESPONSIBILITY.md) and must describe host-owned UI behavior,
not application content.

## Required handshake

Before publishing a frame, a module must:

1. Run the host with `--version` and verify the experiment, protocol, and
   schema versions it was built for.
2. Run `--capabilities` and verify the capabilities it requires. A module using
   the shared surface requires at least `control-stdin`, `shared-surface`,
   `surface-diagnostics`, `surface-dpi`, `surface-input-reserve`, and
   `surface-stale-policy`.
3. Start the host with `--run <scene> --control`, wait for `READY`, and read
   `status`, `inputmap`, and `surface` before assuming a frame is visible.
4. Reject an unknown capability set or a surface version/header/event layout it
   does not implement. Do not guess numeric key, button, modifier, or event
   codes; use `inputmap`.

The version and capabilities output are line-oriented text. Control responses
and events are JSON lines. A module may use a client library, but it must
preserve these wire contracts.

## Lifecycle

The required lifecycle is:

```text
Created -> Handshaking -> Mapped -> Live <-> Stale
                              |        |
                              +-> Failed <+
                                      |
                                   Closed
```

- **Created:** the module has written its scene and, if needed, its initial
  surface file. The scene names the surface path, logical width and height,
  optional `staleMs`, and event opt-ins.
- **Handshaking:** the host has printed `READY`; the module has verified
  versions/capabilities and is waiting for `surface` to report `mapped:true`.
- **Mapped:** the host has accepted the mapping and reports the expected
  logical/native dimensions. The module publishes an initial frame.
- **Live:** the host has acknowledged the frame through `hostReadSeq` and copies
  new frames on its normal tick. Input is available in the ring.
- **Stale:** no new frame arrived within `staleMs`. The host keeps the last
  visible image but reports `stale:true` and `frameAgeMs`. The module must either
  publish a fresh frame or deliberately stop.
- **Failed:** mapping or validation failed. The host reports `mapped:false`,
  an `error`, and `retryInMs`; it invalidates the surface pixels so an old image
  cannot survive a malformed replacement. A module must repair the file or
  recreate it, then wait for a new successful mapping. It must not busy-loop
  faster than `retryInMs`.
- **Closed:** the module stops publishing, closes its mapping, sends `close`,
  and waits for the host process to exit. The module owns the surface file and
  may delete it only after the host has closed.

The host does not launch, supervise, restart, or sandbox modules. If a module
needs fault isolation, readiness supervision, crash recovery, or orphan
cleanup, it owns that supervisor outside the host.

## Control channel

The control channel is one JSON object per line on stdin/stdout:

- Host output is `READY`, `RESPONSE {json}`, or `EVENT {json}`.
- A request has a unique `id`; the matching response has the same `id`.
- The host processes commands on its UI thread. Modules must not mutate widgets
  from their render thread or through shared memory.
- `status` reports the window and framebuffer dimensions.
- `surface` reports mapping state, frame sequence, `hostReadSeq`, input
  head/tail, coalescing/drop counters, frame age, stale state, and DPI fields.
- `screenshot` is a diagnostic/test operation, not a per-frame transport.

## Shared-surface rules

The surface is a versioned, little-endian memory-mapped file. The generated
[API reference](generated/api.md) is authoritative for offsets and layouts.

A writer must:

1. Fill an inactive buffer completely.
2. Publish the inactive index and then increment `frameSeq`, in that order.
3. Wait until `hostReadSeq` covers that sequence before reusing that buffer.
4. Never mutate the active buffer while the host may read it.

Scene `width` and `height` are logical extents. Header dimensions are native
RGBA pixels. The host scales native pixels into the logical bounds. Input
coordinates in the ring are logical surface coordinates.

Input ring rules:

- The host appends events at `inputTail`; the module reads from `inputHead` and
  advances `inputHead` after consuming each event.
- `head == tail` means empty. `tail - head == inputCapacity` means full.
- Up to eight slots are reserved for discrete key, button, and wheel events;
  smaller rings reserve roughly a quarter, with at least one slot when capacity
  is greater than one.
- Adjacent identical pointer moves may be coalesced. The counters
  `inputCoalesced`, `inputDroppedMoves`, and `inputDroppedDiscrete` are
  diagnostic state and must not be interpreted as input content.

The current input kinds are pointer down/move/up, wheel, key down, and key up.
Focus/blur, IME composition, drag/drop, and clipboard events are not part of
this contract version. A module that requires them needs a newer contract.

## Failure and shutdown

- A missing file, open failure, wrong magic, wrong version, or wrong header
  layout is a recoverable mapping failure unless the module chooses to stop.
- A malformed replacement of a live mapping must be treated as a failure, not
  as a frame. The host invalidates the pixels; the module must remap and publish
  a new frame before reporting healthy.
- A module must handle host exit, stdin close, and a failed `close` command.
  It must not leave a child host process running.
- The host is not responsible for module crashes or for restarting a module.

## Conformance

Run:

```text
python tools/module_contract_test.py
```

The test verifies the handshake, capability set, mapping, frame
acknowledgement, pointer/key ring delivery, stale detection and recovery,
malformed-map recovery, and clean shutdown. The recipe
`.aurora/verify-modules.json` runs it after a fresh host build.

## Explicit non-goals

Contract version 1 does not provide a native plugin ABI, GPU-shared textures or
compositor handoff, audio/video services, focus/IME/accessibility protocol,
drag/drop or clipboard events, a stable binary ABI, a socket transport, client
language bindings, sandboxing, or a packaged WebView2 host. Those require a new
contract and, where observable, a protocol or surface version bump.