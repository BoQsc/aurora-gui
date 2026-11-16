module aurora.dragdrop;

/** Operation negotiated between a drag source and its eventual drop target. */
enum DragAction : uint
{
    none = 0,
    copy = 1u << 0,
    move = 1u << 1,
    link = 1u << 2
}

alias DragActions = uint;

DragActions dragActions(DragAction[] actions...) @safe pure nothrow @nogc
{
    DragActions result;
    foreach (action; actions)
        result |= cast(DragActions) action;
    return result;
}

bool allowsDragAction(DragActions actions, DragAction action)
    @safe pure nothrow @nogc
{
    return action != DragAction.none &&
        (actions & cast(DragActions) action) != 0;
}

/**
 * Arbitrary rich drag data. `mimeType` is the portable identity; native
 * adapters map well-known types to their platform clipboard formats and keep
 * unknown types available under an Aurora-owned registered format.
 */
struct DragFormat
{
    string mimeType;
    ubyte[] data;

    this(string mimeType, const(ubyte)[] data)
    {
        this.mimeType = mimeType;
        this.data = data.dup;
    }
}

/** Platform-neutral payload used for both inbound and outbound drags. */
struct DragPayload
{
    string[] paths;
    dstring text;
    string[] uris;
    DragFormat[] formats;

    bool empty() const @safe pure nothrow @nogc
    {
        return paths.length == 0 && text.length == 0 && uris.length == 0 &&
            formats.length == 0;
    }

    bool hasFormat(string mimeType) const @safe pure nothrow @nogc
    {
        foreach (format; formats)
            if (format.mimeType == mimeType) return true;
        return false;
    }

    const(ubyte)[] formatData(string mimeType) const
        @safe pure nothrow @nogc
    {
        foreach (ref const format; formats)
            if (format.mimeType == mimeType) return format.data;
        return null;
    }

    DragPayload duplicate() const
    {
        DragPayload result;
        result.paths.reserve(paths.length);
        foreach (path; paths) result.paths ~= path.dup;
        result.text = text.idup;
        result.uris.reserve(uris.length);
        foreach (uri; uris) result.uris ~= uri.dup;
        result.formats.reserve(formats.length);
        foreach (format; formats)
            result.formats ~= DragFormat(format.mimeType.dup, format.data);
        return result;
    }
}

DragAction preferredDragAction(DragActions allowed, DragAction requested)
    @safe pure nothrow @nogc
{
    if (allowsDragAction(allowed, requested)) return requested;
    if (allowsDragAction(allowed, DragAction.copy)) return DragAction.copy;
    if (allowsDragAction(allowed, DragAction.move)) return DragAction.move;
    if (allowsDragAction(allowed, DragAction.link)) return DragAction.link;
    return DragAction.none;
}

unittest
{
    auto allowed = dragActions(DragAction.copy, DragAction.move);
    assert(allowsDragAction(allowed, DragAction.copy));
    assert(!allowsDragAction(allowed, DragAction.link));
    assert(preferredDragAction(allowed, DragAction.link) == DragAction.copy);

    DragPayload payload;
    payload.paths = ["one.txt"];
    payload.text = "hello"d;
    payload.formats ~= DragFormat("application/x-aurora-test", [1, 2, 3]);
    auto copy = payload.duplicate();
    payload.paths[0] = "changed";
    payload.formats[0].data[0] = 9;
    assert(copy.paths[0] == "one.txt");
    assert(copy.formatData("application/x-aurora-test")[0] == 1);
}
