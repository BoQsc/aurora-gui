/// Song model and the renderer that turns tracks of note events into audio.
///
/// When a DLS sample bank is supplied the renderer plays real recorded
/// instruments; otherwise it falls back to the built-in synthesis voices.
module auroramusic.song;

import auroramusic.dls : Dls;
import auroramusic.dsp : Rng, SAMPLE_RATE, clampd, dbToGain, midiToFreq;
import auroramusic.instruments : DrumType, GuitarKind, renderDrum, renderGuitar,
    renderPad, renderPiano;
import auroramusic.mix : Mix, finalize;
import auroramusic.sampler : drumToGm, renderSampled;
import std.math : PI, cos, sin;

/// Instrument families the synth knows about.
enum Inst
{
    piano,
    guitar,
    nylon,
    bass,
    pad,
    drums,
}

/// One scheduled event. Pitched tracks use `midi`; drum tracks use `drum`.
struct NoteEvent
{
    double beat;
    double vel = 0.85;
    double durBeats = 0.95;
    int midi = 60;
    DrumType drum = DrumType.kick;
}

/// A single track: an instrument, mix settings and its note events.
struct Track
{
    Inst inst;
    string name;
    double gainDb = 0.0;
    double pan = 0.0;
    double rev = 0.25;
    NoteEvent[] notes;
}

/// A complete piece: tempo plus tracks.
struct Song
{
    double tempo = 100.0;
    double tailSec = 2.5;
    Track[] tracks;

    /// Append a track and return a mutable reference to it.
    ref Track addTrack(Inst inst, string name, double gainDb, double pan, double rev)
    {
        tracks ~= Track(inst, name, gainDb, pan, rev, null);
        return tracks[$ - 1];
    }
}

/// Append a pitched note to a track.
void addNote(ref Track track, double beat, int midi, double vel = 0.85,
    double durBeats = 0.95)
{
    track.notes ~= NoteEvent(beat, vel, durBeats, midi, DrumType.kick);
}

/// Append a drum hit to a track.
void addDrum(ref Track track, double beat, DrumType drum, double vel = 0.9)
{
    track.notes ~= NoteEvent(beat, vel, 0.2, 60, drum);
}

/// GM program, loop-decay and level used when playing a family from samples.
private bool sampledParams(Inst inst, out int program, out double decayTau,
    out double gain)
{
    switch (inst)
    {
        case Inst.piano: program = 0; decayTau = 3.5; gain = 0.9; return true;
        case Inst.guitar: program = 25; decayTau = 2.2; gain = 0.9; return true;
        case Inst.nylon: program = 24; decayTau = 2.0; gain = 0.9; return true;
        case Inst.bass: program = 32; decayTau = 3.0; gain = 1.0; return true;
        case Inst.pad: program = 89; decayTau = 5.0; gain = 0.7; return true;
        default: return false;
    }
}

private void renderOne(Mix mix, ref Rng rng, ref Track track, ref NoteEvent ev,
    size_t start, double durSec, double gl, double gr, const(Dls)* dls)
{
    // Prefer the sampled path when a bank is available.
    if (dls !is null && dls.instruments.length > 0)
    {
        if (track.inst == Inst.drums)
        {
            int kit = dls.findDrumKit();
            if (kit >= 0)
            {
                renderSampled(mix, start, drumToGm(ev.drum), ev.vel, durSec, gl, gr,
                    track.rev, *dls, kit, 0.0, 1.0);
                return;
            }
        }
        else
        {
            int program;
            double decayTau, gain;
            if (sampledParams(track.inst, program, decayTau, gain))
            {
                int idx = dls.findProgram(program);
                if (idx >= 0)
                {
                    renderSampled(mix, start, ev.midi, ev.vel, durSec, gl, gr,
                        track.rev, *dls, idx, decayTau, gain);
                    return;
                }
            }
        }
    }

    final switch (track.inst)
    {
        case Inst.piano:
        {
            double ring = durSec + 1.8;
            if (ring > 4.5) ring = 4.5;
            renderPiano(mix, start, midiToFreq(ev.midi), ev.vel, ring, gl, gr,
                track.rev, rng);
            break;
        }
        case Inst.guitar:
            renderGuitar(mix, start, midiToFreq(ev.midi), ev.vel, durSec,
                gl, gr, track.rev, GuitarKind.steel, rng);
            break;
        case Inst.nylon:
            renderGuitar(mix, start, midiToFreq(ev.midi), ev.vel, durSec,
                gl, gr, track.rev, GuitarKind.nylon, rng);
            break;
        case Inst.bass:
            renderGuitar(mix, start, midiToFreq(ev.midi), ev.vel, durSec,
                gl, gr, track.rev, GuitarKind.bass, rng);
            break;
        case Inst.pad:
            renderPad(mix, start, midiToFreq(ev.midi), ev.vel, durSec,
                gl, gr, track.rev, rng);
            break;
        case Inst.drums:
            renderDrum(mix, start, ev.drum, ev.vel, gl, gr, track.rev, rng);
            break;
    }
}

/// Render a whole song to interleaved stereo floats in [-1, 1].
float[] renderSong(Song song, double reverbWet = 0.5, double room = 0.6,
    const(Dls)* dls = null)
{
    double secPerBeat = 60.0 / song.tempo;

    double maxTime = 0.0;
    foreach (tr; song.tracks)
    {
        foreach (ev; tr.notes)
        {
            double span = tr.inst == Inst.drums ? 1.0 : ev.durBeats;
            double end = (ev.beat + span) * secPerBeat;
            if (end > maxTime) maxTime = end;
        }
    }

    double totalSec = maxTime + song.tailSec + 1.0;
    if (totalSec < 2.0) totalSec = 2.0;

    Mix mix = new Mix(totalSec);
    Rng rng = Rng(0x5EED_1234_ABCDUL);

    foreach (tr; song.tracks)
    {
        double trackGain = dbToGain(tr.gainDb);
        double angle = (clampd(tr.pan, -1.0, 1.0) + 1.0) * PI / 4.0;
        double gl = cos(angle) * trackGain;
        double gr = sin(angle) * trackGain;

        foreach (ev; tr.notes)
        {
            size_t start = cast(size_t)(ev.beat * secPerBeat * SAMPLE_RATE);
            double durSec = ev.durBeats * secPerBeat;
            renderOne(mix, rng, tr, ev, start, durSec, gl, gr, dls);
        }
    }

    return finalize(mix, reverbWet, room);
}
