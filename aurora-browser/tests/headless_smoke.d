module headless_smoke;

/**
 * Headless smoke test for the aurora-browser shell.
 *
 * Runs without a display (software renderer), drives the chrome with the
 * real `UiTestDriver` (typing, Go, back/forward, new tab, Ctrl+T/Ctrl+L),
 * and verifies page content appears in the painted pixels.
 */

import aurora;
import aurorabrowser.appui : BrowserRoot, TabButton, browserTheme;
import auroraweb.dom : Element;

import core.thread : Thread;
import core.time : msecs;
import std.stdio : writeln;
import std.conv : to;
import std.string : indexOf;
import std.utf : toUTF32;

private int failures;

private void check(string label, bool condition)
{
    if (condition)
        writeln("PASS  ", label);
    else
    {
        writeln("FAIL  ", label);
        ++failures;
    }
}

private Widget findById(Widget widget, string requestedId)
{
    if (widget is null) return null;
    if (widget.id() == requestedId) return widget;
    foreach (child; widget.children())
    {
        auto found = findById(child, requestedId);
        if (found !is null) return found;
    }
    return null;
}

int main(string[] args)
{
    WindowOptions options;
    options.title = "Aurora Browser";
    options.width = 1080;
    options.height = 680;
    options.darkTitleBar = false;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, browserTheme());
    auto root = new BrowserRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    driver.paint();
    Thread.sleep(50.msecs);

    check("one tab initially", root.tabCountForTesting() == 1);
    check("starts at auroraweb:hello",
        root.currentUrlForTesting() == "auroraweb:hello");

    // Navigate to the CSS page via the address bar: focus field, type, Enter.
    auto address = cast(TextField) findById(root, "br-address");
    check("address field present", address !is null);
    if (address !is null) address.setText("", false);
    address.requestFocus();
    root.tickTree(0.02);
    driver.text(toUTF32("auroraweb:css"));
    root.tickTree(0.02);
    driver.pressKey(Key.enter);
    root.tickTree(0.02);
    driver.paint();
    Thread.sleep(50.msecs);

    check("navigated to auroraweb:css",
        root.currentUrlForTesting() == "auroraweb:css");
    check("history has two entries", root.historyForTesting().length == 2);

    // JS page: nav to auroraweb:js exercises executeScripts.
    root.navigateForTesting("auroraweb:js");
    driver.paint();
    Thread.sleep(50.msecs);
    check("navigated to auroraweb:js",
        root.currentUrlForTesting() == "auroraweb:js");

    // Back should return to auroraweb:css.
    driver.pressKey(Key.left, cast(uint) KeyModifier.alt);
    root.tickTree(0.02);
    driver.paint();
    Thread.sleep(50.msecs);
    check("back to auroraweb:css",
        root.currentUrlForTesting() == "auroraweb:css");

    // Forward returns to auroraweb:js.
    driver.pressKey(Key.right, cast(uint) KeyModifier.alt);
    root.tickTree(0.02);
    driver.paint();
    Thread.sleep(50.msecs);
    check("forward to auroraweb:js",
        root.currentUrlForTesting() == "auroraweb:js");

    // New tab via Ctrl+T.
    driver.pressKey(Key.t, cast(uint) KeyModifier.control);
    root.tickTree(0.02);
    driver.paint();
    Thread.sleep(50.msecs);
    check("two tabs after Ctrl+T", root.tabCountForTesting() == 2);
    check("second tab active", root.activeTabForTesting() == 1);
    check("second tab on home", root.currentUrlForTesting() == "auroraweb:hello");

    // Painted content sanity: sample pixels below the chrome.
    auto surface = window.surface();
    int nonWhite;
    for (int y = 200; y < 500; y += 3)
        for (int x = 0; x < surface.width(); x += 3)
        {
            const p = surface.pixel(x, y);
            if ((p & 0xffffff) != 0xffffff) ++nonWhite;
        }
    check("page content painted below chrome", nonWhite > 200);

    // Async/await page: the inline script awaits a Promise, then writes the
    // result into the DOM. Verify the painted pixels changed / title loaded.
    root.navigateForTesting("auroraweb:async");
    driver.paint();
    Thread.sleep(50.msecs);
    check("async page loaded", root.currentUrlForTesting() == "auroraweb:async");
    check("async page has title", root.tabTitleForTesting().length > 0);
    // The page's async/await body resolves a Promise and writes the computed
    // result into #status. This exercises the whole chain: inline script runs
    // (parseInto), the await continuation is queued as a microtask on the event
    // loop, and element.textContent = "..." mutates the DOM.
    auto asyncView = root.activeViewForTesting();
    string statusText = "";
    if (asyncView !is null && asyncView.page() !is null)
    {
        Element statusEl = null;
        void findStatus(Element e)
        {
            if (statusEl !is null) return;
            if (e.hasId("status")) { statusEl = e; return; }
            foreach (c; e.elements) findStatus(c);
        }
        findStatus(asyncView.page().root());
        statusText = statusEl is null ? "" : statusEl.textContent();
    }
    check("async await updated the DOM",
        statusText.indexOf("300") >= 0);

    // --- Event loop: setTimeout / setInterval / requestAnimationFrame driven
    // by the browser host's per-tick pump. Each tickTree advances the page's
    // event-loop clock by 20 ms, so a handful of ticks resolves every timer. ---
    root.navigateForTesting("auroraweb:timer");
    driver.paint();
    Thread.sleep(30.msecs);
    check("timer page loaded", root.currentUrlForTesting() == "auroraweb:timer");
    for (int i = 0; i < 4; ++i)
    {
        root.tickTree(0.02);
        driver.paint();
    }
    auto timerView = root.activeViewForTesting();
    string timerText = (timerView !is null && timerView.page() !is null &&
        timerView.page().root() !is null)
        ? timerView.page().root().textContent() : "";
    check("setTimeout fired", timerText.indexOf("timeout fired") >= 0);
    check("setInterval ran then cleared",
        timerText.indexOf("interval ticks: 3") >= 0);
    check("requestAnimationFrame chain ran",
        timerText.indexOf("raf frames: 3") >= 0);

    // Bookmarks: toggle the current page (auroraweb:js) and verify the bar.
    root.navigateForTesting("auroraweb:hello");
    driver.paint();
    Thread.sleep(50.msecs);
    auto bookmarkBtn = cast(Button) findById(root, "br-bookmark");
    check("bookmark button present", bookmarkBtn !is null);
    if (bookmarkBtn !is null) bookmarkBtn.onClick();
    root.tickTree(0.02);
    check("bookmarked current URL",
        root.isBookmarkedForTesting("auroraweb:hello"));
    check("bookmarks list has one entry",
        root.bookmarksForTesting().length == 1);
    // Toggle again removes it.
    bookmarkBtn.onClick();
    root.tickTree(0.02);
    check("unbookmark removes entry",
        root.bookmarksForTesting().length == 0);

    // --- Loading indicator / busy state ---
    // Loads are synchronous in this engine, so the busy flag flips on and off
    // around a load. We verify the accessor is wired up and the reload button
    // exists in the toolbar.
    auto reloadBtn = cast(Button) findById(root, "br-reload");
    check("reload button present", reloadBtn !is null);
    check("not loading after settle", !root.isLoadingForTesting());
    root.navigateForTesting("auroraweb:hello");
    driver.paint();
    Thread.sleep(50.msecs);
    check("not loading after navigate", !root.isLoadingForTesting());
    check("status mentions loaded",
        root.statusTextForTesting().indexOf("Loaded") >= 0);

    // --- Homepage setting + Home button + Ctrl+H ---
    auto homeBtn = cast(Button) findById(root, "br-home");
    check("home button present", homeBtn !is null);
    check("default home is auroraweb:hello",
        root.homeUrlForTesting() == "auroraweb:hello");
    // Set a custom home and verify it persists in-memory.
    root.navigateForTesting("auroraweb:links");
    driver.paint();
    Thread.sleep(50.msecs);
    root.setHomeForTesting("auroraweb:css");
    check("home updated in memory",
        root.homeUrlForTesting() == "auroraweb:css");
    // Home button navigates to the configured home.
    if (homeBtn !is null) homeBtn.onClick();
    root.tickTree(0.02);
    driver.paint();
    Thread.sleep(50.msecs);
    check("home button navigates to configured home",
        root.currentUrlForTesting() == "auroraweb:css");
    // Ctrl+H navigates home from a different page.
    root.navigateForTesting("auroraweb:js");
    driver.paint();
    Thread.sleep(50.msecs);
    driver.pressKey(Key.h, cast(uint) KeyModifier.control);
    root.tickTree(0.02);
    driver.paint();
    Thread.sleep(50.msecs);
    check("Ctrl+H navigates home",
        root.currentUrlForTesting() == "auroraweb:css");
    // Restore the default home so later runs start at hello.
    root.setHomeForTesting("auroraweb:hello");

    // --- Better error page with Retry link ---
    root.navigateForTesting("auroraweb:nonexistent");
    driver.paint();
    Thread.sleep(50.msecs);
    auto errView = root.activeViewForTesting();
    check("error view present", errView !is null);
    if (errView !is null)
    {
        check("error page shows pink background", errView.showsErrorPage());
        check("error page detected as failed", errView.failedUrlForTesting().length > 0);
        // The error page's Retry <a href> links back to the failed URL. Locate
        // the anchor in the DOM and verify hitTestLink resolves it.
        Element retryLink = null;
        void findRetry(Element e)
        {
            if (retryLink !is null) return;
            if (e.tag == "a" && e.hasId("retry")) { retryLink = e; return; }
            foreach (c; e.elements) findRetry(c);
        }
        findRetry(errView.page().root());
        check("retry link element found", retryLink !is null);
        if (retryLink !is null)
        {
            check("retry link box has positive size",
                retryLink.box.width > 0 && retryLink.box.height > 0);
            auto rcx = retryLink.box.x + retryLink.box.width / 2;
            auto rcy = retryLink.box.y + retryLink.box.height / 2;
            check("hitTestLink finds retry anchor",
                errView.hitTestLink(rcx, rcy).length > 0);
        }
    }

    // --- Per-tab history: error navigation must NOT grow history ---
    root.navigateForTesting("auroraweb:hello");
    driver.paint();
    Thread.sleep(50.msecs);
    const historyBefore = root.historyForTesting().length;
    root.navigateForTesting("auroraweb:error404");
    driver.paint();
    Thread.sleep(50.msecs);
    check("error404 page shown as error", root.activeViewForTesting().showsErrorPage());
    check("history did not grow on 404",
        root.historyForTesting().length == historyBefore);
    check("history still ends at previous page",
        root.currentUrlForTesting() == "auroraweb:hello");

    // --- Real remote title: auroraweb:remote mimics a fetched page ---
    root.navigateForTesting("auroraweb:remote");
    driver.paint();
    Thread.sleep(50.msecs);
    check("navigated to auroraweb:remote",
        root.currentUrlForTesting() == "auroraweb:remote");
    check("remote page title extracted", root.tabTitleForTesting() == "Remote");
    const tabLabel = root.tabStripLabelForTesting();
    check("tab strip label contains remote title",
        tabLabel.indexOf("Remote") >= 0);
    // Retry on a real failure: navigate to a remote page that fails, then use
    // the Retry link semantics (re-navigate to the previous URL).
    root.navigateForTesting("auroraweb:nonexistent");
    driver.paint();
    Thread.sleep(50.msecs);
    check("failed URL recorded", root.activeViewForTesting().failedUrlForTesting().length > 0);
    const historyAtError = root.historyForTesting().length;
    // The Retry link re-navigates to the failed URL — which fails again, so
    // history must not grow.
    root.navigateForTesting(root.activeViewForTesting().failedUrlForTesting());
    driver.paint();
    Thread.sleep(50.msecs);
    check("retry re-navigation stays on error",
        root.activeViewForTesting().showsErrorPage());
    check("retry re-navigation does not pollute history",
        root.historyForTesting().length == historyAtError);

    // --- Scrolling: a tall page should scroll with the wheel and stay clamped. ---
    root.navigateForTesting("auroraweb:scroll");
    driver.paint();
    Thread.sleep(50.msecs);
    auto view = root.activeViewForTesting();
    check("active view present", view !is null);
    if (view !is null)
    {
        driver.wheel(Point(400, 300), -120);
        root.tickTree(0.02);
        driver.paint();
        Thread.sleep(50.msecs);
        check("wheel scrolls page", view.scrollYForTesting() > 0);
        driver.wheel(Point(400, 300), 2000);
        root.tickTree(0.02);
        driver.paint();
        check("scroll clamps at top", view.scrollYForTesting() == 0);
    }

    // --- Performance invariants (engine caching): repainting an unchanged page
    // must not re-run layout, and must serve every text shape from the cache.
    // These lock in the rendering-performance work against regressions. ---
    if (view !is null && view.page() !is null)
    {
        import auroraweb.shaping : shapeShapingCount;
        const genBefore = view.page().layoutGeneration();
        const shapesBefore = shapeShapingCount();
        foreach (i; 0 .. 3)
            driver.paint();
        check("idle repaint does not re-layout",
            view.page().layoutGeneration() == genBefore);
        check("idle repaint reuses shaped text",
            shapeShapingCount() == shapesBefore);
    }

    // Links: auroraweb:links has <a href> elements; hit-test their laid-out
    // boxes (the anchor box center maps to the element's href).
    root.navigateForTesting("auroraweb:links");
    driver.paint();
    Thread.sleep(50.msecs);
    check("navigated to auroraweb:links",
        root.currentUrlForTesting() == "auroraweb:links");
    check("links page has title", root.tabTitleForTesting() == "Aurora Links");
    auto linksView = root.activeViewForTesting();
    check("links view present", linksView !is null);
    if (linksView !is null)
    {
        Element homeLink = null;
        void findLink(Element e)
        {
            if (homeLink !is null) return;
            if (e.hasId("home")) { homeLink = e; return; }
            foreach (c; e.elements) findLink(c);
        }
        findLink(linksView.page().root());
        check("home link element found", homeLink !is null);
        if (homeLink !is null)
        {
            const cx = homeLink.box.x + homeLink.box.width / 2;
            const cy = homeLink.box.y + homeLink.box.height / 2;
            check("home link box has positive size",
                homeLink.box.width > 0 && homeLink.box.height > 0);
            check("hitTestLink returns home href",
                linksView.hitTestLink(cx, cy) == "auroraweb:hello");
            check("hitTestLink misses off-link point",
                linksView.hitTestLink(cx + homeLink.box.width + 40, cy) == "");
            // Clicking the link should navigate to auroraweb:hello. The click
            // position must be the anchor's center in window coordinates.
            auto global = linksView.localToGlobal(Point(cx, cy));
            driver.click(global);
            root.tickTree(0.02);
            driver.paint();
            Thread.sleep(50.msecs);
            check("clicking home link navigates",
                root.currentUrlForTesting() == "auroraweb:hello");
        }
    }

    // --- Interactivity: real click / hover / typing routed through the view ---
    root.navigateForTesting("auroraweb:interact");
    driver.paint();
    Thread.sleep(50.msecs);
    check("interact page loaded", root.currentUrlForTesting() == "auroraweb:interact");
    auto interactView = root.activeViewForTesting();
    check("interact view present", interactView !is null);
    if (interactView !is null && interactView.page() !is null)
    {
        auto pageRoot = interactView.page().root();
        Element findEl(Element e, string id)
        {
            auto it = "id" in e.attrs;
            if (it !is null && *it == id) return e;
            foreach (c; e.elements)
            {
                auto r = findEl(c, id);
                if (r !is null) return r;
            }
            return null;
        }
        Element btn = findEl(pageRoot, "btn");
        Element outEl = findEl(pageRoot, "out");
        Element field = findEl(pageRoot, "field");
        check("interact controls present",
            btn !is null && outEl !is null && field !is null);
        if (btn !is null && outEl !is null && field !is null)
        {
            // Inline content must keep document order relative to a following
            // block (a block must never jump above an earlier inline-block).
            check("inline-block keeps document order before a block",
                btn.box.y + btn.box.height <= outEl.box.y);

            // Hover: a real pointer move applies `:hover` to the element.
            auto btnLocal = Point(btn.box.x + btn.box.width / 2, btn.box.y + 2);
            driver.moveTo(interactView.localToGlobal(btnLocal));
            root.tickTree(0.02);
            check("real pointer move sets :hover",
                interactView.page().hoveredElement() is btn);
            check("real pointer move ran the page's onmouseenter",
                ("entered" in btn.attrs) !is null);
            // The computed style is refreshed by a layout, which paint drives.
            driver.paint();
            check(":hover styling applied", btn.style.fontSizePx == 20);

            // Click: the page's inline onclick handler runs.
            driver.click(interactView.localToGlobal(btnLocal));
            root.tickTree(0.02);
            driver.paint();
            Thread.sleep(30.msecs);
            check("click ran the inline onclick",
                outEl.textContent().indexOf("clicked") >= 0);

            // Focus + typing into the input.
            auto fieldLocal = Point(field.box.x + 4, field.box.y + 4);
            driver.click(interactView.localToGlobal(fieldLocal));
            root.tickTree(0.02);
            check("click focuses the input",
                interactView.page().focusedElement() is field);
            driver.text("Hi"d);
            root.tickTree(0.02);
            // The field starts pre-filled ("type here"), so typed text appends.
            check("typing reaches the input",
                field.attrs.get("value", "").indexOf("Hi") >= 0);

            // Tab moves focus to the next control: the window now offers Tab to
            // the focused widget first, so the page view consumes it.
            auto field2 = findEl(pageRoot, "field2");
            check("second interact field present", field2 !is null);
            driver.keyDown(Key.tab);
            driver.keyUp(Key.tab);
            root.tickTree(0.02);
            check("Tab moves focus to the next page control",
                field2 !is null && interactView.page().focusedElement() is field2);

            // A real wheel gesture reaches the page's `onwheel` handler.
            driver.wheel(interactView.localToGlobal(btnLocal), -120);
            root.tickTree(0.02);
            check("real wheel ran the page's onwheel",
                ("wheeled" in btn.attrs) !is null);


            // Double click and right click reach the page's handlers.
            // (The wheel check above scrolled the page, so rewind first: the
            // click checks must hit the button where it was measured.)
            driver.wheel(interactView.localToGlobal(btnLocal), 480);
            root.tickTree(0.02);
            driver.doubleClick(interactView.localToGlobal(btnLocal));
            root.tickTree(0.02);
            check("real double click ran the page's ondblclick",
                ("dbl" in btn.attrs) !is null);
            driver.rightClick(interactView.localToGlobal(btnLocal));
            root.tickTree(0.02);
            check("real right click ran the page's oncontextmenu",
                ("menu" in btn.attrs) !is null);

            // A page scroll listener fires when the view scrolls. This is last
            // because it changes the scroll position the click checks used.
            interactView.page().runScript(
                `window.addEventListener('scroll', function(){` ~
                `document.getElementById('btn').setAttribute('scrolled','1'); });`);
            driver.wheel(interactView.localToGlobal(btnLocal), -120);
            root.tickTree(0.02);
            check("page scroll listener ran on a real wheel",
                ("scrolled" in btn.attrs) !is null);
        }
    }

    // --- --url CLI arg: opening a URL in the first tab at startup ---
    // (openUrlAtStartup is what app.d calls for `--url <target>`.)
    root.openUrlAtStartup("auroraweb:links");
    driver.paint();
    Thread.sleep(50.msecs);
    check("--url opens target in first tab",
        root.currentUrlForTesting() == "auroraweb:links");

    // --- Latest window-shell chrome: frameless titlebar + overlays. ---
    auto bar = root.titleBarForTesting();
    check("frameless titlebar present", bar !is null);
    if (bar !is null)
    {
        check("titlebar height applied", bar.barHeight() == 32);
        check("titlebar carries the browser icon",
            bar.iconKind() == IconKind.computer);
        check("titlebar shows the window title",
            to!string(bar.title()).indexOf("Aurora Browser") >= 0);
    }
    check("snap preview present and input-transparent",
        root.snapPreviewForTesting() !is null &&
        !root.snapPreviewForTesting().enabled());

    // --- Real tab strip: one clickable TabButton per open tab. ---
    auto tabs = root.tabButtonsForTesting();
    check("tab strip has one button per tab",
        tabs.length == root.tabCountForTesting());
    if (tabs.length >= 2)
    {
        check("tab buttons are laid out with positive width",
            tabs[0].bounds().width > 0 && tabs[1].bounds().width > 0);
        // Click the first tab's body: it becomes the active tab.
        const body = tabs[0].localToGlobal(Point(tabs[0].bounds().width / 2,
            tabs[0].bounds().height / 2));
        driver.click(body);
        root.tickTree(0.02);
        driver.paint();   // switching tabs rebuilds the strip; re-lay it out
        check("clicking a tab body activates it",
            root.activeTabForTesting() == 0);
        // Click the second tab's close region: it closes.
        tabs = root.tabButtonsForTesting();
        const before = root.tabCountForTesting();
        if (tabs.length >= 2)
        {
            const region = tabs[1].closeRect();
            const closePoint = tabs[1].localToGlobal(Point(
                region.x + region.width / 2, region.y + region.height / 2));
            driver.click(closePoint);
            root.tickTree(0.02);
            driver.paint();
            check("clicking a tab close button closes it",
                root.tabCountForTesting() == before - 1);
        }
    }

    // --- Dedicated forward icon button. ---
    check("forward button present", findById(root, "br-forward") !is null);

    // --- Light/dark theme toggle is a working component. ---
    auto themeButton = cast(Button) findById(root, "br-theme");
    check("theme toggle present", themeButton !is null);
    if (themeButton !is null)
    {
        import std.file : mkdirRecurse;
        mkdirRecurse("build/headless-smoke");
        const wasDark = root.isDarkForTesting();
        themeButton.onClick();
        root.tickTree(0.02);
        driver.paint();
        check("theme toggle flips dark mode",
            root.isDarkForTesting() != wasDark);
        window.saveScreenshot("build/headless-smoke/browser-dark.ppm");
        themeButton.onClick();
        root.tickTree(0.02);
        driver.paint();
        check("theme toggle flips back",
            root.isDarkForTesting() == wasDark);
        window.saveScreenshot("build/headless-smoke/browser-light.ppm");
    }

    writeln("headless_smoke: ", failures == 0 ? "ALL PASSED" :
        to!string(failures) ~ " FAILURES");
    return failures == 0 ? 0 : 1;
}
