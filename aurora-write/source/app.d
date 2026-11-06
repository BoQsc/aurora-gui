module app;

import aurora;
import aurorawrite.concision : analyzeInstant, wordCount;
import aurorawrite.llmclient : RefinementRequest, refinementSupported, refine;
import aurorawrite.settings : WriteSettings, loadSettings;
import aurorawrite.theme : writeTheme;
import aurorawrite.titlebar : WriteTitleBar;
import aurorawrite.writeroot : WriteRoot;
import std.file : write;
import std.format : format;
import std.string : indexOf;
import std.utf : toUTF32;

/// A paragraph with several real wordiness findings, for the screenshot mode.
private immutable string demoParagraph =
    "Good writing is plain. We utilize a short checklist in order to keep " ~
    "each paragraph tight, and we demonstrate the point with numbers rather " ~
    "than adjectives. The end result is a draft that reads faster and says " ~
    "exactly what it means.";

private string describeRoot(WriteRoot root)
{
    auto card = root.card();
    auto settings = root.settings();
    auto report = format("card open: %s\npanel: %dx%d\nchoices: %d\n",
        card.open(), card.panelSize().width, card.panelSize().height,
        card.choiceCount());
    foreach (index, ref choice; root.analysis.choices)
        report ~= format("  choice %d: '%s' (%d words)\n", index + 1, choice.text,
            choice.words);
    report ~= format("target: '%s'\ndefinition: '%s'\n", root.analysis.target,
        root.analysis.definition);
    report ~= format("status left: %s\nstatus right: %s\n", root.statusLeftText(),
        root.statusRightText());
    report ~= format("provider: %s (%s)\nmodel: %s\n",
        settings.providerOrigin.length ? settings.providerOrigin : "none",
        settings.baseUrl, settings.model);
    return report;
}

private int runScreenshot(string outputPath)
{
    WindowOptions options;
    options.title = "Aurora Write";
    options.width = 1120;
    options.height = 760;
    options.decorated = false;
    options.darkTitleBar = false;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, writeTheme(false));
    auto root = new WriteRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));

    root.setDocumentText(demoParagraph);
    const at = demoParagraph.indexOf("utilize");
    if (at >= 0) root.editor().setCursorIndex(cast(size_t) at + 3);
    root.refreshSuggestions();

    driver.paint();
    window.saveScreenshot(outputPath);
    write(outputPath ~ ".txt", describeRoot(root));
    window.close();
    return 0;
}

/// Ask the configured provider for one refinement and record what happened.
private int runProbe(string sentence, string target, string reportPath)
{
    auto settings = loadSettings();
    const document = sentence.toUTF32;
    const at = sentence.indexOf(target);
    const caret = at >= 0 ? cast(size_t) at + target.length : document.length;
    auto analysis = analyzeInstant(document, caret);

    auto report = format("provider: %s\nbase url: %s\nmodel: %s\nthinking: %s\n",
        settings.providerOrigin.length ? settings.providerOrigin : "none",
        settings.baseUrl, settings.model, settings.thinking);
    report ~= format("instant target: '%s' (%d words)\n", analysis.target,
        wordCount(analysis.target));
    foreach (index, ref choice; analysis.choices)
        report ~= format("  instant %d: '%s' (%d words)\n", index + 1,
            choice.text, choice.words);

    RefinementRequest request;
    request.baseUrl = settings.baseUrl;
    request.apiKey = settings.apiKey;
    request.model = settings.model;
    request.thinking = settings.thinking;
    request.sentence = sentence;
    request.target = analysis.target;
    request.instantDefinition = analysis.definition;
    request.instantChoices = analysis.choices;

    const result = refine(request);
    report ~= format("model ok: %s\nmodel error: '%s'\nmodel ms: %d\n",
        result.ok, result.error, result.elapsedMs);
    report ~= format("model definition: '%s'\n", result.definition);
    foreach (index, ref choice; result.choices)
        report ~= format("  model %d: '%s' (%d words) — %s\n", index + 1,
            choice.text, choice.words, choice.gloss);
    if (result.raw.length > 0)
        report ~= format("raw answer: %s\n", result.raw);
    try write(reportPath, report);
    catch (Exception error) return 2;
    return result.ok ? 0 : 1;
}

int main(string[] args)
{
    if (args.length >= 3 && args[1] == "--screenshot")
        return runScreenshot(args[2]);
    if (args.length >= 5 && args[1] == "--probe-llm")
        return runProbe(args[2], args[3], args[4]);

    WindowOptions options;
    options.title = "Aurora Write";
    options.width = 1120;
    options.height = 760;
    options.resizable = true;
    options.decorated = false;
    options.darkTitleBar = false;
    options.lowLatency = true;
    options.vsync = true;
    options.synchronizedDragPointer = false;
    auto window = new GuiWindow(options, writeTheme(loadSettings().dark));
    window.setRoot(new WriteRoot(window));
    return window.run();
}
