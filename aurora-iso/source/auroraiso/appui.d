/**
 * Aurora ISO user interface.
 *
 * One window with an ISO browser on the left and action panels on the right:
 * image info, extraction, ISO creation, download, and USB preparation.
 * Long operations run on background `Job` threads so the UI stays responsive.
 */
module auroraiso.appui;

import aurora;
import auroraiso.distro;
import auroraiso.download;
import auroraiso.iso;
import auroraiso.job;
import auroraiso.osutil;
import auroraiso.usb;
import std.algorithm : sort;
import std.conv : to;
import std.datetime : Clock;
import std.file : exists, mkdirRecurse, removeFile = remove;
import std.format : format;
import std.path : baseName, buildPath, dirName;
import std.string : endsWith, strip, toLower;
import std.process : environment;

private immutable Color isoMuted = Color.fromHex(0x93a0ac);
private immutable Color isoBorder = Color.fromHex(0x33404c);
private immutable Color isoAccent = Color.fromHex(0x39a0ff);
private immutable Color isoWarn = Color.fromHex(0xffb454);
private immutable Color isoPanel = Color.fromHex(0x181e24);

/// The application root widget.
public final class IsoRoot : VBox
{
    private GuiWindow _window;

    // Browser state.
    private IsoImage _image;
    private string _imagePath;
    private string _currentDir = "/";
    private IsoNode[] _entries;

    // Widgets.
    private ListView _browser;
    private Label _pathLabel;
    private Label _countLabel;
    private Button _upButton;
    private Label _infoVolume;
    private Label _infoFormat;
    private Label _infoBoot;
    private Label _infoSize;
    private TextField _createSource;
    private TextField _createOutput;
    private TextField _createVolume;
    private CheckBox _createJoliet;
    private CheckBox _createRockRidge;
    private TextField _downloadUrl;
    private TextField _downloadDest;
    private ListView _distroList;
    private DistroImage[] _distros;
    private ListView _deviceList;
    private UsbDevice[] _devices;
    private TextField _deviceFs;
    private CheckBox _deviceConfirm;
    private Label _adminLabel;
    private ProgressBar _progress;
    private Label _status;

    private Job _job;
    private IsoDownloader _downloader;
    private ScrollView _sideScroll;
    private VBox _sideColumn;

    this(GuiWindow window)
    {
        super(8, Insets(10));
        _window = window;
        buildUi();
        setStatus("Open an ISO image, create one, or download a Linux distribution.");
        refreshDistros();
        refreshDevices();
        updateInfo();
        setBrowserEnabled(false);
    }

    // ----- UI construction ---------------------------------------------------

    private void buildUi()
    {
        auto toolbar = add(new HBox(8, Insets(6)));
        toolbar.layoutHints().preferredHeight = 52;
        toolbar.setBorder(isoBorder, 6);

        auto title = toolbar.add(new Label("Aurora ISO"));
        title.setScale(2);
        title.setColor(isoAccent);

        auto openButton = toolbar.add(new Button("Open ISO", IconKind.open));
        openButton.setId("iso-open");
        openButton.onClick = delegate() { openIsoDialog(); };

        auto extractButton = toolbar.add(new Button("Extract All", IconKind.save));
        extractButton.setId("iso-extract-all");
        extractButton.onClick = delegate() { extractAllDialog(); };

        auto refreshButton = toolbar.add(new Button("Rescan USB", IconKind.refresh));
        refreshButton.setId("iso-refresh-usb");
        refreshButton.onClick = delegate() { refreshDevices(); };

        toolbar.add(new Spacer());

        _adminLabel = toolbar.add(new Label(""));
        _adminLabel.setScale(1);
        _adminLabel.setColor(isoWarn);

        auto content = add(new HBox(10));
        content.layoutHints().flex = 1.0;

        buildBrowser(content);
        buildSidePanel(content);

        auto statusRow = add(new HBox(8));
        statusRow.layoutHints().preferredHeight = 30;
        _progress = statusRow.add(new ProgressBar(0));
        _progress.layoutHints().preferredWidth = 260;
        _status = statusRow.add(new Label("Ready"));
        _status.setScale(1);
        _status.layoutHints().flex = 1.0;
    }

    private void buildBrowser(Widget parent)
    {
        auto left = parent.add(new VBox(8, Insets(8)));
        left.layoutHints().flex = 1.4;

        auto bar = left.add(new HBox(6));
        bar.layoutHints().preferredHeight = 40;
        _upButton = bar.add(new Button("Up", IconKind.up));
        _upButton.setId("iso-up");
        _upButton.onClick = delegate() { navigateUp(); };
        _pathLabel = bar.add(new Label("/"));
        _pathLabel.setScale(1);
        _pathLabel.layoutHints().flex = 1.0;
        _countLabel = bar.add(new Label(""));
        _countLabel.setScale(1);
        _countLabel.setColor(isoMuted);

        _browser = left.add(new ListView());
        _browser.setId("iso-browser");
        _browser.layoutHints().flex = 1.0;
        _browser.onActivated = delegate(int index) { activateEntry(index); };
        _browser.onSelectionChanged = delegate(int index) { onSelection(index); };
    }

    private void buildSidePanel(Widget parent)
    {
        auto scroll = parent.add(new ScrollView());
        scroll.layoutHints().flex = 1.0;
        scroll.layoutHints().minWidth = 380;
        auto column = new VBox(10, Insets(0));
        scroll.setContent(column);
        _sideScroll = scroll;
        _sideColumn = column;

        // Image info.
        auto info = section(column, "Image");
        _infoVolume = infoLabel(info, "Volume: —");
        _infoFormat = infoLabel(info, "Format: —");
        _infoBoot = infoLabel(info, "Boot: —");
        _infoSize = infoLabel(info, "Size: —");

        // Extraction.
        auto extract = section(column, "Extract & Open");
        auto extractRow = extract.add(new HBox(6));
        extractRow.layoutHints().preferredHeight = 40;
        auto allButton = extractRow.add(new Button("Extract All…", IconKind.save));
        allButton.onClick = delegate() { extractAllDialog(); };
        auto selectedButton = extractRow.add(new Button("Extract Selected…", IconKind.file));
        selectedButton.onClick = delegate() { extractSelectedDialog(); };
        infoLabel(extract, "Tip: double-click a file to extract and open it.");

        // Create.
        auto create = section(column, "Create ISO from Folder");
        _createSource = fieldWithBrowse(create, "Source folder", delegate() {
            showFileDialog(this, folderOptions("Select source folder"),
                delegate(string path) { _createSource.setText(path); });
        });
        _createOutput = fieldWithBrowse(create, "Output .iso", delegate() {
            showFileDialog(this, saveOptions("Save ISO as", "new-image.iso",
                downloadsDirectory()), delegate(string path) { _createOutput.setText(path); });
        });
        _createVolume = new TextField("AURORA_ISO");
        _createVolume.layoutHints().preferredHeight = 36;
        create.add(_createVolume);
        auto createChecks = create.add(new HBox(12));
        createChecks.layoutHints().preferredHeight = 34;
        _createJoliet = createChecks.add(new CheckBox("Joliet", true));
        _createRockRidge = createChecks.add(new CheckBox("Rock Ridge", true));
        auto createRow = create.add(new HBox(6));
        createRow.layoutHints().preferredHeight = 40;
        auto createButton = createRow.add(new Button("Create ISO", IconKind.newDocument));
        createButton.onClick = delegate() { startCreate(); };

        // Official distributions.
        auto distros = section(column, "Official Distributions");
        _distroList = distros.add(new ListView());
        _distroList.layoutHints().preferredHeight = 170;
        _distroList.onSelectionChanged = delegate(int index) { previewDistro(index); };
        _distroList.onActivated = delegate(int index) {
            useDistro(index);
            startDownload();
        };
        auto distroRow = distros.add(new HBox(6));
        distroRow.layoutHints().preferredHeight = 40;
        auto useButton = distroRow.add(new Button("Use in Download", IconKind.save));
        useButton.setId("iso-distro-use");
        useButton.onClick = delegate() { useDistro(_distroList.selectedIndex()); };
        auto distroDownload = distroRow.add(new Button("Download Now", IconKind.search));
        distroDownload.setId("iso-distro-download");
        distroDownload.onClick = delegate() {
            useDistro(_distroList.selectedIndex());
            startDownload();
        };
        infoLabel(distros, "Official Ubuntu and Fedora images from their release servers.");

        // Download.
        auto download = section(column, "Download ISO");
        _downloadUrl = new TextField("");
        _downloadUrl.setPlaceholder("https://releases.ubuntu.com/… .iso");
        _downloadUrl.layoutHints().preferredHeight = 36;
        download.add(_downloadUrl);
        _downloadDest = fieldWithBrowse(download, "Save to", delegate() {
            showFileDialog(this, saveOptions("Save download as", "download.iso",
                downloadsDirectory()), delegate(string path) { _downloadDest.setText(path); });
        });
        auto downloadRow = download.add(new HBox(6));
        downloadRow.layoutHints().preferredHeight = 40;
        auto downloadButton = downloadRow.add(new Button("Download", IconKind.search));
        downloadButton.onClick = delegate() { startDownload(); };
        auto cancelDownload = downloadRow.add(new Button("Cancel", IconKind.close));
        cancelDownload.onClick = delegate() {
            if (_downloader !is null) _downloader.cancel();
        };

        // USB.
        auto usb = section(column, "USB / Linux Installer");
        _deviceList = usb.add(new ListView());
        _deviceList.layoutHints().preferredHeight = 150;
        auto deviceRow = usb.add(new HBox(6));
        deviceRow.layoutHints().preferredHeight = 40;
        auto rawButton = deviceRow.add(new Button("Write Image (dd)", IconKind.drive));
        rawButton.onClick = delegate() { startRawWrite(); };
        auto copyButton = deviceRow.add(new Button("Format + Copy", IconKind.folder));
        copyButton.onClick = delegate() { startFormatCopy(); };
        auto formatOnly = deviceRow.add(new Button("Format Only", IconKind.settings));
        formatOnly.onClick = delegate() { startFormatOnly(); };
        auto fsRow = usb.add(new HBox(8));
        fsRow.layoutHints().preferredHeight = 36;
        auto fsLabel = fsRow.add(new Label("Filesystem"));
        fsLabel.setScale(1);
        _deviceFs = fsRow.add(new TextField("FAT32"));
        _deviceFs.layoutHints().preferredHeight = 36;
        _deviceFs.layoutHints().preferredWidth = 120;
        _deviceConfirm = new CheckBox("I understand this erases the selected USB drive", false);
        usb.add(_deviceConfirm);
        auto refreshUsb = usb.add(new Button("Rescan USB devices", IconKind.refresh));
        refreshUsb.onClick = delegate() { refreshDevices(); };

        finalizeSection(info);
        finalizeSection(extract);
        finalizeSection(create);
        finalizeSection(distros);
        finalizeSection(download);
        finalizeSection(usb);
        column.add(new Spacer(0));
    }

    private VBox section(Widget parent, string title)
    {
        auto box = parent.add(new VBox(6, Insets(10)));
        box.setBackground(isoPanel);
        box.setBorder(isoBorder, 6);
        auto header = box.add(new Label(title));
        header.setScale(1);
        header.setColor(isoAccent);
        return box;
    }

    /**
     * Box layout uses each child's layout hints, not its measured intrinsic
     * size, so a nested section box must publish an explicit preferred height
     * or it collapses to zero. Sum the children's preferred heights here.
     */
    private void finalizeSection(VBox box)
    {
        int height = box.padding().top + box.padding().bottom;
        int count = 0;
        foreach (child; box.children())
        {
            if (child is null || !child.visible())
                continue;
            auto hints = child.layoutHints();
            height += hints.preferredHeight >= 0 ? hints.preferredHeight : hints.minHeight;
            ++count;
        }
        if (count > 1)
            height += box.spacing() * (count - 1);
        box.layoutHints().preferredHeight = height;
    }

    private Label infoLabel(Widget parent, string text)
    {
        auto label = parent.add(new Label(text));
        label.setScale(1);
        label.setEllipsis(false);
        return label;
    }

    private TextField fieldWithBrowse(Widget parent, string placeholder,
        void delegate() onBrowse)
    {
        auto row = parent.add(new HBox(6));
        row.layoutHints().preferredHeight = 40;
        auto field = row.add(new TextField(""));
        field.setPlaceholder(placeholder);
        field.layoutHints().flex = 1.0;
        field.layoutHints().preferredHeight = 36;
        auto browse = row.add(new Button("…", IconKind.folder));
        browse.onClick = delegate() { onBrowse(); };
        return field;
    }

    private FileDialogOptions folderOptions(string title)
    {
        FileDialogOptions options;
        options.mode = FileDialogMode.open;
        options.title = title;
        options.acceptLabel = "Select";
        options.selectFolders = true;
        options.initialPath = _imagePath.length > 0 ? dirName(_imagePath) : downloadsDirectory();
        return options;
    }

    private FileDialogOptions saveOptions(string title, string defaultName, string initialPath)
    {
        FileDialogOptions options;
        options.mode = FileDialogMode.save;
        options.title = title;
        options.defaultFileName = defaultName;
        options.acceptLabel = "Save";
        options.initialPath = initialPath;
        return options;
    }

    // ----- ISO loading -------------------------------------------------------

    private void openIsoDialog()
    {
        FileDialogOptions options;
        options.mode = FileDialogMode.open;
        options.title = "Open ISO image";
        options.acceptLabel = "Open";
        options.initialPath = _imagePath.length > 0 ? dirName(_imagePath) : downloadsDirectory();
        showFileDialog(this, options, delegate(string path) { loadIso(path); });
    }

    /// Load an image and reset the browser to its root directory.
    public void loadIso(string path)
    {
        try
        {
            if (_image !is null)
            {
                _image.close();
                _image = null;
            }
            _image = new IsoImage(path);
            _imagePath = path;
            _currentDir = "/";
            setBrowserEnabled(true);
            refreshBrowser();
            updateInfo();
            _window.setTitle(baseName(path) ~ " — Aurora ISO");
            setStatus(format("Opened %s (%s)", baseName(path),
                formatSize(_image.volumeSizeBytes())));
        }
        catch (Exception error)
        {
            setStatus("Open failed: " ~ error.msg);
        }
    }

    private void refreshBrowser()
    {
        _entries = [];
        if (_image is null)
        {
            _browser.clear();
            _pathLabel.setText("/");
            _countLabel.setText("");
            return;
        }
        try
        {
            _entries = _image.list(_currentDir).dup;
        }
        catch (Exception error)
        {
            setStatus("Cannot list " ~ _currentDir ~ ": " ~ error.msg);
            _entries = [];
        }
        sort!((a, b) => a.isDirectory != b.isDirectory ? a.isDirectory :
            a.name.toLower < b.name.toLower)(_entries);

        ListItem[] items;
        foreach (entry; _entries)
        {
            auto icon = entry.isDirectory ? IconKind.folder : IconKind.file;
            auto secondary = entry.isDirectory ? "Directory" :
                formatPipe(entry);
            items ~= ListItem(entry.name, icon, secondary);
        }
        _browser.setItems(items);
        _pathLabel.setText(_currentDir);
        _countLabel.setText(format("%d items", _entries.length));
    }

    private string formatPipe(IsoNode entry)
    {
        string text = formatSize(entry.size);
        if (entry.isSymlink)
            text ~= "  → " ~ entry.linkTarget;
        return text;
    }

    private void navigateUp()
    {
        if (_image is null || _currentDir == "/")
            return;
        auto parent = dirName(_currentDir);
        if (parent.length == 0)
            parent = "/";
        _currentDir = parent;
        refreshBrowser();
    }

    private void activateEntry(int index)
    {
        if (index < 0 || index >= cast(int) _entries.length)
            return;
        auto entry = _entries[cast(size_t) index];
        if (entry.isDirectory)
        {
            _currentDir = entry.path;
            refreshBrowser();
        }
        else
        {
            openEntry(entry);
        }
    }

    private void onSelection(int index)
    {
        if (index < 0 || index >= cast(int) _entries.length)
            return;
        auto entry = _entries[cast(size_t) index];
        setStatus(entry.path ~ (entry.isDirectory ? "  (directory)" :
            format("  (%s)", formatSize(entry.size))));
    }

    private void openEntry(IsoNode entry)
    {
        if (_job !is null)
        {
            setStatus("Another operation is running.");
            return;
        }
        mkdirRecurse(workingDirectory());
        auto destination = buildPath(workingDirectory(), baseName(entry.name));
        auto image = _image;
        auto path = entry.path;
        _job = new Job("Open " ~ entry.name, delegate() {
            if (_job.cancelled()) return;
            _job.report(0.2, "Extracting " ~ entry.name);
            extractFile(image, path, destination);
            _job.report(1.0, "Opening " ~ entry.name);
            openPathWithShell(destination);
        });
        _job.start();
    }

    // ----- Extraction --------------------------------------------------------

    private void extractAllDialog()
    {
        if (!requireImage()) return;
        FileDialogOptions options = folderOptions("Choose extraction folder");
        showFileDialog(this, options, delegate(string path) { startExtractAll(path); });
    }

    private void startExtractAll(string destination)
    {
        if (_job !is null)
        {
            setStatus("Another operation is running.");
            return;
        }
        auto image = _image;
        auto total = image.walk("/", false).length;
        _job = new Job("Extract all", delegate() {
            mkdirRecurse(destination);
            uint done;
            auto stats = extractAll(image, destination,
                delegate(string current) {
                    ++done;
                    _job.report(total == 0 ? 1.0 : cast(double) done / total,
                        "Extracting " ~ current);
                },
                delegate() { return _job.cancelled(); });
            _job.report(1.0, format("Extracted %d files", stats.files));
        });
        _job.start();
    }

    private void extractSelectedDialog()
    {
        if (!requireImage()) return;
        const index = _browser.selectedIndex();
        if (index < 0 || index >= cast(int) _entries.length)
        {
            setStatus("Select a file to extract.");
            return;
        }
        auto entry = _entries[cast(size_t) index];
        auto defaultName = baseName(entry.name);
        showFileDialog(this, saveOptions("Extract file as", defaultName,
            downloadsDirectory()), delegate(string path) {
                startExtractOne(entry, path);
            });
    }

    private void startExtractOne(IsoNode entry, string destination)
    {
        if (_job !is null)
        {
            setStatus("Another operation is running.");
            return;
        }
        auto image = _image;
        auto imagePath = entry.path;
        _job = new Job("Extract " ~ entry.name, delegate() {
            _job.report(0.3, "Extracting " ~ entry.name);
            extractFile(image, imagePath, destination);
            _job.report(1.0, "Saved " ~ destination);
        });
        _job.start();
    }

    // ----- Creation ----------------------------------------------------------

    private void startCreate()
    {
        if (_job !is null)
        {
            setStatus("Another operation is running.");
            return;
        }
        auto source = _createSource.textUtf8().strip;
        auto output = _createOutput.textUtf8().strip;
        if (source.length == 0 || !exists(source))
        {
            setStatus("Choose a source folder that exists.");
            return;
        }
        if (output.length == 0)
        {
            setStatus("Choose an output .iso path.");
            return;
        }
        IsoWriterOptions options;
        options.volumeId = _createVolume.textUtf8().strip.length > 0 ?
            _createVolume.textUtf8().strip : "AURORA_ISO";
        options.joliet = _createJoliet.checked();
        options.rockRidge = _createRockRidge.checked();
        if (exists(output))
            removeFile(output);

        _job = new Job("Create ISO", delegate() {
            _job.report(0.0, "Scanning " ~ source);
            auto result = createIsoFromDirectory(source, output, options,
                delegate(double fraction) {
                    _job.report(fraction, format("Writing image… %d%%",
                        cast(int)(fraction * 100)));
                },
                delegate() { return _job.cancelled(); });
            if (!result.ok)
                throw new Exception(result.error);
            _job.report(1.0, format("Created %s (%s)", baseName(output),
                formatSize(result.bytesWritten)));
        });
        _job.start();
    }

    // ----- Download ----------------------------------------------------------

    private void startDownload()
    {
        if (_downloader !is null && _downloader.running())
        {
            setStatus("A download is already running.");
            return;
        }
        auto url = _downloadUrl.textUtf8().strip;
        if (url.length == 0)
        {
            setStatus("Enter an ISO URL to download.");
            return;
        }
        auto destination = _downloadDest.textUtf8().strip;
        if (destination.length == 0)
        {
            try
            {
                destination = buildPath(downloadsDirectory(),
                    baseName(parseUrl(url).target));
            }
            catch (Exception error)
            {
                setStatus("Bad URL: " ~ error.msg);
                return;
            }
            _downloadDest.setText(destination);
        }
        try
        {
            _downloader = new IsoDownloader();
            _downloader.start(url, destination, true);
            setStatus("Downloading " ~ baseName(destination));
        }
        catch (Exception error)
        {
            setStatus("Download failed: " ~ error.msg);
            _downloader = null;
        }
    }

    // ----- Official distributions -------------------------------------------

    private void refreshDistros()
    {
        _distros = officialImages();
        ListItem[] items;
        foreach (image; _distros)
        {
            string secondary = image.vendor ~ " · " ~ image.edition;
            if (image.approxBytes > 0)
                secondary ~= "  ·  ~" ~ formatSize(image.approxBytes);
            items ~= ListItem(image.name, IconKind.drive, secondary);
        }
        _distroList.setItems(items);
    }

    private void previewDistro(int index)
    {
        if (index < 0 || index >= cast(int) _distros.length)
            return;
        auto image = _distros[cast(size_t) index];
        setStatus(image.vendor ~ " " ~ image.edition ~ " — " ~ image.url);
    }

    private void useDistro(int index)
    {
        if (index < 0 || index >= cast(int) _distros.length)
        {
            setStatus("Select a distribution first.");
            return;
        }
        auto image = _distros[cast(size_t) index];
        _downloadUrl.setText(image.url);
        _downloadDest.setText(buildPath(downloadsDirectory(), baseName(image.url)));
        setStatus("Selected " ~ image.name ~ ". Press Download to fetch it.");
    }

    // ----- USB ---------------------------------------------------------------

    private void refreshDevices()
    {
        _devices = usbDevices();
        ListItem[] items;
        foreach (device; _devices)
            items ~= ListItem(device.displayName(), IconKind.drive,
                device.hasDiskNumber
                    ? (device.model.length > 0 ? device.model : device.devicePath)
                    : "disk number unknown");
        _deviceList.setItems(items);
        if (hasRawDiskAccess())
            _adminLabel.setText("");
        else
            _adminLabel.setText("Administrator rights required to write to USB.");
        if (_devices.length == 0)
            setStatus("No removable USB drives detected.");
    }

    private UsbDevice* selectedDevice()
    {
        const index = _deviceList.selectedIndex();
        if (index < 0 || index >= cast(int) _devices.length)
            return null;
        return &_devices[cast(size_t) index];
    }

    private bool requireImage()
    {
        if (_image is null)
        {
            setStatus("Open or download an ISO image first.");
            return false;
        }
        return true;
    }

    private bool confirmErase()
    {
        if (!_deviceConfirm.checked())
        {
            setStatus("Tick the confirmation box before writing to a USB drive.");
            return false;
        }
        return true;
    }

    private void startRawWrite()
    {
        if (_job !is null)
        {
            setStatus("Another operation is running.");
            return;
        }
        if (!requireImage()) return;
        if (!confirmErase()) return;
        auto device = selectedDevice();
        if (device is null)
        {
            setStatus("Select a USB device first.");
            return;
        }
        if (!device.hasDiskNumber)
        {
            setStatus("Cannot resolve the physical disk for this drive.");
            return;
        }
        auto imagePath = _imagePath;
        const diskNumber = device.diskNumber;
        const label = device.displayName();
        _job = new Job("Write image to USB", delegate() {
            _job.report(0.0, "Preparing " ~ label);
            auto written = writeImageToPhysicalDrive(imagePath, diskNumber,
                delegate(DeviceProgress progress) {
                    _job.report(progress.fraction, progress.message);
                },
                delegate() { return _job.cancelled(); });
            _job.report(1.0, format("Wrote %s to %s", formatSize(written), label));
        });
        _job.start();
    }

    private void startFormatOnly()
    {
        if (!confirmErase()) return;
        auto device = selectedDevice();
        if (device is null)
        {
            setStatus("Select a USB device first.");
            return;
        }
        auto fs = _deviceFs.textUtf8().strip.length > 0 ?
            _deviceFs.textUtf8().strip : "FAT32";
        const letter = device.letter;
        _job = new Job("Format USB", delegate() {
            _job.report(0.2, format("Formatting %c: as %s", letter, fs));
            const ok = formatVolume(letter, fs, "AURORA-USB", true);
            if (!ok)
                throw new Exception("Format failed (administrator rights required)");
            _job.report(1.0, format("Formatted %c: as %s", letter, fs));
        });
        _job.start();
    }

    private void startFormatCopy()
    {
        if (!requireImage()) return;
        if (!confirmErase()) return;
        auto device = selectedDevice();
        if (device is null)
        {
            setStatus("Select a USB device first.");
            return;
        }
        auto fs = _deviceFs.textUtf8().strip.length > 0 ?
            _deviceFs.textUtf8().strip : "FAT32";
        const letter = device.letter;
        auto image = _image;
        auto root = format("%c:\\", letter);
        _job = new Job("Format and copy to USB", delegate() {
            _job.report(0.1, format("Formatting %c: as %s", letter, fs));
            if (!formatVolume(letter, fs, "AURORA-USB", true))
                throw new Exception("Format failed (administrator rights required)");
            _job.report(0.2, "Copying image contents…");
            auto files = image.walk("/", false).length;
            uint done;
            extractAll(image, root,
                delegate(string current) {
                    ++done;
                    _job.report(0.2 + 0.8 * (files == 0 ? 1.0 :
                        cast(double) done / files), "Copying " ~ current);
                },
                delegate() { return _job.cancelled(); });
            _job.report(1.0, format("Copied image to %c:", letter));
        });
        _job.start();
    }

    // ----- Info & status -----------------------------------------------------

    private void updateInfo()
    {
        if (_image is null)
        {
            _infoVolume.setText("Volume: —");
            _infoFormat.setText("Format: —");
            _infoBoot.setText("Boot: —");
            _infoSize.setText("Size: —");
            return;
        }
        _infoVolume.setText("Volume: " ~ (_image.volumeId().length > 0 ?
            _image.volumeId() : "(none)"));
        string formatText = "ISO 9660";
        if (_image.hasJoliet()) formatText ~= " + Joliet";
        if (_image.hasRockRidge()) formatText ~= " + Rock Ridge";
        _infoFormat.setText("Format: " ~ formatText);
        if (_image.isBootable())
        {
            auto torito = _image.elTorito();
            _infoBoot.setText("Boot: El Torito (" ~ torito.platform ~ ")");
        }
        else
        {
            _infoBoot.setText("Boot: not bootable");
        }
        _infoSize.setText(format("Size: %s (%d blocks)",
            formatSize(_image.volumeSizeBytes()), _image.volumeSpaceSectors()));
    }

    private void setBrowserEnabled(bool enabled)
    {
        _upButton.setEnabled(enabled);
        _browser.setEnabled(enabled);
    }

    private void setStatus(string text)
    {
        _status.setText(text);
    }

    protected override void onTick(double deltaSeconds)
    {
        super.onTick(deltaSeconds);
        pollJob();
        pollDownload();
    }

    private void pollJob()
    {
        if (_job is null)
            return;
        _progress.setValue(_job.progress());
        auto message = _job.message();
        if (message.length > 0)
            setStatus(message);
        if (!_job.done())
            return;
        if (_job.failed())
        {
            if (_job.error() == "cancelled")
                setStatus("Operation cancelled.");
            else
                setStatus("Failed: " ~ _job.error());
        }
        else
        {
            setStatus(_job.title() ~ " complete.");
        }
        _job = null;
        if (_image !is null && _currentDir.length > 0)
            refreshBrowser();
    }

    private void pollDownload()
    {
        if (_downloader is null)
            return;
        auto snap = _downloader.snapshot();
        if (snap.total > 0)
            _progress.setValue(snap.fraction());
        setStatus(format("Downloading %s / %s",
            formatSize(snap.received),
            snap.total > 0 ? formatSize(snap.total) : "?"));
        if (snap.active)
            return;
        if (snap.failed && !snap.cancelled)
            setStatus("Download failed: " ~ snap.error);
        else if (snap.cancelled)
            setStatus("Download cancelled.");
        else
        {
            setStatus("Download complete: " ~ baseName(snap.destination));
            loadIso(snap.destination);
        }
        _downloader = null;
    }

    // ----- Input -------------------------------------------------------------

    override bool onKeyDown(ref Event event)
    {
        if ((event.control() || event.meta()) && event.key == Key.o)
        {
            openIsoDialog();
            return true;
        }
        if ((event.control() || event.meta()) && event.key == Key.r)
        {
            refreshDevices();
            return true;
        }
        return false;
    }

    override bool onFilesDropped(ref Event event)
    {
        foreach (path; event.paths)
        {
            if (path.toLower.endsWith(".iso"))
            {
                loadIso(path);
                return true;
            }
        }
        return false;
    }

    // ----- Testing hooks -----------------------------------------------------

    /// Test-only: load an image and return true on success.
    public bool loadForTesting(string path)
    {
        loadIso(path);
        return _image !is null;
    }

    /// Test-only: true once an image is open.
    public bool imageLoadedForTesting() const
    {
        return _image !is null;
    }

    /// Test-only: current status text.
    public string statusTextForTesting()
    {
        return _status.text().to!string;
    }

    /// Test-only: number of browser entries.
    public int browserCountForTesting() const
    {
        return cast(int) _entries.length;
    }

    /// Test-only: side panel child count.
    public int sideChildCountForTesting() const
    {
        return _sideColumn is null ? -1 : cast(int) _sideColumn.children().length;
    }

    /// Test-only: side scroll view bounds.
    public Rect sideScrollBoundsForTesting()
    {
        return _sideScroll is null ? Rect.init : _sideScroll.bounds();
    }

    /// Test-only: number of catalog entries.
    public int distroCountForTesting() const
    {
        return cast(int) _distros.length;
    }

    /// Test-only: select a catalog entry as if the user clicked it.
    public void selectDistroForTesting(int index)
    {
        useDistro(index);
    }

    /// Test-only: current download URL field text.
    public string downloadUrlForTesting()
    {
        return _downloadUrl.textUtf8();
    }

    /// Test-only: side content first section bounds.
    public Rect firstSectionBoundsForTesting()
    {
        if (_sideColumn is null || _sideColumn.children().length == 0)
            return Rect.init;
        return _sideColumn.children()[0].bounds();
    }

    /// Test-only: first child of the first section.
    public Rect firstSectionChildBoundsForTesting()
    {
        if (_sideColumn is null || _sideColumn.children().length == 0)
            return Rect.init;
        auto section = _sideColumn.children()[0];
        if (section.children().length == 0)
            return Rect.init;
        return section.children()[0].bounds();
    }

    /// Test-only: side content bounds.
    public Rect sideContentBoundsForTesting()
    {
        return _sideColumn is null ? Rect.init : _sideColumn.bounds();
    }

    /// Test-only: current image (may be null).
    public IsoImage imageForTesting()
    {
        return _image;
    }
}
