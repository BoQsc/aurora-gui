module preview_pipeline;

import auroradesigner.model : DesignDocument, NodeKind, generateCode;
import std.array : replace;
import std.file : chdir, exists, getcwd, mkdirRecurse, read, rmdirRecurse,
    thisExePath, write;
import std.path : buildPath, buildNormalizedPath, dirName;
import std.process : execute;
import std.stdio : writeln;
import std.string : representation;
import std.conv : to;

private string wrapPreview(string generated, int width, int height)
{
    return "import aurora;\n\n" ~ generated ~
        "\nvoid main()\n{\n" ~
        "    auto root = buildDesignedUi();\n" ~
        "    WindowOptions options;\n" ~
        "    options.title = \"Aurora generated preview\";\n" ~
        "    options.width = " ~ to!string(width) ~ ";\n" ~
        "    options.height = " ~ to!string(height) ~ ";\n" ~
        "    options.decorated = false;\n" ~
        "    options.renderer = RendererPreference.software;\n" ~
        "    auto window = new GuiWindow(options, Theme.dark());\n" ~
        "    window.setRoot(root);\n" ~
        "    auto driver = new UiTestDriver(window);\n" ~
        "    driver.resize(Size(" ~ to!string(width) ~ ", " ~
            to!string(height) ~ "));\n" ~
        "    driver.paint();\n" ~
        "    window.saveScreenshot(\"preview.ppm\");\n" ~
        "    window.close();\n" ~
        "}\n";
}

/** Compile one generated document and run it in a real window. */
private void buildAndRun(string workDir, string auroraPath, string name,
    string generated, int width, int height)
{
    auto dir = buildPath(workDir, name);
    mkdirRecurse(dir);
    write(buildPath(dir, name ~ ".d"),
        wrapPreview(generated, width, height));
    write(buildPath(dir, "dub.json"),
        "{\n" ~
        "  \"name\": \"aurora-generated-preview\",\n" ~
        "  \"targetType\": \"executable\",\n" ~
        "  \"targetName\": \"" ~ name ~ "\",\n" ~
        "  \"mainSourceFile\": \"" ~ name ~ ".d\",\n" ~
        "  \"dependencies\": {\"aurora-d\": {\"path\": \"" ~
            auroraPath.replace("\\", "/") ~ "\"}},\n" ~
        "  \"libs-windows\": [\"user32\", \"gdi32\"]\n" ~
        "}\n");

    auto previous = getcwd();
    scope (exit) chdir(previous);
    chdir(dir);
    auto built = execute(["dub", "build", "--build=release"]);
    if (built.status != 0)
    {
        writeln(built.output);
        throw new Exception("generated preview failed to compile");
    }
    auto ran = execute([buildPath(dir, name ~ ".exe")]);
    if (ran.status != 0)
    {
        writeln(ran.output);
        throw new Exception("generated preview failed to run");
    }
}

void main()
{
    DesignDocument doc;
    doc.canvasWidth = 900;
    doc.canvasHeight = 560;
    const root = doc.addNode(NodeKind.window, 0, 0);
    const panel = doc.addNode(NodeKind.panel, 40, 40);
    const button = doc.addNode(NodeKind.button, 64, 96);
    doc.root = root;
    doc.nodes[root].children ~= panel;
    doc.nodes[panel].children ~= button;
    doc.nodes[panel].name = "Preview panel";
    doc.nodes[button].id = "preview-action";
    doc.nodes[button].name = "Preview action";
    doc.nodes[button].text = "Generated preview";
    doc.nodes[button].accent = true;

    auto base = getcwd();
    auto work = buildPath(base, "preview_pipeline");
    if (exists(work)) rmdirRecurse(work);
    mkdirRecurse(work);
    auto auroraPath = buildNormalizedPath(base, "..", "aurora-d");

    auto first = generateCode(doc);
    buildAndRun(work, auroraPath, "preview1", first, doc.canvasWidth,
        doc.canvasHeight);
    if (!exists(buildPath(work, "preview1", "preview.ppm")))
        throw new Exception("generated preview produced no screenshot");

    DesignDocument secondDoc = doc;
    secondDoc.nodes = doc.nodes.dup;
    foreach (ref node; secondDoc.nodes)
        node.children = node.children.dup;
    secondDoc.nodes[button].text = "Generated preview v2";
    secondDoc.nodes[button].accent = false;
    auto second = generateCode(secondDoc);
    buildAndRun(work, auroraPath, "preview2", second, doc.canvasWidth,
        doc.canvasHeight);

    auto one = cast(ubyte[]) read(buildPath(work, "preview1", "preview.ppm"));
    auto two = cast(ubyte[]) read(buildPath(work, "preview2", "preview.ppm"));
    if (one == two)
        throw new Exception("generated previews did not differ");

    writeln("PASS generated preview");
    writeln("compiled=", first.length, "/", second.length,
        " bytes; screenshots=", one.length, "/", two.length);
}
