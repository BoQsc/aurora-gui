module experiment.aurorahost.dev_panel;

import experiment.aurorahost.host_editor : HostTextArea;
import experiment.aurorahost.host_ui : ChromeButton, ChromeStyle;
import experiment.aurorahost.scene : applyScene, loadScene, NodeRegistry;
import aurora : Canvas, Color, GuiWindow, IconKind, Label, Rect, TextField, Widget;
import std.algorithm : max;
import std.file : readText, remove, write;
import std.path : baseName;
import std.string : strip;

/**
 * Mutable project state for the dev panel. The panel can switch the scene path
 * without recreating the host window.
 */
class DevProject
{
    private GuiWindow _window;
    private NodeRegistry _registry;
    private string _path;
    private string _starter;

    this(GuiWindow window, NodeRegistry registry, string path, string starter)
    {
        _window = window;
        _registry = registry;
        _path = path;
        _starter = starter;
    }

    string path() const
    {
        return _path;
    }

    NodeRegistry registry()
    {
        return _registry;
    }

    string apply(string source)
    {
        const tempPath = _path ~ ".live";
        try
        {
            write(tempPath, source);
            auto next = loadScene(tempPath);
            write(_path, source);
            try remove(tempPath);
            catch (Exception) {}
            applyScene(_window, next, _registry);
            return "";
        }
        catch (Exception error)
        {
            try remove(tempPath);
            catch (Exception) {}
            return error.msg;
        }
    }

    string save(string source)
    {
        try
        {
            write(_path, source);
            return "";
        }
        catch (Exception error)
        {
            return error.msg;
        }
    }

    string create(string path, out string source)
    {
        source = _starter;
        try
            write(path, source);
        catch (Exception error)
            return error.msg;
        _path = path;
        return apply(source);
    }

    string open(string path, out string source)
    {
        const previous = _path;
        _path = path;
        try
        {
            source = readText(path);
            const error = apply(source);
            if (error.length > 0)
            {
                _path = previous;
                return error;
            }
            return "";
        }
        catch (Exception error)
        {
            _path = previous;
            return error.msg;
        }
    }

    string saveAs(string source, string path)
    {
        try
        {
            write(path, source);
            _path = path;
            return "";
        }
        catch (Exception error)
        {
            return error.msg;
        }
    }
}

/**
 * Host-owned scene source panel.
 *
 * It floats above the retained scene, survives a scene reload, and is the
 * single-executable development loop: edit the source, reload it in place, or
 * save without reloading. The panel is not part of the application scene and
 * does not affect its layout.
 */
class DevPanel : Widget
{
    private DevProject _project;
    private NodeRegistry _registry;
    private HostTextArea _editor;
    private TextField _pathField;
    private Label _title;
    private Label _status;
    private ChromeButton _reload;
    private ChromeButton _save;
    private ChromeButton _liveButton;
    private ChromeButton _hideButton;
    private ChromeButton _expandButton;
    private ChromeButton _newButton;
    private ChromeButton _openButton;
    private ChromeButton _saveAsButton;
    private bool _live = true;
    private bool _dirty;
    private bool _collapsed;
    private double _liveTimer;
    private string _lastApplied;

    this(DevProject project, string source)
    {
        _project = project;
        _registry = project.registry();
        layoutHints().excludeFromLayout = true;

        _title = new Label("DEV · SCENE SOURCE");
        _title.setScale(2);
        _title.setColor(Color.rgba(226, 232, 240, 255));
        add(_title);

        _pathField = new TextField(project.path());
        _pathField.setTextColor(Color.rgba(203, 213, 225, 255));
        add(_pathField);

        _newButton = new ChromeButton("New", IconKind.none, ChromeStyle.toolbar);
        _newButton.setTextColor(Color.rgba(226, 232, 240, 255));
        _newButton.onClick = delegate() { newProject(); };
        add(_newButton);

        _openButton = new ChromeButton("Open", IconKind.none, ChromeStyle.toolbar);
        _openButton.setTextColor(Color.rgba(226, 232, 240, 255));
        _openButton.onClick = delegate() { openProject(); };
        add(_openButton);

        _saveAsButton = new ChromeButton("Save As", IconKind.none,
            ChromeStyle.toolbar);
        _saveAsButton.setTextColor(Color.rgba(226, 232, 240, 255));
        _saveAsButton.onClick = delegate() { saveAsProject(); };
        add(_saveAsButton);

        _editor = new HostTextArea(source);
        _editor.setLineNumbers(true);
        _editor.setWordWrap(false);
        _editor.setTextColor(Color.rgba(203, 213, 225, 255));
        _editor.setSelection(0, 0);
        _editor.onChanged = delegate() { markDirty(); };
        add(_editor);
        _lastApplied = source;

        _status = new Label("Live on — changes apply after a pause. Save writes only.");
        _status.setScale(1);
        _status.setColor(Color.rgba(148, 163, 184, 255));
        add(_status);

        _reload = new ChromeButton("Reload", IconKind.none, ChromeStyle.toolbar);
        _reload.setTextColor(Color.rgba(226, 232, 240, 255));
        _reload.onClick = delegate() { reload(); };
        add(_reload);

        _save = new ChromeButton("Save", IconKind.none, ChromeStyle.toolbar);
        _save.setTextColor(Color.rgba(226, 232, 240, 255));
        _save.onClick = delegate() { save(); };
        add(_save);

        _liveButton = new ChromeButton("Live", IconKind.none, ChromeStyle.toolbar);
        _liveButton.setTextColor(Color.rgba(226, 232, 240, 255));
        _liveButton.setActive(true);
        _liveButton.onClick = delegate() { toggleLive(); };
        add(_liveButton);

        _hideButton = new ChromeButton("Hide", IconKind.none, ChromeStyle.toolbar);
        _hideButton.setTextColor(Color.rgba(226, 232, 240, 255));
        _hideButton.onClick = delegate() { setCollapsed(true); };
        add(_hideButton);

        _expandButton = new ChromeButton("DEV", IconKind.none, ChromeStyle.toolbar);
        _expandButton.setTextColor(Color.rgba(226, 232, 240, 255));
        _expandButton.setActive(true);
        _expandButton.onClick = delegate() { setCollapsed(false); };
        _expandButton.setVisible(false);
        add(_expandButton);

        setBounds(Rect(0, 0, 520, 640));
        layoutChildren();
    }

    /** Reattach after the scene root is replaced, then re-expose dev nodes. */
    void attach(Widget root)
    {
        if (root is null)
            return;
        if (parent() !is null && parent() !is root)
            parent().remove(this);
        if (parent() is null)
            root.add(this);
        const size = root.bounds();
        const panelWidth = _collapsed ? 64 : 520;
        const panelHeight = _collapsed ? 44 : max(360, size.height - 32);
        setBounds(Rect(max(16, size.width - panelWidth - 16), 16, panelWidth,
            panelHeight));
        layoutChildren();
        root.bringChildToFront(this);
        registerNodes();
    }

    private void layoutChildren()
    {
        const width = bounds().width;
        const height = bounds().height;
        if (_collapsed)
        {
            _title.setVisible(false);
            _pathField.setVisible(false);
            _newButton.setVisible(false);
            _openButton.setVisible(false);
            _saveAsButton.setVisible(false);
            _editor.setVisible(false);
            _status.setVisible(false);
            _reload.setVisible(false);
            _save.setVisible(false);
            _liveButton.setVisible(false);
            _hideButton.setVisible(false);
            _expandButton.setVisible(true);
            _expandButton.setBounds(Rect(8, 6, 48, 32));
            return;
        }
        _title.setVisible(true);
        _pathField.setVisible(true);
        _newButton.setVisible(true);
        _openButton.setVisible(true);
        _saveAsButton.setVisible(true);
        _editor.setVisible(true);
        _status.setVisible(true);
        _reload.setVisible(true);
        _save.setVisible(true);
        _liveButton.setVisible(true);
        _hideButton.setVisible(true);
        _expandButton.setVisible(false);
        const pad = 16;
        const inner = max(80, width - pad * 2);
        const editorTop = 116;
        const editorHeight = max(120, height - editorTop - 88);
        _title.setBounds(Rect(pad, 14, inner, 28));
        _pathField.setBounds(Rect(pad, 44, inner, 28));
        _newButton.setBounds(Rect(pad, 78, 60, 28));
        _openButton.setBounds(Rect(pad + 68, 78, 64, 28));
        _saveAsButton.setBounds(Rect(pad + 140, 78, 80, 28));
        _editor.setBounds(Rect(pad, editorTop, inner, editorHeight));
        _status.setBounds(Rect(pad, editorTop + editorHeight + 8, inner, 20));
        const buttonY = height - 40;
        _reload.setBounds(Rect(pad, buttonY, 100, 30));
        _save.setBounds(Rect(pad + 108, buttonY, 84, 30));
        _liveButton.setBounds(Rect(pad + 200, buttonY, 84, 30));
        _hideButton.setBounds(Rect(width - 80, buttonY, 64, 30));
    }

    private void registerNodes()
    {
        if (_registry is null ||
            _registry.widget("aurora.dev.source") !is null)
            return;
        _registry.registerNode("aurora.dev.source", "textArea", _editor, "");
        _registry.setQuiet("aurora.dev.source");
        _registry.registerNode("aurora.dev.path", "textField", _pathField,
            _project.path());
        _registry.registerNode("aurora.dev.reload", "button", _reload, "Reload");
        _registry.registerNode("aurora.dev.save", "button", _save, "Save");
        _registry.registerNode("aurora.dev.live", "button", _liveButton, "Live");
        _registry.registerNode("aurora.dev.hide", "button", _hideButton, "Hide");
        _registry.registerNode("aurora.dev.expand", "button", _expandButton, "DEV");
        _registry.registerNode("aurora.dev.new", "button", _newButton, "New");
        _registry.registerNode("aurora.dev.open", "button", _openButton, "Open");
        _registry.registerNode("aurora.dev.saveas", "button", _saveAsButton,
            "Save As");
    }


    private void newProject()
    {
        const path = _pathField.textUtf8().strip;
        if (path.length == 0)
        {
            setStatus("A project path is required",
                Color.rgba(248, 113, 113, 255));
            return;
        }
        string source;
        const error = _project.create(path, source);
        if (error.length == 0)
        {
            _pathField.setText(path);
            _editor.setText(source, false);
            _editor.setSelection(0, 0);
            _lastApplied = source;
            _dirty = false;
        }
        showResult(error, "Created");
    }

    private void openProject()
    {
        const path = _pathField.textUtf8().strip;
        if (path.length == 0)
        {
            setStatus("A project path is required",
                Color.rgba(248, 113, 113, 255));
            return;
        }
        string source;
        const error = _project.open(path, source);
        if (error.length == 0)
        {
            _pathField.setText(path);
            _editor.setText(source, false);
            _editor.setSelection(0, 0);
            _lastApplied = source;
            _dirty = false;
        }
        showResult(error, "Opened");
    }

    private void saveAsProject()
    {
        const path = _pathField.textUtf8().strip;
        if (path.length == 0)
        {
            setStatus("A project path is required",
                Color.rgba(248, 113, 113, 255));
            return;
        }
        const error = _project.saveAs(_editor.textUtf8(), path);
        if (error.length == 0)
            _pathField.setText(path);
        showResult(error, "Saved as");
    }

    /** Called from the host frame clock; applies a paused edit automatically. */
    void service(double delta)
    {
        if (!_live || !_dirty)
            return;
        _liveTimer += delta;
        if (_liveTimer < 0.25)
            return;
        _dirty = false;
        _liveTimer = 0;
        if (_editor.textUtf8() == _lastApplied)
            return;
        reload();
    }


    private void markDirty()
    {
        _dirty = true;
        _liveTimer = 0;
    }

    private void toggleLive()
    {
        _live = !_live;
        _liveButton.setActive(_live);
        if (_live)
        {
            markDirty();
            setStatus("Live on — changes apply after a pause",
                Color.rgba(52, 211, 153, 255));
        }
        else
        {
            _dirty = false;
            _liveTimer = 0;
            setStatus("Live off — use Reload",
                Color.rgba(148, 163, 184, 255));
        }
    }

    private void reload()
    {
        const source = _editor.textUtf8();
        const hadFocus = _editor.focused();
        const cursor = _editor.cursorIndex();
        const anchor = _editor.selectionAnchor();
        string error;
        try
            error = _project.apply(source);
        catch (Exception exception)
            error = exception.msg;
        if (hadFocus)
        {
            _editor.requestFocus();
            _editor.setSelection(anchor, cursor);
        }
        if (error.length == 0)
        {
            _lastApplied = source;
            _dirty = false;
            _liveTimer = 0;
        }
        showResult(error, "Reloaded");
    }

    private void save()
    {
        string error;
        try
            error = _project.save(_editor.textUtf8());
        catch (Exception exception)
            error = exception.msg;
        showResult(error, "Saved");
    }

    private void showResult(string error, string success)
    {
        if (error.length > 0)
            setStatus("Error: " ~ error, Color.rgba(248, 113, 113, 255));
        else
            setStatus(success ~ " — " ~ baseName(_project.path()),
                Color.rgba(52, 211, 153, 255));
    }

    private void setStatus(string message, Color color)
    {
        _status.setText(message);
        _status.setColor(color);
        invalidate();
    }

    private void setCollapsed(bool collapsed)
    {
        _collapsed = collapsed;
        const rootWidth = parent() !is null ? parent().bounds().width : 1180;
        const rootHeight = parent() !is null ? parent().bounds().height : 800;
        const panelWidth = _collapsed ? 64 : 520;
        const panelHeight = _collapsed ? 44 : max(360, rootHeight - 32);
        setBounds(Rect(max(16, rootWidth - panelWidth - 16), 16, panelWidth,
            panelHeight));
        layoutChildren();
        if (parent() !is null)
            parent().bringChildToFront(this);
        if (!_collapsed)
            _editor.requestFocus();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const width = bounds().width;
        const height = bounds().height;
        if (width <= 0 || height <= 0)
            return;
        const body = Rect(0, 0, width, height);
        canvas.fillRoundedRect(body, 12, Color.rgba(11, 18, 32, 250));
        canvas.drawRoundedRect(body, 12, Color.rgba(11, 18, 32, 250),
            Color.rgba(45, 212, 191, 120), 1);
        canvas.fillRect(Rect(0, 0, width, 3), Color.rgba(45, 212, 191, 255));
    }
}
