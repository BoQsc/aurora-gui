module auroraopencode.filecontext;

// Remove this module and all filecontext:begin/end regions in appui.d and
// core.d. The optional sidecars are independent of conversation history.
import auroraopencode.core : ChatMessage, ChatSession, activeMessagePath;
import auroraopencode.markdown : looksLikeLocalPath;
import auroraopencode.systemprompt : SystemPromptModule, textModule;
import auroraopencode.logging : logError;
import std.algorithm : canFind, sort;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.file : exists, isDir, mkdirRecurse, readText, rename, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;
import std.process : environment;
import std.string : indexOf, lastIndexOf, replace, startsWith, strip, toLower;
import std.uri : decodeComponent;
import std.utf : toUTF32;

public SystemPromptModule fileContextPromptModule()
{
    return textModule("smartFileContext",
        "\n## File references\n" ~
        "For every file or folder you mention, provide its absolute filesystem " ~
        "path or a Markdown link whose target is the absolute path. Short relative " ~
        "labels are fine when the link carries the full target. Use the actual " ~
        "tool workspace to resolve relative paths, including paths outside it; " ~
        "never invent a location. Keep web and remote resource URLs intact. " ~
        "Apply this rule only to actual filesystem references, never slash-separated " ~
        "concepts, alternatives, API names, version numbers or specification sections. " ~
        "Do not invent links or paths to satisfy the rule. Use an explicit ./ prefix " ~
        "or an absolute link for extensionless directories. When a reference is " ~
        "ambiguous, ask for its base folder. Before sending, check that every local " ~
        "link names the intended file and that ordinary prose remains plain text.\n");
}

public struct FileReferenceSpan
{
    size_t begin, end;
    dstring text;
}

private bool pathChar(dchar ch)
{
    return ch > 127 || (ch >= 'a' && ch <= 'z') ||
        (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
        "_-. /\\:~+@%#"d.canFind(ch) && ch != ' ';
}

// Includes bare filenames and quoted paths with spaces. Ordinary words are
// candidates only: resolveReference accepts them solely when they exist.
public FileReferenceSpan[] fileReferenceSpans(dstring text)
{
    FileReferenceSpan[] result;
    size_t i;
    while (i < text.length)
    {
        const quote = text[i];
        if (quote == '`' || quote == '"' || quote == '\'' || quote == '<')
        {
            const closing = quote == '<' ? '>' : quote;
            size_t end = i + 1;
            while (end < text.length && text[end] != closing && text[end] != '\n') ++end;
            if (end < text.length && text[end] == closing)
            {
                const candidate = text[i + 1 .. end];
                if (looksLikeLocalPath(candidate) || filenameLike(candidate))
                {
                    result ~= FileReferenceSpan(i + 1, end, candidate);
                    i = end + 1;
                    continue;
                }
            }
        }
        if (!pathChar(text[i])) { ++i; continue; }
        const begin = i;
        while (i < text.length && pathChar(text[i])) ++i;
        size_t end = i;
        while (end > begin && ".,:;!?"d.canFind(text[end - 1])) --end;
        if (end > begin) result ~= FileReferenceSpan(begin, end, text[begin .. end]);
    }
    return result;
}

private bool filenameLike(dstring text)
{
    if (text.length == 0 || text.canFind(' ') || text.canFind(':')) return false;
    if (text[0] == '.' && text.length > 1 && text[1] != '.') return true;
    const dot = text.lastIndexOf('.');
    if (dot <= 0 || dot + 1 >= text.length || text.length - dot > 17) return false;
    foreach (ch; text[cast(size_t) dot + 1 .. $])
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
            (ch >= '0' && ch <= '9'))) return false;
    return true;
}

public bool fileContextResourceUrl(string value)
{
    return value.indexOf("://") > 1 && !value.toLower.startsWith("file://");
}

// Line/column suffixes belong to the reference, not the filesystem name.
public string absoluteFileTarget(string value, string base)
{
    value = value.strip;
    if (value.length == 0 || fileContextResourceUrl(value)) return "";
    try
    {
        if (value.toLower.startsWith("file://"))
        {
            value = decodeComponent(value[7 .. $]);
            if (value.startsWith("localhost/")) value = value[10 .. $];
            else if (!value.startsWith("/")) value = "\\\\" ~ value;
            if (value.length > 3 && value[0] == '/' && value[2] == ':') value = value[1 .. $];
        }
        auto suffix = value.lastIndexOf("#L");
        if (suffix >= 0) value = value[0 .. cast(size_t) suffix];
        foreach (_; 0 .. 2)
        {
            const colon = value.lastIndexOf(':');
            if (colon <= 1 || colon + 1 >= value.length) break;
            bool numeric = true;
            foreach (ch; value[cast(size_t) colon + 1 .. $])
                if (ch < '0' || ch > '9') numeric = false;
            if (!numeric) break;
            value = value[0 .. cast(size_t) colon];
        }
        if (value.startsWith("~/") || value.startsWith("~\\"))
        {
            const home = environment.get("USERPROFILE", environment.get("HOME", ""));
            if (home.length == 0) return "";
            value = buildPath(home, value[2 .. $]);
        }
        // A drive-relative path has no reliable meaning without that drive's
        // own cwd; do not silently treat it as an absolute target.
        if (value.length >= 2 && value[1] == ':' &&
            (value.length < 3 || (value[2] != '/' && value[2] != '\\'))) return "";
        foreach (i, ch; value)
            if (ch == ':' && i != 1 || ch == '\n' || ch == '\r' || ch == '*'
                || ch == '?' || ch == '"' || ch == '<' || ch == '>' || ch == '|') return "";
        if (base.length == 0) return "";
        return buildNormalizedPath(absolutePath(value, absolutePath(base)));
    }
    catch (Exception) return "";
}

public struct FileReference
{
    string mention, target;
    bool tool;
}

private struct MessageContext
{
    string base;
    FileReference[] references;
    // Transient cache: equality is cheap for unchanged immutable text.
    string content, args;
    bool scanned;
}

private class ConversationContext
{
    string manualFolder;
    string[] activeMessages;
    MessageContext[string] messages;
    bool dirty;
}

public struct FolderCandidate { string path; size_t score; }

public final class FileContextStore
{
    private string directory;
    private ConversationContext[string] conversations;
    this(string directory) { this.directory = directory; }

    private string path(string id)
    {
        return buildPath(directory, toHexString(sha256Of(id)) ~ ".json");
    }

    private ConversationContext context(string id)
    {
        if (auto found = id in conversations) return *found;
        auto value = new ConversationContext();
        conversations[id] = value;
        try
        {
            if (!exists(path(id))) return value;
            auto root = parseJSON(readText(path(id)));
            if (root.type != JSONType.object) return value;
            if (auto field = "manualFolder" in root.object)
                if (field.type == JSONType.string) value.manualFolder = field.str;
            if (auto field = "activeMessages" in root.object)
                if (field.type == JSONType.array)
                    foreach (item; field.array)
                        if (item.type == JSONType.string) value.activeMessages ~= item.str;
            if (auto field = "messages" in root.object)
                if (field.type == JSONType.object)
                    foreach (key, item; field.object)
                    {
                        if (item.type != JSONType.object) continue;
                        MessageContext message;
                        if (auto base = "base" in item.object)
                            if (base.type == JSONType.string) message.base = base.str;
                        if (auto refs = "references" in item.object)
                            if (refs.type == JSONType.array)
                                foreach (refValue; refs.array)
                                {
                                    if (refValue.type != JSONType.object) continue;
                                    auto mention = "mention" in refValue.object;
                                    auto target = "target" in refValue.object;
                                    if (mention is null || target is null || mention.type != JSONType.string ||
                                        target.type != JSONType.string) continue;
                                    bool tool;
                                    if (auto flag = "tool" in refValue.object) tool = flag.type == JSONType.true_;
                                    // Discard metadata created by older, overly broad
                                    // slash-count recognition instead of reviving it.
                                    if (!tool && !validProseReference(mention.str, target.str))
                                    { value.dirty = true; continue; }
                                    message.references ~= FileReference(mention.str, target.str, tool);
                                }
                        value.messages[key] = message;
                    }
        }
        catch (Exception error) { logError("File context load: " ~ error.msg); }
        return value;
    }

    private string key(const ref ChatMessage message)
    {
        // Graph messages always have ids. The fallback is for legacy rows only.
        return message.id.length ? message.id : toHexString(sha256Of(message.role ~ message.content ~ message.toolArgs)).idup;
    }

    public void rememberBase(string id, const ref ChatMessage message, string workspace)
    {
        if (!id.length || message.internal) return;
        auto entry = context(id);
        const messageId = key(message);
        if (messageId in entry.messages) return;
        MessageContext initial;
        initial.base = absoluteFileTarget(".", workspace);
        entry.messages[messageId] = initial;
        entry.dirty = true;
    }

    public void capture(string id, const ref ChatMessage message, string workspace)
    {
        if (id.length == 0 || message.internal) return;
        auto entry = context(id);
        const messageId = key(message);
        auto saved = messageId in entry.messages;
        if (saved !is null && saved.scanned && saved.content == message.content && saved.args == message.toolArgs) return;
        if (saved is null)
        {
            rememberBase(id, message, workspace);
            saved = messageId in entry.messages;
        }
        const previous = saved.references.dup;
        saved.references = null;
        saved.content = message.content;
        saved.args = message.toolArgs;
        saved.scanned = true;
        void accept(string mention, bool tool = false)
        {
            auto target = tool ? absoluteFileTarget(mention, saved.base) : resolveCandidate(mention, saved.base);
            foreach (old; previous)
                if (old.mention == mention) { target = old.target; break; }
            if (target.length == 0) return;
            foreach (ref old; saved.references)
                if (old.mention == mention)
                {
                    if (tool && !old.tool) { old.tool = true; entry.dirty = true; }
                    return;
                }
            saved.references ~= FileReference(mention, target, tool);
        }
        // File contents in tool output are not evidence of a conversation's
        // subject. Structured path arguments are much stronger evidence.
        if (message.role != "tool")
        {
            foreach (span; fileReferenceSpans(toUTF32(message.content))) accept(to!string(span.text));
            size_t cursor;
            while (cursor < message.content.length)
            {
                const start = message.content.indexOf("](", cursor);
                if (start < 0) break;
                const end = message.content.indexOf(')', cast(size_t) start + 2);
                if (end < 0) break;
                auto target = message.content[cast(size_t) start + 2 .. cast(size_t) end].strip;
                if (target.startsWith("<") && target.length > 1 && target[$ - 1] == '>') target = target[1 .. $ - 1];
                accept(target);
                cursor = cast(size_t) end + 1;
            }
        }
        if (message.role == "tool")
            try
            {
                auto args = parseJSON(message.toolArgs);
                if (args.type == JSONType.object)
                {
                    foreach (name; ["filePath", "path", "source", "destinationFolder", "cwd", "workdir"])
                        if (auto field = name in args.object)
                            if (field.type == JSONType.string) accept(field.str, true);
                    if (message.toolName == "open")
                        if (auto field = "target" in args.object)
                            if (field.type == JSONType.string) accept(field.str, true);
                    if (auto field = "sources" in args.object)
                        if (field.type == JSONType.array)
                            foreach (source; field.array)
                                if (source.type == JSONType.string) accept(source.str, true);
                    if (message.toolName == "apply_patch")
                        if (auto field = "patch" in args.object)
                            if (field.type == JSONType.string)
                            {
                                import std.string : splitLines;
                                foreach (line; field.str.splitLines)
                                    foreach (prefix; ["*** Add File:", "*** Update File:", "*** Delete File:", "*** Move to:"])
                                        if (line.startsWith(prefix)) accept(line[prefix.length .. $].strip, true);
                            }
                }
            }
            catch (Exception) {}
        if (previous != saved.references) entry.dirty = true;
    }

    private bool validProseReference(string mention, string target)
    {
        if (looksLikeLocalPath(toUTF32(mention)) || filenameLike(toUTF32(mention))) return true;
        try return exists(target);
        catch (Exception) return false;
    }

    private string resolveCandidate(string mention, string base)
    {
        const target = absoluteFileTarget(mention, base);
        if (target.length == 0) return "";
        return validProseReference(mention, target) ? target : "";
    }

    public string resolve(string id, const ref ChatMessage message, string mention, string workspace)
    {
        if (id.length == 0) return resolveCandidate(mention, workspace);
        rememberBase(id, message, workspace);
        auto entry = context(id);
        if (auto saved = key(message) in entry.messages)
        {
            foreach (refValue; saved.references)
                if (refValue.mention == mention) return refValue.target;
            const target = resolveCandidate(mention, saved.base);
            if (target.length)
            {
                saved.references ~= FileReference(mention, target, message.role == "tool");
                entry.dirty = true;
            }
            return target;
        }
        return "";
    }

    public void captureSession(const ref ChatSession session, string workspace)
    {
        foreach (ref message; session.messages) capture(session.id, message, workspace);
        if (!session.messages.length) return; // Unloaded sidebar rows use persisted evidence.
        string[] active;
        foreach (index; activeMessagePath(session)) active ~= key(session.messages[index]);
        auto entry = context(session.id);
        if (entry.activeMessages != active) { entry.activeMessages = active; entry.dirty = true; }
    }

    public string referenceAt(string id, const ref ChatMessage message,
        dstring text, size_t character, string workspace)
    {
        rememberBase(id, message, workspace);
        auto saved = key(message) in context(id).messages;
        string target;
        size_t longest;
        if (saved !is null)
            foreach (refValue; saved.references)
            {
                const mention = toUTF32(refValue.mention);
                const begin = text.indexOf(mention);
                if (begin >= 0 && character >= begin && character < begin + mention.length && mention.length > longest)
                { target = refValue.target; longest = mention.length; }
            }
        if (target.length) return target;
        foreach (span; fileReferenceSpans(text))
            if (character >= span.begin && character < span.end)
                return resolve(id, message, to!string(span.text), workspace);
        return "";
    }

    public FileReference[] references(string id, const ref ChatMessage message, string workspace)
    {
        capture(id, message, workspace);
        auto saved = key(message) in context(id).messages;
        return saved is null ? null : saved.references.dup;
    }

    public FolderCandidate[] candidates(const ref ChatSession session, string workspace)
    {
        captureSession(session, workspace);
        size_t[string] scores;
        string[string] folderNames;
        auto entry = context(session.id);
        foreach (messageId; entry.activeMessages)
        {
            auto saved = messageId in entry.messages;
            if (saved is null) continue;
            bool[string] counted;
            foreach (refValue; saved.references)
            {
                string folder;
                try
                {
                    folder = exists(refValue.target) && isDir(refValue.target)
                        ? refValue.target : dirName(refValue.target);
                    if (!exists(folder)) continue;
                    // Group sibling directories at their repository boundary.
                    auto ancestor = folder;
                    while (ancestor != dirName(ancestor))
                    {
                        if (exists(buildPath(ancestor, ".git"))) { folder = ancestor; break; }
                        ancestor = dirName(ancestor);
                    }
                    if (folder == dirName(folder)) continue;
                }
                catch (Exception) { continue; }
                const identity = folder.replace("/", "\\").toLower;
                if (identity in counted) continue;
                counted[identity] = true;
                scores[identity] += refValue.tool ? 3 : 1;
                folderNames[identity] = folder;
            }
        }
        FolderCandidate[] result;
        foreach (identity, score; scores) result ~= FolderCandidate(folderNames[identity], score);
        result.sort!((a, b) => a.score == b.score ? a.path < b.path : a.score > b.score);
        return result;
    }

    public string mainFolder(const ref ChatSession session, string workspace)
    {
        const manual = context(session.id).manualFolder;
        if (manual.length) return manual;
        auto ranked = candidates(session, workspace);
        if (ranked.length && (ranked.length == 1 || ranked[0].score > ranked[1].score)) return ranked[0].path;
        return absoluteFileTarget(".", workspace);
    }

    public bool setMainFolder(string id, string folder, string workspace)
    {
        const target = absoluteFileTarget(folder, workspace);
        try { if (!exists(target) || !isDir(target)) return false; }
        catch (Exception) { return false; }
        auto entry = context(id);
        entry.manualFolder = target;
        entry.dirty = true;
        return true;
    }

    public void redetect(string id)
    {
        auto entry = context(id);
        entry.manualFolder = "";
        entry.dirty = true;
    }

    public void copyConversation(const ref ChatSession source, const ref ChatSession copy, string workspace)
    {
        captureSession(source, workspace);
        auto old = context(source.id);
        auto fresh = context(copy.id);
        fresh.manualFolder = old.manualFolder;
        foreach (index, ref message; copy.messages)
        {
            if (index >= source.messages.length) break;
            if (auto saved = key(source.messages[index]) in old.messages)
            {
                auto cloned = *saved;
                cloned.references = saved.references.dup;
                fresh.messages[key(message)] = cloned;
            }
        }
        fresh.dirty = true;
        captureSession(copy, workspace);
    }

    // Call on the UI thread to take immutable snapshots, then write on the
    // existing snapshot worker. Nothing is written from layout or painting.
    public void delegate() pendingWrite()
    {
        string[string] pending;
        foreach (id, entry; conversations)
        {
            if (!entry.dirty) continue;
            JSONValue root;
            root["version"] = 1;
            root["manualFolder"] = entry.manualFolder;
            root["activeMessages"] = entry.activeMessages;
            JSONValue[string] messageRows;
            JSONValue messages = JSONValue(messageRows);
            foreach (key, saved; entry.messages)
            {
                JSONValue item;
                item["base"] = saved.base;
                JSONValue refs = JSONValue(JSONValue[].init);
                foreach (refValue; saved.references)
                {
                    JSONValue row;
                    row["mention"] = refValue.mention;
                    row["target"] = refValue.target;
                    row["tool"] = refValue.tool;
                    refs.array ~= row;
                }
                item["references"] = refs;
                messages[key] = item;
            }
            root["messages"] = messages;
            pending[path(id)] = root.toString;
            entry.dirty = false;
        }
        const destination = directory;
        return delegate()
        {
            foreach (file, content; pending)
                try
                {
                    mkdirRecurse(destination);
                    const temporary = file ~ ".tmp";
                    write(temporary, content);
                    rename(temporary, file);
                }
                catch (Exception error) { logError("File context save: " ~ error.msg); }
        };
    }
}
