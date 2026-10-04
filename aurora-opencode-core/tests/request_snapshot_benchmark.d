module auroraopencode_request_snapshot_benchmark;

import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent;
import auroraopencode.core : ChatRequestMessage, ChatImageAttachment;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.array : replicate;
import std.stdio : writeln;

int main(string[] args)
{
    assert(args.length == 2);
    auto client = new OpenCodeClient(args[1], "original-key");
    scope (exit) client.closeSession();
    ChatRequestMessage message;
    message.role = "user";
    message.content = replicate("x", 8 * 1024 * 1024);
    message.reasoningContent = replicate("r", 8 * 1024 * 1024);
    ChatImageAttachment image;
    image.mimeType = "image/png";
    image.base64Data = replicate("A", 8 * 1024 * 1024);
    message.images ~= image;
    foreach (trial; 0 .. 3)
    {
        const began = MonoTime.currTime;
        client.startChatMessages([message], null, "snapshot", false);
        const micros = (MonoTime.currTime - began).total!"usecs";
        writeln("snapshot_us=", micros);
        const deadline = MonoTime.currTime + seconds(30);
        OpenCodeEvent[] events;
        while (client.busy() && MonoTime.currTime < deadline)
        {
            client.drain(events);
            Thread.sleep(5.msecs);
        }
        assert(!client.busy());
        client.drain(events);
    }
    return 0;
}
