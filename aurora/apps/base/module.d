module base;

// Aurora Base: the live D module shape shared by the rest of the suite.
//
// One module owns the layout, palette, pages, hit testing, and session state.
// The host owns the window, the shared surface handshake, and the input ring.
// Everything visible is painted through aurora.Canvas and aurora.text.

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Key, KeyModifier;
import aurora.font : FontRole;
import aurora.surface : Surface;
import aurora.types : Point, Rect;
import core.stdc.string : memcpy;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.file : exists, readText, thisExePath, write;
import std.json : JSONValue, parseJSON, toJSON;
import std.mmfile : MmFile;
import std.path : buildPath, dirName;
import std.process : spawnProcess, wait;
import std.stdio : File, stderr, writeln;
import std.utf : toUTF32;

enum Revision = 1;
enum int Width = 1180;
enum int Height = 760;
enum int EventBytes = 24;
enum int EventCapacity = 64;
enum int HeaderBytes = 80;
enum int StatusH = 28;
enum int TopH = 56;
enum int TabH = 44;
enum int NavW = 248;
enum int NavCollapsedW = 76;
enum bool BlankMode = false;
enum int PageCount = BlankMode ? 1 : 3;

// ---------------------------------------------------------------------------
// Shared surface

struct LiveSurface
{
    MmFile map;
    ubyte[] data;
    int frameBytes;
    ulong sequence;

    this(string path)
    {
        frameBytes = Width * Height * 4;
        const size = HeaderBytes + EventCapacity * EventBytes +
            2 * frameBytes;
        auto stream = File(path, "wb");
        stream.rawWrite(new ubyte[size]);
        stream.close();
        map = new MmFile(path, MmFile.Mode.readWrite, cast(ulong) size, null);
        data = cast(ubyte[]) map[];

        char[8] magic = "AURSFACE";
        memcpy(data.ptr, magic.ptr, 8);
        put!uint(8, 2);
        put!uint(12, HeaderBytes);
        put!uint(16, Width);
        put!uint(20, Height);
        put!uint(24, 0);
        put!uint(28, EventCapacity);
        put!ulong(32, 0);
        put!ulong(40, 0);
        put!uint(48, 0);
        put!uint(52, 0);
        put!uint(56, EventBytes);
        put!uint(60, 2);
        put!uint(64, frameBytes);
    }

    private void put(T)(size_t offset, T value)
    {
        memcpy(data.ptr + offset, &value, T.sizeof);
    }

    private T get(T)(size_t offset)
    {
        T value;
        memcpy(&value, data.ptr + offset, T.sizeof);
        return value;
    }

    void publish(const(ubyte)[] pixels)
    {
        const active = get!uint(24);
        const target = 1 - active;
        const offset = HeaderBytes + EventCapacity * EventBytes +
            target * frameBytes;
        data[offset .. offset + frameBytes] = pixels[];
        put!uint(24, target);
        sequence++;
        put!ulong(32, sequence);
    }

    bool waitHost(ulong wanted, int timeoutMs = 120)
    {
        while (get!ulong(40) < wanted)
        {
            if (timeoutMs <= 0) return false;
            Thread.sleep(2.msecs);
            timeoutMs -= 2;
        }
        return true;
    }

    int readInputs(ref InputEvent[EventCapacity] events)
    {
        const head = get!uint(48);
        const tail = get!uint(52);
        const count = tail - head;
        int used;
        foreach (i; 0 .. count)
        {
            if (used >= EventCapacity) break;
            const offset = HeaderBytes +
                ((head + i) % EventCapacity) * EventBytes;
            events[used].kind = data[offset];
            events[used].button = data[offset + 1];
            ushort key;
            uint modifiers;
            memcpy(&key, data.ptr + offset + 2, ushort.sizeof);
            memcpy(&modifiers, data.ptr + offset + 4, uint.sizeof);
            events[used].key = key;
            events[used].modifiers = modifiers;
            int x;
            int y;
            memcpy(&x, data.ptr + offset + 8, int.sizeof);
            memcpy(&y, data.ptr + offset + 12, int.sizeof);
            events[used].x = x;
            events[used].y = y;
            used++;
        }
        put!uint(48, tail);
        return used;
    }

    void close()
    {
        map = null;
    }
}

struct InputEvent
{
    int kind;
    int button;
    int key;
    uint modifiers;
    int x;
    int y;
}

// ---------------------------------------------------------------------------
// Palette

private Color C(uint rgb, int alpha = 255)
{
    return Color.fromHex(rgb, cast(ubyte) alpha);
}

private Color bg() { return C(0x0b0f15); }
private Color panel() { return C(0x111722); }
private Color elevated() { return C(0x17202c); }
private Color ink() { return C(0xe7eef6); }
private Color muted() { return C(0x8c9caf); }
private Color dim() { return C(0x5f7186); }
private Color border() { return C(0x232d3a); }
private Color accent() { return C(0x38bdf8); }
private Color accentSoft() { return C(0x1b3346); }
private Color green() { return C(0x34d399); }

// ---------------------------------------------------------------------------
// Model

enum Page : int
{
    home,
    activity,
    guide,
}

enum Action
{
    none,
    page,
    toggleNav,
    card,
    clearLog,
    openActivity,
}

struct Hit
{
    Action action = Action.none;
    int data;
}

struct Box
{
    int x;
    int y;
    int w;
    int h;

    bool has(int px, int py) const
    {
        return px >= x && py >= y && px < x + w && py < y + h;
    }

    Rect asRect() const
    {
        return Rect(x, y, w, h);
    }
}

struct LogEntry
{
    string label;
    int frame;
}

private bool sameHit(Hit a, Hit b)
{
    return a.action == b.action && a.data == b.data;
}

private string pageName(Page page)
{
    switch (page)
    {
        case Page.home: return "Home";
        case Page.activity: return "Activity";
        case Page.guide: return "Guide";
        default: return "Home";
    }
}

private string pageUpper(Page page)
{
    switch (page)
    {
        case Page.home: return "HOME";
        case Page.activity: return "ACTIVITY";
        case Page.guide: return "GUIDE";
        default: return "HOME";
    }
}

private string shortName(int index)
{
    immutable string[3] names = ["H", "A", "G"];
    return names[index];
}

private string pad2(int value)
{
    return value < 10 ? "0" ~ to!string(value) : to!string(value);
}

struct Base
{
    Page page = Page.home;
    bool navCollapsed;
    int frame;
    int build = 1;
    string statePath;
    string message = "READY";
    int messageTicks;
    LogEntry[] log;
    int mouseX = -1;
    int mouseY = -1;
    bool mouseDown;
    Hit press;
    Hit hover;

    void init(string path, int buildId)
    {
        statePath = path;
        loadState();
        if (BlankMode) page = Page.home;
        build = buildId;
        hover = hitTest(mouseX, mouseY);
    }

    void loadState()
    {
        if (statePath.length == 0 || !exists(statePath)) return;
        try
        {
            auto value = parseJSON(readText(statePath));
            if (auto found = "page" in value.object)
            {
                const saved = (*found).get!int;
                if (saved >= 0 && saved < PageCount)
                    page = cast(Page) saved;
            }
            if (auto found = "navCollapsed" in value.object)
                navCollapsed = (*found).get!bool;
        }
        catch (Exception)
        {
            // A missing or half-written state file is not a startup failure.
        }
    }

    void saveState()
    {
        if (statePath.length == 0) return;
        auto state = JSONValue(string[string].init);
        state.object["generation"] = JSONValue(cast(int) Revision);
        state.object["build"] = JSONValue(build);
        state.object["page"] = JSONValue(cast(int) page);
        state.object["navCollapsed"] = JSONValue(navCollapsed);
        try
            write(statePath, state.toJSON());
        catch (Exception)
        {
            // The supervisor may be reading the file at this instant.
        }
    }

    void logAction(string label)
    {
        log ~= LogEntry(label, frame);
        if (log.length > 10) log = log[1 .. $];
    }

    void navigate(Page next)
    {
        if (BlankMode && next != Page.home) return;
        if (page == next)
        {
            message = pageUpper(next) ~ " ALREADY OPEN";
            messageTicks = 60;
            return;
        }
        page = next;
        message = "OPEN " ~ pageUpper(next);
        messageTicks = 90;
        logAction("OPEN " ~ pageUpper(next));
        hover = hitTest(mouseX, mouseY);
    }

    void toggleNav()
    {
        navCollapsed = !navCollapsed;
        message = navCollapsed ? "SIDEBAR COLLAPSED" : "SIDEBAR EXPANDED";
        messageTicks = 90;
        logAction(navCollapsed ? "COLLAPSE SIDEBAR" : "EXPAND SIDEBAR");
        hover = hitTest(mouseX, mouseY);
    }

    void clearLog()
    {
        log.length = 0;
        message = "LOG CLEARED";
        messageTicks = 90;
        hover = hitTest(mouseX, mouseY);
    }

    int navWidth() const
    {
        return navCollapsed ? NavCollapsedW : NavW;
    }

    int contentTop() const { return TopH + TabH; }
    int contentBottom() const { return Height - StatusH; }
    int pageLeft() const { return navWidth() + 40; }
    int pageWidth() const { return Width - navWidth() - 80; }

    Box tabBox(int index) const
    {
        immutable int[3] widths = [108, 126, 108];
        int x = 24;
        foreach (i; 0 .. index) x += widths[i] + 4;
        return Box(x, TopH + 5, widths[index], TabH - 10);
    }

    Box navItemBox(int index) const
    {
        const inset = navCollapsed ? 12 : 20;
        return Box(inset, contentTop() + 48 + index * 44,
            navWidth() - inset * 2, 36);
    }

    Box navToggleBox() const
    {
        const inset = navCollapsed ? 12 : 20;
        return Box(inset, contentTop() + 352, navWidth() - inset * 2, 36);
    }

    Box cardBox(int index) const
    {
        const width = pageWidth();
        const cols = width >= 840 ? 3 : width >= 560 ? 2 : 1;
        const gap = 16;
        const cardWidth = (width - gap * (cols - 1)) / cols;
        const cardHeight = 166;
        const top = contentTop() + 172;
        return Box(pageLeft() + (index % cols) * (cardWidth + gap),
            top + (index / cols) * (cardHeight + 14), cardWidth, cardHeight);
    }

    Box clearLogBox() const
    {
        return Box(pageLeft(), contentTop() + 158 + 300 + 18, 120, 36);
    }

    Box openActivityBox() const
    {
        return Box(pageLeft(), contentTop() + 158 + 300 + 18, 160, 38);
    }

    Hit hitTest(int x, int y) const
    {
        foreach (i; 0 .. PageCount)
            if (tabBox(i).has(x, y)) return Hit(Action.page, i);
        foreach (i; 0 .. PageCount)
            if (navItemBox(i).has(x, y)) return Hit(Action.page, i);
        if (navToggleBox().has(x, y)) return Hit(Action.toggleNav, 0);

        final switch (page)
        {
            case Page.home:
                if (!BlankMode)
                    foreach (i; 0 .. 3)
                        if (cardBox(i).has(x, y)) return Hit(Action.card, i);
                break;
            case Page.activity:
                if (clearLogBox().has(x, y)) return Hit(Action.clearLog, 0);
                break;
            case Page.guide:
                if (openActivityBox().has(x, y))
                    return Hit(Action.openActivity, 0);
                break;
        }
        return Hit(Action.none, 0);
    }

    bool hovered(Action action, int data = -1) const
    {
        return hover.action == action && (data < 0 || hover.data == data);
    }

    bool pressed(Action action, int data = -1) const
    {
        return mouseDown && press.action == action &&
            (data < 0 || press.data == data);
    }

    void activate(Hit hit)
    {
        final switch (hit.action)
        {
            case Action.none:
                break;
            case Action.page:
                navigate(cast(Page) hit.data);
                break;
            case Action.toggleNav:
                toggleNav();
                break;
            case Action.card:
                logAction("CARD " ~ pad2(hit.data + 1));
                if (hit.data == 1) navigate(Page.activity);
                else navigate(Page.guide);
                break;
            case Action.clearLog:
                clearLog();
                break;
            case Action.openActivity:
                navigate(Page.activity);
                break;
        }
    }

    void handleKey(InputEvent event)
    {
        const control = (event.modifiers & cast(uint) KeyModifier.control) != 0;
        if (!control) return;
        if (event.key == cast(int) Key.digit1) navigate(Page.home);
        else if (event.key == cast(int) Key.digit2) navigate(Page.activity);
        else if (event.key == cast(int) Key.digit3) navigate(Page.guide);
        else if (event.key == cast(int) Key.b) toggleNav();
    }

    void onInput(InputEvent event)
    {
        if (event.kind == 5)
        {
            handleKey(event);
            return;
        }
        if (event.kind == 6) return;
        mouseX = event.x;
        mouseY = event.y;
        if (event.kind == 1 && event.button == 1)
        {
            mouseDown = true;
            press = hitTest(event.x, event.y);
        }
        else if (event.kind == 3 && event.button == 1)
        {
            mouseDown = false;
            auto released = hitTest(event.x, event.y);
            if (sameHit(press, released)) activate(released);
            press = Hit();
        }
        hover = hitTest(mouseX, mouseY);
    }

    void update()
    {
        frame++;
        if (messageTicks > 0) messageTicks--;
    }

    ulong renderSignature() const
    {
        ulong hash = 1469598103934665603UL;
        void add(ulong value)
        {
            hash = (hash ^ value) * 1099511628211UL;
        }
        add(cast(ulong) page);
        add(navCollapsed ? 1 : 0);
        add(cast(ulong) build);
        add(cast(ulong) (frame / 30));
        add(cast(ulong) (mouseX + 1000));
        add(cast(ulong) (mouseY + 1000));
        add(mouseDown ? 1 : 0);
        add(cast(ulong) press.action);
        add(cast(ulong) press.data);
        add(cast(ulong) hover.action);
        add(cast(ulong) hover.data);
        add(messageTicks > 0 ? 1 : 0);
        foreach (ch; message) add(ch);
        foreach (i; 0 .. log.length)
        {
            foreach (ch; log[i].label) add(ch);
            add(cast(ulong) log[i].frame);
        }
        return hash;
    }
}

// ---------------------------------------------------------------------------
// Drawing helpers

private void text(ref Canvas canvas, int scale, string value, int x, int y,
    Color color)
{
    if (value.length == 0) return;
    auto layout = canvas.layoutText(toUTF32(value), scale, FontRole.ui);
    canvas.drawLayout(Point(x, y), layout, color);
}

private int measure(ref Canvas canvas, int scale, string value)
{
    if (value.length == 0) return 0;
    return canvas.measureText(toUTF32(value), scale, FontRole.ui).width;
}

private void textRight(ref Canvas canvas, int scale, string value, int right,
    int y, Color color)
{
    text(canvas, scale, value, right - measure(canvas, scale, value), y, color);
}

private void textCenter(ref Canvas canvas, int scale, string value,
    int centerX, int y, Color color)
{
    text(canvas, scale, value, centerX - measure(canvas, scale, value) / 2,
        y, color);
}

private void wrap(ref Canvas canvas, int scale, string value, int x, int y,
    int width, int height, Color color)
{
    if (value.length == 0 || width <= 0 || height <= 0) return;
    auto layout = canvas.layoutText(toUTF32(value), scale, FontRole.ui,
        null, width, true);
    auto child = canvas.clipped(Rect(x, y, width, height));
    child.drawLayout(Point(x, y), layout, color);
}

private void buttonBox(ref Canvas canvas, Box box, string label, bool hovered,
    bool pressed)
{
    const fill = pressed ? C(0x213044) :
        (hovered ? C(0x1b2a3a) : C(0x14202e));
    canvas.drawRoundedRect(box.asRect(), 8, fill,
        hovered ? C(0x35516a) : border(), 1);
    textCenter(canvas, 1, label, box.x + box.w / 2, box.y + 14, ink());
}

// ---------------------------------------------------------------------------
// Renderer

private void drawTopBar(ref Canvas canvas, ref Base app)
{
    canvas.fillRect(Rect(0, 0, Width, TopH), panel());
    canvas.drawLine(Point(0, TopH - 1), Point(Width, TopH - 1), border(), 1);

    canvas.fillRoundedRect(Rect(24, 19, 18, 18), 5, accent());
    canvas.drawLine(Point(28, 33), Point(33, 23), bg(), 2);
    canvas.drawLine(Point(33, 23), Point(38, 33), bg(), 2);
    canvas.drawLine(Point(30, 29), Point(36, 29), bg(), 2);

    text(canvas, 2, "AURORA", 52, 16, ink());
    text(canvas, 1, "BASE", 52 + measure(canvas, 2, "AURORA") + 8, 24,
        muted());

    const pulse = (app.frame / 30) % 2 == 0 ? 235 : 120;
    canvas.fillCircle(Point(Width - 172, 27), 4, C(0x34d399, pulse));
    textRight(canvas, 1, "LIVE  /  BUILD " ~ to!string(app.build),
        Width - 24, 19, muted());
    textRight(canvas, 1, "CTRL 1-3  /  CTRL B", Width - 24, 36, dim());
}

private void drawTabs(ref Canvas canvas, ref Base app)
{
    canvas.fillRect(Rect(0, TopH, Width, TabH), bg());
    canvas.drawLine(Point(0, TopH + TabH - 1),
        Point(Width, TopH + TabH - 1), border(), 1);

    foreach (i; 0 .. PageCount)
    {
        auto box = app.tabBox(i);
        const active = cast(int) app.page == i;
        if (active)
            canvas.fillRoundedRect(box.asRect(), 8, C(0x14202f));
        else if (app.hovered(Action.page, i))
            canvas.fillRoundedRect(box.asRect(), 8, C(0x101822));
        text(canvas, 2, pageName(cast(Page) i), box.x + 16, box.y + 8,
            active ? ink() : muted());
        if (active)
            canvas.fillRect(Rect(box.x + 16, box.y + box.h - 2,
                box.w - 32, 2), accent());
    }

    textRight(canvas, 1, "FIXED SURFACE  /  CANVAS + TEXT",
        Width - 24, TopH + 16, dim());
}

private void drawNav(ref Canvas canvas, ref Base app)
{
    const width = app.navWidth();
    const top = app.contentTop();
    const bottom = app.contentBottom();
    canvas.fillRect(Rect(0, top, width, bottom - top), panel());
    canvas.drawLine(Point(width - 1, top), Point(width - 1, bottom),
        border(), 1);

    if (!app.navCollapsed)
        text(canvas, 1, "WORKSPACE", 20, top + 22, dim());

    foreach (i; 0 .. PageCount)
    {
        auto box = app.navItemBox(i);
        const active = cast(int) app.page == i;
        if (active)
            canvas.fillRoundedRect(box.asRect(), 7, C(0x172433));
        else if (app.hovered(Action.page, i))
            canvas.fillRoundedRect(box.asRect(), 7, C(0x121b26));
        if (active)
            canvas.fillRect(Rect(box.x + 4, box.y + 8, 3, box.h - 16),
                accent());

        if (app.navCollapsed)
        {
            textCenter(canvas, 1, shortName(i), box.x + box.w / 2,
                box.y + 13, active ? ink() : muted());
        }
        else
        {
            canvas.fillCircle(Point(box.x + 20, box.y + box.h / 2), 3,
                active ? accent() : muted());
            text(canvas, 2, pageName(cast(Page) i), box.x + 34,
                box.y + 9, active ? ink() : muted());
        }
    }

    if (!app.navCollapsed)
    {
        canvas.drawLine(Point(20, top + 196), Point(width - 20, top + 196),
            border(), 1);
        text(canvas, 1, "SESSION", 20, top + 208, dim());
        text(canvas, 1, "PAGE", 20, top + 232, dim());
        text(canvas, 2, pageName(app.page), 76, top + 226, ink());
        text(canvas, 1, "BUILD", 20, top + 258, dim());
        text(canvas, 2, to!string(app.build), 76, top + 252, ink());
        text(canvas, 1, "INPUT", 20, top + 284, dim());
        text(canvas, 1, "pointer + key", 76, top + 286, muted());
        canvas.drawLine(Point(20, top + 310), Point(width - 20, top + 310),
            border(), 1);
        text(canvas, 1, "VIEW", 20, top + 322, dim());
    }

    auto toggle = app.navToggleBox();
    if (app.hovered(Action.toggleNav))
        canvas.fillRoundedRect(toggle.asRect(), 7, C(0x121b26));
    if (app.navCollapsed)
        textCenter(canvas, 2, ">>", toggle.x + toggle.w / 2,
            toggle.y + 7, ink());
    else
    {
        text(canvas, 2, "Collapse sidebar", toggle.x + 20, toggle.y + 9,
            ink());
        textRight(canvas, 1, "CTRL B", toggle.x + toggle.w, toggle.y + 14,
            dim());
    }

    if (!app.navCollapsed)
    {
        text(canvas, 1, "BASE / 0.1", 20, bottom - 46, dim());
        text(canvas, 1, "D + AURORA CANVAS", 20, bottom - 30, dim());
    }
    else
        textCenter(canvas, 1, "v0.1", width / 2, bottom - 34, dim());
}

private void drawHome(ref Canvas canvas, ref Base app)
{
    const left = app.pageLeft();
    const top = app.contentTop();
    const width = app.pageWidth();

    if (BlankMode)
    {
        text(canvas, 1, "AURORA BASE  /  BLANK WORKBENCH", left, top + 26,
            accent());
        text(canvas, 4, "Your app starts here.", left, top + 46, ink());
        wrap(canvas, 2,
            "Keep the window, surface handshake, input ring, and dark shell. " ~
            "Replace this canvas with your first real screen.", left,
            top + 100, width, 44, muted());

        const areaY = top + 158;
        const areaHeight = app.contentBottom() - areaY - 44;
        canvas.drawRoundedRect(Rect(left, areaY, width, areaHeight), 12,
            C(0x0f1824), border(), 1);
        textCenter(canvas, 2, "CONTENT AREA", left + width / 2,
            areaY + areaHeight / 2 - 8, dim());
        textCenter(canvas, 1,
            "Draw your first screen with Aurora Canvas and text.",
            left + width / 2, areaY + areaHeight / 2 + 12, muted());

        text(canvas, 1, "CTRL B TOGGLES THE SIDEBAR", left,
            app.contentBottom() - 26, dim());
        return;
    }

    text(canvas, 1, "AURORA BASE  /  REFERENCE SHELL", left, top + 26,
        accent());
    text(canvas, width >= 700 ? 5 : 4,
        "A small app that already behaves.", left, top + 46, ink());
    wrap(canvas, 2,
        "The window and input belong to the host. This module owns the " ~
        "layout, palette, state, and hit testing.", left, top + 108, width,
        44, muted());

    immutable string[3] titles = [
        "One module", "Host-owned window", "Canvas + text"
    ];
    immutable string[3] bodies = [
        "Layout, pages, hit testing, keyboard, and persistence live in " ~
        "this file.",
        "The host presents the surface and maps pointer and key events " ~
        "back into it.",
        "Every rectangle and line is Aurora Canvas; every glyph goes " ~
        "through the shared text engine.",
    ];
    immutable string[3] footers = [
        "READ THE GUIDE", "SEE THE EVENT LOG", "READ THE GUIDE"
    ];

    foreach (i; 0 .. 3)
    {
        auto box = app.cardBox(i);
        const hovered = app.hovered(Action.card, i);
        const pressed = app.pressed(Action.card, i);
        const fill = pressed ? C(0x1a2a3a) :
            (hovered ? C(0x142131) : C(0x111a26));
        canvas.drawRoundedRect(box.asRect(), 12, fill,
            hovered ? C(0x2d4358) : border(), 1);
        text(canvas, 1, "0" ~ to!string(i + 1), box.x + 18, box.y + 16,
            accent());
        text(canvas, 2, titles[i], box.x + 18, box.y + 34, ink());
        wrap(canvas, 1, bodies[i], box.x + 18, box.y + 64, box.w - 36,
            54, muted());
        text(canvas, 1, footers[i], box.x + 18, box.y + box.h - 24,
            hovered ? accent() : dim());
    }

    const stripY = top + 372;
    canvas.drawRoundedRect(Rect(left, stripY, width, 78), 10,
        C(0x0f1824), border(), 1);
    text(canvas, 1, "START HERE", left + 18, stripY + 16, accent());
    text(canvas, 2, "Copy module.d, keep the handshake, replace the pages.",
        left + 18, stripY + 34, ink());
    text(canvas, 1, "01 COPY   /   02 REPLACE   /   03 SHIP",
        left + 18, stripY + 58, dim());

    const metricsY = stripY + 98;
    canvas.drawRoundedRect(Rect(left, metricsY, width, 84), 10,
        C(0x0f1824), border(), 1);
    immutable string[3] values = ["1180 x 760", "24 BYTE", "2 FRAMES"];
    immutable string[3] labels = [
        "LOGICAL SURFACE", "INPUT EVENTS", "DOUBLE BUFFER"
    ];
    const columnWidth = width / 3;
    foreach (i; 0 .. 3)
    {
        const x = left + 20 + i * columnWidth;
        text(canvas, 3, values[i], x, metricsY + 18, ink());
        text(canvas, 1, labels[i], x, metricsY + 52, dim());
        if (i > 0)
            canvas.drawLine(Point(left + i * columnWidth, metricsY + 16),
                Point(left + i * columnWidth, metricsY + 68), border(), 1);
    }

    text(canvas, 1,
        "CLICK A TAB OR CARD  /  CTRL 1-3 SWITCHES PAGES",
        left, app.contentBottom() - 26, dim());
}

private void drawActivity(ref Canvas canvas, ref Base app)
{
    const left = app.pageLeft();
    const top = app.contentTop();
    const width = app.pageWidth();

    text(canvas, 1, "SESSION  /  EVENT LOG", left, top + 26, accent());
    text(canvas, 4, "Every action leaves a trace.", left, top + 46, ink());
    wrap(canvas, 2,
        "The log is ordinary module state. Nothing is sent to the host " ~
        "except the finished frame.", left, top + 100, width, 40, muted());

    auto panel = Rect(left, top + 150, width, 300);
    canvas.drawRoundedRect(panel, 10, C(0x0f1824), border(), 1);

    if (app.log.length == 0)
    {
        textCenter(canvas, 2,
            "No actions yet. Click a tab, card, or sidebar item.",
            left + width / 2, panel.y + 126, muted());
        textCenter(canvas, 1, "EVERY CLICK IS LOGGED WITH ITS FRAME",
            left + width / 2, panel.y + 158, dim());
    }
    else
    {
        foreach (i, entry; app.log)
        {
            const rowY = panel.y + 14 + cast(int) i * 28;
            text(canvas, 1, "#" ~ pad2(cast(int) i + 1), panel.x + 16,
                rowY, dim());
            text(canvas, 1, "FRAME " ~ to!string(entry.frame),
                panel.x + 64, rowY, dim());
            text(canvas, 2, entry.label, panel.x + 178, rowY - 2, ink());
            if (i + 1 < app.log.length)
                canvas.drawLine(Point(panel.x + 16, rowY + 24),
                    Point(panel.x + panel.width - 16, rowY + 24),
                    C(0x192331), 1);
        }
    }

    buttonBox(canvas, app.clearLogBox(), "CLEAR LOG",
        app.hovered(Action.clearLog), app.pressed(Action.clearLog));
}

private void drawGuideSection(ref Canvas canvas, string title, string[] items,
    int x, int y, int width, int height)
{
    canvas.drawRoundedRect(Rect(x, y, width, height), 10,
        C(0x0f1824), border(), 1);
    text(canvas, 1, title, x + 18, y + 16, accent());
    foreach (i, item; items)
    {
        const itemY = y + 48 + cast(int) i * 30;
        canvas.fillCircle(Point(x + 22, itemY + 5), 2, C(0x38bdf8, 150));
        text(canvas, 2, item, x + 34, itemY - 4, ink());
    }
}

private void drawGuide(ref Canvas canvas, ref Base app)
{
    const left = app.pageLeft();
    const top = app.contentTop();
    const width = app.pageWidth();

    text(canvas, 1, "GUIDE  /  FILES AND BOUNDARY", left, top + 26, accent());
    text(canvas, 4, "Copy the shape, replace the content.", left, top + 46,
        ink());
    wrap(canvas, 2,
        "Keep the surface handshake and the Canvas/text path. Swap the " ~
        "pages and the state for your product.", left, top + 100, width, 40,
        muted());

    immutable string[3] headings = ["HOST OWNS", "MODULE OWNS", "NEXT"];
    string[][] items = [
        [
            "Window and decoration",
            "Pointer and key input ring",
            "Surface handshake",
            "DPI and placement",
        ],
        [
            "Layout and palette",
            "Page content and copy",
            "Hit testing and state",
            "Persistence",
        ],
        [
            "Copy module.d",
            "Swap the three pages",
            "Add your own state",
            "Keep Canvas + text",
        ],
    ];

    const gap = 16;
    const cols = width >= 760 ? 3 : 1;
    const sectionWidth = (width - gap * (cols - 1)) / cols;
    const sectionHeight = 300;
    const sectionTop = top + 158;
    foreach (i; 0 .. 3)
    {
        const x = left + (i % cols) * (sectionWidth + gap);
        const y = sectionTop + (i / cols) * (sectionHeight + gap);
        drawGuideSection(canvas, headings[i], items[i], x, y, sectionWidth,
            sectionHeight);
    }

    buttonBox(canvas, app.openActivityBox(), "OPEN ACTIVITY",
        app.hovered(Action.openActivity), app.pressed(Action.openActivity));
}

private void drawStatus(ref Canvas canvas, ref Base app)
{
    const top = Height - StatusH;
    canvas.fillRect(Rect(0, top, Width, StatusH), panel());
    canvas.drawLine(Point(0, top), Point(Width, top), border(), 1);

    text(canvas, 1, app.message, 16, top + 9,
        app.messageTicks > 0 ? accent() : muted());
    textCenter(canvas, 1, pageName(app.page), Width / 2, top + 9, dim());
    textRight(canvas, 1,
        "BUILD " ~ to!string(app.build) ~ "  /  " ~ to!string(Width) ~
        " x " ~ to!string(Height) ~ "  /  DARK",
        Width - 16, top + 9, dim());
}

private void draw(ref Canvas canvas, ref Base app)
{
    canvas.clear(bg());
    drawTopBar(canvas, app);
    drawTabs(canvas, app);
    drawNav(canvas, app);

    final switch (app.page)
    {
        case Page.home:
            drawHome(canvas, app);
            break;
        case Page.activity:
            drawActivity(canvas, app);
            break;
        case Page.guide:
            drawGuide(canvas, app);
            break;
    }

    drawStatus(canvas, app);
}

// ---------------------------------------------------------------------------
// Frame conversion and entry point

private void publishArgb(const(uint)[] pixels, ubyte[] result)
{
    foreach (i; 0 .. Width * Height)
    {
        const offset = i * 4;
        const argb = pixels[i];
        result[offset] = cast(ubyte) ((argb >> 16) & 0xff);
        result[offset + 1] = cast(ubyte) ((argb >> 8) & 0xff);
        result[offset + 2] = cast(ubyte) (argb & 0xff);
        result[offset + 3] = cast(ubyte) ((argb >> 24) & 0xff);
    }
}

private bool launchProject()
{
    // The module is normally started by aurora-hotswap with --surface and
    // --state. When it is launched directly (Explorer double-click), hand off
    // to the project launcher instead of failing in the child process.
    const exeDir = dirName(thisExePath());
    immutable string[] candidates = [
        buildPath(exeDir, "run.py"),
        buildPath(exeDir, "..", "run.py"),
        buildPath(exeDir, "..", "..", "run.py"),
    ];
    foreach (candidate; candidates)
    {
        if (!exists(candidate)) continue;
        try
        {
            auto process = spawnProcess(["python", "-B", candidate]);
            return wait(process) == 0;
        }
        catch (Exception)
        {
            continue;
        }
    }
    return false;
}

int main(string[] args)
{
    string surfacePath;
    string statePath;
    int buildId = 1;
    int seconds = 900;
    for (size_t i = 1; i < args.length; ++i)
    {
        if (args[i] == "--surface" && i + 1 < args.length)
            surfacePath = args[++i];
        else if (args[i] == "--state" && i + 1 < args.length)
            statePath = args[++i];
        else if (args[i] == "--seconds" && i + 1 < args.length)
            seconds = to!int(args[++i]);
        else if (args[i] == "--build" && i + 1 < args.length)
            buildId = to!int(args[++i]);
    }
    if (surfacePath.length == 0 || statePath.length == 0)
    {
        if (launchProject()) return 0;
        stderr.writeln(
            "Aurora Base is a live child module; launch it with " ~
            "aurora/apps/base/run.py or aurora-hotswap. Direct launch " ~
            "requires --surface and --state.");
        return 2;
    }

    auto app = Base();
    app.init(statePath, buildId);
    app.saveState();

    auto surface = LiveSurface(surfacePath);
    scope (exit) surface.close();

    auto auroraSurface = new Surface(Width, Height);
    auto auroraCanvas = Canvas(auroraSurface);
    auto frameBytes = new ubyte[Width * Height * 4];

    InputEvent[EventCapacity] events;
    ulong lastSignature;
    bool painted;
    for (int tick = 0; tick < seconds * 60; ++tick)
    {
        const eventCount = surface.readInputs(events);
        foreach (i; 0 .. eventCount) app.onInput(events[i]);
        app.update();
        const signature = app.renderSignature();
        if (!painted || signature != lastSignature)
        {
            draw(auroraCanvas, app);
            publishArgb(auroraSurface.pixels(), frameBytes);
            lastSignature = signature;
            painted = true;
        }
        surface.publish(frameBytes);
        surface.waitHost(surface.sequence, 80);
        if (tick % 8 == 0) app.saveState();
        Thread.sleep(4.msecs);
    }
    app.saveState();
    return 0;
}
