module history_preservation_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;
import std.string : indexOf;

int main()
{
    const state = absolutePath("history-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:1/v1","apiKey":"fixture","model":"fixture","toolsEnabled":false}`);
    setOpencodeStateDirectoryForTesting(state);
    WindowOptions options;
    options.width = 1000; options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    scope(exit) root.shutdownClient();
    auto driver = new UiTestDriver(window);
    foreach (_; 0 .. 30)
    {
        window.onNativeTick(0.02);
        assert(driver.paint());
        Thread.sleep(5.msecs);
    }
    root.newChatForTesting();
    root.addConversationForTesting(["user", "assistant"], ["prompt", "original answer"]);
    assert(root.prepareRegenerateForTesting());
    assert(root.totalMessageCountForTesting() == 2);
    assert(root.messageContentForTesting(1) == "original answer");
    assert(root.lastBubbleActionForTesting() == "View response");
    root.projectTranscriptForTesting();
    assert(driver.paint());
    assert(root.selectAllMessageTextForTesting(1));
    assert(root.selectedMessageTextForTesting(1).indexOf("original answer") >= 0,
        "Old response vanished before replacement headers");
    assert(root.bubbleVersionForTesting(1) == "1/1");
    assert(root.requestMessagesForTesting().length == 1,
        "Preserved preview leaked into the regeneration request");
    root.cancelStreamForTesting();
    root.persistForTesting();
    root.reloadSessionsForTesting();
    assert(root.lastBubbleActionForTesting() == "View response");
    assert(root.invokeBubbleActionForTesting(1));
    assert(root.lastAssistantContentForTesting() == "original answer");

    assert(root.prepareRegenerateForTesting());
    root.beginStreamForTesting();
    assert(root.bubbleVersionForTesting(1) == "2/2");
    assert(!root.bubbleHiddenForTesting(1), "Empty replacement hid its navigation");
    root.projectTranscriptForTesting();
    assert(driver.paint());
    assert(root.bubbleVersionNavBoundsForTesting(1).width > 0,
        "Replacement version arrows were not rendered before its first token");
    root.streamContentForTesting("partial replacement");
    root.startTurnClockForTesting();
    assert(!root.invokeBubbleVersionNextForTesting(1), "Unavailable next arrow was enabled");
    assert(root.turnBusyForTesting(), "Unavailable next arrow stopped generation");
    assert(root.invokeBubbleVersionPrevForTesting(1));
    assert(root.lastAssistantContentForTesting() == "original answer");
    assert(root.messageContentForTesting(2) == "partial replacement");
    assert(root.invokeBubbleVersionNextForTesting(1));
    assert(root.lastAssistantContentForTesting() == "partial replacement");
    assert(root.totalMessageCountForTesting() == 3);
    root.persistForTesting();
    root.reloadSessionsForTesting();
    assert(root.bubbleVersionForTesting(1) == "2/2");
    assert(root.invokeBubbleVersionPrevForTesting(1));
    assert(root.lastAssistantContentForTesting() == "original answer");
    assert(root.invokeBubbleVersionNextForTesting(1));
    assert(root.lastAssistantContentForTesting() == "partial replacement");

    assert(root.prepareRegenerateForTesting());
    root.failAssistantMessageForTesting("fixture failure before headers");
    assert(root.bubbleVersionForTesting(1) == "3/3");
    assert(root.totalMessageCountForTesting() == 4);
    assert(root.invokeBubbleVersionPrevForTesting(1));
    assert(root.lastAssistantContentForTesting() == "partial replacement");
    assert(root.invokeBubbleVersionPrevForTesting(1));
    assert(root.lastAssistantContentForTesting() == "original answer");
    root.addConversationForTesting(["user", "assistant"], ["follow-up", "original continuation"]);
    assert(root.invokeBubbleVersionNextForTesting(1));
    assert(root.lastAssistantContentForTesting() == "partial replacement");
    assert(root.invokeBubbleVersionPrevForTesting(1));
    assert(root.lastAssistantContentForTesting() == "original continuation",
        "Switching versions discarded the old response's continuation");
    assert(root.totalMessageCountForTesting() == 6);
    root.persistForTesting();
    root.reloadSessionsForTesting();
    assert(root.totalMessageCountForTesting() == 6);
    assert(root.lastAssistantContentForTesting() == "original continuation");
    writeln("PASS pre-header preview, empty/live navigation, bounded arrows, partial cancellation, failed retry and all branches/continuations after reload");
    return 0;
}
