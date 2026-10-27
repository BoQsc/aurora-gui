module auroraopencode.reactiveparagraph;

/**
 * Experimental: one ongoing paragraph across tool rounds.
 *
 * The ordinary transcript is round-shaped: every assistant round is its own
 * bubble, so a turn that uses tools reads as
 * `paragraph -> tool card -> paragraph -> tool card`. This variant renders a
 * round that follows a tool result as a continuation of the paragraph above it
 * (no fresh top inset) and reports the pace of the loop in the status row, so a
 * screenshot/act/observe loop reads as one live paragraph and its speed is
 * visible instead of guessed.
 *
 * Nothing about the message model changes: rounds stay separate durable
 * messages, a tool call still terminates its stream, and no extra request is
 * sent. This only changes presentation and a readout.
 *
 * Off by default. Set `AURORA_REACTIVE_PARAGRAPH=1` (or the Settings checkbox)
 * to enable it. Delete this file plus the `experimental: reactive paragraph`
 * markers in appui.d and core.d to remove the variant.
 */

import core.time : MonoTime, msecs;
import std.algorithm.searching : startsWith;
import std.conv : to;
import std.process : environment;
import std.string : indexOf, strip;

private __gshared bool _enabled;

/// Called by the app on load and whenever the Settings checkbox changes.
public void setReactiveParagraphSetting(bool value)
{
    _enabled = value;
}

/// The environment override exists so a scripted run can pin the variant
/// without touching persisted settings.
public bool experimentalReactiveParagraphEnabled()
{
    const raw = strip(environment.get("AURORA_REACTIVE_PARAGRAPH", ""));
    if (raw.length > 0)
        return raw == "1" || raw == "true" || raw == "on";
    return _enabled;
}

/// A round continues the paragraph above it exactly when the message before it
/// is a tool result: that boundary is the seam this experiment removes.
public bool reactiveParagraphContinues(string previousRole, string role)
{
    return role == "assistant" && previousRole == "tool";
}

/// Pace of the live loop. `stepMs` is the previous round's full cost (its first
/// visible text to this round's first visible text), which is what a reader
/// actually feels: provider time-to-first-token plus every tool in between.
public struct ReactivePace
{
    int round;
    long stepMs;
}

private struct ReactiveState
{
    int round;
    bool deltaSeen;
    bool hasFirstDeltaAt;
    MonoTime firstDeltaAt;
    long lastStepMs;
}

private __gshared ReactiveState _state;

/// A new user turn starts the loop's accounting from scratch.
public void reactiveParagraphReset()
{
    _state = ReactiveState.init;
}

/// One assistant round started (the model's request for it returned headers).
public void reactiveParagraphRoundStarted()
{
    if (!experimentalReactiveParagraphEnabled()) return;
    ++_state.round;
    _state.deltaSeen = false;
}

/// Visible text arrived. The first delta of a round closes the previous step.
public void reactiveParagraphFirstDelta()
{
    if (!experimentalReactiveParagraphEnabled() || _state.deltaSeen) return;
    _state.deltaSeen = true;
    const now = MonoTime.currTime;
    if (_state.hasFirstDeltaAt)
        _state.lastStepMs = (now - _state.firstDeltaAt).total!"msecs";
    _state.firstDeltaAt = now;
    _state.hasFirstDeltaAt = true;
}

public ReactivePace reactiveParagraphPace()
{
    return ReactivePace(_state.round, _state.lastStepMs);
}

/// Status-row text for the running loop. Empty when the variant is off, so the
/// caller can use it unconditionally.
public string reactiveParagraphStatus(const ReactivePace pace)
{
    if (!experimentalReactiveParagraphEnabled() || pace.round <= 0) return "";
    auto text = "Reactive paragraph · round " ~ to!string(pace.round);
    if (pace.stepMs > 0)
        text ~= " · " ~ stepText(pace.stepMs) ~ " per step";
    return text;
}

/// Loop discipline appended to the system prompt while the switch is on. The
/// point of the variant is that the paragraph is not narration: each sentence
/// either reads the desktop or acts on it.
public string reactiveParagraphPromptModule()
{
    if (!experimentalReactiveParagraphEnabled()) return "";
    return "\n# Reactive paragraph loop\n" ~
        "This conversation drives a real desktop through the `computer` tool. " ~
        "Write one ongoing paragraph of short sentences, and make every " ~
        "sentence earn its place: after each sentence either read the screen " ~
        "(the screenshot a `computer` call already returns, or `action: " ~
        "\"screen\"`) or act on what you just read (click, type, key, scroll). " ~
        "Never describe a plan you have not looked at, and never claim an " ~
        "outcome you have not seen in a screenshot. " ~
        "A game window reads raw device input, so pass `input_mode: native` " ~
        "for it; posted messages never reach it. " ~
        "When the next several moves are already known, send them as one " ~
        "batched `steps` call and read the frame it returns instead of " ~
        "spending a round per click. " ~
        "If a frame comes back marked unchanged, do not repeat the action: " ~
        "re-read the screen, then either take a different action or stop and " ~
        "say where you are stuck.\n";
}

private string stepText(long ms)
{
    if (ms < 1000) return to!string(ms) ~ " ms";
    const tenths = (ms + 50) / 100;
    return to!string(tenths / 10) ~ "." ~ to!string(tenths % 10) ~ " s";
}

unittest
{
    // A round after a tool result continues; a round after prose does not, and
    // a user prompt never does.
    assert(reactiveParagraphContinues("tool", "assistant"));
    assert(!reactiveParagraphContinues("assistant", "assistant"));
    assert(!reactiveParagraphContinues("user", "assistant"));
    assert(!reactiveParagraphContinues("assistant", "tool"));

    // Pace accounting: round 1 has no step yet, round 2 reports the gap between
    // the two rounds' first visible text.
    setReactiveParagraphSetting(true);
    reactiveParagraphReset();
    assert(reactiveParagraphStatus(reactiveParagraphPace()).length == 0);
    reactiveParagraphRoundStarted();
    reactiveParagraphFirstDelta();
    reactiveParagraphFirstDelta(); // one measurement per round
    auto first = reactiveParagraphPace();
    assert(first.round == 1);
    assert(first.stepMs == 0);
    reactiveParagraphRoundStarted();
    reactiveParagraphFirstDelta();
    auto second = reactiveParagraphPace();
    assert(second.round == 2);
    assert(second.stepMs >= 0);

    const status = reactiveParagraphStatus(second);
    assert(status.startsWith("Reactive paragraph · round 2"));

    // The loop discipline travels with the switch.
    assert(reactiveParagraphPromptModule().indexOf("every sentence") >= 0);
    assert(reactiveParagraphPromptModule().indexOf("input_mode: native") >= 0);

    // Off means no status text and no accounting.
    setReactiveParagraphSetting(false);
    reactiveParagraphReset();
    reactiveParagraphRoundStarted();
    assert(reactiveParagraphPace().round == 0);
    assert(reactiveParagraphStatus(reactiveParagraphPace()).length == 0);
    assert(reactiveParagraphPromptModule().length == 0);
}
