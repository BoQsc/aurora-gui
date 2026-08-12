module auroraopencode_markdown_probe;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : msecs;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;

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
    const stateDir = buildPath(tempDir(), "aurora-opencode-markdown-probe");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);

    WindowOptions options;
    options.title = "Aurora OpenCode markdown probe";
    options.width = 1200;
    options.height = 900;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    assert(driver.paint(), "Initial paint failed");
    root.tickTree(0.02);

    const markdown =
        "# Streaming markdown\n\n" ~
        "This is a **bold** phrase, an *italic* one, and `inline code`. " ~
        "A [link](https://opencode.ai) is underlined.\n\n" ~
        "- first bullet with **bold** item\n" ~
        "- second bullet\n\n" ~
        "1. ordered one\n" ~
        "2. ordered two\n\n" ~
        "> A quoted line stays indented with a bar.\n\n" ~
        "```d\nimport std.stdio;\nvoid main() { writeln(\"hi\"); }\n```\n\n" ~
        "---\n\n" ~
        "Trailing paragraph after the rule.";

    root.addConversationForTesting(
        ["user", "assistant"],
        ["What does markdown look like?", markdown]);

    assert(driver.paint(), "Markdown paint failed");
    root.tickTree(0.02);
    assert(driver.paint(), "Markdown repaint failed");

    auto messages = cast(VBox) findById(root, "oc-messages");
    assert(messages !is null, "Missing oc-messages");
    assert(messages.children().length == 2, "Expected 2 bubbles");
    writeln("Bubbles: ", messages.children().length);
    foreach (child; messages.children())
    {
        assert(child.bounds().height > 0,
            "Markdown bubble has zero height");
        assert(child.bounds().width > 0,
            "Markdown bubble has zero width");
        writeln("Bubble ", child.bounds());
    }
    writeln("Markdown content length: ",
        root.lastAssistantContentForTesting().length);

    const output = args.length >= 2
        ? args[1]
        : buildPath(tempDir(), "aurora-opencode-markdown.png");
    window.saveScreenshot(output);
    writeln("Screenshot saved to ", output);

    root.shutdownClient();
    window.close();
    writeln("Markdown probe passed.");
    return 0;
}
