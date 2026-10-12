/// Self-contained verification of the synth engine: tuning, non-silence and
/// headroom are checked from the rendered samples themselves.
module auroramusic.selftest;

import auroramusic.demo : buildDemo;
import auroramusic.dsp : SAMPLE_RATE, midiToFreq;
import auroramusic.instruments : DrumType;
import auroramusic.song : Inst, Song, addDrum, addNote, renderSong;
import std.math : fabs, sqrt;
import std.stdio : writeln;

private int failures;

private void check(bool condition, string label, string detail)
{
    if (condition)
    {
        writeln("  ok   ", label);
    }
    else
    {
        writeln("  FAIL ", label, " : ", detail);
        failures++;
    }
}

/// Left-channel pitch estimate using normalized autocorrelation.
private double dominantFreq(const(float)[] inter)
{
    size_t frames = inter.length / 2;
    size_t window = 8192;
    if (frames < window) window = frames / 2;
    size_t start = cast(size_t)(0.15 * SAMPLE_RATE);
    if (start + window > frames) start = 0;

    double[] x = new double[window];
    foreach (i; 0 .. window) x[i] = inter[(start + i) * 2];

    size_t minLag = SAMPLE_RATE / 1200;
    size_t maxLag = SAMPLE_RATE / 40;
    size_t n = 4096;
    if (window < n + maxLag) n = window - maxLag;

    double[] r = new double[maxLag + 1];
    foreach (lag; minLag .. maxLag + 1)
    {
        double sxy = 0.0, sxx = 0.0, syy = 0.0;
        foreach (i; 0 .. n)
        {
            double a = x[i];
            double b = x[i + lag];
            sxy += a * b;
            sxx += a * a;
            syy += b * b;
        }
        r[lag] = (sxx > 0.0 && syy > 0.0) ? sxy / sqrt(sxx * syy) : 0.0;
    }

    double best = 0.0;
    foreach (lag; minLag .. maxLag + 1)
        if (r[lag] > best) best = r[lag];
    if (best <= 0.0) return 0.0;

    // Take the first prominent local maximum (the fundamental period), then
    // refine it with parabolic interpolation so the estimate is not biased
    // toward the leading shoulder of the correlation peak.
    double period = 0.0;
    foreach (lag; minLag + 1 .. maxLag)
    {
        if (r[lag] < 0.6 * best) continue;
        if (!(r[lag] > r[lag - 1] && r[lag] >= r[lag + 1])) continue;
        double denom = r[lag - 1] - 2.0 * r[lag] + r[lag + 1];
        double delta = denom != 0.0
            ? 0.5 * (r[lag - 1] - r[lag + 1]) / denom : 0.0;
        period = lag + delta;
        break;
    }
    if (period <= 0.0) return 0.0;
    return cast(double) SAMPLE_RATE / period;
}

private float[] renderSingle(Inst inst, int midi, double vel)
{
    Song song;
    song.tempo = 60.0;
    song.tailSec = 0.5;
    song.addTrack(inst, "test", 0.0, 0.0, 0.0);
    addNote(song.tracks[0], 0.0, midi, vel, 1.0);
    return renderSong(song, 0.0, 0.0);
}

private float[] renderSingleDrum(DrumType type)
{
    Song song;
    song.tempo = 60.0;
    song.tailSec = 0.5;
    song.addTrack(Inst.drums, "test", 0.0, 0.0, 0.0);
    addDrum(song.tracks[0], 0.0, type, 0.9);
    return renderSong(song, 0.0, 0.0);
}

private void checkTuning(Inst inst, int midi, string label)
{
    auto samples = renderSingle(inst, midi, 0.9);
    double expected = midiToFreq(midi);
    double detected = dominantFreq(samples);
    double error = expected > 0.0 && detected > 0.0
        ? fabs(detected - expected) / expected : 1.0;
    import std.format : format;
    string detail = format("expected %.1f Hz, detected %.1f Hz (%.2f%%)",
        expected, detected, error * 100.0);
    check(detected > 0.0 && error < 0.04, label, detail);
}

private void checkNonSilent(const(float)[] samples, string label)
{
    double peak = 0.0, energy = 0.0;
    foreach (v; samples)
    {
        double a = fabs(v);
        if (a > peak) peak = a;
        energy += v * v;
    }
    double rms = samples.length > 0 ? sqrt(energy / samples.length) : 0.0;
    bool finite = (rms == rms) && (peak == peak);
    import std.format : format;
    string detail = format("rms=%.4f peak=%.3f", rms, peak);
    check(finite && rms > 1.0e-4 && peak <= 1.0, label, detail);
}

/// Run the full self-test. Returns true when everything passed.
bool runSelfTest()
{
    failures = 0;
    writeln("Aurora Music self-test");

    writeln("Tuning (autocorrelation of the rendered samples):");
    checkTuning(Inst.piano, 69, "piano A4 (440 Hz)");
    checkTuning(Inst.piano, 60, "piano C4 (261.6 Hz)");
    checkTuning(Inst.guitar, 64, "guitar E4 (329.6 Hz)");
    checkTuning(Inst.guitar, 40, "guitar E2 (82.4 Hz)");
    checkTuning(Inst.nylon, 62, "nylon D4 (293.7 Hz)");
    checkTuning(Inst.bass, 45, "bass A2 (110 Hz)");
    checkTuning(Inst.bass, 33, "bass A1 (55 Hz)");
    checkTuning(Inst.pad, 57, "pad A3 (220 Hz)");

    writeln("Drum voices (non-silent, no clipping):");
    checkNonSilent(renderSingleDrum(DrumType.kick), "kick");
    checkNonSilent(renderSingleDrum(DrumType.snare), "snare");
    checkNonSilent(renderSingleDrum(DrumType.hat), "hat");
    checkNonSilent(renderSingleDrum(DrumType.ohat), "ohat");
    checkNonSilent(renderSingleDrum(DrumType.clap), "clap");
    checkNonSilent(renderSingleDrum(DrumType.tom), "tom");
    checkNonSilent(renderSingleDrum(DrumType.crash), "crash");

    writeln("Full demo arrangement:");
    checkNonSilent(renderSong(buildDemo()), "demo mix");
    writeln(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED");
    return failures == 0;
}
