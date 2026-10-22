module experiment.aurorahost.component;

import aurora : GuiWindow, RgbaImage, Widget;
import std.json : JSONValue;

/**
 * Services exposed to an application component.
 *
 * Components receive only the window, asset root, and action channel. They do
 * not reach into the scene parser or registry, so an application-specific
 * control can be added without teaching the scene engine a new node type.
 */
struct ComponentContext
{
    GuiWindow window;
    string assetBase;
    void delegate(string action) dispatchAction;
    RgbaImage icon;
}

alias ComponentFactory = Widget delegate(ComponentContext context,
    JSONValue props);

/** Named component factories shared by all scene instances in a host. */
final class ComponentRegistry
{
    private ComponentFactory[string] _factories;

    void register(string name, ComponentFactory factory)
    {
        if (name.length == 0)
            throw new Exception("component name must not be empty");
        if (factory is null)
            throw new Exception("component factory must not be null");
        if (name in _factories)
            throw new Exception("duplicate component: " ~ name);
        _factories[name] = factory;
    }

    bool has(string name) const
    {
        return (name in _factories) !is null;
    }

    Widget create(string name, ComponentContext context, JSONValue props)
    {
        auto factory = name in _factories;
        if (factory is null)
            throw new Exception("unknown component: " ~ name);
        auto widget = (*factory)(context, props);
        if (widget is null)
            throw new Exception("component returned no widget: " ~ name);
        return widget;
    }
}
