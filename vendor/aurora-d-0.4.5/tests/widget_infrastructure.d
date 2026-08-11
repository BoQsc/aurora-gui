module tests.widget_infrastructure;

import aurora;
import std.stdio : writeln;

private final class TallContent : Widget
{
    this()
    {
        layoutHints().preferredWidth = 200;
        layoutHints().preferredHeight = 800;
    }
}

private final class RichDropTarget : Widget
{
    DragPayload received;
    int enters;
    int moves;
    int leaves;
    int drops;

    override bool onDragEnter(ref Event event)
    {
        ++enters;
        if (allowsDragAction(event.allowedDragActions, DragAction.move))
            event.dragAction = DragAction.move;
        return true;
    }

    override bool onDragMove(ref Event event)
    {
        ++moves;
        event.dragAction = preferredDragAction(event.allowedDragActions,
            DragAction.move);
        return true;
    }

    override void onDragLeave(ref Event)
    {
        ++leaves;
    }

    override bool onDrop(ref Event event)
    {
        ++drops;
        received = event.dragPayload.duplicate();
        event.dragAction = preferredDragAction(event.allowedDragActions,
            DragAction.move);
        return true;
    }
}

private GuiWindow makeWindow(int width = 260, int height = 180)
{
    WindowOptions options;
    options.width = width;
    options.height = height;
    options.renderer = RendererPreference.software;
    return new GuiWindow(options);
}

private void testUnifiedScrollControls()
{
    auto window = makeWindow();
    auto driver = new UiTestDriver(window);

    auto scrollView = new ScrollView(new TallContent());
    window.setRoot(scrollView);
    driver.resize(Size(260, 180));
    driver.paint();
    assert(scrollView.verticalScrollbar().visible());
    driver.wheel(Point(40, 40), -3);
    assert(scrollView.scrollY() == 42);
    assert(scrollView.verticalScrollbar().value() == scrollView.scrollY());

    auto list = new ListView();
    string[] rows;
    foreach (index; 0 .. 80) rows ~= "Row";
    list.setStrings(rows);
    window.setRoot(list);
    driver.resize(Size(260, 180));
    driver.paint();
    assert(list.verticalScrollbar().visible());
    driver.wheel(Point(40, 40), -3);
    assert(list.scrollOffset() == list.rowHeight());
    assert(list.verticalScrollbar().value() == list.scrollOffset());

    string text;
    foreach (index; 0 .. 80) text ~= "A line of editable text\n";
    auto editor = new TextArea(text);
    editor.setCursorIndex(0);
    window.setRoot(editor);
    driver.resize(Size(260, 180));
    driver.paint();
    assert(editor.verticalScrollbar().visible());
    driver.wheel(Point(40, 40), -3);
    assert(editor.verticalScrollbar().value() == 3);

    Event nativePosition;
    nativePosition.type = EventType.mouseWheel;
    nativePosition.globalPosition = Point(40, 40);
    nativePosition.hasVerticalScrollPosition = true;
    nativePosition.verticalScrollPosition = 12;
    window.onNativeEvent(nativePosition);
    assert(editor.verticalScrollbar().value() == 12);
}

private void testRichDragDispatch()
{
    auto window = makeWindow();
    auto target = new RichDropTarget();
    window.setRoot(target);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(260, 180));

    DragPayload payload;
    payload.paths = ["C:\\example.txt"];
    payload.text = "Unicode ✓"d;
    payload.uris = ["https://example.com"];
    payload.formats ~= DragFormat("application/x-aurora-contract",
        cast(const(ubyte)[]) "payload");
    const allowed = dragActions(DragAction.copy, DragAction.move);

    assert(driver.dragEnter(Point(30, 30), payload, allowed) == DragAction.move);
    assert(driver.dragMove(Point(40, 40), payload, allowed) == DragAction.move);
    assert(driver.drop(Point(50, 50), payload, allowed) == DragAction.move);
    assert(target.enters == 1);
    assert(target.moves == 1);
    assert(target.drops == 1);
    assert(target.leaves == 1);
    assert(target.received.paths == payload.paths);
    assert(target.received.text == payload.text);
    assert(target.received.uris == payload.uris);
    assert(target.received.formatData("application/x-aurora-contract") ==
        cast(const(ubyte)[]) "payload");
}

void main()
{
    testUnifiedScrollControls();
    testRichDragDispatch();
    writeln("Unified scrolling and rich drag/drop contracts passed.");
}
