/// Aurora Music command-line entry point.
module app;

import auroramusic.demo : buildDemo;
import auroramusic.dls : Dls, defaultDlsPath, loadDlsFile;
import auroramusic.dsp : SAMPLE_RATE;
import auroramusic.player : playSamples;
import auroramusic.score : parseScore;
import auroramusic.selftest : runSelfTest;
import auroramusic.song : Song, renderSong;
import auroramusic.wav : writeWav16;
import std.file : exists, readText;
import std.math : fabs, log10, sqrt;
import std.stdio : stderr, writefln, writeln;
import std.string : endsWith, toLower;

private Dls* g_bank;

private double dbfs(double v)
{
    return v > 1.0e-7 ? 20.0 * log10(v) : -120.0;
}

private void reportSamples(const(float)[] samples)
{
    size_t frames = samples.length / 2;
    double peak = 0.0, energy = 0.0;
    size_t clipped = 0;
    foreach (v; samples)
    {
        double a = fabs(v);
        if (a > peak) peak = a;
        energy += v * v;
        if (a >= 0.9995) clipped++;
    }
    double rms = samples.length > 0 ? sqrt(energy / samples.length) : 0.0;
    double duration = cast(double) frames / SAMPLE_RATE;
    writefln("  frames=%d  duration=%.2f s", frames, duration);
    writefln("  peak=%.2f dBFS  rms=%.2f dBFS  clipped=%d", dbfs(peak),
        dbfs(rms), clipped);
}

private float[] renderSongCurrent(Song song)
{
    return renderSong(song, 0.5, 0.6, g_bank);
}

private void renderAndReport(Song song, string outPath)
{
    auto samples = renderSongCurrent(song);
    writeWav16(outPath, samples, SAMPLE_RATE);
    reportSamples(samples);
    writeln("  wrote ", outPath);
}

private int renderScoreFile(string scorePath, string outPath)
{
    if (!exists(scorePath))
    {
        stderr.writeln("score not found: ", scorePath);
        return 2;
    }
    try
    {
        auto song = parseScore(readText(scorePath));
        renderAndReport(song, outPath);
        return 0;
    }
    catch (Exception error)
    {
        stderr.writeln("could not parse ", scorePath, ": ", error.msg);
        return 2;
    }
}

private void usage()
{
    writeln("Aurora Music - a self-contained 0BSD software instrument");
    writeln("");
    writeln("usage:");
    writeln("  aurora-music [--synth|--dls FILE] [command] [args]");
    writeln("  aurora-music                     render the demo to aurora-music-demo.wav");
    writeln("  aurora-music demo [out.wav]      render the built-in demo");
    writeln("  aurora-music render <score> [out.wav]");
    writeln("  aurora-music play demo|<score>   render then play through the speakers");
    writeln("  aurora-music selftest            synthesize test notes and verify");
    writeln("");
    writeln("  --synth    force the built-in synthesis voices");
    writeln("  --dls F    use a DLS instrument bank (default: the system GM bank)");
}

/// Load a sample bank if one is wanted and available. Returns nothing; sets
/// `g_bank` on success.
private void prepareBank(bool useSamples, string dlsPath)
{
    if (!useSamples) return;
    string path = dlsPath.length > 0 ? dlsPath : defaultDlsPath();
    if (path.length == 0) return;

    auto bank = loadDlsFile(path);
    if (bank.instruments.length > 0)
    {
        g_bank = new Dls;
        *g_bank = bank;
        writefln("  instrument bank: %s (%d instruments)", path,
            bank.instruments.length);
    }
    else if (dlsPath.length > 0)
    {
        stderr.writeln("could not read DLS bank: ", path);
    }
    else
    {
        writeln("  no system instrument bank found; using synthesis");
    }
}

int main(string[] args)
{
    string[] positional;
    bool useSamples = true;
    string dlsPath;
    bool sawReserved = false;

    for (size_t i = 1; i < args.length; ++i)
    {
        string a = args[i];
        if (a == "--synth")
        {
            useSamples = false;
            continue;
        }
        if (a == "--samples")
        {
            useSamples = true;
            continue;
        }
        if (a == "--dls")
        {
            if (i + 1 < args.length) dlsPath = args[++i];
            continue;
        }
        positional ~= a;
    }

    // The self-test checks synthesis, so never load a bank for it.
    bool isSelfTest = positional.length > 0 && positional[0].toLower == "selftest";
    if (!isSelfTest) prepareBank(useSamples, dlsPath);

    string command = positional.length > 0 ? positional[0].toLower : "";

    if (command.length == 0)
    {
        renderAndReport(buildDemo(), "aurora-music-demo.wav");
        return 0;
    }
    if (command.endsWith(".amusic"))
        return renderScoreFile(positional[0], "aurora-music-out.wav");

    switch (command)
    {
        case "demo":
        {
            string outPath = positional.length > 1
                ? positional[1] : "aurora-music-demo.wav";
            renderAndReport(buildDemo(), outPath);
            return 0;
        }
        case "render":
        {
            if (positional.length < 2)
            {
                stderr.writeln("usage: aurora-music render <score.amusic> [out.wav]");
                return 2;
            }
            string outPath = positional.length > 2
                ? positional[2] : "aurora-music-out.wav";
            return renderScoreFile(positional[1], outPath);
        }
        case "play":
        {
            string target = positional.length > 1 ? positional[1] : "demo";
            Song song;
            if (target.toLower == "demo")
            {
                song = buildDemo();
            }
            else
            {
                if (!exists(target))
                {
                    stderr.writeln("score not found: ", target);
                    return 2;
                }
                try
                    song = parseScore(readText(target));
                catch (Exception error)
                {
                    stderr.writeln("could not parse ", target, ": ", error.msg);
                    return 2;
                }
            }
            auto samples = renderSongCurrent(song);
            reportSamples(samples);
            playSamples(samples, SAMPLE_RATE);
            return 0;
        }
        case "selftest":
            return runSelfTest() ? 0 : 1;
        case "help": case "-h": case "--help":
            usage();
            return 0;
        default:
            usage();
            return 2;
    }
}
