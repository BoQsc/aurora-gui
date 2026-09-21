// Direct probe of the real drop path. The path is a compile-time constant so
// argv handling cannot be fooled by spaces or by argv[0].
module image_drop_probe;

import auroraopencode.attachments;
import auroraopencode.core;
import std.stdio : writeln, writefln;

private immutable string probePath =
    "C:\\Users\\Windows10_new\\Pictures\\Screenshots\\before.png";

void main(string[] args)
{
    // argv[1] is argv[0] under this build (WinMain entry), so the argument is
    // deliberately ignored: the probed file is fixed at compile time.
    const path = probePath;
    writeln("PROBING: ", path);

    auto attachment = attachmentForFile(path);
    writefln("isFile=%s isImage=%s name=%s bytes=%d bodyLen=%d",
        attachment.isFile, attachment.isImage, attachment.name,
        attachment.bytes, attachment.body.length);
    writefln("mime=[%s] base64Len=%d", attachment.image.mimeType,
        attachment.image.base64Data.length);
    if (attachment.body.length > 0)
        writeln("BODY (first 200): ",
            attachment.body[0 .. (attachment.body.length > 200 ? 200 : $)]);

    const model = "deepseek-v4.1-flash";
    writefln("isVisionModel(%s)=%s", model, isVisionModel(model));
    writefln("attachmentsContainImage=%s",
        attachmentsContainImage([attachment]));
    auto images = attachmentImages([attachment]);
    writefln("attachmentImages=%d", images.length);
    if (images.length > 0)
        writefln("dataUrl=%s", "data:" ~ images[0].mimeType ~ ";base64," ~
            images[0].base64Data[0 .. 24] ~ "…");
}
