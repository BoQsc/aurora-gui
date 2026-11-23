module session_smoke;

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import opencodelite.session : ChatSession, SessionEventKind;
import opencodelite.settings : LiteSettings, loadSettings, openCodeBaseUrl,
    openCodeModel, saveSettings;
import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : environment;
import std.stdio : stderr, writeln;
import std.string : strip;

int main(string[] args)
{
    if (args.length < 3)
    {
        stderr.writeln("usage: session-smoke <sse-url> <settings-path>");
        return 2;
    }

    LiteSettings settings;
    settings.baseUrl = args[1];
    settings.model = "mock";
    settings.apiKey = "";
    auto session = new ChatSession(settings);
    session.send("hello");

    const appData = buildPath(tempDir(), "aurora-lite-settings-test");
    if (exists(appData))
        rmdirRecurse(appData);
    mkdirRecurse(appData);
    environment["APPDATA"] = appData;
    const legacyDirectory = buildPath(appData, "Aurora OpenCode",
        "Aurora OpenCode");
    mkdirRecurse(legacyDirectory);
    write(buildPath(legacyDirectory, "settings.json"),
        `{"baseUrl":"https://opencode.ai/zen/go/v1",` ~
        `"model":"deepseek-v4.1-flash","apiKey":"",` ~
        `"providerKeys":[{"providerId":"opencode",` ~
        `"baseUrl":"https://opencode.ai/zen/go/v1",` ~
        `"apiKey":"legacy-opencode-key","additionalApiKey":"",` ~
        `"extraApiKeys":[],"activeKeyIndex":0}]}`);
    const migrated = loadSettings();
    const defaultsOk = migrated.baseUrl == openCodeBaseUrl
        && migrated.model == openCodeModel
        && migrated.apiKey == "legacy-opencode-key";

    string assistant;
    bool done;
    bool failed;
    string failure;
    const deadline = MonoTime.currTime + seconds(20);
    while (MonoTime.currTime < deadline && !done && !failed)
    {
        foreach (event; session.drain())
        {
            final switch (event.kind)
            {
                case SessionEventKind.delta:
                    assistant ~= event.text;
                    break;
                case SessionEventKind.done:
                    done = true;
                    break;
                case SessionEventKind.failed:
                    failed = true;
                    failure = event.text;
                    break;
            }
        }
        if (!done && !failed)
            Thread.sleep(10.msecs);
    }

    saveSettings(settings, args[2]);
    const loaded = loadSettings(args[2]);
    const settingsRoundTrip = loaded.baseUrl == settings.baseUrl
        && loaded.model == settings.model
        && loaded.apiKey == settings.apiKey;
    writeln("assistant=", assistant);
    writeln("done=", done, " failed=", failed,
        " settings=", settingsRoundTrip, " defaults=", defaultsOk);
    if (failure.length != 0)
        writeln("failure=", failure);
    try
        remove(args[2]);
    catch (Exception)
    {
    }
    return assistant.strip == "Hello world" && done && !failed
        && settingsRoundTrip && defaultsOk ? 0 : 1;
}
