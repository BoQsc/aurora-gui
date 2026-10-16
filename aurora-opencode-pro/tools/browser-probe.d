module browser_probe;

import auroraweb : WebPage;
import auroraweb.dom : Element;
import aurora.surface : Surface;
import aurora.color : Color;
import std.file : readText;
import std.conv : to;
import std.string : endsWith;
import std.stdio : writeln;

Element find(Element element, string id)
{
    if (auto value = "id" in element.attrs) if (*value == id) return element;
    foreach (child; element.elements)
        if (auto result = find(child, id)) return result;
    return null;
}

int main(string[] args)
{
    assert(args.length == 3 || args.length == 5,
        "usage: browser-probe --interaction fixture.html | fixture.html width height output.ppm");
    const interaction = args[1] == "--interaction";
    const width = interaction ? 320 : to!int(args[2]);
    const height = interaction ? 240 : to!int(args[3]);
    assert(width > 0 && width <= 4096 && height > 0 && height <= 4096);
    auto page = new WebPage(width, height);
    page.setHtml(readText(interaction ? args[2] : args[1]));
    page.executeScripts();
    page.layout();
    if (interaction)
    {
        page.click(20,20);
        const button = find(page.root(),"button");
        assert(button !is null && "data-clicked" in button.attrs && button.attrs["data-clicked"] == "yes",
            "Click did not hit the specified button and dispatch its DOM handler");
        assert(page.click(20,70).endsWith("#target"), "Link hit-testing did not produce the specified destination");
        writeln("PASS independent click-handler and link-destination assertions");
        return 0;
    }
    auto surface = new Surface(width,height);
    surface.clear(Color.rgb(255,255,255));
    page.paint(surface);
    surface.savePpm(args[4]);
    writeln("Captured page content at ",width,"x",height);
    return 0;
}
