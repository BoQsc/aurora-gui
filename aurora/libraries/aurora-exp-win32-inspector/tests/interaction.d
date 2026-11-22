// SPDX-License-Identifier: 0BSD
/**
 * Interaction test: load an image, then click Verify, Emit, and Run through the
 * real widget input path (UiTestDriver), checking the resulting status.
 *
 * Usage: win32-inspector-interaction <image.exe>
 */
module interaction;

import aurora;
import aurorainspector.inspector : InspectorRoot;
import std.algorithm.searching : canFind, startsWith;
import std.stdio : stderr;

private void fail(string message)
{
    stderr.writeln("inspector interaction failed: ", message);
    throw new Exception(message);
}

int main(string[] args)
{
    if (args.length < 2)
    {
        stderr.writeln("usage: win32-inspector-interaction <image.exe>");
        return 2;
    }

    WindowOptions options;
    options.title = "Aurora Win32 Laboratory";
    options.width = 1280;
    options.height = 820;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new InspectorRoot(window, args[1]);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    driver.paint();

    if (!root.hasImage())
        fail("the startup image was not loaded");

    // Open the file dialog and dismiss it; the dialog is part of the real path
    // a user takes, and Escape must leave the loaded image untouched.
    driver.click(root.openButtonCenter());
    driver.paint();
    driver.pressKey(Key.escape);
    driver.paint();
    if (!root.hasImage())
        fail("dismissing the open dialog lost the loaded image");

    driver.click(root.verifyButtonCenter());
    driver.paint();
    if (!root.verificationMessage().startsWith("PASS"))
        fail("Verify did not report a byte-identical rebuild: "
            ~ root.verificationMessage());

    driver.click(root.emitButtonCenter());
    driver.paint();
    if (!root.statusMessage().startsWith("Emitted"))
        fail("Emit did not report a written image: " ~ root.statusMessage());

    driver.click(root.runButtonCenter());
    driver.paint();
    if (!root.statusMessage().canFind("thread exit 0"))
        fail("Run emitted did not execute with exit code 0: "
            ~ root.statusMessage());

    window.close();
    return 0;
}
