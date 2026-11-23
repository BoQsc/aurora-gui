module plugin_main;

import opencodelite.controller : LiteController, LiteView;
import opencodelite.pluginloader : LitePluginApi;
import opencodelite.settings : loadSettings;
import std.string : fromStringz, toStringz;

private __gshared LitePluginApi api;
private __gshared LiteController controller;

final class PluginView : LiteView
{
    string text(string id)
    {
        if (api.getText is null)
            return "";
        auto value = api.getText(api.context, toStringz(id));
        return value is null ? "" : fromStringz(value).idup;
    }

    bool setText(string id, string text)
    {
        if (api.setText is null)
            return false;
        api.setText(api.context, toStringz(id), toStringz(text));
        return true;
    }

    bool setEnabled(string id, bool enabled)
    {
        if (api.setEnabled is null)
            return false;
        api.setEnabled(api.context, toStringz(id), enabled ? 1 : 0);
        return true;
    }
}

extern(C) export int aurora_lite_plugin_init(LitePluginApi* value)
{
    api = *value;
    controller = new LiteController(new PluginView(), loadSettings());
    controller.refreshView();
    return 0;
}

extern(C) export void aurora_lite_plugin_action(const(char)* node,
    const(char)* action)
{
    if (controller !is null)
        controller.handleAction(fromStringz(node).idup, fromStringz(action).idup);
}

extern(C) export void aurora_lite_plugin_tick()
{
    if (controller !is null)
        controller.service(0.016);
}

extern(C) export void aurora_lite_plugin_refresh()
{
    if (controller !is null)
        controller.refreshView();
}

extern(C) export void aurora_lite_plugin_shutdown()
{
    controller = null;
}
