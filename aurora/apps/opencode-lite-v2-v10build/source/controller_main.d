module controller_main;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : msecs;
import opencodelite.controller : LiteController, LiteView;
import opencodelite.settings : loadSettings;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.socket : AddressFamily, InternetAddress, Socket, TcpSocket;
import std.stdio : stderr, stdout, writeln;
import std.string : indexOf, startsWith;

/// The controller's host transport. The host owns the scene; this process only
/// sends commands and consumes events, so it can be rebuilt and restarted while
/// the host window stays open.
final class HostLink
{
    private Socket _socket;
    private Mutex _mutex;
    private string[] _lines;
    private JSONValue[] _events;
    private bool _closed;
    private long _nextId;

    this(ushort port)
    {
        _mutex = new Mutex();
        foreach (attempt; 0 .. 100)
        {
            try
            {
                _socket = new TcpSocket(AddressFamily.INET);
                _socket.connect(new InternetAddress("127.0.0.1", port));
                break;
            }
            catch (Exception)
            {
                _socket = null;
                Thread.sleep(50.msecs);
            }
        }
        if (_socket is null)
            throw new Exception("could not connect to the host control port");
        auto reader = new Thread(&readLoop);
        reader.isDaemon = true;
        reader.start();
    }

    private void readLoop()
    {
        char[4096] buffer;
        string carry;
        try
        {
            while (true)
            {
                const received = _socket.receive(buffer);
                if (received <= 0)
                    break;
                carry ~= buffer[0 .. cast(size_t) received].idup;
                while (true)
                {
                    const newline = carry.indexOf('\n');
                    if (newline < 0)
                        break;
                    auto line = carry[0 .. newline];
                    carry = carry[newline + 1 .. $];
                    if (line.length > 0 && line[$ - 1] == '\r')
                        line = line[0 .. $ - 1];
                    if (line.length != 0)
                    {
                        // Asynchronous action events arrive without a
                        // request/response exchange. Queue them as events so
                        // the controller loop sees them immediately.
                        if (line.startsWith("EVENT "))
                        {
                            try
                            {
                                const event = parseJSON(line[6 .. $]);
                                synchronized (_mutex)
                                    _events ~= event;
                            }
                            catch (Exception)
                            {
                            }
                        }
                        else
                        {
                            synchronized (_mutex)
                                _lines ~= line.idup;
                        }
                    }
                }
            }
        }
        catch (Exception)
        {
        }
        synchronized (_mutex)
            _closed = true;
    }

    private string nextLine()
    {
        while (true)
        {
            synchronized (_mutex)
            {
                if (_lines.length != 0)
                {
                    const line = _lines[0];
                    _lines = _lines[1 .. $];
                    return line;
                }
                if (_closed)
                    return "";
            }
            Thread.sleep(1.msecs);
        }
    }

    private JSONValue exchange(JSONValue payload)
    {
        ++_nextId;
        payload["id"] = JSONValue(_nextId);
        const wire = payload.toString() ~ "\n";
        _socket.send(wire);
        while (true)
        {
            const line = nextLine();
            if (line.length == 0)
                throw new Exception("host control channel closed");
            if (line.startsWith("EVENT "))
            {
                synchronized (_mutex)
                    _events ~= parseJSON(line[6 .. $]);
                continue;
            }
            if (!line.startsWith("RESPONSE "))
                continue;
            const response = parseJSON(line[9 .. $]);
            if (response["id"].get!long != _nextId)
                continue;
            if (!response["ok"].get!bool)
                throw new Exception("host command failed: " ~
                    response["error"].get!string);
            return response;
        }
    }

    JSONValue request(string command, string[string] fields = null)
    {
        JSONValue payload;
        payload["command"] = JSONValue(command);
        foreach (name, value; fields)
            payload[name] = JSONValue(value);
        return exchange(payload);
    }

    void setEnabled(string id, bool enabled)
    {
        JSONValue payload;
        payload["command"] = JSONValue("setEnabled");
        payload["node"] = JSONValue(id);
        payload["enabled"] = JSONValue(enabled);
        exchange(payload);
    }

    JSONValue[] takeEvents()
    {
        synchronized (_mutex)
        {
            auto result = _events.dup;
            _events = null;
            return result;
        }
    }

    bool closed()
    {
        synchronized (_mutex)
            return _closed;
    }
}

final class RemoteLiteView : LiteView
{
    private HostLink _link;

    this(HostLink link)
    {
        _link = link;
    }

    string text(string id)
    {
        return _link.request("getText", ["node": id])["text"].get!string;
    }

    bool setText(string id, string text)
    {
        _link.request("setText", ["node": id, "text": text]);
        return true;
    }

    bool setEnabled(string id, bool enabled)
    {
        _link.setEnabled(id, enabled);
        return true;
    }
}

int main(string[] args)
{
    ushort port;
    for (size_t index = 1; index < args.length; ++index)
    {
        if (args[index] == "--port" && index + 1 < args.length)
        {
            port = to!ushort(args[index + 1]);
            ++index;
        }
    }
    if (port == 0)
    {
        stderr.writeln("usage: aurora-opencode-lite-v2-controller --port <port>");
        return 2;
    }

    try
    {
        HostLink link;
        for (int attempt = 0; attempt < 100 && link is null; ++attempt)
        {
            try
                link = new HostLink(port);
            catch (Exception)
                Thread.sleep(20.msecs);
        }
        if (link is null)
            throw new Exception("could not connect to the host control port");
        auto view = new RemoteLiteView(link);
        auto controller = new LiteController(view, loadSettings());
        controller.refreshView();
        while (!link.closed())
        {
            foreach (event; link.takeEvents())
            {
                if (event.type != JSONType.object)
                    continue;
                auto kind = "event" in event.object;
                if (kind is null || kind.str != "action")
                    continue;
                auto node = "node" in event.object;
                auto action = "action" in event.object;
                if (node !is null && action !is null)
                {
                    controller.handleAction(node.str, action.str);
                }
            }
            controller.service(0.016);
            Thread.sleep(16.msecs);
        }
        return 0;
    }
    catch (Exception error)
    {
        stderr.writeln("lite-controller: " ~ error.msg);
        return 1;
    }
}
