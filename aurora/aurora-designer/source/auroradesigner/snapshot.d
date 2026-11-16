module auroradesigner.snapshot;

import auroradesigner.model : DesignDocument, Node, NodeKind;
import core.stdc.string : memcpy;
import std.string : fromStringz;

/**
 * Fixed-layout, pointer-free editor state for cross-process handoff.
 *
 * The live `DesignDocument` uses GC strings and `int[]` children, so it cannot
 * cross a process boundary. A snapshot copies every field into fixed buffers
 * and stores children in one flat array. Node identity is the stable string id,
 * not the array index.
 */
enum ulong SnapshotMagic = 0x4155524F44534E31; // "AURODSN1"
enum int SnapshotVersion = 1;
enum int MaxSnapshotNodes = 4096;
enum int MaxSnapshotChildren = 8192;
enum int SnapshotNameChars = 64;
enum int SnapshotIdChars = 64;
enum int SnapshotTextChars = 256;
enum int SnapshotColorChars = 16;

struct SnapshotNode
{
    int kind;
    char[SnapshotNameChars] name;
    char[SnapshotIdChars] id;
    int x;
    int y;
    int width;
    int height;
    int childStart;
    int childCount;
    char[SnapshotTextChars] text;
    char[SnapshotColorChars] colorHex;
    bool transparent;
    bool accent;
    bool checked;
}

struct SnapshotHeader
{
    ulong magic;
    int schema;
    int canvasWidth;
    int canvasHeight;
    int nodeCount;
    int root;
    int childCount;
    char[SnapshotIdChars] selectedId;
}

struct DocumentSnapshot
{
    SnapshotHeader header;
    SnapshotNode[MaxSnapshotNodes] nodes;
    int[MaxSnapshotChildren] children;

}

private void putString(size_t N)(ref char[N] dst, const(char)[] value)
{
    size_t i;
    for (; i < value.length && i < N - 1; ++i)
        dst[i] = value[i];
    for (; i < N; ++i)
        dst[i] = 0;
}

private string getString(size_t N)(const ref char[N] src)
{
    return fromStringz(cast(const(char)*) src.ptr).idup;
}

/** Build a POD snapshot from a live document and a selected node index. */
DocumentSnapshot* snapshotOf(const ref DesignDocument document, int selectedIndex)
{
    if (document.nodes.length > MaxSnapshotNodes)
        throw new Exception("document exceeds the snapshot node capacity");
    if (document.root < -1 ||
        (document.root >= 0 && document.root >= cast(int) document.nodes.length))
        throw new Exception("document root is out of range");

    auto snapshot = new DocumentSnapshot;
    snapshot.header.magic = SnapshotMagic;
    snapshot.header.schema = SnapshotVersion;
    snapshot.header.canvasWidth = document.canvasWidth;
    snapshot.header.canvasHeight = document.canvasHeight;
    snapshot.header.nodeCount = cast(int) document.nodes.length;
    snapshot.header.root = document.root;

    if (selectedIndex >= 0 && selectedIndex < cast(int) document.nodes.length)
        putString(snapshot.header.selectedId,
            document.nodes[selectedIndex].id);

    int childCount;
    foreach (i, node; document.nodes)
    {
        auto dst = &snapshot.nodes[i];
        dst.kind = cast(int) node.kind;
        putString(dst.name, node.name);
        putString(dst.id, node.id);
        dst.x = node.x;
        dst.y = node.y;
        dst.width = node.width;
        dst.height = node.height;
        dst.childStart = childCount;
        dst.childCount = cast(int) node.children.length;
        putString(dst.text, node.text);
        putString(dst.colorHex, node.colorHex);
        dst.transparent = node.transparent;
        dst.accent = node.accent;
        dst.checked = node.checked;

        if (childCount + node.children.length > MaxSnapshotChildren)
            throw new Exception("document exceeds the snapshot child capacity");
        foreach (child; node.children)
        {
            if (child < 0 || child >= cast(int) document.nodes.length)
                throw new Exception("document child index is out of range");
            snapshot.children[childCount++] = child;
        }
    }
    snapshot.header.childCount = childCount;
    return snapshot;
}

/** Resolve a node id to its current array index, or -1. */
int indexOfId(const ref DesignDocument document, string id)
{
    if (id.length == 0) return -1;
    foreach (i, node; document.nodes)
        if (node.id == id) return cast(int) i;
    return -1;
}

/** Rebuild a live document and the selected index from a snapshot. */
void restoreInto(const DocumentSnapshot* snapshot,
    out DesignDocument document, out int selectedIndex)
{
    if (snapshot is null) throw new Exception("snapshot is null");
    if (snapshot.header.magic != SnapshotMagic)
        throw new Exception("bad snapshot magic");
    if (snapshot.header.schema != SnapshotVersion)
        throw new Exception("unsupported snapshot version");
    if (snapshot.header.nodeCount < 0 ||
        snapshot.header.nodeCount > MaxSnapshotNodes)
        throw new Exception("snapshot node count is out of range");
    if (snapshot.header.childCount < 0 ||
        snapshot.header.childCount > MaxSnapshotChildren)
        throw new Exception("snapshot child count is out of range");
    if (snapshot.header.root < -1 ||
        (snapshot.header.root >= 0 &&
         snapshot.header.root >= snapshot.header.nodeCount))
        throw new Exception("snapshot root is out of range");

    document = DesignDocument.init;
    document.canvasWidth = snapshot.header.canvasWidth;
    document.canvasHeight = snapshot.header.canvasHeight;
    document.root = snapshot.header.root;
    document.nodes.length = snapshot.header.nodeCount;

    foreach (i; 0 .. snapshot.header.nodeCount)
    {
        const src = &snapshot.nodes[i];
        auto node = &document.nodes[i];
        if (src.kind < 0 || src.kind > cast(int) NodeKind.max)
            throw new Exception("snapshot node kind is out of range");
        node.kind = cast(NodeKind) src.kind;
        node.name = getString(src.name);
        node.id = getString(src.id);
        node.x = src.x;
        node.y = src.y;
        node.width = src.width;
        node.height = src.height;
        node.text = getString(src.text);
        node.colorHex = getString(src.colorHex);
        node.transparent = src.transparent;
        node.accent = src.accent;
        node.checked = src.checked;

        if (src.childStart < 0 || src.childCount < 0 ||
            src.childStart + src.childCount > snapshot.header.childCount)
            throw new Exception("snapshot child range is out of bounds");
        node.children.length = src.childCount;
        foreach (k; 0 .. src.childCount)
        {
            const child = snapshot.children[src.childStart + k];
            if (child < 0 || child >= snapshot.header.nodeCount)
                throw new Exception("snapshot child index is out of range");
            node.children[k] = child;
        }
    }

    selectedIndex = indexOfId(document, getString(snapshot.header.selectedId));
}

/** Compact byte size: header plus the used node and child slots only. */
size_t snapshotByteSize(const DocumentSnapshot* snapshot)
{
    if (snapshot is null) return 0;
    return SnapshotHeader.sizeof +
        snapshot.header.nodeCount * SnapshotNode.sizeof +
        snapshot.header.childCount * int.sizeof;
}

/** Serialize the used portion; trailing capacity is not copied. */
ubyte[] snapshotToBytes(const DocumentSnapshot* snapshot)
{
    if (snapshot is null) throw new Exception("snapshot is null");
    auto bytes = new ubyte[snapshotByteSize(snapshot)];
    memcpy(bytes.ptr, &snapshot.header, SnapshotHeader.sizeof);
    if (snapshot.header.nodeCount != 0)
        memcpy(bytes.ptr + SnapshotHeader.sizeof, snapshot.nodes.ptr,
            snapshot.header.nodeCount * SnapshotNode.sizeof);
    if (snapshot.header.childCount != 0)
        memcpy(bytes.ptr + SnapshotHeader.sizeof +
            snapshot.header.nodeCount * SnapshotNode.sizeof,
            snapshot.children.ptr, snapshot.header.childCount * int.sizeof);
    return bytes;
}

/** Parse a compact snapshot; rejects truncation, bad magic and bad counts. */
DocumentSnapshot* snapshotFromBytes(const(ubyte)[] bytes)
{
    if (bytes.length < SnapshotHeader.sizeof)
        throw new Exception("snapshot is truncated");

    SnapshotHeader header;
    memcpy(&header, bytes.ptr, SnapshotHeader.sizeof);
    if (header.magic != SnapshotMagic)
        throw new Exception("bad snapshot magic");
    if (header.schema != SnapshotVersion)
        throw new Exception("unsupported snapshot version");
    if (header.nodeCount < 0 || header.nodeCount > MaxSnapshotNodes)
        throw new Exception("snapshot node count is out of range");
    if (header.childCount < 0 || header.childCount > MaxSnapshotChildren)
        throw new Exception("snapshot child count is out of range");

    const expected = SnapshotHeader.sizeof +
        header.nodeCount * SnapshotNode.sizeof +
        header.childCount * int.sizeof;
    if (bytes.length != expected)
        throw new Exception("snapshot size does not match its header");

    auto snapshot = new DocumentSnapshot;
    snapshot.header = header;
    if (header.nodeCount != 0)
        memcpy(snapshot.nodes.ptr, bytes.ptr + SnapshotHeader.sizeof,
            header.nodeCount * SnapshotNode.sizeof);
    if (header.childCount != 0)
        memcpy(snapshot.children.ptr, bytes.ptr + SnapshotHeader.sizeof +
            header.nodeCount * SnapshotNode.sizeof,
            header.childCount * int.sizeof);
    return snapshot;
}
