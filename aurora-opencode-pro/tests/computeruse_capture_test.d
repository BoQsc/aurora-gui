module computeruse_capture_test;

// Drives the production computer-use tool against disposable fixture windows
// and reports each call's text plus the frames it attached. The Python harness
// owns the windows and checks what the frames actually depict.

import auroraopencode.computeruse : experimentalComputerUseExecute,
    experimentalComputerUseTools, setComputerUseVirtualPointer,
    setComputerUseSetting;
import std.file : readText, write;
import std.base64 : Base64;
import std.path : buildPath;
import std.conv : to;
import std.json : parseJSON, JSONValue;
import std.stdio : writeln;
import core.thread : Thread;
import core.time : msecs;
import core.sys.windows.windows : GetForegroundWindow;

int main(string[] args)
{
    setComputerUseSetting(true);
    setComputerUseVirtualPointer(true);
    scope (exit) setComputerUseVirtualPointer(false);
    // The advertised schema is what the model sees; a malformed parameter
    // block would make the tool unusable even though the D code compiles.
    auto tools = experimentalComputerUseTools();
    assert(tools.length == 1);
    auto schema = parseJSON(tools[0].parametersJson);
    assert("full_screen" in schema["properties"].object);
    assert("window" in schema["properties"].object);
    auto cases = parseJSON(readText(args[1])).array;
    foreach (index, item; cases)
    {
        auto before = GetForegroundWindow();
        auto result = experimentalComputerUseExecute(item.toString(), "");
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
            const path = buildPath(args[2], "frame-" ~ to!string(index) ~ "-" ~
                to!string(imageIndex) ~ ".jpg");
            write(path, Base64.decode(attachment.base64Data));
            detail["path"] = path;
            details ~= detail;
        }
        output["image_details"] = details;
        output["foreground_unchanged"] = before is GetForegroundWindow();
        writeln(output.toString());
        Thread.sleep(150.msecs);
    }
    return 0;
}
