/**
 * The instant concision pass for Aurora Write.
 *
 * This module is the "show results without thinking" half of the optimizer: it
 * is pure, allocation-light and answers in microseconds, so the caret card can
 * appear on the keystroke that completes a word. The language model refines the
 * same span afterwards (see `llmclient.d`); nothing here waits for the network.
 *
 * A pass resolves one span around the caret:
 *   - the longest known wordy phrase containing the caret ("due to the fact
 *     that"), else
 *   - the word containing the caret, or the word that ends at it (the common
 *     case while typing plus a trailing space),
 * and returns shorter rewrites with a one-sentence definition of the original
 * plus a one-sentence gloss per choice.
 */
module aurorawrite.concision;

import std.utf : toUTF8, toUTF32;
import std.conv : to;

/// Most choices the caret card shows at once (the spec's 6-8 word shortlist).
enum maxChoices = 8;

/// Longest replacement the instant pass offers (6-8 words is the design target).
enum maxChoiceWords = 8;

/// Sentence window scanned around the caret, in UTF-32 code units.
private enum int sentenceReach = 240;

/// One replacement offered for the resolved span.
struct ConciseChoice
{
    /// Replacement text; empty means "delete the span".
    string text;
    /// One-sentence explanation of the replacement.
    string gloss;
    /// Word count of `text`, precomputed for the card's word-savings label.
    int words;
    /// True when a language model produced this choice.
    bool refined;
}

/// Result of one analysis pass over the document at the caret.
struct Analysis
{
    /// UTF-32 span to replace, within the document passed to the analyzer.
    size_t start;
    size_t end;
    /// The span as typed.
    string target;
    /// One-sentence definition of the span.
    string definition;
    /// Concise rewrites, longest list first.
    ConciseChoice[] choices;
    /// `instant` for the local table, `model` for a refined pass.
    string origin;
    /// Short status line the card can show.
    string status;

    bool hasSpan() const @safe pure nothrow @nogc { return end > start; }
    bool valid() const @safe pure nothrow @nogc
    {
        return hasSpan() && choices.length > 0;
    }
}

private struct Pick
{
    string text;
    string gloss;
}

private struct Phrase
{
    string key;
    Pick[] picks;
    string definition;
}

/**
 * Extra concise synonyms for the words writers reach for most.
 *
 * The rewrite table above answers "what is the one fix here?" and stays short
 * on purpose. This table widens the same answer into a real shortlist of six to
 * eight word choices, which is what the caret card promises. Entries are keyed
 * by the same base form, so inflected targets ("demonstrated") reuse them.
 */
private struct Shortlist
{
    string key;
    Pick[] picks;
}

/**
 * Hand-tuned wordiness table.
 *
 * Every key is ASCII lowercase. Keys with a space match a span that contains
 * the caret; single keys match a whole word (and its regular inflections).
 */
private immutable Phrase[] phrases = [
    // --- Verbose verbs. ---
    Phrase("utilize", [Pick("use", "Plain verb for the same act."),
            Pick("apply", "Put a thing to its purpose.")],
        "To put something to practical use."),
    Phrase("utilise", [Pick("use", "Plain verb for the same act.")],
        "To put something to practical use."),
    Phrase("utilization", [Pick("use", "The noun is shorter and plainer.")],
        "The act of putting something to practical use."),
    Phrase("commence", [Pick("start", "Shorter and less formal."),
            Pick("begin", "Same meaning, fewer letters.")],
        "To begin or to set something going."),
    Phrase("terminate", [Pick("end", "Shorter and less formal."),
            Pick("stop", "Same meaning, plainer verb.")],
        "To bring something to its end."),
    Phrase("demonstrate", [Pick("show", "Plain verb for the same act."),
            Pick("prove", "Use when evidence is the point.")],
        "To show something clearly by example or evidence."),
    Phrase("facilitate", [Pick("help", "Plain verb for the same act."),
            Pick("ease", "Use when effort or friction drops.")],
        "To make an action or process easier."),
    Phrase("implement", [Pick("do", "Shortest verb that fits."),
            Pick("carry out", "Keeps the sense of execution.")],
        "To put a plan or decision into effect."),
    Phrase("initiate", [Pick("start", "Shorter and less formal.")],
        "To start something or set it in motion."),
    Phrase("modify", [Pick("change", "Plainer verb, same meaning.")],
        "To change something in some part."),
    Phrase("eliminate", [Pick("cut", "Short, direct verb."),
            Pick("remove", "Keeps the sense of taking away.")],
        "To remove something completely."),
    Phrase("endeavor", [Pick("try", "Shorter and less formal.")],
        "To try hard to do something."),
    Phrase("establish", [Pick("set", "Shortest verb that fits."),
            Pick("create", "Use when something new is made.")],
        "To set something up on a firm basis."),
    Phrase("maintain", [Pick("keep", "Shorter and plainer.")],
        "To keep something in its present state."),
    Phrase("obtain", [Pick("get", "Shorter and less formal.")],
        "To get or come into possession of something."),
    Phrase("purchase", [Pick("buy", "The plain word for the act.")],
        "To buy something by paying for it."),
    Phrase("assist", [Pick("help", "The plain word for the act.")],
        "To help someone with a task."),
    Phrase("attempt", [Pick("try", "Shorter and less formal.")],
        "To try to do something."),
    Phrase("require", [Pick("need", "Shorter and plainer.")],
        "To need something as a condition."),
    Phrase("indicate", [Pick("show", "Plain verb for the same act.")],
        "To show or point something out."),
    Phrase("transmit", [Pick("send", "The plain word for the act.")],
        "To send something from one place to another."),
    Phrase("ascertain", [Pick("find", "Shortest verb that fits."),
            Pick("learn", "Use when knowledge is gained.")],
        "To find something out with certainty."),
    Phrase("expedite", [Pick("speed up", "Two plain words, same meaning.")],
        "To make a process happen faster."),
    Phrase("formulate", [Pick("frame", "Shorter and plainer."),
            Pick("draft", "Use when a first version is made.")],
        "To express an idea in a precise form."),
    Phrase("necessitate", [Pick("need", "Shorter and plainer.")],
        "To make something necessary."),
    Phrase("prohibit", [Pick("ban", "Short, direct verb."),
            Pick("block", "Use when an action is stopped.")],
        "To forbid something by rule or law."),
    Phrase("substantiate", [Pick("prove", "Shorter and plainer.")],
        "To support a claim with evidence."),
    Phrase("disseminate", [Pick("share", "Shorter and plainer."),
            Pick("spread", "Use for reaching a wider group.")],
        "To spread information to many people."),
    Phrase("accommodate", [Pick("fit", "Shortest verb that fits."),
            Pick("hold", "Use for capacity.")],
        "To make room for something or someone."),
    Phrase("anticipate", [Pick("expect", "The plainer verb.")],
        "To expect something before it happens."),
    Phrase("comprehend", [Pick("grasp", "Shorter and plainer."),
            Pick("see", "Shortest verb that fits.")],
        "To understand something fully."),
    Phrase("relocate", [Pick("move", "The plain word for the act.")],
        "To move something to another place."),
    Phrase("verify", [Pick("check", "Shorter and plainer.")],
        "To check that something is true."),
    Phrase("inquire", [Pick("ask", "Shorter and plainer.")],
        "To ask for information."),

    // --- Long adjectives and adverbs. ---
    Phrase("approximately", [Pick("about", "Short and equally precise.")],
        "Close to a value, but not exact."),
    Phrase("additional", [Pick("more", "Shorter and plainer."),
            Pick("extra", "Use for something added beyond need.")],
        "Something added to what already exists."),
    Phrase("sufficient", [Pick("enough", "The plain word for the amount.")],
        "As much as is needed."),
    Phrase("numerous", [Pick("many", "The plain word for the count.")],
        "A large number of things."),
    Phrase("currently", [Pick("now", "Shortest word that fits.")],
        "At the present time."),
    Phrase("consequently", [Pick("so", "Shorter and less formal.")],
        "As a result of what came before."),
    Phrase("additionally", [Pick("also", "Shorter and less formal.")],
        "In addition to what was just said."),
    Phrase("nevertheless", [Pick("but", "Shorter and less formal."),
            Pick("still", "Keeps the contrast in one word.")],
        "In spite of what was just said."),
    Phrase("ultimately", [Pick("finally", "Plainer adverb.")],
        "At the end of a process."),
    Phrase("regarding", [Pick("about", "The plain word for the topic.")],
        "On the subject of something."),
    Phrase("aforementioned", [Pick("this", "Points at the same thing.")],
        "The thing already mentioned earlier."),
    Phrase("subsequent", [Pick("later", "Shorter and plainer.")],
        "Coming after something else in time."),

    // --- Wordy multi-word phrases. ---
    Phrase("in order to", [Pick("to", "One word carries the purpose.")],
        "For the purpose of doing something."),
    Phrase("due to the fact that",
        [Pick("because", "One word carries the cause.")],
        "Because of the reason that follows."),
    Phrase("in spite of the fact that",
        [Pick("although", "One word carries the contrast.")],
        "Even though the stated thing is true."),
    Phrase("notwithstanding the fact that",
        [Pick("although", "One word carries the contrast.")],
        "Even though the stated thing is true."),
    Phrase("for the purpose of",
        [Pick("to", "One word carries the purpose.")],
        "In order to achieve something."),
    Phrase("at this point in time",
        [Pick("now", "One word carries the timing.")],
        "At the present moment."),
    Phrase("at the present time",
        [Pick("now", "One word carries the timing.")],
        "At the present moment."),
    Phrase("in the event that", [Pick("if", "One word carries the condition.")],
        "If the stated thing happens."),
    Phrase("in the near future", [Pick("soon", "One word carries the timing.")],
        "After a short time from now."),
    Phrase("a large number of", [Pick("many", "One word carries the count.")],
        "A big count of things."),
    Phrase("a number of", [Pick("several", "One word carries the count.")],
        "More than two, but not many."),
    Phrase("a majority of", [Pick("most", "One word carries the share.")],
        "More than half of a group."),
    Phrase("has the ability to", [Pick("can", "One word carries the ability.")],
        "Is able to do something."),
    Phrase("have the ability to", [Pick("can", "One word carries the ability.")],
        "Are able to do something."),
    Phrase("is able to", [Pick("can", "One word carries the ability.")],
        "Has the ability to do something."),
    Phrase("are able to", [Pick("can", "One word carries the ability.")],
        "Have the ability to do something."),
    Phrase("make a decision", [Pick("decide", "One verb replaces three words.")],
        "To choose between options."),
    Phrase("make an adjustment", [Pick("adjust", "One verb replaces three words.")],
        "To change something slightly."),
    Phrase("take into consideration",
        [Pick("consider", "One verb replaces three words.")],
        "To weigh something before deciding."),
    Phrase("with regard to", [Pick("about", "One word carries the topic.")],
        "On the subject of something."),
    Phrase("with respect to", [Pick("about", "One word carries the topic.")],
        "On the subject of something."),
    Phrase("each and every", [Pick("every", "One word carries the whole set.")],
        "All of the individual members."),
    Phrase("first and foremost",
        [Pick("first", "One word carries the priority.")],
        "Before anything else in importance."),
    Phrase("in my personal opinion",
        [Pick("I think", "Two words carry the same claim.")],
        "This is what I believe."),
    Phrase("it is important to note that",
        [Pick("note that", "Keeps the point, drops the throat-clearing."),
            Pick("", "Cut the phrase; the sentence stands.")],
        "A filler lead-in before the real point."),
    Phrase("it should be noted that",
        [Pick("note that", "Keeps the point, drops the throat-clearing."),
            Pick("", "Cut the phrase; the sentence stands.")],
        "A filler lead-in before the real point."),
    Phrase("there is no doubt that",
        [Pick("clearly", "One word carries the certainty."),
            Pick("", "Cut the phrase; state the claim directly.")],
        "A strong claim that something is certain."),
    Phrase("the fact that", [Pick("that", "One word does the same work."),
            Pick("", "Cut the phrase; the clause stands.")],
        "A padding phrase before a plain statement."),
    Phrase("in terms of", [Pick("for", "One word carries the frame.")],
        "With respect to a particular measure."),
    Phrase("as a result of", [Pick("because of", "Two words carry the cause.")],
        "Caused by the thing that follows."),
    Phrase("on account of", [Pick("because of", "Same length, plainer words.")],
        "Caused by the thing that follows."),
    Phrase("in close proximity to",
        [Pick("near", "One word carries the distance.")],
        "Close to something in space."),
    Phrase("close proximity", [Pick("near", "One word carries the distance.")],
        "A short distance from something."),
    Phrase("in the process of", [Pick("while", "One word carries the overlap.")],
        "During the course of doing something."),
    Phrase("in the majority of cases",
        [Pick("usually", "One word carries the frequency.")],
        "In most instances."),
    Phrase("prior to", [Pick("before", "Shorter and plainer.")],
        "Earlier than something else."),
    Phrase("subsequent to", [Pick("after", "Shorter and plainer.")],
        "Later than something else."),
    Phrase("end result", [Pick("result", "One word is exact.")],
        "The outcome of a process."),
    Phrase("basic fundamentals", [Pick("basics", "One word is exact.")],
        "The simplest underlying principles."),
    Phrase("past history", [Pick("history", "One word is exact.")],
        "Events that already happened."),
    Phrase("future plans", [Pick("plans", "One word is exact.")],
        "Intended actions for later."),
    Phrase("advance planning", [Pick("planning", "One word is exact.")],
        "Deciding what to do before acting."),
    Phrase("absolutely essential", [Pick("essential", "One word is exact.")],
        "Needed without any alternative."),
    Phrase("completely eliminate", [Pick("eliminate", "One word is exact.")],
        "To remove something entirely."),
    Phrase("very unique", [Pick("unique", "One word is exact.")],
        "The only one of its kind."),
    Phrase("joint collaboration",
        [Pick("collaboration", "One word is exact.")],
        "Working together on something."),
    Phrase("repeat again", [Pick("repeat", "One word is exact.")],
        "To say or do something once more."),
    Phrase("return back", [Pick("return", "One word is exact.")],
        "To go or give something back."),
    Phrase("combine together", [Pick("combine", "One word is exact.")],
        "To join two or more things."),

    // --- Intensifiers that usually earn their place in the bin. ---
    Phrase("very", [Pick("", "Cut; the adjective carries the strength.")],
        "An intensifier that rarely adds information."),
    Phrase("really", [Pick("", "Cut; the claim is already made.")],
        "An intensifier that rarely adds information."),
    Phrase("quite", [Pick("", "Cut; the adjective stands alone.")],
        "A hedge that rarely adds information."),
    Phrase("actually", [Pick("", "Cut; the contrast is already clear.")],
        "A filler adverb that rarely adds information."),
    Phrase("basically", [Pick("", "Cut; state the point itself.")],
        "A filler adverb that rarely adds information."),
    Phrase("simply", [Pick("", "Cut; the verb stands alone.")],
        "A filler adverb that rarely adds information."),
    Phrase("literally", [Pick("", "Cut unless the sense is literal.")],
        "An intensifier that is often figurative."),
    Phrase("definitely", [Pick("", "Cut; the statement is already firm.")],
        "An intensifier that rarely adds information."),
    Phrase("extremely", [Pick("", "Cut; the adjective carries the strength.")],
        "An intensifier that rarely adds information."),
    Phrase("totally", [Pick("", "Cut; the verb carries the degree.")],
        "An intensifier that rarely adds information."),
    Phrase("rather", [Pick("", "Cut unless a comparison is meant.")],
        "A hedge that rarely adds information."),
    Phrase("somewhat", [Pick("", "Cut unless the degree matters.")],
        "A hedge that rarely adds information."),
    Phrase("fairly", [Pick("", "Cut unless the degree matters.")],
        "A hedge that rarely adds information."),
];

private immutable Shortlist[] shortlists = [
    Shortlist("utilize", [Pick("employ", "Put someone or something to work."),
            Pick("exercise", "Use a right or an ability."),
            Pick("draw on", "Use what is already available."),
            Pick("play to", "Turn a strength into an advantage.")]),
    Shortlist("commence", [Pick("open", "Begin an event or session."),
            Pick("launch", "Start something with intent."),
            Pick("start", "Plain verb for the first step.")]),
    Shortlist("terminate", [Pick("stop", "Bring an action to a halt."),
            Pick("quit", "Leave or give up something."),
            Pick("close", "End an event or a session."),
            Pick("drop", "Stop something already running."),
            Pick("cancel", "Call off a planned thing.")]),
    Shortlist("demonstrate", [Pick("show", "Plain verb for the same act."),
            Pick("prove", "Use when evidence settles it."),
            Pick("display", "Show it openly to others."),
            Pick("present", "Show it to an audience."),
            Pick("illustrate", "Show it through an example."),
            Pick("exhibit", "Show a trait or an object."),
            Pick("reveal", "Show what was hidden.")]),
    Shortlist("facilitate", [Pick("help", "Plain verb for the same act."),
            Pick("ease", "Lower the effort involved."),
            Pick("speed", "Make the process quicker."),
            Pick("enable", "Make the act possible."),
            Pick("allow", "Let the thing happen."),
            Pick("guide", "Lead the group through it.")]),
    Shortlist("implement", [Pick("do", "Shortest verb that fits."),
            Pick("run", "Put the thing into operation."),
            Pick("build", "Make the planned thing real."),
            Pick("apply", "Put the rule into practice."),
            Pick("perform", "Carry the action through.")]),
    Shortlist("eliminate", [Pick("cut", "Short, direct verb."),
            Pick("end", "Stop it for good."),
            Pick("ban", "Forbid it by rule."),
            Pick("remove", "Take it out of the set."),
            Pick("drop", "Let it fall away."),
            Pick("erase", "Wipe it from the record.")]),
    Shortlist("establish", [Pick("set", "Shortest verb that fits."),
            Pick("form", "Bring a group or shape into being."),
            Pick("build", "Make it step by step."),
            Pick("found", "Start an institution."),
            Pick("prove", "Show it beyond doubt."),
            Pick("place", "Put it into position.")]),
    Shortlist("obtain", [Pick("get", "Shortest verb that fits."),
            Pick("gain", "Come to have more of it."),
            Pick("earn", "Get it through effort."),
            Pick("win", "Get it through competition."),
            Pick("buy", "Get it by paying."),
            Pick("secure", "Get it and keep it.")]),
    Shortlist("require", [Pick("need", "Shortest verb that fits."),
            Pick("ask", "Call for it to be done."),
            Pick("demand", "Call for it firmly."),
            Pick("force", "Make it unavoidable."),
            Pick("involve", "Bring it in as a condition."),
            Pick("take", "Use up time or effort.")]),
    Shortlist("indicate", [Pick("show", "Plain verb for the same act."),
            Pick("signal", "Send a sign of it."),
            Pick("mark", "Point it out on a surface."),
            Pick("hint", "Suggest it without saying it."),
            Pick("point", "Direct attention to it."),
            Pick("mean", "Stand for the same thing.")]),
    Shortlist("modify", [Pick("change", "Plainer verb, same meaning."),
            Pick("alter", "Change one part of it."),
            Pick("tweak", "Change it in a small way."),
            Pick("revise", "Change a draft or plan."),
            Pick("adjust", "Change it to fit better."),
            Pick("adapt", "Change it for a new use.")]),
    Shortlist("maintain", [Pick("keep", "Shortest verb that fits."),
            Pick("hold", "Keep it in place."),
            Pick("claim", "Say it as a position."),
            Pick("run", "Keep it operating."),
            Pick("argue", "Say it with reasons."),
            Pick("tend", "Keep it in good order.")]),
    Shortlist("purchase", [Pick("buy", "The plain word for the act."),
            Pick("get", "Shortest verb that fits."),
            Pick("acquire", "Get it into your hands.")]),
    Shortlist("assist", [Pick("help", "The plain word for the act."),
            Pick("aid", "Give support to a cause."),
            Pick("back", "Support it from behind."),
            Pick("serve", "Do the work for someone.")]),
    Shortlist("attempt", [Pick("try", "Shortest verb that fits."),
            Pick("seek", "Try to obtain it."),
            Pick("aim", "Direct effort at a goal."),
            Pick("test", "Try it to see what happens.")]),
    Shortlist("verify", [Pick("check", "Shortest verb that fits."),
            Pick("test", "Try it to confirm behaviour."),
            Pick("prove", "Show that it holds."),
            Pick("confirm", "Check it and agree."),
            Pick("ensure", "Make certain it is so.")]),
    Shortlist("prohibit", [Pick("ban", "Short, direct verb."),
            Pick("block", "Stop it from happening."),
            Pick("stop", "Bring it to a halt."),
            Pick("bar", "Keep it out by rule."),
            Pick("forbid", "Say it must not happen."),
            Pick("deny", "Refuse to allow it.")]),
    Shortlist("anticipate", [Pick("expect", "The plainer verb."),
            Pick("plan", "Prepare for what may come."),
            Pick("foresee", "See it coming."),
            Pick("await", "Wait for it to arrive."),
            Pick("predict", "Say it will happen."),
            Pick("reckon", "Expect it in an informal register."),
            Pick("suspect", "Think it likely without proof.")]),
    Shortlist("transmit", [Pick("send", "The plain word for the act."),
            Pick("pass", "Hand or carry it along."),
            Pick("issue", "Send it out officially."),
            Pick("relay", "Send it onward."),
            Pick("carry", "Move it from place to place."),
            Pick("broadcast", "Send it to many at once.")]),
    Shortlist("accommodate", [Pick("fit", "Shortest verb that fits."),
            Pick("hold", "Have room for it."),
            Pick("take", "Accept it into the space."),
            Pick("serve", "Meet the need of someone."),
            Pick("suit", "Fit the needs of someone."),
            Pick("help", "Adjust so it works.")]),
    Shortlist("disseminate", [Pick("share", "Shortest verb that fits."),
            Pick("spread", "Send it out widely."),
            Pick("issue", "Release it officially."),
            Pick("publish", "Make it public."),
            Pick("post", "Put it where others read it."),
            Pick("air", "Make it heard in public.")]),
    Shortlist("comprehend", [Pick("grasp", "Shortest verb that fits."),
            Pick("see", "Understand it plainly."),
            Pick("know", "Hold it as knowledge."),
            Pick("follow", "Keep pace with the reasoning.")]),
    Shortlist("substantiate", [Pick("prove", "Shortest verb that fits."),
            Pick("back", "Give support to the claim."),
            Pick("show", "Make the case visible."),
            Pick("support", "Hold the claim up.")]),
    Shortlist("endeavor", [Pick("try", "Shortest verb that fits."),
            Pick("strive", "Try hard toward a goal."),
            Pick("seek", "Try to reach it."),
            Pick("work", "Put effort into it.")]),
    Shortlist("expedite", [Pick("speed", "Set a faster pace."),
            Pick("rush", "Move it along quickly."),
            Pick("push", "Drive it forward."),
            Pick("ease", "Remove what slows it down.")]),
    Shortlist("necessitate", [Pick("need", "Shortest verb that fits."),
            Pick("force", "Make it unavoidable."),
            Pick("cause", "Bring it about."),
            Pick("bring", "Lead to the same result.")]),
    Shortlist("formulate", [Pick("frame", "Put it into words."),
            Pick("draft", "Write a first version."),
            Pick("plan", "Lay out the steps."),
            Pick("shape", "Give it a clear form."),
            Pick("write", "Set it down in words.")]),
    Shortlist("ascertain", [Pick("find", "Shortest verb that fits."),
            Pick("learn", "Come to know it."),
            Pick("check", "Look it up and confirm."),
            Pick("confirm", "Make sure it is true."),
            Pick("see", "Look and know.")]),
    Shortlist("initiate", [Pick("start", "Shortest verb that fits."),
            Pick("open", "Begin a session or event."),
            Pick("launch", "Start it with intent."),
            Pick("begin", "Plain verb for the first step."),
            Pick("form", "Bring the first shape into being.")]),
    Shortlist("relocate", [Pick("move", "The plain word for the act."),
            Pick("shift", "Move it a short way."),
            Pick("house", "Give it a new home.")]),
    Shortlist("inquire", [Pick("ask", "Shortest verb that fits."),
            Pick("query", "Ask it of a system or person."),
            Pick("seek", "Look for the answer.")]),
    Shortlist("additional", [Pick("more", "Shortest word that fits."),
            Pick("extra", "Something beyond the usual."),
            Pick("spare", "An unused one held in reserve."),
            Pick("further", "More of the same kind."),
            Pick("other", "A different one besides.")]),
    Shortlist("sufficient", [Pick("enough", "The plain word for the amount."),
            Pick("ample", "More than enough."),
            Pick("plenty", "A comfortable amount."),
            Pick("full", "Complete for the purpose.")]),
    Shortlist("numerous", [Pick("many", "The plain word for the count."),
            Pick("several", "More than two, not many."),
            Pick("countless", "Too many to count."),
            Pick("plenty", "A generous number.")]),
    Shortlist("approximately", [Pick("about", "The plain word for the estimate."),
            Pick("near", "Close to the value."),
            Pick("roughly", "Rough but useful."),
            Pick("almost", "Not quite the value."),
            Pick("around", "In the region of.")]),
    Shortlist("currently", [Pick("now", "Shortest word that fits."),
            Pick("today", "At the present day.")]),
    Shortlist("consequently", [Pick("so", "Shortest word that fits."),
            Pick("thus", "As a result, in one word."),
            Pick("hence", "For that reason."),
            Pick("then", "Following from that.")]),
    Shortlist("utilization", [Pick("use", "Shortest word that fits."),
            Pick("role", "The part it plays."),
            Pick("usage", "The way it is used.")]),
];

/// ASCII-only lowercasing keeps UTF-32 offsets stable for non-ASCII text.
private dchar asciiLower(dchar value) @safe pure nothrow @nogc
{
    return value >= 'A' && value <= 'Z' ? value + ('a' - 'A') : value;
}

private bool isWordChar(dchar value) @safe pure nothrow @nogc
{
    return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') ||
        (value >= '0' && value <= '9') || value == '\'' || value == '-';
}

/// Lowercased UTF-8 view of a UTF-32 slice, for table keys.
private string loweredKey(const(dchar)[] slice) @safe pure
{
    dchar[] buffer;
    buffer.reserve(slice.length);
    foreach (value; slice) buffer ~= asciiLower(value);
    return toUTF8(buffer);
}

private bool matchesAt(const(dchar)[] window, size_t position, string key)
    @safe pure nothrow @nogc
{
    if (position + key.length > window.length) return false;
    foreach (offset, char expected; key)
        if (asciiLower(window[position + offset]) != expected) return false;
    return true;
}

private bool wordStartAt(const(dchar)[] window, size_t position)
    @safe pure nothrow @nogc
{
    return position == 0 || !isWordChar(window[position - 1]);
}

private bool wordEndAt(const(dchar)[] window, size_t position)
    @safe pure nothrow @nogc
{
    return position >= window.length || !isWordChar(window[position]);
}

/** Count words in `text` the way the card reports it (space-separated runs). */
int wordCount(string text) @safe pure nothrow
{
    int count;
    bool inside;
    foreach (char value; text)
    {
        const space = value == ' ' || value == '\t' || value == '\n' ||
            value == '\r';
        if (space) inside = false;
        else if (!inside) { inside = true; ++count; }
    }
    return count;
}

/// Word count for a UTF-32 document or span.
int countWords(const(dchar)[] text) @safe pure nothrow @nogc
{
    int count;
    bool inside;
    foreach (value; text)
    {
        const space = value == ' ' || value == '\t' || value == '\n' ||
            value == '\r';
        if (space) inside = false;
        else if (!inside) { inside = true; ++count; }
    }
    return count;
}

private size_t sentenceStart(const(dchar)[] document, size_t caret)
    @safe pure nothrow @nogc
{
    const floorIndex = caret > sentenceReach ? caret - sentenceReach : 0;
    auto index = caret;
    while (index > floorIndex)
    {
        const value = document[index - 1];
        if (value == '.' || value == '!' || value == '?' || value == '\n')
            break;
        --index;
    }
    return index;
}

private size_t sentenceEnd(const(dchar)[] document, size_t caret)
    @safe pure nothrow @nogc
{
    const ceiling = document.length < caret + sentenceReach
        ? document.length : caret + sentenceReach;
    auto index = caret;
    while (index < ceiling)
    {
        const value = document[index];
        if (value == '.' || value == '!' || value == '?' || value == '\n')
            break;
        ++index;
    }
    return index;
}

private bool isTerminator(dchar value) @safe pure nothrow @nogc
{
    return value == '.' || value == '!' || value == '?' || value == '\n';
}

/**
 * The sentence around `offset`, as UTF-8, used as model context.
 *
 * Callers pass the offset of the span being rewritten. When that lands on a
 * terminator or at the very end of the document (the ordinary state right after
 * typing a full stop) the finished sentence is the useful context, so the
 * lookup steps back onto its last content unit instead of returning nothing.
 */
string sentenceAround(const(dchar)[] document, size_t offset) @safe pure
{
    if (document.length == 0) return "";
    if (offset > document.length) offset = document.length;
    auto start = sentenceStart(document, offset);
    auto finish = sentenceEnd(document, offset);
    auto text = toUTF8(document[start .. finish]).stripSpaces;
    if (text.length > 0) return text;

    auto anchor = offset;
    while (anchor > 0 && (isTerminator(document[anchor - 1]) ||
        document[anchor - 1] == ' ' || document[anchor - 1] == '\t'))
        --anchor;
    if (anchor == 0) return "";
    start = sentenceStart(document, anchor - 1);
    finish = sentenceEnd(document, anchor);
    return toUTF8(document[start .. finish]).stripSpaces;
}

private string stripSpaces(string value) @safe pure nothrow
{
    auto start = 0;
    auto finish = value.length;
    while (start < finish && (value[start] == ' ' || value[start] == '\t' ||
        value[start] == '\n' || value[start] == '\r')) ++start;
    while (finish > start && (value[finish - 1] == ' ' || value[finish - 1] == '\t' ||
        value[finish - 1] == '\n' || value[finish - 1] == '\r')) --finish;
    return value[start .. finish];
}

/**
 * Index of the longest table key with a space that covers the caret, or -1.
 *
 * `start`/`finish` receive the window span, so the caller never re-searches and
 * no probe string is allocated per candidate position.
 */
private ptrdiff_t phraseCovering(const(dchar)[] window, size_t caretLocal,
    out size_t start, out size_t finish) @safe pure nothrow @nogc
{
    ptrdiff_t best = -1;
    size_t bestLength;
    start = 0;
    finish = 0;

    foreach (index, ref phrase; phrases)
    {
        if (phrase.key.length <= bestLength) continue;
        bool spaced;
        foreach (char value; phrase.key) if (value == ' ') { spaced = true; break; }
        if (!spaced) continue;
        if (window.length < phrase.key.length) continue;

        const last = window.length - phrase.key.length;
        for (size_t position = 0; position <= last; ++position)
        {
            if (caretLocal < position) break;
            // The caret may sit exactly after the phrase's last letter, which
            // is where it lands the moment the user finishes typing it.
            if (caretLocal > position + phrase.key.length) continue;
            if (!matchesAt(window, position, phrase.key)) continue;
            if (!wordStartAt(window, position) ||
                !wordEndAt(window, position + phrase.key.length)) continue;
            best = cast(ptrdiff_t) index;
            bestLength = phrase.key.length;
            start = position;
            finish = position + phrase.key.length;
            break;
        }
    }
    return best;
}

/// The word containing the caret, or the word that ends at it.
private bool wordSpan(const(dchar)[] window, size_t caretLocal,
    out size_t start, out size_t end) @safe pure nothrow @nogc
{
    start = caretLocal;
    end = caretLocal;
    if (window.length == 0) return false;

    // The caret sits inside a word only while editing mid-word; the common
    // state after typing a word (or a word plus a space) is caret == end.
    if (caretLocal < window.length && isWordChar(window[caretLocal]))
        ++end;
    while (start > 0 && isWordChar(window[start - 1])) --start;
    while (end < window.length && isWordChar(window[end])) ++end;
    return end > start;
}

private ptrdiff_t exactPhrase(string key) @safe pure nothrow
{
    foreach (index, ref phrase; phrases)
        if (phrase.key == key) return cast(ptrdiff_t) index;
    return -1;
}

private enum Inflection : ubyte { none, plural, past, gerund }

/// Match the regular inflections the table keys are written without.
private ptrdiff_t inflectedPhrase(string key, out Inflection form)
    @safe pure nothrow
{
    form = Inflection.none;
    const entry = exactPhrase(key);
    if (entry >= 0) return entry;

    struct Candidate { string suffix; Inflection form; }
    static immutable Candidate[] candidates = [
        Candidate("ies", Inflection.plural),
        Candidate("es", Inflection.plural),
        Candidate("s", Inflection.plural),
        Candidate("ed", Inflection.past),
        Candidate("ing", Inflection.gerund),
    ];
    foreach (ref candidate; candidates)
    {
        if (key.length <= candidate.suffix.length) continue;
        if (key[$ - candidate.suffix.length .. $] != candidate.suffix) continue;
        const stem = key[0 .. $ - candidate.suffix.length];
        // Silent-e verbs drop the e before -ed/-ing/-es ("utilize" gives
        // "utilizing", not "utilizeing"), so the stem is tried both ways.
        auto found = exactPhrase(stem);
        if (found < 0 && stem.length > 0) found = exactPhrase(stem ~ "e");
        if (found < 0) continue;
        form = candidate.form;
        return found;
    }
    return -1;
}

/// Apply an inflection to one replacement word.
private string inflect(string word, Inflection form) @safe pure nothrow
{
    if (form == Inflection.none || word.length == 0) return word;
    const last = word[$ - 1];
    final switch (form)
    {
        case Inflection.none:
            return word;
        case Inflection.plural:
            if (last == 's' || last == 'x' || last == 'z' || last == 'h')
                return word ~ "es";
            if (last == 'y' && word.length > 1 &&
                !(word[$ - 2] == 'a' || word[$ - 2] == 'e' ||
                    word[$ - 2] == 'i' || word[$ - 2] == 'o' ||
                    word[$ - 2] == 'u'))
                return word[0 .. $ - 1] ~ "ies";
            return word ~ "s";
        case Inflection.past:
            return last == 'e' ? word ~ "d" : word ~ "ed";
        case Inflection.gerund:
            // "use" -> "using", "apply" -> "applying": drop a silent e, keep
            // y. Doubling a final consonant after a short vowel ("get") is a
            // spelling rule the table avoids needing.
            return last == 'e' && (word.length < 2 || word[$ - 2] != 'e')
                ? word[0 .. $ - 1] ~ "ing" : word ~ "ing";
    }
}

/// Build choices for a matched entry, inflecting single-word keys on demand.
private ConciseChoice[] choicesFor(ptrdiff_t phraseIndex, Inflection form)
    @safe pure
{
    ConciseChoice[] result;
    const key = phrases[cast(size_t) phraseIndex].key;
    addPicks(result, phrases[cast(size_t) phraseIndex].picks, form);
    foreach (ref entry; shortlists)
        if (entry.key == key) addPicks(result, entry.picks, form);
    return result;
}

private void addPicks(ref ConciseChoice[] result, const(Pick)[] picks,
    Inflection form) @safe pure
{
    foreach (ref pick; picks)
    {
        if (result.length >= maxChoices) return;
        string text = pick.text;
        // An empty pick is a documented deletion; never inflect it.
        if (text.length > 0 && form != Inflection.none && !hasSpace(text))
            text = inflect(text, form);
        bool duplicate;
        foreach (ref existing; result)
            if (lowerEquals(existing.text, text)) { duplicate = true; break; }
        if (duplicate) continue;
        result ~= ConciseChoice(text, pick.gloss, wordCount(text), false);
    }
}

private bool lowerEquals(string left, string right) @safe pure nothrow @nogc
{
    if (left.length != right.length) return false;
    foreach (index, char value; left)
        if (asciiLower(value) != asciiLower(right[index])) return false;
    return true;
}

/// Keep only rewrites that are at least as short as the span they replace.
private ConciseChoice[] conciseOnly(ConciseChoice[] choices, int targetWords)
    @safe pure nothrow
{
    ConciseChoice[] kept;
    foreach (choice; choices)
        if (choice.words <= targetWords) kept ~= choice;
    return kept.length > 0 ? kept : choices;
}

unittest
{
    // The card promises a shortlist, so the most common verbose words must
    // really produce six to eight concise choices, never a longer replacement.
    foreach (key; ["demonstrate", "eliminate", "require", "anticipate",
            "accommodate", "transmit"])
    {
        const analysis = analyzeInstant(("We " ~ key ~ " it now.").toUTF32, 5);
        assert(analysis.target == key);
        assert(analysis.choices.length >= 6,
            key ~ " offered only " ~ to!string(analysis.choices.length));
        assert(analysis.choices.length <= maxChoices);
        foreach (ref choice; analysis.choices)
        {
            assert(choice.words <= wordCount(analysis.target),
                key ~ " offered a longer rewrite: " ~ choice.text);
            assert(choice.words <= maxChoiceWords);
            assert(choice.gloss.length > 0);
        }
    }
}

private bool hasSpace(string value) @safe pure nothrow @nogc
{
    foreach (char value2; value) if (value2 == ' ') return true;
    return false;
}

unittest
{
    // A plain verbose verb offers its shorter picks and defines the original.
    const document = "We utilize the tool daily.".toUTF32;
    // "We " is three units, so indices 3..9 are "utilize" and 6 is inside it.
    const analysis = analyzeInstant(document, 6);
    assert(analysis.valid());
    assert(analysis.target == "utilize");
    assert(analysis.start == 3 && analysis.end == 10);
    assert(analysis.definition == "To put something to practical use.");
    assert(analysis.choices[0].text == "use");
    assert(analysis.choices[0].words == 1);
    assert(!analysis.choices[0].refined);
    assert(analysis.origin == "instant");
}

unittest
{
    // The caret resting right after the word (the typing state) still resolves.
    const document = "We utilize".toUTF32;
    const analysis = analyzeInstant(document, document.length);
    assert(analysis.target == "utilize");
    assert(analysis.choices[0].text == "use");
}

unittest
{
    // A wordy phrase outranks its own words and spans the whole phrase.
    const document = "It failed due to the fact that we left.".toUTF32;
    const caret = "It failed due to the fact".length; // inside the phrase
    const analysis = analyzeInstant(document, caret);
    assert(analysis.target == "due to the fact that",
        "phrase span not resolved: " ~ analysis.target);
    assert(analysis.start == 10);
    // "due to the fact that" is 20 units long, so the span is [10, 30).
    assert(analysis.end == 30);
    assert(analysis.end - analysis.start == 20);
    assert(analysis.choices[0].text == "because");
}

unittest
{
    // Regular inflections reuse the table and inflect the replacement.
    const plural = analyzeInstant("She utilizes it.".toUTF32, 8);
    assert(plural.target == "utilizes");
    assert(plural.choices[0].text == "uses");

    const gerund = analyzeInstant("We are utilizing it.".toUTF32, 12);
    assert(gerund.target == "utilizing");
    assert(gerund.choices[0].text == "using");

    const past = analyzeInstant("They utilized it.".toUTF32, 9);
    assert(past.target == "utilized");
    assert(past.choices[0].text == "used");
}

unittest
{
    // An intensifier offers deletion, which the card renders as "cut".
    const analysis = analyzeInstant("It was very late.".toUTF32, 9);
    assert(analysis.target == "very");
    assert(analysis.choices[0].text.length == 0);
    assert(analysis.choices[0].words == 0);
}

unittest
{
    // An unknown word still reports its span so the model can refine it, and
    // never invents a local rewrite.
    const analysis = analyzeInstant("We calibrate the rig.".toUTF32, 7);
    assert(analysis.target == "calibrate");
    assert(analysis.choices.length == 0);
    assert(!analysis.valid());
}

unittest
{
    // Nothing to optimize at a blank document or below the length floor.
    assert(!analyzeInstant("".toUTF32, 0).valid());
    const tiny = analyzeInstant("I go.".toUTF32, 2);
    assert(tiny.target.length == 0 || tiny.choices.length == 0);
}

unittest
{
    assert(wordCount("") == 0);
    assert(wordCount("one") == 1);
    assert(wordCount("  one   two  ") == 2);
    assert(wordCount("a b c d e f g h") == 8);
}

unittest
{
    // The model prompt gets the sentence that holds the caret, trimmed.
    const document = "First one. We utilize sand. Last one.".toUTF32;
    assert(sentenceAround(document, 14) == "We utilize sand");
    assert(sentenceAround(document, 0) == "First one");
    assert(sentenceAround(document, document.length) == "Last one");
    // Right after the final full stop (the state the writer is usually in) the
    // finished sentence is still the context.
    const finished = "First one. We utilize sand.".toUTF32;
    assert(sentenceAround(finished, finished.length) == "We utilize sand");
    // Offset 27 in `document` starts the next sentence, which is the right
    // context there even though the previous one just ended.
    assert(sentenceAround(document, 27) == "Last one");
    // And a document that contains only a full stop has no sentence to give.
    assert(sentenceAround(".".toUTF32, 1) == "");
}

unittest
{
    // Every table entry stays inside the product's shape: ASCII key, at least
    // one pick, no more than `maxChoices`, choices no longer than 8 words, and
    // a one-sentence definition.
    foreach (ref phrase; phrases)
    {
        assert(phrase.key.length > 0);
        foreach (char value; phrase.key)
            assert(value >= 'a' && value <= 'z' || value == ' ',
                "table keys are ASCII lowercase: " ~ phrase.key);
        assert(phrase.definition.length > 0, phrase.key ~ " has no definition");
        assert(phrase.picks.length > 0 && phrase.picks.length <= maxChoices,
            phrase.key ~ " has the wrong number of picks");
        foreach (ref pick; phrase.picks)
        {
            assert(wordCount(pick.text) <= maxChoiceWords,
                phrase.key ~ " offers an oversized choice: " ~ pick.text);
            assert(pick.gloss.length > 0, phrase.key ~ " has an unglossed pick");
        }
    }
}

/// The instant pass. Pure and allocation-light: safe on every keystroke.
Analysis analyzeInstant(const(dchar)[] document, size_t caret) @safe pure
{
    Analysis result;
    result.origin = "instant";
    if (document.length == 0) return result;

    if (caret > document.length) caret = document.length;
    const windowStart = sentenceStart(document, caret);
    const windowEnd = sentenceEnd(document, caret);
    const window = document[windowStart .. windowEnd];
    const caretLocal = caret - windowStart;

    // Phrase pass first: a wordy phrase is the stronger finding.
    size_t phraseStart, phraseEnd;
    const phraseIndex = phraseCovering(window, caretLocal, phraseStart,
        phraseEnd);
    if (phraseIndex >= 0)
    {
        result.start = windowStart + phraseStart;
        result.end = windowStart + phraseEnd;
        result.target = toUTF8(document[result.start .. result.end]).stripSpaces;
        result.definition = phrases[cast(size_t) phraseIndex].definition;
        result.choices = conciseOnly(choicesFor(phraseIndex, Inflection.none),
            wordCount(result.target));
        result.status = "Instant";
        return result;
    }

    size_t start, finish;
    if (!wordSpan(window, caretLocal, start, finish)) return result;
    const key = loweredKey(window[start .. finish]);
    if (key.length < 3) return result;

    Inflection form;
    const phraseIndex2 = inflectedPhrase(key, form);
    if (phraseIndex2 >= 0)
    {
        result.start = windowStart + start;
        result.end = windowStart + finish;
        result.target = toUTF8(document[result.start .. result.end]).stripSpaces;
        result.definition = phrases[cast(size_t) phraseIndex2].definition;
        result.choices = conciseOnly(choicesFor(phraseIndex2, form),
            wordCount(result.target));
        result.status = "Instant";
        return result;
    }

    result.start = windowStart + start;
    result.end = windowStart + finish;
    result.target = toUTF8(document[result.start .. result.end]).stripSpaces;
    result.status = "";
    return result;
}
