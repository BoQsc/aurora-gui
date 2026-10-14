module auroraweb.tls;

/**
 * A TLS 1.3 client (RFC 8446) implemented from scratch on top of this project's
 * own crypto (`auroraweb.crypto`) and byte transport (`auroraweb.transport`).
 *
 * There is no OpenSSL/SChannel/System.Net here: the ClientHello, the noise-free
 * key schedule (HKDF-Expand-Label), the AEAD record layer (AES-128-GCM) and the
 * Finished computation are all written out. `TlsTransport` implements
 * `ByteTransport`, so the HTTP client treats an HTTPS connection exactly like a
 * plaintext one.
 *
 * Certificate *signature* verification is not performed yet (the browser already
 * tolerated untrusted certificates through the previous stack); the handshake
 * still authenticates the server's key exchange and Finished, so traffic is
 * encrypted and integrity-protected. Full X.509 chain validation is the next
 * step.
 */

import core.time : Duration, dur;
import std.conv : to;
import std.format : format;
import std.string : toLower, indexOf;

import auroraweb.transport : ByteTransport, TransportException;
import auroraweb.crypto : sha256, hmacSha256, hkdfExtract, hkdfExpandLabel,
    x25519, x25519Base, aes128GcmEncrypt, aes128GcmDecrypt,
    ecdsaP256VerifySha256, parseEcdsaSigDer, rsaPssVerifySha256;

/// The server's public key, taken from its leaf certificate.
private struct PeerKey
{
    bool isEc;                 /// true = ECDSA P-256, false = RSA
    ubyte[65] ecPoint;
    ubyte[] rsaModulus;        /// big-endian modulus
    ulong rsaExponent;
}

private enum ubyte CT_CHANGE_CIPHER_SPEC = 20;
private enum ubyte CT_ALERT = 21;
private enum ubyte CT_HANDSHAKE = 22;
private enum ubyte CT_APPLICATION_DATA = 23;

private enum ubyte HS_CLIENT_HELLO = 1;
private enum ubyte HS_SERVER_HELLO = 2;
private enum ubyte HS_NEW_SESSION_TICKET = 4;
private enum ubyte HS_ENCRYPTED_EXTENSIONS = 8;
private enum ubyte HS_CERTIFICATE = 11;
private enum ubyte HS_CERTIFICATE_VERIFY = 15;
private enum ubyte HS_FINISHED = 20;

private enum ushort GROUP_X25519 = 0x001d;
private enum ushort CS_AES_128_GCM_SHA256 = 0x1301;

version (Windows)
{
    // RtlGenRandom is exported as SystemFunction036 from advapi32.
    pragma(lib, "advapi32");
    private extern (Windows) ubyte SystemFunction036(void* buf, uint len);
}

/// Random bytes from the operating system.
private void fillRandom(ubyte[] buf)
{
    version (Windows)
    {
        if (SystemFunction036(buf.ptr, cast(uint) buf.length) == 0)
            throw new TransportException("RtlGenRandom failed");
    }
    else version (Posix)
    {
        import core.stdc.stdio : fopen, fread, fclose, FILE;
        auto f = fopen("/dev/urandom", "rb");
        if (f is null) throw new TransportException("cannot open /dev/urandom");
        scope (exit) fclose(f);
        if (fread(buf.ptr, 1, buf.length, f) != buf.length)
            throw new TransportException("short read from /dev/urandom");
    }
    else
        static assert(0, "no OS random source");
}

private ubyte[32] random32()
{
    ubyte[32] b;
    fillRandom(b[]);
    return b;
}

/// A record-layer key + IV + monotonically increasing sequence number.
private struct TrafficKey
{
    ubyte[16] key;
    ubyte[12] iv;
    ulong seq;
}

private TrafficKey trafficKeyFrom(const(ubyte)[] secret)
{
    TrafficKey tk;
    auto k = hkdfExpandLabel(secret, "key", null, 16);
    foreach (i; 0 .. 16) tk.key[i] = k[i];
    auto iv = hkdfExpandLabel(secret, "iv", null, 12);
    foreach (i; 0 .. 12) tk.iv[i] = iv[i];
    tk.seq = 0;
    return tk;
}

private ubyte[12] nonceFor(const(ubyte)[12] iv, ulong seq)
{
    ubyte[12] n = iv;
    foreach (i; 0 .. 8)
        n[4 + i] ^= cast(ubyte) (seq >> (56 - 8 * i));
    return n;
}

private ubyte[] zeros(size_t n) { return new ubyte[](n); }

private void putU8(ref ubyte[] b, ubyte v) { b ~= v; }
private void putU16(ref ubyte[] b, ushort v) { b ~= cast(ubyte) (v >> 8); b ~= cast(ubyte) v; }
private void putU24(ref ubyte[] b, uint v)
{
    b ~= cast(ubyte) (v >> 16); b ~= cast(ubyte) (v >> 8); b ~= cast(ubyte) v;
}
private ushort getU16(const(ubyte)[] b, size_t off)
{
    return cast(ushort) ((cast(ushort) b[off] << 8) | b[off + 1]);
}

/// A TLS 1.3 client connection over a base transport.
final class TlsTransport : ByteTransport
{
    private ByteTransport _base;
    private bool _closed;

    // Buffered decrypted application data awaiting the reader.
    private ubyte[] _appBuf;
    private size_t _appPos;

    // Traffic keys.
    private TrafficKey _clientKey;
    private TrafficKey _serverKey;

    private this(ByteTransport base) { _base = base; }

    /**
     * Perform a TLS 1.3 handshake with `host` (used for SNI) over `base`.
     * Throws `TransportException` on any handshake failure.
     */
    static TlsTransport connect(string host, ByteTransport base,
        Duration timeout = dur!"seconds"(30))
    {
        auto t = new TlsTransport(base);
        try
            t.handshake(host);
        catch (Exception e)
        {
            t._closed = true; // do not attempt an alert write on a dead session
            base.close();
            throw e;
        }
        return t;
    }

    // --- public ByteTransport API ---

    override ptrdiff_t readSome(ubyte[] buf)
    {
        if (_closed) return 0;
        while (_appPos >= _appBuf.length)
        {
            ubyte recType;
            ubyte[] payload;
            if (!readRecord(recType, payload))
            {
                _closed = true;
                _base.close();
                return 0; // clean EOF
            }
            if (recType == CT_CHANGE_CIPHER_SPEC) continue;
            if (recType == CT_ALERT) { _closed = true; _base.close(); return 0; }
            if (recType != CT_APPLICATION_DATA) continue;

            ubyte innerType;
            ubyte[] pt;
            if (!openRecord(_serverKey, recType, payload, innerType, pt))
                throw new TransportException("TLS: record authentication failed");
            if (innerType == CT_APPLICATION_DATA)
            {
                _appBuf = pt;
                _appPos = 0;
            }
            else if (innerType == CT_HANDSHAKE)
            {
                // NewSessionTicket / KeyUpdate: ignore for now.
            }
            else if (innerType == CT_ALERT)
            {
                _closed = true;
                _base.close();
                return 0;
            }
        }
        auto avail = _appBuf.length - _appPos;
        auto n = buf.length < avail ? buf.length : avail;
        buf[0 .. n] = _appBuf[_appPos .. _appPos + n];
        _appPos += n;
        return n;
    }

    override void writeAll(const(ubyte)[] data)
    {
        size_t off = 0;
        while (off < data.length)
        {
            auto n = data.length - off < 16000 ? data.length - off : 16000;
            auto rec = sealRecord(_clientKey, CT_APPLICATION_DATA, data[off .. off + n]);
            _base.writeAll(rec);
            off += n;
        }
    }

    override void close()
    {
        if (_closed) return;
        _closed = true;
        try
        {
            // close_notify alert (level warn(1), description close_notify(0)).
            auto rec = sealRecord(_clientKey, CT_ALERT, cast(ubyte[]) [1, 0]);
            _base.writeAll(rec);
        }
        catch (Exception) {}
        _base.close();
    }

    ~this() { close(); }

    // --- record layer ---

    private ubyte[] sealRecord(ref TrafficKey tk, ubyte contentType, const(ubyte)[] plaintext)
    {
        ubyte[] inner = new ubyte[](plaintext.length + 1);
        inner[0 .. plaintext.length] = plaintext[];
        inner[plaintext.length] = contentType;
        auto nonce = nonceFor(tk.iv, tk.seq);
        int recLen = cast(int) (inner.length + 16);
        ubyte[5] hdr = [CT_APPLICATION_DATA, 0x03, 0x03,
            cast(ubyte) (recLen >> 8), cast(ubyte) (recLen & 0xff)];
        ubyte[] ct;
        auto tag = aes128GcmEncrypt(tk.key[], nonce[], hdr[], inner, ct);
        ubyte[] rec;
        rec ~= hdr[];
        rec ~= ct;
        rec ~= tag[];
        tk.seq++;
        return rec;
    }

    private bool openRecord(ref TrafficKey tk, ubyte recType, const(ubyte)[] payload,
        ref ubyte innerType, ref ubyte[] plaintext)
    {
        if (payload.length < 16) return false;
        auto ct = payload[0 .. $ - 16];
        ubyte[16] tag;
        tag[] = payload[$ - 16 .. $];
        auto nonce = nonceFor(tk.iv, tk.seq);
        int recLen = cast(int) payload.length;
        ubyte[5] hdr = [CT_APPLICATION_DATA, 0x03, 0x03,
            cast(ubyte) (recLen >> 8), cast(ubyte) (recLen & 0xff)];
        ubyte[] pt;
        if (!aes128GcmDecrypt(tk.key[], nonce[], hdr[], ct, tag, pt))
            return false;
        tk.seq++;
        if (pt.length < 1) return false;
        innerType = pt[$ - 1];
        plaintext = pt[0 .. $ - 1].dup;
        return true;
    }

    /// Read one record header + payload from the base transport.
    private bool readRecord(ref ubyte type, ref ubyte[] payload)
    {
        ubyte[5] hdr;
        if (!readExact(hdr[])) return false;
        type = hdr[0];
        int len = (cast(int) hdr[3] << 8) | hdr[4];
        if (len < 0 || len > 18432) throw new TransportException("TLS: bad record length");
        payload = new ubyte[](len);
        if (len > 0 && !readExact(payload)) return false;
        return true;
    }

    /// Fill `dst` completely; returns false if EOF before any byte.
    private bool readExact(ubyte[] dst)
    {
        size_t got = 0;
        while (got < dst.length)
        {
            auto n = _base.readSome(dst[got .. $]);
            if (n <= 0)
            {
                if (got == 0) return false;
                throw new TransportException("TLS: connection closed mid-record");
            }
            got += cast(size_t) n;
        }
        return true;
    }

    // --- handshake ---

    private void handshake(string host)
    {
        // 1. Ephemeral X25519 key pair.
        auto priv = random32();
        auto pub = x25519Base(priv);

        // 2. ClientHello.
        auto ch = buildClientHello(host, pub);
        ubyte[] transcript;
        transcript ~= ch;

        // Write it in a plaintext handshake record (legacy record version 0x0301).
        writePlainRecord(CT_HANDSHAKE, ch);

        // 3. Read ServerHello (skipping ChangeCipherSpec records).
        ubyte[] hsBuf;
        ubyte[] serverHello;
        while (serverHello.length == 0)
        {
            ubyte recType;
            ubyte[] payload;
            if (!readRecord(recType, payload))
                throw new TransportException("TLS: server closed during handshake");
            if (recType == CT_CHANGE_CIPHER_SPEC) continue;
            if (recType == CT_ALERT)
                throw new TransportException("TLS: server alert during handshake: " ~ alertText(payload));
            if (recType != CT_HANDSHAKE)
                throw new TransportException("TLS: unexpected record type " ~ to!string(recType));
            hsBuf ~= payload;
            foreach (msg; extractMessages(hsBuf))
            {
                if (msg[0] == HS_SERVER_HELLO)
                {
                    serverHello = msg.dup;
                    break;
                }
            }
        }
        transcript ~= serverHello;

        // 4. Parse the ServerHello (keyshare + cipher).
        auto sh = parseServerHello(serverHello);
        if (sh.cipherSuite != CS_AES_128_GCM_SHA256)
            throw new TransportException("TLS: server chose unsupported cipher 0x" ~ format("%04x", sh.cipherSuite));
        if (sh.group != GROUP_X25519)
            throw new TransportException("TLS: server chose unsupported group 0x" ~ format("%04x", sh.group));

        // 5. Shared secret.
        auto sharedSecret = x25519(priv, sh.serverKey);

        // 6. Key schedule up to handshake secrets.
        auto earlySecret = hkdfExtract(zeros(32), zeros(32));
        auto derived1 = hkdfExpandLabel(earlySecret, "derived", sha256(""), 32);
        auto handshakeSecret = hkdfExtract(derived1, sharedSecret);
        auto thSH = sha256(transcript);
        auto cHsSecret = hkdfExpandLabel(handshakeSecret, "c hs traffic", thSH, 32);
        auto sHsSecret = hkdfExpandLabel(handshakeSecret, "s hs traffic", thSH, 32);
        auto serverHsKey = trafficKeyFrom(sHsSecret);
        auto clientHsKey = trafficKeyFrom(cHsSecret);

        auto sFinishedKey = hkdfExpandLabel(sHsSecret, "finished", null, 32);
        auto cFinishedKey = hkdfExpandLabel(cHsSecret, "finished", null, 32);

        // 7. Consume the server's encrypted handshake flight.
        auto serverVerified = false;
        PeerKey peerKey;
        while (!serverVerified)
        {
            ubyte recType;
            ubyte[] payload;
            if (!readRecord(recType, payload))
                throw new TransportException("TLS: server closed mid-handshake");
            if (recType == CT_CHANGE_CIPHER_SPEC) continue;
            if (recType == CT_ALERT)
                throw new TransportException("TLS: alert during handshake: " ~ alertText(payload));

            ubyte innerType;
            ubyte[] pt;
            if (!openRecord(serverHsKey, recType, payload, innerType, pt))
                throw new TransportException("TLS: cannot decrypt handshake record");
            if (innerType == CT_ALERT)
                throw new TransportException("TLS: alert during handshake: " ~ alertText(pt));
            if (innerType != CT_HANDSHAKE)
                continue;

            hsBuf ~= pt;
            foreach (msg; extractMessages(hsBuf))
            {
                auto mt = msg[0];
                if (mt == HS_FINISHED)
                {
                    // Finished covers the transcript up to but excluding itself.
                    auto expected = hmacSha256(sFinishedKey, sha256(transcript));
                    auto body = msg[4 .. $];
                    if (body.length != 32 || body != expected[])
                        throw new TransportException("TLS: server Finished verification failed");
                    transcript ~= msg;
                    serverVerified = true;
                    break;
                }
                else
                {
                    if (mt == HS_CERTIFICATE)
                    {
                        parseCertificateKey(msg, peerKey, host);
                        transcript ~= msg;
                    }
                    else if (mt == HS_CERTIFICATE_VERIFY)
                    {
                        verifyCertificateVerify(msg, peerKey, transcript);
                        transcript ~= msg;
                    }
                    else
                    {
                        // EncryptedExtensions and anything else.
                        transcript ~= msg;
                    }
                }
            }
        }

        // 8. Application secrets.
        auto derived2 = hkdfExpandLabel(handshakeSecret, "derived", sha256(""), 32);
        auto masterSecret = hkdfExtract(derived2, zeros(32));
        auto thFull = sha256(transcript);
        auto cApSecret = hkdfExpandLabel(masterSecret, "c ap traffic", thFull, 32);
        auto sApSecret = hkdfExpandLabel(masterSecret, "s ap traffic", thFull, 32);

        // 9. Client Finished.
        auto clientVerify = hmacSha256(cFinishedKey, sha256(transcript));
        ubyte[] finMsg;
        finMsg ~= HS_FINISHED;
        putU24(finMsg, 32);
        finMsg ~= clientVerify[];
        writePlainRecord2(clientHsKey, CT_HANDSHAKE, finMsg);

        // 10. Switch to application keys.
        _clientKey = trafficKeyFrom(cApSecret);
        _serverKey = trafficKeyFrom(sApSecret);
    }

    /// Write a plaintext (unencrypted) record during the handshake.
    private void writePlainRecord(ubyte type, const(ubyte)[] payload)
    {
        ubyte[] rec;
        rec ~= type;
        rec ~= 0x03; rec ~= 0x01;
        putU16(rec, cast(ushort) payload.length);
        rec ~= payload;
        _base.writeAll(rec);
    }

    /// Write an encrypted record with an explicit key (handshake phase).
    private void writePlainRecord2(ref TrafficKey tk, ubyte type, const(ubyte)[] payload)
    {
        auto rec = sealRecord(tk, type, payload);
        _base.writeAll(rec);
    }

    private ubyte[] buildClientHello(string host, const(ubyte)[32] clientPub)
    {
        ubyte[] body;
        putU16(body, 0x0303);                     // legacy_version
        auto rand = random32();
        body ~= rand[];                            // random(32)
        auto sessionId = random32();
        putU8(body, 32);                           // legacy_session_id length
        body ~= sessionId[];                       // legacy_session_id

        // cipher_suites
        putU16(body, 2);
        putU16(body, CS_AES_128_GCM_SHA256);
        // legacy_compression_methods
        putU8(body, 1);
        putU8(body, 0);

        ubyte[] exts;

        // server_name (SNI)
        {
            ubyte[] name = cast(ubyte[]) host.dup;
            ubyte[] sn = new ubyte[](name.length + 3);
            sn[0] = 0; // host_name
            sn[1] = cast(ubyte) (name.length >> 8);
            sn[2] = cast(ubyte) name.length;
            sn[3 .. $] = name[];
            ubyte[] e;
            putU16(e, 0);
            putU16(e, cast(ushort) (sn.length + 2));
            putU16(e, cast(ushort) sn.length);
            e ~= sn;
            exts ~= e;
        }
        // supported_groups: x25519
        {
            ubyte[] e;
            putU16(e, 10);
            putU16(e, 4);
            putU16(e, 2);
            putU16(e, GROUP_X25519);
            exts ~= e;
        }
        // signature_algorithms
        {
            ushort[] algos = [0x0403, 0x0503, 0x0603, 0x0804, 0x0805, 0x0806,
                0x0807, 0x0401, 0x0501, 0x0601, 0x0201, 0x0203];
            ubyte[] list;
            foreach (a; algos) putU16(list, a);
            ubyte[] e;
            putU16(e, 13);
            putU16(e, cast(ushort) (list.length + 2));
            putU16(e, cast(ushort) list.length);
            e ~= list;
            exts ~= e;
        }
        // key_share: x25519
        {
            ubyte[] e;
            putU16(e, 51);
            putU16(e, 2 + 2 + 2 + 32);           // extension length
            putU16(e, 2 + 2 + 32);               // client_shares length
            putU16(e, GROUP_X25519);
            putU16(e, 32);
            e ~= clientPub[];
            exts ~= e;
        }
        // supported_versions: TLS 1.3
        {
            ubyte[] e;
            putU16(e, 43);
            putU16(e, 3);
            putU8(e, 2);
            putU16(e, 0x0304);
            exts ~= e;
        }
        // ALPN: http/1.1
        {
            ubyte[] protos;
            putU8(protos, 8);
            protos ~= cast(ubyte[]) "http/1.1";
            ubyte[] e;
            putU16(e, 16);
            putU16(e, cast(ushort) (protos.length + 2));
            putU16(e, cast(ushort) protos.length);
            e ~= protos;
            exts ~= e;
        }

        putU16(body, cast(ushort) exts.length);
        body ~= exts;

        ubyte[] msg;
        msg ~= HS_CLIENT_HELLO;
        putU24(msg, cast(uint) body.length);
        msg ~= body;
        return msg;
    }

    private struct ServerHelloInfo
    {
        ushort cipherSuite;
        ushort group;
        ubyte[32] serverKey;
    }

    private ServerHelloInfo parseServerHello(const(ubyte)[] msg)
    {
        ServerHelloInfo info;
        // msg[0]=type, msg[1..4]=len, body starts at 4.
        size_t p = 4;
        p += 2;                 // legacy_version
        p += 32;                // random

        // HelloRetryRequest detection (special random).
        static immutable ubyte[32] HRR = [
            0xCF,0x21,0xAD,0x74,0xE5,0x9A,0x61,0x11,0xBE,0x1D,0x8C,0x02,
            0x1E,0x65,0xB8,0x91,0xC2,0xA2,0x11,0x16,0x7A,0xBB,0x8C,0x5E,
            0x07,0x9E,0x09,0xE2,0xC8,0xA8,0x33,0x9C];
        if (msg[6 .. 38] == HRR[])
            throw new TransportException("TLS: HelloRetryRequest is not supported");

        auto sidLen = msg[p]; p += 1 + sidLen;
        info.cipherSuite = getU16(msg, p); p += 2;
        p += 1;                 // legacy_compression_method
        auto extLen = getU16(msg, p); p += 2;
        auto extEnd = p + extLen;
        while (p + 4 <= extEnd)
        {
            auto et = getU16(msg, p); p += 2;
            auto el = getU16(msg, p); p += 2;
            auto eend = p + el;
            if (et == 51) // key_share
            {
                info.group = getU16(msg, p);
                auto kl = getU16(msg, p + 2);
                if (info.group == GROUP_X25519 && kl == 32)
                    info.serverKey[] = msg[p + 4 .. p + 4 + 32];
            }
            p = eend;
        }
        return info;
    }

    /// Split a buffer into complete handshake messages (type + 3-byte length),
    /// consuming them from the front. Handles messages spanning records.
    private ubyte[][] extractMessages(ref ubyte[] buf)
    {
        ubyte[][] msgs;
        size_t pos = 0;
        while (buf.length - pos >= 4)
        {
            uint len = (cast(uint) buf[pos + 1] << 16) | (cast(uint) buf[pos + 2] << 8) | buf[pos + 3];
            if (buf.length - pos < 4 + len) break;
            msgs ~= buf[pos .. pos + 4 + len].dup;
            pos += 4 + len;
        }
        if (pos > 0) buf = buf[pos .. $].dup;
        return msgs;
    }

    private static uint u24(const(ubyte)[] b, size_t off)
    {
        return (cast(uint) b[off] << 16) | (cast(uint) b[off + 1] << 8) | b[off + 2];
    }

    /// Extract the server's public key (ECDSA P-256 or RSA) from the leaf cert.
    private void parseCertificateKey(const(ubyte)[] msg, ref PeerKey key, string host)
    {
        auto body = msg[4 .. $];
        // Certificate ::= { certificate_request_context<0..255>, CertificateEntry list }
        if (body.length < 1) throw new TransportException("TLS: malformed Certificate");
        size_t p = 1 + body[0];           // skip certificate_request_context
        if (p + 3 > body.length) throw new TransportException("TLS: malformed Certificate");
        p += 3;                            // skip certificate_list length
        if (p + 3 > body.length) throw new TransportException("TLS: malformed Certificate");
        uint certLen = u24(body, p);
        p += 3;
        if (p + certLen > body.length)
            throw new TransportException("TLS: malformed Certificate entry");
        auto certDer = body[p .. p + certLen];

        // The certificate must actually be issued for the host we asked for.
        if (!hostnameMatches(host, certificateDnsNames(certDer)))
            throw new TransportException("TLS: certificate does not match host '" ~ host ~ "'");

        if (extractP256Point(certDer, key.ecPoint))
        {
            key.isEc = true;
            return;
        }
        if (extractRsaKey(certDer, key.rsaModulus, key.rsaExponent))
        {
            key.isEc = false;
            return;
        }
        throw new TransportException("TLS: unsupported server certificate key type");
    }

    private bool extractP256Point(const(ubyte)[] der, ref ubyte[65] point)
    {
        foreach (i; 0 .. der.length)
        {
            if (i + 68 <= der.length && der[i] == 0x03 && der[i + 1] == 0x42 &&
                der[i + 2] == 0x00 && der[i + 3] == 0x04)
            {
                point[0 .. 65] = der[i + 3 .. i + 68];
                return true;
            }
        }
        return false;
    }

    /// Extract an RSA public key (modulus, exponent) from the leaf certificate
    /// by locating the id-rsaEncryption OID and the following RSAPublicKey.
    private bool extractRsaKey(const(ubyte)[] der, ref ubyte[] modulus, ref ulong exponent)
    {
        static immutable ubyte[] OID = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86,
            0xF7, 0x0D, 0x01, 0x01, 0x01];
        size_t oi = size_t.max;
        foreach (i; 0 .. der.length)
            if (i + OID.length <= der.length && der[i .. i + OID.length] == OID[])
            {
                oi = i;
                break;
            }
        if (oi == size_t.max) return false;

        // DER length reader.
        size_t p = oi + OID.length;
        // find the BIT STRING (0x03)
        while (p < der.length && der[p] != 0x03) p++;
        if (p + 1 >= der.length) return false;
        p++;
        size_t blen = der[p++];
        if (blen & 0x80)
        {
            int nb = cast(int) (blen & 0x7f);
            if (p + nb > der.length) return false;
            blen = 0;
            foreach (k; 0 .. nb) blen = (blen << 8) | der[p++];
        }
        p++;                              // unused-bits byte (0x00)
        if (p >= der.length || der[p] != 0x30) return false;
        p++;
        size_t slen = der[p++];
        if (slen & 0x80)
        {
            int nb = cast(int) (slen & 0x7f);
            if (p + nb > der.length) return false;
            slen = 0;
            foreach (k; 0 .. nb) slen = (slen << 8) | der[p++];
        }

        // INTEGER modulus
        if (p + 1 >= der.length || der[p] != 0x02) return false;
        p++;
        size_t nlen = der[p++];
        if (nlen & 0x80)
        {
            int nb = cast(int) (nlen & 0x7f);
            if (p + nb > der.length) return false;
            nlen = 0;
            foreach (k; 0 .. nb) nlen = (nlen << 8) | der[p++];
        }
        if (p + nlen > der.length) return false;
        auto nb2 = der[p .. p + nlen];
        p += nlen;
        if (nb2.length && nb2[0] == 0) nb2 = nb2[1 .. $];
        modulus = nb2.dup;

        // INTEGER exponent
        if (p + 1 >= der.length || der[p] != 0x02) return false;
        p++;
        size_t elen = der[p++];
        if (elen & 0x80)
        {
            int nb = cast(int) (elen & 0x7f);
            if (p + nb > der.length) return false;
            elen = 0;
            foreach (k; 0 .. nb) elen = (elen << 8) | der[p++];
        }
        if (p + elen > der.length || elen > 8) return false;
        ulong ev = 0;
        foreach (k; 0 .. elen) ev = (ev << 8) | der[p + k];
        exponent = ev;
        return modulus.length > 0 && exponent != 0;
    }

    /// Verify the CertificateVerify signature over the handshake transcript.
    private void verifyCertificateVerify(const(ubyte)[] msg, const PeerKey key,
        const(ubyte)[] transcript)
    {
        auto body = msg[4 .. $];
        if (body.length < 4) throw new TransportException("TLS: malformed CertificateVerify");
        ushort scheme = cast(ushort) ((cast(ushort) body[0] << 8) | body[1]);
        ushort sigLen = cast(ushort) ((cast(ushort) body[2] << 8) | body[3]);
        if (body.length < 4 + sigLen)
            throw new TransportException("TLS: malformed CertificateVerify signature");
        auto sig = body[4 .. 4 + sigLen];

        // RFC 8446 section 4.4.3 content to be signed.
        ubyte[] content;
        foreach (i; 0 .. 64) content ~= cast(ubyte) 0x20;
        content ~= cast(ubyte[]) "TLS 1.3, server CertificateVerify";
        content ~= cast(ubyte) 0x00;
        auto th = sha256(transcript);
        content ~= th[];

        bool verified = false;
        if (scheme == 0x0403)                    // ecdsa_secp256r1_sha256
        {
            if (!key.isEc)
                throw new TransportException("TLS: ECDSA CertificateVerify but certificate is not EC");
            ubyte[32] r, s;
            if (!parseEcdsaSigDer(sig, r, s))
                throw new TransportException("TLS: malformed ECDSA signature");
            verified = ecdsaP256VerifySha256(content, key.ecPoint[], r[], s[]);
        }
        else if (scheme == 0x0804)               // rsa_pss_rsae_sha256
        {
            if (key.isEc)
                throw new TransportException("TLS: RSA CertificateVerify but certificate is EC");
            verified = rsaPssVerifySha256(content, sig, key.rsaModulus, key.rsaExponent);
        }
        else
            throw new TransportException("TLS: unsupported CertificateVerify scheme 0x" ~ format("%04x", scheme));

        if (!verified)
            throw new TransportException("TLS: server CertificateVerify signature does not verify");
    }

    private string alertText(const(ubyte)[] payload)
    {
        if (payload.length >= 2)
            return "level " ~ to!string(payload[0]) ~ ", description " ~ to!string(payload[1]);
        return "malformed alert";
    }
}

// ---------------------------------------------------------------------------
// Certificate hostname matching (RFC 6125): SAN dNSNames, single-label `*`.
// ---------------------------------------------------------------------------

private size_t readDerLen(const(ubyte)[] der, ref size_t p)
{
    size_t v = der[p++];
    if (v & 0x80)
    {
        int nb = cast(int) (v & 0x7f);
        v = 0;
        foreach (k; 0 .. nb)
        {
            if (p >= der.length) return 0;
            v = (v << 8) | der[p++];
        }
    }
    return v;
}

/// DNS names from the certificate's subjectAltName extension (2.5.29.17).
private string[] certificateDnsNames(const(ubyte)[] der)
{
    string[] names;
    static immutable ubyte[] OID = [0x06, 0x03, 0x55, 0x1D, 0x11];
    size_t oi = size_t.max;
    foreach (i; 0 .. der.length)
        if (i + OID.length <= der.length && der[i .. i + OID.length] == OID[])
        {
            oi = i;
            break;
        }
    if (oi == size_t.max) return names;

    size_t p = oi + OID.length;
    if (p >= der.length) return names;
    if (der[p] == 0x01)                     // critical BOOLEAN
    {
        p++;
        if (p >= der.length) return names;
        size_t bl = der[p];
        p += 1 + bl;
    }
    if (p >= der.length || der[p] != 0x04) return names;  // extnValue OCTET STRING
    p++;
    readDerLen(der, p);                     // octet string length
    if (p >= der.length || der[p] != 0x30) return names;  // SEQUENCE OF GeneralName
    p++;
    size_t slen = readDerLen(der, p);
    size_t end = p + slen;
    if (end > der.length) end = der.length;
    while (p < end)
    {
        ubyte tag = der[p++];
        if (p >= der.length) break;
        size_t glen = readDerLen(der, p);
        if (p + glen > der.length) break;
        if (tag == 0x82)                    // dNSName (IA5String)
            names ~= cast(string) der[p .. p + glen].dup;
        p += glen;
    }
    return names;
}

/// `true` if `host` matches any of the certificate DNS names.
private bool hostnameMatches(string host, const(string)[] names)
{
    foreach (n; names)
        if (dnsNameMatches(host, n)) return true;
    return false;
}

private bool dnsNameMatches(string host, string pattern)
{
    host = toLower(host);
    pattern = toLower(pattern);
    if (pattern.length == 0) return false;
    if (pattern[0] == '*')
    {
        if (pattern.length < 3 || pattern[1] != '.') return false;
        auto suffix = pattern[2 .. $];
        if (host.length <= suffix.length) return false;
        if (host[$ - suffix.length .. $] != suffix) return false;
        if (host[$ - suffix.length - 1] != '.') return false;
        auto left = host[0 .. $ - suffix.length - 1];
        return left.length > 0 && indexOf(left, '.') < 0;
    }
    return host == pattern;
}

version (unittest)
unittest
{
    assert(hostnameMatches("example.com", ["example.com"]), "exact match");
    assert(hostnameMatches("Example.COM", ["example.com"]), "case-insensitive");
    assert(!hostnameMatches("example.com", ["example.org"]), "different host");
    assert(hostnameMatches("www.example.com", ["*.example.com"]), "wildcard match");
    assert(!hostnameMatches("a.b.example.com", ["*.example.com"]), "wildcard is one label");
    assert(!hostnameMatches("example.com", ["*.example.com"]), "wildcard needs a label");
    assert(hostnameMatches("a.example.com", ["x.example.com", "*.example.com"]), "list match");
    assert(!hostnameMatches("evil.com", ["good.com", "*.other.com"]), "no match in list");
}
