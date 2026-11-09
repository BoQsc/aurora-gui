// Headless real execution owner for opt-in hosted-agent utility benchmarks.
module native_services_host;
import auroraopencode.tools : runFilesystemHelperMode, runNativeUtilityMode;
import auroraopencode.sessionserver : runSessionServer;
import std.stdio : stderr;
int main(string[] args)
{
    const native = runNativeUtilityMode(args);
    if (native >= 0) return native;
    const filesystem = runFilesystemHelperMode(args);
    if (filesystem >= 0) return filesystem;
    if (args.length >= 2 && args[1] == "--session-server") return runSessionServer(args[2 .. $]);
    stderr.writeln("Use --session-server or --aurora-native-tool");
    return 2;
}
