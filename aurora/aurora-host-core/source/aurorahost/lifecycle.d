module aurorahost.lifecycle;

import std.file : exists, mkdirRecurse, readText, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.process : environment;

/**
 * Durable run intent for a host application.
 *
 * A normal window close records "closed". A process that disappears before
 * recording that intent leaves "running" (or "failed") behind, which the next
 * launch reports as an unclean shutdown. This makes an unexpected close
 * diagnosable instead of indistinguishable from a deliberate development stop.
 */
struct HostRunJournal
{
    private string _path;
    private bool _started;
    private bool _finished;
    bool previousUnclean;

    @disable this(this);

    /** Begin a host run and report whether the previous run did not close. */
    void begin(string appId)
    {
        auto root = environment.get("LOCALAPPDATA", "");
        if (root.length == 0)
            root = environment.get("APPDATA", "");
        if (root.length == 0)
            root = ".";
        _path = buildPath(root, appId, "run-state.json");
        const directory = dirName(_path);
        if (!exists(directory))
            mkdirRecurse(directory);
        if (exists(_path))
        {
            try
            {
                const previous = parseJSON(readText(_path));
                if (auto status = "status" in previous.object)
                    previousUnclean = status.type == JSONType.string &&
                        (status.str == "running" || status.str == "failed");
            }
            catch (Exception)
            {
                previousUnclean = true;
            }
        }
        writeState("running", "");
        _started = true;
    }

    /** Record a deliberate close, such as the user closing the window. */
    void close(string reason)
    {
        if (!_started || _finished)
            return;
        writeState("closed", reason);
        _finished = true;
    }

    /** Record a host failure without pretending it was a deliberate close. */
    static void recordFailure(string appId, string reason)
    {
        HostRunJournal journal;
        journal._path = buildPath(environment.get("LOCALAPPDATA", "."), appId,
            "run-state.json");
        const directory = dirName(journal._path);
        if (!exists(directory))
            mkdirRecurse(directory);
        journal.writeState("failed", reason);
    }

    private void writeState(string status, string reason)
    {
        JSONValue value;
        value["status"] = status;
        value["previousUnclean"] = previousUnclean;
        if (reason.length > 0)
            value["reason"] = reason;
        write(_path, value.toString() ~ "\n");
    }
}