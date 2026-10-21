module experiment.aurorahost.components;

import experiment.aurorahost.component : ComponentContext, ComponentRegistry;
import experiment.aurorahost.notepad_ui : createNotepad;
import std.json : JSONValue;

/** Application components bundled with the experiment host. */
void registerBuiltinComponents(ComponentRegistry registry)
{
    registry.register("notepad.win10",
        delegate(ComponentContext context, JSONValue props)
        {
            return createNotepad(context, props);
        });
}
