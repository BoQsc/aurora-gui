module auroraremote.capsule;

import auroraremote.crypto : constantTimeEqual, randomBytes, sha256;
import std.base64 : Base64URLNoPadding;
import std.conv : to;
import std.datetime.systime : Clock;
import std.exception : enforce;
import std.string : startsWith, strip;

enum connectionPrefix = "aurora://connect/";
enum capsuleVersion = 3;
enum maximumCapsuleLifetimeSeconds = 30 * 24 * 60 * 60;

enum AccessPermission : uint
{
    view = 1,
    input = 2,
    files = 4,
    clipboard = 8,
    all = view | input | files | clipboard
}

enum ConnectionTransport : ubyte
{
    direct = 1,
    relay = 2
}

struct ConnectionCapsule
{
    ubyte versionNumber = capsuleVersion;
    ConnectionTransport transport = ConnectionTransport.direct;
    bool persistent;
    uint permissions = AccessPermission.all;
    long expiresUnix;
    ushort port;
    ubyte[16] deviceId;
    ubyte[32] token;
    string host;

    bool expired(long nowUnix = Clock.currTime.toUnixTime()) const
    {
        return !persistent && expiresUnix <= nowUnix;
    }
}

private void appendU16(ref ubyte[] output, ushort value)
{
    output ~= cast(ubyte)(value >> 8);
    output ~= cast(ubyte) value;
}

private void appendU64(ref ubyte[] output, ulong value)
{
    foreach_reverse (shift; 0 .. 8)
        output ~= cast(ubyte)(value >> (shift * 8));
}

private ushort readU16(const(ubyte)[] input, ref size_t offset)
{
    enforce(offset + 2 <= input.length, "Connection code is truncated.");
    const result = cast(ushort)((cast(ushort) input[offset] << 8) |
        input[offset + 1]);
    offset += 2;
    return result;
}

private ulong readU64(const(ubyte)[] input, ref size_t offset)
{
    enforce(offset + 8 <= input.length, "Connection code is truncated.");
    ulong result;
    foreach (_; 0 .. 8) result = (result << 8) | input[offset++];
    return result;
}

string encodeConnectionCapsule(const ConnectionCapsule capsule)
{
    enforce(capsule.versionNumber == capsuleVersion,
        "Unsupported connection-capsule version.");
    enforce(capsule.port != 0, "Connection port must not be zero.");
    enforce(capsule.host.length > 0 && capsule.host.length <= 255,
        "Connection host must contain 1–255 UTF-8 bytes.");
    enforce(capsule.persistent || capsule.expiresUnix > 0,
        "Expiring connection code needs an expiry time.");

    enforce(capsule.transport == ConnectionTransport.direct ||
        capsule.transport == ConnectionTransport.relay,
        "Unsupported connection transport.");
    ubyte[] bytes = ['A', 'R', 'C', capsule.versionNumber,
        cast(ubyte) capsule.transport, cast(ubyte)(capsule.persistent ? 1 : 0),
        cast(ubyte)(capsule.permissions >> 24),
        cast(ubyte)(capsule.permissions >> 16),
        cast(ubyte)(capsule.permissions >> 8),
        cast(ubyte) capsule.permissions];
    appendU64(bytes, cast(ulong) capsule.expiresUnix);
    appendU16(bytes, capsule.port);
    bytes ~= capsule.deviceId[];
    bytes ~= capsule.token[];
    bytes ~= cast(ubyte) capsule.host.length;
    bytes ~= cast(const(ubyte)[]) capsule.host;
    const checksum = sha256(bytes);
    bytes ~= checksum[0 .. 6];
    return (connectionPrefix ~ Base64URLNoPadding.encode(bytes)).idup;
}

ConnectionCapsule decodeConnectionCapsule(string text,
    long nowUnix = Clock.currTime.toUnixTime())
{
    text = strip(text);
    enforce(text.startsWith(connectionPrefix),
        "Connection code must start with aurora://connect/.");
    ubyte[] bytes;
    try bytes = Base64URLNoPadding.decode(text[connectionPrefix.length .. $]);
    catch (Exception)
        throw new Exception("Connection code contains invalid base64url data.");
    enforce(bytes.length >= 10 + 8 + 2 + 16 + 32 + 1 + 1 + 6,
        "Connection code is too short.");
    enforce(bytes[0 .. 3] == cast(const(ubyte)[]) "ARC",
        "Connection code has the wrong signature.");
    enforce(bytes[3] == capsuleVersion,
        "This connection code uses an unsupported version.");

    const contentLength = bytes.length - 6;
    const expectedChecksum = sha256(bytes[0 .. contentLength]);
    enforce(constantTimeEqual(bytes[contentLength .. $],
        expectedChecksum[0 .. 6]), "Connection code checksum is invalid.");

    size_t offset = 10;
    ConnectionCapsule result;
    result.versionNumber = bytes[3];
    result.transport = cast(ConnectionTransport) bytes[4];
    enforce(result.transport == ConnectionTransport.direct ||
        result.transport == ConnectionTransport.relay,
        "Connection code contains an unsupported transport.");
    result.persistent = bytes[5] != 0;
    result.permissions = (cast(uint) bytes[6] << 24) |
        (cast(uint) bytes[7] << 16) | (cast(uint) bytes[8] << 8) | bytes[9];
    enforce((result.permissions & ~cast(uint) AccessPermission.all) == 0,
        "Connection code contains unsupported permissions.");
    result.expiresUnix = cast(long) readU64(bytes, offset);
    result.port = readU16(bytes, offset);
    result.deviceId[] = bytes[offset .. offset + result.deviceId.length];
    offset += result.deviceId.length;
    result.token[] = bytes[offset .. offset + result.token.length];
    offset += result.token.length;
    const hostLength = bytes[offset++];
    enforce(hostLength > 0 && offset + hostLength == contentLength,
        "Connection code has an invalid host length.");
    result.host = cast(string) bytes[offset .. offset + hostLength].idup;
    enforce(result.port != 0, "Connection code contains port zero.");
    if (!result.persistent)
    {
        enforce(result.expiresUnix > nowUnix, "Connection code has expired.");
        enforce(result.expiresUnix <= nowUnix + maximumCapsuleLifetimeSeconds,
            "Connection code expiry is unreasonably far in the future.");
    }
    return result;
}

ConnectionCapsule newConnectionCapsule(string host, ushort port,
    const(ubyte)[] deviceId, long lifetimeSeconds = 10 * 60,
    ConnectionTransport transport = ConnectionTransport.direct,
    uint permissions = AccessPermission.all)
{
    enforce(deviceId.length == 16, "Device identity must be 16 bytes.");
    enforce(lifetimeSeconds >= 30 &&
        lifetimeSeconds <= maximumCapsuleLifetimeSeconds,
        "Connection-code lifetime is outside the allowed range.");
    ConnectionCapsule result;
    result.expiresUnix = Clock.currTime.toUnixTime() + lifetimeSeconds;
    result.transport = transport;
    result.permissions = permissions;
    result.port = port;
    result.deviceId[] = deviceId[];
    result.token[] = randomBytes(result.token.length);
    result.host = host;
    return result;
}

ConnectionCapsule newPersistentConnectionCapsule(string host, ushort port,
    const(ubyte)[] deviceId, const(ubyte)[] token,
    ConnectionTransport transport = ConnectionTransport.direct,
    uint permissions = AccessPermission.all)
{
    enforce(deviceId.length == 16, "Device identity must be 16 bytes.");
    enforce(token.length == 32, "Persistent access token must be 32 bytes.");
    ConnectionCapsule result;
    result.persistent = true;
    result.expiresUnix = 0;
    result.port = port;
    result.transport = transport;
    result.permissions = permissions;
    result.deviceId[] = deviceId[];
    result.token[] = token[];
    result.host = host;
    return result;
}

string deviceIdText(const(ubyte)[] id)
{
    enforce(id.length >= 10, "Device identity is too short.");
    enum alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    string result;
    uint accumulator;
    uint bits;
    size_t emitted;
    foreach (value; id[0 .. 10])
    {
        accumulator = (accumulator << 8) | value;
        bits += 8;
        while (bits >= 5 && emitted < 16)
        {
            bits -= 5;
            if (emitted > 0 && emitted % 4 == 0) result ~= '-';
            result ~= alphabet[(accumulator >> bits) & 31];
            ++emitted;
        }
    }
    return result;
}

unittest
{
    ubyte[16] device;
    foreach (index, ref value; device) value = cast(ubyte)(index * 7);
    auto capsule = newConnectionCapsule("desk.example.test", 47831,
        device[], 600);
    const encoded = encodeConnectionCapsule(capsule);
    const restored = decodeConnectionCapsule(encoded);
    assert(restored.host == capsule.host);
    assert(restored.port == capsule.port);
    assert(restored.transport == ConnectionTransport.direct);
    assert(restored.permissions == AccessPermission.all);
    assert(restored.deviceId[] == capsule.deviceId[]);
    assert(restored.token[] == capsule.token[]);

    auto damaged = encoded.dup;
    damaged[$ - 2] = damaged[$ - 2] == 'A' ? 'B' : 'A';
    bool rejected;
    try decodeConnectionCapsule(damaged.idup);
    catch (Exception) rejected = true;
    assert(rejected);
    assert(deviceIdText(device[]).length == 19);
}
