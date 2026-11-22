// SPDX-License-Identifier: 0BSD
/**
 * Aurora Win32 Laboratory inspector.
 *
 * A friendly front end for the binary-format laboratory: open an image, read
 * every modeled directory, verify that a rebuild is byte-identical, emit the
 * minimal PE from fields, and map and run that emitted image with the
 * laboratory loader.
 *
 * The window is built from Aurora-D widgets; all text uses the shared text
 * engine. The package depends on `aurora-exp-win32-image`, which stays free of
 * GUI dependencies.
 */
module aurorainspector.inspector;

import aurora;
import auroraexp.win32.emit;
import auroraexp.win32.image;
import auroraexp.win32.loader;
import auroraexp.win32.pe;
import std.conv : to;
import std.file : exists, mkdirRecurse, read, thisExePath, write;
import std.format : format;
import std.path : baseName, buildPath, dirName;

private enum Color success = Color.fromHex(0x5fd38d);
private enum Color neutral = Color.fromHex(0xaab4c0);

final class InspectorRoot : VBox
{
    private GuiWindow _window;
    private Theme _palette;
    private HBox _toolbar;
    private Label _status;
    private Label _verificationLabel;
    private Label _fileValue;
    private Label _formatValue;
    private Label _machineValue;
    private Label _subsystemValue;
    private Label _baseValue;
    private Label _entryValue;
    private Label _sizeValue;
    private Label _sectionsValue;
    private Label _importsValue;
    private Label _exportsValue;
    private Label _resourcesValue;
    private Label _directoriesValue;
    private Label _relocationsValue;
    private Label _debugValue;
    private Label _certificatesValue;
    private TextEditor _report;
    private Button _openButton;
    private Button _verifyButton;
    private Button _emitButton;
    private Button _runButton;
    private Button _saveButton;

    private PeImage _image;
    private bool _loaded;
    private string _path;
    private string _reportBase;
    private string _verification;
    private string _statusMessage;
    private ubyte[] _emitted;

    this(GuiWindow window, string initialPath = "")
    {
        super(0, Insets(0));
        _window = window;
        _palette = Theme.dark();
        setBackground(_palette.windowBackground);

        buildToolbar();
        buildBody();
        buildFooter();

        setStatus("Ready. Open a PE image, or emit the minimal executable and run it.", neutral);
        if (initialPath.length != 0)
            loadPath(initialPath);
    }

    // ---- Layout ----------------------------------------------------------

    private void buildToolbar()
    {
        _toolbar = new HBox(8, Insets(16, 10));
        _toolbar.setBackground(_palette.windowBackground);
        _toolbar.layoutHints().preferredHeight = 64;

        auto title = new Label("Aurora Win32 Laboratory");
        title.setScale(3);
        title.setColor(_palette.text);
        title.layoutHints().minWidth = 340;
        _toolbar.add(title);
        _toolbar.add(new Spacer(1.0));

        _openButton = action("Open image…", true, &openImage);
        _verifyButton = action("Verify rebuild", false, &verifyImage);
        _emitButton = action("Emit minimal", false, &emitMinimal);
        _runButton = action("Run emitted", false, &runEmitted);
        _saveButton = action("Save report…", false, &saveReport);

        _toolbar.add(_openButton);
        _toolbar.add(_verifyButton);
        _toolbar.add(_emitButton);
        _toolbar.add(_runButton);
        _toolbar.add(_saveButton);
        add(_toolbar);
    }

    private void buildBody()
    {
        auto body = new HBox(16, Insets(16, 12));
        body.layoutHints().flex = 1.0;
        body.setBackground(_palette.windowBackground);

        auto sidebar = new VBox(6, Insets(16));
        sidebar.setBackground(_palette.panelBackground);
        sidebar.setBorder(_palette.border, 10);
        sidebar.layoutHints().preferredWidth = 400;
        sidebar.layoutHints().minWidth = 400;
        sidebar.layoutHints().flex = 0.0;

        sidebar.add(sectionLabel("IMAGE"));

        _fileValue = metric(sidebar, "File");
        _formatValue = metric(sidebar, "Format");
        _machineValue = metric(sidebar, "Machine");
        _subsystemValue = metric(sidebar, "Subsystem");
        _baseValue = metric(sidebar, "Image base");
        _entryValue = metric(sidebar, "Entry point");
        _sizeValue = metric(sidebar, "Size of image");
        _sectionsValue = metric(sidebar, "Sections");
        _importsValue = metric(sidebar, "Imports");
        _exportsValue = metric(sidebar, "Exports");
        _resourcesValue = metric(sidebar, "Resources");
        _directoriesValue = metric(sidebar, "Directories");
        _relocationsValue = metric(sidebar, "Relocations");
        _debugValue = metric(sidebar, "Debug entries");
        _certificatesValue = metric(sidebar, "Certificates");

        sidebar.add(new Spacer(0.0));
        sidebar.add(sectionLabel("VERIFICATION"));
        _verificationLabel = new Label("Not run");
        _verificationLabel.setScale(1);
        _verificationLabel.setColor(neutral);
        sidebar.add(_verificationLabel);

        auto right = new VBox(8);
        right.layoutHints().flex = 1.0;
        right.layoutHints().minWidth = 420;
        right.add(sectionLabel("INSPECTION"));
        _report = new TextEditor("", true);
        _report.setReadOnly(true);
        _report.setWordWrap(true);
        _report.setTextColor(_palette.text);
        _report.layoutHints().flex = 1.0;
        right.add(_report);

        body.add(sidebar);
        body.add(right);
        add(body);
    }

    private void buildFooter()
    {
        auto footer = new HBox(8, Insets(16, 8));
        footer.setBackground(_palette.panelElevated);
        footer.layoutHints().preferredHeight = 38;
        _status = new Label("Ready");
        _status.setScale(1);
        _status.setColor(_palette.textMuted);
        _status.layoutHints().flex = 1.0;
        footer.add(_status);
        add(footer);
    }

    private Label sectionLabel(string text)
    {
        auto label = new Label(text);
        label.setScale(1);
        label.setColor(_palette.textMuted);
        return label;
    }

    private Label metric(VBox parent, string caption)
    {
        auto row = new HBox(10);
        row.layoutHints().minHeight = 22;
        auto name = new Label(caption);
        name.setScale(1);
        name.setColor(_palette.textMuted);
        name.layoutHints().preferredWidth = 112;
        auto value = new Label("—");
        value.setScale(1);
        value.setColor(_palette.text);
        value.layoutHints().flex = 1.0;
        row.add(name);
        row.add(value);
        parent.add(row);
        return value;
    }

    private Button action(string text, bool accent, void delegate() handler)
    {
        auto button = new Button(text);
        button.setAccent(accent);
        button.onClick = handler;
        return button;
    }

    // ---- Actions ---------------------------------------------------------

    private void openImage()
    {
        FileDialogOptions options;
        options.mode = FileDialogMode.open;
        options.title = "Open a PE image";
        options.acceptLabel = "Inspect";
        if (_path.length != 0)
            options.initialPath = dirName(_path);
        showFileDialog(this, options,
            delegate(string path) { loadPath(path); });
    }

    private void loadPath(string path)
    {
        try
        {
            const data = cast(const(ubyte)[]) read(path);
            _image = PeImage.load(data);
            _loaded = true;
            _path = path;
            _verification = "";
            _verificationLabel.setText("Not run");
            _verificationLabel.setColor(neutral);
            _reportBase = buildReport(_image);
            updateMetrics();
            refreshReport();
            setStatus(format("Loaded %s — %d bytes, %d sections.",
                baseName(path), data.length, _image.sections.length), _palette.textMuted);
        }
        catch (PeError error)
        {
            fail("Not a usable PE image: " ~ error.msg);
        }
        catch (Exception error)
        {
            fail("Could not read the file: " ~ error.msg);
        }
    }

    private void verifyImage()
    {
        if (!_loaded)
        {
            setStatus("Open an image before verifying a rebuild.", _palette.textMuted);
            return;
        }
        try
        {
            const rebuilt = _image.rebuild();
            bool identical = rebuilt.length == _image.bytes.length;
            size_t difference = size_t.max;
            if (identical)
                foreach (offset; 0 .. rebuilt.length)
                {
                    if (rebuilt[offset] != _image.bytes[offset])
                    {
                        difference = offset;
                        identical = false;
                        break;
                    }
                }
            if (identical)
            {
                _verification = format("PASS — byte-identical rebuild (%d bytes)", rebuilt.length);
                _verificationLabel.setColor(success);
                setStatus("Verified: rebuild is byte-identical.", success);
            }
            else
            {
                _verification = format("FAIL — first difference at 0x%X", difference);
                _verificationLabel.setColor(_palette.danger);
                setStatus("Verification failed: the rebuilt image differs.", _palette.danger);
            }
            _verificationLabel.setText(_verification);
            refreshReport();
        }
        catch (Exception error)
        {
            fail("Verification error: " ~ error.msg);
        }
    }

    private void emitMinimal()
    {
        try
        {
            _emitted = emitMinimalExecutable();
            const directory = buildPath(dirName(thisExePath()), "build", "inspector");
            if (!exists(directory))
                mkdirRecurse(directory);
            const output = buildPath(directory, "minimal-hello.exe");
            write(output, _emitted);
            setStatus(format("Emitted %d bytes to %s. Run emitted maps and executes it.",
                _emitted.length, output), success);
        }
        catch (Exception error)
        {
            fail("Emit failed: " ~ error.msg);
        }
    }

    private void runEmitted()
    {
        if (_emitted.length == 0)
            emitMinimal();
        if (_emitted.length == 0)
            return;
        try
        {
            auto mapped = mapImage(_emitted);
            scope (exit) unmapImage(mapped);
            const exitCode = runEntry(mapped);
            setStatus(format("Mapped at 0x%X (delta %d), entry 0x%X, thread exit %d.",
                cast(ulong) mapped.base, mapped.relocationDelta,
                mapped.entryPoint, exitCode),
                exitCode == 0 ? success : _palette.danger);
        }
        catch (Exception error)
        {
            fail("Loader failed: " ~ error.msg);
        }
    }

    private void saveReport()
    {
        if (!_loaded)
        {
            setStatus("Open an image before saving a report.", _palette.textMuted);
            return;
        }
        FileDialogOptions options;
        options.mode = FileDialogMode.save;
        options.title = "Save inspection report";
        options.acceptLabel = "Save";
        options.defaultFileName = baseName(_path) ~ ".report.txt";
        options.initialPath = dirName(_path);
        showFileDialog(this, options, delegate(string path)
        {
            try
            {
                write(path, reportText());
                setStatus("Report saved to " ~ path, _palette.textMuted);
            }
            catch (Exception error)
            {
                fail("Could not save the report: " ~ error.msg);
            }
        });
    }

    // ---- Data presentation ------------------------------------------------

    private void updateMetrics()
    {
        const image = _image;
        const libraries = image.imports();
        size_t symbols;
        foreach (index; 0 .. libraries.length)
            symbols += libraries[index].symbols.length;
        const exports = image.exports();
        const resources = image.resources();
        const blocks = image.relocationBlocks();
        uint relocationEntries;
        foreach (index; 0 .. blocks.length)
            relocationEntries += blocks[index].entryCount;
        const debugEntries = image.debugEntries();
        const certificates = image.certificates();

        size_t directories;
        foreach (directory; image.directories())
            if (directory.virtualAddress != 0)
                ++directories;

        _fileValue.setText(baseName(_path));
        _formatValue.setText(image.is64 ? "PE32+" : "PE32");
        _machineValue.setText(format("0x%04X  %s", image.coff.machine,
            machineName(image.coff.machine)));
        _subsystemValue.setText(format("%d  %s", image.subsystem,
            subsystemName(image.subsystem)));
        _baseValue.setText(format("0x%X", image.imageBase));
        _entryValue.setText(format("0x%X", image.addressOfEntryPoint));
        _sizeValue.setText(format("%d bytes", image.sizeOfImage));
        _sectionsValue.setText(to!string(image.sections.length));
        _importsValue.setText(format("%d symbols / %d DLLs", symbols, libraries.length));
        _exportsValue.setText(to!string(exports.length));
        _resourcesValue.setText(to!string(resources.length));
        _directoriesValue.setText(format("%d / %d", directories, image.directories().length));
        _relocationsValue.setText(format("%d blocks / %d entries",
            blocks.length, relocationEntries));
        _debugValue.setText(to!string(debugEntries.length));
        _certificatesValue.setText(to!string(certificates.length));
    }

    private string reportText()
    {
        return _reportBase ~ (_verification.length == 0 ? "" :
            "\n\nVERIFICATION\n  " ~ _verification);
    }

    private void refreshReport()
    {
        _report.setText(reportText(), false);
        _report.setCursorIndex(0);
        _report.verticalScrollbar().setValue(0, false);
    }

    private string buildReport(const ref PeImage image)
    {
        string text;
        text ~= format("FILE  %s\n", _path);
        text ~= format("  bytes=%d  format=%s  machine=%s  subsystem=%s\n",
            image.bytes.length, image.is64 ? "PE32+" : "PE32",
            machineName(image.coff.machine), subsystemName(image.subsystem));
        text ~= format("  imageBase=0x%X  entry=0x%X  sizeOfImage=%d  headers=%d\n",
            image.imageBase, image.addressOfEntryPoint,
            image.sizeOfImage, image.sizeOfHeaders);

        text ~= format("\nSECTIONS (%d)\n", image.sections.length);
        foreach (index; 0 .. image.sections.length)
        {
            const section = image.sections[index];
            text ~= format("  %-8s rva=0x%-8X raw=0x%-8X size=0x%X\n",
                section.nameString, section.virtualAddress,
                section.pointerToRawData, section.sizeOfRawData);
        }

        const directories = image.directories();
        text ~= format("\nDATA DIRECTORIES (%d)\n", directories.length);
        foreach (index; 0 .. directories.length)
        {
            if (directories[index].virtualAddress == 0)
                continue;
            text ~= format("  %-2d %-14s rva=0x%-8X size=0x%X\n", index,
                directoryName(index), directories[index].virtualAddress,
                directories[index].size);
        }

        const libraries = image.imports();
        size_t symbols;
        foreach (index; 0 .. libraries.length)
            symbols += libraries[index].symbols.length;
        text ~= format("\nIMPORTS (%d symbols in %d DLLs)\n", symbols, libraries.length);
        foreach (index; 0 .. libraries.length)
            text ~= format("  %-32s %d\n", libraries[index].dll,
                libraries[index].symbols.length);

        const exports = image.exports();
        text ~= format("\nEXPORTS (%d)\n", exports.length);
        foreach (index; 0 .. exports.length)
        {
            if (index == 60)
            {
                text ~= format("  … %d more\n", exports.length - 60);
                break;
            }
            text ~= format("  #%-5d %-40s rva=0x%X%s\n", exports[index].ordinal,
                exports[index].name.length ? exports[index].name : "(unnamed)",
                exports[index].rva,
                exports[index].forwarder.length
                    ? "  -> " ~ exports[index].forwarder : "");
        }

        const resources = image.resources();
        text ~= format("\nRESOURCES (%d)\n", resources.length);
        foreach (index; 0 .. resources.length)
        {
            const resource = resources[index];
            text ~= format("  type=%-12s name=%-16s lang=%-5d size=%d\n",
                resource.typeName.length
                    ? resource.typeName : to!string(resource.typeId),
                resource.name.length ? resource.name : "#" ~ to!string(resource.nameId),
                resource.languageId, resource.size);
        }

        const blocks = image.relocationBlocks();
        uint relocationEntries;
        foreach (index; 0 .. blocks.length)
            relocationEntries += blocks[index].entryCount;
        text ~= format("\nRELOCATIONS  %d blocks, %d entries\n",
            blocks.length, relocationEntries);

        const debugEntries = image.debugEntries();
        text ~= format("\nDEBUG (%d)\n", debugEntries.length);
        foreach (index; 0 .. debugEntries.length)
            text ~= format("  type=%-3d size=%-6d stamp=%d%s\n",
                debugEntries[index].type, debugEntries[index].sizeOfData,
                debugEntries[index].timeDateStamp,
                debugEntries[index].codeViewPath.length
                    ? "  pdb=" ~ debugEntries[index].codeViewPath : "");

        const certificates = image.certificates();
        text ~= format("\nCERTIFICATES (%d)\n", certificates.length);
        foreach (index; 0 .. certificates.length)
            text ~= format("  length=%-6d revision=%d type=%d\n",
                certificates[index].length, certificates[index].revision,
                certificates[index].certificateType);

        const delayImports = image.delayImports();
        text ~= format("\nDELAY IMPORTS (%d)\n", delayImports.length);
        foreach (index; 0 .. delayImports.length)
            text ~= format("  %-32s %d\n", delayImports[index].dll,
                delayImports[index].symbols.length);

        const tls = image.tls();
        text ~= format("\nTLS  %s, callbacks=%d\n",
            tls.present ? "present" : "absent", tls.callbacks.length);

        text ~= format("\nEXCEPTIONS  %d\n", image.exceptionCount());

        const bound = image.boundImports();
        text ~= format("\nBOUND IMPORTS (%d)\n", bound.length);
        foreach (index; 0 .. bound.length)
            text ~= format("  %-32s stamp=%d\n", bound[index].dll,
                bound[index].timeDateStamp);

        return text;
    }

    private string directoryName(size_t index)
    {
        switch (index)
        {
        case DirectoryIndex.exports:
            return "exports";
        case DirectoryIndex.imports:
            return "imports";
        case DirectoryIndex.resources:
            return "resources";
        case DirectoryIndex.exception:
            return "exceptions";
        case DirectoryIndex.security:
            return "certificates";
        case DirectoryIndex.baseRelocations:
            return "relocations";
        case DirectoryIndex.debugDirectory:
            return "debug";
        case DirectoryIndex.architecture:
            return "architecture";
        case DirectoryIndex.globalPointer:
            return "global-pointer";
        case DirectoryIndex.tls:
            return "tls";
        case DirectoryIndex.loadConfig:
            return "load-config";
        case DirectoryIndex.boundImports:
            return "bound-imports";
        case DirectoryIndex.importAddressTable:
            return "iat";
        case DirectoryIndex.delayImports:
            return "delay-imports";
        case DirectoryIndex.clrRuntime:
            return "clr";
        case DirectoryIndex.reserved:
            return "reserved";
        default:
            return "unknown";
        }
    }

    // ---- Status and test hooks -------------------------------------------

    private void setStatus(string message, Color color)
    {
        _statusMessage = message;
        _status.setText(message);
        _status.setColor(color);
    }

    private void fail(string message)
    {
        setStatus(message, _palette.danger);
    }

    /// Test hook: true after a successful load.
    bool hasImage() const
    {
        return _loaded;
    }

    /// Test hook: last status-bar message.
    string statusMessage() const
    {
        return _statusMessage;
    }

    /// Test hook: last verification result.
    string verificationMessage() const
    {
        return _verification;
    }

    /// Test hook: click target for the Verify button.
    Point openButtonCenter()
    {
        return centerOf(_openButton);
    }

    /// Test hook: click target for the Verify button.
    Point verifyButtonCenter()
    {
        return centerOf(_verifyButton);
    }

    /// Test hook: click target for the Emit button.
    Point emitButtonCenter()
    {
        return centerOf(_emitButton);
    }

    /// Test hook: click target for the Run button.
    Point runButtonCenter()
    {
        return centerOf(_runButton);
    }

    private Point centerOf(Button button)
    {
        const bounds = button.bounds();
        const bar = _toolbar.bounds();
        return Point(bar.x + bounds.x + bounds.width / 2,
            bar.y + bounds.y + bounds.height / 2);
    }
}
