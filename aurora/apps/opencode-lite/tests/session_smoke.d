module session_smoke;

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import opencodelite.session : ChatSession, SessionEventKind;
import opencodelite.settings : LiteSettings, loadSettings, saveSettings;
import std.file : remove;
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
        " settings=", settingsRoundTrip);
    if (failure.length != 0)
        writeln("failure=", failure);
    try
        remove(args[2]);
    catch (Exception)
    {
    }
    return assistant.strip == "Hello world" && done && !failed
        && settingsRoundTrip ? 0 : 1;
}
