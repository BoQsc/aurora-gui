module snapshot_test;

import auroradesigner.model : DesignDocument, NodeKind;
import auroradesigner.snapshot;
import std.exception : assertThrown;
import std.stdio : writeln;

void main()
{
    DesignDocument doc;
    doc.canvasWidth = 1024;
    doc.canvasHeight = 768;

    const root = doc.addNode(NodeKind.window, 0, 0);
    const panel = doc.addNode(NodeKind.panel, 40, 40);
    const button = doc.addNode(NodeKind.button, 60, 80);
    doc.root = root;
    doc.nodes[root].children ~= panel;
    doc.nodes[panel].children ~= button;
    doc.nodes[panel].name = "Main panel";
    doc.nodes[button].name = "Primary action";
    doc.nodes[button].text = "Click me";
    doc.nodes[button].colorHex = "#FFAA33";
    doc.nodes[button].accent = true;
    doc.nodes[button].checked = true;

    auto snapshot = snapshotOf(doc, button);
    auto bytes = snapshotToBytes(snapshot);
    if (bytes.length != snapshotByteSize(snapshot))
        throw new Exception("compact size mismatch");
    if (bytes.length >= DocumentSnapshot.sizeof)
        throw new Exception("snapshot did not compact its capacity");

    auto parsed = snapshotFromBytes(bytes);
    DesignDocument restored;
    int selected;
    restoreInto(parsed, restored, selected);

    if (restored.canvasWidth != 1024 || restored.canvasHeight != 768)
        throw new Exception("canvas dimensions were not preserved");
    if (restored.root != root || restored.nodes.length != doc.nodes.length)
        throw new Exception("document shape was not preserved");
    if (restored.nodes[panel].name != "Main panel")
        throw new Exception("panel name was not preserved");
    if (restored.nodes[panel].children.length != 1 ||
        restored.nodes[panel].children[0] != button)
        throw new Exception("child range was not preserved");
    if (restored.nodes[button].id != doc.nodes[button].id)
        throw new Exception("stable node id was not preserved");
    if (restored.nodes[button].text != "Click me" ||
        restored.nodes[button].colorHex != "#FFAA33" ||
        !restored.nodes[button].accent || !restored.nodes[button].checked)
        throw new Exception("node properties were not preserved");
    if (selected != button || restored.nodes[selected].id != doc.nodes[button].id)
        throw new Exception("selection was not restored by id");

    // Selection is identity-based: a different node order must not change which
    // node the id resolves to.
    DesignDocument reordered;
    reordered.canvasWidth = doc.canvasWidth;
    reordered.canvasHeight = doc.canvasHeight;
    reordered.root = 0;
    reordered.nodes.length = 3;
    reordered.nodes[0] = doc.nodes[button];
    reordered.nodes[0].children.length = 0;
    reordered.nodes[1] = doc.nodes[root];
    reordered.nodes[1].children = [2];
    reordered.nodes[2] = doc.nodes[panel];
    reordered.nodes[2].children = [0];
    if (indexOfId(reordered, doc.nodes[button].id) != 0)
        throw new Exception("id lookup depends on node order");

    DesignDocument emptySelection;
    int none;
    restoreInto(snapshotOf(doc, -1), emptySelection, none);
    if (none != -1)
        throw new Exception("empty selection was not preserved");

    auto bad = bytes.dup;
    bad[0] = 0;
    assertThrown!Exception(snapshotFromBytes(bad));
    assertThrown!Exception(snapshotFromBytes(bytes[0 .. $ - 1]));

    writeln("PASS designer snapshot");
    writeln("nodes=", restored.nodes.length,
        " children=", parsed.header.childCount,
        " bytes=", bytes.length,
        " selected=", restored.nodes[selected].id);
}
