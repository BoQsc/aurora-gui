# Aurora Remote 1.0

Aurora Remote is a symmetric Windows remote-control application. The same
single executable can share a computer, control another computer, or run the
optional public relay used when neither endpoint accepts incoming connections.

## Normal use

Open `aurora-remote.exe` on both Windows computers.

To share this computer:

1. Leave **Allow connections** enabled.
2. Select **Copy connection link** and send the private link to the intended
   controller.
3. Keep Aurora Remote running, or enable its notification-area and Windows
   startup options for unattended access.

To control the other computer:

1. Paste its `aurora://connect/...` link.
2. Select **Connect**.
3. Control the rendered desktop with the mouse and keyboard. Use the toolbar or
   drag and drop to transfer data, and select **End session** when finished.

Successful permanent connections can be stored on the current Windows account
and recalled with **Use saved computer**. Stored peer links, the local identity,
and the unattended secret are protected with Windows DPAPI.

## Why the link is enough

There is no separate computer-ID lookup. The connection link encodes the
transport, reachable direct or relay address, port, device identity, expiry,
permissions, and a cryptographically random authentication secret. That is the
discovery data the other executable needs. Treat a link as a private bearer
capability.

Ordinary links expire after ten minutes. A permanent unattended key does not
expire; rotate it in **Connection settings** to revoke every saved copy.

## Internet connections

Direct mode is appropriate on a LAN or when the host's TCP port is reachable
through its firewall/router. For arbitrary Internet/NAT locations, deploy the
same executable on a publicly reachable machine:

```text
aurora-remote.exe --relay 47832
```

Allow inbound TCP port 47832, then enter that machine's DNS name and port under
**Connection settings**, enable **Use relay**, and create a new link. Both
desktop endpoints make outbound connections. The relay pairs them using an
opaque identifier and forwards encrypted bytes; it never receives the session
key and cannot decrypt the desktop, input, clipboard, or files.

A public relay hostname is infrastructure, not information that can be invented
inside a key. The key does carry the selected relay endpoint, so the receiver
does not need to configure or discover it separately.

## Implemented product flows

- One executable and one connection-link workflow for hosting and controlling.
- Direct and outbound-only relayed connections.
- Mutual possession proof followed by AES-256-GCM authenticated encryption;
  replayed or reordered application records are rejected.
- Virtual-desktop capture across Windows monitors, delta compression, and
  adaptive 1280×720/30 FPS through 640×360/10 FPS degradation without a stale
  frame queue.
- Mouse movement, buttons, wheel, and keyboard input through `SendInput`.
- Bidirectional, chunked file and recursive folder transfer, including empty
  files and directories. Received data goes to
  `%USERPROFILE%\Downloads\Aurora Remote`; traversal and overwrite attempts are
  rejected.
- Explicit bidirectional text clipboard send/request (never automatic clipboard
  upload).
- Ten-minute attended links and rotatable permanent unattended keys with
  independent control, file, and clipboard permissions.
- DPAPI-protected identity, persistent key, saved peers, and settings.
- Start-with-Windows, background startup, minimize/close to notification area,
  and tray Show/Exit actions.
- Interactive sockets use `TCP_NODELAY` and keepalive. The stream degrades before
  connectivity loss while input/control remain available.

## Security and Windows boundaries

- Anyone holding an unexpired link has the permissions encoded in it. Share it
  only with the intended person and rotate permanent keys after suspected
  disclosure.
- The relay is deliberately content-blind, but a public deployment still needs
  normal host hardening, firewalling, availability monitoring, and abuse
  protection.
- Windows UIPI prevents an unelevated process from injecting input into a
  higher-integrity application. The Windows secure desktop and pre-login screen
  require a signed/elevated service design and are outside this user-session
  executable.
- The current low-delay codec is optimized for desktop interaction, not
  full-motion gaming or production video. It uses GDI capture, CPU delta/zlib,
  and reliable TCP; it does not claim GPU capture, hardware H.264/AV1, QUIC,
  audio, or sub-round-trip latency.

## Build and verification

Run the complete deterministic acceptance suite:

```text
python build.py --test
```

It builds the application and tests cryptography/capsules, direct reconnect,
separate host/controller processes exchanging real video and input, relay
pairing, recursive transfer, clipboard, permanent-key restart and permissions,
saved peers, and the complete GUI flow including invalid-link recovery.

Create an optimized release build with:

```text
python build.py --release --test
```

The output is the single `aurora-remote.exe` application. It depends only on
Windows system libraries and the Microsoft runtime supplied by normal supported
Windows installations.
