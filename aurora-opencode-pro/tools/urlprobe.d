module urlprobe;

// Live-URL probe: load a URL through the engine's own fetch path and write the
// page content (no browser chrome) as a PPM, for comparison against Edge.
//
// With an optional flip URL it performs TWO loads in one process, asking the
// server to change what it serves in between. It writes the first load's render
// to "<out>.first.ppm" and the second load's render to "<out>", so a
// resource-cache decision (does the second load reuse the first load's bytes,
// or refetch them?) is visible by comparing the two files. Comparing loads
// inside one process avoids depending on server state left by an earlier run.

import auroraweb : WebPage;
import aurora.surface : Surface;
import aurora.color : Color;
import std.conv : to;
import std.stdio : writeln;

private void render(WebPage page, int width, int height, string path)
{
    auto surface = new Surface(width, height);
    surface.clear(Color.rgb(255, 255, 255));
    page.paint(surface);
    surface.savePpm(path);
}

int main(string[] args)
{
    // The runner duplicates argv[0]: the program path arrives as both args[0]
    // and args[1]. Strip every leading repeat before reading positionals.
    while (args.length >= 2 && args[1] == args[0])
        args = args[1 .. $];
    assert(args.length == 5 || args.length == 6,
        "usage: urlprobe <url> <width> <height> <out.ppm> [flipUrl]");
    const url = args[1];
    const width = to!int(args[2]);
    const height = to!int(args[3]);
    const outPath = args[4];
    auto page = new WebPage(width, height);
    page.navigate(url);            // first load: may populate the resource cache
    page.executeScripts();
    page.layout();
    render(page, width, height, outPath ~ ".first.ppm");
    if (args.length == 6)
        page.navigate(args[5]);    // ask the server to change what it serves
    page.navigate(url);            // second load: reuse or refetch the subresources
    page.executeScripts();
    page.layout();
    render(page, width, height, outPath);
    writeln("captured ", url);
    return 0;
}
