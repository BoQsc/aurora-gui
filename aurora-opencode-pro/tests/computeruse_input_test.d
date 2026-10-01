module computeruse_input_test;

import auroraopencode.computeruse : experimentalComputerUseExecute,
    setComputerUseVirtualPointer, setComputerUseProvider, setComputerUseSetting,
    requestComputerUseAbort, clearComputerUseAbort;
import std.file : readText, write;
import std.base64 : Base64;
import std.path : buildPath;
import std.conv : to;
import std.json : parseJSON, JSONValue;
import std.stdio : writeln;
import core.thread : Thread;
import core.time : msecs;
import core.sys.windows.windows : CreateWindowExW, DestroyWindow,
    GetForegroundWindow, WS_VISIBLE, WS_POPUP;

int main(string[] args)
{
    // This process represents Aurora: input into its own window must be refused.
    auto own = CreateWindowExW(0x08000000, "STATIC"w.ptr,
        "Aurora Input Driver Self"w.ptr, WS_VISIBLE | WS_POPUP,
        850, 200, 180, 100, null, null, null, null);
    assert(own !is null);
    scope (exit) DestroyWindow(own);
    setComputerUseVirtualPointer(true);
    scope (exit) setComputerUseVirtualPointer(false);
    if (args.length > 3)
    {
        setComputerUseSetting(true);
        setComputerUseProvider(args[3], "local-fixture-key", "deepseek-v4.1-flash");
    }
    auto cases = parseJSON(readText(args[1])).array;
    foreach (index, item; cases)
    {
        auto before = GetForegroundWindow();
        Thread interrupter;
        if (auto delay = "test_abort_after_ms" in item.object)
        {
            const milliseconds = delay.integer;
            interrupter = new Thread({ Thread.sleep(msecs(milliseconds)); requestComputerUseAbort(); });
            interrupter.start();
        }
        auto result = experimentalComputerUseExecute(item.toString(), "");
        if (interrupter !is null) { interrupter.join(); clearComputerUseAbort(); }
        JSONValue output;
        output["failed"] = result.failed;
        output["output"] = result.output;
        output["images"] = cast(long) result.images.length;
        JSONValue[] details;
        foreach (imageIndex, attachment; result.images)
        {
            JSONValue detail;
            detail["name"] = attachment.name;
            detail["mime"] = attachment.mimeType;
            if (args.length > 2)
            {
                const path = buildPath(args[2], "frame-" ~ to!string(index) ~ "-" ~ to!string(imageIndex) ~ ".jpg");
                write(path, Base64.decode(attachment.base64Data));
                detail["path"] = path;
            }
            details ~= detail;
        }
        output["image_details"] = details;
        output["foreground_unchanged"] = before is GetForegroundWindow();
        writeln(output.toString());
        Thread.sleep(150.msecs);
    }
    return 0;
}
