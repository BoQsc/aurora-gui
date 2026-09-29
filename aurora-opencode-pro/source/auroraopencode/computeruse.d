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
import std.json : JSONType, JSONValue, parseJSON, toJSON;
import std.file : readText;
import std.process : environment;
import std.string : indexOf, split, startsWith, strip, toLower;
import std.base64 : Base64;
import std.utf : toUTF16z;
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

// ---------------------------------------------------------------------------
// Kill switch. A global hotkey the human can press to stop the agent at once,
// even while a fullscreen game owns the keyboard. The hotkey thread sets a flag
// the tool worker polls between every step; nothing the agent does can ignore
// it. `__gshared` because the two run on different threads.
// ---------------------------------------------------------------------------

/// Human-facing chord that stops the agent. The label is what the model and the
/// UI show; the actual VK/modifiers live in the Windows section below.
public enum string computerUseKillSwitchChord = "Ctrl+Alt+Shift+K";

/// Set by the hotkey thread, read by the tool worker. Cleared at the start of
/// every computer call so a stray press while idle cannot stop a later run.
private __gshared bool computerUseAbortFlag = false;

/// Workspace directory of the current call, so a `macro` can be loaded from
/// `<workspace>/computer-macros.json`. Set at the start of every call.
private __gshared string computerUseWorkspace;

/// True once the human has pressed the kill switch during the current call.
public bool computerUseAbortActive()
{
    return computerUseAbortFlag;
}

/// Called from the hotkey thread when the chord is pressed. Only sets the flag:
/// the tool worker notices it between steps and returns, and its own
/// `scope (exit) releaseHeldInputs()` releases anything held - so no input is
/// injected from inside a keyboard-hook callback.
public void requestComputerUseAbort()
{
    computerUseAbortFlag = true;
}

/// Start the background thread that owns the global kill-switch hotkey. No-op
/// when computer use is not compiled for this platform.
public void startComputerUseKillSwitch()
{
    version (Windows) startKillSwitchThread();
}

/// Unregister the chord and stop the hotkey thread (called on app shutdown).
public void stopComputerUseKillSwitch()
{
    version (Windows) stopKillSwitchThread();
}

// ---------------------------------------------------------------------------
// Provider config for the `subagent` action. The nested model loop needs a
// base URL, an API key and a model; the app already has these in Settings, so it
// pushes them here (like the enabled flag) instead of computer use reading the
// settings file itself.
// ---------------------------------------------------------------------------

public __gshared string computerUseProviderBaseUrl;
public __gshared string computerUseProviderApiKey;
public __gshared string computerUseProviderModel;

/// Default model for the nested computer-use loop (the `subagent` action). A
/// per-call `model` argument overrides it. Vision-capable and cheap; measured
/// ~40% faster per round than the main app model on the live CoH1 playtest.
public enum string computerUseDefaultLoopModel = "deepseek-v4-flash-vision-exp";

/// Called by the app on load and whenever Settings change.
public void setComputerUseProvider(string baseUrl, string apiKey, string model)
{
    computerUseProviderBaseUrl = baseUrl;
    computerUseProviderApiKey = apiKey;
    computerUseProviderModel = model;
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
            "`mouse_move`, `drag`, `type`, `key`, `key_down`, `key_up`, " ~
            "`scroll` and `wait_for_change` act on it. Coordinates are in the " ~
            "screenshot's own pixel space (x right, y down): pass the x,y you " ~
            "read off the latest `screen` image and they are scaled to the " ~
            "real desktop automatically. Use `mouse_move` to hover without " ~
            "clicking (e.g. edge-pan), `drag` for box-select, order and camera " ~
            "drags, and `key_down`/`key_up` to hold a key down (camera pan, " ~
            "shift-queue). `focus` brings a window to the front by title " ~
            "substring, and every action reports the active window so you can " ~
            "tell where input actually went. `macro` runs a named sequence of " ~
            "steps from computer-macros.json in the workspace - one call, no " ~
            "per-action reasoning, for learned routines; `loop` repeats a " ~
            "macro for `seconds` at `interval_ms` with no model turns at all. " ~
            "`type` text may " ~
            "contain a literal newline for Enter " ~
            "and a tab character. `screen` accepts a `region` {x,y,w,h} for a " ~
            "zoomed-in crop of one area. Every call costs a full model turn, so " ~
            "prefer one `steps` batch (click a field, type a line, press enter) " ~
            "over a see -> act -> see round trip per action; `screenshot` " ~
            "decides whether a fresh capture comes back (default: yes for " ~
            "`steps`, no for one action, always for `screen`). Keep focus: the " ~
            "action goes to whatever window is focused, so click the target " ~
            "first. The human can stop everything at any time with " ~
            computerUseKillSwitchChord ~ ". Keep reasoning minimal; only stop " ~
            "to plan when genuinely stuck (an unexpected dialog, a choice that " ~
            "needs judgement). Windows only.",
            `{"type":"object","properties":{"action":{"type":"string","enum":["screen","click","double_click","right_click","mouse_move","drag","focus","macro","loop","subagent","key","key_down","key_up","type","scroll","wait_for_change"],"description":"Action to perform; omit when using steps"},"x":{"type":"integer","description":"Screenshot x (click/double_click/right_click/mouse_move/drag/scroll)"},"y":{"type":"integer","description":"Screenshot y (click/double_click/right_click/mouse_move/drag/scroll)"},"x2":{"type":"integer","description":"Drag end x (screenshot pixels)"},"y2":{"type":"integer","description":"Drag end y (screenshot pixels)"},"text":{"type":"string","description":"Text to type (type); a newline presses Enter"},"name":{"type":"string","description":"Key for key/key_down/key_up (e.g. \"enter\", \"shift\", \"t\", \"ctrl+s\"; key_down key_up hold it until the matching key_up) OR the macro name for macro"},"amount":{"type":"integer","description":"Scroll wheel delta; negative scrolls down (default -120)"},"duration_ms":{"type":"integer","description":"drag: milliseconds for the move (default 400)"},"button":{"type":"string","enum":["left","right","middle"],"description":"drag: which button (default left)"},"title":{"type":"string","description":"focus: window title substring to bring to the front, e.g. \"Notepad\""},"repeat":{"type":"integer","description":"macro: how many times to run the sequence (default 1, max 64)"},"delay_ms":{"type":"integer","description":"macro: pause between repeats, in ms"},"seconds":{"type":"integer","description":"loop/subagent: time budget in seconds (loop default 10; subagent default 60)"},"task":{"type":"string","description":"subagent: the goal for the nested computer-use loop"},"max_steps":{"type":"integer","description":"subagent: how many model steps the nested loop may take (default 4, max 16)"},"frame":{"type":"string","enum":["full","half","quarter","diff"],"description":"subagent: per-step view - full/half/quarter (downscaled) or diff (only changed tiles at native scale with origins, fastest + most accurate coordinates; default half)"},"model":{"type":"string","description":"subagent: override the loop model for this call (default: the app's model)"},"reasoning":{"type":"string","enum":["none","default"],"description":"subagent: hidden thinking - none (fast, default) or default (slower, better spatial judgement)"},"region":{"type":"object","description":"screen: crop {x,y,w,h} in screenshot pixels for a zoomed view of one area","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"}}},"timeout_ms":{"type":"integer","description":"wait_for_change: how long to wait for the screen to change (default 5000)"},"interval_ms":{"type":"integer","description":"wait_for_change: how often to re-check, in ms (default 250)"},"screenshot":{"type":"boolean","description":"Return a fresh screenshot after the action(s) as an image"},"steps":{"type":"array","maxItems":32,"description":"Actions run in order in this one call, followed by a single screenshot","items":{"type":"object","properties":{"action":{"type":"string","enum":["screen","click","double_click","right_click","mouse_move","drag","focus","macro","loop","subagent","key","key_down","key_up","type","scroll","wait_for_change"]},"x":{"type":"integer"},"y":{"type":"integer"},"x2":{"type":"integer"},"y2":{"type":"integer"},"text":{"type":"string"},"name":{"type":"string"},"amount":{"type":"integer"},"duration_ms":{"type":"integer"},"button":{"type":"string"},"title":{"type":"string"},"repeat":{"type":"integer"},"delay_ms":{"type":"integer"},"seconds":{"type":"integer"},"task":{"type":"string"},"max_steps":{"type":"integer"},"frame":{"type":"string"},"model":{"type":"string"},"region":{"type":"object"},"timeout_ms":{"type":"integer"},"interval_ms":{"type":"integer"}},"required":["action"]}}},"required":[]}`
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

    // A new call always starts un-aborted; a press meant for a previous call
    // must not silently kill this one.
    computerUseAbortFlag = false;

    string action;
    int screenshotFlag = -1; // -1 absent, 0 false, 1 true
    JSONValue[] steps;
    if (value.type == JSONType.object)
    {
        action = jsonString(value, "action");
        screenshotFlag = jsonBoolFlag(value, "screenshot");
        if (auto field = "steps" in value.object)
            if (field.type == JSONType.array) steps = field.array;
    }
    action = strip(toLower(action));
    if (action.length == 0 && steps.length == 0)
        return failedResult("Error: computer requires an `action` " ~
            "(screen, click, double_click, right_click, mouse_move, drag, " ~
            "key, key_down, key_up, type, scroll, wait_for_change) or a " ~
            "`steps` batch.");

    version (Windows)
    {
        // Any key/button still held when the call ends is released here, so a
        // model that forgets `key_up` cannot leave an input stuck down.
        scope (exit) releaseHeldInputs();
        const started = MonoTime.currTime;
        computerUseWorkspace = workspace;
        ComputerUseResult result;
        // A batch screenshots by default: the caller's next move depends on the
        // result, and asking for it in the same call saves a whole model turn.
        if (steps.length > 0)
            result = runWindowsSteps(steps,
                screenshotFlag < 0 ? true : screenshotFlag == 1);
        else
            result = runWindowsAction(value, screenshotFlag == 1);
        result.output = withElapsed(result.output, started);
        return result;
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

/// Append how long the desktop work took. Latency is dominated by the model
/// turn around the call, so this isolates the part batching/macros shrink.
private string withElapsed(string text, MonoTime started)
{
    const ms = (MonoTime.currTime - started).total!"msecs";
    return text ~ " [" ~ to!string(cast(long) ms) ~ " ms]";
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
    private alias WPARAM = size_t;
    private alias LPARAM = size_t;

    private enum SRCCOPY = 0x00CC0020;
    private enum DIB_RGB_COLORS = 0;
    private enum SM_CXSCREEN = 0;
    private enum SM_CYSCREEN = 1;

    // Kill-switch hotkey: Ctrl+Alt+Shift+K. Detected with a low-level keyboard
    // hook (WH_KEYBOARD_LL) rather than RegisterHotKey: the hook fires even while
    // a fullscreen game owns focus, sees the chord regardless of who else may
    // have registered it, and (unlike RegisterHotKey) also sees injected input.
    private enum int WH_KEYBOARD_LL = 13;
    private enum uint WM_KEYDOWN = 0x0100;
    private enum uint WM_KEYUP = 0x0101;
    private enum uint WM_SYSKEYDOWN = 0x0104;
    private enum uint WM_SYSKEYUP = 0x0105;
    private enum DWORD VK_SHIFT = 0x10;
    private enum DWORD VK_CONTROL = 0x11;
    private enum DWORD VK_MENU = 0x12; // Alt
    private enum DWORD VK_K = 0x4B;
    private enum DWORD VK_LSHIFT = 0xA0;
    private enum DWORD VK_RSHIFT = 0xA1;
    private enum DWORD VK_LCONTROL = 0xA2;
    private enum DWORD VK_RCONTROL = 0xA3;
    private enum DWORD VK_LMENU = 0xA4;
    private enum DWORD VK_RMENU = 0xA5;
    private enum uint WM_QUIT = 0x0012;
    private enum uint PM_NOREMOVE = 0x0000;

    private struct KBDLLHOOKSTRUCT
    {
        DWORD vkCode;
        DWORD scanCode;
        DWORD flags;
        DWORD time;
        size_t dwExtraInfo;
    }

    private struct POINT
    {
        LONG x;
        LONG y;
    }

    private struct MSG
    {
        void* hwnd;
        UINT message;
        WPARAM wParam;
        LPARAM lParam;
        DWORD time;
        POINT pt;
    }

    private enum INPUT_MOUSE = 0;
    private enum INPUT_KEYBOARD = 1;
    private enum MOUSEEVENTF_LEFTDOWN = 0x0002;
    private enum MOUSEEVENTF_LEFTUP = 0x0004;
    private enum MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private enum MOUSEEVENTF_RIGHTUP = 0x0010;
    private enum MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    private enum MOUSEEVENTF_MIDDLEUP = 0x0040;
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
        void* GetForegroundWindow();
        int GetWindowTextW(void* hwnd, wchar* buffer, int maxCount);
        int IsWindowVisible(void* hwnd);
        int IsIconic(void* hwnd);
        int ShowWindow(void* hwnd, int command);
        int SetForegroundWindow(void* hwnd);
        int EnumWindows(void* enumProc, LPARAM lParam);
        int RegisterHotKey(void* hwnd, int id, uint modifiers, uint vk);
        int UnregisterHotKey(void* hwnd, int id);
        void* SetWindowsHookExW(int hookId, void* hookProc, void* hModule,
            uint threadId);
        int UnhookWindowsHookEx(void* hook);
        size_t CallNextHookEx(void* hook, int code, WPARAM wParam,
            LPARAM lParam);
        void* GetModuleHandleW(const wchar* name);
        int GetMessageW(MSG* message, void* hwnd, uint filterMin,
            uint filterMax);
        int PeekMessageW(MSG* message, void* hwnd, uint filterMin,
            uint filterMax, uint remove);
        int TranslateMessage(const MSG* message);
        int DispatchMessageW(const MSG* message);
        int PostThreadMessageW(uint threadId, uint message, WPARAM wParam,
            LPARAM lParam);
        uint GetCurrentThreadId();
        uint GetLastError();
        void* InternetOpenW(const wchar* agent, uint accessType,
            const wchar* proxy, const wchar* proxyBypass, uint flags);
        void* InternetConnectW(void* session, const wchar* host, ushort port,
            const wchar* user, const wchar* pass, uint service, uint flags,
            size_t context);
        void* HttpOpenRequestW(void* connect, const wchar* verb,
            const wchar* object, const wchar* slot, const wchar* referrer,
            const wchar** acceptTypes, uint flags, size_t context);
        int HttpSendRequestW(void* request, const wchar* headers,
            int headersLength, void* optional, uint optionalLength);
        int InternetReadFile(void* handle, void* buffer, uint toRead,
            uint* read);
        int InternetCloseHandle(void* handle);
        int HttpQueryInfoW(void* request, uint infoLevel, void* buffer,
            uint* bufferLength, uint* index);
    }

    // -----------------------------------------------------------------------
    // Kill-switch hotkey. A dedicated message-only thread registers
    // Ctrl+Alt+Shift+K and waits for WM_HOTKEY. It has to own its own thread and
    // queue because WM_HOTKEY is posted to the thread that registered the chord;
    // this way it fires regardless of which window (the game included) has
    // focus, and nothing in the UI toolkit has to change.
    // -----------------------------------------------------------------------

    private __gshared Thread killSwitchThread;
    private __gshared uint killSwitchThreadId;
    private __gshared bool killSwitchStop;
    private __gshared void* killSwitchHook;
    private __gshared bool llCtrlDown;
    private __gshared bool llAltDown;
    private __gshared bool llShiftDown;

    /// Best-effort trace of the kill-switch thread: hook install result and the
    /// moment the chord is seen. Lives in %TEMP% so it never touches the user's
    /// project, and is the only way to tell a failed install from a chord the OS
    /// never routed to us.
    private void killSwitchLog(string message)
    {
        try
        {
            import std.file : append;
            const dir = environment.get("TEMP", ".");
            append(dir ~ "/aurora-computeruse-killswitch.log", message ~ "\n");
        }
        catch (Exception) {}
    }

    private bool indicatesControl(DWORD vk)
    {
        return vk == VK_CONTROL || vk == VK_LCONTROL || vk == VK_RCONTROL;
    }

    private bool indicatesAlt(DWORD vk)
    {
        return vk == VK_MENU || vk == VK_LMENU || vk == VK_RMENU;
    }

    private bool indicatesShift(DWORD vk)
    {
        return vk == VK_SHIFT || vk == VK_LSHIFT || vk == VK_RSHIFT;
    }

    /// Low-level keyboard hook: tracks Ctrl/Alt/Shift and fires the kill switch
    /// when K goes down with all three held. Everything is passed through to the
    /// next hook, so the chord still reaches the focused app.
    private extern (Windows) size_t killSwitchKeyboardProc(int code,
        WPARAM wParam, LPARAM lParam)
    {
        if (code == 0)
        {
            try
            {
                auto info = cast(KBDLLHOOKSTRUCT*) cast(void*) lParam;
                if (info !is null)
                {
                    const vk = info.vkCode;
                    const down = wParam == WM_KEYDOWN ||
                        wParam == WM_SYSKEYDOWN;
                    const up = wParam == WM_KEYUP || wParam == WM_SYSKEYUP;
                    if (indicatesControl(vk))
                    {
                        if (down) llCtrlDown = true;
                        else if (up) llCtrlDown = false;
                    }
                    else if (indicatesAlt(vk))
                    {
                        if (down) llAltDown = true;
                        else if (up) llAltDown = false;
                    }
                    else if (indicatesShift(vk))
                    {
                        if (down) llShiftDown = true;
                        else if (up) llShiftDown = false;
                    }
                    else if (vk == VK_K && down && llCtrlDown && llAltDown &&
                        llShiftDown)
                    {
                        killSwitchLog("chord detected");
                        requestComputerUseAbort();
                    }
                }
            }
            catch (Throwable) {}
        }
        return CallNextHookEx(null, code, wParam, lParam);
    }

    private void runKillSwitchThread()
    {
        // Force this thread's message queue to exist; a low-level hook needs its
        // installing thread to pump messages.
        MSG message;
        PeekMessageW(&message, null, 0, 0, PM_NOREMOVE);
        killSwitchThreadId = GetCurrentThreadId();
        llCtrlDown = false;
        llAltDown = false;
        llShiftDown = false;
        killSwitchHook = SetWindowsHookExW(WH_KEYBOARD_LL,
            cast(void*) &killSwitchKeyboardProc, GetModuleHandleW(null), 0);
        if (killSwitchHook is null)
        {
            killSwitchLog("hook install failed, GetLastError=" ~
                to!string(GetLastError()));
            return;
        }
        killSwitchLog("hook installed; " ~ computerUseKillSwitchChord);
        scope (exit) UnhookWindowsHookEx(killSwitchHook);
        while (!killSwitchStop)
        {
            const got = GetMessageW(&message, null, 0, 0);
            if (got <= 0) break; // WM_QUIT (0) or error (-1)
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        killSwitchLog("thread stopped");
    }

    private void startKillSwitchThread()
    {
        if (killSwitchThread !is null) return;
        killSwitchStop = false;
        killSwitchThreadId = 0;
        killSwitchThread = new Thread(&runKillSwitchThread);
        killSwitchThread.isDaemon = true;
        killSwitchThread.start();
    }

    private void stopKillSwitchThread()
    {
        if (killSwitchThread is null) return;
        killSwitchStop = true;
        // The thread may not have published its id yet; give it a moment so the
        // WM_QUIT lands and GetMessage unblocks.
        foreach (_; 0 .. 100)
        {
            if (killSwitchThreadId != 0) break;
            Thread.sleep(msecs(10));
        }
        if (killSwitchThreadId != 0)
            PostThreadMessageW(killSwitchThreadId, WM_QUIT, 0, 0);
        killSwitchThread.join();
        killSwitchThread = null;
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

    /// Capture the screen. With a positive region (screenshot-space x,y,w,h)
    /// only that sub-rectangle is returned, sampled from the *native* pixels, so
    /// the result is a magnified crop - the way to read small UI text a
    /// half-scale full screenshot would blur away.
    private Capture captureScreen(int rx = -1, int ry = -1, int rw = 0,
        int rh = 0)
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

        // Resolve the source rectangle in native pixels. A region is given in
        // screenshot pixels and stays in that space: the crop is sampled with
        // the screen's own downscale, so one region image pixel equals one click
        // coordinate - the model can read a coordinate off a crop and use it
        // directly.
        const step = screenDownscale();
        int srcX = 0;
        int srcY = 0;
        int srcW = width;
        int srcH = height;
        if (rw > 0 && rh > 0)
        {
            srcX = rx * step;
            srcY = ry * step;
            srcW = rw * step;
            srcH = rh * step;
            if (srcX < 0) srcX = 0;
            if (srcY < 0) srcY = 0;
            if (srcX > width - 1) srcX = width - 1;
            if (srcY > height - 1) srcY = height - 1;
            if (srcX + srcW > width) srcW = width - srcX;
            if (srcY + srcH > height) srcH = height - srcY;
            if (srcW < step) srcW = step;
            if (srcH < step) srcH = step;
        }

        const outWidth = (srcW + step - 1) / step;
        const outHeight = (srcH + step - 1) / step;
        auto rgb = new ubyte[cast(size_t) outWidth * outHeight * 3];
        foreach (oy; 0 .. outHeight)
        {
            const sy = min(srcY + oy * step, height - 1);
            foreach (ox; 0 .. outWidth)
            {
                const sx = min(srcX + ox * step, width - 1);
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
        return screenshotResult(prefix, -1, -1, 0, 0);
    }

    private ComputerUseResult screenshotResult(string prefix, int rx, int ry,
        int rw, int rh)
    {
        auto capture = captureScreen(rx, ry, rw, rh);
        if (!capture.ok) return failedResult(capture.error);
        auto png = computerUseEncodePng(capture.width, capture.height,
            capture.rgb);
        const step = screenDownscale();
        const screenW = GetSystemMetrics(SM_CXSCREEN);
        const screenH = GetSystemMetrics(SM_CYSCREEN);
        string note;
        if (rw > 0 && rh > 0)
            note = "a " ~ to!string(rw) ~ "x" ~ to!string(rh) ~
                " region at " ~ to!string(rx) ~ "," ~ to!string(ry) ~
                " of the " ~ to!string(screenW) ~ "x" ~ to!string(screenH) ~
                " screen, so add the region origin to these pixels";
        else if (step > 1)
            note = "1/" ~ to!string(step) ~ " of the " ~ to!string(screenW) ~
                "x" ~ to!string(screenH) ~ " screen";
        const active = foregroundWindowTitle();
        ComputerUseResult result;
        result.output = prefix ~ " (" ~ to!string(capture.width) ~ "x" ~
            to!string(capture.height) ~ ", " ~ to!string(png.length) ~
            " bytes" ~ (note.length ? ", " ~ note : "") ~
            "; click in these image pixels" ~
            (active.length ? ", active window \"" ~ active ~ "\"" : "") ~
            ").";
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

    // -----------------------------------------------------------------------
    // Held inputs. `key_down`/`key_up` and `drag` leave inputs pressed across
    // steps, so we remember what is down (plain flags - cheap, and the kill
    // switch thread reads them) and can always release everything again.
    // -----------------------------------------------------------------------

    private __gshared bool[256] heldKeys;
    private __gshared bool heldLeftButton;
    private __gshared bool heldRightButton;
    private __gshared bool heldMiddleButton;

    private void sendKeyEvent(ushort vk, bool up)
    {
        INPUT[1] inputs;
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].ki.wVk = vk;
        inputs[0].ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
        SendInput(1, inputs.ptr, INPUT.sizeof);
    }

    /// Release every key and mouse button the agent is holding. Called by the
    /// kill switch immediately, and when a computer call ends, so nothing is
    /// ever left stuck down.
    private void releaseHeldInputs()
    {
        foreach (vk; 0 .. 256)
            if (heldKeys[vk])
            {
                sendKeyEvent(cast(ushort) vk, true);
                heldKeys[vk] = false;
            }
        if (heldLeftButton) { sendMouse(MOUSEEVENTF_LEFTUP); heldLeftButton = false; }
        if (heldRightButton) { sendMouse(MOUSEEVENTF_RIGHTUP); heldRightButton = false; }
        if (heldMiddleButton) { sendMouse(MOUSEEVENTF_MIDDLEUP); heldMiddleButton = false; }
    }

    /// Virtual key for a one-character token. A letter's virtual key is its
    /// *uppercase* code (VK 'A' = 0x41, not the ASCII 'a' = 0x61, which is the
    /// numeric keypad); digits and punctuation already match. Without this,
    /// `key: "k"` presses keypad '+', not the K key.
    private ushort vkForToken(string token)
    {
        if (token.length != 1) return 0;
        const ch = token[0];
        if (ch >= 'a' && ch <= 'z') return cast(ushort) (ch - 'a' + 'A');
        return cast(ushort) ch;
    }

    /// Resolve a name for `key_down`/`key_up`: a normal virtual key, a modifier
    /// (shift/ctrl/alt/win), or a single character.
    private ushort resolveHoldKey(string token)
    {
        const t = strip(toLower(token));
        if (t.length == 0) return 0;
        ushort vk = virtualKeyFor(t);
        if (vk == 0) vk = modifierKeyFor(t);
        if (vk == 0) vk = vkForToken(t);
        return vk;
    }

    private ComputerUseResult runHoldKey(string keyName, bool up)
    {
        const vk = resolveHoldKey(keyName);
        if (vk == 0)
            return failedResult("Error: unknown key '" ~ keyName ~ "'.");
        sendKeyEvent(vk, up);
        heldKeys[vk & 0xFF] = !up;
        return succeededResult((up ? "Released key \"" : "Held key \"") ~
            keyName ~ "\".");
    }

    /// Press a mouse button, move through interpolated points, release. Used
    /// for box-select (left), order drags (right) and camera drags (middle).
    /// `durationMs` controls how long the move takes.
    private void dragMouse(int x1, int y1, int x2, int y2, int durationMs,
        string button)
    {
        DWORD down = MOUSEEVENTF_LEFTDOWN;
        DWORD up = MOUSEEVENTF_LEFTUP;
        if (button == "right")
        {
            down = MOUSEEVENTF_RIGHTDOWN;
            up = MOUSEEVENTF_RIGHTUP;
        }
        else if (button == "middle" || button == "wheel")
        {
            down = MOUSEEVENTF_MIDDLEDOWN;
            up = MOUSEEVENTF_MIDDLEUP;
        }

        moveCursor(x1, y1);
        Thread.sleep(msecs(40));
        sendMouse(down);
        if (down == MOUSEEVENTF_LEFTDOWN) heldLeftButton = true;
        else if (down == MOUSEEVENTF_RIGHTDOWN) heldRightButton = true;
        else heldMiddleButton = true;
        Thread.sleep(msecs(40));

        int steps = durationMs / 16;
        if (steps < 2) steps = 2;
        if (steps > 150) steps = 150;
        foreach (i; 1 .. steps + 1)
        {
            if (computerUseAbortActive()) break;
            const t = cast(double) i / steps;
            moveCursor(cast(int) (x1 + (x2 - x1) * t),
                cast(int) (y1 + (y2 - y1) * t));
            Thread.sleep(msecs(16));
        }
        sendMouse(up);
        if (down == MOUSEEVENTF_LEFTDOWN) heldLeftButton = false;
        else if (down == MOUSEEVENTF_RIGHTDOWN) heldRightButton = false;
        else heldMiddleButton = false;
    }

    // -----------------------------------------------------------------------
    // Window awareness. Input (type/key/click) goes to whatever window holds
    // focus, and a wrong guess is otherwise invisible - so every action reports
    // the active window, and `focus` brings a window forward by title. This is
    // what makes "typed, but nothing appeared" diagnosable instead of silent.
    // -----------------------------------------------------------------------

    private enum int SW_RESTORE = 9;
    private enum uint INTERNET_OPEN_TYPE_PRECONFIG = 0;
    private enum uint INTERNET_SERVICE_HTTP = 3;
    private enum ushort INTERNET_DEFAULT_HTTPS_PORT = 443;
    private enum uint INTERNET_FLAG_RELOAD = 0x80000000;
    private enum uint INTERNET_FLAG_SECURE = 0x00800000;
    private enum uint INTERNET_FLAG_NO_CACHE_WRITE = 0x04000000;
    private enum uint HTTP_QUERY_STATUS_CODE = 19;
    private enum uint HTTP_QUERY_FLAG_NUMBER = 0x20000000;
    private __gshared string findNeedle;
    private __gshared void* findResult;
    private __gshared bool findExact;
    private __gshared size_t findTitleLength;

    private string windowTitleOf(void* hwnd)
    {
        if (hwnd is null) return "";
        wchar[256] buffer;
        const length = GetWindowTextW(hwnd, buffer.ptr,
            cast(int) buffer.length);
        if (length <= 0) return "";
        return to!string(buffer[0 .. length]);
    }

    private string foregroundWindowTitle()
    {
        return windowTitleOf(GetForegroundWindow());
    }

    private extern (Windows) int enumWindowsProc(void* hwnd, LPARAM)
    {
        try
        {
            if (IsWindowVisible(hwnd))
            {
                const title = strip(toLower(windowTitleOf(hwnd)));
                if (title.length > 0 && findNeedle.length > 0 &&
                    indexOf(title, findNeedle) >= 0)
                {
                    // Prefer an exact title, then the shortest match: a browser
                    // window ("<tab> and 43 more pages - Edge") can contain the
                    // needle in a tab title, while the real target is short.
                    const exact = title == findNeedle;
                    if (findResult is null ||
                        (exact && !findExact) ||
                        (exact == findExact && title.length < findTitleLength))
                    {
                        findResult = hwnd;
                        findExact = exact;
                        findTitleLength = title.length;
                    }
                }
            }
        }
        catch (Throwable) {}
        return 1;
    }

    /// First visible top-level window whose title contains `needle`
    /// (case-insensitive). null when nothing matches.
    private void* findTopWindow(string needle)
    {
        findNeedle = strip(toLower(needle));
        findResult = null;
        findExact = false;
        findTitleLength = size_t.max;
        if (findNeedle.length == 0) return null;
        EnumWindows(cast(void*) &enumWindowsProc, 0);
        auto result = findResult;
        findNeedle = null;
        findResult = null;
        return result;
    }

    /// Append the currently focused window, so a caller can tell where input
    /// landed (or that it landed somewhere unexpected).
    private string withActiveWindow(string text)
    {
        const title = foregroundWindowTitle();
        if (title.length == 0) return text;
        return text ~ " (active window: \"" ~ title ~ "\")";
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
        if (vk == 0) vk = vkForToken(last);
        if (vk == 0)
            return failedResult("Error: unknown key '" ~ last ~ "'.");
        pressChord(modifiers, vk);
        return succeededResult("Pressed key \"" ~ keyName ~ "\".");
    }

    /// One computer action, driven by the JSON object (top-level call or one
    /// entry of a `steps` batch). Reads every field it needs from `value` so
    /// the two call paths share one implementation.
    private ComputerUseResult runWindowsAction(JSONValue value, bool screenshot)
    {
        const action = strip(toLower(jsonString(value, "action")));
        const x = cast(int) jsonInt(value, "x", 0);
        const y = cast(int) jsonInt(value, "y", 0);
        const x2 = cast(int) jsonInt(value, "x2", 0);
        const y2 = cast(int) jsonInt(value, "y2", 0);
        const text = jsonString(value, "text");
        const keyName = jsonString(value, "name");
        const amount = cast(int) jsonInt(value, "amount", -120);
        const timeoutMs = jsonInt(value, "timeout_ms", 5000);
        const intervalMs = jsonInt(value, "interval_ms", 250);
        const durationMs = cast(int) jsonInt(value, "duration_ms", 400);
        const button = strip(toLower(jsonString(value, "button")));

        switch (action)
        {
            case "screen":
                if (auto region = "region" in value.object)
                    if (region.type == JSONType.object)
                        return screenshotResult("Captured screen region",
                            cast(int) jsonInt(*region, "x", 0),
                            cast(int) jsonInt(*region, "y", 0),
                            cast(int) jsonInt(*region, "w", 0),
                            cast(int) jsonInt(*region, "h", 0));
                return screenshotResult("Captured the screen");
            case "macro":
                return withFinalScreenshot(runMacro(value, computerUseWorkspace),
                    screenshot);
            case "loop":
                return withFinalScreenshot(runLoop(value, computerUseWorkspace),
                    screenshot);
            case "subagent":
                return runSubAgent(value, computerUseWorkspace);
            case "focus":
            {
                const title = jsonString(value, "title");
                if (title.length == 0)
                    return failedResult("Error: focus requires `title`.");
                auto hwnd = findTopWindow(title);
                if (hwnd is null)
                    return failedResult("Error: no visible window matches \"" ~
                        title ~ "\".");
                if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
                SetForegroundWindow(hwnd);
                Thread.sleep(msecs(150));
                return withOptionalScreenshot("Focused window \"" ~
                    foregroundWindowTitle() ~ "\".", screenshot);
            }
            case "click":
                clickAt(x, y, 1);
                return withOptionalScreenshot(withActiveWindow("Clicked at " ~
                    to!string(x) ~ "," ~ to!string(y) ~ "."), screenshot);
            case "double_click":
                clickAt(x, y, 2);
                return withOptionalScreenshot(withActiveWindow("Double-clicked " ~
                    "at " ~ to!string(x) ~ "," ~ to!string(y) ~ "."),
                    screenshot);
            case "right_click":
                clickAt(x, y, 1, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP);
                return withOptionalScreenshot(withActiveWindow("Right-clicked " ~
                    "at " ~ to!string(x) ~ "," ~ to!string(y) ~ "."),
                    screenshot);
            case "mouse_move":
                moveCursor(x, y);
                return withOptionalScreenshot("Moved the pointer to " ~
                    to!string(x) ~ "," ~ to!string(y) ~ ".", screenshot);
            case "drag":
                dragMouse(x, y, x2, y2, durationMs, button);
                return withOptionalScreenshot(withActiveWindow("Dragged " ~
                    (button.length > 0 ? button : "left") ~ " from " ~
                    to!string(x) ~ "," ~ to!string(y) ~ " to " ~
                    to!string(x2) ~ "," ~ to!string(y2) ~ "."), screenshot);
            case "type":
                if (text.length == 0)
                    return failedResult("Error: type requires `text`.");
                typeText(text);
                return withOptionalScreenshot(withActiveWindow("Typed " ~
                    to!string(text.length) ~ " characters."), screenshot);
            case "key":
                return keyResultAction(runKey(keyName), screenshot);
            case "key_down":
                return keyResultAction(runHoldKey(keyName, false), screenshot);
            case "key_up":
                return keyResultAction(runHoldKey(keyName, true), screenshot);
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

    /// Shared by key/key_down/key_up: keep a failure as-is, otherwise report the
    /// key plus the active window, so a mis-focused keypress is visible.
    private ComputerUseResult keyResultAction(ComputerUseResult result,
        bool screenshot)
    {
        if (result.failed) return result;
        return withOptionalScreenshot(withActiveWindow(result.output),
            screenshot);
    }

    /// Attach one screenshot after a macro/loop, so the next decision sees the
    /// result of the burst instead of acting blind.
    private ComputerUseResult withFinalScreenshot(ComputerUseResult result,
        bool screenshot)
    {
        if (!screenshot || result.failed) return result;
        auto shot = screenshotResult("Screen after the action");
        if (shot.failed)
        {
            result.output ~= " " ~ shot.output;
            result.failed = true;
            return result;
        }
        result.output ~= " " ~ shot.output;
        result.images = shot.images;
        return result;
    }

    /// Load a macro's step array from `<workspace>/computer-macros.json`.
    /// Returns null and sets `error` when it cannot be read or found.
    private JSONValue[] macroSteps(string name, string workspace,
        out string error)
    {
        error = null;
        const path = (workspace.length ? workspace ~ "/" : "") ~
            "computer-macros.json";
        string body;
        try body = readText(path);
        catch (Exception)
        {
            error = "Error: cannot read " ~ path ~
                " (define macros as a JSON object of name -> [steps]).";
            return null;
        }
        JSONValue root;
        try root = parseJSON(body);
        catch (Exception)
        {
            error = "Error: " ~ path ~ " is not valid JSON.";
            return null;
        }
        if (root.type != JSONType.object)
        {
            error = "Error: " ~ path ~
                " must be a JSON object of name -> [steps].";
            return null;
        }
        auto entry = name in root.object;
        if (entry is null)
        {
            string names;
            foreach (key, _; root.object)
                names ~= (names.length ? ", " : "") ~ key;
            error = "Error: unknown macro \"" ~ name ~ "\". Defined: " ~
                (names.length ? names : "(none)");
            return null;
        }
        if (entry.type != JSONType.array)
        {
            error = "Error: macro \"" ~ name ~
                "\" must be an array of steps.";
            return null;
        }
        return entry.array;
    }

    /// Run a named sequence of steps from `<workspace>/computer-macros.json`.
    /// A macro is one model turn that performs many actions - the fast path for a
    /// learned sequence (a build order, a select+move, a hotkey pattern), so
    /// routine play costs no reasoning per action.
    /// `repeat` runs the whole sequence that many times and `delay_ms` pauses
    /// between runs, so a learned routine can play as a loop without any model.
    private ComputerUseResult runMacro(JSONValue value, string workspace)
    {
        const name = strip(jsonString(value, "name"));
        if (name.length == 0)
            return failedResult("Error: macro requires `name`.");
        int repeat = cast(int) jsonInt(value, "repeat", 1);
        if (repeat < 1) repeat = 1;
        if (repeat > 64) repeat = 64;
        const delayMs = jsonInt(value, "delay_ms", 0);
        string error;
        auto steps = macroSteps(name, workspace, error);
        if (error !is null) return failedResult(error);
        auto builder = appender!string();
        foreach (iteration; 0 .. repeat)
        {
            if (computerUseAbortActive())
            {
                builder.put("stopped by the kill switch (" ~
                    computerUseKillSwitchChord ~ ")\n");
                return failedResult(builder.data);
            }
            auto result = runWindowsSteps(steps, false);
            builder.put("Macro \"" ~ name ~ "\" run " ~
                to!string(iteration + 1) ~ ": " ~ result.output);
            if (builder.data.length > 0 && builder.data[$ - 1] != '\n')
                builder.put("\n");
            if (result.failed)
            {
                ComputerUseResult failure;
                failure.output = builder.data;
                failure.failed = true;
                failure.images = result.images;
                return failure;
            }
            if (iteration + 1 < repeat && delayMs > 0)
                Thread.sleep(msecs(delayMs));
        }
        ComputerUseResult done;
        done.output = builder.data;
        return done;
    }

    /// Reflex executor: repeat a macro for a bounded time at a fixed cadence,
    /// with no model turns - the fast layer. Stops early on the kill switch.
    private ComputerUseResult runLoop(JSONValue value, string workspace)
    {
        const name = strip(jsonString(value, "name"));
        if (name.length == 0)
            return failedResult("Error: loop requires `name` (a macro).");
        long seconds = jsonInt(value, "seconds", 10);
        if (seconds < 1) seconds = 1;
        if (seconds > 300) seconds = 300;
        long intervalMs = jsonInt(value, "interval_ms", 500);
        if (intervalMs < 100) intervalMs = 100;
        if (intervalMs > 60000) intervalMs = 60000;
        string error;
        auto steps = macroSteps(name, workspace, error);
        if (error !is null) return failedResult(error);
        const started = MonoTime.currTime;
        const deadline = started + msecs(seconds * 1000);
        size_t runs;
        while (MonoTime.currTime < deadline)
        {
            if (computerUseAbortActive())
                return failedResult("Loop \"" ~ name ~ "\" stopped by the " ~
                    "kill switch (" ~ computerUseKillSwitchChord ~ ") after " ~
                    to!string(runs) ~ " run(s).");
            auto result = runWindowsSteps(steps, false);
            ++runs;
            if (result.failed)
            {
                ComputerUseResult failure;
                failure.output = "Loop \"" ~ name ~ "\" stopped after " ~
                    to!string(runs) ~ " run(s): " ~ result.output;
                failure.failed = true;
                failure.images = result.images;
                return failure;
            }
            if (MonoTime.currTime >= deadline) break;
            Thread.sleep(msecs(intervalMs));
        }
        const elapsed = (MonoTime.currTime - started).total!"msecs";
        ComputerUseResult done;
        done.output = "Loop \"" ~ name ~ "\": " ~ to!string(runs) ~
            " run(s) in " ~ to!string(cast(long) elapsed) ~ " ms.";
        return done;
    }

    // -----------------------------------------------------------------------
    // Subagent: a nested model loop. The main agent hands it a short task; it
    // requests the loop model (with the `computer` tool and one screenshot),
    // executes the tool calls it returns, feeds the results back, and repeats
    // until the model answers without a tool call or the budget runs out.
    // -----------------------------------------------------------------------

    private struct UrlParts
    {
        bool secure;
        ushort port;
        string host;
        string path;
    }

    private UrlParts parseUrl(string url)
    {
        UrlParts parts;
        string rest = url;
        if (rest.startsWith("https://"))
        {
            parts.secure = true;
            parts.port = INTERNET_DEFAULT_HTTPS_PORT;
            rest = rest[8 .. $];
        }
        else if (rest.startsWith("http://"))
        {
            parts.port = 80;
            rest = rest[7 .. $];
        }
        const slash = indexOf(rest, "/");
        if (slash < 0)
        {
            parts.host = rest;
            parts.path = "/";
        }
        else
        {
            parts.host = rest[0 .. slash];
            parts.path = rest[slash .. $];
        }
        return parts;
    }

    /// Quote a string as a JSON string literal.
    private string jsonQuote(string text)
    {
        auto builder = appender!string();
        builder.put('"');
        foreach (dchar c; text)
        {
            if (c == '"') builder.put("\\\"");
            else if (c == '\\') builder.put("\\\\");
            else if (c == '\n') builder.put("\\n");
            else if (c == '\r') builder.put("\\r");
            else if (c == '\t') builder.put("\\t");
            else if (cast(uint) c < 0x20)
            {
                enum hex = "0123456789abcdef";
                builder.put("\\u00");
                builder.put(hex[(cast(uint) c >> 4) & 0xF]);
                builder.put(hex[cast(uint) c & 0xF]);
            }
            else builder.put(c);
        }
        builder.put('"');
        return builder.data;
    }

    /// POST a JSON body over WinINet and return the response text.
    /// Reused connection: opening a WinINet session + TLS handshake costs ~0.3-0.6 s,
    /// which would be paid on every round of the loop.
    private struct HttpConn
    {
        void* session;
        void* connect;
    }

    private HttpConn openHttp(string url, out string error)
    {
        HttpConn conn;
        error = null;
        const parts = parseUrl(url);
        conn.session = InternetOpenW(toUTF16z("Aurora OpenCode"),
            INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0);
        if (conn.session is null)
        {
            error = "could not open an HTTP session.";
            return conn;
        }
        conn.connect = InternetConnectW(conn.session, toUTF16z(parts.host),
            parts.port, null, null, INTERNET_SERVICE_HTTP, 0, 0);
        if (conn.connect is null)
        {
            error = "could not connect to " ~ parts.host ~ ".";
            InternetCloseHandle(conn.session);
            conn.session = null;
        }
        return conn;
    }

    private void closeHttp(ref HttpConn conn)
    {
        if (conn.connect !is null) InternetCloseHandle(conn.connect);
        if (conn.session !is null) InternetCloseHandle(conn.session);
        conn.connect = null;
        conn.session = null;
    }

    private string httpPostJson(HttpConn conn, string url, string apiKey,
        string body,
        out string error)
    {
        error = null;
        const parts = parseUrl(url);
        if (conn.connect is null)
        {
            error = "HTTP connection is not open.";
            return null;
        }
        uint flags = INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE;
        if (parts.secure) flags |= INTERNET_FLAG_SECURE;
        auto request = HttpOpenRequestW(conn.connect, toUTF16z("POST"),
            toUTF16z(parts.path), null, null, null, flags, 0);
        if (request is null)
        {
            error = "could not open the request.";
            return null;
        }
        scope (exit) InternetCloseHandle(request);
        const headers = "Content-Type: application/json\r\n" ~
            "Authorization: Bearer " ~ apiKey ~ "\r\n" ~
            "x-opencode-session: aurora-subagent\r\n";
        if (!HttpSendRequestW(request, toUTF16z(headers), -1,
            cast(void*) body.ptr, cast(uint) body.length))
        {
            error = "send failed (" ~ to!string(GetLastError()) ~ ").";
            return null;
        }
        uint status;
        uint statusLength = uint.sizeof;
        uint statusIndex;
        if (!HttpQueryInfoW(request, HTTP_QUERY_STATUS_CODE |
            HTTP_QUERY_FLAG_NUMBER, &status, &statusLength, &statusIndex))
            status = 0;
        if (status != 200)
        {
            try
            {
                import std.file : write;
                const dir = environment.get("TEMP", ".");
                write(dir ~ "/aurora-subagent-request.json", body);
            }
            catch (Exception) {}
            error = "HTTP " ~ to!string(status) ~ " (body " ~
                to!string(body.length) ~ " bytes).";
            return null;
        }
        auto builder = appender!string();
        ubyte[8192] buffer;
        while (true)
        {
            uint read;
            if (!InternetReadFile(request, buffer.ptr,
                cast(uint) buffer.length, &read))
            {
                error = "read failed.";
                return null;
            }
            if (read == 0) break;
            foreach (i; 0 .. read) builder.put(cast(char) buffer[i]);
        }
        return builder.data;
    }

    /// Nearest-neighbour half-size copy of an RGB frame. The subagent sends one
    /// fresh frame per step; halving it keeps the image small (fewer image
    /// tokens, faster prefill) while staying readable.
    private ubyte[] halfRgb(int width, int height, in ubyte[] rgb,
        out int outWidth, out int outHeight)
    {
        outWidth = (width + 1) / 2;
        outHeight = (height + 1) / 2;
        auto out_ = new ubyte[cast(size_t) outWidth * outHeight * 3];
        foreach (y; 0 .. outHeight)
        {
            const sy = min(y * 2, height - 1);
            foreach (x; 0 .. outWidth)
            {
                const sx = min(x * 2, width - 1);
                const src = (cast(size_t) sy * width + sx) * 3;
                const dst = (cast(size_t) y * outWidth + x) * 3;
                out_[dst] = rgb[src];
                out_[dst + 1] = rgb[src + 1];
                out_[dst + 2] = rgb[src + 2];
            }
        }
        return out_;
    }

    /// One user message holding a caption and its image.
    private string imagePart(string caption, ubyte[] png)
    {
        return multiImagePart([caption], [png]);
    }

    /// One user message holding several caption/image pairs (the diff mode sends
    /// only the tiles that changed, each at native scale).
    private string multiImagePart(string[] captions, ubyte[][] pngs)
    {
        auto parts = appender!string();
        parts.put(`,{"role":"user","content":[`);
        foreach (i; 0 .. captions.length)
        {
            if (i > 0) parts.put(",");
            parts.put(`{"type":"text","text":` ~ jsonQuote(captions[i]) ~ `},`);
            parts.put(`{"type":"image_url","image_url":{"url":` ~
                jsonQuote("data:image/png;base64," ~
                Base64.encode(pngs[i]).idup) ~ `}}`);
        }
        parts.put(`]}`);
        return parts.data;
    }

    private string textPart(string text)
    {
        return `,{"role":"user","content":` ~ jsonQuote(text) ~ `}`;
    }

    /// A user message carrying one image a nested tool call produced (screenshots
    /// must reach the model as image parts; tool messages are text only).
    private string attachmentPart(string caption, ChatImageAttachment image)
    {
        return `,{"role":"user","content":[{"type":"text","text":` ~
            jsonQuote(caption) ~ `},{"type":"image_url","image_url":{"url":` ~
            jsonQuote("data:" ~ image.mimeType ~ ";base64," ~ image.base64Data) ~
            `}}]}`;
    }

    /// Extract a sub-rectangle of an RGB frame.
    private ubyte[] cropRgb(int width, in ubyte[] rgb, int x, int y, int w,
        int h)
    {
        auto out_ = new ubyte[cast(size_t) w * h * 3];
        foreach (row; 0 .. h)
            foreach (col; 0 .. w)
            {
                const src = (cast(size_t) (y + row) * width + (x + col)) * 3;
                const dst = (cast(size_t) row * w + col) * 3;
                out_[dst] = rgb[src];
                out_[dst + 1] = rgb[src + 1];
                out_[dst + 2] = rgb[src + 2];
            }
        return out_;
    }

    /// How many pixels in one tile differ noticeably between two frames.
    private size_t tileChangeCount(int width, int tileX, int tileY, int tileW,
        int tileH, in ubyte[] a, in ubyte[] b)
    {
        size_t changed;
        foreach (row; 0 .. tileH)
            foreach (col; 0 .. tileW)
            {
                const p = (cast(size_t) (tileY + row) * width +
                    (tileX + col)) * 3;
                const delta = absolute(cast(int) a[p] - b[p]) +
                    absolute(cast(int) a[p + 1] - b[p + 1]) +
                    absolute(cast(int) a[p + 2] - b[p + 2]);
                if (delta > 24) ++changed;
            }
        return changed;
    }

    /// Scale a nested `computer` call's coordinates up from the per-step frame's
    /// True when a nested computer call asks for a `region` crop (native-res
    /// detail, unlike the cheap per-step frame - those must still run).
    private bool computerArgsHaveRegion(string argsJson)
    {
        JSONValue parsed;
        try parsed = parseJSON(argsJson);
        catch (Exception) return false;
        if (parsed.type != JSONType.object) return false;
        auto region = "region" in parsed.object;
        return region !is null && region.type == JSONType.object;
    }

    /// The `action` of a nested computer call, for decisions the loop makes about
    /// it (notably: refuse a redundant `screen` capture).
    private string computerActionOf(string argsJson)
    {
        JSONValue parsed;
        try parsed = parseJSON(argsJson);
        catch (Exception) return "";
        if (parsed.type != JSONType.object) return "";
        if (auto field = "action" in parsed.object)
            if (field.type == JSONType.string) return strip(toLower(field.str));
        return "";
    }

    /// Scale a nested `computer` call's coordinates up from the per-step frame's
    /// pixel space to the tool's screenshot space. When the model reads a half or
    /// quarter frame, its x/y are in that image; without this the click lands in
    /// the wrong place.
    private string scaleComputerArgs(string argsJson, int factor)
    {
        if (factor <= 1 || argsJson.length == 0) return argsJson;
        JSONValue parsed;
        try parsed = parseJSON(argsJson);
        catch (Exception) return argsJson;
        if (parsed.type != JSONType.object) return argsJson;
        void scaleOne(ref JSONValue node)
        {
            if (node.type != JSONType.object) return;
            foreach (key; ["x", "y", "x2", "y2"])
                if (auto field = key in node.object)
                    if (field.type == JSONType.integer)
                        (*field).integer = (*field).integer * factor;
            if (auto batch = "steps" in node.object)
                if (batch.type == JSONType.array)
                    foreach (ref step; batch.array) scaleOne(step);
        }
        scaleOne(parsed);
        try return toJSON(parsed);
        catch (Exception) return argsJson;
    }

    /// Test hook: scale a nested call's coordinates exactly as the subagent
    /// loop does before executing it (see scaleComputerArgs).
    public string computerUseScaledArgsForTesting(string argsJson, int factor)
    {
        return scaleComputerArgs(argsJson, factor);
    }

    /// Test hook: whether two frames differ, using the same signature the
    /// subagent loop uses to notice a missed action.
    public bool computerUseFramesDifferForTesting(in ubyte[] a, in ubyte[] b)
    {
        return frameSignature(a) != frameSignature(b);
    }

    /// Test hook: whether every coordinate in a nested call lies inside a
    /// `w` x `h` frame (see computerArgsWithinFrame).
    public bool computerUseArgsWithinFrameForTesting(string argsJson, int w, int h)
    {
        return computerArgsWithinFrame(argsJson, w, h);
    }

    /// True when every x/y/x2/y2 in a nested `computer` call (including one
    /// nested inside `steps`) lies inside a `w` x `h` frame. The loop uses this
    /// to reject a call whose coordinates are outside the frame the model was
    /// looking at - a misread would otherwise become an off-screen click.
    private bool computerArgsWithinFrame(string argsJson, int w, int h)
    {
        if (w <= 0 || h <= 0) return true;
        JSONValue parsed;
        try parsed = parseJSON(argsJson);
        catch (Exception) return true;
        if (parsed.type != JSONType.object) return true;
        bool within = true;
        void check(ref JSONValue node)
        {
            if (node.type != JSONType.object) return;
            foreach (key; ["x", "y", "x2", "y2"])
                if (auto field = key in node.object)
                    if (field.type == JSONType.integer)
                    {
                        const isX = key == "x" || key == "x2";
                        const max = isX ? w : h;
                        if (field.integer < 0 || field.integer >= max)
                            within = false;
                    }
            if (auto batch = "steps" in node.object)
                if (batch.type == JSONType.array)
                    foreach (ref step; batch.array) check(step);
        }
        check(parsed);
        return within;
    }

    /// Normalize a `frame` argument to one of full/half/quarter/diff. Unknown or
    /// missing values fall back to `quarter`. NOTE: `half` must be in the
    /// allowed set - it used to be coerced to `quarter`, so a caller asking for
    /// `half` silently got the tiny 240x135 frame (a real accuracy loss).
    private string normalizeFrameScale(string frame)
    {
        auto s = strip(toLower(frame));
        if (s != "full" && s != "half" && s != "quarter" && s != "diff")
            s = "quarter";
        return s;
    }

    /// How much a frame is downscaled from the 1:1 click space.
    private int frameFactorOf(string frameScale)
    {
        if (frameScale == "quarter") return 4;
        if (frameScale == "half") return 2;
        return 1;
    }

    /// Test hook: the downscale factor the loop uses for a `frame` argument.
    public int computerUseFrameFactorForTesting(string frame)
    {
        return frameFactorOf(normalizeFrameScale(frame));
    }

    private ComputerUseResult runSubAgent(JSONValue value, string workspace)
    {
        const task = jsonString(value, "task");
        if (task.length == 0)
            return failedResult("Error: subagent requires `task`.");
        if (computerUseProviderApiKey.length == 0 ||
            computerUseProviderBaseUrl.length == 0 ||
            computerUseProviderModel.length == 0)
            return failedResult("Error: subagent has no provider configured.");
        int maxSteps = cast(int) jsonInt(value, "max_steps", 4);
        if (maxSteps < 1) maxSteps = 1;
        if (maxSteps > 16) maxSteps = 16;
        // `frame` trades image detail for latency: full / half / quarter. A
        // downscaled frame is not 1:1 with click coordinates, so the model's
        // pixel readings are scaled back up before we execute (see frameFactor).
        string frameScale = normalizeFrameScale(jsonString(value, "frame"));
        const frameFactor = frameFactorOf(frameScale);
        // `model` overrides the loop model for this call (e.g. the faster vision
        // variant) without restarting the app. The default loop model is the
        // fast, cheap vision model (measured ~40% faster per round than
        // deepseek-v4.1-flash on the same CoH1 task); the app's own model is only
        // used if a call explicitly asks for it.
        string loopModel = jsonString(value, "model");
        if (loopModel.length == 0) loopModel = computerUseDefaultLoopModel;
        // `reasoning`: "default" (thought on) is slower but better at spatial
        // judgements; "none" omits hidden thinking for the fastest reactions.
        // Default is "none" for the ~6 s-per-reaction playtest target; pass
        // "reasoning":"default" to trade speed back for spatial care.
        string reasoningArg = strip(toLower(jsonString(value, "reasoning")));
        if (reasoningArg.length == 0) reasoningArg = "none";
        long seconds = jsonInt(value, "seconds", 60);
        if (seconds < 5) seconds = 5;
        if (seconds > 300) seconds = 300;
        const deadline = MonoTime.currTime + msecs(seconds * 1000);
        const endpoint = computerUseProviderBaseUrl ~ "/chat/completions";
        // One connection for the whole run: a fresh session + TLS handshake per
        // round would add ~0.3-0.6 s to every step.
        string httpError;
        auto http = openHttp(endpoint, httpError);
        if (httpError !is null)
            return failedResult("Error: subagent " ~ httpError);
        scope (exit) closeHttp(http);
        auto toolDefs = experimentalComputerUseTools();
        if (toolDefs.length == 0)
            return failedResult("Error: subagent needs the computer tool.");
        const toolJson = `{"type":"function","function":{"name":` ~
            jsonQuote(toolDefs[0].name) ~ `,"description":` ~
            jsonQuote(toolDefs[0].description) ~ `,"parameters":` ~
            toolDefs[0].parametersJson ~ `}}`;
        string system = "You are a fast computer-use operator driving the local " ~
            "desktop for a short burst. Each step, call the `computer` tool to " ~
            "act. A screenshot of the current screen is attached to every " ~
            "message; read positions off it directly (in that image's own pixel " ~
            "space - the tool scales them) and do NOT spend a step calling " ~
            "`screen` for the whole screen. Do call `screen` with a small " ~
            "`region` when you must read fine detail (region crops come back at " ~
            "full resolution). After each action, look at the newly attached frame before " ~
            "deciding the next one, and never repeat the same click twice. " ~
            "Always LOCATE the target visually in the current frame - never reuse " ~
            "a coordinate from notes or memory, because the window may have moved " ~
            "or changed size. If an action was meant to change the screen and the " ~
            "next frame shows no change, that action missed: find the control " ~
            "visually and click a different point, do not click the same spot " ~
            "again. If the current frame ALREADY shows the goal state, stop and " ~
            "answer immediately without clicking. If a menu is open because the " ~
            "app lost focus (e.g. a game showing RESUME), click RESUME first. " ~
            "Keep actions " ~
            "small and reversible, and plan the WHOLE burst up front: put every " ~
            "action you can foresee into ONE `steps` batch (e.g. press win, type " ~
            "'notepad', press enter, wait, then type the text) - one round per " ~
            "keystroke is far too slow. Unless the goal is already achieved, " ~
            "EVERY step must contain at least one input action (click, " ~
            "double_click, right_click, drag, type, key or scroll); never end a " ~
            "step having only inspected the screen, and do not burn a step on a " ~
            "`screen` region read when you can already act on what you see. When " ~
            "the goal is reached or you are stuck, reply with a short plain-text " ~
            "summary and no tool call.";
        // The loop has no memory of its own: carry the project's playbook into
        // the prompt so it knows the game's menus and hotkeys. Bounded, and the
        // live screen wins any conflict.
        try
        {
            const notesPath = (workspace.length ? workspace ~ "/" : "") ~
                "company-of-heroes-1.md";
            const notes = readText(notesPath);
            if (notes.length > 0)
                system ~= "\n\nProject notes for this machine (may be stale; " ~
                    "the live screen wins any conflict):\n" ~
                    notes[0 .. (notes.length > 2500 ? 2500 : notes.length)];
        }
        catch (Exception) {}
        auto messages = appender!string();
        messages.put(`[{"role":"system","content":` ~ jsonQuote(system) ~ `}`);
        messages.put(`,{"role":"user","content":` ~ jsonQuote(task) ~ `}`);
        auto log_ = appender!string();
        string answer;
        size_t steps;
        // `diff` mode needs the previous frame to compute what changed.
        ubyte[] previousFrame;
        int previousWidth;
        ulong previousSignature;
        bool havePreviousFrame;
        bool previousRoundHadAction;
        bool previousStepOnlyInspected;
        // Latency accounting for the "how many seconds per reaction" goal.
        // Awareness = settle + capture + model round; response = running the
        // actions the model returned. Measured, never guessed.
        long captureTotalMs;
        long modelTotalMs;
        long actionTotalMs;
        long roundTotalMs;
        foreach (step; 0 .. maxSteps)
        {
            if (computerUseAbortActive())
            {
                log_.put("stopped by the kill switch\n");
                break;
            }
            if (MonoTime.currTime >= deadline)
            {
                log_.put("time budget reached\n");
                break;
            }
            const roundStarted = MonoTime.currTime;
            string screenPart;
            // Let the UI settle so this frame reflects the previous action
            // rather than the state before it.
            Thread.sleep(msecs(300));
            auto shot = captureScreen();
            captureTotalMs += (MonoTime.currTime - roundStarted).total!"msecs";
            // Did the previous round's action change anything? A game UI that
            // swallows a click leaves the frame byte-identical; tell the model,
            // which otherwise re-clicks the same dead spot forever.
            string correctionPart;
            if (shot.ok)
            {
                const currentSignature = frameSignature(shot.rgb);
                if (havePreviousFrame && previousWidth == shot.width &&
                    currentSignature == previousSignature && previousRoundHadAction)
                {
                    correctionPart = textPart("Note: the screen did NOT change " ~
                        "after your last action - it probably missed or the " ~
                        "target was elsewhere. Re-locate the control in THIS " ~
                        "frame and click a different point; do not repeat the " ~
                        "same click.");
                    log_.put("note: injected identical-frame correction\n");
                }
                previousSignature = currentSignature;
                havePreviousFrame = true;
            }
            // Break the "analysis paralysis" pattern: if the last step only
            // looked at the screen and issued no input action, push it to act.
            if (previousStepOnlyInspected)
            {
                correctionPart ~= textPart("Note: your previous step only " ~
                    "inspected the screen and changed nothing. Issue the next " ~
                    "input action now (click/drag/type/key) instead of reading " ~
                    "again.");
                log_.put("note: injected act-now nudge\n");
            }
            if (shot.ok)
            {
                if (frameScale == "diff")
                {
                    if (previousFrame.length != shot.rgb.length)
                        screenPart = imagePart("Full screen (first look; " ~
                            "coordinates are in this image's pixels):",
                            computerUseEncodePng(shot.width, shot.height,
                            shot.rgb));
                    else
                    {
                        enum int tileW = 240;
                        enum int tileH = 180;
                        enum size_t tileMinChanged = 400;
                        const cols = (shot.width + tileW - 1) / tileW;
                        const rows = (shot.height + tileH - 1) / tileH;
                        int[] tiles;
                        size_t[] counts;
                        foreach (ty; 0 .. rows)
                            foreach (tx; 0 .. cols)
                            {
                                const x = tx * tileW;
                                const y = ty * tileH;
                                const w = min(tileW, shot.width - x);
                                const h = min(tileH, shot.height - y);
                                tiles ~= cast(int) (ty * cols + tx);
                                counts ~= tileChangeCount(shot.width, x, y, w,
                                    h, shot.rgb, previousFrame);
                            }
                        string[] captions;
                        ubyte[][] pngs;
                        foreach (_; 0 .. 6)
                        {
                            int best = -1;
                            size_t bestCount;
                            foreach (slot, index; tiles)
                                if (counts[slot] >= tileMinChanged &&
                                    (best < 0 || counts[slot] > bestCount))
                                {
                                    best = cast(int) slot;
                                    bestCount = counts[slot];
                                }
                            if (best < 0) break;
                            counts[best] = 0;
                            const tx = tiles[best] % cols;
                            const ty = tiles[best] / cols;
                            const x = tx * tileW;
                            const y = ty * tileH;
                            const w = min(tileW, shot.width - x);
                            const h = min(tileH, shot.height - y);
                            captions ~= "Changed area: origin " ~ to!string(x) ~
                                "," ~ to!string(y) ~ ", size " ~ to!string(w) ~
                                "x" ~ to!string(h) ~ " (coordinates are in the " ~
                                "full 960x540 space):";
                            pngs ~= computerUseEncodePng(w, h,
                                cropRgb(shot.width, shot.rgb, x, y, w, h));
                        }
                        screenPart = pngs.length > 0
                            ? multiImagePart(captions, pngs)
                            : textPart("No significant screen change since the " ~
                              "last step. Continue if there is a next action.");
                    }
                }
                else
                {
                int frameWidth = shot.width;
                int frameHeight = shot.height;
                auto frame = shot.rgb;
                if (frameScale != "full")
                    frame = halfRgb(frameWidth, frameHeight, frame,
                        frameWidth, frameHeight);
                if (frameScale == "quarter")
                    frame = halfRgb(frameWidth, frameHeight, frame,
                        frameWidth, frameHeight);
                auto png = computerUseEncodePng(frameWidth, frameHeight, frame);
                const caption = frameScale == "full"
                    ? "Current screen (same pixel space as click coordinates):"
                    : "Current screen: this image is " ~
                      to!string(frameWidth) ~ "x" ~ to!string(frameHeight) ~
                      " pixels (a 1/" ~ to!string(frameFactor) ~ " downscale of " ~
                      "the 960x540 click space). Give click x,y in THIS image's " ~
                      "pixels; the tool multiplies them by " ~
                      to!string(frameFactor) ~ " for you:";
                screenPart = `,{"role":"user","content":[{"type":"text","text":` ~
                    jsonQuote(caption) ~
                    `},{"type":"image_url","image_url":{"url":` ~
                    jsonQuote("data:image/png;base64," ~
                    Base64.encode(png).idup) ~ `}}]}`;
                }
                previousFrame = shot.rgb;
                previousWidth = shot.width;
            }
            const body = `{"model":` ~ jsonQuote(loopModel) ~
                `,"messages":` ~ messages.data ~ correctionPart ~ screenPart ~
                `],"tools":[` ~
                toolJson ~ `],"tool_choice":"auto",` ~
                (reasoningArg == "none" ? `"reasoning_effort":"none",` : ``) ~
                `"stream":false}`;
            const modelStarted = MonoTime.currTime;
            string error;
            const response = httpPostJson(http, endpoint,
                computerUseProviderApiKey, body, error);
            if (error !is null)
                return failedResult("Error: subagent " ~ error);
            JSONValue parsed;
            try parsed = parseJSON(response);
            catch (Exception)
                return failedResult("Error: subagent got invalid JSON back: " ~
                    response[0 .. (response.length > 300 ? 300 :
                    response.length)]);
            if (parsed.type != JSONType.object)
                return failedResult("Error: subagent response was not an " ~
                    "object (len=" ~ to!string(response.length) ~ ", err=" ~
                    to!string(GetLastError()) ~ "): " ~
                    response[0 .. (response.length > 300 ? 300 :
                    response.length)]);
            auto choices = "choices" in parsed.object;
            if (choices is null || choices.type != JSONType.array ||
                choices.array.length == 0)
                return failedResult("Error: subagent response had no choices.");
            auto message = "message" in choices.array[0].object;
            if (message is null || message.type != JSONType.object)
                return failedResult("Error: subagent response had no message.");
            string content;
            if (auto c = "content" in message.object)
                if (c.type == JSONType.string) content = c.str;
            auto calls = "tool_calls" in message.object;
            const hasCalls = calls !is null && calls.type == JSONType.array &&
                calls.array.length > 0;
            ++steps;
            modelTotalMs += (MonoTime.currTime - modelStarted).total!"msecs";
            if (!hasCalls)
            {
                answer = content;
                roundTotalMs += (MonoTime.currTime - roundStarted).total!"msecs";
                break;
            }
            const actionStarted = MonoTime.currTime;
            bool roundHadAction;
            auto toolCallsJson = appender!string();
            auto toolResultsJson = appender!string();
            ChatImageAttachment[] resultShots;
            foreach (call; calls.array)
            {
                string id;
                if (auto idField = "id" in call.object)
                    if (idField.type == JSONType.string) id = idField.str;
                string name;
                string argsJson = "{}";
                if (auto fn = "function" in call.object)
                {
                    if (fn.type == JSONType.object)
                    {
                        if (auto nm = "name" in fn.object)
                            if (nm.type == JSONType.string) name = nm.str;
                        if (auto ar = "arguments" in fn.object)
                            if (ar.type == JSONType.string) argsJson = ar.str;
                    }
                }
                if (toolCallsJson.data.length > 0) toolCallsJson.put(",");
                toolCallsJson.put(`{"id":` ~ jsonQuote(id) ~
                    `,"type":"function","function":{"name":` ~
                    jsonQuote(name) ~ `,"arguments":` ~ jsonQuote(argsJson) ~
                    `}}`);
                ComputerUseResult result;
                if (name == "computer")
                {
                    // A `screen` call is redundant (a fresh frame is attached to
                    // every message) and its full-frame result would flood the
                    // request with a huge image on every step.
                    if (computerActionOf(argsJson) == "screen")
                    {
                        // A full-screen capture is redundant (a frame is attached
                        // to every message), but a `region` crop is the way to get
                        // native-resolution detail, so let those through.
                        if (computerArgsHaveRegion(argsJson))
                            result = experimentalComputerUseExecute(argsJson,
                                workspace);
                        else
                            result = succeededResult("Skipped: a current " ~
                                "screenshot is already attached to this " ~
                                "conversation - read positions from it. Use " ~
                                "`screen` with a small `region` if you need " ~
                                "native-resolution detail.");
                    }
                    else
                    {
                        // The frame the model just read is `frameFactor` times
                        // smaller than the click space. A coordinate outside that
                        // frame is a misread; executing it would be an off-screen
                        // click that silently does nothing (the observed drag to
                        // 1040,960 in a 480x270 frame). Reject and tell it.
                        const coordW = shot.ok ? shot.width / frameFactor : 0;
                        const coordH = shot.ok ? shot.height / frameFactor : 0;
                        if (!computerArgsWithinFrame(argsJson, coordW, coordH))
                        {
                            result = succeededResult("Rejected: this call's " ~
                                "coordinates fall outside the " ~
                                to!string(coordW) ~ "x" ~ to!string(coordH) ~
                                " frame you were shown. Re-read the attached " ~
                                "frame and give x in 0.." ~
                                to!string(coordW - 1) ~ " and y in 0.." ~
                                to!string(coordH - 1) ~ ".");
                            log_.put("note: rejected an out-of-frame call\n");
                        }
                        else
                        {
                            result = experimentalComputerUseExecute(
                                scaleComputerArgs(argsJson, frameFactor), workspace);
                            roundHadAction = true;
                        }
                    }
                }
                else
                    result = failedResult("Error: unknown tool '" ~ name ~
                        "'.");
                log_.put("step " ~ to!string(step + 1) ~ " " ~ name ~ ": " ~
                    result.output ~ " [round " ~
                    to!string((MonoTime.currTime - roundStarted).total!"msecs") ~
                    " ms]\n");
                foreach (image; result.images) resultShots ~= image;
                if (toolResultsJson.data.length > 0) toolResultsJson.put(",");
                toolResultsJson.put(`{"role":"tool","tool_call_id":` ~
                    jsonQuote(id) ~ `,"content":` ~ jsonQuote(result.output) ~
                    `}`);
            }
            messages.put(`,{"role":"assistant","content":null,"tool_calls":[` ~
                toolCallsJson.data ~ `]}`);
            messages.put(`,` ~ toolResultsJson.data);
            // Do NOT forward the screenshots nested calls return: every step
            // already carries a fresh frame, and forwarding these made full
            // frames accumulate in the history, slowing each later round.
            previousRoundHadAction = roundHadAction;
            previousStepOnlyInspected = !roundHadAction;
            actionTotalMs += (MonoTime.currTime - actionStarted).total!"msecs";
            roundTotalMs += (MonoTime.currTime - roundStarted).total!"msecs";
        }
        const rounds = steps > 0 ? cast(long) steps : 0;
        const avgCapture = rounds > 0 ? captureTotalMs / rounds : 0;
        const avgAwareness = rounds > 0 ?
            (captureTotalMs + modelTotalMs) / rounds : 0;
        const avgModel = rounds > 0 ? modelTotalMs / rounds : 0;
        const avgAction = rounds > 0 ? actionTotalMs / rounds : 0;
        const avgRound = rounds > 0 ? roundTotalMs / rounds : 0;
        ComputerUseResult out_;
        out_.output = "Subagent (" ~ to!string(steps) ~ " step(s), avg " ~
            to!string(avgRound) ~ " ms/round = awareness " ~
            to!string(avgAwareness) ~ " ms (capture " ~ to!string(avgCapture) ~
            " + model " ~ to!string(avgModel) ~ ") + response " ~
            to!string(avgAction) ~ " ms): " ~
            (answer.length ? answer : "(no final answer)") ~ "\n" ~ log_.data;
        return out_;
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
            if (computerUseAbortActive())
            {
                builder.put(label ~ ": stopped by the kill switch (" ~
                    computerUseKillSwitchChord ~ ").\n");
                failed = true;
                break;
            }
            auto one = runWindowsAction(step, false);
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
        if (screenshot && !computerUseAbortActive())
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
            if (computerUseAbortActive())
                return failedResult("Stopped by the kill switch (" ~
                    computerUseKillSwitchChord ~ ").");
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
