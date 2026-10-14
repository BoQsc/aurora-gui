module auroraweb.crypto;

/**
 * Cryptographic primitives for the browser's TLS 1.3 client, implemented in
 * pure D on top of druntime/Phobos only (`std.digest` for SHA-256, `core.int128`
 * for 64x64->128 multiplication). No OpenSSL, no BoringSSL, no platform crypto:
 * the browser carries its own.
 *
 * Covered here:
 *   - SHA-256 and HMAC-SHA256
 *   - HKDF (RFC 5869) and the TLS 1.3 HKDF-Expand-Label
 *   - AES-128 block cipher and AES-128-GCM (RFC 5288 / NIST SP 800-38D)
 *   - X25519 (RFC 7748), the (EC)DHE group every TLS 1.3 server supports
 *
 * Every routine is checked against its published test vector in the unittests
 * below (FIPS-197, NIST GCM, RFC 4231, RFC 5869, RFC 7748).
 */

import core.int128 : Cent, mul, add;
import std.digest.sha : SHA256;

// ---------------------------------------------------------------------------
// SHA-256 / HMAC / HKDF
// ---------------------------------------------------------------------------

/// SHA-256 of `data`.
ubyte[32] sha256(const(ubyte)[] data)
{
    auto h = new SHA256();
    h.put(data);
    ubyte[32] res;
    auto d = h.finish();
    res[] = d[];
    return res;
}

/// SHA-256 of a string.
ubyte[32] sha256(string s)
{
    return sha256(cast(const(ubyte)[]) s);
}

private enum size_t BLOCK = 64;

/// HMAC-SHA256 (RFC 2104).
ubyte[32] hmacSha256(const(ubyte)[] key, const(ubyte)[] message)
{
    ubyte[BLOCK] k;
    if (key.length > BLOCK)
    {
        auto kk = sha256(key);
        k[0 .. 32] = kk[];
    }
    else
        k[0 .. key.length] = key[];

    ubyte[BLOCK] ipad;
    ubyte[BLOCK] opad;
    foreach (i; 0 .. BLOCK)
    {
        ipad[i] = k[i] ^ 0x36;
        opad[i] = k[i] ^ 0x5c;
    }

    auto inner = sha256(ipad[] ~ message);
    return sha256(opad[] ~ inner[]);
}

/// HKDF-Extract: PRK = HMAC(salt, IKM).
ubyte[32] hkdfExtract(const(ubyte)[] salt, const(ubyte)[] ikm)
{
    return hmacSha256(salt, ikm);
}

/// HKDF-Expand: OKM = first `length` bytes of the T(1)||T(2)||... stream.
ubyte[] hkdfExpand(const(ubyte)[] prk, const(ubyte)[] info, size_t length)
{
    ubyte[] okm;
    ubyte[] t;
    ubyte counter = 1;
    while (okm.length < length)
    {
        t = hmacSha256(prk, t ~ info ~ [counter]).dup;
        okm ~= t;
        counter++;
    }
    okm.length = length;
    return okm;
}

/**
 * TLS 1.3 HKDF-Expand-Label (RFC 8446 section 7.1):
 *   HkdfLabel = uint16 length; opaque label<7..255> ("tls13 " + label);
 *               opaque context<0..255>.
 */
ubyte[] hkdfExpandLabel(const(ubyte)[] secret, string label,
    const(ubyte)[] context, size_t length)
{
    auto fullLabel = "tls13 " ~ label;
    ubyte[] info;
    info ~= cast(ubyte) (length >> 8);
    info ~= cast(ubyte) (length & 0xff);
    info ~= cast(ubyte) fullLabel.length;
    info ~= cast(const(ubyte)[]) fullLabel;
    info ~= cast(ubyte) context.length;
    info ~= context;
    return hkdfExpand(secret, info, length);
}

// ---------------------------------------------------------------------------
// AES-128 (FIPS-197)
// ---------------------------------------------------------------------------

private immutable ubyte[256] SBOX = [
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
];

private ubyte xtime(ubyte b)
{
    return cast(ubyte) ((b << 1) ^ ((b & 0x80) ? 0x1b : 0x00));
}

/// An AES-128 expanded key schedule.
struct Aes128
{
    ubyte[176] roundKeys;
}

/// Expand a 16-byte key into the round-key schedule.
void aes128Init(const(ubyte)[] key, ref Aes128 a)
{
    a.roundKeys[0 .. 16] = key[0 .. 16];
    int bytes = 16;
    ubyte rcon = 1;
    while (bytes < 176)
    {
        ubyte[4] t = [a.roundKeys[bytes - 4], a.roundKeys[bytes - 3],
            a.roundKeys[bytes - 2], a.roundKeys[bytes - 1]];
        if (bytes % 16 == 0)
        {
            ubyte tmp = t[0]; t[0] = t[1]; t[1] = t[2]; t[2] = t[3]; t[3] = tmp;
            foreach (i; 0 .. 4) t[i] = SBOX[t[i]];
            t[0] ^= rcon;
            rcon = xtime(rcon);
        }
        foreach (i; 0 .. 4)
        {
            a.roundKeys[bytes] = cast(ubyte) (a.roundKeys[bytes - 16] ^ t[i]);
            bytes++;
        }
    }
}

private void aesSubBytes(ref ubyte[16] s)
{
    foreach (i; 0 .. 16) s[i] = SBOX[s[i]];
}

private void aesShiftRows(ref ubyte[16] s)
{
    // State is column-major: s[4*c + r]. Row r rotates left by r.
    ubyte[16] t = s;
    foreach (c; 0 .. 4)
        foreach (r; 0 .. 4)
            s[4 * c + r] = t[4 * ((c + r) % 4) + r];
}

private void aesMixColumns(ref ubyte[16] s)
{
    foreach (c; 0 .. 4)
    {
        ubyte a0 = s[4 * c + 0], a1 = s[4 * c + 1], a2 = s[4 * c + 2], a3 = s[4 * c + 3];
        s[4 * c + 0] = cast(ubyte) (xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3);
        s[4 * c + 1] = cast(ubyte) (a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3);
        s[4 * c + 2] = cast(ubyte) (a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3));
        s[4 * c + 3] = cast(ubyte) ((xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3));
    }
}

private void aesAddRoundKey(ref ubyte[16] s, const(ubyte)[] k)
{
    foreach (i; 0 .. 16) s[i] ^= k[i];
}

/// Encrypt one 16-byte block.
void aes128EncryptBlock(const Aes128* a, const(ubyte)[] in_, ref ubyte[16] out_)
{
    ubyte[16] s;
    foreach (i; 0 .. 16) s[i] = in_[i];
    aesAddRoundKey(s, a.roundKeys[0 .. 16]);
    foreach (round; 1 .. 10)
    {
        aesSubBytes(s);
        aesShiftRows(s);
        aesMixColumns(s);
        aesAddRoundKey(s, a.roundKeys[16 * round .. 16 * round + 16]);
    }
    aesSubBytes(s);
    aesShiftRows(s);
    aesAddRoundKey(s, a.roundKeys[160 .. 176]);
    out_ = s;
}

// ---------------------------------------------------------------------------
// AES-128-GCM
// ---------------------------------------------------------------------------

private void ghashXor(ref ubyte[16] z, const(ubyte)[16] v)
{
    foreach (i; 0 .. 16) z[i] ^= v[i];
}

/// GF(2^128) multiply Z = X * H with the GCM bit ordering (MSB-first, R=0xe1).
private void ghashMul(const(ubyte)[16] X, const(ubyte)[16] H, ref ubyte[16] Z)
{
    ubyte[16] v = H;
    Z = 0;
    foreach (i; 0 .. 128)
    {
        if (X[i >> 3] & (0x80 >> (i & 7)))
            ghashXor(Z, v);
        bool lsb = (v[15] & 1) != 0;
        foreach (j; 0 .. 15)
            v[15 - j] = cast(ubyte) ((v[15 - j] >> 1) | ((v[14 - j] & 1) << 7));
        v[0] >>= 1;
        if (lsb) v[0] ^= 0xe1;
    }
}

private ubyte[16] ghash(const(ubyte)[16] H, const(ubyte)[] data)
{
    ubyte[16] y = 0;
    size_t i = 0;
    while (i < data.length)
    {
        ubyte[16] block = 0;
        size_t n = data.length - i < 16 ? data.length - i : 16;
        block[0 .. n] = data[i .. i + n];
        ghashXor(y, block);
        ubyte[16] z;
        ghashMul(y, H, z);
        y = z;
        i += n;
    }
    return y;
}

private void inc32(ref ubyte[16] ctr)
{
    foreach_reverse (i; 0 .. 4)
    {
        ctr[12 + i]++;
        if (ctr[12 + i] != 0) break;
    }
}

/// Encrypt with AES-128-GCM (12-byte IV, optional AAD). Returns the tag; the
/// ciphertext is written into `outCipher` (same length as `plaintext`).
ubyte[16] aes128GcmEncrypt(const(ubyte)[] key, const(ubyte)[] iv,
    const(ubyte)[] aad, const(ubyte)[] plaintext, ref ubyte[] outCipher)
{
    Aes128 a;
    aes128Init(key[0 .. 16].dup, a);
    auto kp = &a;

    ubyte[16] zero = 0;
    ubyte[16] H;
    aes128EncryptBlock(kp, zero, H);

    ubyte[16] J0 = 0;
    J0[0 .. 12] = iv[0 .. 12];
    J0[15] = 1;

    outCipher = new ubyte[plaintext.length];
    ubyte[16] ctr = J0;
    for (size_t off = 0; off < plaintext.length; off += 16)
    {
        inc32(ctr);
        ubyte[16] ks;
        aes128EncryptBlock(kp, ctr, ks);
        size_t n = plaintext.length - off < 16 ? plaintext.length - off : 16;
        foreach (i; 0 .. n)
            outCipher[off + i] = cast(ubyte) (plaintext[off + i] ^ ks[i]);
    }

    // GHASH over AAD || pad || C || pad || len(A)bits || len(C)bits.
    ubyte[] gdata;
    gdata ~= aad;
    if (aad.length % 16) gdata ~= new ubyte[16 - aad.length % 16];
    gdata ~= outCipher;
    if (outCipher.length % 16) gdata ~= new ubyte[16 - outCipher.length % 16];
    ulong aBits = cast(ulong) aad.length * 8;
    ulong cBits = cast(ulong) outCipher.length * 8;
    ubyte[16] lens;
    foreach (i; 0 .. 8) { lens[i] = cast(ubyte) (aBits >> (56 - 8 * i)); }
    foreach (i; 0 .. 8) { lens[8 + i] = cast(ubyte) (cBits >> (56 - 8 * i)); }
    gdata ~= lens[];
    ubyte[16] s = ghash(H, gdata);

    ubyte[16] ek;
    aes128EncryptBlock(kp, J0, ek);
    ubyte[16] tag;
    foreach (i; 0 .. 16) tag[i] = cast(ubyte) (s[i] ^ ek[i]);
    return tag;
}

/// Authenticate and decrypt AES-128-GCM. Returns true (and fills `outPlain`) on
/// a tag match, false otherwise.
bool aes128GcmDecrypt(const(ubyte)[] key, const(ubyte)[] iv,
    const(ubyte)[] aad, const(ubyte)[] ciphertext, const(ubyte)[16] tag,
    ref ubyte[] outPlain)
{
    Aes128 a;
    aes128Init(key[0 .. 16].dup, a);
    auto kp = &a;

    ubyte[16] zero = 0;
    ubyte[16] H;
    aes128EncryptBlock(kp, zero, H);

    ubyte[16] J0 = 0;
    J0[0 .. 12] = iv[0 .. 12];
    J0[15] = 1;

    ubyte[] gdata;
    gdata ~= aad;
    if (aad.length % 16) gdata ~= new ubyte[16 - aad.length % 16];
    gdata ~= ciphertext;
    if (ciphertext.length % 16) gdata ~= new ubyte[16 - ciphertext.length % 16];
    ulong aBits = cast(ulong) aad.length * 8;
    ulong cBits = cast(ulong) ciphertext.length * 8;
    ubyte[16] lens;
    foreach (i; 0 .. 8) lens[i] = cast(ubyte) (aBits >> (56 - 8 * i));
    foreach (i; 0 .. 8) lens[8 + i] = cast(ubyte) (cBits >> (56 - 8 * i));
    gdata ~= lens[];
    ubyte[16] s = ghash(H, gdata);

    ubyte[16] ek;
    aes128EncryptBlock(kp, J0, ek);
    ubyte[16] expected;
    foreach (i; 0 .. 16) expected[i] = cast(ubyte) (s[i] ^ ek[i]);
    ubyte diff = 0;
    foreach (i; 0 .. 16) diff |= expected[i] ^ tag[i];
    if (diff != 0) return false;

    outPlain = new ubyte[ciphertext.length];
    ubyte[16] ctr = J0;
    for (size_t off = 0; off < ciphertext.length; off += 16)
    {
        inc32(ctr);
        ubyte[16] ks;
        aes128EncryptBlock(kp, ctr, ks);
        size_t n = ciphertext.length - off < 16 ? ciphertext.length - off : 16;
        foreach (i; 0 .. n)
            outPlain[off + i] = cast(ubyte) (ciphertext[off + i] ^ ks[i]);
    }
    return true;
}

// ---------------------------------------------------------------------------
// X25519 (RFC 7748) over GF(2^255 - 19), 4x64-bit limbs
// ---------------------------------------------------------------------------

private alias U256 = ulong[4];

private immutable U256 P256 = [
    0xffffffffffffffedUL, 0xffffffffffffffffUL,
    0xffffffffffffffffUL, 0x7fffffffffffffffUL];
private immutable U256 TWO_P = [
    0xffffffffffffffdaUL, 0xffffffffffffffffUL,
    0xffffffffffffffffUL, 0xffffffffffffffffUL];

private Cent mk(ulong lo, ulong hi) { Cent c; c.lo = lo; c.hi = hi; return c; }
private Cent addL(Cent a, ulong b) { return add(a, mk(b, 0)); }

private bool gteP(const U256 a)
{
    foreach_reverse (i; 0 .. 4)
    {
        if (a[i] != P256[i]) return a[i] > P256[i];
    }
    return true; // equal
}

private U256 sub256(const U256 a, const U256 b)
{
    U256 r;
    ulong borrow = 0;
    foreach (i; 0 .. 4)
    {
        ulong t = a[i] - b[i];
        ulong nb = (a[i] < b[i]) ? 1 : 0;
        ulong t2 = t - borrow;
        nb |= (t < borrow) ? 1 : 0;
        r[i] = t2;
        borrow = nb;
    }
    return r;
}

/// Reduce a 5-limb value (< 2^320) modulo p. Closed under canonical outputs.
private U256 reduce5(ulong[5] t)
{
    // value = t[0..4] + t[4]*2^256 ≡ t[0..4] + 38*t[4] (mod p).
    Cent p = mul(t[4], 38);
    U256 res;
    Cent s = addL(mk(t[0], 0), p.lo);
    res[0] = s.lo;
    ulong carry = s.hi;
    s = addL(mk(t[1], 0), p.hi);
    s = addL(s, carry);
    res[1] = s.lo; carry = s.hi;
    s = addL(mk(t[2], 0), carry); res[2] = s.lo; carry = s.hi;
    s = addL(mk(t[3], 0), carry); res[3] = s.lo; carry = s.hi;
    while (carry)
    {
        s = addL(mk(res[0], 0), carry * 38); res[0] = s.lo; carry = s.hi;
        foreach (i; 1 .. 4) { s = addL(mk(res[i], 0), carry); res[i] = s.lo; carry = s.hi; }
    }
    while (gteP(res)) res = sub256(res, P256);
    return res;
}

private U256 reduceWide(ulong[8] r)
{
    ulong[5] t;
    ulong carry = 0;
    foreach (i; 0 .. 4)
    {
        Cent p = mul(r[4 + i], 38);
        Cent s = addL(p, r[i]);
        s = addL(s, carry);
        t[i] = s.lo;
        carry = s.hi;
    }
    t[4] = carry;
    return reduce5(t);
}

private U256 feAdd(const U256 a, const U256 b)
{
    ulong[5] t;
    ulong carry = 0;
    foreach (i; 0 .. 4)
    {
        Cent s = addL(addL(mk(a[i], 0), b[i]), carry);
        t[i] = s.lo;
        carry = s.hi;
    }
    t[4] = carry;
    return reduce5(t);
}

private U256 feSub(const U256 a, const U256 b)
{
    // a + 2p - b (both operands are canonical, so this is non-negative).
    ulong[5] t;
    ulong carry = 0;
    foreach (i; 0 .. 4)
    {
        Cent s = addL(addL(mk(a[i], 0), TWO_P[i]), carry);
        t[i] = s.lo;
        carry = s.hi;
    }
    t[4] = carry;
    // subtract b (4 limbs) from the 5-limb value
    ulong borrow = 0;
    foreach (i; 0 .. 4)
    {
        ulong x = t[i] - b[i];
        ulong nb = (t[i] < b[i]) ? 1 : 0;
        ulong x2 = x - borrow;
        nb |= (x < borrow) ? 1 : 0;
        t[i] = x2;
        borrow = nb;
    }
    t[4] -= borrow;
    return reduce5(t);
}

private U256 feMul(const U256 a, const U256 b)
{
    ulong[8] r;
    foreach (i; 0 .. 4)
    {
        ulong carry = 0;
        foreach (j; 0 .. 4)
        {
            Cent prod = mul(a[i], b[j]);
            Cent s = addL(prod, r[i + j]);
            s = addL(s, carry);
            r[i + j] = s.lo;
            carry = s.hi;
        }
        r[i + 4] = carry;
    }
    return reduceWide(r);
}

private U256 feSq(const U256 a) { return feMul(a, a); }

private U256 feFromBytes(const(ubyte)[] b)
{
    U256 r;
    foreach (i; 0 .. 4)
    {
        ulong v = 0;
        foreach (j; 0 .. 8)
            v |= cast(ulong) b[i * 8 + j] << (8 * j);
        r[i] = v;
    }
    return r;
}

private void feToBytes(const U256 a, ref ubyte[32] out_)
{
    foreach (i; 0 .. 4)
        foreach (j; 0 .. 8)
            out_[i * 8 + j] = cast(ubyte) (a[i] >> (8 * j));
}

private U256 feInvert(const U256 a)
{
    // a^(p-2) mod p. p-2 = 2^255 - 21.
    ubyte[32] e;
    e[0] = 0xeb;
    foreach (i; 1 .. 31) e[i] = 0xff;
    e[31] = 0x7f;

    U256 result = [1, 0, 0, 0];
    foreach_reverse (bit; 0 .. 255)
    {
        result = feSq(result);
        if (e[bit >> 3] & (1 << (bit & 7)))
            result = feMul(result, a);
    }
    return result;
}

private void cswap(bool swap, ref U256 a, ref U256 b)
{
    if (!swap) return;
    foreach (i; 0 .. 4)
    {
        auto t = a[i]; a[i] = b[i]; b[i] = t;
    }
}

/// X25519 scalar multiplication (RFC 7748). `scalar` is clamped internally.
ubyte[32] x25519(const(ubyte)[] scalar, const(ubyte)[] u)
{
    ubyte[32] k;
    k[0 .. 32] = scalar[0 .. 32];
    k[0] &= 248;
    k[31] &= 127;
    k[31] |= 64;

    ubyte[32] ub;
    ub[0 .. 32] = u[0 .. 32];
    ub[31] &= 0x7f; // mask the top bit of the u-coordinate
    U256 x1 = feFromBytes(ub);
    U256 x2 = [1, 0, 0, 0];
    U256 z2 = [0, 0, 0, 0];
    U256 x3 = x1;
    U256 z3 = [1, 0, 0, 0];
    U256 a24 = [121665, 0, 0, 0];

    int swap = 0;
    foreach_reverse (t; 0 .. 255)
    {
        int kt = (k[t >> 3] >> (t & 7)) & 1;
        swap ^= kt;
        cswap(swap != 0, x2, x3);
        cswap(swap != 0, z2, z3);
        swap = kt;

        auto A = feAdd(x2, z2);
        auto AA = feSq(A);
        auto B = feSub(x2, z2);
        auto BB = feSq(B);
        auto E = feSub(AA, BB);
        auto C = feAdd(x3, z3);
        auto D = feSub(x3, z3);
        auto DA = feMul(D, A);
        auto CB = feMul(C, B);
        x3 = feSq(feAdd(DA, CB));
        z3 = feMul(x1, feSq(feSub(DA, CB)));
        x2 = feMul(AA, BB);
        z2 = feMul(E, feAdd(AA, feMul(E, a24)));
    }
    cswap(swap != 0, x2, x3);
    cswap(swap != 0, z2, z3);

    ubyte[32] res;
    feToBytes(feMul(x2, feInvert(z2)), res);
    return res;
}

/// X25519 to the base point (u = 9), i.e. derive a public key from a private key.
ubyte[32] x25519Base(const(ubyte)[] scalar)
{
    ubyte[32] nine;
    nine[0] = 9; // base point u = 9 (not a fill: a scalar init would fill all bytes)
    return x25519(scalar, nine);
}

// ---------------------------------------------------------------------------
// P-256 (secp256r1) ECDSA verification, for TLS CertificateVerify.
// Generic 256-bit modular arithmetic (modulus > 2^255) shared by the field
// prime p and the group order n. Little-endian 64-bit limbs.
// ---------------------------------------------------------------------------

private immutable ulong[] P256_P = [0xFFFFFFFFFFFFFFFFUL, 0x00000000FFFFFFFFUL,
    0x0000000000000000UL, 0xFFFFFFFF00000001UL];
private immutable ulong[] P256_CP = [0x0000000000000001UL, 0xFFFFFFFF00000000UL,
    0xFFFFFFFFFFFFFFFFUL, 0x00000000FFFFFFFEUL];
private immutable ulong[] P256_N = [0xF3B9CAC2FC632551UL, 0xBCE6FAADA7179E84UL,
    0xFFFFFFFFFFFFFFFFUL, 0xFFFFFFFF00000000UL];
private immutable ulong[] P256_CN = [0x0C46353D039CDAAFUL, 0x4319055258E8617BUL,
    0x0000000000000000UL, 0x00000000FFFFFFFFUL];
private immutable ulong[] P256_GX = [0xf4a13945d898c296UL, 0x77037d812deb33a0UL,
    0xf8bce6e563a440f2UL, 0x6b17d1f2e12c4247UL];
private immutable ulong[] P256_GY = [0xcbb6406837bf51f5UL, 0x2bce33576b315eceUL,
    0x8ee7eb4a7c0f9e16UL, 0x4fe342e2fe1a7f9bUL];

private ulong[] arrTrim(ulong[] a)
{
    while (a.length > 1 && a[$ - 1] == 0) a.length--;
    return a;
}

private int arrCmp(const(ulong)[] a, const(ulong)[] b)
{
    size_t la = a.length; while (la > 1 && a[la - 1] == 0) la--;
    size_t lb = b.length; while (lb > 1 && b[lb - 1] == 0) lb--;
    if (la != lb) return la < lb ? -1 : 1;
    foreach_reverse (i; 0 .. la)
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    return 0;
}

private ulong[] arrAdd(const(ulong)[] a, const(ulong)[] b)
{
    size_t n = a.length > b.length ? a.length : b.length;
    auto r = new ulong[](n + 1);
    ulong carry = 0;
    foreach (i; 0 .. n)
    {
        ulong av = i < a.length ? a[i] : 0;
        ulong bv = i < b.length ? b[i] : 0;
        Cent s = addL(addL(mk(av, 0), bv), carry);
        r[i] = s.lo;
        carry = s.hi;
    }
    r[n] = carry;
    return arrTrim(r);
}

private ulong[] arrSub(const(ulong)[] a, const(ulong)[] b) // a >= b
{
    auto r = new ulong[](a.length);
    ulong borrow = 0;
    foreach (i; 0 .. a.length)
    {
        ulong av = a[i];
        ulong bv = i < b.length ? b[i] : 0;
        ulong t = av - bv;
        ulong nb = (av < bv) ? 1 : 0;
        ulong t2 = t - borrow;
        nb |= (t < borrow) ? 1 : 0;
        r[i] = t2;
        borrow = nb;
    }
    return arrTrim(r);
}

private ulong[] arrMul(const(ulong)[] a, const(ulong)[] b)
{
    auto r = new ulong[](a.length + b.length);
    foreach (i; 0 .. a.length)
    {
        if (a[i] == 0) continue;
        ulong carry = 0;
        foreach (j; 0 .. b.length)
        {
            Cent s = addL(addL(mul(a[i], b[j]), r[i + j]), carry);
            r[i + j] = s.lo;
            carry = s.hi;
        }
        size_t k = i + b.length;
        while (carry != 0 && k < r.length)
        {
            Cent s = addL(mk(r[k], 0), carry);
            r[k] = s.lo;
            carry = s.hi;
            k++;
        }
    }
    return arrTrim(r);
}

/// Reduce `v` mod m (m > 2^255), with c = 2^256 - m. Returns 4 limbs.
private ulong[] modReduce(ulong[] v, const(ulong)[] m, const(ulong)[] c)
{
    arrTrim(v);
    while (v.length > 4)
    {
        auto H = v[4 .. $].dup;
        auto L = v[0 .. 4].dup;
        v = arrAdd(arrMul(H, c), L);
    }
    while (arrCmp(v, m) >= 0) v = arrSub(v, m);
    auto r = new ulong[](4);
    r[0 .. v.length] = v[];
    return r;
}

private ulong[] modMul(const(ulong)[] a, const(ulong)[] b,
    const(ulong)[] m, const(ulong)[] c)
{
    return modReduce(arrMul(a, b), m, c);
}

private ulong[] modPow(const(ulong)[] baseIn, const(ulong)[] exp,
    const(ulong)[] m, const(ulong)[] c)
{
    auto base = new ulong[](4);
    base[0 .. baseIn.length] = baseIn[];
    auto result = new ulong[](4);
    result[0] = 1;
    int top = -1;
    foreach_reverse (i; 0 .. 4 * 64)
        if ((exp[i >> 6] >> (i & 63)) & 1) { top = i; break; }
    if (top < 0) return result;
    foreach_reverse (bit; 0 .. top + 1)
    {
        result = modMul(result, result, m, c);
        if ((exp[bit >> 6] >> (bit & 63)) & 1)
            result = modMul(result, base, m, c);
    }
    return result;
}

private ulong[] modInv(const(ulong)[] a, const(ulong)[] m, const(ulong)[] c)
{
    // a^(m-2) mod m
    auto e = arrSub(m, [2UL]);
    return modPow(a, e, m, c);
}

private bool arrEq(const(ulong)[] a, const(ulong)[] b) { return arrCmp(a, b) == 0; }
private ulong[] arrZero() { return new ulong[](4); }

private ulong[] modAdd(const(ulong)[] a, const(ulong)[] b, const(ulong)[] m, const(ulong)[] c)
{
    return modReduce(arrAdd(a, b), m, c);
}
private ulong[] modSub(const(ulong)[] a, const(ulong)[] b, const(ulong)[] m, const(ulong)[] c)
{
    return modReduce(arrAdd(a, arrSub(m, b)), m, c);
}

private struct EcPoint
{
    ulong[] x;
    ulong[] y;
    bool inf;
}

private EcPoint ecDouble(const EcPoint P)
{
    if (P.inf || arrCmp(P.y, [0UL]) == 0) return EcPoint(null, null, true);
    auto p = P256_P, cp = P256_CP;
    // lambda = (3x^2 + a) / (2y), a = -3
    auto x2 = modMul(P.x, P.x, p, cp);
    auto num = modSub(modMul([3UL], x2, p, cp), [3UL], p, cp);
    auto den = modMul([2UL], P.y, p, cp);
    auto lambda = modMul(num, modInv(den, p, cp), p, cp);
    auto x3 = modSub(modSub(modMul(lambda, lambda, p, cp), P.x, p, cp), P.x, p, cp);
    auto y3 = modSub(modMul(lambda, modSub(P.x, x3, p, cp), p, cp), P.y, p, cp);
    return EcPoint(x3, y3, false);
}

private EcPoint ecAdd(EcPoint P, EcPoint Q)
{
    if (P.inf) return Q;
    if (Q.inf) return P;
    auto p = P256_P, cp = P256_CP;
    if (arrEq(P.x, Q.x))
    {
        if (arrCmp(modAdd(P.y, Q.y, p, cp), [0UL]) == 0)
            return EcPoint(null, null, true);
        return ecDouble(P);
    }
    auto num = modSub(Q.y, P.y, p, cp);
    auto den = modSub(Q.x, P.x, p, cp);
    auto lambda = modMul(num, modInv(den, p, cp), p, cp);
    auto x3 = modSub(modSub(modMul(lambda, lambda, p, cp), P.x, p, cp), Q.x, p, cp);
    auto y3 = modSub(modMul(lambda, modSub(P.x, x3, p, cp), p, cp), P.y, p, cp);
    return EcPoint(x3, y3, false);
}

private EcPoint ecMul(const(ulong)[] k, EcPoint P)
{
    EcPoint R = EcPoint(null, null, true);
    foreach_reverse (bit; 0 .. 256)
    {
        R = ecDouble(R);
        if ((k[bit >> 6] >> (bit & 63)) & 1)
            R = ecAdd(R, P);
    }
    return R;
}

private ulong[] beToLimbs(const(ubyte)[] be)
{
    auto r = new ulong[](4);
    foreach (i; 0 .. 4)
    {
        ulong v = 0;
        foreach (j; 0 .. 8)
        {
            auto idx = be.length - 1 - (i * 8 + j);
            if (idx >= 0 && idx < be.length) v |= cast(ulong) be[idx] << (8 * j);
        }
        r[i] = v;
    }
    return r;
}

/// Parse a DER ECDSA signature (SEQUENCE of two INTEGERs) into r and s (32-byte
/// big-endian each). Returns false on malformed input.
bool parseEcdsaSigDer(const(ubyte)[] der, ref ubyte[32] r, ref ubyte[32] s)
{
    size_t p;
    if (der.length < 8 || der[0] != 0x30) return false;
    p = 2;
    bool readInt(ref ubyte[32] dst)
    {
        if (p >= der.length || der[p] != 0x02) return false;
        p++;
        if (p >= der.length) return false;
        size_t len = der[p++];
        if (p + len > der.length) return false;
        auto val = der[p .. p + len];
        p += len;
        // strip leading zeroes, then left-pad to 32 bytes
        while (val.length > 1 && val[0] == 0) val = val[1 .. $];
        if (val.length > 32) return false;
        dst = 0;
        dst[32 - val.length .. 32] = val[];
        return true;
    }
    return readInt(r) && readInt(s);
}

/**
 * Verify an ECDSA P-256 / SHA-256 signature. `pubUncompressed` is the 65-byte
 * uncompressed point (0x04 || X || Y). `r` and `s` are 32-byte big-endian.
 */
bool ecdsaP256VerifySha256(const(ubyte)[] message, const(ubyte)[] pubUncompressed,
    const(ubyte)[] r32, const(ubyte)[] s32)
{
    if (pubUncompressed.length != 65 || pubUncompressed[0] != 0x04) return false;
    auto p = P256_P, cp = P256_CP, n = P256_N, cn = P256_CN;

    auto e = sha256(message);
    auto eInt = modReduce(beToLimbs(e[]), n, cn);
    auto r = modReduce(beToLimbs(r32), n, cn);
    auto s = modReduce(beToLimbs(s32), n, cn);
    if (arrCmp(r, [0UL]) == 0 || arrCmp(s, [0UL]) == 0) return false;

    auto w = modInv(s, n, cn);
    auto u1 = modMul(eInt, w, n, cn);
    auto u2 = modMul(r, w, n, cn);

    EcPoint G = EcPoint(P256_GX.dup, P256_GY.dup, false);
    EcPoint Q = EcPoint(beToLimbs(pubUncompressed[1 .. 33]),
        beToLimbs(pubUncompressed[33 .. 65]), false);

    auto R = ecAdd(ecMul(u1, G), ecMul(u2, Q));
    if (R.inf) return false;
    auto v = modReduce(R.x.dup, n, cn);
    return arrEq(v, r);
}

// ---------------------------------------------------------------------------
// RSA (RSASSA-PSS with SHA-256) verification, for TLS CertificateVerify.
// Generic big-integer modular exponentiation via Montgomery multiplication.
// ---------------------------------------------------------------------------

private ulong[] biPad(const(ulong)[] a, size_t L)
{
    auto r = new ulong[](L);
    foreach (i; 0 .. (a.length < L ? a.length : L)) r[i] = a[i];
    return r;
}

/// Montgomery multiplication mod n (n odd, L = n.length limbs).
private ulong[] montMul(const(ulong)[] aIn, const(ulong)[] bIn,
    const(ulong)[] n, ulong nInv)
{
    size_t L = n.length;
    auto a = biPad(aIn, L);
    auto b = biPad(bIn, L);
    auto T = new ulong[](2 * L + 1);

    foreach (i; 0 .. L)
    {
        ulong carry = 0;
        foreach (j; 0 .. L)
        {
            Cent s = addL(addL(mul(a[i], b[j]), T[i + j]), carry);
            T[i + j] = s.lo;
            carry = s.hi;
        }
        T[i + L] += carry;
    }

    foreach (i; 0 .. L)
    {
        ulong m = T[0] * nInv;
        ulong carry = 0;
        foreach (j; 0 .. L)
        {
            Cent s = addL(addL(mul(m, n[j]), T[j]), carry);
            T[j] = s.lo;
            carry = s.hi;
        }
        size_t k = L;
        while (carry != 0)
        {
            Cent s = addL(mk(T[k], 0), carry);
            T[k] = s.lo;
            carry = s.hi;
            k++;
        }
        foreach (j; 0 .. 2 * L) T[j] = T[j + 1];
        T[2 * L] = 0;
    }

    auto res = T[0 .. L].dup;
    if (T[L] != 0)
        res = arrSub(res, n);           // V - n (fits, since n > 2^(64L-1))
    else
        while (arrCmp(res, n) >= 0) res = arrSub(res, n);
    return biPad(res, L);
}

private ulong[] doubleMod(const(ulong)[] x, const(ulong)[] n)
{
    size_t L = n.length;
    auto t = new ulong[](L);
    ulong carry = 0;
    foreach (i; 0 .. L)
    {
        ulong v = x[i];
        t[i] = (v << 1) | carry;
        carry = v >> 63;
    }
    if (carry != 0 || arrCmp(t, n) >= 0)
        t = arrSub(t, n);
    return t;
}

/// base^exp mod n, big-endian exponent bytes, using Montgomery arithmetic.
private ulong[] modPowBig(const(ulong)[] baseIn, const(ubyte)[] expBE, const(ulong)[] n)
{
    size_t L = n.length;
    ulong nInv = 1;
    ulong n0 = n[0];
    foreach (i; 0 .. 6) nInv *= 2 - n0 * nInv;   // n^-1 mod 2^64
    nInv = 0 - nInv;

    // rmod = 2^(64L) mod n
    auto rmod = new ulong[](L); rmod[0] = 1;
    foreach (k; 0 .. 64 * L) rmod = doubleMod(rmod, n);
    // r2 = 2^(128L) mod n
    auto r2 = rmod.dup;
    foreach (k; 0 .. 64 * L) r2 = doubleMod(r2, n);

    auto base = biPad(baseIn, L);
    auto aM = montMul(base, r2, n, nInv);
    auto resM = biPad(rmod, L);                    // Montgomery 1

    // exponent bits, MSB first
    foreach (i; 0 .. expBE.length)
    {
        foreach_reverse (b; 0 .. 8)
        {
            resM = montMul(resM, resM, n, nInv);
            if ((expBE[i] >> b) & 1)
                resM = montMul(resM, aM, n, nInv);
        }
    }
    return montMul(resM, biPad([1UL], L), n, nInv);
}

/// MGF1 with SHA-256 (RFC 8017 appendix B.2.1).
private ubyte[] mgf1Sha256(const(ubyte)[] seed, size_t len)
{
    ubyte[] outBytes;
    uint counter = 0;
    while (outBytes.length < len)
    {
        ubyte[] c = seed.dup;
        c ~= cast(ubyte) (counter >> 24);
        c ~= cast(ubyte) (counter >> 16);
        c ~= cast(ubyte) (counter >> 8);
        c ~= cast(ubyte) counter;
        auto h = sha256(c);
        outBytes ~= h[];
        counter++;
    }
    outBytes.length = len;
    return outBytes;
}

/**
 * Verify an RSASSA-PSS signature with SHA-256 (salt length = 32), given the
 * RSA modulus (big-endian) and public exponent.
 */
bool rsaPssVerifySha256(const(ubyte)[] message, const(ubyte)[] sig,
    const(ubyte)[] nBE, ulong e)
{
    if (nBE.length == 0) return false;
    auto n = beToLimbsBig(nBE);
    size_t L = n.length;

    auto s = beToLimbsBig(sig);
    if (arrCmp(biPad(s, L), n) >= 0) return false;   // signature out of range

    ubyte[] eBE;
    for (int shift = 56; shift >= 0; shift -= 8) eBE ~= cast(ubyte) (e >> shift);
    // strip leading zero bytes of exponent
    size_t z = 0; while (z + 1 < eBE.length && eBE[z] == 0) z++;
    eBE = eBE[z .. $];

    auto m = modPowBig(s, eBE, n);
    auto em = limbsToBe(m, nBE.length);              // I2OSP(m, k)

    // EMSA-PSS-VERIFY (SHA-256, sLen = hLen = 32), emBits = 8*k - 1.
    enum size_t hLen = 32;
    enum size_t sLen = 32;
    size_t emLen = em.length;
    size_t dbLen = emLen - hLen - 1;
    if (em[emLen - 1] != 0xbc) return false;
    auto maskedDB = em[0 .. dbLen].dup;
    auto h = em[dbLen .. dbLen + hLen];

    // The leftmost 8*emLen - emBits bits must be zero (here: top bit).
    size_t splitBits = 8 * emLen - (8 * nBE.length - 1); // = 1 for full-size keys
    if (splitBits > 0 && (maskedDB[0] >> (8 - splitBits)) != 0) return false;

    auto dbMask = mgf1Sha256(h, dbLen);
    ubyte[] db;
    foreach (i; 0 .. dbLen) db ~= cast(ubyte) (maskedDB[i] ^ dbMask[i]);
    if (splitBits > 0) db[0] &= cast(ubyte) (0xff >> splitBits);

    // DB = 0x00 .. 0x00 || 0x01 || salt   (DB contains only PS and the salt)
    size_t psLen = dbLen - sLen - 1;
    foreach (i; 0 .. psLen) if (db[i] != 0) return false;
    if (db[psLen] != 0x01) return false;
    auto salt = db[psLen + 1 .. psLen + 1 + sLen];

    ubyte[] mPrime;
    foreach (i; 0 .. 8) mPrime ~= cast(ubyte) 0;      // 8 zero bits
    auto mHash = sha256(message);
    mPrime ~= mHash[];
    mPrime ~= salt;
    auto hPrime = sha256(mPrime);
    foreach (i; 0 .. hLen) if (hPrime[i] != h[i]) return false;
    return true;
}

private ulong[] beToLimbsBig(const(ubyte)[] be)
{
    size_t L = (be.length + 7) / 8;
    if (L == 0) L = 1;
    auto r = new ulong[](L);
    foreach (i; 0 .. L)
    {
        ulong v = 0;
        foreach (j; 0 .. 8)
        {
            auto idx = be.length - 1 - (i * 8 + j);
            if (idx >= 0 && idx < be.length) v |= cast(ulong) be[idx] << (8 * j);
        }
        r[i] = v;
    }
    return arrTrim(r);
}

private ubyte[] limbsToBe(const(ulong)[] a, size_t outLen)
{
    auto r = new ubyte[](outLen);
    foreach (i; 0 .. outLen)
    {
        size_t limb = i / 8;
        size_t shift = (i % 8) * 8;
        ulong v = limb < a.length ? a[limb] : 0;
        r[outLen - 1 - i] = cast(ubyte) (v >> shift);
    }
    return r;
}

// ---------------------------------------------------------------------------
// Test vectors
// ---------------------------------------------------------------------------

unittest
{
    // SHA-256("abc")
    auto d = sha256("abc");
    ubyte[32] expect = [
        0xba,0x78,0x16,0xbf,0x8f,0x01,0xcf,0xea,0x41,0x41,0x40,0xde,0x5d,0xae,0x22,0x23,
        0xb0,0x03,0x61,0xa3,0x96,0x17,0x7a,0x9c,0xb4,0x10,0xff,0x61,0xf2,0x00,0x15,0xad];
    assert(d == expect, "SHA-256 vector");

    // HMAC-SHA256, RFC 4231 test case 1
    ubyte[] key = new ubyte[](20);
    key[] = 0x0b;
    auto mac = hmacSha256(key, cast(const(ubyte)[]) "Hi There");
    ubyte[32] macExpect = [
        0xb0,0x34,0x4c,0x61,0xd8,0xdb,0x38,0x53,0x5c,0xa8,0xaf,0xce,0xaf,0x0b,0xf1,0x2b,
        0x88,0x1d,0xc2,0x00,0xc9,0x83,0x3d,0xa7,0x26,0xe9,0x37,0x6c,0x2e,0x32,0xcf,0xf7];
    assert(mac == macExpect, "HMAC-SHA256 vector");
}

unittest
{
    // HKDF, RFC 5869 test case 1
    ubyte[] ikm = new ubyte[](22);
    ikm[] = 0x0b;
    ubyte[] salt;
    foreach (i; 0 .. 13) salt ~= cast(ubyte) i;
    ubyte[] info;
    foreach (i; 0 .. 10) info ~= cast(ubyte) (0xf0 + i);

    auto prk = hkdfExtract(salt, ikm);
    ubyte[32] prkExpect = [
        0x07,0x77,0x09,0x36,0x2c,0x2e,0x32,0xdf,0x0d,0xdc,0x3f,0x0d,0xc4,0x7b,0xba,0x63,
        0x90,0xb6,0xc7,0x3b,0xb5,0x0f,0x9c,0x31,0x22,0xec,0x84,0x4a,0xd7,0xc2,0xb3,0xe5];
    assert(prk == prkExpect, "HKDF-Extract vector");

    auto okm = hkdfExpand(prk, info, 42);
    ubyte[42] okmExpect = [
        0x3c,0xb2,0x5f,0x25,0xfa,0xac,0xd5,0x7a,0x90,0x43,0x4f,0x64,0xd0,0x36,0x2f,0x2a,
        0x2d,0x2d,0x0a,0x90,0xcf,0x1a,0x5a,0x4c,0x5d,0xb0,0x2d,0x56,0xec,0xc4,0xc5,0xbf,
        0x34,0x00,0x72,0x08,0xd5,0xb8,0x87,0x18,0x58,0x65];
    assert(okm == okmExpect[], "HKDF-Expand vector");
}

unittest
{
    // AES-128, FIPS-197 appendix B/C
    ubyte[16] key = [0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,
                     0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f];
    ubyte[16] pt = [0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,
                    0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff];
    Aes128 a;
    aes128Init(key, a);
    ubyte[16] ct;
    aes128EncryptBlock(&a, pt, ct);
    ubyte[16] ctExpect = [0x69,0xc4,0xe0,0xd8,0x6a,0x7b,0x04,0x30,
                          0xd8,0xcd,0xb7,0x80,0x70,0xb4,0xc5,0x5a];
    assert(ct == ctExpect, "AES-128 vector");

    // AES-128-GCM, NIST SP 800-38D test case 1 (empty key/iv/pt/aad)
    ubyte[16] zkey;
    ubyte[12] ziv;
    ubyte[] cipher;
    ubyte[16] tag = aes128GcmEncrypt(zkey[], ziv[], null, null, cipher);
    ubyte[16] tagExpect = [0x58,0xe2,0xfc,0xce,0xfa,0x7e,0x30,0x61,
                           0x36,0x7f,0x1d,0x57,0xa4,0xe7,0x45,0x5a];
    assert(cipher.length == 0, "empty GCM ciphertext");
    assert(tag == tagExpect, "AES-128-GCM empty tag vector");

    // NIST test case 2: all-zero key/iv, one all-zero plaintext block.
    ubyte[16] zpt;
    ubyte[] c2;
    ubyte[16] t2 = aes128GcmEncrypt(zkey[], ziv[], null, zpt[], c2);
    ubyte[16] c2Expect = [0x03,0x88,0xda,0xce,0x60,0xb6,0xa3,0x92,
                          0xf3,0x28,0xc2,0xb9,0x71,0xb2,0xfe,0x78];
    ubyte[16] t2Expect = [0xab,0x6e,0x47,0xd4,0x2c,0xec,0x13,0xbd,
                          0xf5,0x3a,0x67,0xb2,0x12,0x57,0xbd,0xdf];
    assert(c2 == c2Expect[], "GCM ciphertext (case 2)");
    assert(t2 == t2Expect, "GCM tag (case 2)");
}

unittest
{
    // AES-128-GCM round-trip across lengths, with AAD. (The two NIST vectors
    // above pin the exact bytes for the empty and single-block cases.)
    import std.conv : to;
    ubyte[16] key = [0xfe,0xff,0xe9,0x92,0x86,0x65,0x73,0x1c,
                     0x6d,0x6a,0x8f,0x94,0x67,0x30,0x83,0x08];
    ubyte[12] iv = [0xca,0xfe,0xba,0xbe,0xfa,0xce,0xdb,0xad,0xde,0xca,0xf8,0x88];
    ubyte[] aad = cast(ubyte[]) "associated-data";
    foreach (n; [0, 1, 15, 16, 17, 60, 64, 257])
    {
        ubyte[] pt = new ubyte[](n);
        foreach (i; 0 .. n) pt[i] = cast(ubyte) (i * 7 + 1);
        ubyte[] ct;
        auto tag = aes128GcmEncrypt(key[], iv[], aad, pt, ct);
        assert(ct.length == n, "ct length " ~ to!string(n));
        ubyte[] back;
        assert(aes128GcmDecrypt(key[], iv[], aad, ct, tag, back),
            "gcm decrypt " ~ to!string(n));
        assert(back == pt, "gcm round-trip " ~ to!string(n));
        ubyte[16] bad = tag; bad[n % 16] ^= 1;
        ubyte[] dummy;
        assert(!aes128GcmDecrypt(key[], iv[], aad, ct, bad, dummy),
            "tamper rejected " ~ to!string(n));
    }
}

unittest
{
    // Field arithmetic self-checks (independent of any X25519 vector).
    U256 a = [0x123456789abcdef0UL, 0xfedcba9876543210UL,
              0x1122334455667788UL, 0x0abcdef00fedcba9UL];
    assert(feAdd(a, [0UL, 0, 0, 0]) == a, "feAdd identity");
    assert(feSub(a, a) == [0UL, 0, 0, 0], "feSub self");
    assert(feMul(a, [1UL, 0, 0, 0]) == a, "feMul identity");
    assert(feMul(a, feInvert(a)) == [1UL, 0, 0, 0], "feInvert a*inv(a)=1");
}

unittest
{
    // X25519, RFC 7748 section 5.2
    auto scalar1 = hexToBytes("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4");
    auto u1 = hexToBytes("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c");
    auto out1 = x25519(scalar1, u1);
    assert(toHex(out1) == "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552",
        "X25519 vector 1: " ~ toHex(out1));

    auto scalar2 = hexToBytes("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d");
    auto u2 = hexToBytes("e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493");
    auto out2 = x25519(scalar2, u2);
    assert(toHex(out2) == "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957",
        "X25519 vector 2: " ~ toHex(out2));

    // Diffie-Hellman agreement (RFC 7748 section 6.1).
    auto aPriv = hexToBytes("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
    auto bPriv = hexToBytes("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
    auto aPub = x25519Base(aPriv);
    auto bPub = x25519Base(bPriv);
    assert(toHex(aPub) == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a",
        "X25519 Alice public: " ~ toHex(aPub));
    assert(toHex(bPub) == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f",
        "X25519 Bob public: " ~ toHex(bPub));
    auto shared1 = x25519(aPriv, bPub);
    auto shared2 = x25519(bPriv, aPub);
    assert(shared1 == shared2, "X25519 shared secret agreement");
    assert(toHex(shared1) == "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742",
        "X25519 shared secret: " ~ toHex(shared1));
}

unittest
{
    // ECDSA P-256 / SHA-256 verify, RFC 6979 A.2.5 (message "sample").
    auto qx = hexToBytes("60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6");
    auto qy = hexToBytes("7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299");
    ubyte[] pub;
    pub ~= cast(ubyte) 0x04;
    pub ~= qx;
    pub ~= qy;
    auto r = hexToBytes("EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716");
    auto s = hexToBytes("F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8");
    assert(ecdsaP256VerifySha256(cast(const(ubyte)[]) "sample", pub, r, s),
        "ECDSA P-256 verify (RFC 6979 A.2.5)");
    assert(!ecdsaP256VerifySha256(cast(const(ubyte)[]) "samplE", pub, r, s),
        "ECDSA verify must reject a changed message");

    // DER signature parsing round-trip.
    ubyte[32] rr, ss;
    ubyte[] body;
    body ~= 0x02; body ~= 32; body ~= r;
    body ~= 0x02; body ~= 32; body ~= s;
    ubyte[] derSig;
    derSig ~= 0x30; derSig ~= cast(ubyte) body.length;
    derSig ~= body;
    assert(parseEcdsaSigDer(derSig, rr, ss), "DER sig parse");
    assert(rr[] == r[], "DER r round-trip");
    assert(ss[] == s[], "DER s round-trip");
}

unittest
{
    // Montgomery modexp sanity (RSA path).
    assert(arrEq(modPowBig([3UL], [cast(ubyte) 5], [7UL]), [5UL]), "mont 3^5 mod 7");
    assert(arrEq(modPowBig([2UL], [cast(ubyte) 10], [13UL]), [10UL]), "mont 2^10 mod 13");
    ulong m61 = (1UL << 61) - 1;
    assert(arrEq(modPowBig([2UL], [cast(ubyte) 255], [m61]), [2048UL]),
        "mont 2^255 mod 2^61-1");
}

// --- test helpers ---


private ubyte[] hexToBytes(string s)
{
    ubyte[] res;
    int hi = -1;
    foreach (ch; s)
    {
        int v;
        if (ch >= '0' && ch <= '9') v = ch - '0';
        else if (ch >= 'a' && ch <= 'f') v = ch - 'a' + 10;
        else if (ch >= 'A' && ch <= 'F') v = ch - 'A' + 10;
        else continue;
        if (hi < 0) hi = v;
        else { res ~= cast(ubyte) ((hi << 4) | v); hi = -1; }
    }
    return res;
}

private string toHex(const(ubyte)[] data)
{
    static immutable char[16] digits = "0123456789abcdef";
    string s;
    foreach (b; data)
    {
        s ~= digits[b >> 4];
        s ~= digits[b & 0xf];
    }
    return s;
}
