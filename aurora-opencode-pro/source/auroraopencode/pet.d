module auroraopencode.pet;

// ===========================================================================
// Floating pet (HIGHLY EXPERIMENTAL, suggestion-only companion).
//
// A small always-on-top companion window that observes notable activity and
// PROPOSES actions. It never executes anything on its own: every proposal is
// text the user must approve, and any eventual action flows through the normal
// tool pipeline and its existing approval gate. Observation is off until the
// user opts in, and the window shows an unmistakable "watching" indicator.
//
// The visible pet is a drawn creature (PetFace), not an image: a tinted body
// with blinking eyes. Clicking it opens the input row, and the bubble above it
// shows at most three short lines - short because the vendored Label has no
// word wrap, so anything longer is clipped mid-sentence.
//
// Removable drop-in. To drop the feature: delete this file, the
// `experimentalFloatingPet` switch in core.d (its load/save lines), the
// Settings checkbox and the two guarded hooks in appui.d, and the feature is
// gone. This module imports only aurora and core - it references no tool,
// orchestrator or computer-use logic.
//
// Off by default. Opt in with the Settings checkbox or AURORA_FLOATING_PET=1.
//
// Design invariants (do not weaken - see docs/floating-pet.md):
//   * Deny by default: observe() proposes, it never acts.
//   * No new effect path: a proposal is inert text until the user approves it.
//   * Budgeted: at most petMaxProposalsPerMinute proposals per minute, and
//     duplicate (kind, text) pairs are dropped, so "always on" cannot become a
//     stream of prompts that trains blind approvals.
//   * Read-only awareness: observe() records counts, never file contents.
//   * Absent when off: nothing is published and no window exists unless the
//     switch is on.
//
// Threading mirrors minichat.d: a second GuiWindow owns its own Win32 message
// loop and is thread-affine, so it is created and run on a dedicated thread.
// If that window cannot be created (e.g. no display), the host leaves it null
// and degrades to proposal tracking only - the main app is unaffected.
// ===========================================================================

import aurora;
import auroraopencode.core : opencodeAccent, opencodeBorder, opencodeMuted,
    opencodePanel, opencodeStateDirectory, opencodeText, opencodeTheme;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.array : array;
import std.algorithm : canFind, sort, uniq;
import std.conv : to;
import std.datetime : Clock, SysTime;
import std.math : sin;
import std.process : environment;
import std.string : strip, toLower;
import std.utf : toUTF8;

version (Windows)
{
    private extern (Windows) int ShellExecuteW(void* hwnd, const(wchar)* op,
        const(wchar)* file, const(wchar)* params, const(wchar)* dir,
        int show);
    private extern (Windows)
    {
        void* GetForegroundWindow();
        int GetWindowTextW(void* hwnd, wchar* text, int max);
        uint GetWindowThreadProcessId(void* hwnd, uint* processId);
        void* OpenProcess(uint access, int inherit, uint processId);
        int QueryFullProcessImageNameW(void* process, uint flags, wchar* name,
            uint* size);
        int CloseHandle(void* handle);
        ptrdiff_t GetWindowLongPtrW(void* hwnd, int index);
        ptrdiff_t SetWindowLongPtrW(void* hwnd, int index, ptrdiff_t value);
        int SetWindowPos(void* hwnd, void* after, int x, int y, int cx, int cy,
            uint flags);
        int ShowWindow(void* hwnd, int command);
        int SetForegroundWindow(void* hwnd);
        void* SetFocus(void* hwnd);
    }
}

/// Only these environment values enable the pet, so an unset variable (the
/// common case) leaves it off.
private enum enableValues = ["1", "on", "true", "yes", "y", "enabled", "enable"];

/// Set by the host app from the persisted Settings checkbox. `__gshared` is
/// required: the UI thread writes it while the observers read it.
public __gshared bool floatingPetEnabledBySetting = false;

/// Whether the floating pet is active. Read on every call so tests (and a
/// relaunch with a different environment) see the current value. When this is
/// false every entry point is a no-op.
public bool experimentalPetEnabled()
{
    if (floatingPetEnabledBySetting) return true;
    const raw = strip(toLower(environment.get("AURORA_FLOATING_PET", "")));
    if (raw.length == 0) return false;
    return enableValues.canFind(raw);
}

/// Apply the Settings choice. Called on load and whenever the checkbox changes.
/// Turning it off also forgets the remaining budget/dedup state so a later
/// re-enable starts clean rather than inheriting a stale window.
public void setFloatingPetSetting(bool value)
{
    floatingPetEnabledBySetting = value;
    if (!value) forgetPetProposals();
}

/// The most proposals the pet may surface in any rolling minute. A safety
/// budget, not a target: silence is the default and this is the ceiling.
public static immutable int petMaxProposalsPerMinute = 4;

/// Consecutive identical tool failures before the pet offers to help. Two is
/// the point at which a command is more likely stuck than merely unlucky, and
/// it keeps the pet quiet for the common single failure the app already
/// handles on its own.
public static immutable int petFailureRepeatsThreshold = 2;

/// One proposed action awaiting the user's approval. `kind` is a short stable
/// tag (e.g. "idle", "failures"); `text` is the human-readable suggestion. The
/// struct intentionally carries no executable payload - a proposal cannot run.
public struct PetProposal
{
    string kind;
    string text;
    SysTime time;
}

/// A single observation of activity, produced by the host from things it
/// already knows. Only counts and short phrases travel; never file contents.
public struct PetObservation
{
    string kind;
    string detail;
    int count;
}

/// Outcome of observe(): the message to show, or an empty string when the pet
/// stays silent (disabled, budget spent, or a duplicate).
public struct PetDecision
{
    bool propose;
    string text;
    string reason;
}

/// A ready-made observation: the app has been quiet for `minutes` while a
/// conversation is open. Kept here so the caller assembles no logic.
public PetObservation petIdleObservation(int minutes)
{
    return PetObservation("idle",
        "the current conversation has been idle for " ~ to!string(minutes) ~
        " minutes", minutes);
}

/// A ready-made observation: `count` tool calls failed in a row.
public PetObservation petFailureObservation(int count)
{
    return PetObservation("failures",
        to!string(count) ~ " tool call(s) failed in a row", count);
}

/// A ready-made observation: the foreground app changed to `app`. The caller
/// passes only a bounded name, never pixels or file contents.
public PetObservation petSceneObservation(string app)
{
    return PetObservation("scene", app, 1);
}

/// Guards the ledger below. A class object, because `synchronized` cannot be
/// taken on an array.
private __gshared Object proposedLock;
private __gshared PetProposal[] proposed;
private __gshared SysTime[] proposedTimes;
private __gshared PetProposal[] lastShown;

/// Lazily create the ledger mutex (the ledger is process-wide and starts
/// empty, so this is the common case rather than an error path).
private Object proposeLedger()
{
    if (proposedLock is null) proposedLock = new Object();
    return proposedLock;
}

/// Reset the budget ledger and dedup memory. Called when the pet is turned off
/// and by tests.
public void forgetPetProposals()
{
    synchronized (proposeLedger())
    {
        proposed = null;
        proposedTimes = null;
        lastShown = null;
    }
}

/// The proposals surfaced in the last rolling minute.
public size_t petProposalsLastMinute()
{
    synchronized (proposeLedger())
    {
        const now = Clock.currTime;
        size_t live;
        foreach (time; proposedTimes)
            if ((now - time).total!"seconds" < 60) ++live;
        return live;
    }
}

/// How many distinct proposals have been surfaced this session (for tests).
public size_t petProposalCount()
{
    synchronized (proposeLedger()) return lastShown.length;
}

/// Turn one observation into a proposal, or silence. Never throws, never
/// executes: it only formats text and records it against the budget.
public PetDecision observe(in PetObservation observation)
{
    PetDecision decision;
    if (!experimentalPetEnabled())
    {
        decision.reason = "disabled";
        return decision;
    }
    if (observation.kind.length == 0)
    {
        decision.reason = "empty";
        return decision;
    }
    const now = Clock.currTime;
    const text = formatPetProposal(observation);
    if (text.length == 0)
    {
        decision.reason = "no-text";
        return decision;
    }
    synchronized (proposeLedger())
    {
        // Prune the rolling window, then enforce the per-minute budget.
        PetProposal[] kept;
        SysTime[] keptTimes;
        foreach (i, time; proposedTimes)
            if ((now - time).total!"seconds" < 60)
            {
                kept ~= proposed[i];
                keptTimes ~= time;
            }
        proposed = kept;
        proposedTimes = keptTimes;
        if (proposedTimes.length >= petMaxProposalsPerMinute)
        {
            decision.reason = "budget";
            return decision;
        }
        // Deduplicate an identical suggestion surfaced in the same window.
        foreach (p; proposed)
            if (p.kind == observation.kind && p.text == text)
            {
                decision.reason = "duplicate";
                return decision;
            }
        const proposal = PetProposal(observation.kind, text, now);
        proposed ~= proposal;
        proposedTimes ~= now;
        lastShown ~= proposal;
    }
    decision.propose = true;
    decision.text = text;
    return decision;
}

/// Suggest a deduplicated \`count\` from an observation. Pure and testable.
public int petObservationWeight(in PetObservation observation)
{
    return observation.count > 0 ? observation.count : 1;
}

/// The proposal text for an observation. Deterministic so it can be asserted
/// in a unit test. The suggestion is advice, never an instruction the pet can
/// carry out itself.
public string formatPetProposal(in PetObservation observation)
{
    const weighted = petObservationWeight(observation);
    switch (observation.kind)
    {
        case "idle":
            // Kept short: the overlay's Label has no wrapping in this toolkit,
            // so a long suggestion would be clipped mid-sentence.
            return "Quiet for a while. Want me to suggest a next step?";
        case "failures":
            // The wording matters: it asks, it does not announce. The pet has no
            // way to retry anything itself, and the text must not imply it does.
            return to!string(weighted) ~ " failed. Want me to take another " ~
                "look and retry?";
        case "scene":
            // Names the app without a paragraph: the bubble is one short line.
            return "You're in " ~
                (observation.detail.length ? observation.detail : "another app") ~
                ". Want notes or a next step?";
        default:
            return "";
    }
}

/// The proposals surfaced so far, newest last. A copy, so callers cannot mutate
/// the ledger.
public PetProposal[] petRecentProposals()
{
    synchronized (proposeLedger()) return lastShown.dup;
}

unittest
{
    // Formatting is deterministic and never claims the pet itself will act.
    assert(formatPetProposal(petIdleObservation(5)).canFind("Want me to"));
    const failure = formatPetProposal(petFailureObservation(2));
    assert(failure.canFind("2 failed"));
    // A proposal is an offer, never an announcement that the pet will act.
    assert(failure.canFind("Want me to") && failure.canFind("retry"));
    assert(!failure.canFind("I will") && !failure.canFind("Retrying"));
    assert(formatPetProposal(PetObservation("unknown", "x", 0)) == "");
    assert(petObservationWeight(PetObservation("idle", "x", 0)) == 1);
    assert(petObservationWeight(PetObservation("idle", "x", 9)) == 9);
    // The failure threshold is a real gate, not documentation.
    assert(petFailureRepeatsThreshold >= 2);
}

// The gate is the load-bearing safety claim: with the feature off - the
// default - observe() must be silent and must not consume budget, so turning
// the pet on later starts from a clean slate.
unittest
{
    const wasEnabled = floatingPetEnabledBySetting;
    setFloatingPetSetting(false);
    forgetPetProposals();
    assert(!experimentalPetEnabled(), "the pet must be off by default");
    const decision = observe(petFailureObservation(3));
    assert(!decision.propose, "a disabled pet must never propose");
    assert(decision.reason == "disabled", "silence must be reported as disabled");
    assert(petProposalsLastMinute() == 0,
        "a disabled pet must not consume any of the budget");

    // Enabled, the same observation is surfaced exactly once: the duplicate
    // suppression is what stops a repeating signal from training blind
    // approvals.
    setFloatingPetSetting(true);
    forgetPetProposals();
    assert(experimentalPetEnabled(), "the setting must enable the pet");
    const first = observe(petFailureObservation(3));
    assert(first.propose, "an enabled pet should surface the observation");
    const again = observe(petFailureObservation(3));
    assert(!again.propose && again.reason == "duplicate",
        "an identical suggestion must not repeat inside the window");

    // The budget is a real ceiling: after enough distinct proposals the pet
    // goes quiet rather than becoming a stream of prompts.
    foreach (i; 0 .. petMaxProposalsPerMinute + 2)
        observe(PetObservation("idle", "distinct " ~ to!string(i), i + 1));
    assert(petProposalsLastMinute() <= petMaxProposalsPerMinute,
        "the per-minute budget must cap the proposals");

    // Restore whatever the environment had before the test.
    setFloatingPetSetting(wasEnabled);
    forgetPetProposals();
}

// ---------------------------------------------------------------------------
// Overlay window (created only while enabled, on its own thread).
// ---------------------------------------------------------------------------

/// How the creature looks. Mood only changes its tint and eyes; it never
/// implies the pet is doing something on its own.
public enum PetMood
{
    idle,
    listening,
    thinking,
    alert,
    paused,
}

/// The pet's face, drawn with the canvas rather than loaded from an image: a
/// rounded body, two eyes that blink, a mouth and an antenna. Clicking it is
/// the "start writing" gesture, so the widget itself handles mouse-down and
/// exposes a hand cursor.
final class PetFace : Widget
{
    private double _time;
    private PetMood _mood = PetMood.idle;
    private int _bob;
    private bool _blinking;
    private int _paintCount;
    private Rect _lastBox;
    /// Fired on a left click. Set by the overlay.
    void delegate() onClick;

    this()
    {
        setId("pet-face");
        // Added as the last child so it paints above the rows, but laid out at
        // the creature's own slot: a full-window layer swallowed every click,
        // which made Pause, Notes and Send unreachable.
        layoutHints().excludeFromLayout = true;
        setCursor(CursorKind.hand);
    }

    PetMood mood() const { return _mood; }

    void setMood(PetMood mood)
    {
        if (_mood == mood) return;
        _mood = mood;
        invalidate();
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        if (!petFaceRect(bounds()).contains(event.position)) return false;
        if (onClick !is null) onClick();
        return true;
    }

    /// Animate from the overlay's tick. Repaint only when the visible pose
    /// changes (a whole pixel of bob or a blink), so an idle pet costs a few
    /// repaints per second rather than a continuous 60 fps redraw.
    protected override void onTick(double deltaSeconds)
    {
        _time += deltaSeconds;
        const blinking = (_time % 4.2) > 3.95;
        const bob = cast(int) (sin(_time * 2.0) * 1.5);
        if (blinking == _blinking && bob == _bob) return;
        _blinking = blinking;
        _bob = bob;
        invalidate();
    }

    /// Drawing lives in this top layer: the root's own paint was covered by its
    /// rows, and a child in the first column was covered by the ones after it.
    protected override void onPaint(ref Canvas canvas)
    {
        ++_paintCount;
        _lastBox = petFaceRect(bounds());
        paintPetFace(canvas, _lastBox, _mood, _blinking, _bob);
    }

    int paintCountForTesting() const { return _paintCount; }
    Rect lastBoxForTesting() const { return _lastBox; }

    /// The creature is painted by the overlay root, not here: in the floating
    /// window a child widget's fill output never reached the frame, while the
    /// root panel's did. The face keeps the animation state and hit testing.
    bool blinking() const { return _blinking; }
    int bob() const { return _bob; }
}

/// The creature's box inside a full-window layer.
private Rect petFaceRect(Rect layerBounds)
{
    return Rect(layerBounds.x + petFaceInset, layerBounds.y + petFaceTop,
        petFaceSize, petFaceSize);
}

/// Paint the creature into `box`, in the canvas's own coordinates. Uses only
/// rect fills and lines, the primitives the overlay already proves it renders.
private void paintPetFace(ref Canvas canvas, Rect box, PetMood mood,
    bool blinking, int bob)
{
    const width = box.width;
    const height = box.height;
    const radius = (width < height ? width : height) / 2 - 4;
    if (radius < 6) return;
    const cx = box.x + width / 2;
    const cy = box.y + height / 2 - bob;

    const tint = petMoodTint(mood);
    // Shaped with fill == border and thickness 1: in this window a rounded rect
    // with a contrasting border drew nothing, while a solid one renders. That
    // is also the shape the overlay's own panel border uses.
    canvas.drawRoundedRect(
        Rect(cx - radius, cy - radius, radius * 2, radius * 2), radius / 2,
        tint, tint, 1);
    // A lighter belly reads as volume at this size, where a gradient would be a
    // handful of pixels.
    canvas.drawRoundedRect(
        Rect(cx - radius / 2, cy, radius, radius * 2 / 3), radius / 3,
        petLighten(tint), petLighten(tint), 1);
    // Antenna: the readable "it's alive" cue when the face is tiny.
    canvas.drawLine(Point(cx, cy - radius), Point(cx, cy - radius - 5),
        opencodeMuted, 1);
    canvas.drawRoundedRect(Rect(cx - 2, cy - radius - 7, 4, 4), 2,
        petLighten(tint), petLighten(tint), 1);

    const eyeY = cy - radius / 4;
    const eyeDX = radius / 2;
    const eyeR = radius / 6 < 2 ? 2 : radius / 6;
    if (blinking || mood == PetMood.paused)
    {
        canvas.drawLine(Point(cx - eyeDX - eyeR, eyeY),
            Point(cx - eyeDX + eyeR, eyeY), opencodePanel, 2);
        canvas.drawLine(Point(cx + eyeDX - eyeR, eyeY),
            Point(cx + eyeDX + eyeR, eyeY), opencodePanel, 2);
    }
    else
    {
        canvas.drawRoundedRect(
            Rect(cx - eyeDX - eyeR, eyeY - eyeR, eyeR * 2, eyeR * 2),
            eyeR, opencodePanel, opencodePanel, 1);
        canvas.drawRoundedRect(
            Rect(cx + eyeDX - eyeR, eyeY - eyeR, eyeR * 2, eyeR * 2),
            eyeR, opencodePanel, opencodePanel, 1);
    }

    const mouthY = cy + radius / 3;
    if (mood == PetMood.alert)
    {
        canvas.drawLine(Point(cx - 4, mouthY + 2), Point(cx, mouthY),
            opencodePanel, 1);
        canvas.drawLine(Point(cx, mouthY), Point(cx + 4, mouthY + 2),
            opencodePanel, 1);
    }
    else
    {
        canvas.drawLine(Point(cx - 4, mouthY), Point(cx, mouthY + 2),
            opencodePanel, 1);
        canvas.drawLine(Point(cx, mouthY + 2), Point(cx + 4, mouthY),
            opencodePanel, 1);
    }
}

private Color petMoodTint(PetMood mood)
{
    final switch (mood)
    {
        case PetMood.idle: return opencodeAccent;
        case PetMood.listening: return Color.rgb(0x74, 0xa9, 0xf2);
        case PetMood.thinking: return Color.rgb(0x9a, 0x8f, 0xe8);
        case PetMood.alert: return Color.rgb(0xe6, 0x9a, 0x5a);
        case PetMood.paused: return opencodeBorder;
    }
}


private Color petLighten(Color color, int amount = 26)
{
    static int lift(int channel, int by)
    {
        const value = channel + by;
        return value > 255 ? 255 : value;
    }
    return Color.rgb(lift(color.r, amount), lift(color.g, amount),
        lift(color.b, amount));
}


/// Longest bubble line that fits the overlay without being clipped. The Label
/// cannot wrap, so the limit is a real layout bound, not a style preference.
public enum int petBubbleLineCharacters = 44;

/// The pet's notes are one markdown file in its own state folder, capped so a
/// long-running pet cannot grow it without bound.
public enum int petNoteLineLimit = 400;

/// <state>/pet/notes.md
public string petNotesPath()
{
    import std.path : buildPath;
    return buildPath(opencodeStateDirectory(), "pet", "notes.md");
}

/// Append one observation as a markdown bullet, then trim to the newest
/// `petNoteLineLimit` lines. Best effort: a read-only state folder must not take
/// the app down over a note.
public void petNote(string text)
{
    import std.array : join;
    import std.file : exists, mkdirRecurse, readText, write;
    import std.path : dirName;
    import std.string : splitLines;

    const line = petBubbleLine(text, 160);
    if (line.length == 0) return;
    try
    {
        const path = petNotesPath();
        const dir = dirName(path);
        if (!exists(dir)) mkdirRecurse(dir);
        string[] lines;
        if (exists(path)) lines = readText(path).splitLines();
        lines ~= "- " ~ line;
        if (lines.length > petNoteLineLimit)
            lines = lines[$ - petNoteLineLimit .. $];
        write(path, lines.join("\n") ~ "\n");
    }
    catch (Exception)
    {
        // Notes are a convenience; losing one is better than a failed overlay.
    }
}

/// Open the notes file in the user's editor, creating it first when needed.
public void openPetNotes()
{
    version (Windows)
    {
        import std.file : exists, mkdirRecurse, write;
        import std.path : dirName;
        import std.utf : toUTF16z;

        try
        {
            const path = petNotesPath();
            const dir = dirName(path);
            if (!exists(dir)) mkdirRecurse(dir);
            if (!exists(path)) write(path, "");
            ShellExecuteW(null, "open".toUTF16z, path.toUTF16z, null, null, 1);
        }
        catch (Exception)
        {
            // No shell handler is not an error worth interrupting the pet for.
        }
    }
}

/// One coarse observation of the foreground window: which app, which window,
/// and a bounded text digest of both. Never pixels, never file contents.
public struct PetScene
{
    string app;
    string title;
    string digest;
    bool changed;
}

/// Test seam: returns what the screen currently shows, as text.
alias PetSceneSampler = PetScene delegate();

/// Flatten and bound the scene text, so a long window title cannot smuggle a
/// wall of text into the pet and digests compare stable strings.
public string petSceneDigest(string app, string title)
{
    return petBubbleLine(app, 60) ~ " | " ~ petBubbleLine(title, 80);
}

/// Samples the foreground window at most once per interval, keeping text only.
public final class PetScreenWatch
{
    private PetSceneSampler _sampler;
    private string _lastDigest;
    private long _lastSampleMs = -1;

    this(PetSceneSampler sampler = null)
    {
        _sampler = sampler;
    }

    /// An empty digest means the interval has not elapsed and nothing was read.
    PetScene sample(long nowMs, long intervalMs = 20_000)
    {
        if (_lastSampleMs >= 0 && nowMs - _lastSampleMs < intervalMs)
            return PetScene.init;
        _lastSampleMs = nowMs;
        auto scene = _sampler is null ? sampleForegroundScene() : _sampler();
        scene.digest = petSceneDigest(scene.app, scene.title);
        scene.changed = _lastDigest.length > 0 && scene.digest != _lastDigest;
        _lastDigest = scene.digest;
        return scene;
    }

    string lastDigest() const
    {
        return _lastDigest;
    }
}

/// The foreground app and window title, empty when there is no foreground
/// window (for example on a locked desktop).
public PetScene sampleForegroundScene()
{
    version (Windows)
    {
        import std.utf : toUTF8;

        auto hwnd = GetForegroundWindow();
        if (hwnd is null) return PetScene.init;
        wchar[512] buffer;
        const length = GetWindowTextW(hwnd, buffer.ptr, cast(int) buffer.length);
        const title = length > 0 ? toUTF8(buffer[0 .. length]) : "";
        uint processId;
        GetWindowThreadProcessId(hwnd, &processId);
        return PetScene(foregroundAppName(processId), title);
    }
    return PetScene.init;
}

private string foregroundAppName(uint processId)
{
    version (Windows)
    {
        import std.path : baseName, stripExtension;
        import std.utf : toUTF8;

        // PROCESS_QUERY_LIMITED_INFORMATION: enough for the image name, and it
        // works for processes the user can query but not fully open.
        auto handle = OpenProcess(0x1000, 0, processId);
        if (handle is null) return "";
        scope (exit) CloseHandle(handle);
        wchar[512] buffer;
        uint size = cast(uint) buffer.length;
        if (QueryFullProcessImageNameW(handle, 0, buffer.ptr, &size) == 0)
            return "";
        return stripExtension(baseName(toUTF8(buffer[0 .. size])));
    }
    return "";
}

/// The overlay's native window handle, or null when the platform has none.
version (Windows)
private void* overlayHwnd(GuiWindow window)
{
    if (window is null) return null;
    return window.nativeWindow().nativeSurfaceInfo().handleB;
}

/// Keep the companion out of the taskbar: a tool window has no task button, so
/// it reads as part of the desktop rather than another running app.
version (Windows)
private void hideFromTaskbar(GuiWindow window)
{
    auto hwnd = overlayHwnd(window);
    if (hwnd is null) return;
    enum GWL_EXSTYLE = -20;
    enum WS_EX_TOOLWINDOW = 0x80;
    enum WS_EX_APPWINDOW = 0x40000;
    enum SWP_NOMOVE = 0x2, SWP_NOSIZE = 0x1, SWP_NOZORDER = 0x4,
        SWP_NOACTIVATE = 0x10, SWP_FRAMECHANGED = 0x20;
    const style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    SetWindowLongPtrW(hwnd, GWL_EXSTYLE,
        (style | WS_EX_TOOLWINDOW) & ~cast(ptrdiff_t) WS_EX_APPWINDOW);
    SetWindowPos(hwnd, null, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
        SWP_FRAMECHANGED);
}

/// Bring the companion forward and give it keyboard focus, so clicking it leads
/// straight to typing instead of doing nothing.
version (Windows)
private void focusOverlay(GuiWindow window)
{
    auto hwnd = overlayHwnd(window);
    if (hwnd is null) return;
    SetForegroundWindow(hwnd);
    SetFocus(hwnd);
}

/// The creature's fixed slot in the overlay: inset 8, directly under the 26px
/// titlebar, 48x48. The overlay's chrome is fixed, so this stays aligned with
/// the layout without depending on a child's measured box.
private enum int petFaceInset = 8;
private enum int petFaceTop = 8;
private enum int petFaceSize = 48;

/// The line the companion rests on. "write", not "talk": clicking opens a text
/// field, and the bubble should say what actually happens.
public enum string petIdleLine = "I'm watching. Click me to write.";

/// Flatten arbitrary text to one short bubble line: whitespace runs collapse,
/// and the tail is replaced by an ellipsis past `limit` visible characters.
public string petBubbleLine(string raw, int limit = petBubbleLineCharacters)
{
    dstring text;
    bool pendingSpace;
    foreach (dchar ch; raw)
    {
        if (ch == '\n' || ch == '\r' || ch == '\t' || ch == ' ' ||
            ch == '\u00a0')
        {
            if (text.length > 0) pendingSpace = true;
            continue;
        }
        if (pendingSpace)
        {
            text ~= ' ';
            pendingSpace = false;
        }
        text ~= ch;
        if (limit > 0 && text.length >= limit)
        {
            text ~= '…';
            break;
        }
    }
    return toUTF8(text);
}

unittest
{
    assert(petBubbleLine("  hi   there ") == "hi there");
    assert(petBubbleLine("line one\nline two") == "line one line two");
    assert(petBubbleLine("abcdefghij", 5) == "abcde…");
    assert(petBubbleLine("") == "");
    // The render width assumes a bounded line; keep the limit honest.
    assert(petBubbleLineCharacters > 0 && petBubbleLineCharacters <= 52);
}

/// The overlay's root widget. Built and ticked only on the dedicated overlay
/// thread, so it never reads another thread's state directly.
final class PetOverlay : VBox
{
    private PetHost _host;
    private GuiWindow _window;
    private PetFace _face;
    private Label _faceGlyph;
    private HBox _content;
    private VBox _bubble;
    private HBox _inputRow;
    private TextField _input;
    private Button _pauseButton;
    /// Test-only: the labels of the last right-click menu that was built.
    private string[] _lastMenuLabels;
    /// Persistent footer. It is a separate row precisely so the approval notice
    /// can never be pushed out of view by a long suggestion.
    private Label _approval;
    /// Last text handed to the body, for content assertions in tests.
    private string _lastText;

    this(PetHost host)
    {
        super(6, Insets(8));
        _host = host;
        setId("pet-root");
        setBackground(opencodePanel);
        setBorder(opencodeBorder, 12);
        layoutHints().flex = 1.0;

        // No titlebar row: this window draws no chrome, so the 26px it reserved
        // only pushed the input row out of view once it was revealed.

        _content = new HBox(10);
        _content.setId("pet-content");
        _content.layoutHints().flex = 1.0;
        _content.layoutHints().preferredHeight = 72;

        // The creature's column. A glyph carries the face because only Label
        // text reaches this window's surface; the drawn PetFace layer below
        // keeps the animation state and the click target.
        auto faceColumn = new VBox(0);
        faceColumn.setId("pet-face-column");
        faceColumn.layoutHints().preferredWidth = petFaceSize + 10;
        _faceGlyph = new Label("☺");
        _faceGlyph.setId("pet-face-glyph");
        _faceGlyph.setScale(2);
        _faceGlyph.setColor(opencodeAccent);
        faceColumn.add(_faceGlyph);
        _content.add(faceColumn);

        _bubble = new VBox(3);
        _bubble.setId("pet-body");
        _bubble.layoutHints().flex = 1.0;
        _content.add(_bubble);
        add(_content);

        // Hidden until the face is clicked, so the resting pet is small.
        _inputRow = new HBox(6);
        _inputRow.setId("pet-input-row");
        _inputRow.layoutHints().preferredHeight = 30;
        _input = new TextField();
        _input.setId("pet-input");
        _input.setPlaceholder("Tell me what to do...");
        _input.layoutHints().flex = 1.0;
        _input.onSubmitted = &submit;
        _inputRow.add(_input);
        auto notes = new Button("Notes");
        notes.setId("pet-notes");
        notes.onClick = delegate() { if (_host !is null) _host.openNotes(); };
        _inputRow.add(notes);
        auto send = new Button("Send");
        send.setId("pet-send");
        send.onClick = &submit;
        _inputRow.add(send);
        _inputRow.setVisible(false);
        add(_inputRow);

        // Always visible, independent of the suggestion's length.
        _approval = new Label("Nothing happens without your approval.");
        _approval.setId("pet-approval");
        _approval.setColor(opencodeMuted);
        _approval.layoutHints().flex = 1.0;
        auto footer = new HBox(6);
        footer.setId("pet-footer");
        footer.layoutHints().preferredHeight = 22;
        footer.add(_approval);
        _pauseButton = new Button("Pause");
        _pauseButton.setId("pet-pause");
        _pauseButton.onClick = delegate() { togglePause(); };
        footer.add(_pauseButton);
        auto close = new Button("×");
        close.setId("pet-close");
        close.onClick = delegate() { closeCompanion(); };
        footer.add(close);
        add(footer);

        // Last child: paints and hit-tests the creature, so no row can cover it.
        _face = new PetFace();
        _face.onClick = delegate() { revealInput(); };
        add(_face);
        setLines([petIdleLine]);
    }

    void bindWindow(GuiWindow window)
    {
        _window = window;
    }

    /// The creature layer must sit exactly on the creature's slot; everything
    /// else (Pause, Notes, Send, the × button) has to receive its own clicks.
    protected override void onLayout()
    {
        super.onLayout();
        if (_face !is null) _face.setBounds(petFaceRect(bounds()));
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right)
        {
            showPetMenu(event.position);
            return true;
        }
        if (event.button == MouseButton.left)
        {
            // Anywhere on the companion is a write target; the buttons and the
            // creature layer consume their own presses before this runs.
            revealInput();
            return true;
        }
        return super.onMouseDown(event);
    }

    /// Right-click anywhere on the companion: write, pause, notes, close.
    private void showPetMenu(Point local)
    {
        const paused = _host !is null && _host.paused();
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("Write…", IconKind.notepad,
            delegate() { revealInput(); });
        items ~= ContextMenuItem.command(paused ? "Resume" : "Pause",
            IconKind.settings, delegate() { togglePause(); });
        items ~= ContextMenuItem.command("Notes", IconKind.open,
            delegate() { if (_host !is null) _host.openNotes(); });
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Close companion", IconKind.close,
            delegate() { closeCompanion(); });
        _lastMenuLabels = ["Write…", paused ? "Resume" : "Pause", "Notes",
            "Close companion"];
        showContextMenu(this, localToGlobal(local), items);
    }

    private void togglePause()
    {
        if (_host is null) return;
        _host.setPaused(!_host.paused());
        if (_pauseButton !is null)
            _pauseButton.setText(_host.paused() ? "Resume" : "Pause");
    }

    /// Stop the host: the overlay closes and the app clears its pet so the
    /// Settings switch reflects reality.
    private void closeCompanion()
    {
        if (_host !is null) _host.stop();
        else if (_window !is null) _window.close();
    }


    /// Replace the bubble. At most three short lines are shown; anything more
    /// would not fit the window, and silence falls back to the watch line.
    /// Runs on the overlay thread only.
    void setLines(string[] lines)
    {
        _lastText = lines.length ? lines[0] : "";
        _bubble.clearChildren();
        const shown = lines.length > 3 ? 3 : lines.length;
        foreach (line; lines[0 .. shown])
        {
            const text = petBubbleLine(line);
            if (text.length == 0) continue;
            addBubbleLine(text, opencodeText);
        }
        if (_bubble.children().length == 0)
            addBubbleLine("I'm watching.", opencodeMuted);
    }

    private void addBubbleLine(string text, Color color)
    {
        auto label = new Label(text);
        label.setColor(color);
        label.setScale(1);
        _bubble.add(label);
    }

    /// Show the input row and put the caret in it. Runs on the overlay thread.
    void revealInput()
    {
        if (_inputRow is null) return;
        _inputRow.setVisible(true);
        _face.setMood(PetMood.listening);
        // A click must hand keyboard focus to the companion, otherwise the user
        // types into whatever was in front and "click to talk" does nothing.
        if (_window !is null)
        {
            focusOverlay(_window);
            _window.redrawWindow();
        }
        invalidate();
        if (_input !is null) _input.requestFocus();
    }

    private void submit()
    {
        if (_input is null) return;
        const text = _input.textUtf8().strip();
        if (text.length == 0) return;
        _input.setText("");
        _face.setMood(PetMood.thinking);
        // The host owns the hand-off; the overlay never submits anything itself.
        if (_host !is null) _host.publishPrompt(text);
    }

    protected override void onTick(double deltaSeconds)
    {
        if (_host is null) return;
        _host.drain(this);
        if (_host.stopRequested() && _window !is null)
            _window.close();
    }

    /// Show a single line (the newest proposal). Overlay thread only.
    void setText(string text)
    {
        if (text.length == 0)
        {
            setLines([]);
            return;
        }
        setLines([text]);
    }

    /// The text currently shown. Overlay thread only.
    string shownText() const { return _lastText; }

    /// Test-only: whether the input row is revealed.
    bool inputVisibleForTesting() const
    {
        return _inputRow !is null && _inputRow.visible();
    }

    /// Test-only: where the input row actually laid out, to tell "not shown"
    /// apart from "shown but placed outside the window".
    Rect inputBoundsForTesting() const
    {
        return _inputRow is null ? Rect.init : _inputRow.bounds();
    }

    /// Test-only: the creature layer's box. It must stay on the creature and
    /// leave the footer controls clickable.
    Rect faceLayerBoundsForTesting() const
    {
        return _face is null ? Rect.init : _face.bounds();
    }

    Rect pauseBoundsForTesting() const
    {
        return _pauseButton is null ? Rect.init : _pauseButton.bounds();
    }

    /// Test-only: the pause action, without a pointer.
    void clickPauseForTesting()
    {
        togglePause();
    }

    /// Test-only: the close action, without a pointer.
    void clickCloseForTesting()
    {
        closeCompanion();
    }

    /// Test-only: labels of the right-click menu.
    string[] menuLabelsForTesting()
    {
        showPetMenu(Point(10, 10));
        return _lastMenuLabels;
    }

    /// Test-only: a left press on the companion body, away from the face.
    void clickBodyForTesting(Point at)
    {
        Event event;
        event.type = EventType.mouseDown;
        event.button = MouseButton.left;
        event.position = at;
        onMouseDown(event);
    }

    /// Test-only: the current input text.
    string inputTextForTesting() const
    {
        return _input is null ? "" : _input.textUtf8();
    }

    /// Test-only: fill the input without keystrokes.
    void setInputForTesting(string text)
    {
        if (_input !is null) _input.setText(text);
    }

    /// Test-only: drive the same delegate the face's mouse-down invokes.
    void clickFaceForTesting()
    {
        if (_face !is null && _face.onClick !is null) _face.onClick();
    }

    /// Test-only: the creature's current mood.
    PetMood faceMoodForTesting() const
    {
        return _face is null ? PetMood.idle : _face.mood();
    }

    /// Test-only: the creature's painted box.
    Rect faceBoundsForTesting() const
    {
        return _face is null ? Rect.init : _face.lastBoxForTesting();
    }

    /// Test-only: how many times the face layer painted.
    int facePaintCountForTesting() const
    {
        return _face is null ? 0 : _face.paintCountForTesting();
    }

    /// Test-only: the overlay-local box the creature was last painted into.
    Rect facePaintBoxForTesting() const
    {
        return _face is null ? Rect.init : _face.lastBoxForTesting();
    }
}

/// Owns the overlay window, its thread, and the cross-thread hand-off.
final class PetHost
{
    private Mutex _mutex;
    private Thread _thread;
    private string[] _pendingLines;
    private string _pendingPrompt;
    private bool _promptPending;
    private bool _textDirty;
    private bool _stop;
    /// Lifts the overlay clear of the mini chat when both are visible.
    private int _bottomOffset;
    // Text-only foreground sampling, at most once per 20s.
    private PetScreenWatch _watch;
    private PetScene _scene;
    // Pause stops observing, commenting and note-taking; the overlay stays.
    private bool _paused;
    private bool _pausedShown;
    // The screen-watching sub-switch. Off means no foreground sampling at all.
    private bool _screenWatching = true;
    /// The overlay built by the last renderForTesting call, so a headless test
    /// can drive the visible widget without creating a second window.
    private PetOverlay _testOverlay;

    this(int bottomOffset = 0, bool screenWatching = true)
    {
        _mutex = new Mutex();
        _bottomOffset = bottomOffset;
        _screenWatching = screenWatching;
        _watch = new PetScreenWatch();
    }

    /// Create the overlay window on its own thread and run its native loop.
    /// Best-effort: a failure leaves the thread ending quietly and never
    /// disturbs the main UI.
    void start()
    {
        if (_thread !is null) return;
        _thread = new Thread(&threadMain);
        _thread.isDaemon = true;
        _thread.start();
    }

    /// Ask the overlay to close (on its own thread, at its next tick).
    void stop()
    {
        synchronized (_mutex) _stop = true;
    }

    private void threadMain()
    {
        try
        {
            auto overlay = new PetOverlay(this);
            WindowOptions options;
            options.title = "Aurora Companion";
            // Wide enough for the longest suggestion without wrapping, since
            // this Label has no wrap support in the vendored toolkit.
            options.width = 420;
            // Tall enough for the bubble plus the revealed input row; at 132 the
            // row had no room, so clicking the creature appeared to do nothing.
            options.height = 168;
            options.decorated = false;
            options.resizable = false;
            options.alwaysOnTop = true;
            // Never steal focus when it appears.
            options.startNoActivate = true;
            options.noActivate = false;
            options.renderer = RendererPreference.software;
            options.vsync = false;
            options.lowLatency = false;
            options.extendedScrollInput = false;
            options.nativeVerticalScrollHost = false;
            options.enableFullscreenShortcut = false;

            auto window = new GuiWindow(options, opencodeTheme());
            overlay.bindWindow(window);
            window.setRoot(overlay);
            placeBottomRight(window);
            // Before the first show: no taskbar button, ever.
            hideFromTaskbar(window);
            window.run();
            overlay.bindWindow(null);
        }
        catch (Exception)
        {
            // No display / no text engine: the pet is simply absent rather than
            // a failing mode. State tracking still works.
        }
    }

    /// Test-only: apply the bottom-left placement to an externally built window
    /// so the geometry can be asserted against an injected work area.
    void placeForTesting(GuiWindow window)
    {
        placeBottomRight(window);
    }

    /// Put the overlay above the taskbar in the work area's bottom-right
    /// corner, inset by 16px. `_bottomOffset` lifts it clear of the mini chat
    /// overlay when both are on.
    private void placeBottomRight(GuiWindow window)
    {
        Rect bounds;
        Rect work;
        if (!window.queryWorkArea(Point(0, 0), work)) return;
        if (work.empty) return;
        if (!window.windowBounds(bounds)) return;
        const margin = 16;
        window.setWindowPosition(Point(work.right() - bounds.width - margin,
            work.bottom() - bounds.height - margin - _bottomOffset));
    }

    /// UI thread: replace the text the overlay will render next tick.
    void publishText(string text)
    {
        publishLines([text]);
    }

    /// UI thread: replace the bubble with up to three short lines.
    void publishLines(string[] lines)
    {
        synchronized (_mutex)
        {
            _pendingLines = lines.dup;
            _textDirty = true;
        }
    }

    /// Overlay thread: apply pending content, if any.
    void drain(PetOverlay overlay)
    {
        if (paused())
        {
            if (!_pausedShown)
            {
                _pausedShown = true;
                overlay.setLines(["Paused"]);
            }
            return;
        }
        if (_pausedShown)
        {
            _pausedShown = false;
            overlay.setLines([petIdleLine]);
        }
        if (screenWatching())
        {
            const scene = _watch.sample(Clock.currTime.toUnixTime * 1000);
            if (scene.digest.length)
            {
                synchronized (_mutex) _scene = scene;
            }
        }
        string[] lines;
        bool have;
        synchronized (_mutex)
        {
            if (_textDirty)
            {
                _textDirty = false;
                lines = _pendingLines;
                have = true;
            }
        }
        if (have) overlay.setLines(lines);
    }

    /// Overlay thread: hand a typed request to the UI thread exactly once.
    void publishPrompt(string text)
    {
        synchronized (_mutex)
        {
            _pendingPrompt = text;
            _promptPending = true;
        }
    }

    /// UI thread: take the pending prompt, if one was typed.
    bool takePrompt(out string text)
    {
        synchronized (_mutex)
        {
            if (!_promptPending) return false;
            _promptPending = false;
            text = _pendingPrompt;
            _pendingPrompt = "";
            return true;
        }
    }

    /// Record one notable observation in the pet's own notes file.
    void note(string text)
    {
        if (paused()) return;
        petNote(text);
    }

    /// The notes file this pet writes.
    string notesPath()
    {
        return petNotesPath();
    }

    /// Open the notes file in the user's editor.
    void openNotes()
    {
        openPetNotes();
    }

    bool stopRequested()
    {
        synchronized (_mutex) return _stop;
    }

    /// Stop observing, commenting and taking notes while staying visible.
    void setPaused(bool value)
    {
        synchronized (_mutex) _paused = value;
    }

    bool paused()
    {
        synchronized (_mutex) return _paused;
    }

    /// Turn foreground sampling on or off; off means no capture at all.
    void setScreenWatching(bool value)
    {
        synchronized (_mutex) _screenWatching = value;
    }

    bool screenWatching()
    {
        synchronized (_mutex) return _screenWatching;
    }

    /// The most recent scene sample (empty until the first 20s tick).
    PetScene lastScene()
    {
        synchronized (_mutex) return _scene;
    }

    // Test-only: build the overlay's window on the CALLING thread and paint one
    // frame, so a headless test can capture and inspect what the overlay renders.
    // The production path creates the same overlay on its own thread
    // (threadMain); this exists only because that window is thread-affine and
    // therefore unreachable from the test's thread. Returns null if the window
    // could not be created (no display / no text engine), which is also a valid
    // production outcome.
    GuiWindow renderForTesting(string text)
    {
        auto overlay = new PetOverlay(this);
        _testOverlay = overlay;
        if (text.length) overlay.setText(text);
        WindowOptions options;
        options.title = "Companion";
        options.width = 400;
        options.height = 176;
        options.decorated = false;
        options.resizable = false;
        options.alwaysOnTop = true;
        options.startNoActivate = true;
        // Default renderer: the software path in this window rendered text and
        // panel chrome but dropped every custom-painted shape, which is where
        // the creature lives.
        options.vsync = false;
        auto window = new GuiWindow(options, opencodeTheme());
        overlay.bindWindow(window);
        window.setRoot(overlay);
        overlay.tickTree(0.02);
        // setRoot paints before the tree is laid out, so the first paint can
        // see zero-sized children. Mark the base tree dirty and paint again:
        // other smoke tests drive an explicit paint for the same reason.
        overlay.invalidate();
        auto driver = new UiTestDriver(window);
        driver.paint();
        return window;
    }

    /// Test-only: the overlay from the last renderForTesting call.
    PetOverlay renderedOverlayForTesting()
    {
        return _testOverlay;
    }
}
