module auroraremote.protocol;

import auroraremote.capsule : ConnectionCapsule;
import auroraremote.crypto : AuthenticatedCiphertext, aesGcmDecrypt,
    aesGcmEncrypt, constantTimeEqual, hmacSha256, randomBytes;
import core.sync.mutex : Mutex;
import std.exception : enforce;
import std.socket : Socket, SocketShutdown;

enum ProtocolChannel : ubyte
{
    control = 1,
    input = 2,
    video = 3,
    file = 4,
    clipboard = 5,
    telemetry = 6
}

enum ControlMessage : ubyte
{
    ping = 1,
    pong = 2,
    disconnect = 3,
    clipboardRequest = 4
}

struct SecureMessage
{
    ProtocolChannel channel;
    ubyte kind;
    ubyte[] payload;
}

private enum recordHeaderLength = 18;
private enum maximumRecordLength = 16 * 1024 * 1024;

private ubyte[] joined(const(ubyte)[][] parts...)
{
    size_t length;
    foreach (part; parts) length += part.length;
    auto result = new ubyte[length];
    size_t offset;
    foreach (part; parts)
    {
        result[offset .. offset + part.length] = part[];
        offset += part.length;
    }
    return result;
}

private void writeU32(ubyte[] output, size_t offset, uint value)
{
    output[offset] = cast(ubyte)(value >> 24);
    output[offset + 1] = cast(ubyte)(value >> 16);
    output[offset + 2] = cast(ubyte)(value >> 8);
    output[offset + 3] = cast(ubyte) value;
}

private uint readU32(const(ubyte)[] input, size_t offset)
{
    return (cast(uint) input[offset] << 24) |
        (cast(uint) input[offset + 1] << 16) |
        (cast(uint) input[offset + 2] << 8) |
        input[offset + 3];
}

private void writeU64(ubyte[] output, size_t offset, ulong value)
{
    foreach_reverse (shift; 0 .. 8)
        output[offset++] = cast(ubyte)(value >> (shift * 8));
}

private ulong readU64(const(ubyte)[] input, size_t offset)
{
    ulong result;
    foreach (_; 0 .. 8) result = (result << 8) | input[offset++];
    return result;
}

private void sendAll(Socket socket, const(ubyte)[] bytes)
{
    size_t offset;
    while (offset < bytes.length)
    {
        const sent = socket.send(bytes[offset .. $]);
        enforce(sent > 0, "Remote computer closed the connection while sending.");
        offset += sent;
    }
}

private ubyte[] receiveExact(Socket socket, size_t length)
{
    auto result = new ubyte[length];
    size_t offset;
    while (offset < length)
    {
        const received = socket.receive(result[offset .. $]);
        enforce(received > 0,
            "Remote computer closed the connection while receiving.");
        offset += received;
    }
    return result;
}

private struct SessionMaterial
{
    ubyte[] clientToServerKey;
    ubyte[] serverToClientKey;
    ubyte[4] clientToServerSalt;
    ubyte[4] serverToClientSalt;
}

private SessionMaterial deriveSession(const(ubyte)[] token,
    const(ubyte)[] clientNonce, const(ubyte)[] serverNonce)
{
    const master = hmacSha256(token, joined(
        cast(const(ubyte)[]) "aurora-remote/session/v1",
        clientNonce, serverNonce));
    SessionMaterial result;
    result.clientToServerKey = hmacSha256(master,
        cast(const(ubyte)[]) "client-to-server/key");
    result.serverToClientKey = hmacSha256(master,
        cast(const(ubyte)[]) "server-to-client/key");
    const clientSalt = hmacSha256(master,
        cast(const(ubyte)[]) "client-to-server/nonce");
    const serverSalt = hmacSha256(master,
        cast(const(ubyte)[]) "server-to-client/nonce");
    result.clientToServerSalt[] = clientSalt[0 .. 4];
    result.serverToClientSalt[] = serverSalt[0 .. 4];
    return result;
}

final class SecureConnection
{
    private Socket _socket;
    private ubyte[] _sendKey;
    private ubyte[] _receiveKey;
    private ubyte[4] _sendSalt;
    private ubyte[4] _receiveSalt;
    private ulong _sendSequence;
    private ulong _receiveSequence;
    private Mutex _sendMutex;
    private Mutex _stateMutex;

    private this(Socket socket, const(ubyte)[] sendKey,
        const(ubyte)[] receiveKey, const(ubyte)[] sendSalt,
        const(ubyte)[] receiveSalt)
    {
        _socket = socket;
        _sendKey = sendKey.dup;
        _receiveKey = receiveKey.dup;
        _sendSalt[] = sendSalt[];
        _receiveSalt[] = receiveSalt[];
        _sendMutex = new Mutex;
        _stateMutex = new Mutex;
    }

    private Socket socketSnapshot()
    {
        synchronized (_stateMutex)
        {
            enforce(_socket !is null, "Encrypted connection is closed.");
            return _socket;
        }
    }

    void send(ProtocolChannel channel, ubyte kind,
        const(ubyte)[] payload = null)
    {
        synchronized (_sendMutex) sendLocked(channel, kind, payload);
    }

    private void sendLocked(ProtocolChannel channel, ubyte kind,
        const(ubyte)[] payload)
    {
        auto socket = socketSnapshot();
        enforce(payload.length <= maximumRecordLength,
            "Encrypted record is too large.");
        auto header = new ubyte[recordHeaderLength];
        header[0] = 'A';
        header[1] = 'R';
        header[2] = 1;
        header[3] = cast(ubyte) channel;
        header[4] = kind;
        header[5] = 0;
        writeU32(header, 6, cast(uint) payload.length);
        writeU64(header, 10, _sendSequence);

        ubyte[12] nonce;
        nonce[0 .. 4] = _sendSalt[];
        writeU64(nonce[], 4, _sendSequence);
        const encrypted = aesGcmEncrypt(_sendKey, nonce[], header, payload);
        sendAll(socket, header);
        sendAll(socket, encrypted.bytes);
        sendAll(socket, encrypted.tag[]);
        ++_sendSequence;
    }

    SecureMessage receive()
    {
        auto socket = socketSnapshot();
        const header = receiveExact(socket, recordHeaderLength);
        enforce(header[0] == 'A' && header[1] == 'R' && header[2] == 1,
            "Remote computer sent an invalid record header.");
        const payloadLength = readU32(header, 6);
        enforce(payloadLength <= maximumRecordLength,
            "Remote computer sent an oversized record.");
        const sequence = readU64(header, 10);
        enforce(sequence == _receiveSequence,
            "Remote computer sent an out-of-order record.");
        const encrypted = receiveExact(socket, payloadLength);
        const tag = receiveExact(socket, 16);
        ubyte[12] nonce;
        nonce[0 .. 4] = _receiveSalt[];
        writeU64(nonce[], 4, sequence);
        SecureMessage result;
        result.channel = cast(ProtocolChannel) header[3];
        result.kind = header[4];
        result.payload = aesGcmDecrypt(_receiveKey, nonce[], header,
            encrypted, tag);
        ++_receiveSequence;
        return result;
    }

    void close()
    {
        Socket socket;
        synchronized (_stateMutex)
        {
            socket = _socket;
            _socket = null;
        }
        if (socket is null) return;
        try socket.shutdown(SocketShutdown.BOTH);
        catch (Exception) {}
        try socket.close();
        catch (Exception) {}
    }
}

SecureConnection establishClient(Socket socket,
    const ConnectionCapsule capsule)
{
    immutable ubyte[] clientMagic = cast(immutable(ubyte)[]) "ARHS1C\0\0";
    immutable ubyte[] serverMagic = cast(immutable(ubyte)[]) "ARHS1S\0\0";
    const clientNonce = randomBytes(32);
    const proof = hmacSha256(capsule.token[], joined(clientMagic,
        clientNonce, capsule.deviceId[]));
    sendAll(socket, joined(clientMagic, clientNonce, proof));

    const response = receiveExact(socket, 8 + 32 + 32);
    enforce(response[0 .. 8] == serverMagic,
        "The destination is not an Aurora Remote host.");
    const serverNonce = response[8 .. 40];
    const expected = hmacSha256(capsule.token[], joined(serverMagic,
        clientNonce, serverNonce, capsule.deviceId[]));
    enforce(constantTimeEqual(response[40 .. 72], expected),
        "The host could not prove possession of the invitation secret.");

    const session = deriveSession(capsule.token[], clientNonce, serverNonce);
    return new SecureConnection(socket, session.clientToServerKey,
        session.serverToClientKey, session.clientToServerSalt[],
        session.serverToClientSalt[]);
}

SecureConnection acceptClient(Socket socket, const ConnectionCapsule capsule)
{
    immutable ubyte[] clientMagic = cast(immutable(ubyte)[]) "ARHS1C\0\0";
    immutable ubyte[] serverMagic = cast(immutable(ubyte)[]) "ARHS1S\0\0";
    enforce(!capsule.expired(), "The invitation has expired.");
    const request = receiveExact(socket, 8 + 32 + 32);
    enforce(request[0 .. 8] == clientMagic,
        "Incoming connection is not an Aurora Remote client.");
    const clientNonce = request[8 .. 40];
    const expected = hmacSha256(capsule.token[], joined(clientMagic,
        clientNonce, capsule.deviceId[]));
    enforce(constantTimeEqual(request[40 .. 72], expected),
        "Incoming client does not possess the invitation secret.");

    const serverNonce = randomBytes(32);
    const proof = hmacSha256(capsule.token[], joined(serverMagic,
        clientNonce, serverNonce, capsule.deviceId[]));
    sendAll(socket, joined(serverMagic, serverNonce, proof));
    const session = deriveSession(capsule.token[], clientNonce, serverNonce);
    return new SecureConnection(socket, session.serverToClientKey,
        session.clientToServerKey, session.serverToClientSalt[],
        session.clientToServerSalt[]);
}
