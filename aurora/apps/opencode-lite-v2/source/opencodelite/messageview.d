module opencodelite.messageview;

import aurora : Color, Widget;
import aurora.types : Rect;
import aurorahost.component : ComponentContext, ComponentFactory;
import aurorahost.host_editor : EditorTextStyle, HostTextEditor;
import std.datetime : SysTime;
import std.file : exists, readText, timeLastModified, write;
import std.conv : to;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.process : environment;
import std.string : splitLines, strip;
import std.utf : toUTF32;

/// Scrollable message surface fed by the controller's formatted conversation
/// file. The scene owns layout; the controller owns message content.
final class MessageListView : Widget
{
    private HostTextEditor _editor;
    private string _path;
    private string _scrollPath;
    private SysTime _stamp;
    private int _savedScroll;
    private int _lastSavedScroll = -1;

    this(string path)
    {
        _path = path.length > 0 ? path : buildPath(
            environment.get("LOCALAPPDATA", ""),
            "AuroraOpenCodeLiteV2", "conversation.txt");
        _scrollPath = _path ~ ".scroll";
        if (exists(_scrollPath))
            try _savedScroll = to!int(readText(_scrollPath).strip);
            catch (Exception) {}
        _editor = new HostTextEditor("No messages yet.");
        _editor.setReadOnly(true);
        _editor.setWordWrap(false);
        _editor.setPadding(10);
        _editor.setShowBorder(false);
        add(_editor);
        reload();
    }

    private void reload()
    {
        if (!exists(_path))
            return;
        try
        {
            const stamp = timeLastModified(_path);
            if (stamp == _stamp) return;
            _stamp = stamp;
            const text = readText(_path);
            _editor.setText(text);
            applyRoleStyles(text);
            if (_savedScroll > 0)
                _editor.restoreScrollLine(_savedScroll);
            invalidate();
        }
        catch (Exception)
        {
        }
    }

    private void applyRoleStyles(string text)
    {
        EditorTextStyle[] styles;
        string prefix;
        foreach (line; text.splitLines)
        {
            const role = (line.length >= 3 && line[0 .. 3] == "YOU") ||
                (line.length >= 9 && line[0 .. 9] == "ASSISTANT") ||
                (line.length >= 6 && line[0 .. 6] == "SYSTEM");
            if (role)
            {
                EditorTextStyle style;
                style.start = toUTF32(prefix).length;
                style.end = style.start + toUTF32(line).length;
                style.color = Color.rgba(105, 210, 168, 255);
                styles ~= style;
            }
            else
            {
                const trimmed = line.strip;
                bool hasActivityColor;
                Color activityColor;
                if (hasPrefix(trimmed, "▸") || hasPrefix(trimmed, "Tool") ||
                    hasPrefix(trimmed, "Thinking") ||
                    hasPrefix(trimmed, "Activity"))
                {
                    activityColor = Color.rgba(224, 184, 108, 255);
                    hasActivityColor = true;
                }
                else if (hasPrefix(trimmed, "ERROR") ||
                    hasPrefix(trimmed, "STOPPED"))
                {
                    activityColor = Color.rgba(232, 126, 126, 255);
                    hasActivityColor = true;
                }
                else if (hasPrefix(trimmed, "PLAN") ||
                    hasPrefix(trimmed, "Goal"))
                {
                    activityColor = Color.rgba(186, 156, 232, 255);
                    hasActivityColor = true;
                }
                if (hasActivityColor)
                {
                    EditorTextStyle style;
                    style.start = toUTF32(prefix).length;
                    style.end = style.start + toUTF32(line).length;
                    style.color = activityColor;
                    styles ~= style;
                }
                else
                {
                const code = (line.length > 0 &&
                    (line[0 .. 1] == " " || line[0 .. 1] == "\t")) ||
                    hasPrefix(line, "python") || hasPrefix(line, "import ") ||
                    hasPrefix(line, "from ") || hasPrefix(line, "for ") ||
                    hasPrefix(line, "if ") || hasPrefix(line, "def ") ||
                    hasPrefix(line, "class ") || hasPrefix(line, "const ") ||
                    hasPrefix(line, "auto ") || hasPrefix(line, "return ");
                if (code)
                {
                    EditorTextStyle style;
                    style.start = toUTF32(prefix).length;
                    style.end = style.start + toUTF32(line).length;
                    style.color = Color.rgba(132, 178, 224, 255);
                    styles ~= style;
                }
                }
            }
            prefix ~= line ~ "\n";
        }
        _editor.setTextStyles(styles);
    }

    private static bool hasPrefix(string value, string prefix)
    {
        return value.length >= prefix.length &&
            value[0 .. prefix.length] == prefix;
    }

    protected override void onLayout()
    {
        _editor.setBounds(Rect(0, 0, bounds().width, bounds().height));
    }

    protected override void onTick(double deltaSeconds)
    {
        reload();
        const line = _editor.scrollLine();
        if (line != _lastSavedScroll)
        {
            _lastSavedScroll = line;
            try write(_scrollPath, to!string(line));
            catch (Exception) {}
        }
    }
}

ComponentFactory messageListFactory()
{
    return delegate(ComponentContext context, JSONValue props)
    {
        string path;
        if (auto value = "path" in props.object)
            if ((*value).type == JSONType.string)
                path = (*value).str;
        return new MessageListView(path);
    };
}
