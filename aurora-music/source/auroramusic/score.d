/// Parser for the human-readable `.amusic` score format.
module auroramusic.score;

import auroramusic.instruments : DrumType;
import auroramusic.song : Inst, Song, Track, addDrum, addNote;
import std.conv : to;
import std.string : indexOf, splitLines, strip, toLower;

private string[] tokenize(string line)
{
    string[] tokens;
    size_t i = 0;
    while (i < line.length)
    {
        while (i < line.length && (line[i] == ' ' || line[i] == '\t')) i++;
        size_t j = i;
        while (j < line.length && !(line[j] == ' ' || line[j] == '\t')) j++;
        if (j > i) tokens ~= line[i .. j];
        i = j;
    }
    return tokens;
}

private bool allDigits(string s)
{
    if (s.length == 0) return false;
    foreach (ch; s)
        if (ch < '0' || ch > '9') return false;
    return true;
}

/// Parse a scientific pitch name (`C4`, `F#3`, `Bb2`) or a raw MIDI number.
int parsePitch(string s)
{
    if (allDigits(s)) return s.to!int;

    int semitone;
    switch (s[0])
    {
        case 'C': case 'c': semitone = 0; break;
        case 'D': case 'd': semitone = 2; break;
        case 'E': case 'e': semitone = 4; break;
        case 'F': case 'f': semitone = 5; break;
        case 'G': case 'g': semitone = 7; break;
        case 'A': case 'a': semitone = 9; break;
        case 'B': case 'b': semitone = 11; break;
        default: throw new Exception("Bad note name: " ~ s);
    }

    size_t i = 1;
    if (i < s.length && s[i] == '#') { semitone++; i++; }
    else if (i < s.length && s[i] == 'b') { semitone--; i++; }

    int octave = s[i .. $].to!int;
    return 12 * (octave + 1) + semitone;
}

/// Parse a drum voice name.
DrumType parseDrum(string s)
{
    switch (s.toLower)
    {
        case "kick": case "k": return DrumType.kick;
        case "snare": case "s": return DrumType.snare;
        case "hat": case "hh": return DrumType.hat;
        case "ohat": case "oh": return DrumType.ohat;
        case "clap": case "c": return DrumType.clap;
        case "tom": case "t": return DrumType.tom;
        case "crash": case "cr": return DrumType.crash;
        default: throw new Exception("Bad drum name: " ~ s);
    }
}

private Inst parseInst(string s)
{
    switch (s.toLower)
    {
        case "piano": case "p": return Inst.piano;
        case "guitar": case "g": return Inst.guitar;
        case "nylon": case "n": return Inst.nylon;
        case "bass": case "b": return Inst.bass;
        case "pad": return Inst.pad;
        case "drums": case "drum": case "d": return Inst.drums;
        default: throw new Exception("Bad instrument: " ~ s);
    }
}

/// Parse score text into a `Song`.
Song parseScore(string text)
{
    Song song;
    int current = -1;

    foreach (rawLine; text.splitLines)
    {
        string line = rawLine;
        auto hash = line.indexOf('#');
        if (hash >= 0) line = line[0 .. hash];
        line = line.strip();
        if (line.length == 0) continue;

        auto parts = tokenize(line);
        string head = parts[0].toLower;

        if (head == "tempo")
        {
            song.tempo = parts[1].to!double;
            continue;
        }
        if (head == "tail")
        {
            song.tailSec = parts[1].to!double;
            continue;
        }
        if (head == "track")
        {
            string name = parts.length > 2 && parts[1].indexOf('=') < 0
                ? parts[1] : "track";
            Inst inst = Inst.piano;
            double gain = 0.0, pan = 0.0, rev = 0.25;
            foreach (p; parts[1 .. $])
            {
                auto eq = p.indexOf('=');
                if (eq < 0) continue;
                string key = p[0 .. eq].toLower;
                string val = p[eq + 1 .. $];
                switch (key)
                {
                    case "inst": inst = parseInst(val); break;
                    case "gain": gain = val.to!double; break;
                    case "pan": pan = val.to!double; break;
                    case "rev": rev = val.to!double; break;
                    default: break;
                }
            }
            song.addTrack(inst, name, gain, pan, rev);
            current = cast(int)(song.tracks.length - 1);
            continue;
        }

        // Otherwise it is a note/drum event for the current track.
        if (current < 0)
            throw new Exception("Note before any track: " ~ line);

        ref Track track = song.tracks[current];
        string pitchName = parts[0];
        double beat = parts.length > 1 ? parts[1].to!double : 0.0;
        double vel = parts.length > 2 ? parts[2].to!double : 0.85;
        double dur = parts.length > 3 ? parts[3].to!double : 0.95;

        if (track.inst == Inst.drums)
            addDrum(track, beat, parseDrum(pitchName), vel);
        else
            addNote(track, beat, parsePitch(pitchName), vel, dur);
    }

    return song;
}
