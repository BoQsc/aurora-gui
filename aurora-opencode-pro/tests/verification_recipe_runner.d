module verification_recipe_runner;
import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : executeTool;
import std.json : JSONValue;
import std.path : absolutePath, buildPath;
import std.file : write;
import std.base64 : Base64;
import std.stdio : writeln;

int main(string[] args)
{
    assert(args.length == 4, "usage: runner <workspace> <recipe.json> <report.json>");
    setOpencodeStateDirectoryForTesting(absolutePath(args[3] ~ ".state"));
    JSONValue request; request["recipe"] = absolutePath(args[2]);
    auto result = executeTool(OpenCodeToolCall("comparison","verify",request.toString()),absolutePath(args[1]));
    write(args[3], result.output); writeln(result.output);
    foreach (index, image; result.images)
        write(args[3] ~ "." ~ (index == 0 ? "reference" : "actual") ~ ".png", Base64.decode(image.base64Data));
    return result.failed ? 1 : 0;
}
