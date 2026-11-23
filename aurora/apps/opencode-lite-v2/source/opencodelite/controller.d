module opencodelite.controller;

import opencodelite.history : ConversationState, loadConversation, saveConversation;
import opencodelite.session : ChatSession, SessionEventKind;
import opencodelite.settings : LiteSettings, openAiBaseUrl, openAiModel,
    isOpenAiBaseUrl, isOpenCodeBaseUrl, openCodeBaseUrl, openCodeModel,
    saveSettings, defaultSettingsPath;
import std.conv : to;
import core.time : seconds;
import std.datetime : Clock, SysTime;
import std.file : exists, mkdirRecurse, write;
import std.file : readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.string : indexOf, splitLines, strip, toLower;

/// The small host-facing surface the controller needs. Implementations are the
/// embedded registry and an external host control client.
interface LiteView
{
    string text(string id);
    bool setText(string id, string text);
    bool setEnabled(string id, bool enabled);
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
    private bool _confirmClearKey;
    private SysTime _clearKeyDeadline;
    private SysTime _statusBannerUntil;
    private int _paletteIndex;
    private string _recentPaletteCommand;
    private static immutable string[5] _paletteCommands = [
        "Help", "Export", "Import", "New session", "Search"];

    this(LiteView view, LiteSettings settings)
    {
        _view = view;
        _settings = settings;
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
            _view.setText("lite-input", "");
            setStatus("Composer cleared");
            updateSession();
        }
        else if (action == "history-prev")
            historyPrevious();
        else if (action == "history-next")
            historyNext();
        else if (action == "workspace-search")
        {
            const query = _view.text("lite-search").strip;
            if (query.length == 0)
                setStatus("Search is empty");
            else
            {
                const needle = query.toLower;
                _searchLines = [];
                foreach (line; _transcript.splitLines)
                    if (line.toLower.indexOf(needle) != -1)
                        _searchLines ~= line.strip;
                _searchIndex = 0;
                showSearchResult(query);
            }
        }
        else if (action == "search-prev")
            searchPrevious();
        else if (action == "search-next")
            searchNext();
        else if (action == "search-clear")
        {
            _view.setText("lite-search", "");
            _searchLines = [];
            _searchIndex = 0;
            _view.setText("search-result", "no matches");
            setStatus("Search cleared");
        }
        else if (action == "save")
            saveConnection();
        else if (action == "save-key")
            saveKey();
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
            _view.setText("key-clear-toast", "");
        }
        else if (action == "help")
            setStatus("Enter sends | Shift+Enter newline | Esc stops | Ctrl+L focus");
        else if (action == "palette-next")
            movePaletteFocus(1);
        else if (action == "palette-prev")
            movePaletteFocus(-1);
        else if (action == "palette-run")
            runPaletteCommand();
        else if (action == "palette-clear-recent")
            _view.setText("command-palette-recent", "Recent: none");
        else if (action == "palette-restore-recent")
        {
            _view.setText("command-palette-recent",
                _recentPaletteCommand.length > 0
                    ? "Recent: " ~ _recentPaletteCommand
                    : "Recent: none");
            setStatus("Restored recent command");
        }
        else if (action == "palette-reset-status")
        {
            _recentPaletteCommand = "";
            _view.setText("command-palette-recent", "Recent: none");
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
            activateSlot(0);
        else if (action == "session-2")
            activateSlot(1);
        else if (action == "session-3")
            activateSlot(2);
        else if (action == "workspace-rename")
            renameWorkspace();
        else if (action == "workspace-new")
            newWorkspace();
        else if (action == "workspace-delete")
            deleteWorkspace();
        else if (action == "preset-opencode")
            applyPreset(openCodeBaseUrl, openCodeModel, "OpenCode API preset");
        else if (action == "preset-openai")
            applyPreset(openAiBaseUrl, openAiModel,
                "OpenAI-compatible preset");
        else if (action == "model-deepseek")
            applyPreset(openCodeBaseUrl, openCodeModel, "DeepSeek selected");
        else if (action == "model-gpt")
            applyPreset(openAiBaseUrl, openAiModel, "GPT-4o mini selected");
    }

    private void applyPreset(string baseUrl, string model, string label)
    {
        rememberKey();
        _settings.baseUrl = baseUrl;
        _settings.model = model;
        _settings.apiKey = isOpenCodeBaseUrl(baseUrl)
            ? _settings.openCodeKey
            : isOpenAiBaseUrl(baseUrl) ? _settings.openAiKey : "";
        _view.setText("lite-base", baseUrl);
        _view.setText("lite-model", model);
        _view.setText("lite-key", "");
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

    private void rememberKey()
    {
        const entered = _view.text("lite-key").strip;
        if (entered.length > 0)
            _settings.apiKey = entered;
        if (isOpenCodeBaseUrl(_settings.baseUrl))
            _settings.openCodeKey = _settings.apiKey;
        else if (isOpenAiBaseUrl(_settings.baseUrl))
            _settings.openAiKey = _settings.apiKey;
    }

    private void saveConnection()
    {
        _settings.baseUrl = _view.text("lite-base").strip;
        _settings.model = _view.text("lite-model").strip;
        rememberKey();
        try
        {
            saveSettings(_settings);
            _session.updateSettings(_settings);
            _view.setText("lite-key", "");
            updateKeyState();
            setStatus("Settings saved");
        }
        catch (Exception error)
        {
            setStatus("Settings error: " ~ error.msg);
        }
    }

    private void saveKey()
    {
        const entered = _view.text("lite-key").strip;
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
            _view.setText("lite-key", "");
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
        const prompt = _view.text("lite-input").strip;
        if (prompt.length == 0)
            return;
        saveConnection();
        if (_settings.apiKey.length == 0)
        {
            setStatus("Add an API key to send");
            updateSession();
            return;
        }
        _lastPrompt = prompt;
        _lastFailed = false;
        ++_messages;
        _view.setText("lite-export-status", "Not exported");
        const stamp = Clock.currTime().toString();
        _transcript ~= "\n[" ~ stamp ~ "] You: " ~ prompt ~
            "\n[" ~ stamp ~ "] Assistant: ";
        _view.setText("lite-input", "");
        _view.setText("lite-transcript", _transcript);
        setStatus("Waiting for response...");
        _view.setText("lite-send", "Stop");
        updateSession();
        persist();
        _session.send(prompt);
    }

    private void retryLast()
    {
        if (_lastPrompt.length == 0 || _session.busy())
            return;
        _view.setText("lite-input", _lastPrompt);
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

    private void activateSlot(int index)
    {
        if (index < 0 || index >= _workspace.length || index == _activeSlot)
            return;
        if (_session.busy())
            _session.cancel();
        syncActive();
        _activeSlot = index;
        loadActive();
        _view.setText("lite-input", "");
        _view.setText("lite-transcript", _transcript);
        _view.setText("lite-send", "Send");
        setStatus("Workspace " ~ to!string(index + 1));
        updateSession();
        persist();
    }

    private void renameWorkspace()
    {
        const name = _view.text("lite-input").strip;
        if (name.length == 0)
            return;
        _workspaceNames[_activeSlot] = name;
        _view.setText("lite-input", "");
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
        _view.setText("lite-input", _promptHistory[_historyIndex]);
        updateSession();
    }

    private void movePaletteFocus(int direction)
    {
        _paletteIndex = (_paletteIndex + direction +
            cast(int) _paletteCommands.length) % cast(int) _paletteCommands.length;
        _view.setText("command-palette-selected",
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
        _view.setText("command-palette-recent",
            "Recent: " ~ _paletteCommands[_paletteIndex]);
    }

    private void historyNext()
    {
        if (_promptHistory.length == 0)
            return;
        if (_historyIndex < _promptHistory.length)
            ++_historyIndex;
        _view.setText("lite-input",
            _historyIndex == _promptHistory.length
                ? ""
                : _promptHistory[_historyIndex]);
        updateSession();
    }

    private void showSearchResult(string query)
    {
        if (_searchLines.length == 0)
        {
            _view.setText("search-result", "no matches");
            setStatus(query ~ ": 0 matches");
            return;
        }
        _view.setText("search-result",
            "match " ~ to!string(_searchIndex + 1) ~ "/" ~
            to!string(_searchLines.length) ~ ": " ~
            _searchLines[_searchIndex]);
        setStatus(query ~ ": match " ~ to!string(_searchIndex + 1) ~
            "/" ~ to!string(_searchLines.length));
    }

    private void searchPrevious()
    {
        if (_searchLines.length == 0)
            return;
        _searchIndex = (_searchIndex - 1 + cast(int) _searchLines.length) %
            cast(int) _searchLines.length;
        showSearchResult(_view.text("lite-search").strip);
    }

    private void searchNext()
    {
        if (_searchLines.length == 0)
            return;
        _searchIndex = (_searchIndex + 1) % cast(int) _searchLines.length;
        showSearchResult(_view.text("lite-search").strip);
    }

    private void newWorkspace()
    {
        _workspace[_activeSlot] = WorkspaceSlot();
        loadActive();
        _view.setText("lite-input", "");
        _view.setText("lite-transcript", _transcript);
        setStatus("Workspace " ~ to!string(_activeSlot + 1));
        updateSession();
        persist();
    }

    private void deleteWorkspace()
    {
        _workspace[_activeSlot] = WorkspaceSlot();
        _workspaceNames[_activeSlot] = "Empty";
        loadActive();
        _view.setText("lite-input", "");
        _view.setText("lite-transcript", _transcript);
        setStatus("Workspace deleted");
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
            _view.setText("lite-export-status",
                "Exported: session.md  ·  " ~ Clock.currTime().toString());
            setStatus("Session exported");
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
            _transcript = readText(path);
            _messages = 0;
            _view.setText("lite-transcript", _transcript);
            _view.setText("lite-export-status",
                "Imported: session.md  ·  " ~ Clock.currTime().toString());
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
        _lastPrompt = "";
        _lastFailed = false;
        _messages = 0;
        _view.setText("lite-input", "");
        _view.setText("lite-transcript", _transcript);
        _view.setText("lite-send", "Send");
        setStatus("Ready");
        updateSession();
        persist();
    }

    private void stop()
    {
        _session.cancel();
        setStatus("Stopping...");
        _statusBannerUntil = SysTime.init;
        _view.setText("key-clear-toast", "");
    }

    void service(double deltaSeconds)
    {
        foreach (event; _session.drain())
        {
            switch (event.kind)
            {
                case SessionEventKind.delta:
                    _transcript ~= event.text;
                    _view.setText("lite-transcript", _transcript);
                    break;
                case SessionEventKind.done:
                    _transcript ~= event.text == "Stopped"
                        ? "\n[stopped]\n" : "\n";
                    _view.setText("lite-transcript", _transcript);
                    setStatus(event.text);
                    _view.setText("lite-send", "Send");
                    _lastFailed = false;
                    updateSession();
                    persist();
                    break;
                case SessionEventKind.failed:
                    _transcript ~= "\n[error] " ~ event.text ~ "\n";
                    _view.setText("lite-transcript", _transcript);
                    setStatus("Error");
                    _view.setText("lite-send", "Send");
                    _lastFailed = true;
                    updateSession();
                    persist();
                    break;
                default:
                    break;
            }
        }
        const now = Clock.currTime();
        if (_lastRefresh == SysTime.init || now >= _lastRefresh + 1.seconds)
        {
            _lastRefresh = now;
            refreshView();
        }
        if (_confirmClearKey && now >= _clearKeyDeadline)
        {
            _confirmClearKey = false;
            setStatus("Clear confirmation expired");
        }
        if (_statusBannerUntil != SysTime.init && now >= _statusBannerUntil &&
            !_confirmClearKey)
        {
            _statusBannerUntil = SysTime.init;
            _view.setText("key-clear-toast", "");
        }
    }

    /// Reapply controller-owned values after a scene reload or controller attach.
    void refreshView()
    {
        _view.setText("lite-base", _settings.baseUrl);
        _view.setText("lite-model", _settings.model);
        _view.setText("lite-key", "");
        updateKeyState();
        _view.setText("lite-transcript", _transcript);
        _view.setText("lite-send", _session.busy() ? "Stop" : "Send");
        setStatus(_status);
        updateSession();
    }

    private void updateSession()
    {
        _view.setText("lite-session",
            "Workspace " ~ to!string(_activeSlot + 1) ~ " - " ~
            to!string(_messages) ~
            (_messages == 1 ? " message" : " messages"));
        foreach (i; 0 .. 3)
        {
            _view.setText("lite-slot-" ~ to!string(i + 1),
                (i == _activeSlot ? "> " : "  ") ~ _workspaceNames[i]);
            _view.setText("header-tab-" ~ to!string(i + 1),
                (i == _activeSlot ? "* " : "  ") ~ _workspaceNames[i]);
        }
        _view.setEnabled("lite-retry", _lastFailed && !_session.busy());
        _view.setText("lite-usage",
            "Messages " ~ to!string(_messages) ~ "  |  " ~
            (_session.busy() ? "working" : "idle") ~ "  |  " ~
            _settings.model);
        _view.setText("header-active-badge",
            _workspaceNames[_activeSlot] ~ "  |  " ~
            to!string(_messages) ~
            (_messages == 1 ? " message" : " messages") ~ "  |  " ~
            (_session.busy() ? "working" : "idle"));
        _view.setText("transcript-meta",
            "MESSAGE ROLES  ·  TIMESTAMPS  ·  " ~
            Clock.currTime().toString());
        _view.setText("composer-state",
            _session.busy()
                ? "Working..."
                : (_view.text("lite-input").length == 0
                    ? "Composer empty"
                    : (_settings.apiKey.length > 0
                        ? "Ready to send"
                        : "Add an API key to send")));
        _view.setText("composer-count",
            to!string(_view.text("lite-input").length) ~ " characters");
        _view.setEnabled("composer-clear",
            _view.text("lite-input").length > 0);
        _view.setText("last-prompt",
            "Last sent: " ~
            (_lastPrompt.length > 0 ? _lastPrompt : "none"));
        const onOpenCode = isOpenCodeBaseUrl(_settings.baseUrl);
        _view.setText("model-deepseek", onOpenCode ? "* DS" : "  DS");
        _view.setText("model-gpt", onOpenCode ? "  GPT" : "* GPT");
        _view.setText("lite-provider-health",
            _settings.baseUrl.length > 0 && _settings.model.length > 0
                ? (_settings.apiKey.length > 0 ? "Provider ready" : "No key")
                : "Invalid configuration");
    }

    private void persist()
    {
        syncActive();
        saveWorkspace();
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

    private void setStatus(string value)
    {
        const changed = _status != value;
        _status = value;
        _view.setText("lite-status", value);
        if (changed)
        {
            _view.setText("key-clear-toast", value);
            _statusBannerUntil = value != "Ready"
                ? Clock.currTime() + 4.seconds
                : SysTime.init;
        }
    }

    private void updateKeyState()
    {
        _view.setText("lite-key-state", _settings.apiKey.length > 0
            ? "Key set" : "No key");
    }
}
