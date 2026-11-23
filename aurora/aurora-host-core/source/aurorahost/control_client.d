module aurorahost.control_client;

import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.socket : AddressFamily, InternetAddress, Socket, TcpSocket;
import std.string : indexOf, startsWith;

/**
 * Minimal synchronous client for the host's loopback JSON control protocol.
 * Intended for command-line tools and scripts; it never touches the UI thread.
 */
final class ControlClient
{
    private Socket _socket;
    private long _nextId;

    this(ushort port)
    {
        _socket = new TcpSocket(AddressFamily.INET);
        _socket.connect(new InternetAddress("127.0.0.1", port));
    }

    JSONValue request(string command, string[string] fields = null)
    {
        ++_nextId;
        JSONValue payload;
        payload["id"] = JSONValue(_nextId);
        payload["command"] = JSONValue(command);
        if (fields !is null)
            foreach (name, value; fields)
                payload[name] = JSONValue(value);
        _socket.send(payload.toString() ~ "\n");

        char[4096] buffer;
        string carry;
        while (true)
        {
            const received = _socket.receive(buffer);
            if (received <= 0)
                throw new Exception("host control channel closed");
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
                if (line.startsWith("EVENT "))
                    continue;
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
    }

    void close()
    {
        if (_socket !is null)
            _socket.close();
        _socket = null;
    }

    ~this()
    {
        close();
    }
}