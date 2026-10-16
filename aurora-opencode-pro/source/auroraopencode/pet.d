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
import auroraopencode.core : opencodeBorder, opencodeMuted, opencodePanel,
    opencodeTheme;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.array : array;
import std.algorithm : canFind, sort, uniq;
import std.conv : to;
import std.datetime : Clock, SysTime;
import std.process : environment;
import std.string : strip, toLower;
import std.utf : toUTF8;

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

/// The overlay's root widget. Built and ticked only on the dedicated overlay
/// thread, so it never reads another thread's state directly.
final class PetOverlay : VBox
{
    private PetHost _host;
    private GuiWindow _window;
    private VBox _body;
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

        auto bar = new TitleBar();
        bar.setId("pet-titlebar");
        bar.setTitle("Companion (watching, suggestions only)");
        bar.setShowIcon(false);
        bar.setShowMinimize(false);
        bar.setShowMaximize(false);
        bar.setShowClose(true);
        bar.setBarHeight(26);
        bar.setSystemMoveOnDrag(true);
        bar.setDoubleClickMaximizes(false);
        bar.setSnapEnabled(false);
        bar.onClose = delegate() { if (_window !is null) _window.close(); };
        add(bar);

        _body = new VBox(4);
        _body.setId("pet-body");
        _body.layoutHints().flex = 1.0;
        add(_body);

        // Always visible, independent of the suggestion's length.
        _approval = new Label("Nothing happens without your approval.");
        _approval.setId("pet-approval");
        _approval.setColor(opencodeMuted);
        add(_approval);
        setWatchText("I'm watching. Every suggestion needs your approval.");
    }

    void bindWindow(GuiWindow window)
    {
        _window = window;
    }

    /// Replace the single status line. Runs on the overlay thread only.
    private void setWatchText(string text)
    {
        _lastText = text;
        _body.clearChildren();
        auto label = new Label(text);
        label.setColor(opencodeMuted);
        _body.add(label);
    }

    protected override void onTick(double deltaSeconds)
    {
        if (_host is null) return;
        _host.drain(this);
        if (_host.stopRequested() && _window !is null)
            _window.close();
    }

    /// Show the newest proposal, or the standing watch notice. Overlay thread
    /// only.
    void setText(string text)
    {
        setWatchText(text.length ? text : "I'm watching.");
    }

    /// The text currently shown. Overlay thread only.
    string shownText() const { return _lastText; }

}

/// Owns the overlay window, its thread, and the cross-thread hand-off.
final class PetHost
{
    private Mutex _mutex;
    private Thread _thread;
    private string _pendingText;
    private bool _textDirty;
    private bool _stop;

    this()
    {
        _mutex = new Mutex();
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
            options.title = "Companion";
            // Wide enough for the longest suggestion without wrapping, since
            // this Label has no wrap support in the vendored toolkit.
            options.width = 420;
            options.height = 132;
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
            placeBottomLeft(window);
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
        placeBottomLeft(window);
    }

    private void placeBottomLeft(GuiWindow window)
    {
        Rect bounds;
        Rect work;
        if (!window.queryWorkArea(Point(0, 0), work)) return;
        if (work.empty) return;
        if (!window.windowBounds(bounds)) return;
        const margin = 16;
        window.setWindowPosition(Point(work.x + margin,
            work.bottom() - bounds.height - margin));
    }

    /// UI thread: replace the text the overlay will render next tick.
    void publishText(string text)
    {
        synchronized (_mutex)
        {
            _pendingText = text;
            _textDirty = true;
        }
    }

    /// Overlay thread: apply pending text, if any.
    void drain(PetOverlay overlay)
    {
        string text;
        bool have;
        synchronized (_mutex)
        {
            if (_textDirty)
            {
                _textDirty = false;
                text = _pendingText;
                have = true;
            }
        }
        if (have) overlay.setText(text);
    }

    bool stopRequested()
    {
        synchronized (_mutex) return _stop;
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
        if (text.length) overlay.setText(text);
        WindowOptions options;
        options.title = "Companion";
        options.width = 420;
        options.height = 132;
        options.decorated = false;
        options.resizable = false;
        options.alwaysOnTop = true;
        options.startNoActivate = true;
        options.renderer = RendererPreference.software;
        options.vsync = false;
        auto window = new GuiWindow(options, opencodeTheme());
        overlay.bindWindow(window);
        window.setRoot(overlay);
        overlay.tickTree(0.02);
        return window;
    }
}
