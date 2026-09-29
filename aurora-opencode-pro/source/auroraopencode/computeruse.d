module auroraopencode.computeruse;

// ===========================================================================
// EXPERIMENTAL: computer use - drive the local desktop from the model.
//
// Highly experimental and OPT-IN: OFF by default. Set AURORA_COMPUTER_USE to
// 1/on/true/yes/enabled/y to expose the `computer` tool; anything unset or in
// the disable list keeps it hidden from both the toolset and the prompt.
//
// Design (from the feature request): a two-level agent. The "computer loop"
// takes one tiny action at a time - screen, click, double_click, type, key,
// scroll, wait_for_change - and is meant to run with no/low model reasoning so
// each step is immediate. Only when the model is genuinely stuck ("which
// installer option?", "why did this fail?") should it escalate to normal
// planning. That escalation steering lives in systemprompt.d; this module only
// exposes the local tool and never builds model requests.
//
// The entire feature lives in this file plus deliberately tiny, greppable hooks
// elsewhere (all tagged `experimental: computer use`):
//   * source/auroraopencode/tools.d        - import, toolset registration, dispatch
//   * source/auroraopencode/systemprompt.d - one steering sentence
//   * source/auroraopencode/appui.d        - UI titles/subtitle
//   * tests/tools_test.d                   - coverage
// To drop the feature: delete this file and delete the tagged hooks. Nothing
// else references it.
//
// Windows: GDI screen capture + SendInput for input. Other platforms report a
// clear "not supported" result instead of failing silently.
// ===========================================================================

import auroraopencode.core : ChatImageAttachment, OpenCodeToolDef;
import auroraopencode.attachments : attachmentImageForData;
import std.algorithm : canFind, min;
import std.array : appender;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.process : environment;
import std.string : split, strip, toLower;
import core.thread : Thread;
import core.time : msecs, MonoTime;

/// Env switch. Off by default: the feature is opt-in. Only these values enable
/// it, so an unset variable (the common case) leaves computer use disabled.
private enum enableValues = ["1", "on", "true", "yes", "y", "enabled",
    "enable"];

/// Whether the experimental computer-use tool is active. Read on every call so
/// tests (and a relaunch with a different environment) see the current value.
public bool experimentalComputerUseEnabled()
{
    if (computerUseEnabledBySetting) return true;
    const raw = strip(toLower(environment.get("AURORA_COMPUTER_USE", "")));
    if (raw.length == 0) return false;
    return enableValues.canFind(raw);
}

/// Set by the host app from the persisted Settings checkbox. `__gshared` is
/// required: the app writes it on the UI thread while tool workers read it.
public __gshared bool computerUseEnabledBySetting = false;

/// Apply the Settings choice. Called on load and whenever the checkbox changes,
/// so the next toolset/prompt build reflects the new value.
public void setComputerUseSetting(bool value)
{
    computerUseEnabledBySetting = value;
}

/// How many of the newest image-carrying messages keep their pixels in a model
/// request. A computer-use loop adds a screenshot per step, and every request
/// resends the whole conversation, so an unbounded history paid for every
/// earlier frame on every turn. Older images stay in the transcript (and are
/// still rendered there); only the wire payload is bounded. 0 disables the
/// limit; override with AURORA_IMAGE_HISTORY.
public size_t experimentalImageHistoryLimit()
{
    const raw = strip(environment.get("AURORA_IMAGE_HISTORY", ""));
    if (raw.length == 0) return imageHistoryLimit;
    try
    {
        const parsed = to!long(raw);
        if (parsed >= 0 && parsed <= 32) return cast(size_t) parsed;
    }
    catch (Exception) {}
    return imageHistoryLimit;
}

/// Two frames is enough for "act on the result of the last step" while keeping
/// a multi-step loop's payload flat instead of growing with every screenshot.
private enum size_t imageHistoryLimit = 2;

/// Tool definition to append to a toolset. Returns an empty array when the
/// experiment is disabled, so registration needs no conditional in the caller.
public OpenCodeToolDef[] experimentalComputerUseTools()
{
    if (!experimentalComputerUseEnabled()) return null;
    return [
        OpenCodeToolDef(
            "computer",
            "Drive the local desktop like a person at the keyboard: `screen` " ~
            "returns a screenshot, and `click`, `double_click`, `right_click`, " ~
            "`type`, `key`, `scroll` and `wait_for_change` act on it. " ~
            "Coordinates are in the screenshot's own pixel space (x right, y " ~
            "down): pass the x,y you read off the latest `screen` image and " ~
            "they are scaled to the real desktop automatically. `type` text " ~
            "may contain a literal newline for Enter and a tab character. " ~
            "Every call costs a full model turn, so prefer one `steps` batch " ~
            "(click a field, type a line, press enter) over a see -> act -> " ~
            "see round trip per action; `screenshot` decides whether a fresh " ~
            "capture comes back (default: yes for `steps`, no for one action, " ~
            "always for `screen`). Keep focus: the action goes to whatever " ~
            "window is focused, so click the target first. Keep reasoning " ~
            "minimal; only stop to plan when genuinely stuck (an unexpected " ~
            "dialog, a choice that needs judgement). Windows only.",
            `{"type":"object","properties":{"action":{"type":"string","enum":["screen","click","double_click","right_click","type","key","scroll","wait_for_change"],"description":"Action to perform; omit when using steps"},"x":{"type":"integer","description":"Screenshot x (click/double_click/right_click)"},"y":{"type":"integer","description":"Screenshot y (click/double_click/right_click)"},"text":{"type":"string","description":"Text to type (type); a newline presses Enter"},"name":{"type":"string","description":"Key for the key action, e.g. \"enter\", \"tab\", \"esc\", \"ctrl+s\", \"alt+f4\""},"amount":{"type":"integer","description":"Scroll wheel delta; negative scrolls down (default -120)"},"timeout_ms":{"type":"integer","description":"wait_for_change: how long to wait for the screen to change (default 5000)"},"interval_ms":{"type":"integer","description":"wait_for_change: how often to re-check, in ms (default 250)"},"screenshot":{"type":"boolean","description":"Return a fresh screenshot after the action(s) as an image"},"steps":{"type":"array","maxItems":32,"description":"Actions run in order in this one call, followed by a single screenshot","items":{"type":"object","properties":{"action":{"type":"string","enum":["screen","click","double_click","right_click","type","key","scroll","wait_for_change"]},"x":{"type":"integer"},"y":{"type":"integer"},"text":{"type":"string"},"name":{"type":"string"},"amount":{"type":"integer"},"timeout_ms":{"type":"integer"},"interval_ms":{"type":"integer"}},"required":["action"]}}},"required":[]}`
        ),
    ];
}

/// Execute a `computer` call. The desktop work happens here; registration,
/// dispatch and UI live in the caller so this module stays the single drop
/// point. Screenshots come back as image attachments in `images`.
public ComputerUseResult experimentalComputerUseExecute(string args,
    string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;

    string action;
    long x;
    long y;
    string text;
    string keyName;
    long amount = -120;
    long timeoutMs = 5000;
    long intervalMs = 250;
    int screenshotFlag = -1; // -1 absent, 0 false, 1 true
    JSONValue[] steps;
    if (value.type == JSONType.object)
    {
        action = jsonString(value, "action");
        x = jsonInt(value, "x", 0);
        y = jsonInt(value, "y", 0);
        text = jsonString(value, "text");
        keyName = jsonString(value, "name");
        amount = jsonInt(value, "amount", -120);
        timeoutMs = jsonInt(value, "timeout_ms", 5000);
        intervalMs = jsonInt(value, "interval_ms", 250);
        screenshotFlag = jsonBoolFlag(value, "screenshot");
        if (auto field = "steps" in value.object)
            if (field.type == JSONType.array) steps = field.array;
    }
    action = strip(toLower(action));
    if (action.length == 0 && steps.length == 0)
        return failedResult("Error: computer requires an `action` " ~
            "(screen, click, double_click, type, key, scroll, " ~
            "wait_for_change) or a `steps` batch.");

    version (Windows)
    {
        // A batch screenshots by default: the caller's next move depends on the
        // result, and asking for it in the same call saves a whole model turn.
        if (steps.length > 0)
            return runWindowsSteps(steps,
                screenshotFlag < 0 ? true : screenshotFlag == 1);
        return runWindowsAction(action, cast(int) x, cast(int) y, text,
            keyName, cast(int) amount, timeoutMs, intervalMs,
            screenshotFlag == 1);
    }
    else
        return failedResult("Error: computer use is only implemented on " ~
            "Windows in this build.");
}

private ComputerUseResult failedResult(string message)
{
    ComputerUseResult result;
    result.output = message;
    result.failed = true;
    return result;
}

private ComputerUseResult succeededResult(string message)
{
    ComputerUseResult result;
    result.output = message;
    return result;
}

// ---------------------------------------------------------------------------
// Platform-neutral argument helpers.
// ---------------------------------------------------------------------------

private string jsonString(in JSONValue value, string key)
{
    if (auto field = key in value.object)
        if (field.type == JSONType.string)
            return field.str;
    return "";
}

private long jsonInt(in JSONValue value, string key, long fallback)
{
    if (auto field = key in value.object)
        if (field.type == JSONType.integer)
            return field.integer;
    return fallback;
}

/// Tri-state boolean read: -1 when absent (the caller applies its own default),
/// 0 for false, 1 for true.
private int jsonBoolFlag(in JSONValue value, string key)
{
    if (auto field = key in value.object)
    {
        if (field.type == JSONType.true_) return 1;
        if (field.type == JSONType.false_) return 0;
    }
    return -1;
}

// ---------------------------------------------------------------------------
// PNG encoding (truecolor, 8-bit) with real deflate compression.
//
// A screenshot must reach the model as PNG/JPEG/WebP/GIF (see the attachment
// magic-byte sniffing), and Aurora has no image encoder, so this module carries
// a small, dependency-free writer: per-row PNG filtering, then LZ77 with
// fixed-Huffman deflate. The earlier stored-block writer was trivial but shipped
// the frame uncompressed - ~1.5 MB for a 960x540 desktop - and the conversation
// resends every image on later requests, so each step got slower than the last.
// Stored blocks remain as a size fallback for incompressible frames.
// ---------------------------------------------------------------------------

/// Encode tightly packed RGB bytes (`w * h * 3`) as a PNG. Public so the tests
/// can validate the container without touching the desktop.
public ubyte[] computerUseEncodePng(int w, int h, in ubyte[] rgb)
{
    assert(cast(size_t) w * h * 3 <= rgb.length, "rgb too small");
    ubyte[] out_;
    out_ ~= [0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A];

    ubyte[] ihdr;
    putBigEndian(ihdr, cast(uint) w);
    putBigEndian(ihdr, cast(uint) h);
    ihdr ~= [8, 2, 0, 0, 0]; // 8-bit, truecolor, deflate, adaptive, no interlace
    appendChunk(out_, "IHDR", ihdr);

    const raw = pngFilteredRows(w, h, rgb);
    appendChunk(out_, "IDAT", zlibCompress(raw));
    appendChunk(out_, "IEND", null);
    return out_;
}

/// PNG scanlines with the per-row filter that minimizes the sum of the absolute
/// (signed) byte values, which is what makes the following deflate shrink a
/// screenshot instead of storing it. Bytes per pixel for truecolor 8-bit.
private enum size_t pngBytesPerPixel = 3;

private ubyte[] pngFilteredRows(int w, int h, in ubyte[] rgb)
{
    const stride = cast(size_t) w * 3;
    auto filtered = new ubyte[](cast(size_t) h * (stride + 1));
    auto previous = new ubyte[](stride); // the raw row above; zeros on row 0
    auto candidate0 = new ubyte[](stride);
    auto candidate1 = new ubyte[](stride);
    auto candidate2 = new ubyte[](stride);
    auto candidate3 = new ubyte[](stride);
    auto candidate4 = new ubyte[](stride);
    const candidates = [candidate0, candidate1, candidate2, candidate3,
        candidate4];
    foreach (row; 0 .. cast(size_t) h)
    {
        const current = rgb[row * stride .. row * stride + stride];
        size_t[5] penalty;
        foreach (index; 0 .. stride)
        {
            const left = index >= pngBytesPerPixel ? current[index -
                pngBytesPerPixel] : 0;
            const above = previous[index];
            const upperLeft = index >= pngBytesPerPixel ? previous[index -
                pngBytesPerPixel] : 0;
            candidate0[index] = current[index];
            candidate1[index] = cast(ubyte) (current[index] - left);
            candidate2[index] = cast(ubyte) (current[index] - above);
            candidate3[index] = cast(ubyte) (current[index] -
                ((cast(int) left + above) >> 1));
            candidate4[index] = cast(ubyte) (current[index] -
                paethPredictor(left, above, upperLeft));
            penalty[0] += filteredPenalty(candidate0[index]);
            penalty[1] += filteredPenalty(candidate1[index]);
            penalty[2] += filteredPenalty(candidate2[index]);
            penalty[3] += filteredPenalty(candidate3[index]);
            penalty[4] += filteredPenalty(candidate4[index]);
        }
        size_t best;
        foreach (index; 1 .. 5)
            if (penalty[index] < penalty[best]) best = index;
        const offset = row * (stride + 1);
        filtered[offset] = cast(ubyte) best;
        filtered[offset + 1 .. offset + 1 + stride] = candidates[best];
        previous[] = current;
    }
    return filtered;
}

/// Cost of one filtered byte: its magnitude read as a signed value.
private size_t filteredPenalty(ubyte value)
{
    const signed = cast(int) cast(byte) value;
    return cast(size_t) (signed < 0 ? -signed : signed);
}

/// The PNG Paeth predictor for bytes to the left, above and above-left.
private ubyte paethPredictor(int left, int above, int upperLeft)
{
    const estimate = left + above - upperLeft;
    const leftDistance = absolute(estimate - left);
    const aboveDistance = absolute(estimate - above);
    const upperLeftDistance = absolute(estimate - upperLeft);
    if (leftDistance <= aboveDistance && leftDistance <= upperLeftDistance)
        return cast(ubyte) left;
    if (aboveDistance <= upperLeftDistance) return cast(ubyte) above;
    return cast(ubyte) upperLeft;
}

private int absolute(int value)
{
    return value < 0 ? -value : value;
}

// ---------------------------------------------------------------------------
// zlib / deflate. Fixed-Huffman blocks with a greedy LZ77 matcher: no dynamic
// Huffman tables (a few percent smaller) but the container stays simple and the
// win over storing the frame is the whole 4-10x.
// ---------------------------------------------------------------------------

/// Deflate `data` into a zlib stream (`78 01` header + adler32 trailer).
private ubyte[] zlibCompress(in ubyte[] data)
{
    auto compressed = deflateFixed(data);
    // An incompressible frame can grow a little under fixed Huffman; storing it
    // is never worse than a few bytes of block headers.
    ubyte[] deflated = compressed.length >= data.length + 5 ?
        deflateStored(data) : compressed;
    ubyte[] out_;
    out_ ~= [0x78, 0x01]; // deflate, 32 KiB window, no dictionary, fastest flag
    out_ ~= deflated;
    putBigEndian(out_, adler32(data));
    return out_;
}

/// A single deflate block holding the bytes verbatim, split at the 65535-byte
/// stored-block limit.
private ubyte[] deflateStored(in ubyte[] data)
{
    ubyte[] out_;
    size_t position;
    do
    {
        const chunk = min(data.length - position, cast(size_t) 65535);
        const last = (position + chunk >= data.length) ? 1 : 0;
        out_ ~= cast(ubyte) last; // BFINAL, BTYPE = 00 (stored)
        out_ ~= cast(ubyte) (chunk & 0xFF);
        out_ ~= cast(ubyte) ((chunk >> 8) & 0xFF);
        out_ ~= cast(ubyte) (~chunk & 0xFF);
        out_ ~= cast(ubyte) ((~chunk >> 8) & 0xFF);
        out_ ~= data[position .. position + chunk];
        position += chunk;
    }
    while (position < data.length);
    return out_;
}

/// LSB-first bit writer. Deflate packs everything this way except Huffman
/// codes, which are written most-significant bit first (see `writeCode`).
private struct BitWriter
{
    private ubyte[] _bytes;
    private uint _accumulator;
    private uint _bitCount;

    private void putBit(uint bit)
    {
        _accumulator |= (bit & 1) << _bitCount;
        if (++_bitCount == 8)
        {
            _bytes ~= cast(ubyte) _accumulator;
            _accumulator = 0;
            _bitCount = 0;
        }
    }

    private void writeBits(uint value, uint count)
    {
        foreach (index; 0 .. count)
            putBit((value >> index) & 1);
    }

    private void writeCode(uint value, uint count)
    {
        foreach_reverse (index; 0 .. count)
            putBit((value >> index) & 1);
    }

    private ubyte[] finish()
    {
        if (_bitCount > 0)
        {
            _bytes ~= cast(ubyte) _accumulator;
            _accumulator = 0;
            _bitCount = 0;
        }
        return _bytes;
    }
}

/// Length codes 257-285: base length plus extra bits (RFC 1951 section 3.2.5).
private immutable int[] lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17,
    19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
private immutable int[] lengthExtraBits = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1,
    1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];

/// Distance codes 0-29: base distance plus extra bits.
private immutable int[] distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33,
    49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
    6145, 8193, 12289, 16385, 24577];
private immutable int[] distanceExtraBits = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4,
    4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];

private enum size_t deflateHashSlots = 1 << 15;
private enum size_t deflateMaxMatch = 258;
private enum size_t deflateWindow = 1 << 15;
private enum int deflateMaxChain = 96;

/// Fixed-Huffman literal/length code (RFC 1951 section 3.2.6).
private void writeFixedSymbol(ref BitWriter writer, uint symbol)
{
    if (symbol <= 143) writer.writeCode(0x30 + symbol, 8);
    else if (symbol <= 255) writer.writeCode(0x190 + symbol - 144, 9);
    else if (symbol <= 279) writer.writeCode(symbol - 256, 7);
    else writer.writeCode(0xC0 + symbol - 280, 8);
}

private void writeLengthDistance(ref BitWriter writer, int length,
    int distance)
{
    size_t code;
    while (code + 1 < lengthBase.length && lengthBase[code + 1] <= length)
        ++code;
    writeFixedSymbol(writer, 257 + cast(uint) code);
    writer.writeBits(cast(uint) (length - lengthBase[code]),
        cast(uint) lengthExtraBits[code]);

    size_t distanceCode;
    while (distanceCode + 1 < distanceBase.length &&
        distanceBase[distanceCode + 1] <= distance)
        ++distanceCode;
    writer.writeCode(cast(uint) distanceCode, 5); // fixed 5-bit distance code
    writer.writeBits(cast(uint) (distance - distanceBase[distanceCode]),
        cast(uint) distanceExtraBits[distanceCode]);
}

private uint deflateHash(in ubyte[] data, size_t position)
{
    return ((cast(uint) data[position] << 10) ^
        (cast(uint) data[position + 1] << 5) ^ data[position + 2]) &
        (cast(uint) deflateHashSlots - 1);
}

/// One fixed-Huffman deflate block over `data`, with a greedy hash-chain match
/// search limited to a 32 KiB window.
private ubyte[] deflateFixed(in ubyte[] data)
{
    auto writer = BitWriter();
    writer.writeBits(1, 1); // BFINAL: single block
    writer.writeBits(1, 2); // BTYPE = 01 (fixed Huffman)

    if (data.length < 3)
    {
        foreach (byte_; data) writeFixedSymbol(writer, byte_);
        writeFixedSymbol(writer, 256); // end of block
        return writer.finish();
    }

    auto chain = new int[data.length];
    chain[] = -1;
    auto head = new int[deflateHashSlots];
    head[] = -1;
    foreach (position; 0 .. data.length - 2)
    {
        const hash = deflateHash(data, position);
        chain[position] = head[hash];
        head[hash] = cast(int) position;
    }

    size_t position;
    while (position < data.length)
    {
        size_t bestLength;
        size_t bestDistance;
        const longest = min(deflateMaxMatch, data.length - position);
        if (longest >= 3)
        {
            int steps = deflateMaxChain;
            int candidate = chain[position];
            while (candidate >= 0 && steps-- > 0)
            {
                const distance = position - cast(size_t) candidate;
                if (distance > deflateWindow) break;
                if (bestLength < longest)
                {
                    size_t length;
                    while (length < longest &&
                        data[cast(size_t) candidate + length] ==
                            data[position + length])
                        ++length;
                    if (length > bestLength)
                    {
                        bestLength = length;
                        bestDistance = distance;
                        if (length == longest) break;
                    }
                }
                candidate = chain[cast(size_t) candidate];
            }
        }
        if (bestLength >= 3)
        {
            writeLengthDistance(writer, cast(int) bestLength,
                cast(int) bestDistance);
            position += bestLength;
        }
        else
        {
            writeFixedSymbol(writer, data[position]);
            ++position;
        }
    }
    writeFixedSymbol(writer, 256); // end of block
    return writer.finish();
}

private void putBigEndian(ref ubyte[] buffer, uint value)
{
    buffer ~= cast(ubyte) ((value >> 24) & 0xFF);
    buffer ~= cast(ubyte) ((value >> 16) & 0xFF);
    buffer ~= cast(ubyte) ((value >> 8) & 0xFF);
    buffer ~= cast(ubyte) (value & 0xFF);
}

private void appendChunk(ref ubyte[] buffer, string type, in ubyte[] data)
{
    putBigEndian(buffer, cast(uint) data.length);
    const start = buffer.length;
    foreach (ch; type) buffer ~= cast(ubyte) ch;
    buffer ~= data;
    putBigEndian(buffer, crc32(buffer[start .. $]));
}

private uint adler32(in ubyte[] data)
{
    enum uint modulus = 65521;
    uint a = 1;
    uint b;
    foreach (byte_; data)
    {
        a = (a + byte_) % modulus;
        b = (b + a) % modulus;
    }
    return (b << 16) | a;
}

private uint crc32(in ubyte[] data)
{
    uint crc = 0xFFFFFFFF;
    foreach (byte_; data)
        crc = crcTable[(crc ^ byte_) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFF;
}

private immutable uint[] crcTable = makeCrcTable();

private uint[] makeCrcTable()
{
    uint[] table;
    table.length = 256;
    foreach (index; 0 .. 256)
    {
        uint value = cast(uint) index;
        foreach (bit; 0 .. 8)
            value = (value & 1) ? (0xEDB88320 ^ (value >> 1)) : (value >> 1);
        table[index] = value;
    }
    return table;
}

// ---------------------------------------------------------------------------
// Windows desktop implementation.
// ---------------------------------------------------------------------------

version (Windows)
{
    private alias DWORD = uint;
    private alias UINT = uint;
    private alias WORD = ushort;
    private alias LONG = int;
    private alias BOOL = int;

    private enum SRCCOPY = 0x00CC0020;
    private enum DIB_RGB_COLORS = 0;
    private enum SM_CXSCREEN = 0;
    private enum SM_CYSCREEN = 1;

    private enum INPUT_MOUSE = 0;
    private enum INPUT_KEYBOARD = 1;
    private enum MOUSEEVENTF_LEFTDOWN = 0x0002;
    private enum MOUSEEVENTF_LEFTUP = 0x0004;
    private enum MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private enum MOUSEEVENTF_RIGHTUP = 0x0010;
    private enum MOUSEEVENTF_WHEEL = 0x0800;
    private enum KEYEVENTF_KEYUP = 0x0002;
    private enum KEYEVENTF_UNICODE = 0x0004;

    private struct MOUSEINPUT
    {
        LONG dx;
        LONG dy;
        DWORD mouseData;
        DWORD dwFlags;
        DWORD time;
        size_t dwExtraInfo;
    }

    private struct KEYBDINPUT
    {
        WORD wVk;
        WORD wScan;
        DWORD dwFlags;
        DWORD time;
        size_t dwExtraInfo;
    }

    private struct HARDWAREINPUT
    {
        DWORD uMsg;
        WORD wParamL;
        WORD wParamH;
    }

    private struct INPUT
    {
        DWORD type;
        union
        {
            MOUSEINPUT mi;
            KEYBDINPUT ki;
            HARDWAREINPUT hi;
        }
    }

    private struct BITMAPINFOHEADER
    {
        DWORD biSize;
        LONG biWidth;
        LONG biHeight;
        WORD biPlanes;
        WORD biBitCount;
        DWORD biCompression;
        DWORD biSizeImage;
        LONG biXPelsPerMeter;
        LONG biYPelsPerMeter;
        DWORD biClrUsed;
        DWORD biClrImportant;
    }

    private struct RGBQUAD
    {
        ubyte blue;
        ubyte green;
        ubyte red;
        ubyte reserved;
    }

    private struct BITMAPINFO
    {
        BITMAPINFOHEADER bmiHeader;
        RGBQUAD bmiColors;
    }

    private extern (Windows)
    {
        int SetCursorPos(int x, int y);
        uint SendInput(uint cInputs, INPUT* pInputs, int cbSize);
        int GetSystemMetrics(int index);
        void* GetDC(void* hwnd);
        int ReleaseDC(void* hwnd, void* hdc);
        void* CreateCompatibleDC(void* hdc);
        void* CreateCompatibleBitmap(void* hdc, int width, int height);
        void* SelectObject(void* hdc, void* object);
        int BitBlt(void* dest, int x, int y, int width, int height,
            void* source, int srcX, int srcY, DWORD rop);
        int GetDIBits(void* hdc, void* bitmap, UINT start, UINT lines,
            void* bits, BITMAPINFO* info, UINT usage);
        int DeleteObject(void* object);
        int DeleteDC(void* hdc);
    }

    /// One downscaled, top-down RGB frame plus its pixel dimensions. `ok` is
    /// false with an explanatory `error` when capture is not possible.
    private struct Capture
    {
        bool ok;
        string error;
        int width;
        int height;
        ubyte[] rgb;
    }

    /// Longest edge of a capture. Keeping the frame near 1280px matches the
    /// ~1300px budget vision models resize to anyway, and keeps the PNG under
    /// the attachment size cap without compressing.
    private enum int captureMaxEdge = 1280;

    /// Integer downscale factor applied to screenshots (1 = native pixels).
    /// Input coordinates arrive in the downscaled screenshot's pixel space, so
    /// input handlers multiply by this to reach real screen pixels. Computed the
    /// same way as `captureScreen` so the two can never disagree.
    private int screenDownscale()
    {
        const width = GetSystemMetrics(SM_CXSCREEN);
        const height = GetSystemMetrics(SM_CYSCREEN);
        const maxEdge = width > height ? width : height;
        if (maxEdge <= captureMaxEdge) return 1;
        return (maxEdge + captureMaxEdge - 1) / captureMaxEdge;
    }

    private Capture captureScreen()
    {
        Capture capture;
        const width = GetSystemMetrics(SM_CXSCREEN);
        const height = GetSystemMetrics(SM_CYSCREEN);
        if (width <= 0 || height <= 0)
        {
            capture.error = "Error: could not determine the screen size.";
            return capture;
        }

        void* screenDc = GetDC(null);
        if (screenDc is null)
        {
            capture.error = "Error: could not get the screen device context.";
            return capture;
        }
        void* memDc = CreateCompatibleDC(screenDc);
        void* bitmap = CreateCompatibleBitmap(screenDc, width, height);
        if (memDc is null || bitmap is null)
        {
            if (bitmap !is null) DeleteObject(bitmap);
            if (memDc !is null) DeleteDC(memDc);
            ReleaseDC(null, screenDc);
            capture.error = "Error: could not create a capture surface.";
            return capture;
        }
        void* previous = SelectObject(memDc, bitmap);
        scope (exit)
        {
            SelectObject(memDc, previous);
            DeleteObject(bitmap);
            DeleteDC(memDc);
            ReleaseDC(null, screenDc);
        }

        if (!BitBlt(memDc, 0, 0, width, height, screenDc, 0, 0, SRCCOPY))
        {
            capture.error = "Error: screen capture (BitBlt) failed.";
            return capture;
        }

        BITMAPINFO info;
        info.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
        info.bmiHeader.biWidth = width;
        info.bmiHeader.biHeight = -height; // top-down rows
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = 0; // BI_RGB
        auto pixels = new ubyte[cast(size_t) width * height * 4];
        if (GetDIBits(memDc, bitmap, 0, cast(UINT) height, pixels.ptr,
            &info, DIB_RGB_COLORS) == 0)
        {
            capture.error = "Error: could not read captured pixels.";
            return capture;
        }

        const step = screenDownscale();
        const outWidth = (width + step - 1) / step;
        const outHeight = (height + step - 1) / step;
        auto rgb = new ubyte[cast(size_t) outWidth * outHeight * 3];
        foreach (oy; 0 .. outHeight)
        {
            const sy = min(oy * step, height - 1);
            foreach (ox; 0 .. outWidth)
            {
                const sx = min(ox * step, width - 1);
                const src = (cast(size_t) sy * width + sx) * 4;
                const dst = (cast(size_t) oy * outWidth + ox) * 3;
                rgb[dst] = pixels[src + 2];     // R
                rgb[dst + 1] = pixels[src + 1]; // G
                rgb[dst + 2] = pixels[src];     // B
            }
        }
        capture.ok = true;
        capture.width = outWidth;
        capture.height = outHeight;
        capture.rgb = rgb;
        return capture;
    }

    /// Cheap whole-frame fingerprint used to detect that "something changed".
    private ulong frameSignature(in ubyte[] rgb)
    {
        ulong hash = 1469598103934665603UL;
        const step = rgb.length / 4096 > 1 ? rgb.length / 4096 : 1;
        for (size_t index; index < rgb.length; index += step)
        {
            hash ^= rgb[index];
            hash *= 1099511628211UL;
        }
        return hash;
    }

    private ComputerUseResult screenshotResult(string prefix)
    {
        auto capture = captureScreen();
        if (!capture.ok) return failedResult(capture.error);
        auto png = computerUseEncodePng(capture.width, capture.height,
            capture.rgb);
        ComputerUseResult result;
        const step = screenDownscale();
        result.output = prefix ~ " (" ~ to!string(capture.width) ~ "x" ~
            to!string(capture.height) ~ ", " ~ to!string(png.length) ~
            " bytes" ~ (step > 1 ? ", 1/" ~ to!string(step) ~ " of the " ~
            to!string(capture.width * step) ~ "x" ~
            to!string(capture.height * step) ~ " screen" : "") ~
            "; click in these image pixels).";
        result.images = [attachmentImageForData("image/png", "screen.png",
            png)];
        return result;
    }

    private void sendMouse(DWORD flags, int data = 0)
    {
        INPUT[1] inputs;
        inputs[0].type = INPUT_MOUSE;
        inputs[0].mi.dwFlags = flags;
        inputs[0].mi.mouseData = cast(DWORD) data;
        SendInput(1, inputs.ptr, INPUT.sizeof);
    }

    /// Move the pointer to a screenshot-space coordinate, clamped to the real
    /// screen so an out-of-range model guess cannot move it off the desktop.
    private void moveCursor(int x, int y)
    {
        const step = screenDownscale();
        const width = GetSystemMetrics(SM_CXSCREEN);
        const height = GetSystemMetrics(SM_CYSCREEN);
        long realX = cast(long) x * step;
        long realY = cast(long) y * step;
        if (realX < 0) realX = 0;
        else if (realX > width - 1) realX = width - 1;
        if (realY < 0) realY = 0;
        else if (realY > height - 1) realY = height - 1;
        SetCursorPos(cast(int) realX, cast(int) realY);
    }

    private void clickAt(int x, int y, int count,
        DWORD down = MOUSEEVENTF_LEFTDOWN, DWORD up = MOUSEEVENTF_LEFTUP)
    {
        // Coordinates arrive in the (possibly downscaled) screenshot's pixel
        // space; mapToReal maps them onto real screen pixels before the press.
        moveCursor(x, y);
        Thread.sleep(msecs(30)); // let the pointer settle before the press
        foreach (i; 0 .. count)
        {
            sendMouse(down);
            sendMouse(up);
            if (i + 1 < count) Thread.sleep(msecs(60));
        }
    }

    private ushort[] utf16Units(dchar c)
    {
        if (c <= 0xFFFF) return [cast(ushort) c];
        const value = cast(uint) c - 0x10000;
        return [cast(ushort) (0xD800 + (value >> 10)),
            cast(ushort) (0xDC00 + (value & 0x3FF))];
    }

    private void typeText(string text)
    {
        foreach (dchar c; text)
        {
            // Control characters go through virtual keys: a lone Unicode
            // newline/tab is ignored by many controls, so press Enter/Tab.
            if (c == '\n') { pressChord(null, 0x0D); continue; }
            if (c == '\r') continue; // already handled by the \n of a CRLF pair
            if (c == '\t') { pressChord(null, 0x09); continue; }
            foreach (unit; utf16Units(c))
            {
                INPUT[2] inputs;
                inputs[0].type = INPUT_KEYBOARD;
                inputs[0].ki.wScan = unit;
                inputs[0].ki.dwFlags = KEYEVENTF_UNICODE;
                inputs[1].type = INPUT_KEYBOARD;
                inputs[1].ki.wScan = unit;
                inputs[1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
                SendInput(2, inputs.ptr, INPUT.sizeof);
            }
        }
    }

    private void pressChord(ushort[] modifiers, ushort vk)
    {
        auto builder = appender!(INPUT[])();
        void put(ushort key, DWORD flags)
        {
            INPUT input;
            input.type = INPUT_KEYBOARD;
            input.ki.wVk = key;
            input.ki.dwFlags = flags;
            builder.put(input);
        }
        foreach (modifier; modifiers) put(modifier, 0);
        put(vk, 0);
        put(vk, KEYEVENTF_KEYUP);
        foreach_reverse (modifier; modifiers) put(modifier, KEYEVENTF_KEYUP);
        auto inputs = builder.data;
        SendInput(cast(UINT) inputs.length, inputs.ptr, INPUT.sizeof);
    }

    private ushort virtualKeyFor(string token)
    {
        switch (token)
        {
            case "enter": case "return": return 0x0D;
            case "tab": return 0x09;
            case "esc": case "escape": return 0x1B;
            case "space": return 0x20;
            case "backspace": case "back": return 0x08;
            case "delete": case "del": return 0x2E;
            case "insert": case "ins": return 0x2D;
            case "up": return 0x26;
            case "down": return 0x28;
            case "left": return 0x25;
            case "right": return 0x27;
            case "home": return 0x24;
            case "end": return 0x23;
            case "pageup": case "pgup": return 0x21;
            case "pagedown": case "pgdn": return 0x22;
            case "f1": return 0x70;
            case "f2": return 0x71;
            case "f3": return 0x72;
            case "f4": return 0x73;
            case "f5": return 0x74;
            case "f6": return 0x75;
            case "f7": return 0x76;
            case "f8": return 0x77;
            case "f9": return 0x78;
            case "f10": return 0x79;
            case "f11": return 0x7A;
            case "f12": return 0x7B;
            case "win": case "meta": case "super": case "lwin": return 0x5B;
            case "rwin": return 0x5C;
            default: return 0;
        }
    }

    private ushort modifierKeyFor(string token)
    {
        switch (token)
        {
            case "ctrl": case "control": return 0x11; // VK_CONTROL
            case "alt": return 0x12;                  // VK_MENU
            case "shift": return 0x10;                // VK_SHIFT
            case "win": case "meta": case "super": return 0x5B; // VK_LWIN
            default: return 0;
        }
    }

    private ComputerUseResult runKey(string keyName)
    {
        auto parts = keyName.toLower.split("+");
        if (parts.length == 0 || strip(parts[$ - 1]).length == 0)
            return failedResult("Error: key requires a `name`, e.g. " ~
                "\"enter\" or \"ctrl+s\".");
        ushort[] modifiers;
        foreach (token; parts[0 .. $ - 1])
        {
            const modifier = modifierKeyFor(strip(token));
            if (modifier == 0)
                return failedResult("Error: unknown modifier '" ~
                    strip(token) ~ "' in key chord.");
            modifiers ~= modifier;
        }
        const last = strip(parts[$ - 1]);
        ushort vk = virtualKeyFor(last);
        if (vk == 0 && last.length == 1)
            vk = cast(ushort) last[0];
        if (vk == 0)
            return failedResult("Error: unknown key '" ~ last ~ "'.");
        pressChord(modifiers, vk);
        return succeededResult("Pressed key \"" ~ keyName ~ "\".");
    }

    private ComputerUseResult runWindowsAction(string action, int x, int y,
        string text, string keyName, int amount, long timeoutMs,
        long intervalMs, bool screenshot = false)
    {
        switch (action)
        {
            case "screen":
                return screenshotResult("Captured the screen");
            case "click":
                clickAt(x, y, 1);
                return withOptionalScreenshot("Clicked at " ~ to!string(x) ~
                    "," ~ to!string(y) ~ ".", screenshot);
            case "double_click":
                clickAt(x, y, 2);
                return withOptionalScreenshot("Double-clicked at " ~
                    to!string(x) ~ "," ~ to!string(y) ~ ".", screenshot);
            case "right_click":
                clickAt(x, y, 1, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP);
                return withOptionalScreenshot("Right-clicked at " ~
                    to!string(x) ~ "," ~ to!string(y) ~ ".", screenshot);
            case "type":
                if (text.length == 0)
                    return failedResult("Error: type requires `text`.");
                typeText(text);
                return withOptionalScreenshot("Typed " ~
                    to!string(text.length) ~ " characters.", screenshot);
            case "key":
            {
                auto result = runKey(keyName);
                if (!screenshot || result.failed) return result;
                return withOptionalScreenshot(result.output, true);
            }
            case "scroll":
                // Optional x,y put the wheel over the pane to scroll instead
                // of wherever the pointer happened to be left.
                if (x != 0 || y != 0) moveCursor(x, y);
                sendMouse(MOUSEEVENTF_WHEEL, amount);
                return withOptionalScreenshot("Scrolled by " ~
                    to!string(amount) ~ ".", screenshot);
            case "wait_for_change":
                return waitForChange(timeoutMs, intervalMs);
            default:
                return failedResult("Error: unknown computer action '" ~
                    action ~ "'.");
        }
    }

    /// The action's text, plus a fresh screenshot when the caller asked for one.
    private ComputerUseResult withOptionalScreenshot(string text,
        bool screenshot)
    {
        if (!screenshot) return succeededResult(text);
        auto shot = screenshotResult(text ~ " Screen after the action");
        if (shot.failed) return shot;
        return shot;
    }

    /// A batch of actions in one call, followed by a single screenshot: the
    /// point is that one model turn can do a short sequence of work instead of
    /// paying a round trip (and a screenshot) per keystroke.
    private ComputerUseResult runWindowsSteps(JSONValue[] steps,
        bool screenshot)
    {
        enum size_t maxSteps = 32;
        if (steps.length > maxSteps)
            return failedResult("Error: too many computer steps (limit " ~
                to!string(maxSteps) ~ ").");

        auto builder = appender!string();
        ComputerUseResult lastStep;
        bool failed;
        foreach (index, step; steps)
        {
            const label = "step " ~ to!string(index + 1);
            if (step.type != JSONType.object)
            {
                builder.put(label ~ ": Error: each step must be an object.\n");
                failed = true;
                break;
            }
            const action = strip(toLower(jsonString(step, "action")));
            auto one = runWindowsAction(action, cast(int) jsonInt(step, "x", 0),
                cast(int) jsonInt(step, "y", 0), jsonString(step, "text"),
                jsonString(step, "name"), cast(int) jsonInt(step, "amount",
                -120), jsonInt(step, "timeout_ms", 5000),
                jsonInt(step, "interval_ms", 250), false);
            builder.put(label ~ " (" ~ (action.length > 0 ? action : "?") ~
                "): " ~ one.output);
            if (builder.data.length > 0 && builder.data[$ - 1] != '\n')
                builder.put("\n");
            if (one.images.length > 0) lastStep = one;
            if (one.failed)
            {
                failed = true;
                break;
            }
            if (index + 1 < steps.length) Thread.sleep(msecs(60));
        }

        ComputerUseResult result;
        result.output = builder.data;
        result.failed = failed;
        if (screenshot)
        {
            auto shot = screenshotResult("Screen after the batch");
            if (shot.failed)
            {
                result.output ~= shot.output;
                result.failed = true;
                return result;
            }
            result.output ~= shot.output;
            result.images = shot.images;
        }
        else
            result.images = lastStep.images;
        return result;
    }

    private ComputerUseResult waitForChange(long timeoutMs, long intervalMs)
    {
        if (timeoutMs < 0) timeoutMs = 0;
        if (intervalMs < 50) intervalMs = 50;
        auto before = captureScreen();
        if (!before.ok) return failedResult(before.error);
        const baseline = frameSignature(before.rgb);
        const deadline = MonoTime.currTime +
            msecs(timeoutMs > 60000 ? 60000 : timeoutMs);
        while (MonoTime.currTime < deadline)
        {
            Thread.sleep(msecs(intervalMs));
            auto now = captureScreen();
            if (!now.ok) return failedResult(now.error);
            if (frameSignature(now.rgb) != baseline)
            {
                auto png = computerUseEncodePng(now.width, now.height,
                    now.rgb);
                ComputerUseResult result;
                result.output = "Screen changed.";
                result.images = [attachmentImageForData("image/png",
                    "screen.png", png)];
                return result;
            }
        }
        return succeededResult("Screen did not change within " ~
            to!string(timeoutMs) ~ " ms.");
    }
}

/// Outcome of one `computer` call. `images` carries any screenshot(s) to stage
/// as a model-visible message; `output` is the text the model reads.
public struct ComputerUseResult
{
    string output;
    bool failed;
    ChatImageAttachment[] images;
}
