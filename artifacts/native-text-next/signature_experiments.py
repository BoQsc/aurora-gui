"""Test Microsoft's documented legacy instruction-function signatures."""
import concurrent.futures
import json

from diagnose import measure, variants, HERE


def signature_variant(source, vacuform=True, spacing=True):
    source = source.replace("    bool composite;\n    ", "    bool composite;\n    uint iupAxes;\n    ", 1)
    marker = "    ref Zone zone0Ref()"
    helper = """    bool functionStarts(int number, const(ubyte)[] signature)
    {
        if (number < 0 || number >= fdefs.length || !fdefs[number].active) return false;
        const def = fdefs[number];
        return def.end >= def.start + signature.length &&
            def.body[def.start .. def.start + signature.length] == signature;
    }

    long readStore(int location)
    {
        if (naturalGrid && glyphProgram && (instructControl & 4) == 0)
        {
"""
    if vacuform:
        helper += """            if (location == 8 && iupAxes == 3 &&
                functionStarts(0, [0x45, 0x23, 0x46, 0x60, 0x20, 0xB0, 38])) return 0;
"""
    if spacing:
        helper += """            if (location == 24)
                foreach (number; [0, 1, 2, 4, 7, 8])
                    if (functionStarts(number, [0x01, 0xB0, 24, 0x43, 0x58]) ||
                        functionStarts(number, [0x01, 0x18, 0xB0, 24, 0x43, 0x58])) return 0;
            if (location == 22)
                foreach (number; [64, 65, 66])
                    if (functionStarts(number, [0xB0, 22, 0x43, 0x58])) return 0;
"""
    helper += """        }
        return location >= 0 && cast(size_t) location < storage.length ? storage[location] : 0;
    }

"""
    source = source.replace(marker, helper + marker, 1)
    source = source.replace("ctx.push(loc >= 0 && cast(size_t) loc < ctx.storage.length ? ctx.storage[loc] : 0);",
                            "ctx.push(ctx.readStore(loc));")
    source = source.replace("                interpolateUntouchedPoints(ctx, (opcode & 1) != 0);",
                            "                ctx.iupAxes |= 1u << (opcode & 1);\n                interpolateUntouchedPoints(ctx, (opcode & 1) != 0);")
    assert "uint iupAxes;" in source
    return source


def main():
    sources = variants()
    cases = {"vacuform": signature_variant(sources["C"], spacing=False),
             "spacing": signature_variant(sources["C"], vacuform=False),
             "signatures": signature_variant(sources["C"]),
             "signatures-cutin": signature_variant(sources["both-cutin"])}
    records = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for future in concurrent.futures.as_completed([pool.submit(measure, name, source) for name, source in cases.items()]):
            name, rows = future.result()
            records[name] = rows
    baseline = json.loads((HERE / "cutin-experiments.json").read_text())["comparisons"]["C"]
    summaries = {}
    for name, rows in records.items():
        summaries[name] = {"improved": sum(a["monitor_error"] < b["monitor_error"] for a,b in zip(rows,baseline)),
                           "regressed": sum(a["monitor_error"] > b["monitor_error"] for a,b in zip(rows,baseline)),
                           "equal": sum(a["monitor_error"] == b["monitor_error"] for a,b in zip(rows,baseline)),
                           "monitor_mean": sum(a["monitor_error"] for a in rows)/len(rows),
                           "neutral_mean": sum(a["neutral_error"] for a in rows)/len(rows)}
    (HERE / "signature-experiments.json").write_text(json.dumps({"default_changed":False,
        "summary":summaries, "comparisons":records},indent=2),encoding="utf-8")
    print(json.dumps(summaries,indent=2))


if __name__ == "__main__":
    main()
