#!/usr/bin/env python3
"""Generate the aurora-host experiment protocol constants and reference."""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "protocol" / "aurora-host.api.json"
D_OUTPUT = ROOT / "generated" / "experiment" / "aurorahost" / "protocol.d"
MD_OUTPUT = ROOT / "generated" / "api.md"


def d_string(value: str) -> str:
    return json.dumps(value)


def render_d(schema: dict) -> str:
    lines = [
        "module experiment.aurorahost.protocol;",
        "",
        "/**",
        " * Generated from protocol/aurora-host.api.json.",
        " * Do not edit manually; run tools/generate_reference.py.",
        " */",
        "",
        f'enum ExperimentVersion = {d_string(schema["experimentVersion"])};',
        f'enum ProtocolVersion = {schema["protocolVersion"]};',
        f'enum SchemaVersion = {schema["schemaVersion"]};',
        "",
        "immutable string[] Capabilities = [",
    ]
    for capability in schema["capabilities"]:
        lines.append(f"    {d_string(capability)},")
    lines += [
        "];",
        "",
        "immutable string[] NodeTypes = [",
    ]
    for node_type in schema["nodeTypes"]:
        lines.append(f"    {d_string(node_type)},")
    lines += [
        "];",
        "",
        f'enum MaxSceneDepth = {schema["limits"]["maxSceneDepth"]};',
        f'enum MaxSceneNodes = {schema["limits"]["maxSceneNodes"]};',
        f'enum MaxCanvasCommands = {schema["limits"]["maxCanvasCommands"]};',
        f'enum MaxSurfacePixels = {schema["limits"]["maxSurfacePixels"]};',
        f'enum MaxInputEvents = {schema["limits"]["maxInputEvents"]};',
        "",
        f'enum SurfaceMagic = {d_string(schema["surface"]["magic"])};',
        f'enum SurfaceVersion = {schema["surface"]["version"]};',
        f'enum SurfaceHeaderSize = {schema["surface"]["headerSize"]};',
        f'enum SurfaceInputEventSize = {schema["surface"]["inputEventSize"]};',
        f'enum SurfaceBufferCount = {schema["surface"]["bufferCount"]};',
        "",
    ]
    return "\n".join(lines)


def render_markdown(schema: dict) -> str:
    lines = [
        "# aurora-host experiment protocol",
        "",
        "**Generated from `protocol/aurora-host.api.json`.** Do not edit manually.",
        "",
        f"- Experiment version: `{schema['experimentVersion']}`",
        f"- Protocol version: `{schema['protocolVersion']}`",
        f"- Schema version: `{schema['schemaVersion']}`",
        f"- Max scene depth: `{schema['limits']['maxSceneDepth']}`",
        f"- Max scene nodes: `{schema['limits']['maxSceneNodes']}`",
        f"- Max canvas commands: `{schema['limits']['maxCanvasCommands']}`",
        f"- Max surface pixels: `{schema['limits']['maxSurfacePixels']}`",
        f"- Max input events: `{schema['limits']['maxInputEvents']}`",
        "",
        "## Capabilities",
        "",
    ]
    for capability in schema["capabilities"]:
        lines.append(f"- `{capability}`")
    lines += [
        "",
        "## Window",
        "",
        "| Field | Type |",
        "|---|---|",
    ]
    for field, kind in schema["window"].items():
        lines.append(f"| `{field}` | {kind} |")
    lines += [
        "",
        "## Node types",
        "",
        "| Type | Children | Text | Scale | Spacing |",
        "|---|---|---|---|---|",
    ]
    for name, fields in schema["nodeTypes"].items():
        lines.append(
            "| `{}` | {} | {} | {} | {} |".format(
                name,
                "yes" if fields["children"] else "no",
                "yes" if fields["text"] else "no",
                "yes" if fields["scale"] else "no",
                "yes" if fields["spacing"] else "no",
            )
        )
    if "common" in schema:
        lines += [
            "",
            "## Common node fields",
            "",
        ]
        for field, description in schema["common"].items():
            lines.append(f"- `{field}`: {description}")
    lines += [
        "",
        "## Commands",
        "",
        "| Command | Meaning |",
        "|---|---|",
    ]
    for command, description in schema["commands"].items():
        lines.append(f"| `{command}` | {description} |")
    if "control" in schema:
        lines += [
            "",
            "## Control channel",
            "",
            f"Transport: {schema['control']['transport']}",
            "",
            "| Command | Meaning |",
            "|---|---|",
        ]
        for command, description in schema["control"]["commands"].items():
            lines.append(f"| `{command}` | {description} |")
    if "surface" in schema:
        surface = schema["surface"]
        lines += [
            "",
            "## Shared surface",
            "",
            f"- Magic: `{surface['magic']}`",
            f"- Version: `{surface['version']}`",
            f"- Header size: `{surface['headerSize']}`",
            f"- Input event size: `{surface['inputEventSize']}`",
            f"- Frame buffers: `{surface['bufferCount']}`",
            f"- Input layout: {surface['inputEventLayout']}",
            f"- Frame layout: {surface['frameLayout']}",
        ]
        for name, description in surface.get("semantics", {}).items():
            lines.append(f"- {name}: {description}")
        lines += [
            "",
            "| Header offset | Field |",
            "|---|---|",
        ]
        for field, offset in surface["offsets"].items():
            lines.append(f"| `{offset}` | `{field}` |")
    lines.append("")
    return "\n".join(lines)


def expected_files(schema: dict) -> dict[pathlib.Path, str]:
    return {
        D_OUTPUT: render_d(schema),
        MD_OUTPUT: render_markdown(schema),
    }


def write_files(files: dict[pathlib.Path, str], output_root: pathlib.Path) -> None:
    for target, content in files.items():
        if output_root == ROOT:
            destination = target
        else:
            destination = output_root / target.relative_to(ROOT)
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
        print(f"Wrote {destination}")


def check_files(files: dict[pathlib.Path, str]) -> int:
    problems: list[str] = []
    for target, content in files.items():
        if not target.is_file():
            problems.append(f"missing: {target.relative_to(ROOT)}")
            continue
        if target.read_text(encoding="utf-8") != content:
            problems.append(f"stale: {target.relative_to(ROOT)}")
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        print("run tools/generate_reference.py to refresh the generated reference", file=sys.stderr)
        return 1
    print("generated reference is current")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--output-root", type=pathlib.Path)
    args = parser.parse_args()
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    files = expected_files(schema)
    if args.check:
        return check_files(files)
    write_files(files, args.output_root or ROOT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
