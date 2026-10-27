module experiment.aurorahost.tcp_control;

import experiment.aurorahost.control : ControlServer;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.socket;
import std.string : indexOf;

/**
 * Loopback JSON-lines transport for the existing control command queue.
 *
 * Commands arrive on a socket and are queued exactly like stdin lines. Every
 * RESPONSE and EVENT is mirrored to connected clients, so the Python bridge is
 * no longer required to drive a host.
 */
class TcpControl
{
    private ControlServer _server;
    private ushort _port;
    private TcpSocket _listener;
    private Thread _acceptThread;

    private Socket[] _clients;
    private Mutex _mutex;
    private bool _running;

    this(ControlServer server, ushort port)
    {
        _server = server;
        _port = port;
        _mutex = new Mutex();
    }

    void start()
    {
        _listener = new TcpSocket(AddressFamily.INET);
        _listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
        _listener.bind(new InternetAddress("127.0.0.1", _port));
        _listener.listen(16);
        _running = true;
        _server.mirror(delegate(string line) { broadcast(line); });
        _acceptThread = new Thread(delegate() { acceptLoop(); });
        _acceptThread.isDaemon = true;
        _acceptThread.start();
    }

    void stop()
    {
        _running = false;
        _server.mirror(null);
        if (_listener !is null)
            _listener.close();
        synchronized (_mutex)
        {
            foreach (client; _clients)
            {
                try client.close();
                catch (Exception) {}
            }
            _clients.length = 0;
        }
    }

    ushort port() const
    {
        return _port;
    }

    private void acceptLoop()
    {
        while (_running)
        {
            Socket client;
            try
                client = _listener.accept();
            catch (Exception)
            {
                if (!_running)
                    break;
                continue;
            }
            if (!_running)
            {
                try client.close();
                catch (Exception) {}
                break;
            }
            synchronized (_mutex)
                _clients ~= client;
            clientLoop(client);
        }
    }

    private void clientLoop(Socket client)
    {
        char[4096] buffer;
        string carry;
        try
        {
            while (_running)
            {
                const received = client.receive(buffer);
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
                    if (line.length > 0)
                    {
                        _server.submit(line.idup);
                    }
                }
            }
        }
        catch (Exception) {}
        removeClient(client);
    }

    private void removeClient(Socket client)
    {
        synchronized (_mutex)
        {
            foreach (index, current; _clients)
            {
                if (current is client)
                {
                    _clients = _clients[0 .. index] ~ _clients[index + 1 .. $];
                    break;
                }
            }
        }
        try client.close();
        catch (Exception) {}
    }

    private void broadcast(string line)
    {
        const data = line ~ "\n";
        synchronized (_mutex)
        {
            size_t index = 0;
            while (index < _clients.length)
            {
                try
                {
                    _clients[index].send(data);
                    index++;
                }
                catch (Exception)
                {
                    try _clients[index].close();
                    catch (Exception) {}
                    _clients = _clients[0 .. index] ~ _clients[index + 1 .. $];
                }
            }
        }
    }
}
