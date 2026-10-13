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
                if (auto progress = "_fixtureProgress" in fields.object)
                    if (progress.boolean)
                    {
                        import auroraopencode.searchprogress : SearchProgress, encodeSearchProgress;
                        SearchProgress scan;
                        scan.phase = "Searching contents";
                        scan.root = request["workspace"].str;
                        scan.path = buildPath(scan.root, "large-log.txt");
                        scan.query = "needle";
                        scan.files = 77; scan.directories = 4; scan.entries = 81;
                        scan.totalsKnown = true; scan.candidateFiles = 100; scan.processedFiles = 76;
                        scan.lines = 50000; scan.bytes = 8 * 1024 * 1024;
                        scan.matches = 2;
                        scan.latest = ["large-log.txt:15: needle", "large-log.txt:29: needle"];
                        if (request["name"].str == "read")
                        {
                            import auroraopencode.readprogress : ReadProgress, encodeReadProgress;
                            ReadProgress reading;
                            reading.phase = "Reading file";
                            reading.path = buildPath(scan.root, fields["filePath"].str);
                            reading.totalKnown = true; reading.totalBytes = 10000; reading.bytesRead = 2500;
                            reading.line = 30; reading.collected = 2;
                            reading.preview = ["29: first returned line", "30: second returned line"];
                            write(request["progressPath"].str, encodeReadProgress(reading));
                        }
                        else write(request["progressPath"].str, encodeSearchProgress(scan));
                    }
                write(buildPath(request["workspace"].str,
                    "host-" ~ to!string(thisProcessID) ~ ".pid"), "ready");
                Thread.sleep(120.seconds);
            }
    }
    catch (Exception) {} // let the real host report malformed arguments
    return runFilesystemHelperMode(args);
}
