module quality_console;
import aurora;
import auroraopencode.appui : OpenCodeRoot, commandLineConversationsProjectName;
import auroraopencode.core : opencodeTheme;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.stdio : stdin, stdout, writeln;
import std.string : strip;
import std.json : JSONValue;
import std.file : getcwd;

// Isolated live-quality fixture: the real desktop root, tools and persistence.
// APPDATA and workspace are supplied by the existing benchmark driver.
int main(string[] args)
{
    import auroraopencode.tools : runFilesystemHelperMode;
    const filesystemCode = runFilesystemHelperMode(args);
    if (filesystemCode >= 0) return filesystemCode;
    WindowOptions options; options.renderer = RendererPreference.software;
    options.width = 1200; options.height = 800;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window); window.setRoot(root);
    scope(exit) { root.shutdownClient(); window.close(); }
    const ready = MonoTime.currTime + 10.seconds;
    while (root.startupPendingForTesting() && MonoTime.currTime < ready)
    { window.onNativeTick(0.02); Thread.sleep(5.msecs); }
    // Match source/app.d's console entry point, including its route override;
    // a GUI chat otherwise inherits the model's default High thinking mode.
    root.setConsoleDefaultModel("deepseek/deepseek-v4.1-flash-fast", false);
    root.startConversationInProject(commandLineConversationsProjectName, getcwd());
    foreach (line; stdin.byLine())
    {
        const prompt = line.idup.strip();
        if (prompt == "exit" || prompt == "quit") break;
        root.setInputForTesting(prompt); root.sendForTesting();
        const deadline = MonoTime.currTime + 1800.seconds;
        do { window.onNativeTick(0.02); Thread.sleep(5.msecs); }
        while (root.turnBusyForTesting() && MonoTime.currTime < deadline);
        JSONValue value;
        value["reply"] = root.lastAssistantContentForTesting();
        value["taskStatus"] = root.taskStatusForTesting();
        value["turnStatus"] = root.turnStatusForTesting();
        value["verificationStatus"] = root.verificationStatusForTesting();
        value["error"] = root.lastAssistantErrorForTesting();
        writeln(value.toString()); stdout.flush();
    }
    return 0;
}
