module aurorahost.components;

import aurorahost.component : ComponentContext, ComponentRegistry;
import aurorahost.notepad_ui : createNotepad;
import std.json : JSONValue;

/** Application components bundled with the host. */
void registerBuiltinComponents(ComponentRegistry registry)
{
    registry.register("notepad.win10",
        delegate(ComponentContext context, JSONValue props)
        {
            return createNotepad(context, props);
        });
}
