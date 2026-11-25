module opencodelite.messages;

import std.string : indexOf, splitLines, strip;
import std.conv : to;

struct ChatMessage
{
    string id;
    string role;
    string timestamp;
    string body;
}

/// Parse the stored transcript into stable role/timestamp messages.
/// The transcript format is intentionally tolerant: role markers without a
/// timestamp still produce a message, and text before the first marker is kept
/// as a system message.
ChatMessage[] parseTranscript(string transcript)
{
    ChatMessage[] messages;
    ChatMessage current;
    current.role = "system";
    size_t ordinal;

    void flush()
    {
        current.body = current.body.strip;
        if (current.body.length > 0 || current.role != "system")
        {
            current.id = "msg-" ~ (
                to!string(ordinal));
            messages ~= current;
            ++ordinal;
        }
        current = ChatMessage();
        current.role = "system";
    }

    foreach (line; transcript.splitLines)
    {
        const you = line.indexOf("] You:");
        const assistant = line.indexOf("] Assistant:");
        const marker = you >= 0 ? you : assistant;
        if (marker >= 0)
        {
            flush();
            current.role = you >= 0 ? "user" : "assistant";
            const stampStart = line.indexOf("[");
            if (stampStart >= 0 && stampStart < marker)
                current.timestamp = line[stampStart + 1 .. marker].strip;
            const bodyStart = line.indexOf(":", marker) + 1;
            current.body = bodyStart > 0 && bodyStart < line.length
                ? line[bodyStart .. $] : "";
        }
        else
        {
            if (current.body.length > 0)
                current.body ~= "\n";
            current.body ~= line;
        }
    }
    flush();
    return messages;
}

unittest
{
    const transcript = "[2026-01-01 10:00:00] You: hello\n" ~
        "[2026-01-01 10:00:01] Assistant: hi\nsecond line";
    auto messages = parseTranscript(transcript);
    assert(messages.length == 2);
    assert(messages[0].role == "user");
    assert(messages[1].role == "assistant");
    assert(messages[1].body == "hi\nsecond line");
}
