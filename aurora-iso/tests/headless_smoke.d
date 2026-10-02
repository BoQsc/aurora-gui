/**
 * Headless UI smoke test for Aurora ISO.
 *
 * Compile with:
 *   dmd -version=AuroraHeadless -Isource -I../vendor/aurora-d-0.4.5/source -i ^
 *       -ofbuild/headless_smoke.exe tests/headless_smoke.d shell32.lib winhttp.lib
 *
 * It builds a small ISO with the writer, loads it through the real GUI root,
 * drives layout/paint through the headless platform, asserts the browser
 * populated, and writes a screenshot for visual inspection.
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
        options.width = 1280;
        options.height = 900;
        options.renderer = RendererPreference.software;
        auto window = new GuiWindow(options, auroraIsoTheme());
        auto view = new IsoRoot(window);
        window.setRoot(view);
        auto driver = new UiTestDriver(window);
        driver.resize(Size(1280, 900));
        driver.paint();
        view.tickTree(0.02);

        const loaded = view.loadForTesting(isoPath);
        view.tickTree(0.02);
        driver.paint();

        const entries = view.browserCountForTesting();
        stderr.writeln("loaded=", loaded, " entries=", entries,
            " status=", view.statusTextForTesting());
        stderr.writeln("side children=", view.sideChildCountForTesting(),
            " scroll=", view.sideScrollBoundsForTesting(),
            " content=", view.sideContentBoundsForTesting());
        stderr.writeln("section=", view.firstSectionBoundsForTesting(),
            " label=", view.firstSectionChildBoundsForTesting());

        window.saveScreenshot("build/headless_smoke.png");
        window.close();

        const ok = loaded && entries == 3 && view.imageLoadedForTesting();
        stderr.writeln(ok ? "HEADLESS SMOKE PASSED" : "HEADLESS SMOKE FAILED");
        return ok ? 0 : 1;
    }
    else
    {
        stderr.writeln("headless_smoke requires -version=AuroraHeadless");
        return 0;
    }
}
