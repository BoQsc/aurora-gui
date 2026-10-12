/// Sample-based instrument playback from a DLS bank.
///
/// This is what makes the guitar (and the rest) sound like a real recording:
/// instead of synthesizing a string, it plays the recorded GM samples, picking
/// the region that covers the note and looping/pitching it to the right key.
module auroramusic.sampler;

import auroramusic.dls : Dls, DlsInstrument, DlsRegion, DlsWave;
import auroramusic.dsp : SAMPLE_RATE, clampd;
import auroramusic.instruments : DrumType;
import auroramusic.mix : Mix;
import std.math : exp, floor, pow;

/// General MIDI drum note numbers for our drum voices.
int drumToGm(DrumType drum)
{
    final switch (drum)
    {
        case DrumType.kick: return 36;
        case DrumType.snare: return 38;
        case DrumType.hat: return 42;
        case DrumType.ohat: return 46;
        case DrumType.clap: return 39;
        case DrumType.tom: return 45;
        case DrumType.crash: return 49;
    }
}

private const(DlsRegion)* pickRegion(const(Dls) dls, int instIndex, int note,
    int velMidi)
{
    if (instIndex < 0 || instIndex >= cast(int) dls.instruments.length)
        return null;
    const(DlsInstrument)* ins = &dls.instruments[instIndex];
    const(DlsRegion)* pick = null;
    int pickSpan = int.max;
    bool pickVel = false;
    foreach (ref reg; ins.regions)
    {
        if (note < reg.keyLow || note > reg.keyHigh) continue;
        bool velMatch = velMidi >= reg.velLow && velMidi <= reg.velHigh;
        int span = reg.keyHigh - reg.keyLow;
        bool better = pick is null
            || (velMatch && !pickVel)
            || (velMatch == pickVel && span < pickSpan);
        if (better)
        {
            pick = &reg;
            pickSpan = span;
            pickVel = velMatch;
        }
    }
    return pick;
}

/// Render one sampled note. `decayTau` shapes how the sustained loop fades
/// (<= 0 means play the sample once, one-shot, as for drums).
void renderSampled(Mix mix, size_t start, int note, double vel, double durSec,
    double gl, double gr, double rev, const(Dls) dls, int instIndex,
    double decayTau, double gain)
{
    if (instIndex < 0) return;
    int velMidi = cast(int)(clampd(vel, 0.0, 1.0) * 127.0);
    const(DlsRegion)* reg = pickRegion(dls, instIndex, note, velMidi);
    if (reg is null) return;
    if (reg.waveIndex < 0 || reg.waveIndex >= cast(int) dls.waves.length) return;
    const(DlsWave)* wave = &dls.waves[reg.waveIndex];
    if (wave.pcm.length < 4) return;

    double ratio = (cast(double) wave.sampleRate / SAMPLE_RATE) *
        pow(2.0, (note - reg.rootKey + reg.fineCents / 100.0) / 12.0);
    if (ratio <= 0.0) return;

    bool looped = reg.loopLength > 8 && reg.loopStart >= 0 &&
        (reg.loopStart + reg.loopLength) <= cast(int) wave.pcm.length;
    double loopStart = cast(double) reg.loopStart;
    double loopLen = cast(double) reg.loopLength;

    int last = cast(int) wave.pcm.length - 1;
    double maxRing = 6.0;
    double fade = 0.30;

    double ringSec = looped
        ? (decayTau > 0.0 ? durSec + 3.0 * decayTau : durSec + 0.5)
        : (durSec + 0.5);
    if (ringSec > maxRing) ringSec = maxRing;
    if (ringSec < 0.05) ringSec = 0.05;
    size_t total = cast(size_t)(ringSec * SAMPLE_RATE);

    double attack = 0.004 * SAMPLE_RATE;
    double amp = gain * vel;
    double pos = 0.0;

    foreach (i; 0 .. total)
    {
        int i0 = cast(int) floor(pos);
        if (i0 < 0) i0 = 0;
        if (i0 > last) i0 = last;
        int i1 = i0 + 1;
        if (i1 > last) i1 = looped ? cast(int) loopStart : last;
        double frac = pos - floor(pos);
        double s = (wave.pcm[i0] + (wave.pcm[i1] - wave.pcm[i0]) * frac) / 32768.0;

        double t = cast(double) i / SAMPLE_RATE;
        double env = i < attack ? i / attack : 1.0;
        if (looped)
        {
            if (decayTau > 0.0) env *= exp(-t / decayTau);
            double remain = ringSec - t;
            if (remain < fade) env *= remain / fade;
        }
        else
        {
            double remain = ringSec - t;
            if (remain < fade) env *= remain / fade;
        }

        double outv = s * amp * env;
        mix.add(start + i, outv * gl, outv * gr, rev);

        pos += ratio;
        if (looped)
        {
            double span = loopStart + loopLen;
            while (pos >= span) pos -= loopLen;
        }
        else if (pos > last)
        {
            break;
        }
    }
}
