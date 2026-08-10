module auroraimageviewer.appui;

import aurora;
import auroraimageviewer.decoder : DecodedImage, ImageLoader;
import auroraimageviewer.imageview : ImageView;
import auroraimageviewer.scaler : MipImage;
import core.time : MonoTime;
import std.conv : to;
import std.file : getcwd;
import std.format : format;
import std.path : baseName, dirName;
import std.utf : toUTF32;

private immutable Color viewerBackground = Color.fromHex(0x15171a);
private immutable Color viewerPanel = Color.fromHex(0x1c1f24);
private immutable Color viewerElevated = Color.fromHex(0x22262c);
private immutable Color viewerField = Color.fromHex(0x131518);
private immutable Color viewerBorder = Color.fromHex(0x3a4149);
private immutable Color viewerText = Color.fromHex(0xeceef1);
private immutable Color viewerMuted = Color.fromHex(0x99a2ab);
private immutable Color viewerAccent = Color.fromHex(0x4f8cff);

public Theme imageViewerTheme()
{
    auto theme = Theme.dark();
    theme.windowBackground = viewerBackground;
    theme.panelBackground = viewerPanel;
    theme.panelElevated = viewerElevated;
    theme.text = viewerText;
    theme.textMuted = viewerMuted;
    theme.border = viewerBorder;
    theme.accent = viewerAccent;
    theme.accentHover = Color.fromHex(0x6ca0ff);
    theme.accentPressed = Color.fromHex(0x3974df);
    theme.selection = Color.fromHex(0x315b99);
    theme.selectionText = Color.fromHex(0xffffff);
    theme.fieldBackground = viewerField;
    theme.buttonBackground = Color.fromHex(0x2a3037);
    theme.buttonHover = Color.fromHex(0x333a43);
    theme.buttonPressed = Color.fromHex(0x22272d);
    theme.disabled = Color.fromHex(0x6e7883);
    theme.danger = Color.fromHex(0xff6b6b);
    theme.cornerRadius = 6;
    theme.controlHeight = 34;
    return theme;
}

public final class ViewerRoot : VBox
{
    private GuiWindow _window;
    private ImageView _view;
    private Button _openButton;
    private Button _reloadButton;
    private Button _zoomOutButton;
    private Button _zoomInButton;
    private Button _fitButton;
    private Button _actualButton;
    private Label _zoomLabel;
    private Label _infoLabel;
    private Label _status;
    private ImageLoader _loader;
    private string _currentPath;
    private string _currentError;
    private bool _loading;
    private MonoTime _decodeStarted;

    this(GuiWindow window, string initialPath = "")
    {
        super(0);
        _window = window;
        _loader = new ImageLoader();
        buildUi();
        if (initialPath.length > 0)
            loadPath(initialPath);
        else
        {
            _status.setText("Open an image with Ctrl+O or drop one here");
            _window.setTitle("Aurora Image Viewer");
        }
    }

    private void buildUi()
    {
        auto toolbar = add(new HBox(6, Insets(8, 6)));
        toolbar.layoutHints().preferredHeight = 48;
        toolbar.setBorder(viewerBorder, 1);

        _openButton = toolbar.add(new Button("Open", IconKind.open));
        _openButton.setId("iv-open");
        _openButton.onClick = delegate() { openDialog(); };

        _reloadButton = toolbar.add(new Button("Reload", IconKind.refresh));
        _reloadButton.setId("iv-reload");
        _reloadButton.onClick = delegate() { reloadCurrent(); };
        _reloadButton.setEnabled(false);

        _zoomOutButton = toolbar.add(new Button("−", IconKind.none));
        _zoomOutButton.setId("iv-zoom-out");
        _zoomOutButton.onClick = delegate() { _view.zoomOut(); };

        _zoomLabel = toolbar.add(new Label("—"));
        _zoomLabel.setId("iv-zoom");
        _zoomLabel.setScale(1);
        _zoomLabel.layoutHints().minWidth = 64;
        _zoomLabel.setAlignment(HorizontalAlign.center, VerticalAlign.middle);

        _zoomInButton = toolbar.add(new Button("+", IconKind.none));
        _zoomInButton.setId("iv-zoom-in");
        _zoomInButton.onClick = delegate() { _view.zoomIn(); };

        _fitButton = toolbar.add(new Button("Fit", IconKind.image));
        _fitButton.setId("iv-fit");
        _fitButton.onClick = delegate() { _view.fitToWindow(); };

        _actualButton = toolbar.add(new Button("100%", IconKind.none));
        _actualButton.setId("iv-actual");
        _actualButton.onClick = delegate() { _view.actualSize(); };

        toolbar.add(new Spacer());

        _infoLabel = toolbar.add(new Label("No image"));
        _infoLabel.setId("iv-info");
        _infoLabel.setScale(1);
        _infoLabel.setColor(viewerMuted);
        _infoLabel.layoutHints().minWidth = 180;

        _view = new ImageView();
        _view.setId("iv-view");
        _view.layoutHints().flex = 1.0;
        _view.onViewChanged = delegate() { updateViewLabels(); };
        _view.onOpenRequested = delegate() { openDialog(); };
        _view.onReloadRequested = delegate() { reloadCurrent(); };
        _view.onFileDropped = delegate(string path) { loadPath(path); };
        add(_view);

        _status = add(new Label("Ready"));
        _status.setId("iv-status");
        _status.layoutHints().preferredHeight = 26;
        _status.setScale(1);
    }

    private void openDialog()
    {
        FileDialogOptions options;
        options.title = "Open Image";
        options.mode = FileDialogMode.open;
        options.acceptLabel = "Open";
        options.initialPath = _currentPath.length > 0 ? dirName(_currentPath) : getcwd();
        showFileDialog(this, options,
            delegate(string path) { loadPath(path); });
    }

    private void reloadCurrent()
    {
        if (_currentPath.length > 0)
            loadPath(_currentPath);
    }

    private void loadPath(string path)
    {
        if (path.length == 0) return;
        _currentPath = path;
        _currentError = "";
        _loading = true;
        _decodeStarted = MonoTime.currTime;
        _status.setText("Loading " ~ baseName(path) ~ "…");
        _reloadButton.setEnabled(true);
        _window.setTitle(baseName(path) ~ " — Aurora Image Viewer");
        _loader.request(path);
    }

    protected override void onTick(double deltaSeconds)
    {
        string path;
        DecodedImage image;
        string error;
        while (_loader.takeResult(path, image, error))
        {
            if (path != _currentPath) continue;
            _loading = false;
            if (error.length > 0)
            {
                _currentError = error;
                _view.setError(error);
                _status.setText("Error: " ~ error);
            }
            else
            {
                _currentError = "";
                const decodeMs = (MonoTime.currTime - _decodeStarted).total!"msecs";
                auto mip = new MipImage(image.width, image.height, image.rgba,
                    image.hasAlpha);
                _view.setImage(mip);
                _infoLabel.setText(format("%d × %d px", image.width, image.height));
                _status.setText(format("%s  ·  %s  ·  decoded in %s ms",
                    baseName(path), image.format, to!string(decodeMs)));
            }
            updateViewLabels();
        }
        super.onTick(deltaSeconds);
    }

    private void updateViewLabels()
    {
        _zoomLabel.setText(format("%.0f%%", _view.zoom() * 100.0));
        _infoLabel.setText(_view.hasImage()
            ? format("%d × %d px", _view.imageWidth(), _view.imageHeight())
            : "No image");
    }

    override bool onKeyDown(ref Event event)
    {
        if ((event.control() || event.meta()) && event.key == Key.o)
        {
            openDialog();
            return true;
        }
        if ((event.control() || event.meta()) && event.key == Key.r)
        {
            reloadCurrent();
            return true;
        }
        return false;
    }

    /// Test-only: current image path, if any.
    public string currentPathForTesting() const
    {
        return _currentPath;
    }

    /// Test-only: the image canvas widget.
    public ImageView viewForTesting()
    {
        return _view;
    }

    /// Test-only: true once a decode has produced an image.
    public bool imageLoadedForTesting() const
    {
        return _view.hasImage();
    }

    /// Test-only: text of the status label.
    public string statusTextForTesting()
    {
        return to!string(_status.text());
    }
}
