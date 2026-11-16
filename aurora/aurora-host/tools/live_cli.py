#!/usr/bin/env python3
"""Send one JSON request to a running host control socket."""
from __future__ import annotations

import argparse
import json
import socket
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "request",
        help="JSON object, for example '{\"command\":\"ping\"}'",
    )
    parser.add_argument("--port", type=int, default=8791)
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument(
        "--out",
        help="screenshot path; implies command=screenshot",
    )
    args = parser.parse_args()

    try:
        request = json.loads(args.request)
    except json.JSONDecodeError:
        request = {"command": args.request}
    if isinstance(request, str):
        request = {"command": request}
    if not isinstance(request, dict):
        raise RuntimeError("request must be a JSON object")
    if args.out:
        request.setdefault("command", "screenshot")
        request["path"] = args.out

    with socket.create_connection(
        ("127.0.0.1", args.port), timeout=args.timeout
    ) as connection:
        connection.sendall(
            (json.dumps(request, ensure_ascii=False) + "\n").encode("utf-8")
        )
        stream = connection.makefile("rb")
        response = None
        for line in stream:
            text = line.decode("utf-8").rstrip("\r\n")
            if text.startswith("EVENT "):
                continue
            if text.startswith("RESPONSE "):
                response = json.loads(text[9:])
                break
            if text:
                response = json.loads(text)
                break
        if response is None:
            raise RuntimeError("host closed the connection")

    print(json.dumps(response, indent=2, ensure_ascii=False))
    return 0 if response.get("ok", False) else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"live command failed: {error}", file=sys.stderr)
        raise SystemExit(1)
