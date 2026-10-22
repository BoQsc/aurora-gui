/**
 * First-party Aurora icon authoring.
 *
 * Generates multi-resolution Windows ICO files from procedural artwork and
 * embeds ICO bytes in a scene as `window.icon` base64. No image library or
 * interpreter is involved: PNG encoding comes from aurora.image and this tool
 * is compiled with the same D installation as the host.
 */
module icon_author;

import aurora.image : RgbaImage, decodeIcoImage, encodePng;
import std.algorithm : equal, min, max;
import std.base64 : Base64;
import std.file : exists, mkdirRecurse, read, write;
import std.json : parseJSON;
import std.math : abs, hypot;
import std.path : dirName;
import std.stdio : stderr, stdout, writeln;
import std.string : indexOf;

version (Windows)
    import experiment.aurorahost.crt.msvcrt_shim;

private enum int[] SIZES = [16, 24, 32, 48, 64, 128, 256];

private alias Sampler = double[4] function(double x, double y) nothrow @safe;

private double[3] mix(double[3] a, double[3] b, double t) nothrow @safe
{
    return [
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
    ];
}

private double roundedRectDistance(double x, double y, double half,
    double radius) nothrow @safe
{
    const qx = abs(x - 0.5) - (half - radius);
    const qy = abs(y - 0.5) - (half - radius);
    return hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - radius;
}

private double segmentDistance(double x, double y, double ax, double ay,
    double bx, double by) nothrow @safe
{
    const dx = bx - ax;
    const dy = by - ay;
    const length2 = dx * dx + dy * dy;
    auto t = ((x - ax) * dx + (y - ay) * dy) / length2;
    t = max(0.0, min(1.0, t));
    return hypot(x - (ax + t * dx), y - (ay + t * dy));
}

private double[4] sampleHost(double x, double y) nothrow @safe
{
    const base = roundedRectDistance(x, y, 0.44, 0.13);
    if (base > 0.0)
        return [0.0, 0.0, 0.0, 0.0];

    auto color = mix([11.0, 18.0, 32.0], [30.0, 41.0, 59.0], y);
    if (abs(base) < 0.022)
        color = mix(color, [34.0, 211.0, 238.0], 0.95);

    const left = segmentDistance(x, y, 0.29, 0.79, 0.50, 0.23);
    const right = segmentDistance(x, y, 0.71, 0.79, 0.50, 0.23);
    const crossbar = segmentDistance(x, y, 0.385, 0.585, 0.615, 0.585);
    const letter = min(left, right) - 0.105;
    const bar = crossbar - 0.075;
    const glyph = min(letter, bar);

    if (glyph <= 0.0)
        color = mix([45.0, 212.0, 191.0], [167.0, 243.0, 208.0],
            (y - 0.23) / 0.56);
    else if (glyph < 0.035)
    {
        const glow = 1.0 - glyph / 0.035;
        color = mix(color, [34.0, 211.0, 238.0], 0.28 * glow);
    }
    return [color[0], color[1], color[2], 255.0];
}

private double[4] sampleNotepad(double x, double y) nothrow @safe
{
    const border = roundedRectDistance(x, y, 0.46, 0.09);
    if (border > 0.0)
        return [0.0, 0.0, 0.0, 0.0];

    auto color = mix([47.0, 120.0, 208.0], [31.0, 87.0, 168.0], y);
    if (abs(border) < 0.02)
        color = mix(color, [89.0, 158.0, 235.0], 0.85);

    const page = max(abs(x - 0.5) - 0.245, abs(y - 0.5) - 0.305);
    if (page <= 0.0)
    {
        color = [255.0, 255.0, 255.0];
        const rule = min(
            segmentDistance(x, y, 0.32, 0.37, 0.68, 0.37),
            min(segmentDistance(x, y, 0.32, 0.49, 0.68, 0.49),
                segmentDistance(x, y, 0.32, 0.61, 0.58, 0.61))) - 0.042;
        if (rule <= 0.0)
            color = [42.0, 111.0, 204.0];
        else if (rule < 0.025)
            color = mix(color, [196.0, 219.0, 244.0], 1.0 - rule / 0.025);
    }
    return [color[0], color[1], color[2], 255.0];
}

private double[4] sampleAlert(double x, double y) nothrow @safe
{
    const edge = roundedRectDistance(x, y, 0.46, 0.10);
    if (edge > 0.0)
        return [0.0, 0.0, 0.0, 0.0];

    auto color = mix([240.0, 120.0, 58.0], [196.0, 42.0, 72.0], y);
    if (abs(edge) < 0.025)
        color = mix(color, [255.0, 205.0, 160.0], 0.85);

    const bar = segmentDistance(x, y, 0.5, 0.235, 0.5, 0.605) - 0.072;
    const dot = hypot(x - 0.5, y - 0.765) - 0.082;
    const mark = min(bar, dot);
    if (mark <= 0.0)
    {
        if (mark < -0.012)
            color = [255.0, 255.0, 255.0];
        else
            color = mix(color, [255.0, 255.0, 255.0],
                1.0 + mark / 0.012);
    }
    return [color[0], color[1], color[2], 255.0];
}

private RgbaImage render(int size, int samples, Sampler sampler)
{
    auto pixels = new ubyte[cast(size_t) size * size * 4];
    foreach (py; 0 .. size)
    {
        foreach (px; 0 .. size)
        {
            double red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
            foreach (sy; 0 .. samples)
            {
                const y = (py + (sy + 0.5) / samples) / size;
                foreach (sx; 0 .. samples)
                {
                    const x = (px + (sx + 0.5) / samples) / size;
                    const sample = sampler(x, y);
                    red += sample[0] * sample[3];
                    green += sample[1] * sample[3];
                    blue += sample[2] * sample[3];
                    alpha += sample[3];
                }
            }
            const offset = (cast(size_t) py * size + px) * 4;
            const count = samples * samples;
            if (alpha > 0.0)
            {
                pixels[offset] = cast(ubyte) (red / alpha + 0.5);
                pixels[offset + 1] = cast(ubyte) (green / alpha + 0.5);
                pixels[offset + 2] = cast(ubyte) (blue / alpha + 0.5);
                pixels[offset + 3] = cast(ubyte) (alpha / count + 0.5);
            }
        }
    }
    return new RgbaImage(size, size, pixels);
}

private void putU16(ref ubyte[] output, ushort value)
{
    output ~= cast(ubyte) (value & 0xff);
    output ~= cast(ubyte) (value >> 8);
}

private void putU32(ref ubyte[] output, uint value)
{
    output ~= cast(ubyte) (value & 0xff);
    output ~= cast(ubyte) ((value >> 8) & 0xff);
    output ~= cast(ubyte) ((value >> 16) & 0xff);
    output ~= cast(ubyte) (value >> 24);
}

private ubyte[] buildIco(Sampler sampler)
{
    ubyte[][] frames;
    foreach (size; SIZES)
        frames ~= encodePng(render(size, size <= 48 ? 8 : 4, sampler));

    ubyte[] output;
    putU16(output, 0);
    putU16(output, 1);
    putU16(output, cast(ushort) frames.length);
    size_t offset = 6 + 16 * frames.length;
    foreach (index, size; SIZES)
    {
        const dimension = size == 256 ? 0 : size;
        output ~= cast(ubyte) dimension;
        output ~= cast(ubyte) dimension;
        output ~= 0;
        output ~= 0;
        putU16(output, 1);
        putU16(output, 32);
        putU32(output, cast(uint) frames[index].length);
        putU32(output, cast(uint) offset);
        offset += frames[index].length;
    }
    foreach (frame; frames)
        output ~= frame;
    return output;
}

private size_t skipSpace(const(char)[] text, size_t at) nothrow @safe
{
    while (at < text.length)
    {
        const ch = text[at];
        if (ch != ' ' && ch != '\t' && ch != '\r' && ch != '\n')
            break;
        ++at;
    }
    return at;
}

private size_t skipString(const(char)[] text, size_t at)
{
    if (at >= text.length || text[at] != '"')
        throw new Exception("expected a JSON string");
    ++at;
    while (at < text.length)
    {
        if (text[at] == '\\')
        {
            at += 2;
            continue;
        }
        if (text[at] == '"')
            return at + 1;
        ++at;
    }
    throw new Exception("unterminated JSON string");
}

private size_t skipValue(const(char)[] text, size_t at)
{
    at = skipSpace(text, at);
    if (at >= text.length)
        throw new Exception("expected a JSON value");
    if (text[at] == '"')
        return skipString(text, at);
    if (text[at] == '{' || text[at] == '[')
    {
        const open = text[at];
        const close = open == '{' ? '}' : ']';
        int depth;
        while (at < text.length)
        {
            if (text[at] == '"')
            {
                at = skipString(text, at);
                continue;
            }
            if (text[at] == open)
                ++depth;
            else if (text[at] == close)
            {
                --depth;
                if (depth == 0)
                    return at + 1;
            }
            ++at;
        }
        throw new Exception("unterminated JSON container");
    }
    while (at < text.length && text[at] != ',' && text[at] != '}'
        && text[at] != ']')
        ++at;
    return at;
}

private bool findMember(const(char)[] text, size_t objectStart, string name,
    out size_t valueStart, out size_t valueEnd)
{
    size_t at = skipSpace(text, objectStart);
    if (at >= text.length || text[at] != '{')
        throw new Exception("expected a JSON object");
    at = skipSpace(text, at + 1);
    while (at < text.length && text[at] != '}')
    {
        const keyEnd = skipString(text, at);
        const key = text[at + 1 .. keyEnd - 1];
        at = skipSpace(text, keyEnd);
        if (at >= text.length || text[at] != ':')
            throw new Exception("expected ':' after a JSON key");
        const start = skipSpace(text, at + 1);
        const end = skipValue(text, start);
        if (key == name)
        {
            valueStart = start;
            valueEnd = end;
            return true;
        }
        at = skipSpace(text, end);
        if (at < text.length && text[at] == ',')
            at = skipSpace(text, at + 1);
        else if (at >= text.length || text[at] != '}')
            throw new Exception("expected ',' or '}' between JSON members");
    }
    return false;
}

private string embedIcon(string sceneText, const(ubyte)[] iconBytes)
{
    // Parse before and after so a malformed scene is never rewritten.
    parseJSON(sceneText);
    size_t windowStart, windowEnd;
    if (!findMember(sceneText, 0, "window", windowStart, windowEnd))
        throw new Exception("scene has no window object");
    if (windowStart >= sceneText.length || sceneText[windowStart] != '{')
        throw new Exception("scene.window must be an object");

    const encoded = Base64.encode(iconBytes);
    size_t iconStart, iconEnd;
    if (findMember(sceneText, windowStart, "icon", iconStart, iconEnd))
    {
        if (sceneText[iconStart] != '"')
            throw new Exception("scene.window.icon must be a string");
        const replacement = "\"" ~ encoded ~ "\"";
        return (sceneText[0 .. iconStart] ~ replacement
            ~ sceneText[iconEnd .. $]).idup;
    }

    const hasMembers = skipSpace(sceneText, windowStart + 1) < sceneText.length
        && sceneText[skipSpace(sceneText, windowStart + 1)] != '}';
    string insertion;
    if (hasMembers)
    {
        size_t lineStart = skipSpace(sceneText, windowStart + 1);
        while (lineStart > 0 && sceneText[lineStart - 1] != '\n')
            --lineStart;
        const indent = lineStart > 0
            ? sceneText[lineStart .. skipSpace(sceneText, windowStart + 1)]
            : "";
        insertion = ("\n" ~ indent ~ "\"icon\": \"" ~ encoded ~ "\",").idup;
    }
    else
        insertion = ("\"icon\": \"" ~ encoded ~ "\"").idup;
    return (sceneText[0 .. windowStart + 1] ~ insertion
        ~ sceneText[windowStart + 1 .. $]).idup;
}

private void writeBase64(const(ubyte)[] bytes, string path)
{
    const directory = dirName(path);
    if (directory.length && !exists(directory))
        mkdirRecurse(directory);
    write(path, Base64.encode(bytes) ~ "\n");
}

private int usage()
{
    stderr.writeln("usage:");
    stderr.writeln("  icon-author --kind host|notepad|alert --out <file.ico>");
    stderr.writeln("  icon-author --scene <scene.json> --icon <file.ico> " ~
        "--scene-out <scene.json>");
    return 2;
}

int main(string[] args)
{
    string kind = "host";
    string outPath, scenePath, iconPath, sceneOut, base64Out;
    const arguments = args.length > 1 ? args[1 .. $] : args[0 .. 0];
    for (size_t index = 0; index < arguments.length; ++index)
    {
        const argument = arguments[index];
        if (argument == "--")
            continue;
        if (argument == "--kind" && index + 1 < arguments.length)
            kind = arguments[++index];
        else if (argument == "--out" && index + 1 < arguments.length)
            outPath = arguments[++index];
        else if (argument == "--scene" && index + 1 < arguments.length)
            scenePath = arguments[++index];
        else if (argument == "--icon" && index + 1 < arguments.length)
            iconPath = arguments[++index];
        else if (argument == "--scene-out" && index + 1 < arguments.length)
            sceneOut = arguments[++index];
        else if (argument == "--base64-out" && index + 1 < arguments.length)
            base64Out = arguments[++index];
        else if (argument == "--help" || argument == "-h")
            return usage();
        else
        {
            stderr.writeln("unknown argument: ", argument);
            return usage();
        }
    }

    try
    {
        if (scenePath.length)
        {
            if (!iconPath.length || !sceneOut.length)
                return usage();
            const sceneText = cast(string) read(scenePath);
            const icon = cast(const(ubyte)[]) read(iconPath);
            const embedded = embedIcon(sceneText, icon);
            const directory = dirName(sceneOut);
            if (directory.length && !exists(directory))
                mkdirRecurse(directory);
            write(sceneOut, embedded);
            if (base64Out.length)
                writeBase64(icon, base64Out);
            writeln("embedded ", iconPath, " in ", sceneOut);
            return 0;
        }

        Sampler sampler;
        final switch (kind)
        {
            case "host": sampler = &sampleHost; break;
            case "notepad": sampler = &sampleNotepad; break;
            case "alert": sampler = &sampleAlert; break;
        }
        if (!outPath.length)
            return usage();
        const icon = buildIco(sampler);
        const directory = dirName(outPath);
        if (directory.length && !exists(directory))
            mkdirRecurse(directory);
        write(outPath, icon);
        if (base64Out.length)
            writeBase64(icon, base64Out);
        writeln("wrote ", outPath, " (", icon.length, " bytes, ",
            SIZES.length, " sizes)");
        return 0;
    }
    catch (Exception error)
    {
        stderr.writeln("icon author failed: ", error.msg);
        return 1;
    }
}

unittest
{
    assert(sampleHost(0.5, 0.5)[3] == 255.0);
    assert(sampleNotepad(0.5, 0.5)[3] == 255.0);
    assert(sampleAlert(0.5, 0.5)[3] == 255.0);
    assert(render(16, 8, &sampleHost).pixels()[(8 * 16 + 8) * 4 + 3] == 255);

    void verifyIcon(const(ubyte)[] icon, string label)
    {
        assert(icon.length >= 6);
        assert(icon[0] == 0 && icon[1] == 0 && icon[2] == 1 && icon[3] == 0);
        const count = icon[4] | (cast(size_t) icon[5] << 8);
        assert(count == SIZES.length);
        assert(6 + count * 16 <= icon.length);
        foreach (index, size; SIZES)
        {
            const entry = 6 + index * 16;
            const dimension = size == 256 ? 0 : size;
            assert(icon[entry] == dimension && icon[entry + 1] == dimension);
            const length = cast(size_t) icon[entry + 8]
                | (cast(size_t) icon[entry + 9] << 8)
                | (cast(size_t) icon[entry + 10] << 16)
                | (cast(size_t) icon[entry + 11] << 24);
            const offset = cast(size_t) icon[entry + 12]
                | (cast(size_t) icon[entry + 13] << 8)
                | (cast(size_t) icon[entry + 14] << 16)
                | (cast(size_t) icon[entry + 15] << 24);
            assert(length > 0 && offset + length <= icon.length);
            auto image = decodeIcoImage(icon, label, size);
            assert(image.width() == size && image.height() == size);
            const center = (cast(size_t) size * size / 2 + size / 2) * 4;
            assert(image.pixels()[center + 3] == 255);
        }
    }

    const host = buildIco(&sampleHost);
    const notepad = buildIco(&sampleNotepad);
    const alert = buildIco(&sampleAlert);
    verifyIcon(host, "host icon");
    verifyIcon(notepad, "notepad icon");
    verifyIcon(alert, "alert icon");
    assert(!equal(host, notepad));
    assert(!equal(alert, host));
    assert(!equal(alert, notepad));

    const scene = "{\n  \"window\": {\n    \"title\": \"x\"\n  }\n}\n";
    const embedded = embedIcon(scene, host);
    assert(embedded.indexOf("\"icon\"") >= 0);
    assert(embedded.indexOf("AAAB") >= 0); // ICO signature in base64.
    auto document = parseJSON(embedded);
    assert(document["window"]["icon"].str.length > 0);
    assert(document["window"]["title"].str == "x");
}
