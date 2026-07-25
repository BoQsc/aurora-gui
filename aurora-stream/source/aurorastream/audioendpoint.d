module aurorastream.audioendpoint;

import std.string : strip;

/**
 * One selectable audio endpoint.
 *
 * label is shown in the Aurora dropdown.
 * displayName is the normal Windows name.
 * inputName is the stable backend identifier stored in settings.
 * alternativeName is optional backend diagnostic information.
 */
struct AudioEndpoint
{
    string label;
    string displayName;
    string inputName;
    string alternativeName;
}

AudioEndpoint cleanedAudioEndpoint(AudioEndpoint source)
{
    source.label = source.label.strip().idup;
    source.displayName = source.displayName.strip().idup;
    source.inputName = source.inputName.strip().idup;
    source.alternativeName = source.alternativeName.strip().idup;
    if (source.inputName.length == 0)
        source.inputName = source.displayName;
    if (source.label.length == 0)
        source.label = source.displayName;
    return source;
}
