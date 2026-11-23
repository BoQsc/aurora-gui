module opencodev3.session;

import std.array : replace;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.process : environment;

struct V3Session
{
    string id;
    string name;
    string transcript;
}

string v3SessionPath()
{
    auto root = environment.get("APPDATA", "");
    if (root.length == 0)
        root = environment.get("LOCALAPPDATA", "");
    return buildPath(root, "AuroraOpenCodeLiteV3", "sessions.json");
}

private string v2ConversationPath()
{
    auto root = environment.get("APPDATA", "");
    return buildPath(root, "AuroraOpenCodeLiteV2", "conversation.json");
}

final class SessionStore
{
    private V3Session[] _sessions;
    private string _active;
    private uint _nextId = 1;
    private bool _dirty;

    this()
    {
        load();
        if (_sessions.length == 0)
            migrateV2();
    }

    string[] list()
    {
        string[] lines;
        lines ~= "SESSIONS " ~ to!string(_sessions.length);
        foreach (session; _sessions)
            lines ~= "SESSION " ~ session.id ~ " " ~
                session.name.replace(" ", "_") ~ " " ~
                (session.id == _active ? "active" : "idle");
        return lines;
    }

    string create(string name)
    {
        if (name.length == 0)
            name = "Session";
        V3Session session;
        session.id = "s" ~ to!string(_nextId++);
        session.name = name;
        _sessions ~= session;
        _active = session.id;
        _dirty = true;
        save();
        return session.id;
    }

    bool use(string id)
    {
        foreach (session; _sessions)
            if (session.id == id)
            {
                _active = id;
                _dirty = true;
                save();
                return true;
            }
        return false;
    }

    bool rename(string id, string name)
    {
        foreach (ref session; _sessions)
            if (session.id == id)
            {
                session.name = name;
                _dirty = true;
                save();
                return true;
            }
        return false;
    }

    bool remove(string id)
    {
        for (size_t i = 0; i < _sessions.length; ++i)
            if (_sessions[i].id == id)
            {
                _sessions = _sessions[0 .. i] ~ _sessions[i + 1 .. $];
                if (_active == id)
                    _active = _sessions.length ? _sessions[0].id : "";
                _dirty = true;
                save();
                return true;
            }
        return false;
    }

    void save()
    {
        const path = v3SessionPath();
        const directory = dirName(path);
        if (!exists(directory))
            mkdirRecurse(directory);
        JSONValue document;
        document["schemaVersion"] = JSONValue(3);
        document["active"] = _active;
        document["nextId"] = JSONValue(cast(long) _nextId);
        JSONValue[] rows;
        foreach (session; _sessions)
        {
            JSONValue row;
            row["id"] = session.id;
            row["name"] = session.name;
            row["transcript"] = session.transcript;
            rows ~= JSONValue(row);
        }
        document["sessions"] = JSONValue(rows);
        write(path, document.toString() ~ "\n");
        _dirty = false;
    }

    private void load()
    {
        const path = v3SessionPath();
        if (!exists(path))
            return;
        try
        {
            const document = parseJSON(readText(path));
            if ("active" in document.object)
                _active = document["active"].str;
            if ("nextId" in document.object)
                _nextId = cast(uint) document["nextId"].integer;
            if (auto rows = "sessions" in document.object)
            {
                if (rows.type != JSONType.array)
                    return;
                foreach (row; rows.array)
                {
                    V3Session session;
                    session.id = row["id"].str;
                    session.name = row["name"].str;
                    session.transcript = row["transcript"].str;
                    _sessions ~= session;
                }
            }
            if (_active.length == 0 && _sessions.length)
                _active = _sessions[0].id;
        }
        catch (Exception)
        {
            _sessions = [];
            _active = "";
            _nextId = 1;
        }
    }

    private void migrateV2()
    {
        const legacy = v2ConversationPath();
        if (!exists(legacy))
            return;
        try
        {
            const document = parseJSON(readText(legacy));
            string transcript = "New session.\n";
            if (auto value = "transcript" in document.object)
                if (value.type == JSONType.string)
                    transcript = value.str;
            V3Session session;
            session.id = "s" ~ to!string(_nextId++);
            session.name = "Imported v2";
            session.transcript = transcript;
            _sessions ~= session;
            _active = session.id;
            save();
        }
        catch (Exception)
        {
        }
    }
}
