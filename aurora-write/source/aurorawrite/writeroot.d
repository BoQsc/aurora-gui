/**
 * The Aurora Write root: a framed writing column, the caret suggestion card, and
 * the status line that reports what the optimizer is doing.
 *
 * Ordering matters. The instant pass runs on the keystroke (no network); the
 * model pass runs only after the writer pauses, on its own thread, and its
 * answer replaces the instant drafts only while the same span is still under
 * the caret.
 */
module aurorawrite.writeroot;

import aurora;
import aurorawrite.concision : Analysis, analyzeInstant, countWords,
    isWordCharacter, sentenceAround, wordCount;
import aurorawrite.llmclient : RefinementJob, RefinementRequest, RefinementResult,
    refinementSupported;
import aurorawrite.settings : WriteSettings, loadSettings, saveSettings;
import aurorawrite.settingssheet : SettingsSheet;
import aurorawrite.suggestioncard : SuggestionCard;
import aurorawrite.theme : writeTheme;
import aurorawrite.titlebar : WriteTitleBar;
import core.time : Duration, MonoTime, msecs;
import std.datetime : Clock;
import std.file : exists, readText, write;
import std.format : format;
import std.path : baseName;
import std.utf : toUTF32, toUTF8;

/// Logical metrics shared by the root and its tests.
enum int titleBarHeight = 38;
enum int statusBarHeight = 30;
enum int pageInset = 16;
enum int columnMaxWidth = 820;
enum int columnMinWidth = 360;
enum int editorPadding = 40;
/// Typing pause before the model is asked for a better rewrite.
enum int refineDebounceMs = 450;
/// Typing pause used when the analysis already knows the word is finished.
enum int refineImmediateMs = 0;
/// Minimum gap between the cheap wake-up frames that observe deferred work.
private enum double pumpIntervalSeconds = 0.1;

/// TextArea whose keys can be pre-empted by the suggestion card and shortcuts.
final class WritingSurface : TextArea
{
    bool delegate(ref Event event) keyFilter;

    override bool onKeyDown(ref Event event)
    {
        if (keyFilter !is null && keyFilter(event)) return true;
        return super.onKeyDown(event);
    }
}

/// One-pixel theme border, created disabled so it never takes pointer input.
final class WindowBorder : Widget
{
    this()
    {
        setEnabled(false);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        canvas.strokeRect(Rect(0, 0, bounds().width, bounds().height),
            theme().border, 1);
    }
}

final class WriteRoot : Widget
{
    private GuiWindow _window;
    private WriteTitleBar _titleBar;
    private Panel _page;
    private WritingSurface _editor;
    private SuggestionCard _card;
    private Panel _statusBand;
    private Label _statusLeft;
    private Label _statusRight;
    private Separator _statusHairline;
    private SettingsSheet _settingsSheet;
    private WindowBorder _windowBorder;
    private TitleBarSnapPreview _snapPreview;

    private WriteSettings _settings;
    private Analysis _analysis;
    private string _modelStatus;
    private RefinementJob _job;
    private size_t _jobGeneration;
    private size_t _generation;
    private bool _debounceActive;
    private MonoTime _debounceDeadline;
    // `onChanged` and `onCursorMoved` both fire for one keystroke; the analysis
    // only depends on the text window around the caret, so an unchanged
    // signature means there is nothing to recompute.
    private ulong _suggestionSignature;
    private bool _hasSuggestionSignature;
    // Accumulated time between wake-up frames. Initialised: D floats default
    // to NaN, and `NaN >= interval` is always false, silencing the pump.
    private double _pumpElapsed = pumpIntervalSeconds;
    private int _savedWords;
    private string _currentPath;
    private bool _dirty;
    // Diagnostics for the interaction probe; no behaviour depends on these.
    size_t diagnosticRefreshCount;
    size_t diagnosticAnalysisCount;
    size_t diagnosticPumpCount;
    // Focus cannot be requested before the root has a host, so the first layout
    // pass hands the caret to the editor.
    private bool _focusOnFirstLayout = true;

    this(GuiWindow window)
    {
        _window = window;
        _settings = loadSettings();

        _titleBar = add(new WriteTitleBar(window));

        _page = add(new Panel(pageColor()));
        _editor = add(new WritingSurface());
        _editor.setPlaceholder("Start writing…");
        // Prose is set in the UI face, not the monospace role the widget
        // defaults to for code-like text.
        _editor.setFontFace(null, FontRole.ui);
        _editor.setWordWrap(true);
        _editor.setShowBorder(false);
        _editor.setFocusDecoration(false);
        _editor.setTransparentBackground(true);
        _editor.setPixelSizeOverride(19);
        _editor.setPadding(editorPadding);
        _editor.onChanged = delegate() { edited(); };
        _editor.onCursorMoved = delegate() { refreshSuggestions(); };
        _editor.keyFilter = delegate(ref Event event) { return filterEditorKey(event); };

        _card = add(new SuggestionCard());
        _card.onApply = delegate(int index) { applyChoice(index); };

        _statusBand = add(new Panel(statusBandColor()));
        _statusLeft = _statusBand.add(new Label(""));
        _statusLeft.setPixelSize(12);
        _statusRight = _statusBand.add(new Label(""));
        _statusRight.setPixelSize(12);
        _statusRight.setAlignment(HorizontalAlign.right);
        _statusHairline = add(new Separator(Orientation.horizontal));

        _settingsSheet = add(new SettingsSheet());
        _settingsSheet.onSave = delegate() { saveProviderSettings(); };
        _settingsSheet.onCancel = delegate() { hideSettings(); };

        _snapPreview = add(new TitleBarSnapPreview());
        _titleBar.setSnapPreview(_snapPreview);
        _windowBorder = add(new WindowBorder());

        applyTheme();
        updateStatus();
    }

    // --- Accessors (also used by the headless smoke test) ----------------

    WriteTitleBar titleBar() @safe pure nothrow @nogc { return _titleBar; }
    WritingSurface editor() @safe pure nothrow @nogc { return _editor; }
    SuggestionCard card() @safe pure nothrow @nogc { return _card; }
    SettingsSheet settingsSheet() @safe pure nothrow @nogc
    {
        return _settingsSheet;
    }
    WriteSettings settings() const @safe pure nothrow @nogc { return _settings; }
    string statusLeftText()
    {
        return toUTF8(_statusLeft.text);
    }
    string statusRightText()
    {
        return toUTF8(_statusRight.text);
    }
    int savedWords() const @safe pure nothrow @nogc { return _savedWords; }
    bool cardOpen() @safe pure nothrow @nogc { return _card.open(); }
    const(Analysis)* analysis() @safe pure nothrow @nogc { return &_analysis; }

    /// Load a whole document (screenshot mode, tests).
    void setDocumentText(string text)
    {
        _editor.setText(text, false);
        _editor.setCursorIndex(text.length > 0 ? text.length - 1 : 0);
        refreshSuggestions(true);
    }

    // --- Optimizer -------------------------------------------------------

    private void edited()
    {
        _dirty = true;
        refreshSuggestions();
    }

    /// Recompute the instant pass for the word at the caret, then queue a model
    /// pass when the writer pauses.
    void refreshSuggestions(bool force = false)
    {
        const text = _editor.textView;
        const caret = _editor.cursorIndex();
        const signature = suggestionSignature(text, caret);
        if (!force && _hasSuggestionSignature && signature == _suggestionSignature)
            return;
        _suggestionSignature = signature;
        _hasSuggestionSignature = true;
        ++diagnosticRefreshCount;
        // Any edit or caret move retires an answer that is already in flight.
        ++_generation;

        if (!_settings.optimizer)
        {
            _card.dismiss();
            updateStatus();
            return;
        }

        ++diagnosticAnalysisCount;
        _analysis = analyzeInstant(text, caret);

        if (_analysis.valid())
        {
            _card.present(_analysis, _modelStatus.length > 0 ? _modelStatus
                : "Instant");
            anchorCard();
        }
        else
        {
            _card.dismiss();
        }
        scheduleRefinement();
        updateStatus();
    }

    /// Hash of everything the instant pass can read, plus the caret and length.
    private static ulong suggestionSignature(const(dchar)[] text, size_t caret)
        @safe pure nothrow @nogc
    {
        enum window = 240; // the analyzer's own reach around the caret
        const start = caret > window ? caret - window : 0;
        const finish = text.length < caret + window ? text.length : caret + window;
        ulong hash = 1469598103934665603UL;
        foreach (value; text[start .. finish])
        {
            hash ^= cast(ulong) value;
            hash *= 1099511628211UL;
        }
        return hash ^ (cast(ulong) caret << 3) ^ (cast(ulong) text.length << 37);
    }

    private void scheduleRefinement()
    {
        _debounceActive = false;
        if (!_analysis.hasSpan()) return;
        if (_settings.offline) return;
        if (!_settings.configured() || !refinementSupported()) return;
        // One request at a time: a newer pause supersedes the running job when
        // its answer arrives, so typing cannot open a request pile-up.
        if (_job !is null) return;
        // A word that is already closed ("utilize ") needs no pause: the writer
        // has moved on, so ask straight away and let the answer arrive while
        // they read the instant card. Mid-word typing keeps the pause.
        const text = _editor.textView;
        const wordComplete = _analysis.end < text.length &&
            !isWordCharacter(text[_analysis.end]);
        _debounceDeadline = MonoTime.currTime + (wordComplete
            ? refineImmediateMs.msecs : refineDebounceMs.msecs);
        _debounceActive = true;
        _pumpElapsed = pumpIntervalSeconds;
    }

    private void startRefinement()
    {
        if (!_analysis.hasSpan()) return;
        if (_settings.offline) return;
        if (!_settings.configured() || !refinementSupported()) return;

        RefinementRequest request;
        request.baseUrl = _settings.baseUrl;
        request.apiKey = _settings.apiKey;
        request.model = _settings.model;
        request.thinking = _settings.thinking;
        // Context is the sentence holding the target span, not just the caret:
        // the two differ whenever the caret already sits past the full stop.
        request.sentence = sentenceAround(_editor.textView, _analysis.start);
        request.target = _analysis.target;
        request.instantDefinition = _analysis.definition;
        request.instantChoices = _analysis.choices;

        _job = new RefinementJob();
        _jobGeneration = _generation;
        _job.start(request);
        _modelStatus = "refining…";
        _card.setStatus(_modelStatus);
        _pumpElapsed = pumpIntervalSeconds;
        updateStatus();
    }

    private void applyRefinement(RefinementResult result)
    {
        if (_jobGeneration != _generation)
        {
            // The span changed while the model was thinking; the instant pass for
            // the new text is the correct answer, so drop this one silently.
            return;
        }
        if (!result.ok)
        {
            _modelStatus = shorten(result.error, 46);
            _card.setStatus(_modelStatus);
            updateStatus();
            return;
        }
        if (result.definition.length > 0) _analysis.definition =
            result.definition;
        if (result.choices.length > 0) _analysis.choices = result.choices;
        _analysis.origin = "model";
        _modelStatus = result.choices.length > 0
            ? format("Model · %d ms", result.elapsedMs) : "Model";
        _card.present(_analysis, _modelStatus);
        anchorCard();
        updateStatus();
    }

    /// Replace the analyzed span with the chosen text.
    void applyChoice(int index)
    {
        auto analysis = _card.analysis;
        auto choice = _card.choice(index);
        if (analysis is null || choice is null) return;
        const start = analysis.start;
        const end = analysis.end;
        const targetWords = wordCount(analysis.target);
        const text = choice.text;
        const words = choice.words;

        _editor.setSelection(start, end);
        if (text.length == 0)
            _editor.deleteSelectionCommand();
        else
            _editor.insertTextAtCursor(toUTF32(text));
        const saved = targetWords - words;
        if (saved > 0) _savedWords += saved;

        _card.dismiss();
        _modelStatus = "";
        _dirty = true;
        _editor.requestFocus();
        refreshSuggestions(true);
    }

    /// Choose the next / previous choice from the card (Tab / Shift+Tab).
    void cycleChoice(int delta)
    {
        if (!_card.open()) return;
        _card.moveSelection(delta);
    }

    void toggleOptimizer()
    {
        _settings.optimizer = !_settings.optimizer;
        saveSettings(_settings);
        refreshSuggestions(true);
    }

    void toggleThinking()
    {
        _settings.thinking = !_settings.thinking;
        saveSettings(_settings);
        updateStatus();
    }

    // --- Keys ------------------------------------------------------------

    private bool filterEditorKey(ref Event event)
    {
        const shortcut = event.control() || event.meta();

        // Card navigation first: these keys belong to the shortlist while it is
        // open, and fall through to normal editing when it is not.
        if (_card.open())
        {
            if (event.key == Key.tab)
            {
                cycleChoice(event.shift() ? -1 : 1);
                return true;
            }
            if (event.key == Key.escape)
            {
                _card.dismiss();
                return true;
            }
            if (shortcut && event.key == Key.enter)
            {
                if (_card.applyActive()) return true;
            }
            if (shortcut && event.key >= Key.digit1 && event.key <= Key.digit8)
            {
                const index = cast(int) (event.key - Key.digit1);
                if (_card.choice(index) !is null)
                {
                    applyChoice(index);
                    return true;
                }
            }
        }

        if (shortcut && event.key == Key.s && event.shift())
        {
            showSaveDialog();
            return true;
        }
        if (shortcut && event.key == Key.s)
        {
            saveDocument();
            return true;
        }
        if (shortcut && event.key == Key.o)
        {
            openDocument();
            return true;
        }
        if (shortcut && event.key == Key.n)
        {
            newDocument();
            return true;
        }
        if (shortcut && event.key == Key.t)
        {
            toggleThinking();
            return true;
        }
        if (shortcut && event.key == Key.period)
        {
            toggleOptimizer();
            return true;
        }
        if (shortcut && event.key == Key.comma)
        {
            showSettings();
            return true;
        }
        if (shortcut && event.key == Key.d)
        {
            toggleTheme();
            return true;
        }
        return false;
    }

    override bool onKeyDown(ref Event event)
    {
        if (_settingsSheet.open())
        {
            if (event.key == Key.escape)
            {
                hideSettings();
                return true;
            }
            return false;
        }
        return filterEditorKey(event);
    }

    // --- Layout ----------------------------------------------------------

    protected override void onLayout()
    {
        if (_focusOnFirstLayout && host !is null)
        {
            _focusOnFirstLayout = false;
            _editor.requestFocus();
        }
        const barHeight = _titleBar.barHeight();
        const statusTop = maxInt(0, bounds().height - statusBarHeight);
        _titleBar.setBounds(Rect(0, 0, bounds().width, barHeight));

        const contentTop = barHeight;
        const contentHeight = maxInt(0, statusTop - contentTop);
        int columnWidth = bounds().width - pageInset * 6;
        if (columnWidth > columnMaxWidth) columnWidth = columnMaxWidth;
        if (columnWidth < columnMinWidth) columnWidth = columnMinWidth;
        const columnX = maxInt(0, (bounds().width - columnWidth) / 2);

        _page.setBounds(Rect(columnX, contentTop + pageInset, columnWidth,
            maxInt(0, contentHeight - pageInset * 2)));
        _editor.setBounds(Rect(_page.bounds().x + 34, _page.bounds().y + 26,
            maxInt(0, _page.bounds().width - 68),
            maxInt(0, _page.bounds().height - 44)));

        _statusBand.setBounds(Rect(0, statusTop, bounds().width, statusBarHeight));
        _statusLeft.setBounds(Rect(16, 0, bounds().width / 2, statusBarHeight));
        _statusRight.setBounds(Rect(bounds().width / 2, 0,
            maxInt(0, bounds().width / 2 - 16), statusBarHeight));
        _statusHairline.setBounds(Rect(0, statusTop, bounds().width, 1));

        _settingsSheet.setBounds(Rect(0, 0, bounds().width, bounds().height));
        _snapPreview.setBounds(Rect(0, 0, bounds().width, bounds().height));
        _windowBorder.setBounds(Rect(0, 0, bounds().width, bounds().height));

        anchorCard();
    }


    /// Place the card just above the caret's line, clamped inside the window.
    private void anchorCard()
    {
        const caret = _editor.caretRect();
        const origin = _editor.bounds();
        _card.anchorAt(Rect(origin.x + caret.x, origin.y + caret.y,
            caret.width, caret.height), bounds().width, bounds().height);
    }

    // --- Frame pump ------------------------------------------------------

    protected override void onTick(double deltaSeconds)
    {
        if (_debounceActive && MonoTime.currTime >= _debounceDeadline)
        {
            _debounceActive = false;
            startRefinement();
        }
        if (_job !is null && _job.done())
        {
            auto result = _job.take();
            _job = null;
            applyRefinement(result);
        }
        // A debounce or an in-flight request needs frames to observe; without
        // this the deadline would only be noticed at the next pointer event.
        // Each wake-up costs a whole-window rebuild, so pace them: a debounce
        // and a model reply both tolerate 100 ms of latency, and unbounded
        // per-frame rebuilds made typing feel heavy.
        if (!(_pumpElapsed >= 0.0)) _pumpElapsed = pumpIntervalSeconds;
        const pending = _debounceActive || _job !is null;
        if (!pending)
        {
            _pumpElapsed = pumpIntervalSeconds;
            return;
        }
        const step = deltaSeconds > 0.0 && deltaSeconds < 0.5
            ? deltaSeconds : 1.0 / 60.0;
        _pumpElapsed += step;
        if (_pumpElapsed >= pumpIntervalSeconds)
        {
            _pumpElapsed = 0.0;
            ++diagnosticPumpCount;
            invalidate();
        }
    }

    // --- Status and theme ------------------------------------------------

    private void updateStatus()
    {
        const text = _editor.textView;
        const model = _settings.offline ? "Offline"
            : _settings.configured()
            ? format("%s · Think %s", shorten(_settings.model, 28),
                _settings.thinking ? "on" : "off")
            : "No provider — set one with Ctrl+,";
        const state = _job !is null ? " · refining…"
            : (_settings.optimizer ? "" : " · optimizer off");
        _statusLeft.setText(format("%d words · %d characters · %d saved",
            countWords(text), text.length, _savedWords));
        _statusRight.setText(model ~ state);
        const name = _currentPath.length == 0 ? "Untitled" : baseName(_currentPath);
        _titleBar.setDocumentTitle(name, _dirty);
    }

    private Color pageColor()
    {
        return writeTheme(_settings.dark).panelBackground;
    }

    private Color statusBandColor()
    {
        const dark = _settings.dark;
        return Color.fromHex(dark ? 0x14171a : 0xefeae1);
    }

    private void applyTheme()
    {
        _window.setTheme(writeTheme(_settings.dark));
        _titleBar.setDarkMode(_settings.dark);
        _window.setFrameDark(_settings.dark);
        _page.setBackground(pageColor());
        _statusBand.setBackground(statusBandColor());
        invalidate();
    }

    private void toggleTheme()
    {
        _settings.dark = !_settings.dark;
        saveSettings(_settings);
        applyTheme();
        updateStatus();
    }

    private void showSettings()
    {
        _settingsSheet.setProvider(_settings.baseUrl, _settings.apiKey,
            _settings.model);
        _settingsSheet.setOriginNote(providerNote());
        _card.dismiss();
        _settingsSheet.show();
        invalidate();
    }

    private void hideSettings()
    {
        _settingsSheet.hide();
        _editor.requestFocus();
        invalidate();
    }

    private string providerNote()
    {
        if (_settings.providerOrigin == "aurora-opencode")
            return "Borrowed from Aurora OpenCode. Saving stores your own copy.";
        if (_settings.providerOrigin == "environment")
            return "From environment variables. Saving stores your own copy.";
        return "Any OpenAI-compatible /chat/completions endpoint works.";
    }

    private void saveProviderSettings()
    {
        _settings.baseUrl = _settingsSheet.baseUrl();
        _settings.apiKey = _settingsSheet.apiKey();
        _settings.model = _settingsSheet.model();
        _settings.providerOrigin = "own";
        saveSettings(_settings);
        hideSettings();
        _modelStatus = "";
        refreshSuggestions(true);
    }

    // --- Documents -------------------------------------------------------

    private void newDocument()
    {
        _editor.setText("", false);
        _currentPath = "";
        _dirty = false;
        _editor.requestFocus();
        refreshSuggestions(true);
    }

    private void openDocument()
    {
        FileDialogOptions options;
        options.mode = FileDialogMode.open;
        options.title = "Open Text File";
        options.initialPath = _currentPath;
        options.acceptLabel = "Open";
        string path;
        if (runFileDialogWindow(_window, options, path, writeTheme(_settings.dark)))
            loadPath(path);
        else
            _editor.requestFocus();
    }

    private void loadPath(string path)
    {
        try
        {
            const text = readText(path);
            _editor.setText(text, false);
            _editor.setCursorIndex(0);
            _currentPath = path;
            _dirty = false;
            _editor.requestFocus();
            refreshSuggestions(true);
        }
        catch (Exception error)
        {
            _modelStatus = shorten("Open failed: " ~ error.msg, 46);
            updateStatus();
        }
    }

    private void saveDocument()
    {
        if (_currentPath.length == 0)
        {
            showSaveDialog();
            return;
        }
        saveToPath(_currentPath);
    }

    private void showSaveDialog()
    {
        FileDialogOptions options;
        options.mode = FileDialogMode.save;
        options.title = "Save Text File";
        options.initialPath = _currentPath.length > 0 ? _currentPath
            : "Untitled.txt";
        options.defaultFileName = "Untitled.txt";
        options.acceptLabel = "Save";
        string path;
        if (runFileDialogWindow(_window, options, path, writeTheme(_settings.dark)))
            saveToPath(path);
        else
            _editor.requestFocus();
    }

    private void saveToPath(string path)
    {
        try
        {
            write(path, _editor.textUtf8());
            _currentPath = path;
            _dirty = false;
            updateStatus();
        }
        catch (Exception error)
        {
            _modelStatus = shorten("Save failed: " ~ error.msg, 46);
            updateStatus();
        }
    }
}

/// Shorten one line of provider text to `limit` characters.
private string shorten(string text, int limit) @safe pure
{
    auto value = text;
    foreach (index, char c; value)
    {
        if (c == '\n' || c == '\r')
        {
            value = value[0 .. index];
            break;
        }
    }
    if (limit <= 0 || value.length <= limit) return value;
    return value[0 .. cast(size_t) limit - 3] ~ "...";
}
