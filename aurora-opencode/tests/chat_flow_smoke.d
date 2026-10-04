module auroraopencode_chat_flow_smoke;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import auroraopencode.opencode_client : OpenCodeEvent, OpenCodeEventKind;
import std.file : mkdirRecurse, tempDir, readText;
import std.path : buildPath, dirName;
import std.json : parseJSON;
import std.stdio : writeln;
import std.array : replicate;
import std.datetime : Clock;
import std.conv : to;

private Widget find(Widget root, string id)
{
    if (root.id() == id) return root;
    foreach (child; root.children())
        if (auto result = find(child, id)) return result;
    return null;
}

private void emit(OpenCodeRoot root, ulong request, OpenCodeEventKind kind,
    string text = "", bool reasoning = false, bool cancelled = false)
{
    OpenCodeEvent event;
    event.kind = kind;
    event.requestId = request;
    event.text = text;
    event.reasoning = reasoning;
    event.cancelled = cancelled;
    root.queueEventForTesting(event);
}

int main(string[] args)
{
    const state = buildPath(tempDir(), "aurora-chat-flow-" ~ to!string(Clock.currTime.stdTime));
    mkdirRecurse(state);
    setOpencodeStateDirectoryForTesting(state);
    WindowOptions options;
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window, false);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    assert(driver.paint());
    auto input = cast(TextArea) find(root, "oc-input");
    auto list = cast(ListView) find(root, "oc-sessions");
    auto scroll = cast(ScrollView) find(root, "oc-scroll");
    auto column = cast(VBox) find(root, "oc-messages");
    assert(input.bounds().height >= 70, "Composer has no usable height");

    auto model = cast(Button) find(root, "oc-model");
    auto modelCenter = model.localToGlobal(Point(model.bounds().width / 2, model.bounds().height / 2));
    driver.click(modelCenter);
    root.tickTree(0.02);
    assert(driver.paint() && find(root, "oc-model-picker") !is null);
    driver.click(modelCenter);
    root.tickTree(0.02);
    assert(find(root, "oc-model-picker") is null, "Second click reopened the model picker");

    root.addConversationForTesting(["user"], ["Explain safe streaming"]);
    input.setText("draft A");
    auto request = root.beginRequestForTesting();
    emit(root, request, OpenCodeEventKind.chatBegin);
    foreach (i; 0 .. 1000) emit(root, request, OpenCodeEventKind.delta, "a");
    root.tickTree(0.02);
    assert(root.conversationsForTesting()[0].messages[$ - 1].content == replicate("a", 1000));
    assert(driver.paint());
    auto copy = cast(Button) find(column.children()[0], "oc-copy");
    driver.click(copy.localToGlobal(Point(copy.bounds().width / 2, copy.bounds().height / 2)));
    assert(root.copiedTextForTesting() == "Explain safe streaming");
    input.setText("");
    input.requestFocus();
    driver.pressKey(Key.enter);
    assert((cast(Button) find(root, "oc-send")).text() == "Stop",
        "Blank Enter cancelled the active request");
    input.setText("follow-up");
    driver.pressKey(Key.enter);
    root.tickTree(0.02);
    assert(root.conversationsForTesting()[0].queuedFollowUps == ["follow-up"]);
    input.setText("draft A");

    // Background completion and stale bytes must not affect the selected chat.
    driver.pressKey(Key.n, cast(uint) KeyModifier.control);
    assert(input.textUtf8() == "");
    input.setText("draft B");
    emit(root, request, OpenCodeEventKind.delta, " background");
    emit(root, request, OpenCodeEventKind.done);
    emit(root, request, OpenCodeEventKind.delta, " stale");
    root.tickTree(0.02);
    auto sessions = root.conversationsForTesting();
    assert(sessions.length == 2);
    assert(sessions[0].messages[$ - 1].content == replicate("a", 1000) ~ " background");
    assert(sessions[1].messages.length == 0, "Background reply polluted selected chat");
    assert(input.textUtf8() == "draft B");
    assert(sessions[0].queuedFollowUps == ["follow-up"], "Navigation dropped the queue");
    list.setSelectedIndex(0);
    assert(input.textUtf8() == "draft A");
    list.setSelectedIndex(1);
    assert(input.textUtf8() == "draft B");
    writeln("Background routing, stale events, follow-up queue and per-chat drafts OK");

    // Early rejection must preserve the user's text and measure wrapped errors.
    root.addConversationForTesting(["user"], ["This user message must not change"]);
    request = root.beginRequestForTesting();
    emit(root, request, OpenCodeEventKind.error, replicate("A useful provider error. ", 50));
    root.tickTree(0.02);
    sessions = root.conversationsForTesting();
    assert(sessions[1].messages[0].content == "This user message must not change");
    assert(sessions[1].messages[$ - 1].role == "assistant");
    assert(sessions[1].messages[$ - 1].content == "");
    assert(sessions[1].messages[$ - 1].failed);
    assert(driver.paint());
    assert(column.children()[$ - 1].bounds().height > 100, "Wrapped error was clipped");
    assert(find(root, "oc-retry").visible());
    request = root.beginRequestForTesting();
    emit(root, request, OpenCodeEventKind.delta, "partial failed retry");
    emit(root, request, OpenCodeEventKind.error, "The retry connection was interrupted.");
    root.tickTree(0.02);
    assert(root.retryHistoryEndForTesting() == 1,
        "Repeated retries would send failed attempts back as context");
    writeln("Early failures preserve user text, wrap fully and offer retry");

    // Growing content follows until the reader scrolls away.
    list.setSelectedIndex(0);
    request = root.beginRequestForTesting();
    emit(root, request, OpenCodeEventKind.chatBegin);
    emit(root, request, OpenCodeEventKind.delta, replicate("Working notes.\n", 500), true);
    emit(root, request, OpenCodeEventKind.delta, replicate("Readable answer with enough lines to scroll.\n", 80));
    root.tickTree(0.02);
    assert(driver.paint());
    assert(scroll.maxScroll() > 100 && scroll.scrollY() == scroll.maxScroll(),
        "Growing content disabled auto-follow during layout");
    assert(column.children()[$ - 1].bounds().height < 5000,
        "Collapsed reasoning was still measured in full");
    scroll.setScrollY(scroll.maxScroll() - 180);
    const readerY = scroll.scrollY();
    emit(root, request, OpenCodeEventKind.delta, replicate("More streamed text.\n", 20));
    root.tickTree(0.02);
    assert(driver.paint());
    assert(scroll.scrollY() == readerY, "Streaming pulled the reader back down");
    assert(find(root, "oc-latest").visible());
    emit(root, request, OpenCodeEventKind.done, "", false, true);
    root.tickTree(0.02);
    assert(root.conversationsForTesting()[0].queuedFollowUps == ["follow-up"]);
    writeln("Auto-follow, reader position, collapsed thinking and cancellation OK");

    root.shutdownClient();
    window.close();
    auto saved = parseJSON(readText(buildPath(state, "sessions.json")));
    assert(saved["sessions"][0]["draft"].str == "draft A");
    auto restoredWindow = new GuiWindow(options, opencodeTheme());
    auto restored = new OpenCodeRoot(restoredWindow, false);
    restoredWindow.setRoot(restored);
    auto restoredSessions = restored.conversationsForTesting();
    assert(restoredSessions[0].draft == "draft A" && restoredSessions[1].draft == "draft B");
    assert(restoredSessions[0].queuedFollowUps == ["follow-up"]);
    assert(restoredSessions[1].messages[$ - 1].failed);
    restored.shutdownClient();
    restoredWindow.close();
    writeln("Atomic persistence and restart recovery OK");
    if (args.length > 1)
    {
        foreach (width; [1200, 800])
        {
            options.width = width;
            auto reviewWindow = new GuiWindow(options, opencodeTheme());
            auto review = new OpenCodeRoot(reviewWindow, false);
            reviewWindow.setRoot(review);
            auto reviewDriver = new UiTestDriver(reviewWindow);
            reviewDriver.pressKey(Key.n, cast(uint) KeyModifier.control);
            review.addConversationForTesting(["user"], [
                "How can I make a streaming chat feel more reliable?"]);
            const reviewRequest = review.beginRequestForTesting();
            emit(review, reviewRequest, OpenCodeEventKind.chatBegin);
            emit(review, reviewRequest, OpenCodeEventKind.delta,
                "Consider response ownership, interruption, drafts, and the reader's position.", true);
            emit(review, reviewRequest, OpenCodeEventKind.delta,
                "Keep the conversation predictable while the answer grows.\n\n" ~
                "### A smoother chat\n\n" ~
                "- Preserve drafts when switching conversations.\n" ~
                "- Let readers scroll without jumping back to the latest token.\n" ~
                "- Keep partial answers after interruption and offer a clear retry.\n\n" ~
                "Use **Stop** to interrupt a reply. Send a follow-up while it is running " ~
                "to queue the next question.\n\n" ~
                "```python\nfor chunk in response:\n    update_answer(chunk)\n```\n\n" ~
                "The composer stays available for your next thought.");
            emit(review, reviewRequest, OpenCodeEventKind.done);
            review.tickTree(0.02);
            (cast(TextArea) find(review, "oc-input")).setText("Explain how retry preserves a partial answer.");
            assert(reviewDriver.paint());
            reviewWindow.saveScreenshot(width == 1200 ? args[1] :
                buildPath(dirName(args[1]), "baseline-narrow.ppm"));
            review.shutdownClient();
            reviewWindow.close();
        }
    }
    return 0;
}
