/// The Aurora Music instruments: additive piano, physically modelled plucked
/// strings with a full acoustic body, a subtractive pad, and synthesized drums.
///
/// Every voice is written directly into a shared `Mix` bus at a sample offset,
/// so voices simply overlap in time.
module auroramusic.instruments;

import auroramusic.dsp : Biquad, Rng, SAMPLE_RATE, clampd;
import auroramusic.mix : Mix;
import std.math : PI, cos, exp, fabs, floor, pow, sin, sqrt;

/// Drum voice identifiers (used as the "pitch" of a drum-track event).
enum DrumType
{
    kick,
    snare,
    hat,
    ohat,
    clap,
    tom,
    crash,
}

/// Plucked-string flavours.
enum GuitarKind
{
    steel,
    nylon,
    bass,
}

private struct PluckPreset
{
    double excitationLpHz; // pick-noise brightness ceiling
    double loopBright;     // one-pole loop cut: higher = darker decay
    double decay;          // overall loop gain (sustain)
    double ringSec;        // extra ring added to the note duration
    double maxRing;        // hard cap on ring time
    double detune;         // second string detune ratio (0 = single tracked)
    int bodyKind;          // 0 none, 1 steel, 2 nylon, 3 bass
}

private PluckPreset presetFor(GuitarKind kind)
{
    final switch (kind)
    {
        case GuitarKind.steel:
            return PluckPreset(6000.0, 0.55, 0.9972, 2.2, 8.0, 0.0, 1);
        case GuitarKind.nylon:
            return PluckPreset(3200.0, 0.36, 0.9958, 2.0, 7.0, 0.0, 2);
        case GuitarKind.bass:
            return PluckPreset(2200.0, 0.45, 0.9984, 1.8, 9.0, 0.0, 3);
    }
}

private Biquad[] bodyFor(int kind)
{
    Biquad[] eq;
    switch (kind)
    {
        case 1: // steel acoustic
            eq ~= Biquad.highpass(SAMPLE_RATE, 75.0, 0.7);
            eq ~= Biquad.peaking(SAMPLE_RATE, 100.0, 1.6, 3.0);
            eq ~= Biquad.peaking(SAMPLE_RATE, 210.0, 1.3, 2.5);
            eq ~= Biquad.peaking(SAMPLE_RATE, 430.0, 1.2, 1.5);
            eq ~= Biquad.peaking(SAMPLE_RATE, 620.0, 1.6, -2.0);
            eq ~= Biquad.lowpass(SAMPLE_RATE, 7000.0, 0.7);
            break;
        case 2: // nylon
            eq ~= Biquad.highpass(SAMPLE_RATE, 70.0, 0.7);
            eq ~= Biquad.peaking(SAMPLE_RATE, 100.0, 1.5, 2.5);
            eq ~= Biquad.peaking(SAMPLE_RATE, 200.0, 1.3, 2.0);
            eq ~= Biquad.peaking(SAMPLE_RATE, 560.0, 1.4, -1.5);
            eq ~= Biquad.lowpass(SAMPLE_RATE, 4600.0, 0.7);
            break;
        case 3: // electric bass cabinet
            eq ~= Biquad.highpass(SAMPLE_RATE, 40.0, 0.7);
            eq ~= Biquad.peaking(SAMPLE_RATE, 95.0, 1.2, 2.5);
            eq ~= Biquad.lowpass(SAMPLE_RATE, 2800.0, 0.7);
            break;
        default:
            break;
    }
    return eq;
}

/// Render one plucked string (mono) into a freshly allocated buffer.
///
/// Excitation is band-limited noise shaped by a pick-position comb; the loop is
/// a one-pole lowpass (so high partials decay faster than low ones, as on a
/// real string) fed by a fractional-delay allpass for correct tuning.
private double[] pluckSamples(double freq, double vel, double ringSec,
    GuitarKind kind, ref Rng rng)
{
    PluckPreset p = presetFor(kind);

    double delay = SAMPLE_RATE / freq;
    int n = cast(int) floor(delay);
    if (n < 2) n = 2;
    double frac = delay - n;
    double allpassCoef = (1.0 - frac) / (1.0 + frac);
    int len = n + 1;

    // Excitation: noise concentrated on the low partials so the fundamental
    // dominates (a full-band hiss reads as "buzz", not wood and steel).
    double excLp = clampd(freq * 4.0 + 400.0, 500.0, p.excitationLpHz);
    double excHp = clampd(freq * 0.75, 40.0, 400.0);
    Biquad lp = Biquad.lowpass(SAMPLE_RATE, excLp, 0.8);
    Biquad hp = Biquad.highpass(SAMPLE_RATE, excHp, 0.7);

    double[] buf = new double[len];
    buf[] = 0.0;
    double[] raw = new double[len];
    foreach (i; 0 .. len) raw[i] = lp.process(hp.process(rng.noise()));

    // Pick-position comb: a short delay subtracted from the burst.
    int pick = cast(int)(len * (0.1 + 0.2 * rng.next01()));
    if (pick > 0 && pick < len)
    {
        double[] tmp = raw.dup;
        foreach (i; 0 .. len)
        {
            int j = i - pick;
            if (j < 0) j += len;
            raw[i] = tmp[i] - 0.55 * tmp[j];
        }
    }

    double peak = 1.0e-9;
    foreach (v; raw)
        if (fabs(v) > peak) peak = fabs(v);
    double gain = (0.9 * vel) / peak;
    foreach (i; 0 .. len) buf[i] = raw[i] * gain;

    int total = cast(int)(clampd(ringSec + p.ringSec, 0.5, p.maxRing) * SAMPLE_RATE);
    if (total < 8) total = 8;

    double[] outv = new double[total];
    outv[] = 0.0;

    size_t idx = 0;
    double ylp = 0.0;
    double apX1 = 0.0;
    double apY1 = 0.0;

    foreach (step; 0 .. total)
    {
        double s = buf[idx];
        ylp += p.loopBright * (s - ylp);
        double ap = allpassCoef * ylp + apX1 - allpassCoef * apY1;
        apX1 = ylp;
        apY1 = ap;
        buf[idx] = ap * p.decay;
        idx = (idx + 1) % len;
        outv[step] = s;
    }
    return outv;
}

/// Plucked-string voice with acoustic body colouring and a real pick transient.
void renderGuitar(Mix mix, size_t start, double freq, double vel, double durSec,
    double gl, double gr, double rev, GuitarKind kind, ref Rng rng)
{
    if (freq < 25.0 || freq > 5000.0) return;

    PluckPreset p = presetFor(kind);

    // A bright, very short pick click that gives the attack its "plucked"
    // character before the string tone takes over.
    int pickN = cast(int)(0.006 * SAMPLE_RATE);
    Biquad pickHp = Biquad.highpass(SAMPLE_RATE, 1500.0, 0.7);
    foreach (n; 0 .. pickN)
    {
        double t = cast(double) n / SAMPLE_RATE;
        double e = exp(-t / 0.0018);
        double s = pickHp.process(rng.noise()) * e * 0.5 * vel;
        mix.add(start + n, s * gl, s * gr, rev);
    }

    double[] mono = pluckSamples(freq, vel, durSec, kind, rng);
    Biquad[] eq = bodyFor(p.bodyKind);
    foreach (step, v; mono)
    {
        double outv = v;
        foreach (ref f; eq) outv = f.process(outv);
        mix.add(start + step, outv * gl, outv * gr, rev);
    }
}

/// Subtractive pad: three detuned saws through a slowly opening lowpass with a
/// soft attack and release, spread across the stereo field. Fills the mids.
void renderPad(Mix mix, size_t start, double freq, double vel, double durSec,
    double gl, double gr, double rev, ref Rng rng)
{
    int total = cast(int)((durSec + 0.9) * SAMPLE_RATE);
    if (total < 8) return;

    immutable double[] detune = [-0.006, 0.004, 0.010];
    immutable double[] voicePan = [0.75, 0.5, 0.85]; // L, centre, R

    double[3] phase;
    phase[] = 0.0;
    foreach (i; 0 .. 3) phase[i] = rng.next01() * 2.0 * PI;

    double attack = 0.35 * SAMPLE_RATE;
    double releaseStart = durSec * SAMPLE_RATE;
    double release = 0.8 * SAMPLE_RATE;

    double lpL = 0.0;
    double lpR = 0.0;
    double gain = 0.16 * vel;

    foreach (step; 0 .. total)
    {
        double amp = step < attack ? step / attack : 1.0;
        if (step > releaseStart)
            amp *= exp(-(step - releaseStart) / release);

        double sumL = 0.0, sumR = 0.0;
        foreach (i; 0 .. 3)
        {
            phase[i] += 2.0 * PI * freq * (1.0 + detune[i]) / SAMPLE_RATE;
            if (phase[i] > 2.0 * PI) phase[i] -= 2.0 * PI;
            double saw = 2.0 * (phase[i] / (2.0 * PI)) - 1.0;
            sumL += saw * voicePan[i];
            sumR += saw * (1.0 - voicePan[i] + 0.2);
        }

        // Lowpass that opens with the envelope, then closes slightly.
        double cut = 350.0 + 2400.0 * amp;
        cut = clampd(cut, 250.0, 7000.0);
        double coef = 1.0 - exp(-2.0 * PI * cut / SAMPLE_RATE);
        lpL += coef * (sumL - lpL);
        lpR += coef * (sumR - lpR);

        double oL = lpL * gain * (0.9 + 0.1 * amp);
        double oR = lpR * gain * (0.9 + 0.1 * amp);
        mix.add(start + step, oL * gl, oR * gr, rev);
    }
}

/// Additive piano-like voice.
void renderPiano(Mix mix, size_t start, double freq, double vel, double ringSec,
    double gl, double gr, double rev, ref Rng rng)
{
    if (freq < 20.0 || freq > 6000.0) return;

    immutable double inharmonicity = 0.00035;
    immutable int maxPartials = 18;
    immutable double nyquist = SAMPLE_RATE * 0.5;

    double tauBase = clampd(5.0 * pow(220.0 / freq, 0.5), 0.7, 9.0);

    int total = cast(int)(ringSec * SAMPLE_RATE);
    if (total < 16) total = 16;
    immutable int maxTotal = cast(int)(9.0 * SAMPLE_RATE);
    if (total > maxTotal) total = maxTotal;

    Biquad hammer = Biquad.lowpass(SAMPLE_RATE, 1200.0 + 2600.0 * vel, 0.7);
    int hammerN = cast(int)(0.012 * SAMPLE_RATE);
    foreach (n; 0 .. hammerN)
    {
        double t = cast(double) n / SAMPLE_RATE;
        double e = exp(-t / 0.004);
        double s = hammer.process(rng.noise()) * e * 0.05 * vel;
        mix.add(start + n, s * gl, s * gr, rev);
    }

    immutable double attackSamples = 0.004 * SAMPLE_RATE;

    foreach (k; 1 .. maxPartials + 1)
    {
        double fk = freq * k * sqrt(1.0 + inharmonicity * k * k);
        if (fk > nyquist * 0.95) break;

        double ampk = 1.0 / pow(cast(double) k, 1.5);
        ampk *= exp(-0.055 * (k - 1));
        ampk *= pow(0.55 + 0.45 * vel, cast(double)(k - 1));
        if (ampk < 1.0e-4) break;

        double tauK = tauBase / (1.0 + 0.35 * (k - 1));
        double decay = exp(-1.0 / (tauK * SAMPLE_RATE));
        double dphi = 2.0 * PI * fk / SAMPLE_RATE;
        double c = cos(dphi);
        double s = sin(dphi);

        double phase = rng.next01() * 2.0 * PI;
        double re = cos(phase);
        double im = sin(phase);

        double spread = 0.0;
        if (k > 2)
            spread = 0.16 * ((k % 2 == 0) ? 1.0 : -1.0);
        double pl = gl * (1.0 - spread);
        double pr = gr * (1.0 + spread);

        double env = ampk;
        foreach (n; 0 .. total)
        {
            double at = n < attackSamples ? n / attackSamples : 1.0;
            double val = env * at * im;
            mix.add(start + n, val * pl, val * pr, rev);

            double nre = re * c - im * s;
            double nim = re * s + im * c;
            re = nre;
            im = nim;
            env *= decay;
        }
    }
}

/// Synthesized drum voices.
void renderDrum(Mix mix, size_t start, DrumType type, double vel,
    double gl, double gr, double rev, ref Rng rng)
{
    final switch (type)
    {
        case DrumType.kick:
            drumMembrane(mix, start, vel, gl, gr, rev, rng,
                145.0, 47.0, 0.035, 0.16, 0.42, 0.9);
            break;
        case DrumType.tom:
            drumMembrane(mix, start, vel, gl, gr, rev, rng,
                280.0, 120.0, 0.07, 0.24, 0.30, 0.75);
            break;
        case DrumType.snare:
            drumSnare(mix, start, vel, gl, gr, rev, rng);
            break;
        case DrumType.hat:
            drumHat(mix, start, vel, gl, gr, rev, rng, 0.05);
            break;
        case DrumType.ohat:
            drumHat(mix, start, vel, gl, gr, rev, rng, 0.30);
            break;
        case DrumType.clap:
            drumClap(mix, start, vel, gl, gr, rev, rng);
            break;
        case DrumType.crash:
            drumCrash(mix, start, vel, gl, gr, rev, rng);
            break;
    }
}

private void drumMembrane(Mix mix, size_t start, double vel, double gl, double gr,
    double rev, ref Rng rng, double fStart, double fEnd, double pitchTau,
    double ampTau, double clickGain, double gain)
{
    int total = cast(int)((ampTau * 6.0) * SAMPLE_RATE);
    double phase = 0.0;
    double g = gain * vel;
    foreach (n; 0 .. total)
    {
        double t = cast(double) n / SAMPLE_RATE;
        double f = fEnd + (fStart - fEnd) * exp(-t / pitchTau);
        phase += 2.0 * PI * f / SAMPLE_RATE;
        double amp = exp(-t / ampTau);
        double body = sin(phase) * amp;
        double click = rng.noise() * exp(-t / 0.004) * clickGain;
        double v = (body + click) * g;
        mix.add(start + n, v * gl, v * gr, rev);
    }
}

private void drumSnare(Mix mix, size_t start, double vel, double gl, double gr,
    double rev, ref Rng rng)
{
    int total = cast(int)(0.35 * SAMPLE_RATE);
    Biquad hp = Biquad.highpass(SAMPLE_RATE, 700.0, 0.7);
    Biquad bp = Biquad.bandpass(SAMPLE_RATE, 1900.0, 0.6);
    double g = 0.7 * vel;
    foreach (n; 0 .. total)
    {
        double t = cast(double) n / SAMPLE_RATE;
        double tone = (sin(2.0 * PI * 185.0 * t) * 0.5 +
            sin(2.0 * PI * 330.0 * t) * 0.28) * exp(-t / 0.055);
        double nf = bp.process(hp.process(rng.noise())) * exp(-t / 0.13);
        double v = (tone * 0.5 + nf * 0.95) * g;
        mix.add(start + n, v * gl, v * gr, rev);
    }
}

private void drumHat(Mix mix, size_t start, double vel, double gl, double gr,
    double rev, ref Rng rng, double decayTau)
{
    int total = cast(int)((decayTau * 6.0 + 0.02) * SAMPLE_RATE);
    Biquad hp = Biquad.highpass(SAMPLE_RATE, 8000.0, 0.8);
    immutable double base = 320.0;
    immutable double[] ratios = [2.0, 3.0, 4.16, 5.43, 6.79, 8.21];
    double[6] phase;
    phase[] = 0.0;
    double g = 0.5 * vel;
    foreach (n; 0 .. total)
    {
        double t = cast(double) n / SAMPLE_RATE;
        double metallic = 0.0;
        foreach (i; 0 .. 6)
        {
            phase[i] += 2.0 * PI * base * ratios[i] / SAMPLE_RATE;
            metallic += sin(phase[i]) >= 0.0 ? 1.0 : -1.0;
        }
        metallic /= 6.0;
        double s = hp.process(metallic * 0.75 + rng.noise() * 0.25);
        s *= exp(-t / decayTau);
        double v = s * g;
        mix.add(start + n, v * gl, v * gr, rev);
    }
}

private void drumClap(Mix mix, size_t start, double vel, double gl, double gr,
    double rev, ref Rng rng)
{
    int total = cast(int)(0.35 * SAMPLE_RATE);
    Biquad bp = Biquad.bandpass(SAMPLE_RATE, 1100.0, 0.9);
    immutable double[] bursts = [0.0, 0.011, 0.022, 0.033];
    double g = 0.55 * vel;
    foreach (n; 0 .. total)
    {
        double t = cast(double) n / SAMPLE_RATE;
        double env = 0.0;
        foreach (b; bursts)
            if (t >= b) env += exp(-(t - b) / 0.012);
        env += 0.6 * exp(-t / 0.15);
        if (env > 1.4) env = 1.4;
        double s = bp.process(rng.noise()) * env;
        double v = s * g;
        mix.add(start + n, v * gl, v * gr, rev);
    }
}

private void drumCrash(Mix mix, size_t start, double vel, double gl, double gr,
    double rev, ref Rng rng)
{
    int total = cast(int)(1.6 * SAMPLE_RATE);
    Biquad hp = Biquad.highpass(SAMPLE_RATE, 4200.0, 0.6);
    double g = 0.32 * vel;
    foreach (n; 0 .. total)
    {
        double t = cast(double) n / SAMPLE_RATE;
        double s = hp.process(rng.noise()) * exp(-t / 0.9);
        double v = s * g;
        mix.add(start + n, v * gl, v * gr, rev);
    }
}
