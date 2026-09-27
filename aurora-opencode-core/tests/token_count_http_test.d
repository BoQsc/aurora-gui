module auroraopencode_core_token_count_http;

import auroraopencode.core : ChatRequestMessage;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent,
    OpenCodeEventKind;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.socket : AddressFamily, InternetAddress, ProtocolType, Socket,
    SocketOption, SocketOptionLevel, SocketType, TcpSocket;
import std.stdio : writeln;
import std.string : indexOf, splitLines, startsWith, strip;

private struct CapturedRequest
{
    string path;
    string body;
}

private CapturedRequest readRequest(Socket socket)
{
    string wire;
    ubyte[4096] buffer;
    size_t headerEnd;
    size_t contentLength;
    while (true)
    {
        const received = socket.receive(buffer[]);
        enforce(received > 0, "mock client closed before request completed");
        wire ~= cast(string) buffer[0 .. cast(size_t) received];
        const marker = wire.indexOf("\r\n\r\n");
        if (marker < 0) continue;
        headerEnd = cast(size_t) marker + 4;
        foreach (line; wire[0 .. cast(size_t) marker].splitLines())
        {
            if (!line.startsWith("Content-Length:")) continue;
            contentLength = line["Content-Length:".length .. $].strip().to!size_t;
            break;
        }
        if (wire.length >= headerEnd + contentLength) break;
    }

    const firstLineEnd = wire.indexOf("\r\n");
    const firstLine = wire[0 .. cast(size_t) firstLineEnd];
    const firstSpace = firstLine.indexOf(' ');
    const secondSpace = firstLine[firstSpace + 1 .. $].indexOf(' ');
    CapturedRequest result;
    result.path = firstLine[firstSpace + 1 .. firstSpace + 1 + secondSpace];
    result.body = wire[headerEnd .. headerEnd + contentLength];
    return result;
}

private void sendResponse(Socket socket, string contentType, string body)
{
    const response = "HTTP/1.1 200 OK\r\nContent-Type: " ~ contentType ~
        "\r\nContent-Length: " ~ to!string(body.length) ~
        "\r\nConnection: close\r\n\r\n" ~ body;
    size_t sent;
    while (sent < response.length)
    {
        const count = socket.send(response[sent .. $]);
        enforce(count > 0, "mock response write failed");
        sent += cast(size_t) count;
    }
}

private void enforce(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

int main()
{
    auto listener = new TcpSocket(AddressFamily.INET);
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    listener.bind(new InternetAddress("127.0.0.1", 0));
    listener.listen(2);
    const port = (cast(InternetAddress) listener.localAddress()).port;

    CapturedRequest[2] captured;
    Exception serverFailure;
    auto server = new Thread({
        try
        {
            foreach (index; 0 .. 2)
            {
                auto connection = listener.accept();
                scope (exit) connection.close();
                captured[index] = readRequest(connection);
                if (index == 0)
                    sendResponse(connection, "application/json",
                        `{"object":"response.input_tokens","input_tokens":321}`);
                else
                    sendResponse(connection, "text/event-stream",
                        "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n" ~
                        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]," ~
                        "\"usage\":{\"prompt_tokens\":321,\"completion_tokens\":1," ~
                        "\"total_tokens\":322}}\n\n" ~
                        "data: [DONE]\n\n");
            }
        }
        catch (Exception error)
        {
            serverFailure = error;
        }
        listener.close();
    });
    server.start();

    auto client = new OpenCodeClient(
        "http://127.0.0.1:" ~ to!string(port) ~ "/v1", "");
    ChatRequestMessage user;
    user.role = "user";
    user.content = "Count this exact Qwen request.";
    client.startChatMessages([user], null, "Qwen/Qwen3.8-27B", false,
        42, "", 0, true);

    OpenCodeEvent[] drained;
    OpenCodeEvent[] events;
    const deadline = MonoTime.currTime + 10.seconds;
    bool done;
    while (!done && MonoTime.currTime < deadline)
    {
        client.drain(drained);
        foreach (event; drained)
        {
            events ~= event;
            if (event.kind == OpenCodeEventKind.done) done = true;
        }
        Thread.sleep(10.msecs);
    }
    server.join();
    client.closeSession();
    if (serverFailure !is null) throw serverFailure;

    assert(done, "client did not finish the mock chat");
    assert(captured[0].path == "/v1/chat/completions/input_tokens",
        "tokenizer-only endpoint was not called first: " ~ captured[0].path);
    assert(captured[1].path == "/v1/chat/completions",
        "completion endpoint was not called second: " ~ captured[1].path);
    assert(captured[0].body == captured[1].body,
        "counting and inference received different request JSON");

    bool sawPreflight;
    bool sawFinalUsage;
    foreach (event; events)
    {
        if (event.kind != OpenCodeEventKind.usage) continue;
        if (event.promptTokens == 321 && event.completionTokens == 0 &&
            event.totalTokens == 321)
            sawPreflight = true;
        if (event.promptTokens == 321 && event.completionTokens == 1 &&
            event.totalTokens == 322)
            sawFinalUsage = true;
    }
    assert(sawPreflight, "exact preflight count was not published to the UI");
    assert(sawFinalUsage, "final provider usage was not published");
    writeln("Exact token count uses byte-identical local request JSON");
    return 0;
}
