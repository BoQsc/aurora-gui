module computeruse_input_test;

import auroraopencode.computeruse : experimentalComputerUseExecute,
    setComputerUseVirtualPointer;
import std.file : readText;
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
    auto cases = parseJSON(readText(args[1])).array;
    foreach (item; cases)
    {
        auto before = GetForegroundWindow();
        auto result = experimentalComputerUseExecute(item.toString(), "");
        JSONValue output;
        output["failed"] = result.failed;
        output["output"] = result.output;
        output["images"] = cast(long) result.images.length;
        output["foreground_unchanged"] = before is GetForegroundWindow();
        writeln(output.toString());
        Thread.sleep(150.msecs);
    }
    return 0;
}
