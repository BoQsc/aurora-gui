module auroraopencode.recipeevidence;
import auroraopencode.core : ChatMessage;
import auroraopencode.checkout : canonicalPath, checkoutIdentity;
import auroraopencode.verificationrecipe : verificationInputsFingerprint, verificationInputsSignature;
import std.file : read, readText, getSize;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : indexOf;
import std.path : absolutePath;

/// Full hashes are reused only within the same native source generation and
/// an unchanged bounded input inventory. External file edits refresh the proof.
struct RecipeEvidenceCache
{
    private struct ConfirmedInput { string signature; string hash; }
    private static ConfirmedInput[string] confirmedInputs;
    JSONValue[string] reports, recipes;
    string[string] fileHashes, inputHashes, inventories;
    bool[string] recipeVerdicts, renderVerdicts;

    JSONValue report(const ref ChatMessage message)
    {
        if (message.toolName != "verify") return JSONValue.init;
        const key = message.id.length ? message.id : message.content;
        if (auto value = key in reports) return *value;
        JSONValue value;
        try { value = parseJSON(message.content); }
        catch (Exception) {}
        reports[key] = value;
        return value;
    }
    string key(const ref ChatMessage message)
    {
        if (message.toolName != "verify") return "";
        try { return canonicalPath(report(message)["recipe"].str); }
        catch (Exception) { return ""; }
    }
    private string renderKey(JSONValue row, string workspace = "")
    {
        try
        {
            if (row["kind"].str == "render")
                return canonicalPath(absolutePath(row["reference"].str, workspace)) ~ "\n" ~ canonicalPath(absolutePath(row["actual"].str, workspace));
        }
        catch (Exception) {}
        return "";
    }
    // Called newest first; a failed case supersedes only the affected proof.
    void observe(const ref ChatMessage message)
    {
        const value = report(message);
        if (value.type != JSONType.object) return;
        const recipe = key(message);
        const workspace = recipe.length ? checkoutIdentity(recipe) : "";
        if (recipe.length && !(recipe in recipeVerdicts)) recipeVerdicts[recipe] = !message.failed;
        if (auto rows = "steps" in value.object)
            if (rows.type == JSONType.array)
                foreach (row; rows.array)
                {
                    const render = renderKey(row, workspace);
                    if (render.length && !(render in renderVerdicts))
                        renderVerdicts[render] = "passed" in row.object && row["passed"].type == JSONType.true_;
                }
        if (message.failed)
            if (auto step = "failedStep" in value.object)
            {
                const render = renderKey(*step, workspace);
                if (render.length && !(render in renderVerdicts)) renderVerdicts[render] = false;
            }
    }
    private string fileHash(string path, ulong maximum)
    {
        path = canonicalPath(path);
        if (auto hash = path in fileHashes) return *hash;
        if (getSize(path) > maximum) return "";
        const hash = sha256Of(cast(const(ubyte)[]) read(path)).toHexString().idup;
        fileHashes[path] = hash;
        return hash;
    }
    bool current(const ref ChatMessage message, string ownerScope)
    {
        if (message.failed || !message.verificationCheck.length) return false;
        try
        {
            const value = report(message);
            if (value["passed"].type != JSONType.true_) return false;
            const path = key(message);
            if (auto verdict = path in recipeVerdicts) if (!*verdict) return false;
            const separator = ownerScope.indexOf('|');
            if (separator <= 0 || checkoutIdentity(path) != ownerScope[0 .. separator]) return false;
            if (fileHash(path, 64 * 1024) != value["recipeSha256"].str) return false;
            JSONValue recipe;
            if (auto cached = path in recipes) recipe = *cached;
            else { recipe = parseJSON(readText(path)); recipes[path] = recipe; }
            const workspace = ownerScope[0 .. separator];
            const inputs = recipe["inputs"];
            const inputKey = workspace ~ "\n" ~ inputs.toString();
            string inputHash;
            if (auto hash = inputKey in inputHashes) inputHash = *hash;
            else
            {
                const signature = verificationInputsSignature(workspace, inputs, inventories);
                const cacheKey = ownerScope ~ "\n" ~ inputKey;
                if (auto previous = cacheKey in confirmedInputs)
                    if (previous.signature == signature) inputHash = previous.hash;
                if (!inputHash.length)
                {
                    inputHash = verificationInputsFingerprint(workspace, inputs);
                    if (verificationInputsSignature(workspace, inputs) != signature) return false;
                    if (confirmedInputs.length >= 128) confirmedInputs = null;
                    confirmedInputs[cacheKey] = ConfirmedInput(signature, inputHash);
                }
                inputHashes[inputKey] = inputHash;
            }
            if (inputHash != value["inputsSha256"].str) return false;
            foreach (row; value["steps"].array)
                if (row["kind"].str == "render")
                {
                    if (auto verdict = renderKey(row) in renderVerdicts) if (!*verdict) return false;
                    if (fileHash(row["reference"].str, 32 * 1024 * 1024) != row["referenceSha256"].str) return false;
                }
            return true;
        }
        catch (Exception) { return false; }
    }
}
