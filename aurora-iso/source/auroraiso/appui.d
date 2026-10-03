/**
 * Aurora ISO user interface.
 *
 * The default view is deliberately minimal: pick a distribution, pick a USB
 * drive, press one button. That single action downloads the official ISO when
 * it is not cached locally, then writes the image to the physical drive (which
 * gives the stick the installer's own filesystem and boot loader).
 *
 * Everything else (browse/extract an ISO, build an ISO, custom download,
 * format-only, copy-files) lives behind the "Advanced" toggle.
 */
module auroraiso.appui;

import aurora;
import auroraiso.disk : LayoutOptions;
import auroraiso.distro;
import auroraiso.download;
import auroraiso.installflow;
import auroraiso.iso;
import auroraiso.job;
import auroraiso.logging;
import auroraiso.osutil;
import auroraiso.usb;
import std.algorithm : sort;
import std.conv : to;
import std.file : exists, getSize, mkdirRecurse, removeFile = remove;
import std.format : format;
import std.path : baseName, buildPath, dirName;
import std.string : endsWith, strip, toLower;

private immutable Color isoMuted = Color.fromHex(0x93a0ac);
private immutable Color isoBorder = Color.fromHex(0x33404c);
private immutable Color isoAccent = Color.fromHex(0x39a0ff);
private immutable Color isoWarn = Color.fromHex(0xffb454);
private immutable Color isoPanel = Color.fromHex(0x181e24);

/// Where the one-button install flow currently is.
enum InstallPhase
{
    idle,
    downloading,
    installing
}

/// The application root widget.
public final class IsoRoot : VBox
{
    private GuiWindow _window;

    // Browser state (advanced view).
    private IsoImage _image;
    private string _imagePath;
    private string _currentDir = "/";
    private IsoNode[] _entries;

    // Simple install flow.
    private VBox _installCard;
    private VBox _advancedBox;
    private Button _advancedToggle;
    private ListView _distroList;
    private DistroImage[] _distros;
    private ListView _deviceList;
    private UsbDevice[] _devices;
    private CheckBox _deviceConfirm;
    private CheckBox _makeDataPartition;
    private CheckBox _useFromScratchLayout;
    private Button _installButton;
    private Label _wizardStatus;
    private Label _adminLabel;

    // Advanced widgets.
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
    private TextField _deviceFs;
    private ScrollView _sideScroll;
    private VBox _sideColumn;

    // Operations.
    private Job _job;
    private IsoDownloader _downloader;
    private bool _downloadForInstall;
    private InstallPhase _phase = InstallPhase.idle;
    private string _installIso;
    private uint _installDisk;
    private string _installLabel;

    private ProgressBar _progress;
    private Label _status;

    this(GuiWindow window)
    {
        super(10, Insets(12));
        _window = window;
        buildUi();
        refreshDistros();
        refreshDevices();
        updateInfo();
        setBrowserEnabled(false);
        setStatus("Pick a distribution, pick a USB drive, then press Install.");
    }

    // ----- UI construction ---------------------------------------------------

    private void buildUi()
    {
        auto toolbar = add(new HBox(10, Insets(8)));
        toolbar.layoutHints().preferredHeight = 54;
        toolbar.setBorder(isoBorder, 6);

        auto title = toolbar.add(new Label("Aurora ISO"));
        title.setScale(2);
        title.setColor(isoAccent);

        auto openButton = toolbar.add(new Button("Open ISO", IconKind.open));
        openButton.setId("iso-open");
        openButton.onClick = delegate() { openIsoDialog(); };

        auto refreshButton = toolbar.add(new Button("Rescan USB", IconKind.refresh));
        refreshButton.setId("iso-refresh-usb");
        refreshButton.onClick = delegate() { refreshDevices(); };

        toolbar.add(new Spacer());

        _adminLabel = toolbar.add(new Label(""));
        _adminLabel.setScale(1);
        _adminLabel.setColor(isoWarn);

        _advancedToggle = toolbar.add(new Button("Advanced", IconKind.settings));
        _advancedToggle.setId("iso-advanced");
        _advancedToggle.onClick = delegate() { toggleAdvanced(); };

        auto stack = add(new VBox(0));
        stack.layoutHints().flex = 1.0;
        _installCard = buildInstallCard(stack);
        _advancedBox = buildAdvanced(stack);
        _advancedBox.setVisible(false);

        auto statusRow = add(new HBox(8));
        statusRow.layoutHints().preferredHeight = 30;
        _progress = statusRow.add(new ProgressBar(0));
        _progress.layoutHints().preferredWidth = 240;
        _status = statusRow.add(new Label("Ready"));
        _status.setScale(1);
        _status.layoutHints().flex = 1.0;
    }

    private VBox buildInstallCard(Widget parent)
    {
        auto card = parent.add(new VBox(10, Insets(16)));
        card.layoutHints().flex = 1.0;
        card.setBorder(isoBorder, 8);

        auto header = card.add(new Label("Install Linux to USB"));
        header.setScale(3);
        header.setColor(isoAccent);
        auto subtitle = card.add(new Label(
            "Choose a distribution and a USB drive, then press one button."));
        subtitle.setScale(1);
        subtitle.setColor(isoMuted);

        auto step1Row = card.add(new HBox(8));
        step1Row.layoutHints().preferredHeight = 30;
        auto step1 = step1Row.add(new Label("1 · Distribution"));
        step1.setScale(1);
        step1.setColor(isoAccent);
        step1Row.add(new Spacer());
        auto deleteDownload = step1Row.add(new Button("Delete download", IconKind.close));
        deleteDownload.setId("iso-distro-delete");
        deleteDownload.onClick = delegate() { deleteDistroDownload(); };
        _distroList = card.add(new ListView());
        _distroList.setId("iso-distros");
        _distroList.layoutHints().flex = 1.0;
        _distroList.layoutHints().minHeight = 120;
        _distroList.onSelectionChanged = delegate(int index) { previewDistro(index); };

        auto step2Row = card.add(new HBox(8));
        step2Row.layoutHints().preferredHeight = 30;
        auto step2 = step2Row.add(new Label("2 · USB drive"));
        step2.setScale(1);
        step2.setColor(isoAccent);
        step2Row.add(new Spacer());
        auto rescan = step2Row.add(new Button("Rescan", IconKind.refresh));
        rescan.onClick = delegate() { refreshDevices(); };
        _deviceList = card.add(new ListView());
        _deviceList.setId("iso-devices");
        _deviceList.layoutHints().flex = 1.0;
        _deviceList.layoutHints().minHeight = 100;

        _deviceConfirm = card.add(new CheckBox(
            "Erase and overwrite the selected USB drive", false));
        _deviceConfirm.setId("iso-confirm");
        _deviceConfirm.layoutHints().preferredHeight = 32;

        _makeDataPartition = card.add(new CheckBox(
            "Use leftover space as a data partition (exFAT)", true));
        _makeDataPartition.setId("iso-data-partition");
        _makeDataPartition.layoutHints().preferredHeight = 32;

        _useFromScratchLayout = card.add(new CheckBox(
            "Experimental: build partitions from scratch (no raw copy)", false));
        _useFromScratchLayout.setId("iso-from-scratch");
        _useFromScratchLayout.layoutHints().preferredHeight = 32;

        _installButton = card.add(new Button("Download & Install to USB", IconKind.drive));
        _installButton.setId("iso-install");
        _installButton.layoutHints().preferredHeight = 52;
        _installButton.onClick = delegate() { startInstall(); };

        _wizardStatus = card.add(new Label(""));
        _wizardStatus.setScale(1);
        _wizardStatus.setColor(isoMuted);

        return card;
    }

    private VBox buildAdvanced(Widget parent)
    {
        auto box = parent.add(new VBox(0));
        box.layoutHints().flex = 1.0;
        auto content = box.add(new HBox(10));
        content.layoutHints().flex = 1.0;
        buildBrowser(content);
        buildSidePanel(content);
        return box;
    }

    private void toggleAdvanced()
    {
        const show = !_advancedBox.visible();
        _advancedBox.setVisible(show);
        _installCard.setVisible(!show);
        _advancedToggle.setText(show ? "Simple" : "Advanced");
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

        auto info = section(column, "Image");
        _infoVolume = infoLabel(info, "Volume: —");
        _infoFormat = infoLabel(info, "Format: —");
        _infoBoot = infoLabel(info, "Boot: —");
        _infoSize = infoLabel(info, "Size: —");

        auto extract = section(column, "Extract & Open");
        auto extractRow = extract.add(new HBox(6));
        extractRow.layoutHints().preferredHeight = 40;
        auto allButton = extractRow.add(new Button("Extract All…", IconKind.save));
        allButton.onClick = delegate() { extractAllDialog(); };
        auto selectedButton = extractRow.add(new Button("Extract Selected…", IconKind.file));
        selectedButton.onClick = delegate() { extractSelectedDialog(); };
        infoLabel(extract, "Double-click a file to extract and open it.");

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

        auto download = section(column, "Custom Download");
        _downloadUrl = new TextField("");
        _downloadUrl.setPlaceholder("https://… .iso");
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

        auto usb = section(column, "Advanced USB");
        infoLabel(usb, "Uses the USB drive selected in the main view.");
        auto fsRow = usb.add(new HBox(8));
        fsRow.layoutHints().preferredHeight = 36;
        auto fsLabel = fsRow.add(new Label("Filesystem"));
        fsLabel.setScale(1);
        _deviceFs = fsRow.add(new TextField("FAT32"));
        _deviceFs.layoutHints().preferredHeight = 36;
        _deviceFs.layoutHints().preferredWidth = 120;
        auto usbRow = usb.add(new HBox(6));
        usbRow.layoutHints().preferredHeight = 40;
        auto rawButton = usbRow.add(new Button("Write Image (dd)", IconKind.drive));
        rawButton.onClick = delegate() { startRawWrite(); };
        auto formatOnly = usbRow.add(new Button("Format Only", IconKind.settings));
        formatOnly.onClick = delegate() { startFormatOnly(); };
        auto copyButton = usbRow.add(new Button("Format + Copy", IconKind.folder));
        copyButton.onClick = delegate() { startFormatCopy(); };
        auto noAdminRow = usb.add(new HBox(6));
        noAdminRow.layoutHints().preferredHeight = 40;
        auto noAdminButton = noAdminRow.add(new Button("Copy Files (no admin)", IconKind.file));
        noAdminButton.onClick = delegate() { startCopyFilesNoAdmin(); };

        finalizeSection(info);
        finalizeSection(extract);
        finalizeSection(create);
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
     * or it collapses to zero.
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

    // ----- Official distribution catalog -------------------------------------

    private void refreshDistros()
    {
        _distros = officialImages();
        ListItem[] items;
        foreach (image; _distros)
        {
            string secondary = image.vendor ~ " · " ~ image.edition;
            if (image.approxBytes > 0)
                secondary ~= "  ·  ~" ~ formatSize(image.approxBytes);
            if (distroCached(image))
                secondary ~= "  ·  downloaded";
            items ~= ListItem(image.name, IconKind.drive, secondary);
        }
        _distroList.setItems(items);
    }

    /// Local path where an official image is cached after download.
    private string distroCachePath(DistroImage image)
    {
        return buildPath(downloadsDirectory(), baseName(image.url));
    }

    /// True when the image is already downloaded and non-empty.
    private bool distroCached(DistroImage image)
    {
        auto path = distroCachePath(image);
        return exists(path) && getSize(path) > 0;
    }

    /// Delete the selected distribution's downloaded ISO (and any partial file).
    private void deleteDistroDownload()
    {
        const index = _distroList.selectedIndex();
        if (index < 0 || index >= cast(int) _distros.length)
        {
            setStatus("Select a distribution first.");
            return;
        }
        auto image = _distros[cast(size_t) index];
        auto path = distroCachePath(image);
        bool removed = false;
        if (exists(path))
        {
            removeFile(path);
            removed = true;
        }
        if (exists(path ~ ".part"))
        {
            removeFile(path ~ ".part");
            removed = true;
        }
        refreshDistros();
        _distroList.setSelectedIndex(index);
        setStatus(removed ? ("Deleted " ~ baseName(path)) :
            "Nothing downloaded for this entry.");
    }

    private void previewDistro(int index)
    {
        if (index < 0 || index >= cast(int) _distros.length)
            return;
        auto image = _distros[cast(size_t) index];
        setStatus(image.name ~ " — " ~ image.url);
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
        setStatus("Selected " ~ image.name ~ ".");
    }

    // ----- One-button install flow -------------------------------------------

    private void startInstall()
    {
        if (_phase != InstallPhase.idle || _job !is null)
        {
            setStatus("An operation is already running.");
            return;
        }
        const distroIndex = _distroList.selectedIndex();
        if (distroIndex < 0 || distroIndex >= cast(int) _distros.length)
        {
            setStatus("Choose a distribution first.");
            return;
        }
        auto device = selectedDevice();
        if (device is null)
        {
            setStatus("Choose a USB drive first.");
            return;
        }
        if (!device.hasDiskNumber)
        {
            setStatus("Cannot resolve the physical disk for this drive.");
            return;
        }
        if (!_deviceConfirm.checked())
        {
            setStatus("Tick the confirmation box to allow erasing the USB drive.");
            return;
        }
        if (!hasAdminRights())
        {
            requestElevation(distroIndex, device.diskNumber);
            return;
        }

        auto image = _distros[cast(size_t) distroIndex];
        _installIso = buildPath(downloadsDirectory(), baseName(image.url));
        _installDisk = device.diskNumber;
        _installLabel = device.displayName();
        logInfo(format("startInstall: distro='%s' disk=%d iso='%s' cached=%s",
            image.name, _installDisk, _installIso, distroCached(image)));
        _downloadUrl.setText(image.url);
        _downloadDest.setText(_installIso);

        const cacheExists = exists(_installIso);
        const cacheSize = cacheExists ? getSize(_installIso) : 0;
        if (firstInstallStep(cacheExists, cacheSize) == InstallStep.writeExisting)
        {
            setStatus("Already downloaded — reusing " ~ baseName(_installIso));
            beginInstallWrite();
            return;
        }
        try
        {
            _downloader = new IsoDownloader();
            _downloader.start(image.url, _installIso, true);
            _downloadForInstall = true;
            _phase = InstallPhase.downloading;
            setStatus("Downloading " ~ baseName(_installIso) ~ " …");
        }
        catch (Exception error)
        {
            setStatus("Download failed: " ~ error.msg);
            _downloader = null;
        }
    }

    private void beginInstallWrite()
    {
        _phase = InstallPhase.installing;
        auto iso = _installIso;
        auto disk = _installDisk;
        auto label = _installLabel;
        const fromScratch = _useFromScratchLayout.checked();
        logInfo(format("beginInstallWrite: iso='%s' disk=%d label='%s' fromScratch=%s",
            iso, disk, label, fromScratch));
        _job = new Job("Install to USB", delegate() {
            try
            {
                ulong written;
                if (fromScratch)
                {
                    // Experimental: GPT + FAT32 (ISO contents) + exFAT data
                    // partition, built entirely from scratch.
                    logInfo(format("install job: writeIsoLayoutToPhysicalDrive iso=%s disk=%d",
                        iso, disk));
                    _job.report(0.0, "Building partitions on " ~ label);
                    LayoutOptions options;
                    options.fatLabel = "AURORA-ISO";
                    options.dataLabel = "AURORA-DATA";
                    written = writeIsoLayoutToPhysicalDrive(iso, disk, options,
                        delegate(DeviceProgress progress) {
                            _job.report(progress.fraction, progress.message);
                        },
                        delegate() { return _job.cancelled(); });
                    logInfo(format("install job: layout wrote %d bytes", written));
                }
                else
                {
                    logInfo(format("install job: writeImageToPhysicalDrive iso=%s disk=%d",
                        iso, disk));
                    _job.report(0.0, "Writing image to " ~ label ~ " (this formats the drive)");
                    written = writeImageToPhysicalDrive(iso, disk,
                        delegate(DeviceProgress progress) {
                            _job.report(progress.fraction, progress.message);
                        },
                        delegate() { return _job.cancelled(); });
                    logInfo(format("install job: wrote %d bytes", written));
                    if (_makeDataPartition.checked())
                    {
                        _job.report(1.0, "Formatting leftover space as a data partition");
                        logInfo("install job: formatRemainingSpace");
                        formatRemainingSpace(disk, "AURORA");
                    }
                }
                _job.report(1.0, format("Installed to %s (%s written)",
                    label, formatSize(written)));
            }
            catch (Exception error)
            {
                logError("install job: exception: " ~ error.msg);
                throw error;
            }
        });
        _job.start();
    }

    /**
     * Relaunch the executable elevated and let the new instance complete the
     * install. The chosen distribution and physical disk are passed on the
     * command line, and the elevated copy reuses the same download cache.
     */
    private void requestElevation(int distroIndex, uint diskNumber)
    {
        auto parameters = format("--auto-install %d %d %d %d", distroIndex, diskNumber,
            _makeDataPartition.checked() ? 1 : 0,
            _useFromScratchLayout.checked() ? 1 : 0);
        const result = shellExecuteRunAs(parameters);
        if (result <= 32)
            setStatus("Administrator rights are required to write a USB drive. Elevation was cancelled.");
        else
            setStatus("Waiting for the administrator prompt… approve UAC to continue.");
    }

    /// Entry point for the elevated instance started by requestElevation.
    public void autoInstall(int distroIndex, uint diskNumber,
        bool makeDataPartition = true, bool useFromScratchLayout = false)
    {
        refreshDistros();
        refreshDevices();
        _makeDataPartition.setChecked(makeDataPartition);
        _useFromScratchLayout.setChecked(useFromScratchLayout);
        if (distroIndex >= 0 && distroIndex < cast(int) _distros.length)
            _distroList.setSelectedIndex(distroIndex);
        foreach (i, device; _devices)
        {
            if (device.hasDiskNumber && device.diskNumber == diskNumber)
            {
                _deviceList.setSelectedIndex(cast(int) i);
                break;
            }
        }
        _deviceConfirm.setChecked(true);
        startInstall();
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
            _entries = _image.list(_currentDir).dup;
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
            auto secondary = entry.isDirectory ? "Directory" : formatSize(entry.size);
            items ~= ListItem(entry.name, icon, secondary);
        }
        _browser.setItems(items);
        _pathLabel.setText(_currentDir);
        _countLabel.setText(format("%d items", _entries.length));
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
        showFileDialog(this, folderOptions("Choose extraction folder"),
            delegate(string path) { startExtractAll(path); });
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
        showFileDialog(this, saveOptions("Extract file as", baseName(entry.name),
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

    // ----- Custom download ---------------------------------------------------

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
                destination = buildPath(downloadsDirectory(), baseName(parseUrl(url).target));
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
            _downloadForInstall = false;
            setStatus("Downloading " ~ baseName(destination));
        }
        catch (Exception error)
        {
            setStatus("Download failed: " ~ error.msg);
            _downloader = null;
        }
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
        logInfo(format("refreshDevices: %d removable device(s)", _devices.length));
        foreach (device; _devices)
            logInfo(format("  %c: label='%s' fs='%s' disk=%d hasDisk=%s model='%s'",
                device.letter, device.volumeLabel, device.fileSystem,
                device.diskNumber, device.hasDiskNumber, device.model));
        if (hasAdminRights())
            _adminLabel.setText("");
        else
            _adminLabel.setText("Install will ask for administrator rights (UAC).");
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
        if (_job !is null || _phase != InstallPhase.idle)
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
        if (_job !is null || _phase != InstallPhase.idle)
        {
            setStatus("Another operation is running.");
            return;
        }
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
            if (!formatVolume(letter, fs, "AURORA-USB", true))
                throw new Exception("Format failed (administrator rights required)");
            _job.report(1.0, format("Formatted %c: as %s", letter, fs));
        });
        _job.start();
    }

    private void startFormatCopy()
    {
        if (_job !is null || _phase != InstallPhase.idle)
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
    /// Copy the current image's files onto the drive's existing filesystem.
    /// No administrator rights are needed, but this installs no boot loader.
    private void startCopyFilesNoAdmin()
    {
        if (_job !is null || _phase != InstallPhase.idle)
        {
            setStatus("Another operation is running.");
            return;
        }
        if (!requireImage()) return;
        auto device = selectedDevice();
        if (device is null)
        {
            setStatus("Select a USB device first.");
            return;
        }
        const letter = device.letter;
        auto image = _image;
        auto root = format("%c:\\", letter);
        _job = new Job("Copy files to USB", delegate() {
            _job.report(0.1, format("Copying files to %c:", letter));
            auto files = image.walk("/", false).length;
            uint done;
            extractAll(image, root,
                delegate(string current) {
                    ++done;
                    _job.report(files == 0 ? 1.0 : cast(double) done / files,
                        "Copying " ~ current);
                },
                delegate() { return _job.cancelled(); });
            _job.report(1.0, format("Copied files to %c: (no admin)", letter));
        });
        _job.start();
    }

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
        if (_upButton is null || _browser is null)
            return;
        _upButton.setEnabled(enabled);
        _browser.setEnabled(enabled);
    }

    private void setStatus(string text)
    {
        if (_status !is null)
            _status.setText(text);
        if (_wizardStatus !is null)
            _wizardStatus.setText(text);
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
            logError("job '" ~ _job.title() ~ "' failed: " ~ _job.error());
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
        _phase = InstallPhase.idle;
        refreshDistros();
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
        if (snap.active)
        {
            setStatus(format("Downloading %s / %s", formatSize(snap.received),
                snap.total > 0 ? formatSize(snap.total) : "?"));
            return;
        }

        if (_downloadForInstall)
        {
            _downloadForInstall = false;
            _downloader = null;
            if (snap.failed && !snap.cancelled)
            {
                setStatus("Download failed: " ~ snap.error);
                _phase = InstallPhase.idle;
            }
            else if (snap.cancelled)
            {
                setStatus("Install cancelled.");
                _phase = InstallPhase.idle;
            }
            else
            {
                beginInstallWrite();
            }
            return;
        }

        if (snap.failed && !snap.cancelled)
            setStatus("Download failed: " ~ snap.error);
        else if (snap.cancelled)
            setStatus("Download cancelled.");
        else
        {
            setStatus("Download complete: " ~ baseName(snap.destination));
            refreshDistros();
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

    /// Test-only: current image (may be null).
    public IsoImage imageForTesting()
    {
        return _image;
    }

    /// Test-only: number of catalog entries.
    public int distroCountForTesting() const
    {
        return cast(int) _distros.length;
    }

    /// Test-only: number of detected USB devices.
    public int deviceCountForTesting() const
    {
        return cast(int) _devices.length;
    }

    /// Test-only: select a catalog entry as if the user clicked it.
    public void selectDistroForTesting(int index)
    {
        _distroList.setSelectedIndex(index);
        useDistro(index);
    }

    /// Test-only: current download URL field text.
    public string downloadUrlForTesting()
    {
        return _downloadUrl.textUtf8();
    }

    /// Test-only: toggle to the advanced view.
    public void toggleAdvancedForTesting()
    {
        toggleAdvanced();
    }

    /// Test-only: whether the advanced view is showing.
    public bool advancedVisibleForTesting() const
    {
        return _advancedBox.visible();
    }

    /// Test-only: side content child count.
    public int sideChildCountForTesting() const
    {
        return _sideColumn is null ? -1 : cast(int) _sideColumn.children().length;
    }

    /// Test-only: side scroll view bounds.
    public Rect sideScrollBoundsForTesting()
    {
        return _sideScroll is null ? Rect.init : _sideScroll.bounds();
    }

    /// Test-only: side content bounds.
    public Rect sideContentBoundsForTesting()
    {
        return _sideColumn is null ? Rect.init : _sideColumn.bounds();
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
}
