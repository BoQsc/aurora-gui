module opencodelite.registryview;

import aurorahost.scene : NodeRegistry;
import opencodelite.controller : LiteView;

/// Embedded host view backed directly by the host scene registry.
final class RegistryLiteView : LiteView
{
    private NodeRegistry _registry;

    this(NodeRegistry registry)
    {
        _registry = registry;
    }

    string text(string id)
    {
        return _registry.text(id);
    }

    bool setText(string id, string text)
    {
        return _registry.setText(id, text);
    }

    bool setEnabled(string id, bool enabled)
    {
        return _registry.setEnabled(id, enabled);
    }

    bool setActive(string id, bool active)
    {
        return _registry.setChrome(id, "", "", active ? 1 : 0);
    }
}
