module auroraopencode.attachments;

// ===========================================================================
// EXPERIMENTAL: `attachments` - dropped files and large pastes as attachments.
//
// This is an isolated, opt-in experiment. It lets the user drag files from
// Explorer (or any shell that publishes CF_HDROP) onto the window and have
// them appear as chips above the prompt, and it diverts a large clipboard
// paste out of the text box and into a text attachment so the prompt stays
// readable. Every attachment is delivered to the model inline with the next
// message (the transcript keeps the typed text plus a one-line summary).
//
// The entire feature lives in this file plus a few deliberately tiny,
// greppable hooks elsewhere (all tagged `experimental: attachments`):
//   * source/auroraopencode/appui.d  - import, composer strip, drop override,
//     Ctrl+V paste intercept, send/queue context, test accessors
//   * tests/headless_pro_smoke.d     - coverage
// To drop the feature: delete this file and delete the tagged hooks. Nothing
// else references it.
//
// Enabled by default so it can be tried immediately; set AURORA_ATTACHMENTS to
// 0/off/false/no (or AURORA_ATTACHMENTS=disabled) to turn it off without
// editing code. Tune the paste threshold with AURORA_ATTACHMENTS_PASTE_CHARS.
//
// The chips are the design answer to "attachments or a floating text viewer?":
// a compact strip of removable chips keeps the composer honest without a second
// window, and the full pasted/file body still reaches the model. A dedicated
// floating viewer can be layered on later without changing this model.
// ===========================================================================

import aurora;
import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.file : exists, getSize, isFile, readText;
import std.path : baseName;
import std.process : environment;
import std.string : splitLines, strip, toLower;

/// Env switch. Anything other than the values below leaves the feature enabled,
/// so an unset variable means "on".
private enum disableValues = ["0", "off", "false", "no", "disabled", "disable"];

/// Height the composer reserves for the chip row when it is showing.
public enum int attachmentStripHeight = 34;

/// A paste at or above this many characters becomes a text attachment.
public enum size_t attachmentPasteCharThreshold = 1500;
/// A paste with at least this many non-blank lines becomes a text attachment.
public enum size_t attachmentPasteLineThreshold = 20;
/// Files at or below this size are read into the message body; larger ones are
/// referenced by name only so a huge binary cannot blow up the request.
public immutable size_t attachmentFileMaxBytes = 64 * 1024;

/// Whether the experimental attachments feature is active. Read on every use so
/// tests (and a relaunch with a different environment) see the current value.
public bool experimentalAttachmentsEnabled()
{
    const raw = strip(toLower(environment.get("AURORA_ATTACHMENTS", "on")));
    if (raw.length == 0) return true;
    return !disableValues.canFind(raw);
}

/// The active paste character threshold; override with
/// AURORA_ATTACHMENTS_PASTE_CHARS for a denser or looser trigger.
private size_t pasteCharThreshold()
{
    const raw = strip(environment.get("AURORA_ATTACHMENTS_PASTE_CHARS", ""));
    if (raw.length == 0) return attachmentPasteCharThreshold;
    try
    {
        const parsed = to!long(raw);
        if (parsed >= 200 && parsed <= 200000) return cast(size_t) parsed;
    }
    catch (Exception) {}
    return attachmentPasteCharThreshold;
}

/// One pending attachment. `isFile` distinguishes a dropped file from a large
/// paste; `name` is the short chip label and `body` is what the model receives.
public struct Attachment
{
    bool isFile;
    string name;
    string body;
    long bytes;
}

/// The text a paste inserted, derived without the clipboard API: the bytes that
/// differ between the box before and after the paste. `after` must contain
/// `before` with a single contiguous insertion (the normal paste case).
public string attachmentInsertedText(string before, string after)
{
    size_t prefix;
    const shortest = before.length < after.length ? before.length : after.length;
    while (prefix < shortest && before[prefix] == after[prefix]) ++prefix;
    size_t suffix;
    while (suffix < before.length - prefix && suffix < after.length - prefix &&
        before[before.length - 1 - suffix] == after[after.length - 1 - suffix])
        ++suffix;
    return after[prefix .. after.length - suffix];
}

/// Whether a pasted block is large enough to deserve its own attachment.
public bool attachmentIsLargePaste(string text)
{
    const trimmed = strip(text);
    if (trimmed.length >= pasteCharThreshold()) return true;
    if (attachmentNonBlankLineCount(trimmed) >= attachmentPasteLineThreshold)
        return true;
    return false;
}

private size_t attachmentNonBlankLineCount(string text)
{
    size_t lines;
    foreach (line; text.splitLines())
        if (strip(line).length > 0) ++lines;
    return lines;
}

/// Build a text attachment from a large paste. Never throws.
public Attachment attachmentForText(string text)
{
    const trimmed = strip(text);
    const lines = attachmentNonBlankLineCount(trimmed);
    Attachment attachment;
    attachment.isFile = false;
    attachment.name = "Pasted text (" ~ to!string(lines > 0 ? lines : 1) ~
        " lines)";
    attachment.body = trimmed;
    attachment.bytes = 0;
    return attachment;
}

/// Build a file attachment from a dropped path. Never throws: an unreadable or
/// oversized file is described by name instead of failing the drop.
public Attachment attachmentForFile(string path)
{
    Attachment attachment;
    attachment.isFile = true;
    attachment.name = baseName(path);
    if (attachment.name.length == 0) attachment.name = path;
    try
    {
        if (!exists(path) || !isFile(path))
        {
            attachment.body = "Attachment " ~ path ~
                " could not be read: it is not a regular file.";
            return attachment;
        }
        const size = getSize(path);
        attachment.bytes = cast(long) size;
        if (size > attachmentFileMaxBytes)
        {
            attachment.body = "Attached file " ~ path ~ " is larger than " ~
                to!string(attachmentFileMaxBytes / 1024) ~
                " KiB. Read it with the file tools only if its contents are " ~
                "needed for this request.";
            return attachment;
        }
        attachment.body = readText(path);
    }
    catch (Exception error)
    {
        attachment.body = "Attachment " ~ path ~ " could not be read: " ~
            error.msg;
    }
    return attachment;
}

/// A short, human-readable size for a chip label ("" when unknown).
public string attachmentSizeSummary(const Attachment attachment)
{
    if (attachment.bytes <= 0) return "";
    if (attachment.bytes < 1024) return to!string(attachment.bytes) ~ " B";
    if (attachment.bytes < 1024 * 1024)
        return to!string((attachment.bytes + 512) / 1024) ~ " KB";
    return to!string((attachment.bytes + 524288) / 1048576) ~ " MB";
}

/// The chip label: a truncated name plus the size.
public string attachmentChipLabel(const Attachment attachment)
{
    string name = attachment.name;
    if (name.length > 28) name = name[0 .. 28] ~ "…";
    const size = attachmentSizeSummary(attachment);
    return size.length == 0 ? name : name ~ "  " ~ size;
}

/// The one-line summary appended to the visible user message so the transcript
/// records what was attached.
public string attachmentVisibleSummary(const(Attachment)[] attachments)
{
    if (attachments.length == 0) return "";
    auto builder = appender!string();
    builder.put("Attached:\n");
    foreach (attachment; attachments)
    {
        const size = attachmentSizeSummary(attachment);
        builder.put("- " ~ attachment.name ~
            (size.length == 0 ? "" : " (" ~ size ~ ")") ~ "\n");
    }
    return strip(builder.data);
}

/// The full attachment bodies, formatted for the model, delivered as a hidden
/// context message with the next request.
public string attachmentContextBlock(const(Attachment)[] attachments)
{
    if (attachments.length == 0) return "";
    auto builder = appender!string();
    builder.put("Attached content (drag-and-drop files or a large paste, " ~
        "provided inline because it was not typed):\n");
    foreach (index, attachment; attachments)
    {
        builder.put("\n--- attachment " ~ to!string(index + 1) ~ ": " ~
            attachment.name ~ " ---\n");
        builder.put(attachment.body);
        if (attachment.body.length == 0 || attachment.body[$ - 1] != '\n')
            builder.put("\n");
    }
    return builder.data;
}

/// Called with the index of a chip the user clicked to remove.
public alias AttachmentRemoveHandler = void delegate(size_t index);

/// A compact row of removable attachment chips shown above the prompt. It is an
/// HBox of buttons; each click removes that attachment. Kept a plain widget so
/// the experiment owns its own presentation and the app only feeds it data.
public final class AttachmentStrip : HBox
{
    private Attachment[] _items;
    public AttachmentRemoveHandler onRemove;

    public this()
    {
        super(6);
        setVisible(false);
    }

    /// Replace the chip row. Cheap no-op when the attachments are unchanged, so
    /// the caller can call it on any UI change without rebuilding needlessly.
    public void setAttachments(const(Attachment)[] attachments)
    {
        if (sameAttachments(attachments)) return;
        _items = attachments.dup;
        clearChildren();
        foreach (index, attachment; attachments)
        {
            auto chip = new Button(attachmentChipLabel(attachment) ~ "  ×");
            chip.setId("oc-attachment");
            chip.layoutHints().preferredHeight = 26;
            chip.layoutHints().minHeight = 26;
            chip.onClick = makeRemove(index);
            add(chip);
        }
        setVisible(attachments.length != 0);
        invalidate();
    }

    public size_t countForTesting() const
    {
        return _items.length;
    }

    // A factory frame per chip so each closure captures its own index (a loop
    // variable captured directly would make every chip remove the last one).
    private void delegate() makeRemove(size_t index)
    {
        const captured = index;
        return delegate()
        {
            if (onRemove !is null) onRemove(captured);
        };
    }

    private bool sameAttachments(const(Attachment)[] attachments)
    {
        if (attachments.length != _items.length) return false;
        foreach (index, attachment; attachments)
        {
            const current = _items[index];
            if (attachment.isFile != current.isFile ||
                attachment.name != current.name ||
                attachment.body != current.body)
                return false;
        }
        return true;
    }
}

// ---------------------------------------------------------------------------
// Pure-helper regressions (run by `-unittest`; the app build ignores them).
// ---------------------------------------------------------------------------

unittest
{
    assert(attachmentInsertedText("abc", "abcXYZdef") == "XYZdef");
    assert(attachmentInsertedText("", "hello") == "hello");
    assert(attachmentInsertedText("left", "leftright") == "right");

    assert(!attachmentIsLargePaste("short note"));
    string big;
    foreach (i; 0 .. attachmentPasteCharThreshold + 10) big ~= 'x';
    assert(attachmentIsLargePaste(big));
    string manyLines;
    foreach (i; 0 .. attachmentPasteLineThreshold) manyLines ~= "line\n";
    assert(attachmentIsLargePaste(manyLines));

    auto text = attachmentForText(big);
    assert(!text.isFile && text.body == big);
    assert(attachmentContextBlock([text]).length > 0);
}

unittest
{
    auto strip = new AttachmentStrip();
    assert(strip.countForTesting() == 0);
    assert(!strip.visible());
    Attachment one;
    one.name = "a.txt";
    one.body = "hello";
    strip.setAttachments([one]);
    assert(strip.countForTesting() == 1);
    assert(strip.visible());
    strip.setAttachments([]);
    assert(strip.countForTesting() == 0);
    assert(!strip.visible());
}
