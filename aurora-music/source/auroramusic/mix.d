/// Mix bus, reverb send, and a small mastering chain (DC block, air shelf,
/// gentle bus compression, RMS normalization) for the synth engine.
module auroramusic.mix;

import auroramusic.dsp : Biquad, SAMPLE_RATE;
import std.math : exp, fabs, pow, sqrt;

/// A stereo bus with a parallel reverb send. Voices add their output here.
final class Mix
{
    /// Interleaved stereo dry signal (L, R, L, R, ...).
    float[] dry;
    /// Interleaved stereo reverb send.
    float[] send;
    /// Number of stereo frames the bus can hold.
    size_t frames;

    this(double seconds)
    {
        frames = cast(size_t)(seconds * SAMPLE_RATE) + 2;
        dry.length = frames * 2;
        send.length = frames * 2;
        dry[] = 0.0f;   // D initialises floats to NaN, not zero.
        send[] = 0.0f;
    }

    /// Mix one sample frame. `sendAmount` routes a copy to the reverb bus.
    void add(size_t frame, double l, double r, double sendAmount)
    {
        if (frame >= frames) return;
        size_t i = frame * 2;
        dry[i] += cast(float) l;
        dry[i + 1] += cast(float) r;
        send[i] += cast(float)(l * sendAmount);
        send[i + 1] += cast(float)(r * sendAmount);
    }
}

private struct Comb
{
    double[] buf;
    size_t idx;
    double store = 0.0;

    void setup(size_t n)
    {
        buf = new double[n];
        buf[] = 0.0;
    }

    double process(double x, double feedback, double damp)
    {
        double y = buf[idx];
        store = y * (1.0 - damp) + store * damp;
        buf[idx] = x + store * feedback;
        if (++idx >= buf.length) idx = 0;
        return y;
    }
}

private struct Allpass
{
    double[] buf;
    size_t idx;

    void setup(size_t n)
    {
        buf = new double[n];
        buf[] = 0.0;
    }

    double process(double x, double feedback)
    {
        double bufout = buf[idx];
        double y = -x + bufout;
        buf[idx] = x + bufout * feedback;
        if (++idx >= buf.length) idx = 0;
        return y;
    }
}

/// A compact Freeverb-style stereo reverb with a ~25 ms predelay and a low-cut
/// on its input so bass stays tight.
final class Reverb
{
    private Comb[4] combsL;
    private Comb[4] combsR;
    private Allpass[2] apL;
    private Allpass[2] apR;
    private double[] predelayL;
    private double[] predelayR;
    private size_t preIdx;
    private Biquad hpL;
    private Biquad hpR;
    private double feedback;
    private double damp = 0.22;

    this(double room)
    {
        feedback = 0.70 + 0.28 * room;
        immutable int[] combTune = [1116, 1188, 1277, 1356];
        immutable int[] apTune = [556, 441];
        foreach (i; 0 .. 4)
        {
            combsL[i].setup(combTune[i]);
            combsR[i].setup(combTune[i] + 23);
        }
        foreach (i; 0 .. 2)
        {
            apL[i].setup(apTune[i]);
            apR[i].setup(apTune[i] + 23);
        }
        size_t pre = cast(size_t)(0.025 * SAMPLE_RATE);
        predelayL = new double[pre];
        predelayR = new double[pre];
        predelayL[] = 0.0;
        predelayR[] = 0.0;
        hpL = Biquad.highpass(SAMPLE_RATE, 170.0, 0.7);
        hpR = Biquad.highpass(SAMPLE_RATE, 170.0, 0.7);
    }

    void process(double inL, double inR, out double outL, out double outR)
    {
        double pl = predelayL[preIdx];
        predelayL[preIdx] = inL;
        double pr = predelayR[preIdx];
        predelayR[preIdx] = inR;
        if (++preIdx >= predelayL.length) preIdx = 0;

        pl = hpL.process(pl);
        pr = hpR.process(pr);

        double l = 0.0, r = 0.0;
        foreach (i; 0 .. 4)
        {
            l += combsL[i].process(pl, feedback, damp);
            r += combsR[i].process(pr, feedback, damp);
        }
        l *= 0.25;
        r *= 0.25;
        foreach (i; 0 .. 2)
        {
            l = apL[i].process(l, 0.5);
            r = apR[i].process(r, 0.5);
        }
        outL = l;
        outR = r;
    }
}

/// Add the reverb send back into the dry mix, then apply a mastering chain:
/// DC block, an "air" high shelf, gentle bus compression, and finally RMS
/// normalization with a peak ceiling.
float[] finalize(Mix mix, double reverbWet, double room)
{
    size_t n = mix.frames;
    double[] wet = new double[n * 2];
    wet[] = 0.0;
    Reverb reverb = new Reverb(room);

    // DC blocker state.
    double dcxL = 0.0, dcyL = 0.0, dcxR = 0.0, dcyR = 0.0;
    immutable double dcR = 0.9955;

    Biquad airL = Biquad.peaking(SAMPLE_RATE, 9000.0, 0.6, 2.5);
    Biquad airR = Biquad.peaking(SAMPLE_RATE, 9000.0, 0.6, 2.5);

    // Bus compressor setup.
    immutable double attackCoef = 1.0 - exp(-1.0 / (0.010 * SAMPLE_RATE));
    immutable double releaseCoef = 1.0 - exp(-1.0 / (0.150 * SAMPLE_RATE));
    immutable double threshold = 0.25;
    immutable double ratioSlope = 1.0 - 1.0 / 2.5;
    double envF = 0.0;

    foreach (i; 0 .. n)
    {
        double wl, wr;
        reverb.process(mix.send[i * 2], mix.send[i * 2 + 1], wl, wr);

        double xl = mix.dry[i * 2] + wl * reverbWet;
        double xr = mix.dry[i * 2 + 1] + wr * reverbWet;

        // DC block.
        double yl = xl - dcxL + dcR * dcyL;
        dcxL = xl;
        dcyL = yl;
        double yr = xr - dcxR + dcR * dcyR;
        dcxR = xr;
        dcyR = yr;

        // Air shelf.
        yl = airL.process(yl);
        yr = airR.process(yr);

        // Gentle bus compression.
        double det = fabs(yl) > fabs(yr) ? fabs(yl) : fabs(yr);
        double coef = det > envF ? attackCoef : releaseCoef;
        envF += coef * (det - envF);
        if (envF > threshold)
        {
            double g = pow(threshold / envF, ratioSlope);
            yl *= g;
            yr *= g;
        }

        wet[i * 2] = yl;
        wet[i * 2 + 1] = yr;
    }

    double peak = 0.0;
    double energy = 0.0;
    foreach (v; wet)
    {
        double a = fabs(v);
        if (a > peak) peak = a;
        energy += v * v;
    }
    double rms = wet.length > 0 ? sqrt(energy / wet.length) : 0.0;

    double gain = rms > 1.0e-7 ? 0.16 / rms : 1.0;
    if (peak > 0.0)
    {
        double ceiling = 0.945 / peak; // ~ -0.5 dBFS
        if (ceiling < gain) gain = ceiling;
    }

    float[] result = new float[n * 2];
    foreach (i, v; wet)
    {
        double s = v * gain;
        if (s > 1.0) s = 1.0;
        else if (s < -1.0) s = -1.0;
        result[i] = cast(float) s;
    }
    return result;
}
