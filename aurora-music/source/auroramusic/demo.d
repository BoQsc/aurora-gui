/// The built-in demonstration piece: a fuller A-minor arrangement with strummed
/// acoustic guitar, a pad, piano, bass and a drum groove.
module auroramusic.demo;

import auroramusic.instruments : DrumType;
import auroramusic.song : Inst, Song, Track, addDrum, addNote;
import std.range : iota;

private struct Mel
{
    double beat;
    int midi;
    double vel;
    double dur;
}

private void strum(ref Track track, double beat, immutable int[] chord,
    bool down, double vel, double spread)
{
    int len = cast(int) chord.length;
    foreach (k; 0 .. len)
    {
        int idx = down ? k : (len - 1 - k);
        addNote(track, beat + spread * k, chord[idx], vel, 0.6);
    }
}

/// Build the demo song.
Song buildDemo()
{
    Song song;
    song.tempo = 84.0;
    song.tailSec = 3.5;

    song.addTrack(Inst.guitar, "Guitar", -3.5, -0.30, 0.35);
    song.addTrack(Inst.pad, "Pad", -14.0, 0.0, 0.60);
    song.addTrack(Inst.bass, "Bass", -5.0, 0.0, 0.10);
    song.addTrack(Inst.drums, "Drums", -4.0, 0.0, 0.24);
    song.addTrack(Inst.piano, "Piano", -9.0, 0.12, 0.55);
    song.addTrack(Inst.piano, "Lead", -10.0, 0.28, 0.65);

    ref Track guitar = song.tracks[0];
    ref Track pad = song.tracks[1];
    ref Track bass = song.tracks[2];
    ref Track drums = song.tracks[3];
    ref Track piano = song.tracks[4];
    ref Track lead = song.tracks[5];

    // Am - F - C - G, one chord per bar.
    immutable int[][] guitarChords = [
        [45, 52, 57, 60, 64, 69],
        [41, 48, 53, 57, 60, 65],
        [48, 55, 60, 64, 67, 72],
        [43, 50, 55, 59, 62, 67],
    ];
    immutable int[][] pianoChords = [
        [57, 60, 64],
        [53, 57, 60],
        [55, 60, 64],
        [55, 59, 62],
    ];
    immutable int[][] padChords = [
        [57, 60, 64],
        [53, 57, 60],
        [52, 55, 60],
        [55, 59, 62],
    ];
    immutable int[] bassRoots = [45, 41, 48, 43];

    immutable Mel[] melody = [
        Mel(0, 76, 0.70, 0.9),
        Mel(1, 72, 0.70, 0.9),
        Mel(2, 69, 0.72, 1.9),
        Mel(4, 65, 0.70, 0.9),
        Mel(5, 69, 0.70, 0.9),
        Mel(6, 72, 0.72, 1.9),
        Mel(8, 67, 0.70, 0.9),
        Mel(9, 76, 0.70, 0.9),
        Mel(10, 72, 0.72, 1.9),
        Mel(12, 74, 0.70, 0.9),
        Mel(13, 71, 0.70, 0.9),
        Mel(14, 67, 0.72, 1.9),
    ];

    int bars = 16;
    foreach (b; 0 .. bars)
    {
        int chordIdx = b % 4;
        double barStart = b * 4.0;
        immutable int[] gchord = guitarChords[chordIdx];

        // Every section has the strummed guitar and the pad.
        strum(guitar, barStart + 0.0, gchord, true, 0.72, 0.04);
        strum(guitar, barStart + 1.5, gchord, false, 0.52, 0.03);
        strum(guitar, barStart + 2.0, gchord, true, 0.68, 0.04);
        strum(guitar, barStart + 3.5, gchord, false, 0.52, 0.03);

        // The intro (bars 0-3) is solo guitar so it can be judged on its own.
        if (b >= 4)
            foreach (m; padChords[chordIdx])
                addNote(pad, barStart, m, 0.5, 3.9);

        // Bass enters from bar 4.
        if (b >= 4)
        {
            int root = bassRoots[chordIdx];
            addNote(bass, barStart + 0.0, root, 0.90, 1.4);
            addNote(bass, barStart + 2.0, root, 0.82, 1.4);
            addNote(bass, barStart + 3.5, root + 7, 0.68, 0.5);
        }

        // Drums enter at bar 4.
        if (b >= 4)
        {
            addDrum(drums, barStart + 0.0, DrumType.kick, 0.95);
            addDrum(drums, barStart + 2.5, DrumType.kick, 0.85);
            if ((b % 4) == 3)
                addDrum(drums, barStart + 3.75, DrumType.kick, 0.7);
            addDrum(drums, barStart + 1.0, DrumType.snare, 0.90);
            addDrum(drums, barStart + 3.0, DrumType.snare, 0.90);
            foreach (h; iota(0, 8))
                addDrum(drums, barStart + h * 0.5, DrumType.hat,
                    (h % 2 == 0) ? 0.52 : 0.32);
            if ((b % 2) == 1)
                addDrum(drums, barStart + 3.5, DrumType.ohat, 0.48);
        }

        // Piano chords and lead enter later for a build.
        if (b >= 8)
            foreach (m; pianoChords[chordIdx])
            {
                addNote(piano, barStart, m, 0.52, 1.9);
                addNote(piano, barStart + 2.0, m, 0.48, 1.9);
            }
    }

    // Lead melody for the last two phrases.
    foreach (loop; 2 .. 4)
        foreach (e; melody)
            addNote(lead, loop * 16.0 + e.beat, e.midi, e.vel, e.dur);

    addDrum(drums, 16.0, DrumType.crash, 0.75);
    addDrum(drums, 40.0, DrumType.crash, 0.65);

    return song;
}
