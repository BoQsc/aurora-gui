/// Small DSP primitives shared by the Aurora Music instruments.
module auroramusic.dsp;

import std.math : PI, cos, exp, fabs, pow, sin, sqrt;

/// Mastering/output sample rate for every synth voice and the WAV writer.
enum int SAMPLE_RATE = 44100;

/// Equal-tempered MIDI note number to frequency in Hz (A4 = note 69 = 440 Hz).
double midiToFreq(double midi)
{
    return 440.0 * pow(2.0, (midi - 69.0) / 12.0);
}

/// Decibels to linear gain.
double dbToGain(double db)
{
    return pow(10.0, db / 20.0);
}

/// Clamp a value to the inclusive [lo, hi] range.
double clampd(double value, double lo, double hi)
{
    if (value < lo) return lo;
    if (value > hi) return hi;
    return value;
}

/// Deterministic xorshift64* generator so every render is reproducible.
struct Rng
{
    ulong state;

    this(ulong seed)
    {
        state = seed != 0 ? seed : 0x9E37_79B9_7F4A_7C15UL;
    }

    /// Uniform in [0, 1).
    double next01()
    {
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        ulong r = state * 2685_8216_5773_6387UL;
        return (r >> 11) * (1.0 / 9007_1992_5474_0992.0);
    }

    /// Uniform white noise in [-1, 1).
    double noise()
    {
        return next01() * 2.0 - 1.0;
    }
}

/// Direct-form-I biquad using the RBJ audio-EQ cookbook coefficients.
struct Biquad
{
    double b0, b1, b2, a1, a2;
    double x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0;

    static Biquad lowpass(double sr, double f, double q)
    {
        Biquad b;
        double w0 = 2.0 * PI * f / sr;
        double cw = cos(w0), sw = sin(w0);
        double alpha = sw / (2.0 * q);
        double a0 = 1.0 + alpha;
        b.b0 = (1.0 - cw) / 2.0 / a0;
        b.b1 = (1.0 - cw) / a0;
        b.b2 = b.b0;
        b.a1 = (-2.0 * cw) / a0;
        b.a2 = (1.0 - alpha) / a0;
        return b;
    }

    static Biquad highpass(double sr, double f, double q)
    {
        Biquad b;
        double w0 = 2.0 * PI * f / sr;
        double cw = cos(w0), sw = sin(w0);
        double alpha = sw / (2.0 * q);
        double a0 = 1.0 + alpha;
        b.b0 = (1.0 + cw) / 2.0 / a0;
        b.b1 = -(1.0 + cw) / a0;
        b.b2 = b.b0;
        b.a1 = (-2.0 * cw) / a0;
        b.a2 = (1.0 - alpha) / a0;
        return b;
    }

    static Biquad bandpass(double sr, double f, double q)
    {
        Biquad b;
        double w0 = 2.0 * PI * f / sr;
        double cw = cos(w0), sw = sin(w0);
        double alpha = sw / (2.0 * q);
        double a0 = 1.0 + alpha;
        b.b0 = alpha / a0;
        b.b1 = 0.0;
        b.b2 = -alpha / a0;
        b.a1 = (-2.0 * cw) / a0;
        b.a2 = (1.0 - alpha) / a0;
        return b;
    }

    static Biquad peaking(double sr, double f, double q, double gainDb)
    {
        Biquad b;
        double A = pow(10.0, gainDb / 40.0);
        double w0 = 2.0 * PI * f / sr;
        double cw = cos(w0), sw = sin(w0);
        double alpha = sw / (2.0 * q);
        double a0 = 1.0 + alpha / A;
        b.b0 = (1.0 + alpha * A) / a0;
        b.b1 = (-2.0 * cw) / a0;
        b.b2 = (1.0 - alpha * A) / a0;
        b.a1 = (-2.0 * cw) / a0;
        b.a2 = (1.0 - alpha / A) / a0;
        return b;
    }

    double process(double x)
    {
        double y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1;
        x1 = x;
        y2 = y1;
        y1 = y;
        return y;
    }
}
