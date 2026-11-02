module wrapped_code_selection_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : Settings, saveSettings, setOpencodeStateDirectoryForTesting, opencodeTheme;
import auroraopencode.markdown : composeMarkdown, parseMarkdown, MdItemKind;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.array : replicate;
import std.file : mkdirRecurse;
import std.path : absolutePath;
import std.stdio : writeln;
import std.utf : toUTF32;
import std.conv : to;
import std.string : indexOf;

int main()
{
    const state = absolutePath("wrapped-selection-state");
    mkdirRecurse(state); setOpencodeStateDirectoryForTesting(state);
    Settings settings; settings.baseUrl = "http://127.0.0.1:9";
    settings.toolsEnabled = false; settings.quickTitle = false;
    saveSettings(settings);
    WindowOptions options; options.width = 1000; options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    const ready = MonoTime.currTime + 5.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    { window.onNativeTick(0.01); Thread.sleep(2.msecs); }
    assert(!root.startupPendingForTesting());
    const line = "0123456789abcdef".replicate(90);
    foreach (text; [line, "\n\n" ~ line ~ "\n\n\nlast", "identical\nidentical\nidentical",
        "Á Привіт العربية שָׁלוֹם 世界 🌍 ".replicate(80)])
    {
        root.newChatForTesting();
        const markdown = "```text\n" ~ text ~ "\n```";
        root.addConversationForTesting(["assistant"], [markdown]);
        root.projectTranscriptForTesting();
        root.scrollToForTesting(0);
        assert(driver.paint());
        assert(root.selectAllMessageTextForTesting(0));
        const selected = root.selectedMessageTextForTesting(0);
        assert(selected == text, "Copy changed wrapped code or blank lines: expected " ~
            to!string(text.length) ~ " bytes, got " ~ to!string(selected.length));
        auto composition = composeMarkdown(parseMarkdown(toUTF32(markdown)), 500, false);
        bool panel;
        foreach (item; composition.items) if (item.kind == MdItemKind.panel)
        { assert(to!string(item.codeText) == text, "Code Copy lost leading blank lines"); panel = true; }
        assert(panel);
    }
    root.newChatForTesting();
    root.addConversationForTesting(["assistant"], ["```text\n" ~ line ~ "\n```"]);
    root.projectTranscriptForTesting(); root.scrollToForTesting(0); assert(driver.paint());
    const start = root.messageSelectionRunPointForTesting(0, 0, false);
    const end = root.messageSelectionRunPointForTesting(0, 1, true);
    assert(end.y > start.y && end.x > start.x);
    driver.drag(start, end);
    const selected = root.selectedMessageTextForTesting(0);
    assert(selected.length > 40 && selected.length < line.length / 2 &&
        selected.indexOf('\n') < 0 && line[0 .. selected.length] == selected,
        "Dragging across visual wraps duplicated, clipped or inserted a newline in the logical line");
    assert(driver.paint());
    writeln("PASS exact Select All/code Copy, leading/internal blank lines, repeated lines and real drag across wrapped code");
    return 0;
}
