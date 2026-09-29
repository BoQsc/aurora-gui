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

/// Tool definition to append to a toolset. Returns an empty array when the
/// experiment is disabled, so registration needs no conditional in the caller.
public OpenCodeToolDef[] experimentalComputerUseTools()
{
    if (!experimentalComputerUseEnabled()) return null;
    return [
        OpenCodeToolDef(
            "computer",
            "Drive the local desktop one action at a time, like a person at " ~
            "the keyboard: `screen` returns a screenshot, then `click`, " ~
            "`double_click`, `type`, `key`, `scroll`, and `wait_for_change` " ~
            "act on it. Meant for a tight see -> act -> see loop: take one " ~
            "action per call, look at the screenshot, and act again " ~
            "immediately. Keep reasoning minimal; only stop to plan when you " ~
            "are genuinely stuck (an unexpected dialog, a choice that needs " ~
            "judgement). Coordinates are screen pixels (x right, y down), " ~
            "matching the screenshot's own coordinate space. Windows only.",
            `{"type":"object","properties":{"action":{"type":"string","enum":["screen","click","double_click","type","key","scroll","wait_for_change"],"description":"Action to perform"},"x":{"type":"integer","description":"Screen x in pixels (click/double_click)"},"y":{"type":"integer","description":"Screen y in pixels (click/double_click)"},"text":{"type":"string","description":"Text to type (type)"},"name":{"type":"string","description":"Key for the key action, e.g. \"enter\", \"tab\", \"esc\", \"ctrl+s\", \"alt+f4\""},"amount":{"type":"integer","description":"Scroll wheel delta; negative scrolls down (default -120)"},"timeout_ms":{"type":"integer","description":"wait_for_change: how long to wait for the screen to change (default 5000)"},"interval_ms":{"type":"integer","description":"wait_for_change: how often to re-check, in ms (default 250)"}},"required":["action"]}`
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
    }
    action = strip(toLower(action));
    if (action.length == 0)
        return failedResult("Error: computer requires an `action` " ~
            "(screen, click, double_click, type, key, scroll, " ~
            "wait_for_change).");

    version (Windows)
        return runWindowsAction(action, cast(int) x, cast(int) y, text,
            keyName, cast(int) amount, timeoutMs, intervalMs);
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

// ---------------------------------------------------------------------------
// PNG encoding (truecolor, 8-bit) using zlib "stored" deflate blocks only.
//
// A screenshot must reach the model as PNG/JPEG/WebP/GIF (see the attachment
// magic-byte sniffing), and Aurora has no image encoder, so this module carries
// a small, dependency-free writer. Stored blocks keep it trivial and correct:
// the image is downscaled first, so the uncompressed size stays well under the
// attachment cap.
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

    const stride = cast(size_t) w * 3;
    auto raw = new ubyte[](cast(size_t) h * (stride + 1));
    size_t cursor;
    foreach (row; 0 .. cast(size_t) h)
    {
        raw[cursor++] = 0; // filter type 0 (None)
        raw[cursor .. cursor + stride] = rgb[row * stride .. row * stride + stride];
        cursor += stride;
    }

    ubyte[] z;
    z ~= [0x78, 0x01]; // zlib header: deflate, default window
    size_t pos;
    while (pos < raw.length)
    {
        const chunk = min(raw.length - pos, cast(size_t) 65535);
        const last = (pos + chunk >= raw.length) ? 1 : 0;
        z ~= cast(ubyte) last;
        z ~= cast(ubyte) (chunk & 0xFF);
        z ~= cast(ubyte) ((chunk >> 8) & 0xFF);
        z ~= cast(ubyte) (~chunk & 0xFF);
        z ~= cast(ubyte) ((~chunk >> 8) & 0xFF);
        z ~= raw[pos .. pos + chunk];
        pos += chunk;
    }
    putBigEndian(z, adler32(raw));
    appendChunk(out_, "IDAT", z);
    appendChunk(out_, "IEND", null);
    return out_;
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

        const maxEdge = width > height ? width : height;
        int step = 1;
        if (maxEdge > captureMaxEdge)
            step = (maxEdge + captureMaxEdge - 1) / captureMaxEdge;
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
        result.output = prefix ~ " (" ~ to!string(capture.width) ~ "x" ~
            to!string(capture.height) ~ ", " ~ to!string(png.length) ~
            " bytes).";
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

    private void clickAt(int x, int y, int count)
    {
        SetCursorPos(x, y);
        Thread.sleep(msecs(30)); // let the pointer settle before the press
        foreach (i; 0 .. count)
        {
            sendMouse(MOUSEEVENTF_LEFTDOWN);
            sendMouse(MOUSEEVENTF_LEFTUP);
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
        long intervalMs)
    {
        switch (action)
        {
            case "screen":
                return screenshotResult("Captured the screen");
            case "click":
                clickAt(x, y, 1);
                return succeededResult("Clicked at " ~ to!string(x) ~ "," ~
                    to!string(y) ~ ".");
            case "double_click":
                clickAt(x, y, 2);
                return succeededResult("Double-clicked at " ~ to!string(x) ~
                    "," ~ to!string(y) ~ ".");
            case "type":
                if (text.length == 0)
                    return failedResult("Error: type requires `text`.");
                typeText(text);
                return succeededResult("Typed " ~ to!string(text.length) ~
                    " characters.");
            case "key":
                return runKey(keyName);
            case "scroll":
                sendMouse(MOUSEEVENTF_WHEEL, amount);
                return succeededResult("Scrolled by " ~ to!string(amount) ~
                    ".");
            case "wait_for_change":
                return waitForChange(timeoutMs, intervalMs);
            default:
                return failedResult("Error: unknown computer action '" ~
                    action ~ "'.");
        }
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
