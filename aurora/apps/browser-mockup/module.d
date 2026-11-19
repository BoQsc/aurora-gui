module browsermockup;

// A self-contained interactive browser mockup for Aurora Host v2.
//
// Everything is drawn into one AURSFACE. The app owns the shell chrome, the
// four sample pages, and all navigation state. Pointer events arrive through
// the standard shared-surface input ring.

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.font : FontRole;
import aurora.surface : Surface;
import aurora.types;
import aurora.types : Point;
import core.stdc.string : memcpy;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm : max;
import std.conv : to;
import std.file : exists, readText, write;
import std.json : JSONValue, parseJSON, toJSON;
import std.mmfile : MmFile;
import std.stdio : File;
import std.utf : toUTF32;

enum Revision = 1;
enum int Width = 960;
enum int Height = 640;
enum int EventBytes = 24;
enum int EventCapacity = 64;
enum int HeaderBytes = 80;
enum int StatusH = 24;
enum int MaxTabs = 4;
enum int HistorySlots = 12;
enum int LoadingFrames = 20;
enum int PageCount = 4;

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
    int x;
    int y;
}

// ---------------------------------------------------------------------------
// Aurora Canvas adapter

private Color C(uint rgb, int alpha = 255)
{
    return Color.fromHex(rgb, cast(ubyte) alpha);
}

private dstring dtext(string value)
{
    return toUTF32(value);
}

private aurora.types.Rect ar(int x, int y, int w, int h)
{
    return aurora.types.Rect(x, y, w, h);
}

private void arcPoints(Canvas canvas, int centerX, int centerY, int radius,
    double start, double end, int thickness, Color color)
{
    import std.math : cos, sin;
    enum int Segments = 6;
    int previousX;
    int previousY;
    foreach (i; 0 .. Segments + 1)
    {
        const t = cast(double) i / Segments;
        const angle = start + (end - start) * t;
        const x = centerX + cast(int) (cos(angle) * radius + 0.5);
        const y = centerY + cast(int) (sin(angle) * radius + 0.5);
        if (i > 0)
            canvas.drawLine(Point(previousX, previousY), Point(x, y),
                color, thickness);
        previousX = x;
        previousY = y;
    }
}

/**
 * Thin compatibility shell over Aurora's portable Canvas. The browser layout
 * below uses ordinary rectangles and Aurora primitives; no GDI, private glyph
 * cache, or private text rasterizer is involved.
 */
struct AuroraCanvas
{
    Canvas inner;

    this(Canvas canvas)
    {
        inner = canvas;
    }

    void clear(Color color)
    {
        inner.clear(color);
    }

    void fill(int x, int y, int w, int h, Color color)
    {
        inner.fillRect(ar(x, y, w, h), color);
    }

    void gradient(int x, int y, int w, int h, Color top, Color bottom)
    {
        inner.fillVerticalGradient(ar(x, y, w, h), top, bottom);
    }

    void roundRect(int x, int y, int w, int h, int radius, Color color)
    {
        inner.fillRoundedRect(ar(x, y, w, h), radius, color);
    }

    void roundOutline(int x, int y, int w, int h, int radius,
        float thickness, Color color)
    {
        if (w <= 0 || h <= 0) return;
        if (radius > w / 2) radius = w / 2;
        if (radius > h / 2) radius = h / 2;
        const t = max(1, cast(int) (thickness + 0.5f));
        import std.math : PI;
        inner.drawLine(Point(x + radius, y), Point(x + w - radius, y),
            color, t);
        inner.drawLine(Point(x + radius, y + h - 1),
            Point(x + w - radius, y + h - 1), color, t);
        inner.drawLine(Point(x, y + radius), Point(x, y + h - radius),
            color, t);
        inner.drawLine(Point(x + w - 1, y + radius),
            Point(x + w - 1, y + h - radius), color, t);
        arcPoints(inner, x + radius, y + radius, radius, PI, PI * 1.5,
            t, color);
        arcPoints(inner, x + w - radius - 1, y + radius, radius,
            PI * 1.5, PI * 2.0, t, color);
        arcPoints(inner, x + w - radius - 1, y + h - radius - 1, radius,
            0.0, PI * 0.5, t, color);
        arcPoints(inner, x + radius, y + h - radius - 1, radius,
            PI * 0.5, PI, t, color);
    }

    void circle(float centerX, float centerY, float radius, Color color)
    {
        inner.fillCircle(Point(cast(int) (centerX + 0.5f),
            cast(int) (centerY + 0.5f)), cast(int) (radius + 0.5f), color);
    }

    void ring(float centerX, float centerY, float radius, float thickness,
        Color color)
    {
        inner.strokeCircle(Point(cast(int) (centerX + 0.5f),
            cast(int) (centerY + 0.5f)), cast(int) (radius + 0.5f),
            color, max(1, cast(int) (thickness + 0.5f)));
    }

    void line(float x1, float y1, float x2, float y2, float thickness,
        Color color)
    {
        inner.drawLine(Point(cast(int) (x1 + 0.5f),
            cast(int) (y1 + 0.5f)), Point(cast(int) (x2 + 0.5f),
            cast(int) (y2 + 0.5f)), color,
            max(1, cast(int) (thickness + 0.5f)));
    }

    void star(float centerX, float centerY, float outer, float innerRadius,
        Color color)
    {
        import std.math : PI, cos, sin;
        Point[10] points;
        foreach (i; 0 .. 10)
        {
            const angle = -PI / 2 + i * PI / 5;
            const radius = (i & 1) == 0 ? outer : innerRadius;
            points[i] = Point(cast(int) (centerX + cos(angle) * radius + 0.5),
                cast(int) (centerY + sin(angle) * radius + 0.5));
        }
        const center = Point(cast(int) (centerX + 0.5f),
            cast(int) (centerY + 0.5f));
        foreach (i; 0 .. 10)
            inner.fillTriangle(center, points[i], points[(i + 1) % 10],
                color);
    }
}

/**
 * Aurora's standard text scale names mapped to the integer scale tiers used
 * by Canvas. Negative values select the monospace role. There is no private
 * font face, size table, weight override, or system renderer here.
 */
struct Fonts
{
    int tiny = 1;
    int small = 1;
    int body = 2;
    int label = 1;
    int title = 3;
    int large = 4;
    int display = 6;
    int boldSmall = 1;
    int boldBody = 2;
    int boldLabel = 1;
    int boldTitle = 3;
    int boldLarge = 4;
    int boldDisplay = 6;
    int serifBody = 2;
    int serifItalic = 2;
    int serifTitle = 6;
    int journal = 3;
    int mono = -1;
    int monoSmall = -1;
}

private float cosf(float x)
{
    import std.math : cos;
    return cast(float) cos(cast(double) x);
}

private float sinf(float x)
{
    import std.math : sin;
    return cast(float) sin(cast(double) x);
}

// ---------------------------------------------------------------------------
// Browser model

enum Page : int
{
    start,
    design,
    docs,
    gallery,
}

enum Action
{
    none,
    tab,
    tabClose,
    newTab,
    back,
    forward,
    reload,
    home,
    address,
    star,
    menu,
    bookmark,
    startCard,
    docNav,
    copyCode,
    articleNext,
    gallerySwatch,
    copyHex,
    menuItem,
    suggestion,
    aboutClose,
}

struct Hit
{
    Action action;
    int data;
}

struct Rect
{
    int x;
    int y;
    int w;
    int h;

    bool has(int px, int py) const
    {
        return px >= x && py >= y && px < x + w && py < y + h;
    }
}

private bool sameHit(Hit a, Hit b)
{
    return a.action == b.action && a.data == b.data;
}

struct TabState
{
    Page[HistorySlots] history;
    int historyLength;
    int historyIndex;
    bool starred;
    int docSection;
    int galleryIndex;

    void reset()
    {
        history[0] = Page.start;
        historyLength = 1;
        historyIndex = 0;
        starred = false;
        docSection = 0;
        galleryIndex = 0;
    }

    Page page() const
    {
        if (historyLength <= 0) return Page.start;
        const index = historyIndex < 0 ? 0 :
            (historyIndex >= historyLength ? historyLength - 1 : historyIndex);
        return history[index];
    }
}

struct Browser
{
    TabState[MaxTabs] tabs;
    int tabCount;
    int activeTab;
    bool bookmarksVisible;
    bool menuOpen;
    bool suggestOpen;
    bool aboutOpen;
    bool mouseDown;
    int mouseX;
    int mouseY;
    int frame;
    int build;
    int loadingTicks;
    int toastTicks;
    int copiedTicks;
    int toastSerial;
    string toast;
    string statePath;
    Hit pressHit;
    Hit hover;

    void init(string path, int buildId)
    {
        statePath = path;
        build = buildId;
        tabCount = 1;
        activeTab = 0;
        bookmarksVisible = true;
        menuOpen = false;
        suggestOpen = false;
        aboutOpen = false;
        mouseX = -100;
        mouseY = -100;
        loadingTicks = 0;
        toastTicks = 0;
        copiedTicks = 0;
        toast = "";
        foreach (i; 0 .. MaxTabs) tabs[i].reset();
        loadState();
        hover = hitTest(mouseX, mouseY);
    }

    TabState* tab()
    {
        return &tabs[activeTab];
    }

    const(TabState)* tab() const
    {
        return &tabs[activeTab];
    }

    int pageTop() const
    {
        return bookmarksVisible ? 138 : 100;
    }

    int contentBottom() const
    {
        return Height - StatusH;
    }

    // ----- persistence -----------------------------------------------------

    void loadState()
    {
        if (!exists(statePath)) return;
        try
        {
            auto value = parseJSON(readText(statePath));
            const count = value.object["tabCount"].get!int;
            if (count >= 1 && count <= MaxTabs) tabCount = count;
            const active = value.object["activeTab"].get!int;
            if (active >= 0 && active < tabCount) activeTab = active;
            bookmarksVisible = value.object["bookmarksVisible"].get!bool;
            auto savedTabs = value.object["tabs"].array;
            foreach (i; 0 .. tabCount)
            {
                if (i >= savedTabs.length) break;
                auto saved = savedTabs[i].object;
                const page = saved["page"].get!int;
                if (page >= 0 && page < PageCount) tabs[i].history[0] = cast(Page) page;
                tabs[i].historyLength = 1;
                tabs[i].historyIndex = 0;
                const section = saved["docSection"].get!int;
                if (section >= 0 && section < 4) tabs[i].docSection = section;
                const gallery = saved["galleryIndex"].get!int;
                if (gallery >= 0 && gallery < 6) tabs[i].galleryIndex = gallery;
                tabs[i].starred = saved["starred"].get!bool;
            }
            if (tabCount < 1) tabCount = 1;
            if (activeTab >= tabCount) activeTab = tabCount - 1;
        }
        catch (Exception)
        {
            foreach (i; 0 .. MaxTabs) tabs[i].reset();
            tabCount = 1;
            activeTab = 0;
            bookmarksVisible = true;
        }
    }

    void saveState()
    {
        auto state = JSONValue(string[string].init);
        state.object["build"] = JSONValue(build);
        state.object["generation"] = JSONValue(cast(int) Revision);
        state.object["tabCount"] = JSONValue(tabCount);
        state.object["activeTab"] = JSONValue(activeTab);
        state.object["bookmarksVisible"] = JSONValue(bookmarksVisible);
        state.object["galleryIndex"] = JSONValue(tabs[activeTab].galleryIndex);
        JSONValue[] savedTabs;
        foreach (i; 0 .. tabCount)
        {
            auto saved = JSONValue(string[string].init);
            saved.object["page"] = JSONValue(cast(int) tabs[i].page());
            saved.object["docSection"] = JSONValue(tabs[i].docSection);
            saved.object["galleryIndex"] = JSONValue(tabs[i].galleryIndex);
            saved.object["starred"] = JSONValue(tabs[i].starred);
            savedTabs ~= saved;
        }
        state.object["tabs"] = JSONValue(savedTabs);
        try
        {
            write(statePath, state.toJSON());
        }
        catch (Exception)
        {
            // The supervisor may be reading the file at this instant.
        }
    }

    // ----- navigation ------------------------------------------------------

    void navigate(Page page)
    {
        auto currentTab = tab();
        if (currentTab.historyLength > 0 && currentTab.page() == page)
        {
            currentTab.starred = false;
            suggestOpen = false;
            menuOpen = false;
            loadingTicks = LoadingFrames / 2;
            return;
        }
        if (currentTab.historyIndex + 1 < currentTab.historyLength)
            currentTab.historyLength = currentTab.historyIndex + 1;
        if (currentTab.historyLength >= HistorySlots)
        {
            foreach (i; 1 .. HistorySlots)
                currentTab.history[i - 1] = currentTab.history[i];
            currentTab.historyLength--;
            if (currentTab.historyIndex > 0) currentTab.historyIndex--;
        }
        currentTab.history[currentTab.historyLength] = page;
        currentTab.historyLength++;
        currentTab.historyIndex = currentTab.historyLength - 1;
        currentTab.starred = false;
        suggestOpen = false;
        menuOpen = false;
        loadingTicks = LoadingFrames;
    }

    void goBack()
    {
        auto currentTab = tab();
        if (currentTab.historyIndex > 0)
        {
            currentTab.historyIndex--;
            currentTab.starred = false;
            suggestOpen = false;
            menuOpen = false;
            loadingTicks = LoadingFrames / 2;
        }
    }

    void goForward()
    {
        auto currentTab = tab();
        if (currentTab.historyIndex + 1 < currentTab.historyLength)
        {
            currentTab.historyIndex++;
            currentTab.starred = false;
            suggestOpen = false;
            menuOpen = false;
            loadingTicks = LoadingFrames / 2;
        }
    }

    void reload()
    {
        loadingTicks = LoadingFrames;
        suggestOpen = false;
        menuOpen = false;
        notify("Refreshing the mockup");
    }

    void home()
    {
        navigate(Page.start);
    }

    void openNewTab()
    {
        if (tabCount >= MaxTabs)
        {
            notify("Four tabs is the demo limit");
            menuOpen = false;
            return;
        }
        tabs[tabCount].reset();
        activeTab = tabCount;
        tabCount++;
        menuOpen = false;
        suggestOpen = false;
        loadingTicks = LoadingFrames;
        notify("New tab opened");
    }

    void closeTab(int index)
    {
        if (index < 0 || index >= tabCount) return;
        if (tabCount == 1)
        {
            tabs[0].reset();
            activeTab = 0;
            loadingTicks = 0;
            suggestOpen = false;
            menuOpen = false;
            return;
        }
        foreach (i; index .. tabCount - 1)
            tabs[i] = tabs[i + 1];
        tabCount--;
        if (activeTab > index) activeTab--;
        if (activeTab >= tabCount) activeTab = tabCount - 1;
        if (activeTab < 0) activeTab = 0;
        loadingTicks = 0;
        suggestOpen = false;
        menuOpen = false;
        notify("Tab closed");
    }

    void toggleStar()
    {
        auto currentTab = tab();
        currentTab.starred = !currentTab.starred;
        suggestOpen = false;
        menuOpen = false;
        notify(currentTab.starred ? "Bookmark saved" : "Bookmark removed");
    }

    void notify(string message)
    {
        toast = message;
        toastTicks = 90;
        toastSerial++;
    }

    Page bookmarkPage(int index) const
    {
        switch (index)
        {
            case 0: return Page.start;
            case 1: return Page.design;
            case 2: return Page.docs;
            case 3: return Page.gallery;
            default: return Page.start;
        }
    }

    string pageTitle(Page page) const
    {
        final switch (page)
        {
            case Page.start: return "Aurora Start";
            case Page.design: return "Designing for focus";
            case Page.docs: return "Docs & guides";
            case Page.gallery: return "Color studies";
        }
    }

    string pageURL(Page page, int section) const
    {
        final switch (page)
        {
            case Page.start: return "aurora://start";
            case Page.design: return "aurora://journal/focus";
            case Page.docs:
                switch (section)
                {
                    case 0: return "aurora://docs/overview";
                    case 1: return "aurora://docs/input";
                    case 2: return "aurora://docs/frames";
                    case 3: return "aurora://docs/lifecycle";
                    default: return "aurora://docs/overview";
                }
            case Page.gallery: return "aurora://gallery";
        }
    }

    // ----- input -----------------------------------------------------------

    void onInput(InputEvent event)
    {
        mouseX = event.x;
        mouseY = event.y;
        if (event.kind == 1 && event.button == 1)
        {
            mouseDown = true;
            pressHit = hitTest(event.x, event.y);
        }
        else if (event.kind == 3 && event.button == 1)
        {
            mouseDown = false;
            auto released = hitTest(event.x, event.y);
            if (sameHit(pressHit, released)) activate(released);
        }
    }

    void update()
    {
        frame++;
        if (loadingTicks > 0) loadingTicks--;
        if (toastTicks > 0) toastTicks--;
        if (copiedTicks > 0) copiedTicks--;
        hover = hitTest(mouseX, mouseY);
    }

    void activate(Hit hit)
    {
        final switch (hit.action)
        {
            case Action.none:
                if (aboutOpen) aboutOpen = false;
                else
                {
                    if (menuOpen) menuOpen = false;
                    if (suggestOpen) suggestOpen = false;
                }
                break;
            case Action.tab:
                if (hit.data >= 0 && hit.data < tabCount)
                {
                    activeTab = hit.data;
                    menuOpen = false;
                    suggestOpen = false;
                }
                break;
            case Action.tabClose:
                closeTab(hit.data);
                break;
            case Action.newTab:
                openNewTab();
                break;
            case Action.back:
                goBack();
                break;
            case Action.forward:
                goForward();
                break;
            case Action.reload:
                reload();
                break;
            case Action.home:
                home();
                break;
            case Action.address:
                menuOpen = false;
                suggestOpen = true;
                break;
            case Action.star:
                toggleStar();
                break;
            case Action.menu:
                suggestOpen = false;
                menuOpen = !menuOpen;
                break;
            case Action.bookmark:
                if (hit.data >= 0 && hit.data < 4)
                    navigate(bookmarkPage(hit.data));
                break;
            case Action.startCard:
                if (hit.data == 0) navigate(Page.design);
                else if (hit.data == 1) navigate(Page.docs);
                else if (hit.data == 2) navigate(Page.gallery);
                break;
            case Action.docNav:
                if (hit.data >= 0 && hit.data < 4)
                {
                    tab().docSection = hit.data;
                    loadingTicks = LoadingFrames / 2;
                    copiedTicks = 0;
                }
                break;
            case Action.copyCode:
                copiedTicks = 90;
                notify("Snippet copied");
                break;
            case Action.articleNext:
                navigate(Page.gallery);
                break;
            case Action.gallerySwatch:
                if (hit.data >= 0 && hit.data < 6)
                    tab().galleryIndex = hit.data;
                break;
            case Action.copyHex:
                copiedTicks = 90;
                notify("Hex value copied");
                break;
            case Action.menuItem:
                activateMenuItem(hit.data);
                break;
            case Action.suggestion:
                if (hit.data >= 0 && hit.data < 4)
                {
                    navigate(cast(Page) hit.data);
                    suggestOpen = false;
                }
                break;
            case Action.aboutClose:
                aboutOpen = false;
                break;
        }
    }

    void activateMenuItem(int index)
    {
        menuOpen = false;
        switch (index)
        {
            case 0: openNewTab(); break;
            case 1: home(); break;
            case 2: toggleStar(); break;
            case 3:
                bookmarksVisible = !bookmarksVisible;
                notify(bookmarksVisible ? "Bookmarks bar shown" :
                    "Bookmarks bar hidden");
                break;
            case 4: aboutOpen = true; break;
            default: break;
        }
    }

    // ----- geometry --------------------------------------------------------

    int tabWidth() const
    {
        int available = Width - 52 - 120;
        int width = 208;
        if (tabCount > 1)
        {
            width = (available - (tabCount - 1) * 4) / tabCount;
            if (width > 208) width = 208;
        }
        return width;
    }

    Rect tabRect(int index) const
    {
        return Rect(52 + index * (tabWidth() + 4), 7, tabWidth(), 34);
    }

    Rect tabCloseRect(int index) const
    {
        auto area = tabRect(index);
        return Rect(area.x + area.w - 28, area.y + 9, 20, 20);
    }

    Rect newTabRect() const
    {
        return Rect(52 + tabCount * (tabWidth() + 4) + 4, 12, 24, 24);
    }

    Rect navButtonRect(int index) const
    {
        return Rect(20 + index * 40, 57, 34, 34);
    }

    Rect addressRect() const
    {
        return Rect(184, 56, Width - 184 - 124, 38);
    }

    Rect starRect() const
    {
        return Rect(Width - 136, 57, 34, 34);
    }

    Rect menuButtonRect() const
    {
        return Rect(Width - 94, 57, 34, 34);
    }

    Rect bookmarkChipRect(int index) const
    {
        immutable int[4] widths = [112, 126, 88, 98];
        int x = 20;
        foreach (i; 0 .. index) x += widths[i] + 8;
        return Rect(x, 107, widths[index], 24);
    }

    Rect searchRect() const
    {
        return Rect(230, pageTop() + 200, 500, 52);
    }

    Rect startCardRect(int index) const
    {
        return Rect(72 + index * 280, pageTop() + 300, 256, 124);
    }

    Rect articleNextRect() const
    {
        return Rect(64, pageTop() + 388, 250, 28);
    }

    Rect docNavRect(int index) const
    {
        return Rect(22, pageTop() + 100 + index * 38, 212, 34);
    }

    Rect copyCodeRect() const
    {
        return Rect(Width - 108, pageTop() + 160, 72, 28);
    }

    Rect galleryCardRect(int index) const
    {
        const col = index % 3;
        const row = index / 3;
        return Rect(64 + col * 186, pageTop() + 156 + row * 154, 168, 136);
    }

    Rect copyHexRect() const
    {
        return Rect(648, pageTop() + 414, 228, 30);
    }

    Rect menuRect() const
    {
        return Rect(Width - 260, 100, 236, 206);
    }

    Rect menuItemRect(int index) const
    {
        auto area = menuRect();
        return Rect(area.x + 8, area.y + 8 + index * 38, area.w - 16, 34);
    }

    Rect suggestRect() const
    {
        return Rect(184, 100, Width - 184 - 124, 224);
    }

    Rect suggestRowRect(int index) const
    {
        auto area = suggestRect();
        return Rect(area.x + 8, area.y + 34 + index * 46, area.w - 16, 44);
    }

    Rect aboutCloseRect() const
    {
        return Rect(Width / 2 + 110, 398, 92, 34);
    }

    // ----- hit testing -----------------------------------------------------

    Hit hitTest(int x, int y) const
    {
        if (aboutOpen)
        {
            if (aboutCloseRect().has(x, y)) return Hit(Action.aboutClose, 0);
            return Hit(Action.none, 0);
        }
        if (menuOpen)
        {
            foreach (i; 0 .. 5)
                if (menuItemRect(i).has(x, y)) return Hit(Action.menuItem, i);
            return Hit(Action.none, 0);
        }
        if (suggestOpen)
        {
            foreach (i; 0 .. 4)
                if (suggestRowRect(i).has(x, y))
                    return Hit(Action.suggestion, i);
            return Hit(Action.none, 0);
        }

        foreach (i; 0 .. tabCount)
        {
            if (tabCloseRect(i).has(x, y)) return Hit(Action.tabClose, i);
            if (tabRect(i).has(x, y)) return Hit(Action.tab, i);
        }
        if (newTabRect().has(x, y)) return Hit(Action.newTab, 0);
        foreach (i; 0 .. 4)
            if (navButtonRect(i).has(x, y))
                return Hit(cast(Action) (cast(int) Action.back + i), 0);
        if (addressRect().has(x, y)) return Hit(Action.address, 0);
        if (starRect().has(x, y)) return Hit(Action.star, 0);
        if (menuButtonRect().has(x, y)) return Hit(Action.menu, 0);

        if (bookmarksVisible)
            foreach (i; 0 .. 4)
                if (bookmarkChipRect(i).has(x, y))
                    return Hit(Action.bookmark, i);

        if (y < pageTop() || y >= contentBottom()) return Hit(Action.none, 0);
        switch (tab().page())
        {
            case Page.start:
                if (searchRect().has(x, y)) return Hit(Action.address, 0);
                foreach (i; 0 .. 3)
                    if (startCardRect(i).has(x, y))
                        return Hit(Action.startCard, i);
                break;
            case Page.design:
                if (articleNextRect().has(x, y))
                    return Hit(Action.articleNext, 0);
                break;
            case Page.docs:
                foreach (i; 0 .. 4)
                    if (docNavRect(i).has(x, y))
                        return Hit(Action.docNav, i);
                if (copyCodeRect().has(x, y))
                    return Hit(Action.copyCode, 0);
                break;
            case Page.gallery:
                foreach (i; 0 .. 6)
                    if (galleryCardRect(i).has(x, y))
                        return Hit(Action.gallerySwatch, i);
                if (copyHexRect().has(x, y))
                    return Hit(Action.copyHex, 0);
                break;
            default:
                break;
        }
        return Hit(Action.none, 0);
    }

    bool hovered(Action action, int data = -1) const
    {
        return hover.action == action && (data < 0 || hover.data == data);
    }

    ulong renderSignature() const
    {
        ulong hash = 1469598103934665603UL;
        void add(ulong value)
        {
            hash = (hash ^ value) * 1099511628211UL;
        }
        add(cast(ulong) tabCount);
        add(cast(ulong) activeTab);
        add(bookmarksVisible ? 1 : 0);
        add(menuOpen ? 1 : 0);
        add(suggestOpen ? 1 : 0);
        add(aboutOpen ? 1 : 0);
        add(cast(ulong) hover.action);
        add(cast(ulong) hover.data);
        add(loadingTicks > 0 ? cast(ulong) loadingTicks : 0);
        if (loadingTicks > 0) add(cast(ulong) (frame / 2));
        add(toastTicks > 0 ? 1 : 0);
        add(cast(ulong) toastSerial);
        add(copiedTicks > 0 ? 1 : 0);
        foreach (i; 0 .. tabCount)
            add(cast(ulong) tabs[i].page());
        add(tabs[activeTab].starred ? 1 : 0);
        add(cast(ulong) tabs[activeTab].docSection);
        add(cast(ulong) tabs[activeTab].galleryIndex);
        return hash;
    }
}

// ---------------------------------------------------------------------------
// Palette and page data

private Color background()
{
    return C(0x0b0f15);
}

private Color chrome()
{
    return C(0x111722);
}

private Color chromeDeep()
{
    return C(0x0e141d);
}

private Color border()
{
    return C(0x232d3a);
}

private Color ink()
{
    return C(0xe7eef6);
}

private Color muted()
{
    return C(0x8c9caf);
}

private Color dim()
{
    return C(0x5d6e82);
}

private Color accent()
{
    return C(0x38bdf8);
}

private Color violet()
{
    return C(0x818cf8);
}

private Color green()
{
    return C(0x34d399);
}

private Color warm()
{
    return C(0xf59e0b);
}

private Color danger()
{
    return C(0xf87171);
}

private immutable uint[6] swatchColors = [
    0xf25f4d, 0x38bdf8, 0xf5b83d, 0x8b7cf6, 0xe8e1d6, 0x293241
];

private immutable string[6] swatchNames = [
    "Ember", "Tide", "Citrus", "Iris", "Paper", "Ink"
];

private immutable string[6] swatchHex = [
    "#F25F4D", "#38BDF8", "#F5B83D", "#8B7CF6", "#E8E1D6", "#293241"
];

private immutable string[4] bookmarkLabels = [
    "Aurora Start", "Design Notes", "Docs", "Gallery"
];

private immutable Page[4] bookmarkPages = [
    Page.start, Page.design, Page.docs, Page.gallery
];

// ---------------------------------------------------------------------------
// Rendering

private struct Renderer
{
    AuroraCanvas canvas;
    Fonts fonts;
    Browser* browser;
    int top;
    int bottom;

    void draw()
    {
        auto b = browser;
        top = b.pageTop();
        bottom = b.contentBottom();
        drawChromeShapes();
        drawPageShapes();
        drawChromeText();
        drawPageText();
        drawOverlays();
    }

    private void text(int encodedScale, string value, int x, int y,
        Color color)
    {
        if (value.length == 0) return;
        const scale = encodedScale < 0 ? -encodedScale : encodedScale;
        const role = encodedScale < 0 ? FontRole.monospace : FontRole.ui;
        auto layout = canvas.inner.layoutText(dtext(value), scale, role);
        canvas.inner.drawLayout(Point(x, y), layout, color);
    }

    private int measure(int encodedScale, string value)
    {
        if (value.length == 0) return 0;
        const scale = encodedScale < 0 ? -encodedScale : encodedScale;
        const role = encodedScale < 0 ? FontRole.monospace : FontRole.ui;
        return canvas.inner.measureText(dtext(value), scale, role).width;
    }

    private void textRight(int encodedScale, string value, int right, int y,
        Color color)
    {
        text(encodedScale, value, right - measure(encodedScale, value),
            y, color);
    }

    private void textCenter(int encodedScale, string value, int centerX,
        int y,
        Color color)
    {
        text(encodedScale, value,
            centerX - measure(encodedScale, value) / 2, y, color);
    }

    private int wrap(int encodedScale, string value, int x, int y, int w, int h,
        Color color)
    {
        if (value.length == 0 || w <= 0 || h <= 0) return 0;
        const scale = encodedScale < 0 ? -encodedScale : encodedScale;
        const role = encodedScale < 0 ? FontRole.monospace : FontRole.ui;
        auto layout = canvas.inner.layoutText(dtext(value), scale, role,
            null, w, true);
        auto child = canvas.inner.clipped(ar(x, y, w, h));
        child.drawLayout(Point(x, y), layout, color);
        return layout.measuredSize.height;
    }

    // ----- common icons ----------------------------------------------------

    private void chevron(int x, int y, int direction, Color color)
    {
        const t = 1.8f;
        if (direction < 0)
        {
            canvas.line(x + 6, y, x, y + 6, t, color);
            canvas.line(x, y + 6, x + 6, y + 12, t, color);
        }
        else
        {
            canvas.line(x, y, x + 6, y + 6, t, color);
            canvas.line(x + 6, y + 6, x, y + 12, t, color);
        }
    }


    private void searchIcon(float x, float y, Color color)
    {
        canvas.ring(x, y, 6.2f, 1.7f, color);
        canvas.line(x + 4.5f, y + 4.5f, x + 10.5f, y + 10.5f, 1.8f, color);
    }

    private void lockIcon(float x, float y, Color color)
    {
        canvas.roundRect(cast(int) x - 6, cast(int) y - 1, 12, 10, 2, color);
        canvas.ring(x, y - 4, 4.2f, 1.4f, color);
    }

    private void plusIcon(float x, float y, Color color)
    {
        canvas.line(x - 5, y, x + 5, y, 1.8f, color);
        canvas.line(x, y - 5, x, y + 5, 1.8f, color);
    }

    private void closeIcon(float x, float y, Color color)
    {
        canvas.line(x - 4, y - 4, x + 4, y + 4, 1.6f, color);
        canvas.line(x + 4, y - 4, x - 4, y + 4, 1.6f, color);
    }

    private void starIcon(float x, float y, float size, Color color,
        bool filled)
    {
        if (filled) canvas.star(x, y, size, size * 0.45f, color);
        else canvas.star(x, y, size, size * 0.45f, color);
    }

    private void menuIcon(float x, float y, Color color)
    {
        canvas.circle(x - 5, y, 1.7f, color);
        canvas.circle(x, y, 1.7f, color);
        canvas.circle(x + 5, y, 1.7f, color);
    }

    private void houseIcon(float x, float y, Color color)
    {
        canvas.line(x - 8, y, x, y - 7, 1.7f, color);
        canvas.line(x, y - 7, x + 8, y, 1.7f, color);
        canvas.line(x - 6, y, x - 6, y + 8, 1.7f, color);
        canvas.line(x + 6, y, x + 6, y + 8, 1.7f, color);
        canvas.line(x - 6, y + 8, x + 6, y + 8, 1.7f, color);
    }

    private void reloadIcon(float x, float y, Color color, bool spin)
    {
        const float start = spin ? (browser.frame % 36) * 0.1745f : -1.1f;
        const float end = spin ? start + 4.7f : start + 4.9f;
        float previousX;
        float previousY;
        foreach (i; 0 .. 13)
        {
            const t = i / 12.0f;
            const angle = start + (end - start) * t;
            const px = x + cosf(angle) * 7;
            const py = y + sinf(angle) * 7;
            if (i > 0) canvas.line(previousX, previousY, px, py, 1.7f, color);
            previousX = px;
            previousY = py;
        }
        const endAngle = end;
        const tipX = x + cosf(endAngle) * 7;
        const tipY = y + sinf(endAngle) * 7;
        canvas.line(tipX, tipY, tipX - 4, tipY - 1, 1.6f, color);
        canvas.line(tipX, tipY, tipX, tipY - 4, 1.6f, color);
    }

    private void arrowRight(float x, float y, Color color)
    {
        canvas.line(x, y, x + 10, y, 1.5f, color);
        canvas.line(x + 10, y, x + 6, y - 4, 1.5f, color);
        canvas.line(x + 10, y, x + 6, y + 4, 1.5f, color);
    }

    private void checkIcon(float x, float y, Color color)
    {
        canvas.line(x - 4, y, x - 1, y + 3, 1.7f, color);
        canvas.line(x - 1, y + 3, x + 5, y - 4, 1.7f, color);
    }

    // ----- chrome shapes ---------------------------------------------------

    private void drawChromeShapes()
    {
        auto b = browser;
        canvas.clear(background());

        // Tab strip.
        canvas.gradient(0, 0, Width, 48, C(0x151b25), C(0x10161f));
        canvas.fill(0, 47, Width, 1, C(0x28323f));

        // Aurora mark.
        canvas.roundRect(18, 13, 22, 22, 7, C(0x172737));
        canvas.ring(29, 24, 7.0f, 1.5f, accent());
        canvas.circle(35, 18, 2.1f, violet());

        foreach (i; 0 .. b.tabCount)
        {
            auto area = b.tabRect(i);
            const active = i == b.activeTab;
            if (active)
            {
                canvas.roundRect(area.x, area.y, area.w, area.h, 9, C(0x1b2431));
                canvas.roundRect(area.x + 1, area.y + 1, area.w - 2,
                    area.h - 2, 8, C(0x17202c));
                canvas.fill(area.x + 14, area.y + area.h - 3,
                    area.w - 28, 2, accent());
            }
            else if (b.hovered(Action.tab, i) || b.hovered(Action.tabClose, i))
                canvas.roundRect(area.x, area.y, area.w, area.h, 9, C(0x202a37));
            if (active || b.hovered(Action.tab, i))
                closeIcon(area.x + area.w - 18, area.y + 17,
                    active ? ink() : muted());
            else if (b.hovered(Action.tabClose, i))
                closeIcon(area.x + area.w - 18, area.y + 17, ink());
        }

        if (b.hovered(Action.newTab))
            canvas.circle(b.newTabRect().x + 12, 24, 12, C(0x202a37));
        plusIcon(b.newTabRect().x + 12, 24,
            b.hovered(Action.newTab) ? ink() : muted());

        // Window controls are decorative in the mockup.
        canvas.line(Width - 64, 23, Width - 54, 23, 1.2f, dim());
        canvas.roundOutline(Width - 40, 17, 11, 11, 1, 1.2f, dim());
        canvas.line(Width - 15, 17, Width - 5, 27, 1.2f, dim());
        canvas.line(Width - 5, 17, Width - 15, 27, 1.2f, dim());

        // Navigation bar.
        canvas.gradient(0, 48, Width, 52, C(0x121923), C(0x0f151e));
        canvas.fill(0, 99, Width, 1, C(0x202a37));
        foreach (i; 0 .. 4)
            if (b.hovered(cast(Action) (cast(int) Action.back + i)))
                canvas.circle(b.navButtonRect(i).x + 17,
                    b.navButtonRect(i).y + 17, 17, C(0x202b39));

        auto address = b.addressRect();
        const addressHot = b.suggestOpen || b.hovered(Action.address);
        canvas.roundRect(address.x, address.y, address.w, address.h, 19,
            C(0x0c121a));
        canvas.roundOutline(address.x, address.y, address.w, address.h,
            19, addressHot ? 1.6f : 1.0f,
            addressHot ? accent() : C(0x2b3747));

        if (b.hovered(Action.star))
            canvas.circle(b.starRect().x + 17, b.starRect().y + 17,
                17, C(0x202b39));
        starIcon(b.starRect().x + 17, b.starRect().y + 17, 8,
            b.tab().starred ? warm() : muted(), b.tab().starred);

        if (b.hovered(Action.menu))
            canvas.circle(b.menuButtonRect().x + 17,
                b.menuButtonRect().y + 17, 17, C(0x202b39));
        menuIcon(b.menuButtonRect().x + 17, b.menuButtonRect().y + 17,
            muted());

        // Bookmark bar.
        if (b.bookmarksVisible)
        {
            canvas.fill(0, 100, Width, 38, C(0x0d131b));
            canvas.fill(0, 137, Width, 1, C(0x1d2734));
            foreach (i; 0 .. 4)
            {
                auto area = b.bookmarkChipRect(i);
                const active = bookmarkPages[i] == b.tab().page();
                if (active)
                {
                    canvas.roundRect(area.x, area.y, area.w, area.h, 12,
                        C(0x173247));
                    canvas.roundOutline(area.x, area.y, area.w, area.h, 12,
                        1.0f, C(0x24506b));
                }
                else if (b.hovered(Action.bookmark, i))
                    canvas.roundRect(area.x, area.y, area.w, area.h, 12,
                        C(0x18222e));
                canvas.circle(area.x + 14, area.y + 12, 3.0f,
                    active ? accent() : (i == 0 ? green() :
                    (i == 1 ? warm() : (i == 2 ? violet() : danger()))));
            }
        }

        // Status bar.
        canvas.fill(0, Height - StatusH, Width, StatusH, C(0x0c1118));
        canvas.fill(0, Height - StatusH, Width, 1, C(0x1c2632));
        canvas.circle(21, Height - 12, 3.0f, green());
    }

    // ----- page shapes -----------------------------------------------------

    private void drawPageShapes()
    {
        auto b = browser;
        switch (b.tab().page())
        {
            case Page.start: drawStartShapes(); break;
            case Page.design: drawDesignShapes(); break;
            case Page.docs: drawDocsShapes(); break;
            case Page.gallery: drawGalleryShapes(); break;
            default: break;
        }
    }

    private void drawStartShapes()
    {
        auto b = browser;
        canvas.gradient(0, top, Width, bottom - top,
            C(0x09111d), C(0x0d1926));
        canvas.ring(848, top + 176, 198, 1.0f, C(0x38bdf8, 20));
        canvas.ring(848, top + 176, 146, 1.0f, C(0x818cf8, 18));
        canvas.ring(92, top + 440, 232, 1.0f, C(0x38bdf8, 12));
        canvas.circle(710, top + 84, 2.2f, C(0x38bdf8, 170));
        canvas.circle(960, top + 324, 3.0f, C(0x818cf8, 130));

        const int center = Width / 2;
        const int pillW = 212;
        canvas.roundRect(center - pillW / 2, top + 42, pillW, 26, 13,
            C(0x101b28));
        canvas.roundOutline(center - pillW / 2, top + 42, pillW, 26, 13,
            1.0f, C(0x223247));
        canvas.circle(center - pillW / 2 + 18, top + 55, 3.0f, green());

        auto search = b.searchRect();
        canvas.roundRect(search.x, search.y, search.w, search.h, 26,
            C(0x0f1a27));
        canvas.roundOutline(search.x, search.y, search.w, search.h, 26,
            b.hovered(Action.address) ? 1.6f : 1.0f,
            b.hovered(Action.address) ? accent() : C(0x27394e));
        canvas.fill(search.x + search.w - 74, search.y + 14, 58, 24,
            C(0x172536));
        searchIcon(search.x + 25, search.y + 26, muted());

        foreach (i; 0 .. 3)
        {
            auto card = b.startCardRect(i);
            const hot = b.hovered(Action.startCard, i);
            canvas.roundRect(card.x, card.y + 5, card.w, card.h, 14,
                C(0x000000, 38));
            canvas.roundRect(card.x, card.y, card.w, card.h, 14,
                hot ? C(0x13202e) : C(0x0f1925));
            canvas.roundOutline(card.x, card.y, card.w, card.h, 14, 1.0f,
                hot ? C(0x3b5d79) : C(0x213044));
            canvas.fill(card.x + 18, card.y + 18, 36, 36,
                C(i == 0 ? 0x463126 : (i == 1 ? 0x173243 : 0x2b2452)));
            const iconColor = i == 0 ? warm() :
                (i == 1 ? accent() : violet());
            if (i == 0)
            {
                canvas.ring(card.x + 36, card.y + 36, 8.0f, 1.5f, iconColor);
                canvas.circle(card.x + 36, card.y + 36, 2.2f, iconColor);
            }
            else if (i == 1)
            {
                canvas.line(card.x + 29, card.y + 30, card.x + 43,
                    card.y + 30, 1.5f, iconColor);
                canvas.line(card.x + 29, card.y + 36, card.x + 43,
                    card.y + 36, 1.5f, iconColor);
                canvas.line(card.x + 29, card.y + 42, card.x + 39,
                    card.y + 42, 1.5f, iconColor);
            }
            else
            {
                canvas.circle(card.x + 36, card.y + 36, 5.0f, iconColor);
                canvas.line(card.x + 24, card.y + 45, card.x + 31,
                    card.y + 37, 1.5f, iconColor);
                canvas.line(card.x + 31, card.y + 37, card.x + 38,
                    card.y + 44, 1.5f, iconColor);
            }
            arrowRight(card.x + card.w - 34, card.y + 30,
                hot ? ink() : dim());
            canvas.fill(card.x + 18, card.y + card.h - 1, 58, 2,
                hot ? iconColor : C(0x33445a));
        }
    }

    private void drawDesignShapes()
    {
        auto b = browser;
        canvas.gradient(0, top, Width, bottom - top,
            C(0xf4efe6), C(0xeee6da));
        canvas.fill(0, top, Width, 58, C(0xf7f3ec));
        canvas.fill(0, top + 58, Width, 1, C(0xd9cec0));
        canvas.fill(48, top + 190, 3, 54, C(0xc55f3f));

        auto quote = Rect(620, top + 196, 276, 156);
        canvas.roundRect(quote.x, quote.y, quote.w, quote.h, 12,
            C(0xe8dfd1));
        canvas.roundOutline(quote.x, quote.y, quote.w, quote.h, 12, 1.0f,
            C(0xd7c8b5));
        canvas.fill(quote.x + 20, quote.y + 20, 30, 2, C(0xc55f3f));

        auto principle = Rect(620, top + 368, 276, 70);
        canvas.roundRect(principle.x, principle.y, principle.w,
            principle.h, 10, C(0x1d2732));
        canvas.circle(principle.x + 24, principle.y + 22, 3.0f, warm());

        if (b.hovered(Action.articleNext))
        {
            canvas.roundRect(64, top + 384, 250, 36, 9, C(0xe5dbcb));
            canvas.roundOutline(64, top + 384, 250, 36, 9, 1.0f,
                C(0xd2c3ae));
        }
    }

    private void drawDocsShapes()
    {
        auto b = browser;
        canvas.gradient(0, top, Width, bottom - top,
            C(0x0a1017), C(0x0b131c));
        canvas.fill(0, top, 260, bottom - top, C(0x0e151e));
        canvas.fill(259, top, 1, bottom - top, C(0x1d2936));
        canvas.fill(260, top, 1, bottom - top, C(0x070b10));

        foreach (i; 0 .. 4)
        {
            auto area = b.docNavRect(i);
            const active = b.tab().docSection == i;
            if (active)
            {
                canvas.roundRect(area.x, area.y, area.w, area.h, 8,
                    C(0x15222f));
                canvas.fill(area.x, area.y + 7, 2, area.h - 14, accent());
            }
            else if (b.hovered(Action.docNav, i))
                canvas.roundRect(area.x, area.y, area.w, area.h, 8,
                    C(0x151f2a));
        }

        canvas.fill(36, top + 292, 188, 1, C(0x1e2a37));

        auto code = Rect(292, top + 146, Width - 292 - 32, 168);
        canvas.roundRect(code.x, code.y, code.w, code.h, 10, C(0x111a24));
        canvas.roundOutline(code.x, code.y, code.w, code.h, 10, 1.0f,
            C(0x263442));
        canvas.fill(code.x, code.y + 34, code.w, 1, C(0x22303d));
        canvas.circle(code.x + 18, code.y + 17, 3.0f, C(0xf87171, 180));
        canvas.circle(code.x + 30, code.y + 17, 3.0f, C(0xf5b83d, 180));
        canvas.circle(code.x + 42, code.y + 17, 3.0f, C(0x34d399, 180));

        auto copy = b.copyCodeRect();
        if (b.hovered(Action.copyCode))
            canvas.roundRect(copy.x, copy.y, copy.w, copy.h, 7,
                C(0x1d2b3a));
        else if (b.copiedTicks > 0)
            canvas.roundRect(copy.x, copy.y, copy.w, copy.h, 7,
                C(0x17372f));
        else
            canvas.roundRect(copy.x, copy.y, copy.w, copy.h, 7,
                C(0x172432));
        canvas.roundOutline(copy.x, copy.y, copy.w, copy.h, 7, 1.0f,
            b.copiedTicks > 0 ? C(0x2d6a5a) : C(0x2c3c4c));

        auto note = Rect(292, top + 430, Width - 292 - 32, 44);
        canvas.roundRect(note.x, note.y, note.w, note.h, 8, C(0x101b19));
        canvas.fill(note.x, note.y + 8, 2, note.h - 16, green());
    }

    private void drawGalleryShapes()
    {
        auto b = browser;
        canvas.gradient(0, top, Width, bottom - top,
            C(0x160f23), C(0x0e1119));
        canvas.ring(824, top + 80, 180, 1.0f, C(0x818cf8, 20));
        canvas.ring(80, top + 440, 200, 1.0f, C(0x38bdf8, 12));

        foreach (i; 0 .. 6)
        {
            auto card = b.galleryCardRect(i);
            const selected = b.tab().galleryIndex == i;
            canvas.roundRect(card.x, card.y + 4, card.w, card.h, 12,
                C(0x000000, 45));
            canvas.roundRect(card.x, card.y, card.w, card.h, 12,
                C(swatchColors[i]));
            if (selected)
                canvas.roundOutline(card.x - 2, card.y - 2, card.w + 4,
                    card.h + 4, 14, 2.0f, accent());
            else if (b.hovered(Action.gallerySwatch, i))
                canvas.roundOutline(card.x, card.y, card.w, card.h, 12,
                    1.4f, C(0xffffff, 130));
        }

        auto detail = Rect(628, top + 156, 268, 290);
        canvas.roundRect(detail.x, detail.y, detail.w, detail.h, 14,
            C(0x111722));
        canvas.roundOutline(detail.x, detail.y, detail.w, detail.h, 14,
            1.0f, C(0x283344));
        canvas.roundRect(detail.x + 18, detail.y + 18, detail.w - 36,
            142, 10, C(swatchColors[b.tab().galleryIndex]));
        canvas.roundRect(detail.x + 18, detail.y + 176, 92, 2, 1,
            C(swatchColors[b.tab().galleryIndex]));

        auto copy = b.copyHexRect();
        if (b.hovered(Action.copyHex))
            canvas.roundRect(copy.x, copy.y, copy.w, copy.h, 8,
                C(0x1d2b3a));
        else
            canvas.roundRect(copy.x, copy.y, copy.w, copy.h, 8,
                C(0x172432));
        canvas.roundOutline(copy.x, copy.y, copy.w, copy.h, 8, 1.0f,
            C(0x2b3a4b));
    }

    // ----- chrome text -----------------------------------------------------

    private void drawChromeText()
    {
        auto b = browser;

        foreach (i; 0 .. b.tabCount)
        {
            auto area = b.tabRect(i);
            const active = i == b.activeTab;
            auto color = active ? ink() : muted();
            string label = b.pageTitle(b.tabs[i].page());
            if (label.length > 20) label = label[0 .. 20];
            text(active ? fonts.boldSmall : fonts.boldSmall, label,
                area.x + 14, area.y + 9, color);
        }

        // Navigation icons.
        chevron(31, 69, -1, b.tab().historyIndex > 0 ? ink() : dim());
        chevron(73, 69, 1,
            b.tab().historyIndex + 1 < b.tab().historyLength ? ink() : dim());
        reloadIcon(117, 74, b.loadingTicks > 0 ? accent() : muted(),
            b.loadingTicks > 0);
        houseIcon(157, 76, muted());

        // Address.
        auto address = b.addressRect();
        lockIcon(address.x + 25, address.y + 20, green());
        string url = b.pageURL(b.tab().page(), b.tab().docSection);
        const scheme = "aurora://";
        text(fonts.monoSmall, scheme, address.x + 42, address.y + 11,
            dim());
        const int schemeWidth = measure(fonts.monoSmall, scheme);
        text(fonts.monoSmall, url[scheme.length .. $],
            address.x + 42 + schemeWidth, address.y + 11,
            b.suggestOpen ? ink() : muted());

        // Bookmark chips.
        if (b.bookmarksVisible)
        {
            foreach (i; 0 .. 4)
            {
                auto area = b.bookmarkChipRect(i);
                const active = bookmarkPages[i] == b.tab().page();
                text(fonts.boldSmall, bookmarkLabels[i], area.x + 24,
                    area.y + 6, active ? ink() : muted());
            }
            textRight(fonts.boldSmall, "LOCAL SESSION", Width - 24, 116,
                dim());
        }

        // Status.
        string statusURL = b.pageURL(b.tab().page(), b.tab().docSection);
        text(fonts.tiny, "READY  /  " ~ statusURL, 32, Height - 19, dim());
        textRight(fonts.tiny, "OFFLINE MOCKUP  /  AURORA LIVE APP",
            Width - 20, Height - 19, dim());
    }

    // ----- page text -------------------------------------------------------

    private void drawPageText()
    {
        switch (browser.tab().page())
        {
            case Page.start: drawStartText(); break;
            case Page.design: drawDesignText(); break;
            case Page.docs: drawDocsText(); break;
            case Page.gallery: drawGalleryText(); break;
            default: break;
        }
    }

    private void drawStartText()
    {
        auto b = browser;
        const int center = Width / 2;
        textCenter(fonts.boldSmall, "AURORA START  /  OFFLINE",
            center + 7, top + 49, muted());
        textCenter(fonts.boldDisplay, "A calmer way to browse.",
            center, top + 86, ink());
        textCenter(fonts.body,
            "A private workspace for the pages you actually need.",
            center, top + 148, C(0x8fa3b9));

        auto search = b.searchRect();
        text(fonts.body, "Search or enter an address", search.x + 48,
            search.y + 16, C(0x72869b));
        text(fonts.boldSmall, "CTRL K", search.x + search.w - 60,
            search.y + 18, muted());

        textCenter(fonts.boldSmall, "QUICK ACCESS", center,
            top + 270, dim());

        immutable string[3] titles = [
            "Design Notes", "Docs & guides", "Color studies"
        ];
        immutable string[3] subtitles = [
            "On focus and quiet interfaces.",
            "The Aurora surface, explained.",
            "Palettes with a point of view."
        ];
        foreach (i; 0 .. 3)
        {
            auto card = b.startCardRect(i);
            text(fonts.boldBody, titles[i], card.x + 18, card.y + 66,
                ink());
            text(fonts.small, subtitles[i], card.x + 18, card.y + 88,
                muted());
        }

        textCenter(fonts.tiny,
            "LOCAL MOCKUP  /  NO NETWORK REQUESTS  /  CLICK A CARD OR A BOOKMARK",
            center, top + 448, C(0x53677d));
    }

    private void drawDesignText()
    {
        auto b = browser;
        text(fonts.journal, "AURORA JOURNAL", 64, top + 20,
            C(0x201b16));
        textRight(fonts.boldSmall, "ISSUE 04  /  DESIGN", Width - 64,
            top + 26, C(0x7a6d5e));

        text(fonts.serifTitle, "Designing for focus", 64, top + 72,
            C(0x1b1712));
        text(fonts.serifItalic,
            "A field guide to interfaces that leave room to think.",
            64, top + 134, C(0x5e554a));
        text(fonts.boldSmall, "MARA VOSS  /  8 MIN READ", 66, top + 170,
            C(0x8b7b68));

        wrap(fonts.serifBody,
            "The best interfaces do not demand attention. They make the " ~
            "next step obvious, then get out of the way. Focus is not a " ~
            "feature you toggle; it is the absence of everything that did " ~
            "not need to be there.",
            64, top + 206, 512, 88, C(0x342e27));

        wrap(fonts.serifBody,
            "Leave room around the thing that matters. Use one strong " ~
            "signal instead of five competing ones, and let quiet surfaces " ~
            "carry the small decisions.",
            64, top + 296, 512, 88, C(0x342e27));

        auto next = b.articleNextRect();
        const linkColor = b.hovered(Action.articleNext) ?
            C(0x9b3f27) : C(0xb34c30);
        text(fonts.boldBody, "Read the field notes", next.x + 14,
            next.y + 8, linkColor);
        const linkWidth = measure(fonts.boldBody,
            "Read the field notes");
        arrowRight(next.x + 22 + linkWidth, next.y + 17, linkColor);

        auto quote = Rect(620, top + 196, 276, 156);
        canvas.roundRect(quote.x + 24, quote.y + 18, 8, 22, 4,
            C(0xc55f3f, 180));
        canvas.roundRect(quote.x + 38, quote.y + 18, 8, 22, 4,
            C(0xc55f3f, 180));
        wrap(fonts.serifItalic,
            "Attention is the rarest thing we can give an interface. " ~
            "Spend it carefully.",
            quote.x + 24, quote.y + 48, quote.w - 48, 80,
            C(0x46392f));
        text(fonts.boldSmall, "PRINCIPLE 01", quote.x + 24,
            quote.y + 127, C(0x8b725d));

        auto principle = Rect(620, top + 368, 276, 70);
        text(fonts.boldSmall, "LEAVE ROOM", principle.x + 40,
            principle.y + 16, C(0xe8eef5));
        text(fonts.tiny, "Quiet chrome. One clear next step.",
            principle.x + 40, principle.y + 37, C(0x8fa1b6));
        textRight(fonts.boldSmall, "02 / 03", principle.x + principle.w - 18,
            principle.y + 16, C(0x63758b));
    }

    private void drawDocsText()
    {
        auto b = browser;
        const int section = b.tab().docSection;

        text(fonts.boldLabel, "AURORA", 64, top + 28, ink());
        text(fonts.tiny, "SURFACE DOCUMENTATION", 64, top + 51, dim());
        text(fonts.boldSmall, "REFERENCE", 36, top + 78, accent());

        immutable string[4] navLabels = [
            "Overview", "Pointer input", "Frames", "Lifecycle"
        ];
        foreach (i; 0 .. 4)
        {
            auto area = b.docNavRect(i);
            text(b.tab().docSection == i ? fonts.boldBody : fonts.body,
                navLabels[i], area.x + 16, area.y + 8,
                b.tab().docSection == i ? ink() : muted());
            if (b.tab().docSection == i)
                canvas.circle(area.x + area.w - 18, area.y + 17, 3.0f,
                    accent());
        }

        text(fonts.boldSmall, "SURFACE V2", 36, top + 310, dim());
        text(fonts.tiny, "24-byte input events", 36, top + 328, dim());
        text(fonts.tiny, "Two RGBA frame buffers", 36, top + 344, dim());
        text(fonts.tiny, "80-byte header", 36, top + 360, dim());
        text(fonts.tiny, "Pointer events enabled", 36, bottom - 52, dim());

        text(fonts.boldSmall, "REFERENCE  /  SURFACE V2", 292, top + 28,
            accent());
        string heading;
        string intro;
        string note;
        string[] codeLines;
        switch (section)
        {
            case 0:
                heading = "Build calm interfaces.";
                intro = "A small explicit contract for pixels, input and " ~
                    "lifecycle. The host owns the window; the module owns " ~
                    "the page.";
                codeLines = [
                    "auto surface = LiveSurface(path);",
                    "surface.publish(frame);",
                    "surface.waitHost(surface.sequence);",
                    "",
                    "// no network, no hidden host widgets",
                ];
                note = "This browser shell is one module. Every tab, page " ~
                    "and transition is local state.";
                break;
            case 1:
                heading = "Pointer input, plainly.";
                intro = "Events arrive in a ring: down, move, up, wheel, " ~
                    "key down and key up. Coordinates are logical surface " ~
                    "coordinates.";
                codeLines = [
                    "InputEvent[64] events;",
                    "const count = surface.readInputs(events);",
                    "foreach (i; 0 .. count)",
                    "    if (events[i].kind == 1)",
                    "        click(events[i].x, events[i].y);",
                ];
                note = "This sample hit-tests the same rectangles it " ~
                    "draws, so tabs and cards stay in sync.";
                break;
            case 2:
                heading = "Publish complete frames.";
                intro = "Fill the inactive buffer, select it, then advance " ~
                    "the sequence. The two buffers prevent the host from " ~
                    "reading half a frame.";
                codeLines = [
                    "const target = 1 - active;",
                    "auto offset = frameStart(target);",
                    "data[offset .. offset + frameBytes] = pixels[];",
                    "put!uint(24, target);",
                    "put!ulong(32, ++sequence);",
                ];
                note = "The module waits for hostReadSeq() before touching " ~
                    "a buffer the host may still be copying.";
                break;
            case 3:
                heading = "Handshake, don't guess.";
                intro = "The host reports mapping state, dimensions and " ~
                    "frame freshness. A module publishes before the stale " ~
                    "window closes.";
                codeLines = [
                    "READY",
                    "  -> Mapped",
                    "  -> Live <-> Stale",
                    "  -> Closed",
                    "",
                    "// version, capabilities, surface",
                ];
                note = "The generic host knows nothing about browser tabs. " ~
                    "That policy stays in this project.";
                break;
            default:
                heading = "Build calm interfaces.";
                intro = "A small explicit contract for pixels, input and " ~
                    "lifecycle.";
                codeLines = ["auto surface = LiveSurface(path);"];
                note = "This browser shell is one module.";
                break;
        }
        text(fonts.boldDisplay, heading, 292, top + 48,
            C(0xf0f5fa));
        wrap(fonts.body, intro, 292, top + 98, Width - 292 - 32, 42,
            muted());

        auto codeRect = Rect(292, top + 146, Width - 292 - 32, 168);
        if (b.copiedTicks > 0)
            text(fonts.boldSmall, "COPIED", b.copyCodeRect().x + 14,
                b.copyCodeRect().y + 8, green());
        else
            text(fonts.boldSmall, "COPY", b.copyCodeRect().x + 18,
                b.copyCodeRect().y + 8,
                b.hovered(Action.copyCode) ? ink() : dim());
        text(fonts.monoSmall, "module.d", codeRect.x + 56,
            codeRect.y + 10, dim());

        foreach (i; 0 .. codeLines.length)
        {
            text(fonts.monoSmall, codeLines[i], codeRect.x + 20,
                codeRect.y + 44 + cast(int) i * 21,
                i == 0 ? C(0x9dd7f4) : C(0xb9cfe2));
        }

        text(fonts.boldSmall, "IN THIS SAMPLE", 292, top + 334,
            C(0x7c8da1));
        text(fonts.boldTitle, "The browser is a page.",
            292, top + 354, C(0xe4edf6));
        wrap(fonts.body,
            "Tabs, history, bookmarks and the command menu are ordinary " ~
            "state in module.d. The host only copies the finished surface " ~
            "and routes pointer events back.",
            292, top + 380, Width - 292 - 32, 46, muted());

        auto noteRect = Rect(292, top + 430, Width - 292 - 32, 44);
        text(fonts.small, note, noteRect.x + 14, noteRect.y + 10,
            C(0xa9c9bf));
    }

    private void drawGalleryText()
    {
        auto b = browser;
        const int selected = b.tab().galleryIndex;

        text(fonts.boldSmall, "COLOR  /  MOTION  /  MATERIAL",
            64, top + 28, violet());
        text(fonts.boldDisplay, "Color studies.", 64, top + 50, ink());
        text(fonts.body,
            "A small palette library for quiet interfaces.",
            64, top + 106, muted());
        textRight(fonts.boldSmall, "06 STUDIES", Width - 64, top + 32,
            dim());

        foreach (i; 0 .. 6)
        {
            auto card = b.galleryCardRect(i);
            const labelColor = (i == 2 || i == 4) ?
                C(0x20252f) : C(0xffffff);
            text(fonts.boldBody, swatchNames[i], card.x + 16,
                card.y + card.h - 50, labelColor);
            text(fonts.tiny, swatchHex[i], card.x + 16,
                card.y + card.h - 24,
                labelColor.withAlpha(190));
            if (b.tab().galleryIndex == i)
            {
                canvas.circle(card.x + card.w - 20, card.y + 20, 11,
                    (i == 2 || i == 4) ? C(0xe9e4da, 235) :
                    C(0xffffff, 210));
                checkIcon(card.x + card.w - 20, card.y + 20,
                    C(0x1b2028));
            }
        }

        auto detail = Rect(628, top + 156, 268, 290);
        text(fonts.boldSmall, "SELECTED STUDY", detail.x + 18,
            detail.y + 166, accent());
        text(fonts.boldTitle, swatchNames[selected], detail.x + 18,
            detail.y + 188, ink());
        text(fonts.monoSmall, swatchHex[selected], detail.x + 18,
            detail.y + 224, C(0x9db3c8));
        text(fonts.tiny, "RGB  " ~ swatchRgb(selected),
            detail.x + 18, detail.y + 240, dim());

        auto copy = b.copyHexRect();
        if (b.copiedTicks > 0)
            text(fonts.boldSmall, "COPIED", copy.x + 86, copy.y + 10,
                green());
        else
            text(fonts.boldSmall, "COPY HEX", copy.x + 78, copy.y + 10,
                b.hovered(Action.copyHex) ? ink() : muted());
        text(fonts.boldSmall, "HEX", copy.x + 16, copy.y + 10, dim());

        textCenter(fonts.tiny,
            "CLICK A STUDY TO INSPECT IT  /  EVERYTHING IS LOCAL",
            Width / 2, top + 462, C(0x68788d));
    }

    private string swatchRgb(int index)
    {
        const value = swatchColors[index];
        return to!string(cast(int) ((value >> 16) & 0xff)) ~ "  " ~
            to!string(cast(int) ((value >> 8) & 0xff)) ~ "  " ~
            to!string(cast(int) (value & 0xff));
    }

    // ----- overlays --------------------------------------------------------

    private void drawOverlays()
    {
        auto b = browser;
        if (b.menuOpen) drawMenu();
        if (b.suggestOpen) drawSuggestions();
        if (b.aboutOpen) drawAbout();
        if (b.toastTicks > 0 && !b.aboutOpen) drawToast();
    }

    private void drawMenu()
    {
        auto b = browser;
        auto area = b.menuRect();
        canvas.roundRect(area.x + 4, area.y + 7, area.w, area.h, 12,
            C(0x000000, 80));
        canvas.roundRect(area.x, area.y, area.w, area.h, 12, C(0x18212c));
        canvas.roundOutline(area.x, area.y, area.w, area.h, 12, 1.0f,
            C(0x334154));

        immutable string[5] labels = [
            "New tab", "Home", "Bookmark this page",
            "Hide bookmarks bar", "About this mockup"
        ];
        foreach (i; 0 .. 5)
        {
            auto row = b.menuItemRect(i);
            if (b.hovered(Action.menuItem, i))
                canvas.roundRect(row.x, row.y, row.w, row.h, 7,
                    C(0x243244));
            const iconColor = b.hovered(Action.menuItem, i) ? ink() : muted();
            if (i == 0) plusIcon(row.x + 18, row.y + 17, iconColor);
            else if (i == 1) houseIcon(row.x + 18, row.y + 18, iconColor);
            else if (i == 2)
                starIcon(row.x + 18, row.y + 17, 7, iconColor,
                    b.tab().starred);
            else if (i == 3)
            {
                canvas.roundRect(row.x + 11, row.y + 10, 14, 16, 2,
                    iconColor);
                canvas.line(row.x + 11, row.y + 20, row.x + 25,
                    row.y + 20, 1.2f, C(0x18212c));
            }
            else
            {
                canvas.ring(row.x + 18, row.y + 17, 6, 1.4f, iconColor);
                canvas.circle(row.x + 18, row.y + 15, 1.2f, iconColor);
                canvas.circle(row.x + 18, row.y + 20, 1.2f, iconColor);
            }
            string label = labels[i];
            if (i == 2 && b.tab().starred) label = "Remove bookmark";
            if (i == 3 && b.bookmarksVisible) label = "Hide bookmarks bar";
            if (i == 3 && !b.bookmarksVisible) label = "Show bookmarks bar";
            text(fonts.small, label, row.x + 38, row.y + 8,
                b.hovered(Action.menuItem, i) ? ink() : C(0xc2cfdd));
        }
    }

    private void drawSuggestions()
    {
        auto b = browser;
        auto area = b.suggestRect();
        canvas.roundRect(area.x + 4, area.y + 7, area.w, area.h, 12,
            C(0x000000, 80));
        canvas.roundRect(area.x, area.y, area.w, area.h, 12, C(0x131c27));
        canvas.roundOutline(area.x, area.y, area.w, area.h, 12, 1.0f,
            C(0x334154));
        text(fonts.boldSmall, "RECENT PAGES", area.x + 18, area.y + 10,
            dim());

        immutable string[4] titles = [
            "Aurora Start", "Designing for focus",
            "Docs & guides", "Color studies"
        ];
        immutable string[4] urls = [
            "aurora://start", "aurora://journal/focus",
            "aurora://docs/overview", "aurora://gallery"
        ];
        immutable uint[4] tints = [0x34d399, 0xf59e0b, 0x818cf8, 0xf25f4d];
        foreach (i; 0 .. 4)
        {
            auto row = b.suggestRowRect(i);
            if (b.hovered(Action.suggestion, i))
                canvas.roundRect(row.x, row.y, row.w, row.h, 8,
                    C(0x213044));
            canvas.circle(row.x + 18, row.y + 21, 5.0f, C(tints[i]));
            text(fonts.boldBody, titles[i], row.x + 36, row.y + 4,
                b.hovered(Action.suggestion, i) ? ink() : C(0xd3dfeb));
            text(fonts.monoSmall, urls[i], row.x + 36, row.y + 27,
                dim());
            arrowRight(row.x + row.w - 24, row.y + 21,
                b.hovered(Action.suggestion, i) ? ink() : dim());
        }
    }

    private void drawAbout()
    {
        auto b = browser;
        canvas.fill(0, 0, Width, Height, C(0x02050a, 190));
        auto card = Rect(Width / 2 - 230, 174, 460, 292);
        canvas.roundRect(card.x + 5, card.y + 9, card.w, card.h, 18,
            C(0x000000, 100));
        canvas.roundRect(card.x, card.y, card.w, card.h, 18, C(0x121b26));
        canvas.roundOutline(card.x, card.y, card.w, card.h, 18, 1.0f,
            C(0x334154));
        canvas.roundRect(card.x + 28, card.y + 28, 36, 36, 10,
            C(0x173247));
        canvas.ring(card.x + 46, card.y + 46, 10, 2.0f, accent());
        canvas.circle(card.x + 56, card.y + 36, 3.0f, violet());

        text(fonts.boldTitle, "About this mockup", card.x + 78,
            card.y + 26, ink());
        text(fonts.tiny, "AURORA LIVE APP  /  SURFACE V2",
            card.x + 78, card.y + 50, dim());
        wrap(fonts.body,
            "This is a local design sample, not a network browser. One D " ~
            "module draws the chrome and pages into a shared surface and " ~
            "turns pointer events into tabs, history, bookmarks and " ~
            "viewport changes.",
            card.x + 28, card.y + 86, card.w - 56, 96,
            C(0xaebdcd));
        wrap(fonts.monoSmall,
            "aurora/apps/browser-mockup/module.d",
            card.x + 28, card.y + 190, card.w - 56, 24, C(0x75b9d8));

        auto button = b.aboutCloseRect();
        if (b.hovered(Action.aboutClose))
            canvas.roundRect(button.x, button.y, button.w, button.h, 9,
                C(0x1d3044));
        else
            canvas.roundRect(button.x, button.y, button.w, button.h, 9,
                C(0x172432));
        canvas.roundOutline(button.x, button.y, button.w, button.h, 9,
            1.0f, C(0x35516a));
        textCenter(fonts.boldSmall, "CLOSE", button.x + button.w / 2,
            button.y + 9, ink());
        text(fonts.tiny, "Click outside the card to dismiss.",
            card.x + 28, card.y + card.h - 24, dim());
    }

    private void drawToast()
    {
        auto b = browser;
        const int width = measure(fonts.boldSmall, b.toast) + 58;
        const int x = Width / 2 - width / 2;
        const int y = Height - StatusH - 42;
        canvas.roundRect(x + 3, y + 4, width, 32, 16, C(0x000000, 90));
        canvas.roundRect(x, y, width, 32, 16, C(0x1d2a38));
        canvas.roundOutline(x, y, width, 32, 16, 1.0f, C(0x3d5268));
        canvas.circle(x + 17, y + 16, 3.0f, accent());
        text(fonts.boldSmall, b.toast, x + 30, y + 8, ink());
    }
}

// ---------------------------------------------------------------------------
// Frame conversion

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

// ---------------------------------------------------------------------------
// Main

void main(string[] args)
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
        throw new Exception("Browser mockup requires --surface and --state");

    auto browser = Browser();
    browser.init(statePath, buildId);
    browser.saveState();

    auto surface = LiveSurface(surfacePath);
    scope (exit) surface.close();

    auto auroraSurface = new Surface(Width, Height);
    auto auroraCanvas = Canvas(auroraSurface);
    auto frameBytes = new ubyte[Width * Height * 4];
    auto renderer = Renderer();
    renderer.canvas = AuroraCanvas(auroraCanvas);
    renderer.fonts = Fonts();
    renderer.browser = &browser;

    InputEvent[EventCapacity] events;
    ulong lastSignature;
    bool painted;
    for (int tick = 0; tick < seconds * 60; ++tick)
    {
        const eventCount = surface.readInputs(events);
        foreach (i; 0 .. eventCount) browser.onInput(events[i]);
        browser.update();
        const signature = browser.renderSignature();
        if (!painted || signature != lastSignature)
        {
            renderer.draw();
            publishArgb(auroraSurface.pixels(), frameBytes);
            lastSignature = signature;
            painted = true;
        }
        surface.publish(frameBytes);
        surface.waitHost(surface.sequence, 80);
        if (tick % 4 == 0) browser.saveState();
    }
    browser.saveState();
}
