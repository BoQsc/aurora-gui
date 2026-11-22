module http_smoke;

import opencodelite.http : Cancellation, streamSse;
import std.stdio : stderr, writeln;

int main(string[] args)
{
    if (args.length < 2)
    {
        stderr.writeln("usage: http-smoke <sse-url>");
        return 2;
    }
    auto cancellation = new Cancellation();
    int events;
    const body = `{"model":"mock","stream":true,`
        ~ `"messages":[{"role":"user","content":"hello"}]}`;
    const result = streamSse(args[1],
        "Content-Type: application/json\r\n"
        ~ "Accept: text/event-stream\r\n",
        body,
        (string data) {
            ++events;
            writeln("data: ", data);
            if (events == 1)
                cancellation.cancel();
        },
        cancellation);
    writeln("status=", result.status,
        " events=", result.events,
        " canceled=", result.canceled,
        " error=", result.error);
    return result.status == 200 && result.events >= 1 && result.canceled
        ? 0 : 1;
}
