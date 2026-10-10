# Aurora RustDesk 1.0

Aurora RustDesk is a RustDesk-style remote desktop for Windows, built as a
downstream application on the vendored Aurora-D library. Instead of the
link-based invitation used by `aurora-remote`, it connects the way RustDesk
does: every computer has a stable **nine-digit ID**, an **ID (rendezvous)
server** introduces the two computers by that ID, and the controller proves a
short **one-time password** before any desktop, input, clipboard, or file data
moves.

The same single executable can share this computer, control another computer,
or run the ID server and content-blind relay used when neither endpoint accepts
incoming connections.

## Normal use

Open `aurora-rustdesk.exe` on both Windows computers. By default it points at an
ID server on `127.0.0.1:21116`; set the real ID server address under
**Settings** on both computers.

To share this computer:

1. Read **YOUR ID** and the generated **PASSWORD**.
2. Send both to the person helping you (or turn on **Permanent password** under
   Settings for unattended access).
3. Keep Aurora RustDesk running, or enable notification-area and Windows
   startup options.

To control the other computer:

1. Enter the remote **ID** and **PASSWORD**.
2. Select **Connect**.
3. Control the rendered desktop with the mouse and keyboard, drag files or
   folders onto the screen to transfer them, and select **End session** when
   finished.

Recently used IDs are remembered on the current Windows account and recalled
with **Recent IDs**. The local secret, the stored permanent password, and the
recent-ID list are protected with Windows DPAPI.

## Why an ID and a password are enough

The ID server keeps a live map of numeric ID to reachable address while a host
is running. A controller asks the server to resolve the ID, connects to the
resulting endpoint (directly, or through the relay when the host asked for
one), and then proves the password in a mutual HMAC challenge. The server never
sees the password or the session key, and the relay only forwards already
encrypted bytes.

The password is a bearer secret. Use the one-time password for a single
session; use **Permanent password** only for a computer you administer, and
change it when it has been disclosed.

## Running an ID server / relay

Deploy the same executable on a machine reachable by both endpoints:

```text
aurora-rustdesk.exe --server 21116 21117
```

Allow inbound TCP `21116` (ID server) and `21117` (relay). Both desktop
endpoints make only outbound connections. Set the ID server address to that
machine under **Settings** and enable **Use relay** when direct connections are
not possible. The relay pairs the two endpoints using an opaque key and cannot
decrypt the desktop, input, clipboard, or files.

Useful command-line options:

```text
aurora-rustdesk.exe --version          Print the version.
aurora-rustdesk.exe --print-id         Print this computer's numeric ID.
aurora-rustdesk.exe --server [IDP] [RELAYP]   Run the ID server and relay.
aurora-rustdesk.exe --background       Start hidden (used by Windows startup).
```

## Implemented product flows

- Numeric ID discovered through a rendezvous (ID) server, with a LAN/loopback
  direct-endpoint fallback when no server is configured.
- Direct and outbound-only relayed connections; the relay is content-blind.
- Mutual possession proof of the one-time or permanent password followed by
  AES-256-GCM authenticated encryption; replayed or reordered application
  records are rejected.
- Virtual-desktop capture across Windows monitors, delta compression, and
  adaptive 1280×720/30 FPS through 640×360/10 FPS degradation without a stale
  frame queue.
- Mouse movement, buttons, wheel, and keyboard input through `SendInput`.
- Bidirectional, chunked file and recursive folder transfer, including empty
  files and directories. Received data goes to
  `%USERPROFILE%\Downloads\Aurora RustDesk`; traversal and overwrite attempts are
  rejected.
- Explicit bidirectional clipboard send/request (never automatic clipboard
  upload).
- Independent control, file, and clipboard permissions for the shared computer.
- DPAPI-protected identity, permanent password, and recent-ID list.
- Start-with-Windows, background startup, minimize/close to notification area,
  and tray Show/Exit actions.

## Security and Windows boundaries

- Anyone holding the ID and a valid password can connect with the permissions
  enabled for this computer. Treat the password as a bearer secret.
- A public ID server or relay still needs normal host hardening, firewalling,
  availability monitoring, and abuse protection.
- Windows UIPI prevents an unelevated process from injecting input into a
  higher-integrity application. The Windows secure desktop and pre-login screen
  require a signed/elevated service design and are outside this user-session
  executable.
- The low-delay codec is optimized for desktop interaction, not full-motion
  gaming or production video. It uses GDI capture, CPU delta/zlib, and reliable
  TCP; it does not claim GPU capture, hardware H.264/AV1, QUIC, audio, or
  sub-round-trip latency.
- Aurora RustDesk talks its own Aurora protocol. It is RustDesk-style in shape
  (numeric ID, ID server, relay, one-time password) but is not wire-compatible
  with the upstream RustDesk client or its hbbs/hbbr servers.

## Build and verification

Run the complete deterministic acceptance suite:

```text
python build.py --test
```

It builds the application and runs the unit tests plus the core, rendezvous,
session, file-transfer, separate-process, and headless GUI-flow smokes. Create
an optimized release build with:

```text
python build.py --release --test
```

The output is the single `aurora-rustdesk.exe` application. It depends only on
Windows system libraries and the Microsoft runtime supplied by normal supported
Windows installations. `RUN-WINDOWS.bat`, `RUN-WINDOWS-SOFTWARE.bat`, and
`VERIFY-WINDOWS.bat` provide the usual quick-entry points.

## Layout

- `source/app.d` — entry point, tray integration, and `--server` mode.
- `source/aurorarustdesk/identity.d` — numeric ID, secret, and password.
- `source/aurorarustdesk/rendezvous.d` — ID server and ID lookup client.
- `source/aurorarustdesk/protocol.d` — password challenge and encrypted records.
- `source/aurorarustdesk/session.d` — host and controller orchestration.
- `source/aurorarustdesk/relay.d` — content-blind relay server.
- `source/aurorarustdesk/desktop.d`, `framecodec.d`, `quality.d`, `input.d`,
  `clipboard.d`, `transfer.d` — capture, codec, and I/O.
- `source/aurorarustdesk/ui.d` — the Aurora-D share/control interface.
- `tests/` — the acceptance smokes driven by `build.py`.
