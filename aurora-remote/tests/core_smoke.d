module tests.core_smoke;

import auroraremote.capsule;
import auroraremote.crypto;
import auroraremote.protocol;

import core.thread : Thread;
import std.exception : enforce;
import std.socket : AddressFamily, InternetAddress, SocketOption,
    SocketOptionLevel, TcpSocket;
import std.stdio : writeln;

private void verifyEncryptedLoopback()
{
    auto listener = new TcpSocket(AddressFamily.INET);
    scope (exit) listener.close();
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    listener.bind(new InternetAddress("127.0.0.1", 0));
    listener.listen(1);
    const port = (cast(InternetAddress) listener.localAddress).port;

    const idBytes = randomBytes(16);
    const capsule = newConnectionCapsule("127.0.0.1", port, idBytes, 600);
    string serverError;
    bool serverCompleted;
    auto server = new Thread({
        try
        {
            auto socket = listener.accept();
            auto secure = acceptClient(socket, capsule);
            scope (exit) secure.close();
            const request = secure.receive();
            enforce(request.channel == ProtocolChannel.control);
            enforce(request.kind == ControlMessage.ping);
            enforce(request.payload == cast(const(ubyte)[]) "loopback-proof");
            secure.send(ProtocolChannel.control, ControlMessage.pong,
                request.payload);
            serverCompleted = true;
        }
        catch (Exception error) serverError = error.msg;
    });
    server.start();

    auto socket = new TcpSocket(AddressFamily.INET);
    socket.connect(new InternetAddress("127.0.0.1", port));
    auto secure = establishClient(socket, capsule);
    scope (exit) secure.close();
    secure.send(ProtocolChannel.control, ControlMessage.ping,
        cast(const(ubyte)[]) "loopback-proof");
    const response = secure.receive();
    enforce(response.channel == ProtocolChannel.control);
    enforce(response.kind == ControlMessage.pong);
    enforce(response.payload == cast(const(ubyte)[]) "loopback-proof");
    server.join();
    enforce(serverError.length == 0, serverError);
    enforce(serverCompleted, "Encrypted loopback server did not complete.");
}

unittest
{
    verifyEncryptedLoopback();
}

int main()
{
    writeln("Aurora Remote core smoke tests passed");
    return 0;
}
