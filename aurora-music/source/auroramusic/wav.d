/// Minimal 16-bit PCM stereo WAV writer.
module auroramusic.wav;

import std.file : write;
import std.math : round;

private void putTag(ref ubyte[] buf, string tag)
{
    foreach (ch; tag) buf ~= cast(ubyte) ch;
}

private void putU16(ref ubyte[] buf, ushort v)
{
    buf ~= cast(ubyte)(v & 0xFF);
    buf ~= cast(ubyte)((v >> 8) & 0xFF);
}

private void putU32(ref ubyte[] buf, uint v)
{
    buf ~= cast(ubyte)(v & 0xFF);
    buf ~= cast(ubyte)((v >> 8) & 0xFF);
    buf ~= cast(ubyte)((v >> 16) & 0xFF);
    buf ~= cast(ubyte)((v >> 24) & 0xFF);
}

/// Write interleaved stereo floats in [-1, 1] as a 16-bit PCM WAV file.
void writeWav16(string path, const(float)[] interleaved, int sampleRate)
{
    size_t frames = interleaved.length / 2;
    uint dataBytes = cast(uint)(frames * 4);

    ubyte[] outb;
    outb.reserve(44 + dataBytes);

    putTag(outb, "RIFF");
    putU32(outb, 36 + dataBytes);
    putTag(outb, "WAVE");
    putTag(outb, "fmt ");
    putU32(outb, 16);                       // PCM chunk size
    putU16(outb, 1);                        // PCM
    putU16(outb, 2);                        // channels
    putU32(outb, cast(uint) sampleRate);
    putU32(outb, cast(uint)(sampleRate * 4));
    putU16(outb, 4);                        // block align
    putU16(outb, 16);                       // bits per sample
    putTag(outb, "data");
    putU32(outb, dataBytes);

    foreach (i; 0 .. frames)
    {
        foreach (c; 0 .. 2)
        {
            double v = interleaved[i * 2 + c];
            if (v > 1.0) v = 1.0;
            else if (v < -1.0) v = -1.0;
            short s = cast(short) round(v * 32767.0);
            outb ~= cast(ubyte)(s & 0xFF);
            outb ~= cast(ubyte)((s >> 8) & 0xFF);
        }
    }

    write(path, outb);
}
