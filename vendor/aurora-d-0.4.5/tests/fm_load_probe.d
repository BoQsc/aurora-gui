module tests.fm_load_probe;

import aurora;
import std.datetime.stopwatch : StopWatch;
import std.file : exists, getcwd, mkdirRecurse, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : format;

import demos.windows_file_manager : WindowsFileManagerRoot;

int main()
{
    const root = buildPath(getcwd(), "build", "fm-probe-dir");
    if (!exists(root))
    {
        mkdirRecurse(root);
        foreach (i; 0 .. 20000)
            write(buildPath(root, format("item-%05d.txt", i)), "x");
    }

    WindowOptions options;
    options.width = 1100;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());

    StopWatch sw;
    sw.start();
    auto fm = new WindowsFileManagerRoot(window, root);
    window.setRoot(fm);
    writeln("root ctor (incl. enumerate): ", sw.peek().total!"msecs", " ms");

    // Pump ticks as the real loop would.
    sw.reset();
    foreach (_; 0 .. 400)
    {
        window.onNativeTick(0.016);
        window.onNativePaint();
    }
    writeln("400 ticks + paints: ", sw.peek().total!"msecs", " ms");
    return 0;
}
