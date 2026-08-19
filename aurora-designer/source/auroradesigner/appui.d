module auroradesigner.appui;

import aurora;
import auroradesigner.model;
import auroradesigner.titlebar : DesignerTitleBar;
import std.algorithm : min;
import std.array : array, appender;
import std.conv : to;
import std.file : exists, readText, write;
import std.format : format;
import std.path : baseName;
import std.string : strip;

/**
 * Aurora Designer root.
 *
 * A three-region desktop: a palette of draggable widget kinds on the left, an
 * artboard surface in the middle (the document's window surface), and an
 * inspector on the right/bottom that edits the selected node's properties.
 *
 * The artboard is drawn by `DesignCanvas`, a plain widget that fills its
 * region and maps pointer events from viewport-local to artboard coordinates
 * so hit-testing is exact regardless of window size.
 */
final class DesignerRoot : VBox
{
    private GuiWindow _window;
    private DesignerTitleBar _titleBar;
    private TitleBarSnapPreview _snapPreview;
    private WindowBorder _windowBorder;
    private DesignCanvas _canvas;
    private ScrollView _paletteScroll;
    private VBox _palette;
    private VBox _inspector;
    private ScrollView _inspectorScroll;
    private PopupOverlay _activePopup;

    // Toolbar controls (kept for test access).
    private Button _newButton;
    private Button _openButton;
    private Button _saveButton;
    private Button _codeButton;
    private Button _undoButton;
    private Button _redoButton;
    private Button _deleteButton;
    private Button _themeButton;
    private TextField _nameField;
    private TextField _xField;
    private TextField _yField;
    private TextField _wField;
    private TextField _hField;

    private DesignDocument _document;
    private int _selected = -1;
    private bool _dirty;
    private bool _dark = true;
    private string _projectPath;

    // History (serialized document snapshots).
    private string[] _undoStack;
    private string[] _redoStack;
    private static immutable size_t HistoryLimit = 50;

    this(GuiWindow window)
    {
        super(0);
        _window = window;
        _document.canvasWidth = 900;
        _document.canvasHeight = 560;
        buildTitleBar();
        buildToolbar();
        buildBody();
        buildWindowChrome();
        addPaletteNode(NodeKind.window);
        commitHistory();
        setDirty(false);
        updateTitle();
    }

    // ------------------------------------------------------------------
    // Accessors (also used by the headless smoke test)
    // ------------------------------------------------------------------

    DesignerTitleBar titleBar() @safe pure nothrow @nogc { return _titleBar; }
    TitleBarSnapPreview snapPreview() @safe pure nothrow @nogc
    {
        return _snapPreview;
    }
    DesignCanvas canvas() @safe pure nothrow @nogc { return _canvas; }
    const(DesignDocument) document() const @safe pure nothrow @nogc
    {
        return _document;
    }
    /// Mutable access for the artboard's drag/resize gestures.
    ref DesignDocument designDocument() @safe nothrow @nogc
    {
        return _document;
    }
    int selectedIndex() @safe pure nothrow @nogc { return _selected; }
    bool dirty() @safe pure nothrow @nogc { return _dirty; }
    string projectPath() const @safe pure nothrow @nogc { return _projectPath; }
    string codeForTesting()
    {
        return generateCode(_document);
    }

    /// Test-only: select a node by index without a pointer event.
    void selectNodeForTesting(int index)
    {
        selectNode(index);
        rebuildInspector();
        _canvas.invalidate();
    }

    /// Test-only: add a node of a kind directly (returns the new index).
    int addNodeForTesting(NodeKind kind)
    {
        commitHistory();
        const index = addNodeToDocument(kind);
        selectNode(index);
        rebuildInspector();
        _canvas.invalidate();
        return index;
    }

    /// Test-only: delete the selected node.
    void deleteSelectedForTesting()
    {
        deleteSelectedNode();
    }

    /// Test-only: run undo once.
    void undoForTesting()
    {
        undo();
    }

    /// Test-only: run redo once.
    void redoForTesting()
    {
        redo();
    }

    private void buildTitleBar()
    {
        _titleBar = add(new DesignerTitleBar(_window));
        _titleBar.onSnapPreview = delegate(TitleBarSnapTarget target, Rect bounds)
        {
            if (target == TitleBarSnapTarget.none)
            {
                _snapPreview.hide();
                return;
            }
            Rect origin;
            _window.windowBounds(origin);
            _snapPreview.show(Rect(bounds.x - origin.x, bounds.y - origin.y,
                bounds.width, bounds.height));
        };
        updateTitle();
    }

    private void buildToolbar()
    {
        auto toolbar = add(new HBox(4, Insets(6, 2)));
        toolbar.layoutHints().preferredHeight = 38;
        toolbar.setId("designer-toolbar");

        _newButton = toolbar.add(new Button("", IconKind.newDocument));
        _newButton.setId("designer-new");
        _newButton.onClick = delegate() { newDesign(); };

        _openButton = toolbar.add(new Button("", IconKind.open));
        _openButton.setId("designer-open");
        _openButton.onClick = delegate() { openDesign(); };

        _saveButton = toolbar.add(new Button("", IconKind.save));
        _saveButton.setId("designer-save");
        _saveButton.onClick = delegate() { saveDesign(); };

        _codeButton = toolbar.add(new Button("", IconKind.terminal));
        _codeButton.setId("designer-code");
        _codeButton.onClick = delegate() { showCodePopup(); };

        _undoButton = toolbar.add(new Button("", IconKind.refresh));
        _undoButton.setId("designer-undo");
        _undoButton.onClick = delegate() { undo(); };

        _redoButton = toolbar.add(new Button("", IconKind.chevronRight));
        _redoButton.setId("designer-redo");
        _redoButton.onClick = delegate() { redo(); };

        _deleteButton = toolbar.add(new Button("", IconKind.trash));
        _deleteButton.setId("designer-delete");
        _deleteButton.onClick = delegate() { deleteSelectedNode(); };

        toolbar.add(new Separator(Orientation.vertical));

        auto nameLabel = toolbar.add(new Label("Name"));
        nameLabel.setScale(1);
        nameLabel.setPixelSize(12);
        _nameField = toolbar.add(new TextField());
        _nameField.setId("designer-name");
        _nameField.setPlaceholder("name");
        _nameField.layoutHints().preferredWidth = 110;
        _nameField.layoutHints().flex = 1.0;
        _nameField.onChanged = delegate() { applyNameField(); };

        toolbar.add(new Label("X"));
        _xField = toolbar.add(new TextField());
        _xField.setId("designer-x");
        _xField.layoutHints().preferredWidth = 52;
        _xField.onChanged = delegate() { applyCoordinate(_xField, 0); };

        toolbar.add(new Label("Y"));
        _yField = toolbar.add(new TextField());
        _yField.setId("designer-y");
        _yField.layoutHints().preferredWidth = 52;
        _yField.onChanged = delegate() { applyCoordinate(_yField, 1); };

        toolbar.add(new Label("W"));
        _wField = toolbar.add(new TextField());
        _wField.setId("designer-w");
        _wField.layoutHints().preferredWidth = 52;
        _wField.onChanged = delegate() { applyCoordinate(_wField, 2); };

        toolbar.add(new Label("H"));
        _hField = toolbar.add(new TextField());
        _hField.setId("designer-h");
        _hField.layoutHints().preferredWidth = 52;
        _hField.onChanged = delegate() { applyCoordinate(_hField, 3); };

        _themeButton = toolbar.add(new Button("Dark", IconKind.settings));
        _themeButton.setId("designer-theme");
        _themeButton.onClick = delegate() { toggleTheme(); };

        auto aboutButton = toolbar.add(new Button("?", IconKind.clock));
        aboutButton.setId("designer-about");
        aboutButton.onClick = delegate() { showAbout(); };
    }

    private void buildBody()
    {
        auto body = add(new SplitPane(buildPalette(), buildCenter(),
            Orientation.horizontal));
        body.setDividerSize(5);
        body.setRatio(0.16);
        body.setId("designer-body");
    }

    private Widget buildPalette()
    {
        auto panel = new VBox(4, Insets(6));
        panel.layoutHints().minWidth = 148;
        panel.layoutHints().preferredWidth = 160;

        auto header = new Label("Palette");
        header.setScale(1);
        header.setPixelSize(12);
        panel.add(header);

        _palette = new VBox(2);
        _paletteScroll = new ScrollView(_palette);
        _paletteScroll.layoutHints().flex = 1.0;
        panel.add(_paletteScroll);

        addPaletteEntry("Window", NodeKind.window);
        addPaletteEntry("Panel", NodeKind.panel);
        addPaletteEntry("HBox", NodeKind.hbox);
        addPaletteEntry("VBox", NodeKind.vbox);
        addPaletteEntry("Button", NodeKind.button);
        addPaletteEntry("Label", NodeKind.label);
        addPaletteEntry("Text Field", NodeKind.textfield);
        addPaletteEntry("Check Box", NodeKind.checkbox);
        addPaletteEntry("Separator", NodeKind.separator);
        addPaletteEntry("Scroll View", NodeKind.scrollview);
        addPaletteEntry("List View", NodeKind.listview);
        addPaletteEntry("Image", NodeKind.image);

        return panel;
    }

    private void addPaletteEntry(string label, NodeKind kind)
    {
        auto button = _palette.add(new Button(label));
        button.setFlat(true);
        button.setTextPixelSize(12);
        button.layoutHints().preferredWidth = 0;
        button.layoutHints().fillCrossAxis = true;
        button.setId("palette-" ~ defaultId(kind, 0));
        button.onClick = delegate() { addPaletteNode(kind); };
    }

    private Widget buildCenter()
    {
        auto center = new SplitPane(_canvas = new DesignCanvas(this),
            buildInspector(), Orientation.vertical);
        center.setDividerSize(5);
        center.setRatio(0.76);
        center.setId("designer-center");
        return center;
    }

    private Widget buildInspector()
    {
        _inspector = new VBox(4, Insets(8));
        _inspector.layoutHints().minHeight = 120;
        _inspectorScroll = new ScrollView(_inspector);
        _inspectorScroll.layoutHints().minHeight = 120;
        _inspectorScroll.layoutHints().flex = 1.0;

        auto panel = new VBox(0);
        panel.layoutHints().minHeight = 130;
        panel.layoutHints().fillCrossAxis = true;
        auto label = new Label("Inspector");
        label.setScale(1);
        label.setPixelSize(12);
        panel.add(label);
        panel.add(_inspectorScroll);
        return panel;
    }

    private void buildWindowChrome()
    {
        _snapPreview = add(new TitleBarSnapPreview());
        _windowBorder = add(new WindowBorder());
    }

    // ------------------------------------------------------------------
    // Document mutations
    // ------------------------------------------------------------------

    private void commitHistory()
    {
        _undoStack ~= serializeDocument(_document);
        if (_undoStack.length > HistoryLimit)
            _undoStack = _undoStack[$ - HistoryLimit .. $];
        _redoStack.length = 0;
    }

    private void undo()
    {
        if (_undoStack.length <= 1) return;
        _redoStack ~= serializeDocument(_document);
        if (_redoStack.length > HistoryLimit)
            _redoStack = _redoStack[$ - HistoryLimit .. $];
        _undoStack = _undoStack[0 .. $ - 1];
        _document = deserializeDocument(_undoStack[$ - 1]);
        if (_document.findNode(_selected) < 0) _selected = -1;
        setDirty(true);
        refreshAll();
    }

    private void redo()
    {
        if (_redoStack.length == 0) return;
        _undoStack ~= serializeDocument(_document);
        const snapshot = _redoStack[$ - 1];
        _redoStack = _redoStack[0 .. $ - 1];
        _document = deserializeDocument(snapshot);
        if (_document.findNode(_selected) < 0) _selected = -1;
        setDirty(true);
        refreshAll();
    }

    /// Add a node under the window root at the artboard center.
    private int addNodeToDocument(NodeKind kind)
    {
        int parent = _document.root;
        if (parent < 0)
        {
            if (kind != NodeKind.window)
            {
                parent = _document.addNode(NodeKind.window, 0, 0);
                _document.root = parent;
            }
            else
            {
                parent = _document.addNode(NodeKind.window, 0, 0);
                _document.root = parent;
                return parent;
            }
        }
        const w = defaultWidth(kind);
        const h = defaultHeight(kind);
        const x = maxInt(0, (_document.canvasWidth - w) / 2);
        const y = maxInt(0, (_document.canvasHeight - h) / 2);
        const index = _document.addNode(kind, x, y);
        _document.nodes[parent].children ~= index;
        return index;
    }

    private void addPaletteNode(NodeKind kind)
    {
        commitHistory();
        const index = addNodeToDocument(kind);
        selectNode(index);
        rebuildInspector();
        setDirty(true);
        refreshAll();
    }

    private void deleteSelectedNode()
    {
        if (_selected < 0) return;
        commitHistory();
        _document.removeNode(_selected);
        _selected = -1;
        setDirty(true);
        refreshAll();
    }

    private void newDesign()
    {
        commitHistory();
        _document = DesignDocument.init;
        _document.canvasWidth = 900;
        _document.canvasHeight = 560;
        _projectPath = "";
        _selected = -1;
        commitHistory();
        setDirty(false);
        refreshAll();
    }

    private void openDesign()
    {
        FileDialogOptions options;
        options.mode = FileDialogMode.open;
        options.title = "Open Aurora Design";
        options.acceptLabel = "Open";
        string path;
        if (runFileDialogWindow(_window, options, path, dialogTheme()))
            loadDesign(path);
    }

    private void loadDesign(string path)
    {
        try
        {
            if (!exists(path))
            {
                showStatus("File does not exist: " ~ path);
                return;
            }
            const text = readText(path);
            auto doc = deserializeDocument(text);
            if (doc.findNode(doc.root) < 0)
            {
                showStatus("Not a valid Aurora design file.");
                return;
            }
            commitHistory();
            _document = doc;
            _projectPath = path;
            _selected = -1;
            setDirty(false);
            refreshAll();
        }
        catch (Exception error)
        {
            showStatus("Open failed: " ~ error.msg);
        }
    }

    private void saveDesign()
    {
        if (_projectPath.length == 0)
        {
            FileDialogOptions options;
            options.mode = FileDialogMode.save;
            options.title = "Save Aurora Design";
            options.initialPath = "design.aurora";
            options.defaultFileName = "design.aurora";
            options.acceptLabel = "Save";
            string path;
            if (runFileDialogWindow(_window, options, path, dialogTheme()))
                saveToPath(path);
            return;
        }
        saveToPath(_projectPath);
    }

    private void saveToPath(string path)
    {
        try
        {
            write(path, serializeDocument(_document));
            _projectPath = path;
            setDirty(false);
            showStatus("Saved " ~ path);
        }
        catch (Exception error)
        {
            showStatus("Save failed: " ~ error.msg);
        }
    }

    // ------------------------------------------------------------------
    // Selection / inspector
    // ------------------------------------------------------------------

    void selectNode(int index)
    {
        _selected = _document.findNode(index);
        refreshToolbarFields();
    }

    private void refreshAll()
    {
        refreshToolbarFields();
        rebuildInspector();
        updateTitle();
        _canvas.invalidate();
    }

    void refreshToolbarFields()
    {
        const selected = _document.findNode(_selected);
        if (selected < 0)
        {
            _nameField.setText("", false);
            _xField.setText("", false);
            _yField.setText("", false);
            _wField.setText("", false);
            _hField.setText("", false);
            _deleteButton.setEnabled(false);
            return;
        }
        const node = _document.nodes[selected];
        _nameField.setText(node.name, false);
        _xField.setText(to!string(node.x), false);
        _yField.setText(to!string(node.y), false);
        _wField.setText(to!string(node.width), false);
        _hField.setText(to!string(node.height), false);
        _deleteButton.setEnabled(true);
    }

    void rebuildInspector()
    {
        _inspector.clearChildren();
        const selected = _document.findNode(_selected);
        if (selected < 0)
        {
            auto hint = _inspector.add(new Label("Select a widget on the\n"
                ~ "artboard to edit it."));
            hint.setScale(1);
            hint.setPixelSize(12);
            return;
        }
        const node = _document.nodes[selected];

        auto typeRow = inspectorRow("Type", new Label(nodeKindName(node.kind)));
        typeRow.layoutHints().fillCrossAxis = true;
        _inspector.add(typeRow);

        _inspector.add(inspectorFieldRow("Name", new TextField(), node.name,
            delegate(string value) { _document.nodes[_selected].name = value; }));

        _inspector.add(inspectorFieldRow("ID", new TextField(), node.id,
            delegate(string value) { _document.nodes[_selected].id = value; }));

        _inspector.add(inspectorFieldRow("X", new TextField(),
            to!string(node.x), delegate(string value)
            {
                _document.nodes[_selected].x = parseCoord(value,
                    _document.nodes[_selected].x);
            }));
        _inspector.add(inspectorFieldRow("Y", new TextField(),
            to!string(node.y), delegate(string value)
            {
                _document.nodes[_selected].y = parseCoord(value,
                    _document.nodes[_selected].y);
            }));
        _inspector.add(inspectorFieldRow("Width", new TextField(),
            to!string(node.width), delegate(string value)
            {
                _document.nodes[_selected].width = maxInt(8, parseCoord(value,
                    _document.nodes[_selected].width));
            }));
        _inspector.add(inspectorFieldRow("Height", new TextField(),
            to!string(node.height), delegate(string value)
            {
                _document.nodes[_selected].height = maxInt(8, parseCoord(value,
                    _document.nodes[_selected].height));
            }));

        if (node.text.length != 0 || textWidget(node.kind))
        {
            _inspector.add(inspectorFieldRow("Text", new TextField(), node.text,
                delegate(string value)
                {
                    _document.nodes[_selected].text = value;
                    _canvas.invalidate();
                }));
        }

        if (node.kind == NodeKind.panel || node.kind == NodeKind.window)
        {
            _inspector.add(inspectorFieldRow("Color", new TextField(),
                node.colorHex, delegate(string value)
                {
                    const hex = value.strip();
                    _document.nodes[_selected].colorHex = hex.length == 6 ? hex : "";
                    _canvas.invalidate();
                }));

            auto transparent = new CheckBox("Transparent");
            transparent.setChecked(node.transparent, false);
            transparent.onChanged = delegate(bool value)
            {
                _document.nodes[_selected].transparent = value;
                _canvas.invalidate();
                noteChange();
            };
            _inspector.add(transparent);
        }

        if (node.kind == NodeKind.button)
        {
            auto accent = new CheckBox("Accent style");
            accent.setChecked(node.accent, false);
            accent.onChanged = delegate(bool value)
            {
                _document.nodes[_selected].accent = value;
                _canvas.invalidate();
                noteChange();
            };
            _inspector.add(accent);
        }

        if (node.kind == NodeKind.checkbox)
        {
            auto checked = new CheckBox("Checked");
            checked.setChecked(node.checked, false);
            checked.onChanged = delegate(bool value)
            {
                _document.nodes[_selected].checked = value;
                _canvas.invalidate();
                noteChange();
            };
            _inspector.add(checked);
        }
    }

    private Widget inspectorRow(string label, Widget control)
    {
        auto row = new HBox(6);
        row.layoutHints().preferredHeight = 34;
        row.layoutHints().fillCrossAxis = true;
        auto name = new Label(label);
        name.setScale(1);
        name.setPixelSize(12);
        name.layoutHints().preferredWidth = 58;
        name.layoutHints().minWidth = 58;
        row.add(name);
        row.add(control);
        return row;
    }

    private Widget inspectorFieldRow(string label, TextField field,
        string initial, void delegate(string) action)
    {
        field.setPixelSizeOverride(12);
        field.setText(initial, false);
        field.layoutHints().flex = 1.0;
        field.onChanged = delegate()
        {
            const value = field.textUtf8();
            action(value);
            noteChange();
        };
        return inspectorRow(label, field);
    }

    private static int parseCoord(string value, int fallback)
    {
        try
        {
            return value.strip().to!int;
        }
        catch (Exception)
        {
            return fallback;
        }
    }

    void noteChange()
    {
        setDirty(true);
        _canvas.invalidate();
        updateTitle();
    }

    // ------------------------------------------------------------------
    // Toolbar field bindings
    // ------------------------------------------------------------------

    private void applyNameField()
    {
        const selected = _document.findNode(_selected);
        if (selected < 0) return;
        _document.nodes[selected].name = _nameField.textUtf8();
        noteChange();
    }

    private void applyCoordinate(TextField field, int which)
    {
        const selected = _document.findNode(_selected);
        if (selected < 0) return;
        int value;
        try
        {
            value = field.textUtf8().strip().to!int;
        }
        catch (Exception)
        {
            field.setText(to!string(valueFor(field)), false);
            return;
        }
        if (which == 0) _document.nodes[selected].x = value;
        else if (which == 1) _document.nodes[selected].y = value;
        else if (which == 2) _document.nodes[selected].width = maxInt(8, value);
        else if (which == 3) _document.nodes[selected].height = maxInt(8, value);
        field.setText(to!string(valueFor(field)), false);
        noteChange();
        refreshToolbarFields();
    }

    private int valueFor(TextField field) const @safe pure nothrow @nogc
    {
        const selected = _document.findNode(_selected);
        if (selected < 0) return 0;
        if (field is _xField) return _document.nodes[selected].x;
        if (field is _yField) return _document.nodes[selected].y;
        if (field is _wField) return _document.nodes[selected].width;
        if (field is _hField) return _document.nodes[selected].height;
        return 0;
    }

    // ------------------------------------------------------------------
    // Theme
    // ------------------------------------------------------------------

    private void toggleTheme()
    {
        _dark = !_dark;
        _window.setTheme(_dark ? darkDesignerTheme() : lightDesignerTheme());
        _titleBar.setDarkMode(_dark);
        _window.setFrameDark(_dark);
        _themeButton.setText(_dark ? "Dark" : "Light");
        _canvas.invalidate();
    }

    private Theme dialogTheme()
    {
        return _dark ? darkDesignerTheme() : lightDesignerTheme();
    }

    private void updateTitle()
    {
        const name = _projectPath.length == 0 ? "Untitled" : baseName(_projectPath);
        _titleBar.setDocumentTitle(name, _dirty);
        const selected = _document.findNode(_selected);
        if (selected >= 0)
            _titleBar.setTitle(format("%s%s — %s (%s)",
                _dirty ? "*" : "", name,
                _document.nodes[selected].id, nodeKindName(_document.nodes[selected].kind)));
        else
            _titleBar.setDocumentTitle(name, _dirty);
    }

    private void setDirty(bool value)
    {
        _dirty = value;
        updateTitle();
    }

    // ------------------------------------------------------------------
    // Code popup
    // ------------------------------------------------------------------

    private void showCodePopup()
    {
        dismissActivePopup();
        const code = generateCode(_document);

        auto content = new VBox(8, Insets(10));
        auto header = new Label("Generated D code");
        header.setScale(1);
        header.setPixelSize(12);
        content.add(header);

        auto codeArea = new TextArea();
        codeArea.setReadOnly(true);
        codeArea.setWordWrap(false);
        codeArea.setPixelSizeOverride(13);
        codeArea.setText(code, false);
        codeArea.layoutHints().preferredHeight = 260;
        content.add(codeArea);

        auto footer = new HBox(8);
        auto copyButton = new Button("Copy to clipboard", IconKind.save);
        copyButton.setAccent(true);
        copyButton.setTextPixelSize(12);
        copyButton.onClick = delegate()
        {
            writeClipboardText(code);
            copyButton.setText("Copied");
        };
        footer.add(copyButton);
        auto closeButton = new Button("Close", IconKind.close);
        closeButton.setTextPixelSize(12);
        closeButton.onClick = delegate() { dismissActivePopup(); };
        footer.add(closeButton);
        content.add(footer);

        auto popup = new PopupOverlay(content, _codeButton);
        popup.setAnchor(Rect.init, PopupPlacement.centered);
        popup.setRequestedSize(Size(620, 420));
        popup.setBackdrop(Color.rgba(0, 0, 0, 130));
        popup.onDismissed = delegate() { _activePopup = null; };
        openPopup(popup);
    }

    private void showAbout()
    {
        dismissActivePopup();
        auto content = new VBox(8, Insets(12));
        auto title = new Label("Aurora Designer");
        title.setScale(2);
        content.add(title);
        auto body = new Label("A visual UI designer for Aurora-D applications.\n\n"
            ~ "Drag widgets from the palette, position them on the artboard, "
            ~ "edit their properties in the inspector, and copy the generated "
            ~ "D code into your application.");
        body.setScale(1);
        body.setPixelSize(12);
        content.add(body);
        auto footer = new HBox(8);
        auto close = new Button("OK", IconKind.close);
        close.setAccent(true);
        close.setTextPixelSize(12);
        close.onClick = delegate() { dismissActivePopup(); };
        footer.add(close);
        content.add(footer);

        auto popup = new PopupOverlay(content, _codeButton);
        popup.setAnchor(Rect.init, PopupPlacement.centered);
        popup.setRequestedSize(Size(460, 220));
        popup.setBackdrop(Color.rgba(0, 0, 0, 120));
        popup.onDismissed = delegate() { _activePopup = null; };
        openPopup(popup);
    }

    private void openPopup(PopupOverlay popup)
    {
        _activePopup = popup;
        popupRoot(this).add(popup);
    }

    private void dismissActivePopup()
    {
        if (_activePopup !is null)
        {
            auto popup = _activePopup;
            _activePopup = null;
            popup.dismiss();
        }
    }

    // ------------------------------------------------------------------
    // Status / keyboard
    // ------------------------------------------------------------------

    private void showStatus(string text)
    {
        _titleBar.setTitle((_dirty ? "*" : "") ~ text);
    }

    override bool onKeyDown(ref Event event)
    {
        if (_activePopup !is null) return false;
        const shortcut = event.control() || event.meta();
        if (shortcut && event.key == Key.z && !event.shift())
        {
            undo();
            return true;
        }
        if (shortcut && event.key == Key.y)
        {
            redo();
            return true;
        }
        if (shortcut && event.key == Key.s)
        {
            saveDesign();
            return true;
        }
        if (shortcut && event.key == Key.o)
        {
            openDesign();
            return true;
        }
        if (shortcut && event.key == Key.n)
        {
            newDesign();
            return true;
        }
        if (event.key == Key.deleteKey)
        {
            deleteSelectedNode();
            return true;
        }
        if (event.key == Key.left || event.key == Key.right ||
            event.key == Key.up || event.key == Key.down)
        {
            const step = event.shift() ? 10 : 1;
            const dx = event.key == Key.left ? -step :
                (event.key == Key.right ? step : 0);
            const dy = event.key == Key.up ? -step :
                (event.key == Key.down ? step : 0);
            nudgeSelected(dx, dy);
            return true;
        }
        return false;
    }

    private void nudgeSelected(int dx, int dy)
    {
        const selected = _document.findNode(_selected);
        if (selected < 0) return;
        if (dx == 0 && dy == 0) return;
        _document.nodes[selected].x += dx;
        _document.nodes[selected].y += dy;
        noteChange();
        refreshToolbarFields();
    }

    /// Called by the canvas on every committed gesture (move/resize).
    void noteGeometryChange()
    {
        commitHistory();
        noteChange();
        refreshToolbarFields();
    }

    protected override void onLayout()
    {
        super.onLayout();
        if (_snapPreview !is null)
            _snapPreview.setBounds(Rect(0, 0, bounds().width, bounds().height));
        if (_windowBorder !is null)
            _windowBorder.setBounds(Rect(0, 0, bounds().width, bounds().height));
    }
}

// ---------------------------------------------------------------------------
// Themes
// ---------------------------------------------------------------------------

Theme darkDesignerTheme()
{
    auto theme = Theme.dark();
    theme.windowBackground = Color.fromHex(0x1b1b1b);
    theme.panelBackground = Color.fromHex(0x252526);
    theme.panelElevated = Color.fromHex(0x2d2d30);
    theme.text = Color.fromHex(0xe6e6e6);
    theme.textMuted = Color.fromHex(0x9d9d9d);
    theme.border = Color.fromHex(0x3e3e42);
    theme.accent = Color.fromHex(0x0e639c);
    theme.accentHover = Color.fromHex(0x1177bb);
    theme.accentPressed = Color.fromHex(0x0b5488);
    theme.selection = Color.fromHex(0x04395e);
    theme.selectionText = Color.fromHex(0xffffff);
    theme.fieldBackground = Color.fromHex(0x1f1f1f);
    theme.buttonBackground = Color.fromHex(0x333333);
    theme.buttonHover = Color.fromHex(0x3c3c3c);
    theme.buttonPressed = Color.fromHex(0x4a4a4a);
    theme.disabled = Color.fromHex(0x6e6e6e);
    theme.danger = Color.fromHex(0xe81123);
    theme.cornerRadius = 3;
    theme.controlHeight = 30;
    theme.fontScale = cast(int) TextScale.caption;
    return theme;
}

Theme lightDesignerTheme()
{
    auto theme = Theme.light();
    theme.windowBackground = Color.fromHex(0xf3f3f3);
    theme.panelBackground = Color.fromHex(0xf5f5f5);
    theme.panelElevated = Color.fromHex(0xffffff);
    theme.text = Color.fromHex(0x1a1a1a);
    theme.textMuted = Color.fromHex(0x616161);
    theme.border = Color.fromHex(0xd6d6d6);
    theme.accent = Color.fromHex(0x0e639c);
    theme.accentHover = Color.fromHex(0x1177bb);
    theme.accentPressed = Color.fromHex(0x0b5488);
    theme.selection = Color.fromHex(0xcce8ff);
    theme.selectionText = Color.fromHex(0x1a1a1a);
    theme.fieldBackground = Color.fromHex(0xffffff);
    theme.buttonBackground = Color.fromHex(0xe9e9e9);
    theme.buttonHover = Color.fromHex(0xdedede);
    theme.buttonPressed = Color.fromHex(0xcccccc);
    theme.disabled = Color.fromHex(0xb0b0b0);
    theme.danger = Color.fromHex(0xe81123);
    theme.cornerRadius = 3;
    theme.controlHeight = 30;
    theme.fontScale = cast(int) TextScale.caption;
    return theme;
}

// ---------------------------------------------------------------------------
// Artboard canvas
// ---------------------------------------------------------------------------

/**
 * The artboard surface. Fills its region; paints the artboard rect centered
 * (clamped to the top-left when the viewport is smaller) and every node in
 * painter order on top. Pointer events are mapped from viewport-local to
 * artboard-local coordinates for exact hit-testing.
 */
final class DesignCanvas : Widget
{
    private DesignerRoot _root;
    private int _hovered = -1;
    private int _dragging = -1;
    private bool _draggingChild;
    private int _resizing = -1;
    private ResizeHandle _resizeHandle;
    private Point _dragStart;
    private Point _dragStartNode;
    private Size _dragStartSize;
    private Point _marqueeStart;
    private bool _marqueeActive;
    private Point _marqueeCurrent;

    private enum ResizeHandle : ubyte { none, nw, ne, sw, se }

    this(DesignerRoot root)
    {
        _root = root;
        setFocusable(true);
        layoutHints().flex = 1.0;
        layoutHints().minWidth = 200;
        layoutHints().minHeight = 140;
        setCursor(CursorKind.arrow);
    }

    const(DesignDocument) document() const @safe pure nothrow @nogc
    {
        return _root.document();
    }
    int hoveredIndex() const @safe pure nothrow @nogc { return _hovered; }
    bool marqueeActive() const @safe pure nothrow @nogc { return _marqueeActive; }

    /// Artboard origin in canvas-local coordinates.
    Point artboardOrigin() const @safe pure nothrow @nogc
    {
        const doc = _root.document();
        const x = maxInt(0, (bounds().width - doc.canvasWidth) / 2);
        const y = maxInt(0, (bounds().height - doc.canvasHeight) / 2);
        return Point(x, y);
    }

    /// Map a canvas-local point to artboard coordinates.
    Point toArtboard(Point local) const @safe pure nothrow @nogc
    {
        const origin = artboardOrigin();
        return Point(local.x - origin.x, local.y - origin.y);
    }

    private Rect artboardRect() const @safe pure nothrow @nogc
    {
        const origin = artboardOrigin();
        return Rect(origin.x, origin.y, document().canvasWidth,
            document().canvasHeight);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        canvas.fillRect(Rect(0, 0, bounds().width, bounds().height),
            palette.windowBackground);

        const art = artboardRect();
        paintCheckerboard(canvas, art);

        const doc = _root.document();
        if (doc.findNode(doc.root) < 0)
        {
            canvas.drawTextInRect(art, "Click a palette item to add a widget"d,
                palette.textMuted, 1, HorizontalAlign.center, VerticalAlign.middle,
                true);
            return;
        }

        // Paint the whole tree in painter order (children after parents).
        foreach (index, node; doc.nodes)
        {
            const rect = doc.absoluteRect(cast(int) index);
            paintNode(canvas, doc, cast(int) index, rect, node);
        }

        // Selection outline + resize handles.
        const selected = doc.findNode(_root.selectedIndex());
        if (selected >= 0)
        {
            const rect = doc.absoluteRect(selected).translated(art.x, art.y);
            canvas.strokeRect(rect, palette.accent, 1);
            paintResizeHandles(canvas, rect, palette.accent);
        }

        if (_marqueeActive)
        {
            const a = _marqueeStart;
            const b = _marqueeCurrent;
            const x = min(a.x, b.x);
            const y = min(a.y, b.y);
            const w = maxInt(0, (a.x > b.x ? a.x : b.x) - x);
            const h = maxInt(0, (a.y > b.y ? a.y : b.y) - y);
            canvas.strokeRect(Rect(x, y, w, h), palette.accent.withAlpha(180), 1);
            canvas.fillRect(Rect(x, y, w, h), palette.accent.withAlpha(40));
        }
    }

    private void paintCheckerboard(ref Canvas canvas, Rect rect)
    {
        const cell = 10;
        for (int y = 0; y < rect.height; y += cell)
            for (int x = 0; x < rect.width; x += cell)
            {
                const dark = ((x / cell) + (y / cell)) % 2 == 0;
                canvas.fillRect(Rect(rect.x + x, rect.y + y, cell, cell),
                    dark ? Color.fromHex(0x2b2b2b) : Color.fromHex(0x333333));
            }
    }

    private void paintNode(ref Canvas canvas, const ref DesignDocument doc,
        int index, Rect artRect, const ref Node node)
    {
        const origin = artboardOrigin();
        const rect = Rect(artRect.x + origin.x, artRect.y + origin.y,
            artRect.width, artRect.height);
        const palette = theme();
        final switch (node.kind)
        {
            case NodeKind.window:
            {
                Color fill = node.transparent ?
                    palette.fieldBackground.withAlpha(90) :
                    nodeColor(node, palette.panelElevated);
                canvas.drawRoundedRect(rect, 2, fill, palette.border, 1);
                canvas.fillRect(Rect(rect.x + 1, rect.y + 1, rect.width - 2, 22),
                    nodeColor(node, palette.buttonBackground));
                canvas.drawText(Point(rect.x + 8, rect.y + 3),
                    to!dstring(node.id ~ " (window)"), palette.text, 1);
                break;
            }
            case NodeKind.panel:
            {
                Color fill = node.transparent ? Color.rgba(0, 0, 0, 0) :
                    nodeColor(node, palette.buttonBackground);
                canvas.drawRoundedRect(rect, 2, fill, palette.border, 1);
                if (!node.transparent)
                    canvas.drawTextInRect(rect, to!dstring(node.id), palette.textMuted,
                        1, HorizontalAlign.left, VerticalAlign.top, true);
                break;
            }
            case NodeKind.hbox:
            case NodeKind.vbox:
            {
                Color fill = nodeColor(node, palette.fieldBackground.withAlpha(60));
                canvas.drawRoundedRect(rect, 2, fill, palette.border, 1);
                const cell = node.kind == NodeKind.hbox ? 4 : 1;
                const pad = 10;
                const gap = 6;
                for (int i = 0; i < 4; ++i)
                {
                    Rect slot;
                    if (node.kind == NodeKind.hbox)
                    {
                        const w = (rect.width - pad * 2 - gap * 3) / 4;
                        slot = Rect(rect.x + pad + i * (w + gap),
                            rect.y + rect.height / 2 - 8, w, 16);
                    }
                    else
                    {
                        const h = (rect.height - pad * 2 - gap * 3) / 4;
                        slot = Rect(rect.x + rect.width / 2 - 8,
                            rect.y + pad + i * (h + gap), 16, h);
                    }
                    canvas.drawRoundedRect(slot, 2, palette.fieldBackground,
                        palette.border, 1);
                }
                canvas.drawTextInRect(Rect(rect.x + 0, rect.y + 2, rect.width, maxInt(0, rect.height - 2)), to!dstring(node.id),
                    palette.textMuted, 1, HorizontalAlign.center,
                    VerticalAlign.top, true);
                break;
            }
            case NodeKind.button:
            {
                Color fill = node.accent ? palette.accent : palette.buttonBackground;
                Color foreground = node.accent ? Color.rgb(255, 255, 255) :
                    palette.text;
                canvas.drawRoundedRect(rect, 3, fill, palette.border, 1);
                canvas.drawTextInRect(rect, to!dstring(node.text.length != 0 ?
                    node.text : "Button"), foreground, 1,
                    HorizontalAlign.center, VerticalAlign.middle, true);
                break;
            }
            case NodeKind.label:
            {
                canvas.drawTextInRect(rect, to!dstring(node.text.length != 0 ?
                    node.text : "Label"), palette.text, 1,
                    HorizontalAlign.left, VerticalAlign.middle, true);
                break;
            }
            case NodeKind.textfield:
            {
                canvas.drawRoundedRect(rect, 2, palette.fieldBackground,
                    palette.border, 1);
                canvas.drawTextInRect(Rect(rect.x + 6, rect.y, maxInt(0, rect.width - 6), rect.height),
                    to!dstring(node.text.length != 0 ? node.text : "Text"),
                    palette.textMuted, 1, HorizontalAlign.left,
                    VerticalAlign.middle, true);
                break;
            }
            case NodeKind.checkbox:
            {
                const box = Rect(rect.x + 3, rect.y + (rect.height - 16) / 2,
                    16, 16);
                canvas.drawRoundedRect(box, 3, node.checked ? palette.accent :
                    palette.fieldBackground, palette.border, 1);
                if (node.checked)
                {
                    canvas.drawLine(Point(box.x + 3, box.y + 8),
                        Point(box.x + 7, box.y + 12), Color.rgb(255, 255, 255), 2);
                    canvas.drawLine(Point(box.x + 7, box.y + 12),
                        Point(box.x + 13, box.y + 4), Color.rgb(255, 255, 255), 2);
                }
                canvas.drawTextInRect(Rect(rect.x + 24, rect.y,
                    maxInt(0, rect.width - 24), rect.height),
                    to!dstring(node.text.length != 0 ? node.text : "Check Box"),
                    palette.text, 1, HorizontalAlign.left, VerticalAlign.middle,
                    true);
                break;
            }
            case NodeKind.separator:
            {
                const cy = rect.y + rect.height / 2;
                canvas.drawLine(Point(rect.x, cy), Point(rect.x + rect.width, cy),
                    palette.border, 1);
                break;
            }
            case NodeKind.scrollview:
            {
                canvas.drawRoundedRect(rect, 2, palette.fieldBackground,
                    palette.border, 1);
                const bar = Rect(rect.right() - 12, rect.y + 4, 8,
                    maxInt(8, rect.height / 3));
                canvas.fillRoundedRect(bar, 2, palette.textMuted.withAlpha(120));
                canvas.drawTextInRect(Rect(rect.x + 6, rect.y + 2, rect.width - 20,
                    18), to!dstring(node.id ~ " (scroll)"), palette.textMuted, 1,
                    HorizontalAlign.left, VerticalAlign.top, true);
                break;
            }
            case NodeKind.listview:
            {
                canvas.drawRoundedRect(rect, 2, palette.fieldBackground,
                    palette.border, 1);
                const rowH = 18;
                int y = rect.y + 2;
                int i = 0;
                while (y + rowH <= rect.bottom() - 2 && i < 4)
                {
                    canvas.fillRect(Rect(rect.x + 2, y, rect.width - 4, rowH - 1),
                        (i % 2 == 0) ? palette.fieldBackground :
                        palette.buttonHover.withAlpha(60));
                    canvas.drawText(Point(rect.x + 6, y + 2),
                        to!dstring("Row " ~ to!string(i + 1)), palette.textMuted, 1);
                    y += rowH;
                    ++i;
                }
                break;
            }
            case NodeKind.image:
            {
                canvas.drawRoundedRect(rect, 2, palette.fieldBackground,
                    palette.border, 1);
                canvas.drawTextInRect(rect, to!dstring(node.id), palette.textMuted, 1,
                    HorizontalAlign.center, VerticalAlign.middle, true);
                break;
            }
        }

        // Hover outline (only over non-selected nodes, drawn after).
        if (index == _hovered && index != _root.selectedIndex() &&
            !_marqueeActive)
            canvas.strokeRect(rect, palette.textMuted.withAlpha(120), 1);
    }

    private Color nodeColor(const ref Node node, Color fallback)
    {
        if (node.colorHex.length == 6)
        {
            try
            {
                return Color.fromHex(to!uint(node.colorHex, 16));
            }
            catch (Exception)
            {
            }
        }
        return fallback;
    }

    private void paintResizeHandles(ref Canvas canvas, Rect rect, Color color)
    {
        const handle = 6;
        paintHandle(canvas, Rect(rect.x - 2, rect.y - 2, handle, handle), color);
        paintHandle(canvas, Rect(rect.right() - handle + 2, rect.y - 2,
            handle, handle), color);
        paintHandle(canvas, Rect(rect.x - 2, rect.bottom() - handle + 2,
            handle, handle), color);
        paintHandle(canvas, Rect(rect.right() - handle + 2,
            rect.bottom() - handle + 2, handle, handle), color);
    }

    private void paintHandle(ref Canvas canvas, Rect rect, Color color)
    {
        canvas.fillRect(rect, color);
        canvas.strokeRect(rect, theme().panelElevated, 1);
    }

    // ------------------------------------------------------------------
    // Pointer interaction
    // ------------------------------------------------------------------

    private ResizeHandle handleAt(Point local)
    {
        const selected = document().findNode(_root.selectedIndex());
        if (selected < 0) return ResizeHandle.none;
        const origin = artboardOrigin();
        const abs = document().absoluteRect(selected);
        const rect = Rect(abs.x + origin.x, abs.y + origin.y, abs.width,
            abs.height);
        const hit = 7;
        const nearTL = local.x >= rect.x - hit && local.y >= rect.y - hit &&
            local.x < rect.x + hit && local.y < rect.y + hit;
        const nearTR = local.x >= rect.right() - hit && local.y >= rect.y - hit &&
            local.x < rect.right() + hit && local.y < rect.y + hit;
        const nearBL = local.x >= rect.x - hit && local.y >= rect.bottom() - hit &&
            local.x < rect.x + hit && local.y < rect.bottom() + hit;
        const nearBR = local.x >= rect.right() - hit &&
            local.y >= rect.bottom() - hit && local.x < rect.right() + hit &&
            local.y < rect.bottom() + hit;
        if (nearTL) return ResizeHandle.nw;
        if (nearTR) return ResizeHandle.ne;
        if (nearBL) return ResizeHandle.sw;
        if (nearBR) return ResizeHandle.se;
        return ResizeHandle.none;
    }

    private CursorKind cursorForHandle(ResizeHandle handle)
    {
        final switch (handle)
        {
            case ResizeHandle.none: return CursorKind.arrow;
            case ResizeHandle.nw:
            case ResizeHandle.se: return CursorKind.resizeDiagonalNWSE;
            case ResizeHandle.ne:
            case ResizeHandle.sw: return CursorKind.resizeDiagonalNESW;
        }
    }

    override bool onMouseMove(ref Event event)
    {
        if (_resizing >= 0)
        {
            updateResize(event.position);
            return true;
        }
        if (_dragging >= 0)
        {
            updateDrag(event.position);
            return true;
        }
        if (_marqueeActive)
        {
            _marqueeCurrent = event.position;
            invalidate();
            return true;
        }

        auto doc = _root.designDocument();
        const art = toArtboard(event.position);
        const hit = doc.findNode(doc.root) >= 0 ? doc.hitTest(art.x, art.y) : -1;
        if (hit != _hovered)
        {
            _hovered = hit;
            invalidate();
        }
        const handle = handleAt(event.position);
        setCursor(cursorForHandle(handle));
        return true;
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left && event.button != MouseButton.right)
            return false;
        requestFocus();

        auto doc = _root.designDocument();
        const art = toArtboard(event.position);
        const hit = doc.findNode(doc.root) >= 0 ? doc.hitTest(art.x, art.y) : -1;

        if (event.button == MouseButton.left)
        {
            const handle = handleAt(event.position);
            if (handle != ResizeHandle.none && doc.findNode(_root.selectedIndex()) >= 0)
            {
                _resizing = _root.selectedIndex();
                _resizeHandle = handle;
                _dragStart = event.position;
                _dragStartNode = Point(doc.nodes[_resizing].x,
                    doc.nodes[_resizing].y);
                _dragStartSize = Size(doc.nodes[_resizing].width,
                    doc.nodes[_resizing].height);
                captureMouse();
                invalidate();
                return true;
            }

            if (hit >= 0)
            {
                _root.selectNode(hit);
                _root.rebuildInspector();
                _dragging = hit;
                _dragStart = event.position;
                _dragStartNode = Point(doc.nodes[hit].x, doc.nodes[hit].y);
                _dragStartSize = Size(doc.nodes[hit].width,
                    doc.nodes[hit].height);
                captureMouse();
                invalidate();
                return true;
            }

            // Empty-space press starts a marquee.
            _root.selectNode(-1);
            _root.rebuildInspector();
            _marqueeStart = event.position;
            _marqueeCurrent = event.position;
            _marqueeActive = true;
            captureMouse();
            invalidate();
            return true;
        }

        if (event.button == MouseButton.right)
        {
            _root.selectNode(hit);
            _root.rebuildInspector();
            invalidate();
            showNodeContextMenu(hit, event.globalPosition);
            return true;
        }
        return false;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        if (_resizing >= 0)
        {
            const node = _resizing;
            _resizing = -1;
            releaseMouse();
            _root.noteGeometryChange();
            invalidate();
            return true;
        }
        if (_dragging >= 0)
        {
            _dragging = -1;
            releaseMouse();
            _root.noteGeometryChange();
            invalidate();
            return true;
        }
        if (_marqueeActive)
        {
            _marqueeActive = false;
            releaseMouse();
            const a = toArtboard(_marqueeStart);
            const b = toArtboard(event.position);
            const x = min(a.x, b.x);
            const y = min(a.y, b.y);
            const w = maxInt(0, (a.x > b.x ? a.x : b.x) - x);
            const h = maxInt(0, (a.y > b.y ? a.y : b.y) - y);
            if (w > 3 && h > 3)
            {
                auto doc = _root.designDocument();
                int best = -1;
                if (doc.findNode(doc.root) >= 0)
                    best = hitTestRect(doc, x, y, w, h);
                _root.selectNode(best);
                _root.rebuildInspector();
            }
            invalidate();
            return true;
        }
        return false;
    }

    private int hitTestRect(const ref DesignDocument doc, int x, int y,
        int w, int h)
    {
        // Find the topmost node whose rect intersects the marquee.
        for (int i = cast(int) doc.nodes.length - 1; i >= 0; --i)
        {
            const abs = doc.absoluteRect(i);
            if (abs.x + abs.width > x && abs.y + abs.height > y &&
                abs.x < x + w && abs.y < y + h)
                return i;
        }
        return -1;
    }

    private void updateDrag(Point local)
    {
        auto doc = _root.designDocument();
        if (doc.findNode(_dragging) < 0) return;
        const delta = local - _dragStart;
        doc.nodes[_dragging].x = _dragStartNode.x + delta.x;
        doc.nodes[_dragging].y = _dragStartNode.y + delta.y;
        _root.noteChange();
        _root.refreshToolbarFields();
        invalidate();
    }

    private void updateResize(Point local)
    {
        auto doc = _root.designDocument();
        if (doc.findNode(_resizing) < 0) return;
        const delta = local - _dragStart;
        int x = _dragStartNode.x;
        int y = _dragStartNode.y;
        int w = _dragStartSize.width;
        int h = _dragStartSize.height;
        final switch (_resizeHandle)
        {
            case ResizeHandle.none: return;
            case ResizeHandle.nw:
                x = _dragStartNode.x + delta.x;
                y = _dragStartNode.y + delta.y;
                w = _dragStartSize.width - delta.x;
                h = _dragStartSize.height - delta.y;
                break;
            case ResizeHandle.ne:
                y = _dragStartNode.y + delta.y;
                w = _dragStartSize.width + delta.x;
                h = _dragStartSize.height - delta.y;
                break;
            case ResizeHandle.sw:
                x = _dragStartNode.x + delta.x;
                w = _dragStartSize.width - delta.x;
                h = _dragStartSize.height + delta.y;
                break;
            case ResizeHandle.se:
                w = _dragStartSize.width + delta.x;
                h = _dragStartSize.height + delta.y;
                break;
        }
        if (w < 8) { x = _dragStartNode.x + _dragStartSize.width - 8; w = 8; }
        if (h < 8) { y = _dragStartNode.y + _dragStartSize.height - 8; h = 8; }
        doc.nodes[_resizing].x = x;
        doc.nodes[_resizing].y = y;
        doc.nodes[_resizing].width = w;
        doc.nodes[_resizing].height = h;
        _root.noteChange();
        _root.refreshToolbarFields();
        invalidate();
    }

    private void showNodeContextMenu(int index, Point globalPosition)
    {
        const selected = document().findNode(index);
        if (selected < 0)
        {
            ContextMenuItem[] items;
            items ~= ContextMenuItem.command("Add Window", IconKind.newDocument,
                delegate() { _root.addPaletteNode(NodeKind.window); });
            items ~= ContextMenuItem.command("Add Panel", IconKind.folder,
                delegate() { _root.addPaletteNode(NodeKind.panel); });
            showContextMenu(this, globalPosition, items);
            return;
        }
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("Add child widget", IconKind.newDocument,
            delegate()
            {
                _root.addPaletteNode(NodeKind.panel);
            });
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Delete", IconKind.trash,
            delegate() { _root.deleteSelectedForTesting(); }, "Del");
        showContextMenu(this, globalPosition, items);
    }
}

// ---------------------------------------------------------------------------
// Window border
// ---------------------------------------------------------------------------

/** One-pixel theme border over every edge; never intercepts pointer input. */
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

// ---------------------------------------------------------------------------
// Clipboard (Windows)
// ---------------------------------------------------------------------------

version (Windows)
{
    import core.sys.windows.windows : CF_UNICODETEXT, CloseClipboard,
        EmptyClipboard, GlobalAlloc, GlobalFree, GlobalLock, GlobalUnlock,
        GMEM_MOVEABLE, OpenClipboard, SetClipboardData;
    import std.utf : toUTF16;
    pragma(lib, "user32");
}

/// Copy a string to the system clipboard (Windows). No-op on other platforms.
void writeClipboardText(string value)
{
    version (Windows)
    {
        if (!OpenClipboard(null)) return;
        scope (exit) CloseClipboard();
        if (!EmptyClipboard()) return;
        auto encoded = toUTF16(value);
        const bytes = (encoded.length + 1) * wchar.sizeof;
        auto memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
        if (memory is null) return;
        auto text = cast(wchar*) GlobalLock(memory);
        if (text is null)
        {
            GlobalFree(memory);
            return;
        }
        foreach (index, ch; encoded) text[index] = ch;
        text[encoded.length] = 0;
        GlobalUnlock(memory);
        if (SetClipboardData(CF_UNICODETEXT, memory) is null)
            GlobalFree(memory);
    }
    else
    {
    }
}
