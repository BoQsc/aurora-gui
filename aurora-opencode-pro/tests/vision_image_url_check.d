// Focused regression for inline image support: the request body must carry an
// OpenAI-compatible `image_url` part with a base64 data URL, and a text-only
// message must keep its plain string content.
//
// Build and run:
//   dmd -I../aurora-opencode-core/source -I../vendor/aurora-d-0.4.5/source \
//       -i ../aurora-opencode-core/source/auroraopencode/core.d \
//          ../aurora-opencode-core/source/auroraopencode/opencode_client.d \
//          ../aurora-opencode-core/source/auroraopencode/logging.d \
//          tests/vision_image_url_check.d -of=build/vision-check.exe
module vision_image_url_check;

import auroraopencode.core;
import auroraopencode.opencode_client;
import std.stdio : writeln;
import std.string : indexOf;

void main()
{
    ChatRequestMessage message;
    message.role = "user";
    message.content = "what is in this screenshot?";

    ChatImageAttachment image;
    image.mimeType = "image/png";
    image.name = "Screenshot (30).png";
    image.base64Data = "TWFu";
    message.images ~= image;

    const json = OpenCodeClient.chatMessageJsonForTesting(message).toString();
    writeln(json);

    // The wire shape: a parts array, the text part first, then one image_url
    // part per image holding a base64 data URL.
    assert(json.indexOf(`"role":"user"`) >= 0, "role missing");
    assert(json.indexOf(`"type":"text"`) >= 0, "text part missing");
    assert(json.indexOf(`"type":"image_url"`) >= 0, "image_url part missing");
    // `toString` escapes solidus, so expect the rendered form the provider sees.
    assert(json.indexOf(`"url":"data:image\/png;base64,TWFu"`) >= 0,
        "data URL missing or malformed");
    assert(json.indexOf(`"content":` ~ `"` ~ "what is in this screenshot?") < 0,
        "image turn must not serialize content as a bare string");

    // A plain text turn must keep the string form every text-only route and
    // local llama.cpp template expects.
    ChatRequestMessage plain;
    plain.role = "user";
    plain.content = "hello";
    const plainJson = OpenCodeClient.chatMessageJsonForTesting(plain).toString();
    assert(plainJson.indexOf(`"content":"hello"`) >= 0,
        "text-only content must stay a plain string");
    assert(plainJson.indexOf("image_url") < 0, "text turn must not carry parts");

    // Vision capability gating: the DeepSeek 4.x line may carry images, and a
    // text-only route must never receive an image part.
    assert(isVisionModel(defaultModel));
    assert(isVisionModel("deepseek-v4-flash-vision-exp"));
    assert(!isVisionModel("glm-5.3"));

    // Mime fallback keeps a caller that only captured bytes valid.
    ChatImageAttachment bare;
    bare.base64Data = "TWFu";
    assert(OpenCodeClient.chatImageDataUrl(bare) == "data:image/png;base64,TWFu");

    writeln("vision_image_url_check: OK");
}
