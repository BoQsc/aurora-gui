module opencodelite.controller;

import opencodelite.history : ConversationState, loadConversation, saveConversation;
import opencodelite.messages : parseTranscript;
import opencodelite.session : ChatSession, SessionEventKind;
import opencodelite.settings : LiteSettings, openAiBaseUrl, openAiModel,
    isOpenAiBaseUrl, isOpenCodeBaseUrl, openCodeBaseUrl, openCodeModel,
    saveSettings, defaultSettingsPath;
import std.conv : to;
import core.thread : Thread;
import core.time : seconds;
import std.array : join, split;
import std.datetime : Clock, SysTime;
import std.file : dirEntries, exists, mkdirRecurse, readText,
    SpanMode, thisExePath, timeLastModified, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName, extension;
import std.process : environment, spawnProcess;
import std.string : indexOf, replace, splitLines, strip, toLower;

/// The small host-facing surface the controller needs. Implementations are the
/// embedded registry and an external host control client.
interface LiteView
{
    string text(string id);
    bool setText(string id, string text);
    bool setEnabled(string id, bool enabled);
    bool setActive(string id, bool active);
    bool activate(string id);
    bool closeHost();
}

private struct WorkspaceSlot
{
    string transcript = "New session.\n";
    uint messages;
    string lastPrompt;
    bool failed;
}

/**
 * V2 is still host-rendered, but now owns a persistent conversation session,
 * explicit new-session/retry controls, and a richer session status.
 */
final class LiteController
{
    private LiteView _view;
    private ChatSession _session;
    private LiteSettings _settings;
    private string _transcript;
    private string _status = "Ready";
    private string _lastPrompt;
    private uint _messages;
    private bool _lastFailed;
    private WorkspaceSlot[3] _workspace;
    private string[3] _workspaceNames = ["Main", "Research", "Scratch"];
    private int _activeSlot;
    private SysTime _lastRefresh;
    private string[] _promptHistory;
    private int _historyIndex;
    private string[] _searchLines;
    private int _searchIndex;
    private string _sessionFilter;
    private int _activeSessionIndex;
    private int _sessionViewIndex = -1;
    private bool _thinkingOn = true;
    private bool _toolsOn;
    private bool _planOn;
    private bool _confirmClearKey;
    private SysTime _clearKeyDeadline;
    private bool _confirmDeleteWorkspace;
    private SysTime _deleteWorkspaceDeadline;
    private bool _confirmSaveKey;
    private SysTime _saveKeyDeadline;
    private SysTime _statusBannerUntil;
    private int _paletteIndex;
    private string _recentPaletteCommand;
    private static immutable string[5] _paletteCommands = [
        "Help", "Export", "Import", "New session", "Search"];

    this(LiteView view, LiteSettings settings)
    {
        _view = view;
        _settings = settings;
        _thinkingOn = settings.thinkingOn;
        _toolsOn = settings.toolsOn;
        _planOn = settings.planOn;
        _session = new ChatSession(_settings);
        const history = loadConversation();
        _workspace[0] = WorkspaceSlot(history.transcript, history.messages,
            history.lastPrompt, history.failed);
        loadWorkspace();
        loadActive();
        if (_lastPrompt.length > 0)
        {
            _promptHistory ~= _lastPrompt;
            _historyIndex = 1;
        }
    }

    void handleAction(string node, string action)
    {
        if (action == "send")
        {
            if (_session.busy())
                stop();
            else
                send();
        }
        else if (action == "stop")
            stop();
        else if (action == "composer-clear")
        {
            safeSetText("lite-input", "");
            setStatus("Composer cleared");
            updateSession();
        }
        else if (action == "history-prev")
            historyPrevious();
        else if (action == "history-next")
            historyNext();
        else if (action == "workspace-search")
        {
            const query = safeText("lite-search").strip;
            if (query.length == 0)
            {
                _sessionFilter = "";
                _searchLines = [];
                _searchIndex = 0;
                safeSetText("search-result", "no matches");
                setStatus("Search is empty");
                updateSession();
            }
            else
            {
                const needle = query.toLower;
                _sessionFilter = query;
                _searchLines = [];
                foreach (line; _transcript.splitLines)
                    if (line.toLower.indexOf(needle) != -1)
                        _searchLines ~= line.strip;
                foreach (name; _workspaceNames)
                    if (name.toLower.indexOf(needle) != -1)
                        _searchLines ~= "Workspace: " ~ name;
                _searchIndex = 0;
                showSearchResult(query);
                updateSession();
            }
        }
        else if (action == "search-prev")
            searchPrevious();
        else if (action == "search-next")
            searchNext();
        else if (action == "search-clear")
        {
            safeSetText("lite-search", "");
            _searchLines = [];
            _searchIndex = 0;
            _sessionFilter = "";
            safeSetText("search-result", "no matches");
            setStatus("Search cleared");
            updateSession();
        }
        else if (action == "session-pick-1")
            pickSession(0);
        else if (action == "session-pick-2")
            pickSession(1);
        else if (action == "session-pick-3")
            pickSession(2);
        else if (action == "session-all")
        {
            _sessionViewIndex = -1;
            _activeSessionIndex = 0;
            displayTranscript();
            setStatus("Full history");
            updateSession();
        }
        else if (action == "plan-open")
            setStatus("Plan: Review sandbox 2 workspace · 1/4 steps");
        else if (action == "plan-start")
        {
            if (!_session.busy())
            {
                safeSetText("lite-input",
                    "Continue the current plan from the next step.");
                setStatus("Plan continuation loaded");
                updateSession();
            }
        }
        else if (action == "toggle-thinking")
        {
            _thinkingOn = !_thinkingOn;
            _settings.thinkingOn = _thinkingOn;
            try saveSettings(_settings);
            catch (Exception) {}
            _session.updateSettings(_settings);
            setStatus("Thinking " ~ (_thinkingOn ? "on" : "off"));
            updateSession();
        }
        else if (action == "toggle-tools")
        {
            _toolsOn = !_toolsOn;
            _settings.toolsOn = _toolsOn;
            try saveSettings(_settings);
            catch (Exception) {}
            _session.updateSettings(_settings);
            setStatus("Tools " ~ (_toolsOn ? "on" : "off"));
            updateSession();
        }
        else if (action == "toggle-plan")
        {
            _planOn = !_planOn;
            _settings.planOn = _planOn;
            try saveSettings(_settings);
            catch (Exception) {}
            _session.updateSettings(_settings);
            setStatus("Plan mode " ~ (_planOn ? "on" : "off"));
            updateSession();
        }
        else if (action == "save")
            saveConnection();
        else if (action == "save-key")
        {
            const entered = safeText("lite-key").strip;
            if (_settings.apiKey.length > 0 && entered.length > 0 &&
                entered != _settings.apiKey && !_confirmSaveKey)
            {
                _confirmSaveKey = true;
                _saveKeyDeadline = Clock.currTime() + 5.seconds;
                setStatus("Confirm replace key");
                return;
            }
            _confirmSaveKey = false;
            saveKey();
        }
        else if (action == "clear-key")
        {
            if (!_confirmClearKey)
            {
                _confirmClearKey = true;
                _clearKeyDeadline = Clock.currTime() + 5.seconds;
                setStatus("Confirm clear key");
                return;
            }
            _confirmClearKey = false;
            _settings.apiKey = "";
            _settings.openCodeKey = "";
            _settings.openAiKey = "";
            try
            {
                saveSettings(_settings);
                updateKeyState();
                updateSession();
                setStatus("Key cleared");
            }
            catch (Exception error)
                setStatus("Key error: " ~ error.msg);
        }
        else if (action == "cancel-clear-key")
        {
            _confirmClearKey = false;
            setStatus("Key clear cancelled");
        }
        else if (action == "dismiss-banner")
        {
            _statusBannerUntil = SysTime.init;
            safeSetText("key-clear-toast", "");
        }
        else if (action == "help")
            setStatus("Enter sends | Shift+Enter newline | Esc stops | Ctrl+L focus");
        else if (action == "audit-text")
        {
            auditTextFit();
            setStatus("Text fit audit refreshed");
        }
        else if (action == "audit-credentials")
            auditCredentials();
        else if (action == "rebuild-request")
            requestRebuild();
        else if (action == "update-request")
            checkForUpdate();
        else if (action == "key-status")
        {
            if (safeActivate("settings-button"))
                setStatus("Settings opened");
            else
                setStatus(_settings.apiKey.length > 0 ? "Key set" : "No key");
        }
        else if (action == "palette-next")
            movePaletteFocus(1);
        else if (action == "palette-prev")
            movePaletteFocus(-1);
        else if (action == "palette-run")
            runPaletteCommand();
        else if (action == "palette-clear-recent")
            safeSetText("command-palette-recent", "Recent: none");
        else if (action == "palette-restore-recent")
        {
            safeSetText("command-palette-recent",
                _recentPaletteCommand.length > 0
                    ? "Recent: " ~ _recentPaletteCommand
                    : "Recent: none");
            setStatus("Restored recent command");
        }
        else if (action == "palette-reset-status")
        {
            _recentPaletteCommand = "";
            safeSetText("command-palette-recent", "Recent: none");
            setStatus("Ready");
        }
        else if (action == "clear")
            clearSession();
        else if (action == "retry")
            retryLast();
        else if (action == "regenerate")
            retryLast();
        else if (action == "export")
            exportSession();
        else if (action == "import")
            importSession();
        else if (action == "session-1")
            selectWorkspaceSlot(0);
        else if (action == "session-2")
            selectWorkspaceSlot(1);
        else if (action == "session-3")
            selectWorkspaceSlot(2);
        else if (action == "workspace-rename")
            renameWorkspace();
        else if (action == "workspace-new")
            newWorkspace();
        else if (action == "workspace-delete")
        {
            if (!_confirmDeleteWorkspace)
            {
                _confirmDeleteWorkspace = true;
                _deleteWorkspaceDeadline = Clock.currTime() + 5.seconds;
                setStatus("Confirm clear workspace");
                return;
            }
            _confirmDeleteWorkspace = false;
            deleteWorkspace();
        }
        else if (action == "workspace-duplicate")
            duplicateWorkspace();
        else if (action == "preset-opencode")
            applyPreset(openCodeBaseUrl, openCodeModel, "OpenCode API preset");
        else if (action == "preset-openai")
            applyPreset(openAiBaseUrl, openAiModel,
                "OpenAI-compatible preset");
        else if (action == "model-deepseek")
            applyPreset(openCodeBaseUrl, openCodeModel, "DeepSeek selected");
        else if (action == "model-gpt")
            applyPreset(openAiBaseUrl, openAiModel, "GPT-4o mini selected");
        else if (action == "reset-connection")
            resetConnection();
    }

    private void applyPreset(string baseUrl, string model, string label)
    {
        if (isOpenCodeBaseUrl(_settings.baseUrl))
            _settings.openCodeModelName = _settings.model;
        else if (isOpenAiBaseUrl(_settings.baseUrl))
            _settings.openAiModelName = _settings.model;
        rememberKey();
        _settings.baseUrl = baseUrl;
        _settings.model = isOpenCodeBaseUrl(baseUrl)
            ? (_settings.openCodeModelName.length > 0
                ? _settings.openCodeModelName : model)
            : (_settings.openAiModelName.length > 0
                ? _settings.openAiModelName : model);
        _settings.apiKey = isOpenCodeBaseUrl(baseUrl)
            ? _settings.openCodeKey
            : isOpenAiBaseUrl(baseUrl) ? _settings.openAiKey : "";
        safeSetText("lite-base", baseUrl);
        safeSetText("lite-model", _settings.model);
        safeSetText("lite-key", "");
        updateKeyState();
        setStatus(label);
        updateSession();
        try
        {
            saveSettings(_settings);
            _session.updateSettings(_settings);
        }
        catch (Exception error)
            setStatus("Settings error: " ~ error.msg);
    }

    private void resetConnection()
    {
        _settings.baseUrl = openCodeBaseUrl;
        _settings.model = _settings.openCodeModelName.length > 0
            ? _settings.openCodeModelName : openCodeModel;
        _settings.apiKey = _settings.openCodeKey;
        safeSetText("lite-base", _settings.baseUrl);
        safeSetText("lite-model", _settings.model);
        safeSetText("lite-key", "");
        try
        {
            saveSettings(_settings);
            _session.updateSettings(_settings);
            setStatus("Connection reset");
        }
        catch (Exception error)
        {
            setStatus("Reset error: " ~ error.msg);
        }
        updateKeyState();
        updateSession();
    }

    private void rememberKey()
    {
        const entered = safeText("lite-key").strip;
        if (entered.length > 0)
            _settings.apiKey = entered;
        if (isOpenCodeBaseUrl(_settings.baseUrl))
            _settings.openCodeKey = _settings.apiKey;
        else if (isOpenAiBaseUrl(_settings.baseUrl))
            _settings.openAiKey = _settings.apiKey;
    }

    private bool saveConnection()
    {
        const viewBase = safeText("lite-base").strip;
        const viewModel = safeText("lite-model").strip;
        if (viewBase.length > 0)
            _settings.baseUrl = viewBase;
        if (viewModel.length > 0)
            _settings.model = viewModel;
        if (isOpenCodeBaseUrl(_settings.baseUrl))
            _settings.openCodeModelName = _settings.model;
        else if (isOpenAiBaseUrl(_settings.baseUrl))
            _settings.openAiModelName = _settings.model;
        const validBase = (_settings.baseUrl.length >= 8 &&
            _settings.baseUrl[0 .. 8] == "https://") ||
            (_settings.baseUrl.length >= 7 &&
            _settings.baseUrl[0 .. 7] == "http://");
        if (!validBase)
        {
            setStatus("Invalid base URL");
            updateSession();
            return false;
        }
        if (_settings.model.length == 0)
        {
            setStatus("Model is required");
            updateSession();
            return false;
        }
        rememberKey();
        try
        {
            saveSettings(_settings);
            _session.updateSettings(_settings);
            safeSetText("lite-key", "");
            updateKeyState();
            setStatus("Settings saved · " ~ Clock.currTime().toString());
            return true;
        }
        catch (Exception error)
        {
            setStatus("Settings error: " ~ error.msg);
            return false;
        }
    }

    private void saveKey()
    {
        const entered = safeText("lite-key").strip;
        if (entered.length == 0)
        {
            setStatus("Enter an API key");
            return;
        }
        _settings.apiKey = entered;
        if (isOpenCodeBaseUrl(_settings.baseUrl))
            _settings.openCodeKey = entered;
        else if (isOpenAiBaseUrl(_settings.baseUrl))
            _settings.openAiKey = entered;
        try
        {
            saveSettings(_settings);
            _session.updateSettings(_settings);
            safeSetText("lite-key", "");
            updateKeyState();
            updateSession();
            setStatus("Key saved");
        }
        catch (Exception error)
            setStatus("Key error: " ~ error.msg);
    }

    private void send()
    {
        if (_session.busy())
            return;
        const prompt = safeText("lite-input").strip;
        if (prompt.length == 0)
            return;
        if (!saveConnection())
            return;
        if (_settings.apiKey.length == 0)
        {
            setStatus("Add an API key to send");
            updateSession();
            return;
        }
        _lastPrompt = prompt;
        _lastFailed = false;
        ++_messages;

        const stamp = Clock.currTime().toString();
        _sessionViewIndex = -1;
        _transcript ~= "\n[" ~ stamp ~ "] You: " ~ prompt ~
            "\n[" ~ stamp ~ "] Assistant: ";
        safeSetText("lite-input", "");
        setStatus("Waiting for response...");
        safeSetText("lite-send", "Stop");
        updateSession();
        persist();
        _session.send(prompt);
    }

    private void retryLast()
    {
        if (_lastPrompt.length == 0 || _session.busy())
            return;
        safeSetText("lite-input", _lastPrompt);
        send();
    }

    private string workspacePath()
    {
        return buildPath(dirName(defaultSettingsPath()), "workspace.json");
    }

    private void loadActive()
    {
        _transcript = _workspace[_activeSlot].transcript;
        _messages = _workspace[_activeSlot].messages;
        _lastPrompt = _workspace[_activeSlot].lastPrompt;
        _lastFailed = _workspace[_activeSlot].failed;
        _sessionViewIndex = -1;
        _activeSessionIndex = 0;
    }

    private string displayTranscript()
    {
        if (_transcript.strip.length == 0 || _transcript.strip == "New session.")
            return publishConversation(
                "No messages yet.\n\nStart a conversation below.");
        auto messages = parseTranscript(_transcript);
        if (_sessionViewIndex >= 0)
        {
            const indices = recentSessionMessageIndices();
            if (_sessionViewIndex < indices.length)
            {
                const start = indices[_sessionViewIndex];
                size_t end = messages.length;
                foreach (i; start + 1 .. messages.length)
                    if (messages[i].role == "user")
                    {
                        end = i;
                        break;
                    }
                messages = messages[start .. end];
            }
        }
        string source = _transcript;
        if (messages.length > 0)
        {
            string[] sections;
            foreach (message; messages)
            {
                const role = message.role == "user" ? "YOU" :
                    message.role == "assistant" ? "ASSISTANT" : "SYSTEM";
                sections ~= role ~
                    (message.timestamp.length > 0 ? "  ·  " ~ message.timestamp : "") ~
                    "\n" ~ message.body;
            }
            source = sections.join("\n\n");
        }
        const clean = source
            .replace("**", "")
            .replace("```", "")
            .replace("`", "")
            .replace("*", "")
            .replace("[error]", "ERROR")
            .replace("[stopped]", "STOPPED");
        if (clean.strip.length == 0)
            return "No messages yet.\n\nStart a conversation below.";
        string[] wrapped;
        foreach (line; clean.splitLines)
        {
            auto shaped = line;
            if (shaped.length >= 2 && shaped[0 .. 2] == "# ")
                shaped = shaped[2 .. $];
            else if (shaped.length >= 2 && shaped[0 .. 2] == "- ")
                shaped = "• " ~ shaped[2 .. $];
            if (shaped.length <= 80)
            {
                wrapped ~= shaped;
                continue;
            }
            string current;
            foreach (word; shaped.split(" "))
            {
                if (current.length == 0)
                    current = word;
                else if (current.length + 1 + word.length <= 80)
                    current ~= " " ~ word;
                else
                {
                    wrapped ~= current;
                    current = word;
                }
            }
            wrapped ~= current;
        }
        return publishConversation(wrapped.join("\n"));
    }

    private string publishConversation(string text)
    {
        try
        {
            const path = buildPath(environment.get("LOCALAPPDATA", ""),
                "AuroraOpenCodeLiteV2", "conversation.txt");
            write(path, text);
        }
        catch (Exception)
        {
        }
        return text;
    }

    private void syncActive()
    {
        _workspace[_activeSlot].transcript = _transcript;
        _workspace[_activeSlot].messages = _messages;
        _workspace[_activeSlot].lastPrompt = _lastPrompt;
        _workspace[_activeSlot].failed = _lastFailed;
    }

    private void loadWorkspace()
    {
        const path = workspacePath();
        if (!exists(path))
            return;
        try
        {
            const document = parseJSON(readText(path));
            if (auto rows = "slots" in document.object)
            {
                size_t index;
                foreach (row; rows.array)
                {
                    if (index >= _workspace.length)
                        break;
                    _workspace[index].transcript = row["transcript"].str;
                    _workspace[index].messages =
                        cast(uint) row["messages"].integer;
                    _workspace[index].lastPrompt = row["lastPrompt"].str;
                    _workspace[index].failed = row["failed"].get!bool;
                    ++index;
                }
            }
            if (auto active = "active" in document.object)
                _activeSlot = cast(int) active.integer;
            if (auto names = "names" in document.object)
            {
                size_t nameIndex;
                foreach (name; names.array)
                {
                    if (nameIndex >= _workspaceNames.length)
                        break;
                    if (name.type == JSONType.string)
                        _workspaceNames[nameIndex] = name.str;
                    ++nameIndex;
                }
            }
            if (_activeSlot < 0 || _activeSlot >= _workspace.length)
                _activeSlot = 0;
        }
        catch (Exception)
        {
        }
    }

    private void saveWorkspace()
    {
        try
        {
            const path = workspacePath();
            const directory = dirName(path);
            if (!exists(directory))
                mkdirRecurse(directory);
            JSONValue document;
            document["active"] = JSONValue(cast(long) _activeSlot);
            JSONValue[] nameValues;
            foreach (name; _workspaceNames)
                nameValues ~= JSONValue(name);
            document["names"] = JSONValue(nameValues);
            JSONValue[] rows;
            foreach (slot; _workspace)
            {
                JSONValue row;
                row["transcript"] = slot.transcript;
                row["messages"] = JSONValue(cast(long) slot.messages);
                row["lastPrompt"] = slot.lastPrompt;
                row["failed"] = JSONValue(slot.failed);
                rows ~= JSONValue(row);
            }
            document["slots"] = JSONValue(rows);
            write(path, document.toString() ~ "\n");
        }
        catch (Exception)
        {
        }
    }

    private void selectWorkspaceSlot(int index)
    {
        if (index < 0 || index >= _workspace.length || index == _activeSlot)
            return;
        if (_session.busy())
            _session.cancel();
        syncActive();
        _activeSlot = index;
        loadActive();
        safeSetText("lite-input", "");
        safeSetText("lite-send", "Send");
        setStatus("Workspace " ~ to!string(index + 1));
        updateSession();
        persist();
    }

    private void renameWorkspace()
    {
        const name = safeText("lite-input").strip;
        if (name.length == 0)
            return;
        _workspaceNames[_activeSlot] = name;
        safeSetText("lite-input", "");
        setStatus("Workspace renamed");
        updateSession();
        persist();
    }

    private void historyPrevious()
    {
        if (_promptHistory.length == 0)
            return;
        if (_historyIndex > 0)
            --_historyIndex;
        safeSetText("lite-input", _promptHistory[_historyIndex]);
        updateSession();
    }

    private void movePaletteFocus(int direction)
    {
        _paletteIndex = (_paletteIndex + direction +
            cast(int) _paletteCommands.length) % cast(int) _paletteCommands.length;
        safeSetText("command-palette-selected",
            "Focus: " ~ _paletteCommands[_paletteIndex]);
        setStatus("Command focus: " ~ _paletteCommands[_paletteIndex]);
    }

    private void runPaletteCommand()
    {
        switch (_paletteIndex)
        {
        case 0: handleAction("", "help"); break;
        case 1: handleAction("", "export"); break;
        case 2: handleAction("", "import"); break;
        case 3: handleAction("", "clear"); break;
        case 4: handleAction("", "workspace-search"); break;
        default: break;
        }
        _recentPaletteCommand = _paletteCommands[_paletteIndex];
        safeSetText("command-palette-recent",
            "Recent: " ~ _paletteCommands[_paletteIndex]);
    }

    private void historyNext()
    {
        if (_promptHistory.length == 0)
            return;
        if (_historyIndex < _promptHistory.length)
            ++_historyIndex;
        safeSetText("lite-input",
            _historyIndex == _promptHistory.length
                ? ""
                : _promptHistory[_historyIndex]);
        updateSession();
    }

    private void showSearchResult(string query)
    {
        if (_searchLines.length == 0)
        {
            safeSetText("search-result", "no matches");
            setStatus(query ~ ": 0 matches");
            return;
        }
        safeSetText("search-result",
            "match " ~ to!string(_searchIndex + 1) ~ "/" ~
            to!string(_searchLines.length) ~ ": " ~
            _searchLines[_searchIndex]);
        setStatus(query ~ ": match " ~ to!string(_searchIndex + 1) ~
            "/" ~ to!string(_searchLines.length));
    }

    private void pickSession(int index)
    {
        if (index < 0 || index >= _workspace.length)
            return;
        selectWorkspaceSlot(index);
    }

    private void searchPrevious()
    {
        if (_searchLines.length == 0)
            return;
        _searchIndex = (_searchIndex - 1 + cast(int) _searchLines.length) %
            cast(int) _searchLines.length;
        showSearchResult(safeText("lite-search").strip);
    }

    private void searchNext()
    {
        if (_searchLines.length == 0)
            return;
        _searchIndex = (_searchIndex + 1) % cast(int) _searchLines.length;
        showSearchResult(safeText("lite-search").strip);
    }

    private void newWorkspace()
    {
        syncActive();
        int target = -1;
        foreach (i; 0 .. _workspace.length)
            if (i != _activeSlot && _workspace[i].messages == 0 &&
                _workspace[i].transcript.strip == "New session.")
            {
                target = cast(int) i;
                break;
            }
        if (target < 0)
        {
            setStatus("No empty workspace slot");
            return;
        }
        _activeSlot = target;
        _workspace[target] = WorkspaceSlot();
        _workspaceNames[target] = "Workspace " ~ to!string(target + 1);
        loadActive();
        safeSetText("lite-input", "");
        setStatus("Created " ~ _workspaceNames[target]);
        updateSession();
        persist();
    }

    private void deleteWorkspace()
    {
        _confirmDeleteWorkspace = false;
        _workspace[_activeSlot] = WorkspaceSlot();
        _workspaceNames[_activeSlot] = "Empty";
        loadActive();
        safeSetText("lite-input", "");
        setStatus("Workspace deleted");
        updateSession();
        persist();
    }

    private void duplicateWorkspace()
    {
        syncActive();
        int target = -1;
        foreach (i; 0 .. _workspace.length)
            if (i != _activeSlot && _workspace[i].messages == 0 &&
                _workspace[i].transcript.strip == "New session.")
            {
                target = cast(int) i;
                break;
            }
        if (target < 0)
        {
            setStatus("No free workspace");
            return;
        }
        _workspace[target] = _workspace[_activeSlot];
        _workspaceNames[target] = _workspaceNames[_activeSlot] ~ " copy";
        setStatus("Workspace duplicated");
        updateSession();
        persist();
    }

    private void exportSession()
    {
        try
        {
            const directory = buildPath(dirName(defaultSettingsPath()),
                "exports");
            if (!exists(directory))
                mkdirRecurse(directory);
            const path = buildPath(directory, "session.md");
            write(path, _transcript);
            JSONValue metadata;
            metadata["model"] = JSONValue(_settings.model);
            metadata["baseUrl"] = JSONValue(_settings.baseUrl);
            metadata["messages"] = JSONValue(cast(long) _messages);
            metadata["exportedAt"] = JSONValue(Clock.currTime().toString());
            write(buildPath(directory, "session.json"),
                metadata.toString() ~ "\n");

            setStatus("Exported session.md · " ~ to!string(_transcript.length) ~
                " chars · " ~ Clock.currTime().toString());
        }
        catch (Exception error)
        {
            setStatus("Export error: " ~ error.msg);
        }
    }

    private void importSession()
    {
        try
        {
            const path = buildPath(dirName(defaultSettingsPath()),
                "exports", "session.md");
            if (!exists(path))
            {
                setStatus("Import file missing");
                return;
            }
            const content = readText(path);
            if (content.length > 2_000_000)
            {
                setStatus("Import file too large");
                return;
            }
            if (content.strip.length == 0)
            {
                setStatus("Import file is empty");
                return;
            }
            const imported = parseTranscript(content);
            if (imported.length == 0)
            {
                setStatus("Import has no messages");
                return;
            }
            _transcript = content;
            _messages = cast(uint) imported.length;

            setStatus("Session imported");
            updateSession();
            persist();
        }
        catch (Exception error)
        {
            setStatus("Import error: " ~ error.msg);
        }
    }

    private void clearSession()
    {
        if (_session.busy())
            _session.cancel();
        _transcript = "New session.\n";
        _sessionViewIndex = -1;
        _lastPrompt = "";
        _lastFailed = false;
        _messages = 0;
        safeSetText("lite-input", "");
        safeSetText("lite-send", "Send");
        setStatus("Ready");
        updateSession();
        persist();
    }

    private void stop()
    {
        _session.cancel();
        setStatus("Stopping...");
        _statusBannerUntil = SysTime.init;
        safeSetText("key-clear-toast", "");
    }

    void service(double deltaSeconds)
    {
        foreach (event; _session.drain())
        {
            switch (event.kind)
            {
                case SessionEventKind.delta:
                    _transcript ~= event.text;
                    break;
                case SessionEventKind.done:
                    _transcript ~= event.text == "Stopped"
                        ? "\n[stopped]\n" : "\n";
                    setStatus(event.text);
                    safeSetText("lite-send", "Send");
                    _lastFailed = false;
                    updateSession();
                    persist();
                    break;
                case SessionEventKind.failed:
                    _transcript ~= "\n[error] " ~ event.text ~ "\n";
                    setStatus("Error");
                    safeSetText("lite-send", "Send");
                    _lastFailed = true;
                    updateSession();
                    persist();
                    break;
                default:
                    break;
            }
        }
        const now = Clock.currTime();
        if (_lastRefresh == SysTime.init || now >= _lastRefresh + 5.seconds)
        {
            _lastRefresh = now;
            refreshView();
        }
        if (_confirmClearKey && now >= _clearKeyDeadline)
        {
            _confirmClearKey = false;
            setStatus("Clear confirmation expired");
        }
        if (_confirmDeleteWorkspace && now >= _deleteWorkspaceDeadline)
        {
            _confirmDeleteWorkspace = false;
            setStatus("Clear workspace confirmation expired");
        }
        if (_confirmSaveKey && now >= _saveKeyDeadline)
        {
            _confirmSaveKey = false;
            setStatus("Replace key confirmation expired");
        }
        if (_statusBannerUntil != SysTime.init && now >= _statusBannerUntil &&
            !_confirmClearKey)
        {
            _statusBannerUntil = SysTime.init;
            safeSetText("key-clear-toast", "");
        }
    }

    /// Reapply controller-owned values after a scene reload or controller attach.
    void refreshView()
    {
        safeSetText("lite-base", _settings.baseUrl);
        safeSetText("lite-model", _settings.model);
        safeSetText("lite-key", "");
        updateKeyState();
        safeSetText("lite-send", _session.busy() ? "Stop" : "Send");
        setStatus(_status);
        updateSession();
        auditTextFit();
    }

    /// Report scene text/nodes whose declared box is too small to hold their
    /// text. `allowTextClip: true` marks deliberate clipping and suppresses
    /// the warning. This is a structural audit; it does not mutate the scene.
    private void auditTextFit()
    {
        try
        {
            const scenePath = buildPath(environment.get("LOCALAPPDATA", ""),
                "AuroraOpenCodeLiteV2", "lite.scene.json");
            if (!exists(scenePath))
                return;
            const doc = parseJSON(readText(scenePath));
            string[] warnings;
            int intentional;

            void inspect(JSONValue node)
            {
                if (node.type != JSONType.object)
                    return;
                bool allowClip;
                if (auto flag = "allowTextClip" in node.object)
                    allowClip = (*flag).type == JSONType.true_;
                if (allowClip)
                    ++intentional;
                string id;
                if (auto value = "id" in node.object)
                    if ((*value).type == JSONType.string)
                        id = (*value).str;
                string type;
                if (auto value = "type" in node.object)
                    if ((*value).type == JSONType.string)
                        type = (*value).str;
                int height;
                if (auto value = "height" in node.object)
                    if ((*value).type == JSONType.integer)
                        height = cast(int) (*value).integer;
                int width;
                if (auto value = "width" in node.object)
                    if ((*value).type == JSONType.integer)
                        width = cast(int) (*value).integer;

                if (type == "component")
                {
                    int lines;
                    int padding = 6;
                    string mode = "card";
                    if (auto props = "props" in node.object)
                        if ((*props).type == JSONType.object)
                        {
                            if (auto value = "mode" in (*props).object)
                                if ((*value).type == JSONType.string)
                                    mode = (*value).str;
                            if (auto value = "padding" in (*props).object)
                                if ((*value).type == JSONType.integer)
                                    padding = cast(int) (*value).integer;
                            foreach (key; ["kicker", "title", "subtitle"])
                                if (auto value = key in (*props).object)
                                    if ((*value).type == JSONType.string &&
                                        (*value).str.length > 0)
                                        ++lines;
                        }


                    if (mode == "badge" || mode == "toolbar")
                        lines = 1;
                    if (lines > 0 && height > 0 &&
                        height < padding * 2 + lines * 12 && !allowClip)
                        warnings ~= (id.length ? id : "component");
                }
                else if (type == "label" || type == "button" || type == "menu")
                {
                    string text;
                    if (auto value = "text" in node.object)
                        if ((*value).type == JSONType.string)
                            text = (*value).str;
                    if (text.length > 0 && width > 2 && height > 0 &&
                        height < 18 && !allowClip)
                        warnings ~= (id.length ? id : type);
                    if ((type == "button" || type == "menu") &&
                        width > 2 && height > 0 && height < 24 && !allowClip)
                        warnings ~= (id.length ? id : type);
                }

                if (auto children = "children" in node.object)
                    if ((*children).type == JSONType.array)
                        foreach (child; (*children).array)
                            inspect(child);
            }

            inspect(doc["root"]);
            const message = warnings.length > 0
                ? "TEXT WARN " ~ to!string(warnings.length) ~ " · " ~ warnings[0]
                : intentional > 0
                    ? "TEXT FIT OK · " ~ to!string(intentional) ~ " intentional"
                    : "TEXT FIT OK";
            safeSetText("text-audit", message);
        }
        catch (Exception)
        {
            safeSetText("text-audit", "TEXT AUDIT ERROR");
        }
    }

    private void auditCredentials()
    {
        const conversationPath = buildPath(
            environment.get("LOCALAPPDATA", ""),
            "AuroraOpenCodeLiteV2", "conversation.txt");
        const rendered = exists(conversationPath)
            ? readText(conversationPath) : "";
        const exposed =
            (_settings.apiKey.length > 2 &&
                rendered.indexOf(_settings.apiKey) != -1) ||
            (_settings.openCodeKey.length > 2 &&
                rendered.indexOf(_settings.openCodeKey) != -1) ||
            (_settings.openAiKey.length > 2 &&
                rendered.indexOf(_settings.openAiKey) != -1);
        setStatus(exposed ? "Credential warning: key exposed"
            : "Credential audit OK");
    }

    private void checkForUpdate()
    {
        try
        {
            const exe = thisExePath();
            SysTime newest = timeLastModified(exe);
            const sourceDir = buildPath(dirName(dirName(exe)), "source");
            if (!exists(sourceDir))
            {
                setStatus("Update check unavailable");
                return;
            }
            bool newer;
            foreach (entry; dirEntries(sourceDir, SpanMode.depth))
            {
                if (!entry.isFile || extension(entry.name) != ".d")
                    continue;
                const stamp = timeLastModified(entry.name);
                if (stamp > newest)
                {
                    newest = stamp;
                    newer = true;
                }
            }
            setStatus(newer ? "Update available" : "Up to date");
        }
        catch (Exception)
        {
            setStatus("Update check failed");
        }
    }

    private void requestRebuild()
    {
        try
        {
            const buildDir = dirName(thisExePath());
            const appDir = dirName(buildDir);
            const helper = buildPath(buildDir, "rebuild_helper.ps1");
            spawnProcess(["powershell", "-NoProfile", "-ExecutionPolicy",
                "Bypass", "-File", helper, appDir]);
            setStatus("Rebuilding…");
            Thread.sleep(2.seconds);
            _view.closeHost();
        }
        catch (Exception)
        {
            setStatus("Rebuild failed");
        }
    }

    private void updateSession()
    {
        safeSetText("lite-session",
            "Workspace " ~ to!string(_activeSlot + 1) ~ " - " ~
            to!string(_messages) ~
            (_messages == 1 ? " message" : " messages"));
        foreach (i; 0 .. 3)
        {
            const slotName = _workspaceNames[i];
            safeSetText("lite-slot-" ~ to!string(i + 1),
                slotName.length > 0 ? slotName[0 .. 1] : "?");
            safeSetActive("lite-slot-" ~ to!string(i + 1),
                i == _activeSlot);
        }
        safeSetText("workspace-title", _workspaceNames[_activeSlot]);
        const titles = recentSessionTitles();
        foreach (i; 0 .. 3)
        {
            auto label = i < titles.length ? titles[i] : "";
            if (_sessionFilter.length > 0 && label.length > 0 &&
                label.toLower.indexOf(_sessionFilter.toLower) == -1)
                label = "";
            if (label.length > 7)
                label = label[0 .. 7] ~ "…";
            safeSetText("session-row-" ~ to!string(i + 1), label);
            safeSetActive("session-row-" ~ to!string(i + 1),
                i == _activeSlot);
        }
        safeSetText("chat-title",
            _activeSlot < titles.length ? titles[_activeSlot] : "New chat");
        safeSetText("thinking-toggle",
            "Thinking: " ~ (_thinkingOn ? "High" : "Off"));
        safeSetText("tools-toggle", _toolsOn ? "Tools: On" : "Tools");
        safeSetText("plan-toggle", _planOn ? "Plan: On" : "Plan");

        safeSetText("lite-usage",
            "Messages " ~ to!string(_messages) ~ "  |  " ~
            (_session.busy() ? "working" : "idle") ~ "  |  " ~
            _settings.model);

        const parsedMessages = parseTranscript(_transcript);
        safeSetText("transcript-meta",
            to!string(parsedMessages.length) ~ " MESSAGES  ·  ROLES  ·  " ~
            Clock.currTime().toString());
        safeSetText("composer-state",
            _session.busy()
                ? "Working..."
                : (safeText("lite-input").length == 0
                    ? "Composer empty"
                    : (_settings.apiKey.length > 0
                        ? "Ready to send"
                        : "Add an API key to send")));
        safeSetText("composer-count",
            to!string(safeText("lite-input").length) ~ " characters");
        safeSetEnabled("composer-clear",
            safeText("lite-input").length > 0);
        safeSetText("last-prompt",
            "Last sent: " ~
            (_lastPrompt.length > 0 ? _lastPrompt : "none"));

        const provider = isOpenCodeBaseUrl(_settings.baseUrl)
            ? "OpenCode" : "OpenAI";
        safeSetText("lite-provider-health",
            _settings.baseUrl.length > 0 && _settings.model.length > 0
                ? provider ~ " · " ~ _settings.model ~ " · " ~
                    (_settings.apiKey.length > 0 ? "ready" : "no key")
                : "Invalid configuration");
    }

    private string[] recentSessionTitles()
    {
        string[] titles;
        foreach (i; 0 .. _workspace.length)
            titles ~= workspaceSessionTitle(cast(int) i);
        return titles;
    }

    private string workspaceSessionTitle(int index)
    {
        const messages = parseTranscript(_workspace[index].transcript);
        for (size_t i = messages.length; i-- > 0;)
        {
            if (messages[i].role != "user")
                continue;
            const lines = messages[i].body.splitLines;
            if (lines.length == 0)
                continue;
            auto title = lines[0].strip;
            if (title.length > 32)
                title = title[0 .. 32] ~ "…";
            if (title.length > 0)
                return title;
        }
        return "New session";
    }

    private size_t[] recentSessionMessageIndices()
    {
        const messages = parseTranscript(_transcript);
        size_t[] indices;
        string[] titles;
        for (size_t i = messages.length; i-- > 0;)
        {
            if (messages[i].role != "user")
                continue;
            const lines = messages[i].body.splitLines;
            if (lines.length == 0)
                continue;
            auto title = lines[0].strip;
            if (title.length == 0)
                continue;
            if (title.length > 32)
                title = title[0 .. 32] ~ "…";
            bool duplicate;
            foreach (existing; titles)
                if (existing == title)
                {
                    duplicate = true;
                    break;
                }
            if (duplicate)
                continue;
            titles ~= title;
            indices ~= i;
            if (indices.length == 3)
                break;
        }
        return indices;
    }

    private void persist()
    {
        syncActive();
        saveWorkspace();
        try
        {
            const directory = buildPath(dirName(defaultSettingsPath()),
                "exports");
            if (!exists(directory))
                mkdirRecurse(directory);
            write(buildPath(directory, "autosave.md"), _transcript);
        }
        catch (Exception)
        {
            // Workspace persistence remains authoritative if autosave fails.
        }
        try
        {
            ConversationState state;
            state.transcript = _transcript;
            state.messages = _messages;
            state.lastPrompt = _lastPrompt;
            state.failed = _lastFailed;
            saveConversation(state);
        }
        catch (Exception)
        {
            // The host remains usable even if the history file is unwritable.
        }
    }

    private void safeSetText(string id, string value)
    {
        try
            _view.setText(id, value);
        catch (Exception)
        {
        }
    }

    private string safeText(string id)
    {
        try
            return _view.text(id);
        catch (Exception)
            return "";
    }

    private void safeSetEnabled(string id, bool enabled)
    {
        try
            _view.setEnabled(id, enabled);
        catch (Exception)
        {
        }
    }

    private void safeSetActive(string id, bool active)
    {
        try
            _view.setActive(id, active);
        catch (Exception)
        {
        }
    }

    private bool safeActivate(string id)
    {
        try
            return _view.activate(id);
        catch (Exception)
            return false;
    }

    private void setStatus(string value)
    {
        const changed = _status != value;
        _status = value;
        safeSetText("lite-status", value);
        if (changed)
        {
            safeSetText("key-clear-toast", value);
            _statusBannerUntil = value != "Ready"
                ? Clock.currTime() + 4.seconds
                : SysTime.init;
        }
    }

    private void updateKeyState()
    {
        safeSetText("lite-key-state", _settings.apiKey.length > 0
            ? "Key set" : "No key");
    }
}
