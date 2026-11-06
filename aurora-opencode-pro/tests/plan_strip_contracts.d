module plan_strip_contracts;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import std.conv : to;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;

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

private T requireWidget(T)(Widget root, string requestedId)
{
    auto widget = cast(T) findById(root, requestedId);
    assert(widget !is null, "Missing or wrong widget type for id: " ~ requestedId);
    return widget;
}

private bool paint(OpenCodeRoot root, UiTestDriver driver)
{
    root.projectTranscriptForTesting();
    return driver.paint();
}

/// A minimal archived task-state snapshot: what taskArchive stores when a new
/// plan replaces the previous one.
private string planSnapshot(string objective, const(string)[] steps)
{
    string json = `{"objective":"` ~ objective ~
        `","taskStatus":"completed","taskSteps":[`;
    foreach (i, step; steps)
    {
        if (i) json ~= ",";
        json ~= `{"text":"` ~ step ~ `","status":"completed"}`;
    }
    return json ~ "]}";
}

int main(string[] args)
{
    const stateDir = buildPath(tempDir(), "aurora-plan-strip-state");
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    setOpencodeStateDirectoryForTesting(stateDir);

    WindowOptions options;
    options.title = "Plan strip contracts";
    options.width = 1200;
    options.height = 800;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    root.tickTree(0.02);
    assert(driver.paint(), "initial app paint failed");

    root.newChatForTesting();
    root.addConversationForTesting(["user"], ["First request"]);
    root.applyPlanForTesting(`{"objective":"Earlier plan","plan":[` ~
        `{"step":"Earlier A","status":"completed"}]}`);
    root.applyPlanForTesting(`{"objective":"Current plan","plan":[` ~
        `{"step":"Current A","status":"in_progress"},` ~
        `{"step":"Current B","status":"pending"}]}`);
    root.setArchivedPlansForTesting([planSnapshot("Earlier plan",
        ["Earlier A"])]);
    assert(paint(root, driver), "plan strip baseline did not paint");

    assert(root.detachedPlanStripCountForTesting() == 2,
        "one rectangle per conversation plan expected, got " ~
        to!string(root.detachedPlanStripCountForTesting()));
    assert(root.detachedPlanPreviewIndexForTesting() == -1,
        "the live plan should render before any hover");
    assert(root.detachedPlanObjectiveForTesting() == "Current plan",
        "live objective missing: " ~ root.detachedPlanObjectiveForTesting());

    const panel = requireWidget!Widget(root, "oc-plan-panel");
    const liveCard = root.detachedPlanRectForTesting();
    const first = root.detachedPlanStripRectForTesting(0);
    assert(first.width > 0 && first.height > 0,
        "history strip rectangle has no area");
    {
        // The rectangles sit on the header row, to the right of the title and
        // above the objective row.
        const objective = root.detachedPlanObjectiveRectForTesting();
        assert(first.y > liveCard.y && first.y < objective.y,
            "the strip is not on the header row");
        assert(first.x > liveCard.x + 60,
            "the strip is not to the right of the header text");
        assert(first.y + first.height <= objective.y,
            "the strip overlaps the objective row");
    }
    const firstX = first.x + first.width / 2;
    const firstY = first.y + first.height / 2;
    // The hit area is exactly the drawn rectangle: the gap beside it must not
    // preview a plan.
    driver.moveTo(Point(4, 700));
    assert(paint(root, driver), "clearing the plan card did not paint");
    driver.moveTo(panel.localToGlobal(Point(first.x - 1, firstY)));
    assert(paint(root, driver), "hovering beside the first rectangle did not paint");
    assert(root.detachedPlanPreviewIndexForTesting() == -1,
        "the hit area extends beyond the drawn rectangle");

    driver.moveTo(Point(4, 700));
    assert(paint(root, driver), "clearing the plan card did not paint");
    driver.moveTo(panel.localToGlobal(Point(firstX, firstY)));
    assert(paint(root, driver), "hovering the strip did not paint");
    assert(!root.detachedPlanHoverExpandedForTesting(),
        "hovering the strip expanded the card");
    assert(root.detachedPlanPreviewIndexForTesting() == 0,
        "hovering the first rectangle did not preview the earlier plan");
    {
        const still = root.detachedPlanStripRectForTesting(0);
        assert(still.x == first.x && still.y == first.y &&
            still.width == first.width,
            "previewing a plan moved the rectangles");
        // The card height follows the shorter previewed plan from the top, so
        // the strip under the title stays put.
        const previewCard = root.detachedPlanRectForTesting();
        assert(previewCard.height < liveCard.height,
            "the card height did not adapt to the shorter previewed plan");
        assert(previewCard.y == liveCard.y,
            "the previewed card moved off the top margin");
        assert(previewCard.y + previewCard.height <
            liveCard.y + liveCard.height,
            "the preview did not shorten the card");
    }
    // The neighbouring rectangle switches plans at its visible edge, without
    // moving the strip under the pointer.
    const second = root.detachedPlanStripRectForTesting(1);
    driver.moveTo(panel.localToGlobal(Point(
        second.x + second.width / 2, second.y + second.height / 2)));
    assert(paint(root, driver), "hovering the current plan rectangle did not paint");
    assert(root.detachedPlanPreviewIndexForTesting() == 1,
        "hovering the current plan rectangle did not preview it");
    assert(root.detachedPlanTitleForTesting().indexOf("  ·  2/2") >= 0,
        "the current plan preview is not labelled: " ~
        root.detachedPlanTitleForTesting());
    {
        const still = root.detachedPlanStripRectForTesting(0);
        assert(still.x == first.x && still.y == first.y,
            "switching plans moved the rectangles");
        const currentCard = root.detachedPlanRectForTesting();
        assert(currentCard.height == liveCard.height,
            "the card did not return to the live plan's height");
    }
    driver.moveTo(panel.localToGlobal(Point(firstX, firstY)));
    assert(paint(root, driver), "returning to the earlier plan did not paint");
    assert(root.detachedPlanPreviewIndexForTesting() == 0,
        "returning to the earlier rectangle did not preview it");
    assert(root.detachedPlanObjectiveForTesting() == "Earlier plan",
        "preview objective is wrong: " ~ root.detachedPlanObjectiveForTesting());
    assert(root.detachedPlanStepCountForTesting() == 1 &&
        root.detachedPlanStepTextForTesting(0) == "Earlier A",
        "preview did not show the earlier plan's steps");
    assert(root.detachedPlanTitleForTesting().indexOf("  ·  1/2") >= 0,
        "preview title does not name the plan: " ~
        root.detachedPlanTitleForTesting());
    // Optional frozen-frame capture for the independent render check.
    if (args.length > 1) window.saveScreenshot(args[1]);

    // Hovering the plan itself keeps the preview open for inspection.
    const card = root.detachedPlanRectForTesting();
    driver.moveTo(panel.localToGlobal(Point(card.x + card.width / 2,
        card.y + 10)));
    assert(paint(root, driver), "moving onto the previewed plan did not paint");
    assert(root.detachedPlanPreviewIndexForTesting() == 0,
        "the preview closed when the pointer moved onto the plan");
    assert(root.detachedPlanObjectiveForTesting() == "Earlier plan",
        "the previewed plan changed while inspecting it");
    assert(!root.detachedPlanHoverExpandedForTesting(),
        "hovering the card title expanded it");

    // Expansion belongs to the clipped text: the objective row and the listed
    // steps. Everything else on the card keeps its resting width.
    driver.moveTo(Point(4, 700));
    assert(paint(root, driver), "clearing the plan card did not paint");
    const objectiveRect = root.detachedPlanObjectiveRectForTesting();
    assert(objectiveRect.width > 0,
        "the objective row has no hover region");
    driver.moveTo(panel.localToGlobal(Point(
        objectiveRect.x + objectiveRect.width / 2,
        objectiveRect.y + objectiveRect.height / 2)));
    assert(paint(root, driver), "hovering the objective did not paint");
    assert(root.detachedPlanHoverExpandedForTesting(),
        "hovering the objective did not expand the card");

    driver.moveTo(Point(4, 700));
    assert(paint(root, driver), "clearing the plan card did not paint");
    assert(!root.detachedPlanHoverExpandedForTesting(),
        "the card stayed expanded after the pointer left it");
    const stepRect = root.detachedPlanStepsRectForTesting();
    assert(stepRect.width > 0 && stepRect.height > 0,
        "the listed steps have no hover region");
    driver.moveTo(panel.localToGlobal(Point(
        stepRect.x + stepRect.width / 2, stepRect.y + 4)));
    assert(paint(root, driver), "hovering the listed steps did not paint");
    assert(root.detachedPlanHoverExpandedForTesting(),
        "hovering the listed steps did not expand the card");

    // Leaving the card returns to the live plan.
    driver.moveTo(Point(4, 700));
    assert(paint(root, driver), "leaving the plan card did not paint");
    assert(root.detachedPlanPreviewIndexForTesting() == -1,
        "the preview survived after the pointer left the card");
    assert(root.detachedPlanObjectiveForTesting() == "Current plan",
        "the live plan did not return: " ~ root.detachedPlanObjectiveForTesting());
    assert(root.detachedPlanStepCountForTesting() == 2,
        "the live plan's steps did not return");

    // The strip is optional, on by default, and off hides it again.
    root.setPlanHistoryStripForTesting(false);
    assert(paint(root, driver), "turning the strip off did not paint");
    assert(root.detachedPlanStripCountForTesting() == 0,
        "the strip stayed visible after being turned off");
    root.setPlanHistoryStripForTesting(true);
    assert(paint(root, driver), "turning the strip back on did not paint");
    assert(root.detachedPlanStripCountForTesting() == 2,
        "the strip did not return after being turned back on");

    // Every plan stays represented while it fits: rectangles shrink instead
    // of dropping plans.
    const(string)[] many;
    foreach (i; 0 .. 11)
        many ~= planSnapshot("Plan " ~ to!string(i + 1),
            ["Step " ~ to!string(i + 1)]);
    root.setArchivedPlansForTesting(many);
    assert(paint(root, driver), "many-plan strip did not paint");
    const expected = 12;
    assert(root.detachedPlanStripCountForTesting() == expected,
        "the strip dropped plans: " ~
        to!string(root.detachedPlanStripCountForTesting()) ~ "/" ~
        to!string(expected));
    const cardRect = root.detachedPlanRectForTesting();
    foreach (i; 0 .. expected)
    {
        const bar = root.detachedPlanStripRectForTesting(i);
        assert(bar.width >= 5,
            "a history rectangle shrank too far: " ~ to!string(bar.width));
        assert(bar.x + bar.width <= cardRect.x + cardRect.width,
            "a history rectangle escaped the card");
    }
    const last = root.detachedPlanStripRectForTesting(expected - 1);
    assert(last.x + last.width <= cardRect.x + cardRect.width,
        "the newest history rectangle is clipped");

    driver.moveTo(Point(4, 700));
    writeln("Plan history strip lists one rectangle per conversation plan");
    return 0;
}
