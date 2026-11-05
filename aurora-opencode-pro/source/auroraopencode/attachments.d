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
import aurora.image : ImageResample, RgbaImage, decodeImage, fitImage;
import auroraopencode.imagenormalization;
import auroraopencode.attachmentstore : AttachmentStore;
import auroraopencode.core : ChatImageAttachment, opencodeStateDirectory;
import std.algorithm : canFind, min;
import std.array : appender;
import std.base64 : Base64;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : exists, getSize, isFile, read, readText;
import std.path : baseName, extension, buildPath;
import std.process : environment;
import std.stdio : File;
import std.string : splitLines, strip, toLower;
import std.utf : toUTF32;

/// Env switch. Anything other than the values below leaves the feature enabled,
/// so an unset variable means "on".
private enum disableValues = ["0", "off", "false", "no", "disabled", "disable"];

/// Height the composer reserves for the chip row when it is showing.
public enum int attachmentStripHeight = 34;

/// Collapsed transcript image row. Keeping it to one small thumbnail line
/// avoids spending vertical space on every image-bearing turn; hovering a cell
/// opens a larger floating preview instead of reflowing the transcript.
public enum int imagePreviewHeight = 28;

public alias ImagePreviewContextMenuHandler =
    void delegate(ChatImageAttachment image, Point globalPosition);
private ImagePreviewContextMenuHandler imagePreviewContextMenuHandler;
public alias ImagePreviewOpenHandler = void delegate(ChatImageAttachment image);
private ImagePreviewOpenHandler imagePreviewOpenHandler;

public void setImagePreviewContextMenuHandler(
    ImagePreviewContextMenuHandler handler)
{
    imagePreviewContextMenuHandler = handler;
}

public void setImagePreviewOpenHandler(ImagePreviewOpenHandler handler)
{
    imagePreviewOpenHandler = handler;
}

// Decoding a full image and resizing it takes far longer than a frame. Doing
// that lazily from onPaint made the first scroll through image-bearing turns
// hitch (measured at ~18 ms/frame versus ~6 ms before previews). Prepare the
// thumbnail when the strip is built instead, and retain it process-wide so a
// rebuild or a second view of the same attachment never decodes it again.
private final class ThumbnailCacheEntry
{
    RgbaImage image;
    size_t bytes;
}

private ThumbnailCacheEntry[string] thumbnailCache;
private string[] thumbnailCacheOrder;
private size_t thumbnailCacheBytes;
private size_t thumbnailDecodes;
private enum size_t thumbnailCacheBudget = 24 * 1024 * 1024;

/// Test-only decode counter: scroll/paint must not increase this after the
/// strips have been prepared.
public size_t thumbnailDecodeCountForTesting()
{
    return thumbnailDecodes;
}

public void resetThumbnailDecodeCountForTesting()
{
    thumbnailDecodes = 0;
}

/// A paste at or above this many characters becomes a text attachment.
public enum size_t attachmentPasteCharThreshold = 1500;
/// A paste with at least this many non-blank lines becomes a text attachment.
public enum size_t attachmentPasteLineThreshold = 20;
/// Files at or below this size are read into the message body; larger ones are
/// referenced by name only so a huge binary cannot blow up the request.
public immutable size_t attachmentFileMaxBytes = 64 * 1024;

/// Maximum raw bytes for explicit original detail. Normal reads accept larger
/// inputs and transmit a bounded derivative instead.
public immutable size_t attachmentImageMaxBytes = 4 * 1024 * 1024;
public enum size_t attachmentImageInputMaxBytes = 32 * 1024 * 1024;

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
    // Set for a dropped/pasted image: the bytes travel as an inline
    // `image_url` part instead of `body` text.
    bool isImage;
    ChatImageAttachment image;
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
        // Images are multimodal content, not text: probe the magic bytes (the
        // extension alone is not trustworthy) and send them inline when the
        // model can see them.
        // `if (auto kind = ...)` would be wrong here: an empty string is
        // truthy in D, so a non-image would be marked as an image with an
        // empty mime type and serialized as a malformed `data:;base64,` URL.
        const kind = attachmentImageKindForPath(path);
        if (kind.length > 0)
        {
            if (size > attachmentImageInputMaxBytes)
            {
                attachment.body = "Attached image " ~ path ~ " is larger than " ~
                    to!string(attachmentImageInputMaxBytes / 1024) ~
                    " KiB, so it was not sent inline. Use the file tools to " ~
                    "inspect or convert it first.";
                return attachment;
            }
            attachment.isImage = true;
            attachment.image = attachmentImageForInlineData(kind,
                attachment.name, cast(ubyte[]) read(path));
            attachment.image.sourcePath = path;
            attachment.body = "";
            return attachment;
        }
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
        attachment.isImage = false;
        attachment.image = ChatImageAttachment.init;
        attachment.body = "Attachment " ~ path ~ " could not be read: " ~
            error.msg;
    }
    return attachment;
}

/// Whether the attachments sent with the next message include an image, which
/// only a vision-capable model can see.
public bool attachmentsContainImage(const(Attachment)[] attachments)
{
    foreach (attachment; attachments)
        if (attachment.isImage) return true;
    return false;
}

/// The images from a pending attachment list, ready for a chat request.
public ChatImageAttachment[] attachmentImages(const(Attachment)[] attachments)
{
    ChatImageAttachment[] images;
    foreach (attachment; attachments)
        if (attachment.isImage && attachment.image.base64Data.length > 0)
            images ~= attachment.image;
    return images;
}

/// A dropped/pasted image transferred as text because the selected model has
/// no vision support. The bytes are deliberately not dumped into the prompt.
public string attachmentImageUnsupportedNote(string model)
{
    return "Images attached but not sent: the selected model (" ~
        (model.length > 0 ? model : "unknown") ~
        ") is not marked vision-capable, so inline images would be rejected. " ~
        "Switch to a vision model, or use the file tools to inspect the image.";
}

/// The image mime type for a path, or null when the file is not an image
/// Aurora sends inline. Content sniffing is authoritative; the extension is
/// only a fallback for a truncated or unusual header.
public string attachmentImageKindForPath(string path)
{
    const ext = extension(path).toLower();
    if (ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".webp" ||
        ext == ".gif")
    {
        try
        {
            if (exists(path) && isFile(path))
            {
                const size = getSize(path);
                if (size > 0)
                {
                    auto file = File(path, "rb");
                    ubyte[16] header;
                    const readBytes = file.rawRead(header[]).length;
                    const sniffed = attachmentImageKindForBytes(
                        header[0 .. readBytes]);
                    return sniffed;
                }
            }
        }
        catch (Exception) {}
        // Header unreadable: trust the extension for the common cases.
        if (ext == ".png") return "image/png";
        if (ext == ".jpg" || ext == ".jpeg") return "image/jpeg";
        if (ext == ".webp") return "image/webp";
        if (ext == ".gif") return "image/gif";
    }
    try
    {
        if (!exists(path) || !isFile(path)) return null;
        if (getSize(path) == 0) return null;
        auto file = File(path, "rb");
        ubyte[16] header;
        const readBytes = file.rawRead(header[]).length;
        return attachmentImageKindForBytes(header[0 .. readBytes]);
    }
    catch (Exception)
    {
        return null;
    }
}

/// Magic-byte sniffing, so a `.png` that is really a PDF is not advertised to
/// the model as an image. Returns the mime type or "".
public string attachmentImageKindForBytes(const(ubyte)[] header)
{
    if (header.length >= 8 &&
        header[0] == 0x89 && header[1] == 'P' && header[2] == 'N' &&
        header[3] == 'G' && header[4] == 0x0D && header[5] == 0x0A &&
        header[6] == 0x1A && header[7] == 0x0A)
        return "image/png";
    if (header.length >= 3 &&
        header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF)
        return "image/jpeg";
    if (header.length >= 12 &&
        header[0] == 'R' && header[1] == 'I' && header[2] == 'F' &&
        header[3] == 'F' && header[8] == 'W' && header[9] == 'E' &&
        header[10] == 'B' && header[11] == 'P')
        return "image/webp";
    if (header.length >= 6 &&
        header[0] == 'G' && header[1] == 'I' && header[2] == 'F')
        return "image/gif";
    return "";
}

/// The inline image payload for already-read bytes.
public ChatImageAttachment attachmentImageForData(string mimeType, string name,
    in ubyte[] data)
{
    ChatImageAttachment image;
    image.mimeType = mimeType;
    image.name = name;
    image.base64Data = base64Encode(data);
    return image;
}

/// A shared, bounded derivative for every normal image entry point. The full
/// original is archived with the derivative so crops and explicit original reads
/// can retrieve it without depending on the source file still being present.
public immutable size_t attachmentImageInlineBytes = 512 * 1024;
public ChatImageAttachment attachmentImageForInlineData(string mimeType,
    string name, in ubyte[] data, bool original = false,
    auroraopencode.imagenormalization.ImageCrop crop = auroraopencode.imagenormalization.ImageCrop.init,
    string sourcePath = "")
{
    import auroraopencode.attachmentstore : AttachmentStore;
    import auroraopencode.core : opencodeStateDirectory;
    import auroraopencode.imagenormalization : normalizeImage;
    const normalized = normalizeImage(data, mimeType, original, crop);
    auto image = attachmentImageForData(normalized.mimeType,
        normalized.mimeType == mimeType ? name : inlineImageName(name), normalized.bytes);
    auto store = AttachmentStore(buildPath(opencodeStateDirectory(), "attachments"));
    image.originalBlob = store.put(base64Encode(data));
    image.originalMimeType = mimeType;
    image.normalizationVersion = 1;
    image.originalDetail = original;
    image.width = normalized.width;
    image.height = normalized.height;
    image.originalWidth = normalized.originalWidth;
    image.originalHeight = normalized.originalHeight;
    image.sourcePath = sourcePath;
    return image;
}

/// Rename an inline image whose bytes were re-encoded to JPEG so the data URL
/// mime type and the chip label agree.
private string inlineImageName(string name)
{
    import std.path : setExtension;
    if (name.length == 0) return "image.jpg";
    return setExtension(name, ".jpg");
}

/// Standard base64. Kept local so the pro app does not add a dependency for
/// one encoder.
public string base64Encode(in ubyte[] data)
{
    static immutable char[] alphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    auto builder = appender!string();
    builder.reserve(((data.length + 2) / 3) * 4);
    size_t index;
    while (index + 3 <= data.length)
    {
        const value = (cast(uint) data[index] << 16) |
            (cast(uint) data[index + 1] << 8) | data[index + 2];
        builder.put(alphabet[(value >> 18) & 0x3F]);
        builder.put(alphabet[(value >> 12) & 0x3F]);
        builder.put(alphabet[(value >> 6) & 0x3F]);
        builder.put(alphabet[value & 0x3F]);
        index += 3;
    }
    const remaining = data.length - index;
    if (remaining == 1)
    {
        const value = cast(uint) data[index] << 16;
        builder.put(alphabet[(value >> 18) & 0x3F]);
        builder.put(alphabet[(value >> 12) & 0x3F]);
        builder.put("==");
    }
    else if (remaining == 2)
    {
        const value = (cast(uint) data[index] << 16) |
            (cast(uint) data[index + 1] << 8);
        builder.put(alphabet[(value >> 18) & 0x3F]);
        builder.put(alphabet[(value >> 12) & 0x3F]);
        builder.put(alphabet[(value >> 6) & 0x3F]);
        builder.put('=');
    }
    return builder.data;
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
    const prefix = attachment.isImage ? "image: " : "";
    const label = prefix ~ name;
    return size.length == 0 ? label : label ~ "  " ~ size;
}

/// The one-line note for an attachment that travels as inline image parts
/// rather than text, so the model is told what it received.
public string attachmentImageSummary(const Attachment attachment)
{
    const size = attachmentSizeSummary(attachment);
    return "attached as an inline " ~ attachment.image.mimeType ~
        " image" ~ (size.length == 0 ? "" : " (" ~ size ~ ")");
}

/// The one-line summary appended to the visible user message for attachments
/// that do not have durable UI metadata. Images are represented by transcript
/// pills instead, using `ChatMessage.images`.
public string attachmentVisibleSummary(const(Attachment)[] attachments)
{
    if (attachments.length == 0) return "";
    auto builder = appender!string();
    foreach (attachment; attachments)
    {
        if (attachment.isImage) continue;
        if (builder.data.length == 0) builder.put("Attached:\n");
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
        if (attachment.isImage)
        {
            builder.put("\n--- attachment " ~ to!string(index + 1) ~ ": " ~
                attachment.name ~ " ---\n");
            builder.put("The image itself is attached to this message as an " ~
                "inline " ~ attachment.image.mimeType ~
                " image; describe what you see in it.\n");
            continue;
        }
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
    private bool _removable;
    public AttachmentRemoveHandler onRemove;

    public this(bool removable = true)
    {
        super(6);
        _removable = removable;
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
            auto chip = new Button(attachmentChipLabel(attachment) ~
                (_removable ? "  ×" : ""));
            chip.setId(_removable ? "oc-attachment" : "oc-sent-attachment");
            chip.layoutHints().preferredHeight = 26;
            chip.layoutHints().minHeight = 26;
            if (_removable) chip.onClick = makeRemove(index);
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
                attachment.isImage != current.isImage ||
                attachment.name != current.name ||
                attachment.body != current.body)
                return false;
        }
        return true;
    }
}

/// A compact line of thumbnails. The row stays collapsed; hovering a cell
/// opens a larger floating card above it, and right-clicking a cell exposes the
/// source file actions. Decoding is prepared when the strip is built, never
/// from paint, so scrolling remains smooth.
public final class ImagePreviewStrip : Widget
{
    private enum int cellWidth = 40;
    private enum int cellHeight = 22;
    private enum int gap = 5;
    private enum int visibleLimit = 16;
    private enum int cellTop = (imagePreviewHeight - cellHeight) / 2;

    private ChatImageAttachment[] _images;
    private RgbaImage[] _thumbnails;
    private bool[] _attempted;
    private int _hoverIndex = -1;
    private ImageHoverPreview _hoverPreview;

    public this()
    {
        setId("oc-image-previews");
        setVisible(false);
    }

    public void setImages(const(ChatImageAttachment)[] images)
    {
        if (sameImages(images)) return;
        hideHoverPreview();
        _images = images.dup;
        _thumbnails = new RgbaImage[images.length];
        _attempted = new bool[images.length];
        setVisible(images.length > 0);
        // Do this while the turn is being built, never from onPaint: decoding
        // and resizing on a newly exposed scroll row was the measured hitch.
        foreach (index; 0 .. _images.length) thumbnail(index);
        invalidate();
    }

    public size_t countForTesting() const
    {
        return _images.length;
    }

    public size_t loadedPreviewCountForTesting()
    {
        size_t loaded;
        foreach (index; 0 .. _images.length)
            if (thumbnail(index) !is null) ++loaded;
        return loaded;
    }

    public string labelForTesting(size_t index)
    {
        return index < _images.length ? previewLabel(_images[index]) : "";
    }

    public Point cellCenterForTesting(size_t index)
    {
        const cell = cellRect(index);
        return localToGlobal(Point(cell.x + cell.width / 2,
            cell.y + cell.height / 2));
    }

    public bool hoverPreviewOpenForTesting()
    {
        return _hoverPreview !is null && _hoverPreview.parent() !is null &&
            _hoverPreview.visible();
    }

    public string hoverPreviewLabelForTesting() const
    {
        return _hoverPreview is null ? "" : _hoverPreview.labelForTesting();
    }

    protected override Size onMeasure(Size available)
    {
        const width = maxInt(0, available.width);
        layoutHints().preferredWidth = width;
        layoutHints().preferredHeight = imagePreviewHeight;
        return Size(width, imagePreviewHeight);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (_images.length == 0) return;
        const palette = theme();
        const fit = maxInt(1, (bounds().width + gap) / (cellWidth + gap));
        const limit = fit < visibleLimit ? fit : visibleLimit;
        const shown = _images.length < limit ? _images.length : limit;
        foreach (index; 0 .. shown)
        {
            const cell = cellRect(index);
            const hovered = cast(int) index == _hoverIndex;
            canvas.drawRoundedRect(cell, 5, palette.fieldBackground,
                hovered ? palette.accent : palette.border, 1);
            const imageRect = Rect(cell.x + 2, cell.y + 2,
                cell.width - 4, cell.height - 4);
            auto preview = thumbnail(index);
            if (preview !is null)
            {
                auto clipped = canvas.clipped(imageRect);
                clipped.drawImage(fittedRect(imageRect, preview.width(),
                    preview.height()), preview);
            }
            else
            {
                canvas.drawTextInRect(imageRect, toUTF32("?"),
                    palette.textMuted, 1, HorizontalAlign.center,
                    VerticalAlign.middle, true);
            }
        }
        if (_images.length > shown)
        {
            const cell = cellRect(shown);
            canvas.drawRoundedRect(cell, 5, palette.fieldBackground,
                palette.border, 1);
            canvas.drawTextInRect(cell,
                toUTF32("+" ~ to!string(_images.length - shown)),
                palette.text, 1, HorizontalAlign.center,
                VerticalAlign.middle, true);
        }
    }

    protected override void onMouseEnter()
    {
        setCursor(CursorKind.hand);
    }

    protected override void onMouseLeave()
    {
        setCursor(CursorKind.arrow);
        hideHoverPreview();
        if (_hoverIndex >= 0)
        {
            _hoverIndex = -1;
            invalidate();
        }
    }

    override bool onMouseMove(ref Event event)
    {
        const next = indexAt(event.position);
        if (next == _hoverIndex) return false;
        _hoverIndex = next;
        if (next >= 0) showHoverPreview(next);
        else hideHoverPreview();
        invalidate();
        return false;
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right)
        {
            const index = indexAt(event.position);
            if (index >= 0 && index < cast(int) _images.length &&
                imagePreviewContextMenuHandler !is null)
            {
                hideHoverPreview();
                imagePreviewContextMenuHandler(_images[index],
                    localToGlobal(event.position));
                return true;
            }
        }
        if (event.button == MouseButton.left)
        {
            const index = indexAt(event.position);
            if (index >= 0 && index < cast(int) _images.length &&
                imagePreviewOpenHandler !is null)
            {
                hideHoverPreview();
                imagePreviewOpenHandler(_images[index]);
                return true;
            }
        }
        return super.onMouseDown(event);
    }

    private Rect cellRect(size_t index)
    {
        return Rect(cast(int) index * (cellWidth + gap), cellTop,
            cellWidth, cellHeight);
    }

    private int indexAt(Point point)
    {
        if (point.y < cellTop || point.y >= cellTop + cellHeight) return -1;
        const fit = maxInt(1, (bounds().width + gap) / (cellWidth + gap));
        const limit = fit < visibleLimit ? fit : visibleLimit;
        const shown = _images.length < limit ? _images.length : limit;
        const column = point.x / (cellWidth + gap);
        if (column < 0 || column >= cast(int) shown) return -1;
        if (point.x - column * (cellWidth + gap) >= cellWidth) return -1;
        return cast(int) column;
    }

    private void showHoverPreview(int index)
    {
        auto root = popupRoot(this);
        auto preview = thumbnail(index);
        if (root is null || preview is null)
        {
            hideHoverPreview();
            return;
        }
        if (_hoverPreview is null) _hoverPreview = new ImageHoverPreview(this);
        if (_hoverPreview.parent() is null)
        {
            root.add(_hoverPreview);
            root.bringChildToFront(_hoverPreview);
        }
        _hoverPreview.setContent(preview, previewTitle(_images[index]));
        const size = _hoverPreview.measure(Size(int.max, int.max));
        const cell = cellRect(index);
        const origin = localToGlobal(Point(cell.x + cell.width / 2, cell.y));
        const rootSize = root.bounds();
        int x = origin.x - size.width / 2;
        int y = origin.y - size.height - 6;
        if (y < 4) y = origin.y + imagePreviewHeight + 6;
        x = clampInt(x, 4, maxInt(4, rootSize.width - size.width - 4));
        y = clampInt(y, 4, maxInt(4, rootSize.height - size.height - 4));
        _hoverPreview.setBounds(Rect(x, y, size.width, size.height));
        _hoverPreview.setVisible(true);
    }

    private void hideHoverPreview()
    {
        if (_hoverPreview !is null && _hoverPreview.parent() !is null)
            _hoverPreview.parent().remove(_hoverPreview);
    }

    private RgbaImage thumbnail(size_t index)
    {
        if (index >= _images.length) return null;
        if (_attempted[index]) return _thumbnails[index];
        _attempted[index] = true;
        _thumbnails[index] = cachedThumbnail(_images[index]);
        return _thumbnails[index];
    }

    private static Rect fittedRect(Rect area, int width, int height)
    {
        if (width <= 0 || height <= 0) return area;
        int fittedWidth, fittedHeight;
        if (cast(long) width * area.height >= cast(long) height * area.width)
        {
            fittedWidth = area.width;
            fittedHeight = maxInt(1, cast(int) (cast(long) height * area.width /
                width));
        }
        else
        {
            fittedHeight = area.height;
            fittedWidth = maxInt(1, cast(int) (cast(long) width * area.height /
                height));
        }
        return Rect(area.x + (area.width - fittedWidth) / 2,
            area.y + (area.height - fittedHeight) / 2, fittedWidth,
            fittedHeight);
    }

    private static string previewTitle(const ref ChatImageAttachment image)
    {
        auto label = image.name.length > 0 ? image.name : "image";
        if (image.error.length > 0) label ~= " · unavailable";
        return label;
    }

    private static string previewLabel(const ref ChatImageAttachment image)
    {
        auto label = previewTitle(image);
        if (label.length > 24) label = label[0 .. 24] ~ "…";
        return label;
    }

    private bool sameImages(const(ChatImageAttachment)[] images)
    {
        if (images.length != _images.length) return false;
        foreach (index, image; images)
        {
            const current = _images[index];
            if (image.name != current.name || image.mimeType != current.mimeType ||
                image.blob != current.blob ||
                image.originalBlob != current.originalBlob ||
                image.error != current.error ||
                image.sourcePath != current.sourcePath ||
                image.base64Data != current.base64Data)
                return false;
        }
        return true;
    }
}

/// Floating hover card for one preview cell. It belongs to the preview strip and
/// reports the strip as its hit target, so moving onto the card keeps the hover
/// open without stealing selection or scrolling.
private final class ImageHoverPreview : Widget
{
    private enum int maxWidth = 420;
    private enum int maxHeight = 320;
    private enum int pad = 10;
    private enum int labelHeight = 20;

    private Widget _owner;
    private RgbaImage _image;
    private string _label;

    this(Widget owner)
    {
        _owner = owner;
        setComposited(true);
        layoutHints().excludeFromLayout = true;
        setVisible(false);
    }

    void setContent(RgbaImage image, string label)
    {
        _image = image;
        _label = label;
        invalidate();
    }

    string labelForTesting() const
    {
        return _label;
    }

    protected override Size onMeasure(Size available)
    {
        int width = 120, height = 80;
        if (_image !is null && _image.width() > 0 && _image.height() > 0)
        {
            const sourceWidth = _image.width();
            const sourceHeight = _image.height();
            double scale = min(1.0, min(
                cast(double) (maxWidth - 2 * pad) / sourceWidth,
                cast(double) (maxHeight - 2 * pad - labelHeight) / sourceHeight));
            // Tiny source images would otherwise open a nearly invisible card.
            // Upscaling makes the hover useful without changing the source.
            if (sourceWidth < 160 && sourceHeight < 160)
                scale = min(160.0 / maxInt(sourceWidth, sourceHeight),
                    cast(double) maxWidth / sourceWidth);
            width = maxInt(1, cast(int) (sourceWidth * scale));
            height = maxInt(1, cast(int) (sourceHeight * scale));
        }
        const result = Size(width + 2 * pad, height + 2 * pad + labelHeight);
        layoutHints().preferredWidth = result.width;
        layoutHints().preferredHeight = result.height;
        return result;
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (_image is null) return;
        const width = bounds().width;
        const height = bounds().height;
        if (width <= 0 || height <= 0) return;
        const palette = theme();
        canvas.drawRoundedRect(Rect(0, 0, width, height), 10,
            palette.panelElevated, palette.border, 1);
        const imageArea = Rect(pad, pad, maxInt(1, width - 2 * pad),
            maxInt(1, height - 2 * pad - labelHeight));
        canvas.fillRoundedRect(imageArea, 6, palette.windowBackground);
        auto clipped = canvas.clipped(imageArea);
        clipped.drawImage(ImagePreviewStrip.fittedRect(imageArea,
            _image.width(), _image.height()), _image);
        canvas.drawTextInRect(Rect(pad, height - labelHeight + 2,
                width - 2 * pad, labelHeight - 4), toUTF32(_label),
            palette.textMuted, 1, HorizontalAlign.left,
            VerticalAlign.middle, true);
    }

    override Widget hitTest(Point globalPoint)
    {
        if (!visible() || !enabled()) return null;
        return containsLocal(globalToLocal(globalPoint)) ? _owner : null;
    }

    protected override void onTick(double deltaSeconds)
    {
        if (_owner is null || _owner.parent() is null)
            if (parent() !is null) parent().remove(this);
    }
}

private string thumbnailKey(const ref ChatImageAttachment image)
{
    if (image.blob.length) return "blob:" ~ image.blob;
    if (image.originalBlob.length) return "original:" ~ image.originalBlob;
    if (image.base64Data.length)
        return "inline:" ~ sha256Of(image.base64Data).toHexString().idup;
    return "unavailable:" ~ image.name ~ ":" ~ image.mimeType;
}

private RgbaImage cachedThumbnail(const ref ChatImageAttachment image)
{
    const key = thumbnailKey(image);
    if (auto found = key in thumbnailCache) return found.image;

    ++thumbnailDecodes;
    auto entry = new ThumbnailCacheEntry();
    string payload = image.base64Data;
    try
    {
        if (payload.length == 0)
        {
            auto store = AttachmentStore(buildPath(opencodeStateDirectory(),
                "attachments"));
            if (image.blob.length) payload = store.get(image.blob);
            else if (image.originalBlob.length)
                payload = store.get(image.originalBlob);
        }
        if (payload.length > 0)
        {
            const bytes = Base64.decode(payload);
            if (bytes.length > 0)
                entry.image = fitImage(decodeImage(bytes,
                    image.name.length > 0 ? image.name : "image"), 192,
                    ImageResample.box);
        }
    }
    catch (Exception)
    {
        return null;
    }
    if (entry.image is null) return null;
    entry.bytes = key.length + 128 +
        cast(size_t) entry.image.width() * entry.image.height() * 4;

    thumbnailCache[key] = entry;
    thumbnailCacheOrder ~= key;
    thumbnailCacheBytes += entry.bytes;
    // Drop the oldest decoded image when the budget is exceeded. A strip still
    // displaying one keeps its own reference, so eviction never blanks a row.
    while (thumbnailCacheBytes > thumbnailCacheBudget &&
        thumbnailCacheOrder.length > 1)
    {
        const oldest = thumbnailCacheOrder[0];
        thumbnailCacheOrder = thumbnailCacheOrder[1 .. $];
        if (auto evicted = oldest in thumbnailCache)
        {
            thumbnailCacheBytes -= evicted.bytes;
            thumbnailCache.remove(oldest);
        }
    }
    return entry.image;
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

unittest
{
    // Base64, including the two partial-tail cases and the empty input.
    assert(base64Encode(cast(ubyte[]) []) == "");
    assert(base64Encode(cast(ubyte[]) "M") == "TQ==");
    assert(base64Encode(cast(ubyte[]) "Ma") == "TWE=");
    assert(base64Encode(cast(ubyte[]) "Man") == "TWFu");
    assert(base64Encode(cast(ubyte[]) "hello world") ==
        "aGVsbG8gd29ybGQ=");

    // Magic bytes decide the mime type, not the extension.
    ubyte[12] pngHeader = [0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A,
        0, 0, 0, 0];
    assert(attachmentImageKindForBytes(pngHeader[]) == "image/png");
    ubyte[3] jpegHeader = [0xFF, 0xD8, 0xFF];
    assert(attachmentImageKindForBytes(jpegHeader[]) == "image/jpeg");
    ubyte[12] webpHeader = ['R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'E', 'B',
        'P'];
    assert(attachmentImageKindForBytes(webpHeader[]) == "image/webp");
    assert(attachmentImageKindForBytes(cast(ubyte[]) "not an image") == "");

    import std.algorithm.searching : startsWith;
    import std.string : indexOf;

    auto image = attachmentImageForData("image/png", "shot.png",
        cast(ubyte[]) "Man");
    assert(image.base64Data == "TWFu" && image.mimeType == "image/png");
    Attachment attached;
    attached.isFile = true;
    attached.isImage = true;
    attached.name = "shot.png";
    attached.image = image;
    attached.bytes = 3;
    assert(attachmentsContainImage([attached]));
    assert(attachmentImages([attached]).length == 1);
    assert(attachmentChipLabel(attached).startsWith("image: shot.png"));
    assert(attachmentContextBlock([attached]).indexOf("inline image/png") >= 0);
    assert(attachmentVisibleSummary([attached]).length == 0);
    assert(attachmentImageUnsupportedNote("glm-5.3").indexOf("glm-5.3") >= 0);
}
