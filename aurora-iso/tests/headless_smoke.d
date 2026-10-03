/**
 * Headless UI smoke test for Aurora ISO.
 *
 * Compile with:
 *   dmd -version=AuroraHeadless -Isource -I../vendor/aurora-d-0.4.5/source -i ^
 *       -ofbuild/headless_smoke.exe tests/headless_smoke.d shell32.lib winhttp.lib
 *
 * It builds a small ISO with the writer, loads it through the real GUI root,
 * drives layout/paint through the headless platform, checks the one-button
 * install view and the advanced view, and writes a screenshot.
 */
module auroraiso_headless_smoke;

import aurora;
import auroraiso.appui : IsoRoot;
import auroraiso.iso;
import auroraiso.theme : auroraIsoTheme;
import std.file : exists, mkdirRecurse, rmdirRecurse, write;
import std.path : buildPath;
import std.stdio : stderr;

int main()
{
    version (AuroraHeadless)
    {
        const root = "build/smoke-src";
        if (exists(root))
            rmdirRecurse(root);
        mkdirRecurse(buildPath(root, "docs"));
        mkdirRecurse(buildPath(root, "EFI/BOOT"));
        write(buildPath(root, "README.txt"), "Aurora ISO smoke test\n");
        write(buildPath(root, "docs/guide.txt"), "Guide contents\n");
        write(buildPath(root, "EFI/BOOT/bootx64.efi"), "fake efi payload\n");

        const isoPath = "build/smoke.iso";
        auto result = createIsoFromDirectory(root, isoPath);
        if (!result.ok)
        {
            stderr.writeln("writer failed: ", result.error);
            return 1;
        }

        WindowOptions options;
        options.title = "Aurora ISO";
        options.width = 980;
        options.height = 720;
        options.renderer = RendererPreference.software;
        auto window = new GuiWindow(options, auroraIsoTheme());
        auto view = new IsoRoot(window);
        window.setRoot(view);
        auto driver = new UiTestDriver(window);
        driver.resize(Size(980, 720));
        driver.paint();
        view.tickTree(0.02);

        const loaded = view.loadForTesting(isoPath);
        view.tickTree(0.02);
        driver.paint();

        const entries = view.browserCountForTesting();
        const distroCount = view.distroCountForTesting();
        const deviceCount = view.deviceCountForTesting();
        view.selectDistroForTesting(0);
        const distroUrl = view.downloadUrlForTesting();
        const simpleVisible = !view.advancedVisibleForTesting();
        stderr.writeln("loaded=", loaded, " entries=", entries,
            " distros=", distroCount, " devices=", deviceCount,
            " simple=", simpleVisible);
        stderr.writeln("firstUrl=", distroUrl, " status=", view.statusTextForTesting());

        // Screenshot the compact install view (the default).
        window.saveScreenshot("build/headless_smoke.png");

        // Exercise the advanced toggle.
        view.toggleAdvancedForTesting();
        view.tickTree(0.02);
        driver.paint();
        const advancedShown = view.advancedVisibleForTesting();
        stderr.writeln("advanced now=", advancedShown);
        window.saveScreenshot("build/headless_advanced.png");

        window.close();

        const ok = loaded && entries == 3 && view.imageLoadedForTesting() &&
            distroCount >= 6 && simpleVisible && advancedShown &&
            distroUrl == "https://releases.ubuntu.com/26.04/ubuntu-26.04.1-desktop-amd64.iso";
        stderr.writeln(ok ? "HEADLESS SMOKE PASSED" : "HEADLESS SMOKE FAILED");
        return ok ? 0 : 1;
    }
    else
    {
        stderr.writeln("headless_smoke requires -version=AuroraHeadless");
        return 0;
    }
}
