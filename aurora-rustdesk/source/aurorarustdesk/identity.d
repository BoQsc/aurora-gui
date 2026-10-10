module aurorarustdesk.identity;

import aurorarustdesk.crypto : randomBytes, sha256;
import std.base64 : Base64;
import std.format : format;
import std.file : exists, mkdirRecurse, readText, write;
import std.path : buildPath;
import std.process : environment;
import std.string : strip;

version (Windows)
{
    import core.sys.windows.windows : BOOL, DWORD, HLOCAL, LocalFree, LPCWSTR;

    private struct DATA_BLOB
    {
        DWORD cbData;
        ubyte* pbData;
    }

    private enum DWORD CRYPTPROTECT_UI_FORBIDDEN = 0x1;

    extern (Windows) BOOL CryptProtectData(DATA_BLOB* input,
        LPCWSTR description, DATA_BLOB* optionalEntropy, void* reserved,
        void* prompt, DWORD flags, DATA_BLOB* output);
    extern (Windows) BOOL CryptUnprotectData(DATA_BLOB* input,
        wchar** description, DATA_BLOB* optionalEntropy, void* reserved,
        void* prompt, DWORD flags, DATA_BLOB* output);
}

// The numeric ID is the RustDesk-style public handle that other computers dial
// through the rendezvous server. It is derived from the private secret, which
// never leaves this machine, so it is stable across restarts but cannot be
// forged without the secret.
struct DeviceIdentity
{
    ubyte[32] secret;
    ubyte[16] id;
    string numericId;
}

string identityFolder()
{
    auto local = environment.get("LOCALAPPDATA", "");
    if (local.length == 0) local = environment.get("APPDATA", ".");
    return buildPath(local, "Aurora RustDesk");
}

string identityPath()
{
    return buildPath(identityFolder(), "identity.dat");
}

string passwordPath()
{
    return buildPath(identityFolder(), "password.dat");
}

package(aurorarustdesk) ubyte[] protectForCurrentUser(const(ubyte)[] plain)
{
    version (Windows)
    {
        DATA_BLOB input = DATA_BLOB(cast(DWORD) plain.length,
            cast(ubyte*) plain.ptr);
        DATA_BLOB output;
        if (!CryptProtectData(&input, null, null, null, null,
            CRYPTPROTECT_UI_FORBIDDEN, &output))
            throw new Exception("Windows could not protect the local secret.");
        scope (exit) LocalFree(cast(HLOCAL) output.pbData);
        return output.pbData[0 .. output.cbData].dup;
    }
    else throw new Exception("Aurora RustDesk secret storage requires Windows.");
}

package(aurorarustdesk) ubyte[] unprotectForCurrentUser(
    const(ubyte)[] protectedBytes)
{
    version (Windows)
    {
        DATA_BLOB input = DATA_BLOB(cast(DWORD) protectedBytes.length,
            cast(ubyte*) protectedBytes.ptr);
        DATA_BLOB output;
        if (!CryptUnprotectData(&input, null, null, null, null,
            CRYPTPROTECT_UI_FORBIDDEN, &output))
            throw new Exception("Windows could not unlock the local secret.");
        scope (exit) LocalFree(cast(HLOCAL) output.pbData);
        return output.pbData[0 .. output.cbData].dup;
    }
    else throw new Exception("Aurora RustDesk secret storage requires Windows.");
}

string numericIdFromSecret(const(ubyte)[] secret)
{
    const digest = sha256(secret);
    const value = (cast(uint) digest[0] << 24) | (cast(uint) digest[1] << 16) |
        (cast(uint) digest[2] << 8) | digest[3];
    return format("%09d", value % 1_000_000_000u);
}

ubyte[16] deviceFingerprint(const(ubyte)[] secret)
{
    const digest = sha256(secret);
    ubyte[16] result;
    result[] = digest[0 .. result.length];
    return result;
}

private DeviceIdentity fromSecret(const(ubyte)[] secret)
{
    if (secret.length != 32)
        throw new Exception("Stored device secret has the wrong length.");
    DeviceIdentity result;
    result.secret[] = secret[];
    result.id = deviceFingerprint(secret);
    result.numericId = numericIdFromSecret(secret);
    return result;
}

DeviceIdentity loadOrCreateIdentity()
{
    const path = identityPath();
    if (exists(path))
    {
        ubyte[] protectedBytes;
        try protectedBytes = Base64.decode(strip(readText(path)));
        catch (Exception)
            throw new Exception("Aurora RustDesk identity file is malformed.");
        return fromSecret(unprotectForCurrentUser(protectedBytes));
    }

    mkdirRecurse(identityFolder());
    const secret = randomBytes(32);
    write(path, Base64.encode(protectForCurrentUser(secret)) ~ "\n");
    return fromSecret(secret);
}

// A one-time or permanent access password. The controller proves possession of
// it during the handshake; the rendezvous server never sees it.
string generatePassword()
{
    enum alphabet = "abcdefghijkmnpqrstuvwxyz23456789";
    auto bytes = randomBytes(12);
    auto result = new char[10];
    foreach (index; 0 .. result.length)
        result[index] = alphabet[bytes[index] % alphabet.length];
    return result.idup;
}

ubyte[] passwordToken(string password)
{
    return sha256(cast(const(ubyte)[]) ("aurora-rustdesk/password/v1\n" ~
        password));
}

string loadStoredPassword()
{
    const path = passwordPath();
    if (!exists(path)) return "";
    ubyte[] plain;
    try plain = unprotectForCurrentUser(Base64.decode(strip(readText(path))));
    catch (Exception) return "";
    return cast(string) plain.idup;
}

void saveStoredPassword(string value)
{
    mkdirRecurse(identityFolder());
    const plain = cast(const(ubyte)[]) value;
    write(passwordPath(), Base64.encode(protectForCurrentUser(plain)) ~ "\n");
}

unittest
{
    const secret = randomBytes(32);
    const id = numericIdFromSecret(secret);
    assert(id.length == 9, "Numeric ID must be nine digits.");
    foreach (ch; id) assert(ch >= '0' && ch <= '9');
    assert(numericIdFromSecret(secret) == id, "Numeric ID must be stable.");
    const password = generatePassword();
    assert(password.length == 10);
    assert(passwordToken(password) == passwordToken(password));
}
