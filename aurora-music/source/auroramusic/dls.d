/// A small reader for DLS (Downloadable Sounds) instrument banks, such as the
/// General MIDI bank Windows ships at `C:\Windows\System32\drivers\gm.dls`.
///
/// The parser is pure D and platform-independent; only the default file path is
/// platform-specific. It yields, for each instrument, a set of regions that map
/// a key/velocity range to a PCM wave plus the root key and loop points needed
/// to play it at any pitch.
module auroramusic.dls;

import std.file : exists, read;

/// One decoded mono PCM wave from the DLS wave pool.
struct DlsWave
{
    short[] pcm;
    int sampleRate;
}

/// A region: a key/velocity range that plays one wave at a given root key.
struct DlsRegion
{
    int keyLow, keyHigh;
    int velLow, velHigh;
    int rootKey;
    int fineCents;
    int loopStart;
    int loopLength;
    int waveIndex;
}

struct DlsInstrument
{
    int program;
    uint selector;
    bool drum;
    DlsRegion[] regions;
}

struct Dls
{
    DlsWave[] waves;
    DlsInstrument[] instruments;

    /// First non-drum instrument for a GM program on bank 0, or -1.
    int findProgram(int program) const
    {
        int fallback = -1;
        foreach (i, ins; instruments)
        {
            if (ins.drum || ins.program != program) continue;
            if (ins.selector == 0) return cast(int) i;
            if (fallback < 0) fallback = cast(int) i;
        }
        return fallback;
    }

    /// First drum kit (the GM Standard kit is program 0).
    int findDrumKit() const
    {
        foreach (i, ins; instruments)
            if (ins.drum) return cast(int) i;
        return -1;
    }
}

private uint u32(const(ubyte)[] d, size_t o)
{
    return cast(uint)(d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24));
}

private ushort u16(const(ubyte)[] d, size_t o)
{
    return cast(ushort)(d[o] | (d[o + 1] << 8));
}

private short i16(const(ubyte)[] d, size_t o)
{
    return cast(short) u16(d, o);
}

private int i32(const(ubyte)[] d, size_t o)
{
    return cast(int) u32(d, o);
}

private string id(const(ubyte)[] d, size_t o)
{
    string s;
    foreach (i; 0 .. 4) s ~= cast(char) d[o + i];
    return s;
}

private bool findChunk(const(ubyte)[] d, size_t a, size_t b, string want,
    out size_t body, out uint size)
{
    size_t p = a;
    while (p + 8 <= b)
    {
        uint sz = u32(d, p + 4);
        if (id(d, p) == want) { body = p + 8; size = sz; return true; }
        p = p + 8 + sz + (sz & 1);
    }
    return false;
}

private struct Span
{
    size_t start, end;
}

private bool findList(const(ubyte)[] d, size_t a, size_t b, string listType,
    out Span sp)
{
    size_t p = a;
    while (p + 12 <= b)
    {
        uint sz = u32(d, p + 4);
        if (id(d, p) == "LIST" && id(d, p + 8) == listType)
        {
            sp.start = p + 12;
            sp.end = p + 8 + sz;
            return true;
        }
        p = p + 8 + sz + (sz & 1);
    }
    return false;
}

/// Parse a DLS bank held in memory.
Dls parseDls(const(ubyte)[] d)
{
    Dls result;
    if (d.length < 12 || id(d, 0) != "RIFF" || id(d, 8) != "DLS ")
        return result;
    size_t topEnd = 8 + cast(size_t) u32(d, 4);
    if (topEnd > d.length) topEnd = d.length;

    // Pool table: byte offsets of each wave, relative to the wave-pool start.
    uint[] poolOffsets;
    size_t pb;
    uint ps;
    if (findChunk(d, 12, topEnd, "ptbl", pb, ps))
    {
        uint count = u32(d, pb + 4);
        if (pb + 8 + cast(size_t) count * 4 <= d.length)
            foreach (i; 0 .. count) poolOffsets ~= u32(d, pb + 8 + i * 4);
    }

    Span wvpl;
    bool haveWvpl = findList(d, 12, topEnd, "wvpl", wvpl);
    if (haveWvpl)
    {
        result.waves.length = poolOffsets.length;
        foreach (i, off; poolOffsets)
        {
            size_t w = wvpl.start + off;
            if (w + 12 > wvpl.end) continue;
            size_t sub = w + 12; // skip "LIST" + size + "wave"
            size_t fb;
            uint fs;
            if (!findChunk(d, sub, w + 8 + u32(d, w + 4), "fmt ", fb, fs))
                continue;
            int channels = u16(d, fb + 2);
            int rate = cast(int) u32(d, fb + 4);
            int bits = u16(d, fb + 14);
            size_t db;
            uint ds;
            if (!findChunk(d, sub, w + 8 + u32(d, w + 4), "data", db, ds))
                continue;
            DlsWave wave;
            wave.sampleRate = rate > 0 ? rate : 22050;
            if (channels <= 0) continue;
            if (bits == 16)
            {
                size_t frames = ds / 2 / channels;
                wave.pcm.length = frames;
                foreach (f; 0 .. frames)
                    wave.pcm[f] = i16(d, db + f * 2 * channels);
            }
            else if (bits == 8)
            {
                size_t frames = ds / channels;
                wave.pcm.length = frames;
                foreach (f; 0 .. frames)
                    wave.pcm[f] = cast(short)((cast(int) d[db + f * channels] - 128) * 256);
            }
            else
            {
                continue;
            }
            result.waves[i] = wave;
        }
    }

    // Instruments.
    Span lins;
    if (!findList(d, 12, topEnd, "lins", lins))
        return result;

    size_t p = lins.start;
    while (p + 12 <= lins.end)
    {
        uint sz = u32(d, p + 4);
        if (id(d, p) == "LIST" && id(d, p + 8) == "ins ")
        {
            size_t insStart = p + 12;
            size_t insEnd = p + 8 + sz;
            size_t b;
            uint s;
            DlsInstrument ins;
            if (findChunk(d, insStart, insEnd, "insh", b, s))
            {
                ins.selector = u32(d, b + 4);
                ins.program = cast(int) u32(d, b + 8);
                ins.drum = (ins.selector & 0x8000_0000) != 0;
            }
            Span lrgn;
            if (findList(d, insStart, insEnd, "lrgn", lrgn))
            {
                size_t r = lrgn.start;
                while (r + 12 <= lrgn.end)
                {
                    uint rsz = u32(d, r + 4);
                    if (id(d, r) == "LIST" && id(d, r + 8) == "rgn ")
                    {
                        size_t rStart = r + 12;
                        size_t rEnd = r + 8 + rsz;
                        DlsRegion reg;
                        size_t rb;
                        uint rs;
                        if (findChunk(d, rStart, rEnd, "rgnh", rb, rs))
                        {
                            reg.keyLow = u16(d, rb);
                            reg.keyHigh = u16(d, rb + 2);
                            reg.velLow = u16(d, rb + 4);
                            reg.velHigh = u16(d, rb + 6);
                        }
                        if (findChunk(d, rStart, rEnd, "wsmp", rb, rs))
                        {
                            reg.rootKey = u16(d, rb + 4);
                            reg.fineCents = i16(d, rb + 6);
                            if (u32(d, rb + 16) > 0)
                            {
                                reg.loopStart = cast(int) u32(d, rb + 28);
                                reg.loopLength = cast(int) u32(d, rb + 32);
                            }
                        }
                        if (findChunk(d, rStart, rEnd, "wlnk", rb, rs))
                            reg.waveIndex = cast(int) u32(d, rb + 8);
                        ins.regions ~= reg;
                    }
                    r = r + 8 + rsz + (rsz & 1);
                }
            }
            result.instruments ~= ins;
        }
        p = p + 8 + sz + (sz & 1);
    }

    return result;
}

/// Load and parse a DLS file. Returns an empty `Dls` if the file is missing.
Dls loadDlsFile(string path)
{
    if (!exists(path)) return Dls.init;
    try
        return parseDls(cast(const(ubyte)[]) read(path));
    catch (Exception)
        return Dls.init;
}

/// The default General MIDI bank path on this platform, or "" if unknown.
string defaultDlsPath()
{
    version (Windows)
    {
        return "C:\\Windows\\System32\\drivers\\gm.dls";
    }
    else version (OSX)
    {
        return "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls";
    }
    else
    {
        return "";
    }
}
