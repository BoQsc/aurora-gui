module headless_smoke;

/**
 * Headless smoke test for the aurora-browser shell.
 *
 * Runs without a display (software renderer), drives the chrome with the
 * real `UiTestDriver` (typing, Go, back/forward, new tab, Ctrl+T/Ctrl+L),
 * and verifies page content appears in the painted pixels.
 */

import aurora;
import aurorabrowser.appui : BrowserRoot;
import auroraweb.dom : Element;

import core.thread : Thread;
import core.time : msecs;
import std.stdio : writeln;
import std.conv : to;
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
    auto window = new GuiWindow(options, Theme.light());
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

    // Scrolling: a tall page should scroll with the wheel and stay clamped.
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

    writeln("headless_smoke: ", failures == 0 ? "ALL PASSED" :
        to!string(failures) ~ " FAILURES");
    return failures == 0 ? 0 : 1;
}
