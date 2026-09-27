module auroraremote.crypto;

import std.exception : enforce;
import std.format : format;

version (Windows)
{
    import core.sys.windows.bcrypt;
    import core.sys.windows.windef : ULONG;
}

private Exception cryptoError(string operation, long status)
{
    return new Exception(format("%s failed (NTSTATUS 0x%08X)", operation,
        cast(uint) status));
}

ubyte[] randomBytes(size_t count)
{
    auto result = new ubyte[count];
    version (Windows)
    {
        if (count > uint.max) throw new Exception("Random request is too large.");
        const status = BCryptGenRandom(null, result.ptr, cast(ULONG) count,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG);
        if (!BCRYPT_SUCCESS(status)) throw cryptoError("BCryptGenRandom", status);
        return result;
    }
    else throw new Exception("Aurora Remote cryptography requires Windows.");
}

private ubyte[] hashImpl(const(ubyte)[] data, const(ubyte)[] secret)
{
    version (Windows)
    {
        BCRYPT_ALG_HANDLE algorithm;
        BCRYPT_HASH_HANDLE hash;
        const flags = secret.length > 0 ? BCRYPT_ALG_HANDLE_HMAC_FLAG : 0;
        auto status = BCryptOpenAlgorithmProvider(&algorithm,
            BCRYPT_SHA256_ALGORITHM.ptr, null, flags);
        if (!BCRYPT_SUCCESS(status))
            throw cryptoError("BCryptOpenAlgorithmProvider(SHA-256)", status);
        scope (exit) BCryptCloseAlgorithmProvider(algorithm, 0);

        ULONG objectLength;
        ULONG bytesWritten;
        status = BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH.ptr,
            cast(ubyte*) &objectLength, objectLength.sizeof, &bytesWritten, 0);
        if (!BCRYPT_SUCCESS(status))
            throw cryptoError("BCryptGetProperty(ObjectLength)", status);

        auto object = new ubyte[objectLength];
        auto secretPointer = secret.length == 0 ? null :
            cast(ubyte*) secret.ptr;
        status = BCryptCreateHash(algorithm, &hash, object.ptr,
            cast(ULONG) object.length, secretPointer,
            cast(ULONG) secret.length, 0);
        if (!BCRYPT_SUCCESS(status)) throw cryptoError("BCryptCreateHash", status);
        scope (exit) BCryptDestroyHash(hash);

        if (data.length > 0)
        {
            status = BCryptHashData(hash, cast(ubyte*) data.ptr,
                cast(ULONG) data.length, 0);
            if (!BCRYPT_SUCCESS(status))
                throw cryptoError("BCryptHashData", status);
        }

        auto digest = new ubyte[32];
        status = BCryptFinishHash(hash, digest.ptr,
            cast(ULONG) digest.length, 0);
        if (!BCRYPT_SUCCESS(status))
            throw cryptoError("BCryptFinishHash", status);
        return digest;
    }
    else throw new Exception("Aurora Remote cryptography requires Windows.");
}

ubyte[] sha256(const(ubyte)[] data)
{
    return hashImpl(data, null);
}

ubyte[] hmacSha256(const(ubyte)[] secret, const(ubyte)[] data)
{
    enforce(secret.length > 0, "HMAC secret must not be empty.");
    return hashImpl(data, secret);
}

bool constantTimeEqual(const(ubyte)[] left, const(ubyte)[] right) @safe pure nothrow
{
    if (left.length != right.length) return false;
    ubyte difference;
    foreach (index; 0 .. left.length)
        difference |= left[index] ^ right[index];
    return difference == 0;
}

struct AuthenticatedCiphertext
{
    ubyte[] bytes;
    ubyte[16] tag;
}

AuthenticatedCiphertext aesGcmEncrypt(const(ubyte)[] key,
    const(ubyte)[] nonce, const(ubyte)[] associatedData,
    const(ubyte)[] plaintext)
{
    return aesGcmTransform(true, key, nonce, associatedData, plaintext, null);
}

ubyte[] aesGcmDecrypt(const(ubyte)[] key, const(ubyte)[] nonce,
    const(ubyte)[] associatedData, const(ubyte)[] ciphertext,
    const(ubyte)[] tag)
{
    enforce(tag.length == 16, "AES-GCM authentication tag must be 16 bytes.");
    return aesGcmTransform(false, key, nonce, associatedData, ciphertext,
        tag).bytes;
}

private AuthenticatedCiphertext aesGcmTransform(bool encrypt,
    const(ubyte)[] key, const(ubyte)[] nonce,
    const(ubyte)[] associatedData, const(ubyte)[] input,
    const(ubyte)[] suppliedTag)
{
    enforce(key.length == 32, "Aurora Remote requires a 256-bit AES key.");
    enforce(nonce.length == 12, "Aurora Remote requires a 96-bit GCM nonce.");
    version (Windows)
    {
        BCRYPT_ALG_HANDLE algorithm;
        BCRYPT_KEY_HANDLE keyHandle;
        auto status = BCryptOpenAlgorithmProvider(&algorithm,
            BCRYPT_AES_ALGORITHM.ptr, null, 0);
        if (!BCRYPT_SUCCESS(status))
            throw cryptoError("BCryptOpenAlgorithmProvider(AES)", status);
        scope (exit) BCryptCloseAlgorithmProvider(algorithm, 0);

        status = BCryptSetProperty(algorithm, BCRYPT_CHAINING_MODE.ptr,
            cast(ubyte*) BCRYPT_CHAIN_MODE_GCM.ptr,
            cast(ULONG)((BCRYPT_CHAIN_MODE_GCM.length + 1) * wchar.sizeof), 0);
        if (!BCRYPT_SUCCESS(status))
            throw cryptoError("BCryptSetProperty(GCM)", status);

        ULONG objectLength;
        ULONG bytesWritten;
        status = BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH.ptr,
            cast(ubyte*) &objectLength, objectLength.sizeof, &bytesWritten, 0);
        if (!BCRYPT_SUCCESS(status))
            throw cryptoError("BCryptGetProperty(AES ObjectLength)", status);
        auto keyObject = new ubyte[objectLength];
        status = BCryptGenerateSymmetricKey(algorithm, &keyHandle,
            keyObject.ptr, cast(ULONG) keyObject.length,
            cast(ubyte*) key.ptr, cast(ULONG) key.length, 0);
        if (!BCRYPT_SUCCESS(status))
            throw cryptoError("BCryptGenerateSymmetricKey", status);
        scope (exit) BCryptDestroyKey(keyHandle);

        ubyte[16] tag;
        if (!encrypt) tag[] = suppliedTag[];
        BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
        BCRYPT_INIT_AUTH_MODE_INFO(info);
        info.pbNonce = cast(ubyte*) nonce.ptr;
        info.cbNonce = cast(ULONG) nonce.length;
        info.pbAuthData = associatedData.length == 0 ? null :
            cast(ubyte*) associatedData.ptr;
        info.cbAuthData = cast(ULONG) associatedData.length;
        info.pbTag = tag.ptr;
        info.cbTag = cast(ULONG) tag.length;

        auto output = new ubyte[input.length];
        ULONG outputLength;
        if (encrypt)
            status = BCryptEncrypt(keyHandle, input.length == 0 ? null :
                cast(ubyte*) input.ptr, cast(ULONG) input.length, &info,
                null, 0, output.length == 0 ? null : output.ptr,
                cast(ULONG) output.length, &outputLength, 0);
        else
            status = BCryptDecrypt(keyHandle, input.length == 0 ? null :
                cast(ubyte*) input.ptr, cast(ULONG) input.length, &info,
                null, 0, output.length == 0 ? null : output.ptr,
                cast(ULONG) output.length, &outputLength, 0);
        if (!BCRYPT_SUCCESS(status))
            throw cryptoError(encrypt ? "BCryptEncrypt(GCM)" :
                "BCryptDecrypt(GCM)", status);
        output.length = outputLength;
        return AuthenticatedCiphertext(output, tag);
    }
    else throw new Exception("Aurora Remote cryptography requires Windows.");
}

unittest
{
    const key = randomBytes(32);
    const nonce = randomBytes(12);
    const plain = cast(const(ubyte)[]) "Aurora encrypted record";
    const aad = cast(const(ubyte)[]) "record-header";
    auto encrypted = aesGcmEncrypt(key, nonce, aad, plain);
    assert(!constantTimeEqual(encrypted.bytes, plain));
    assert(constantTimeEqual(aesGcmDecrypt(key, nonce, aad,
        encrypted.bytes, encrypted.tag[]), plain));

    ubyte[16] damaged = encrypted.tag;
    damaged[0] ^= 1;
    bool rejected;
    try aesGcmDecrypt(key, nonce, aad, encrypted.bytes, damaged[]);
    catch (Exception) rejected = true;
    assert(rejected);
}
