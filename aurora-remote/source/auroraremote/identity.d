module auroraremote.identity;

import auroraremote.crypto : randomBytes, sha256;
import std.base64 : Base64;
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

struct DeviceIdentity
{
    ubyte[32] secret;
    ubyte[16] id;
}

string identityFolder()
{
    auto local = environment.get("LOCALAPPDATA", "");
    if (local.length == 0) local = environment.get("APPDATA", ".");
    return buildPath(local, "Aurora Remote");
}

string identityPath()
{
    return buildPath(identityFolder(), "identity.dat");
}

string persistentAccessPath()
{
    return buildPath(identityFolder(), "unattended-access.dat");
}

package(auroraremote) ubyte[] protectForCurrentUser(const(ubyte)[] plain)
{
    version (Windows)
    {
        DATA_BLOB input = DATA_BLOB(cast(DWORD) plain.length,
            cast(ubyte*) plain.ptr);
        DATA_BLOB output;
        if (!CryptProtectData(&input, null, null, null, null,
            CRYPTPROTECT_UI_FORBIDDEN, &output))
            throw new Exception("Windows could not protect the device identity.");
        scope (exit) LocalFree(cast(HLOCAL) output.pbData);
        return output.pbData[0 .. output.cbData].dup;
    }
    else throw new Exception("Aurora Remote identity storage requires Windows.");
}

package(auroraremote) ubyte[] unprotectForCurrentUser(
    const(ubyte)[] protectedBytes)
{
    version (Windows)
    {
        DATA_BLOB input = DATA_BLOB(cast(DWORD) protectedBytes.length,
            cast(ubyte*) protectedBytes.ptr);
        DATA_BLOB output;
        if (!CryptUnprotectData(&input, null, null, null, null,
            CRYPTPROTECT_UI_FORBIDDEN, &output))
            throw new Exception("Windows could not unlock the device identity.");
        scope (exit) LocalFree(cast(HLOCAL) output.pbData);
        return output.pbData[0 .. output.cbData].dup;
    }
    else throw new Exception("Aurora Remote identity storage requires Windows.");
}

private DeviceIdentity fromSecret(const(ubyte)[] secret)
{
    if (secret.length != 32)
        throw new Exception("Stored device identity has the wrong length.");
    DeviceIdentity result;
    result.secret[] = secret[];
    const digest = sha256(secret);
    result.id[] = digest[0 .. result.id.length];
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
            throw new Exception("Aurora Remote identity file is malformed.");
        return fromSecret(unprotectForCurrentUser(protectedBytes));
    }

    mkdirRecurse(identityFolder());
    const secret = randomBytes(32);
    const protectedBytes = protectForCurrentUser(secret);
    write(path, Base64.encode(protectedBytes) ~ "\n");
    return fromSecret(secret);
}

ubyte[32] loadOrCreatePersistentAccessToken()
{
    const path = persistentAccessPath();
    ubyte[] token;
    if (exists(path))
    {
        try token = unprotectForCurrentUser(
            Base64.decode(strip(readText(path))));
        catch (Exception)
            throw new Exception("Persistent access key is malformed.");
        if (token.length != 32)
            throw new Exception("Persistent access key has the wrong length.");
    }
    else
    {
        mkdirRecurse(identityFolder());
        token = randomBytes(32);
        write(path, Base64.encode(protectForCurrentUser(token)) ~ "\n");
    }
    ubyte[32] result;
    result[] = token[];
    return result;
}

ubyte[32] rotatePersistentAccessToken()
{
    mkdirRecurse(identityFolder());
    const token = randomBytes(32);
    write(persistentAccessPath(),
        Base64.encode(protectForCurrentUser(token)) ~ "\n");
    ubyte[32] result;
    result[] = token[];
    return result;
}
