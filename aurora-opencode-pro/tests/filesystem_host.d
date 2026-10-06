module filesystem_host;
import auroraopencode.tools : runFilesystemHelperMode;
int main(string[] args)
{
    // Only this fixture host can simulate a syscall that never returns.
    import std.file : readText, write;
    import std.json : parseJSON;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.conv : to;
    import core.thread : Thread;
    import core.time : seconds;
    try if (args.length == 3)
    {
        auto request = parseJSON(readText(args[2]));
        auto fields = parseJSON(request["arguments"].str);
        if (auto blocked = "_fixtureBlocked" in fields.object)
            if (blocked.boolean)
            {
                write(buildPath(request["workspace"].str,
                    "host-" ~ to!string(thisProcessID) ~ ".pid"), "ready");
                Thread.sleep(120.seconds);
            }
    }
    catch (Exception) {} // let the real host report malformed arguments
    return runFilesystemHelperMode(args);
}
