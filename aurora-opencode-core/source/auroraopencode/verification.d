module auroraopencode.verification;

import std.path : baseName, stripExtension;
import std.string : toLower, startsWith;

public struct VerificationEvidence
{
    string check;
    string workspace;
    ulong revision;
    bool passed;
    int exitCode = int.min;
}

enum WorkspaceCommandEffect { unknown, readOnly, repositoryMetadata }

/// Classify direct Git invocations, never command text inside a shell or alias.
/// Metadata writes get a before/after worktree check because hooks and filters
/// can also modify source files. Unknown commands remain conservative.
public WorkspaceCommandEffect workspaceCommandEffect(string program,
    const(string)[] args, out size_t commandAt)
{
    commandAt = 0;
    if (stripExtension(baseName(program)).toLower() != "git")
        return WorkspaceCommandEffect.unknown;
    while (commandAt < args.length)
    {
        const option = args[commandAt];
        if (option == "-C" && commandAt + 1 < args.length) commandAt += 2;
        else if (option == "--no-pager" || option == "--no-optional-locks" ||
            option == "--literal-pathspecs") ++commandAt;
        else break;
    }
    if (commandAt >= args.length) return WorkspaceCommandEffect.unknown;
    const verb = args[commandAt];
    const tail = args[commandAt + 1 .. $];
    // External diff/text-conversion programs are arbitrary executables.
    foreach (arg; tail)
        if (arg == "--ext-diff" || arg == "--textconv" ||
            arg == "--output" || arg.startsWith("--output=") ||
            arg == "-o" || arg.startsWith("-o="))
            return WorkspaceCommandEffect.unknown;
    switch (verb)
    {
        case "status", "log", "rev-parse", "ls-files", "ls-tree", "show-ref", "describe":
            return WorkspaceCommandEffect.readOnly;
        case "show", "diff", "diff-tree", "diff-index", "diff-files", "add", "commit":
            return WorkspaceCommandEffect.repositoryMetadata;
        case "config":
            size_t i;
            if (i < tail.length && (tail[i] == "--local" || tail[i] == "--global" || tail[i] == "--system")) ++i;
            if (i + 1 == tail.length && tail[i].length && tail[i][0] != '-')
                return WorkspaceCommandEffect.readOnly;
            if (i + 2 == tail.length && (tail[i] == "--get" || tail[i] == "--get-all"))
                return WorkspaceCommandEffect.readOnly;
            if (i + 1 == tail.length && (tail[i] == "--list" || tail[i] == "-l"))
                return WorkspaceCommandEffect.readOnly;
            break;
        default: break;
    }
    return WorkspaceCommandEffect.unknown;
}

/// Identify an executed checker, never words in arbitrary command text.
public string verificationCheck(string program, const(string)[] args)
{
    const name = stripExtension(baseName(program)).toLower();
    foreach (arg; args)
        if (arg == "--help" || arg == "-h" || arg == "--version" || arg == "-V" ||
            arg == "--collect-only" || arg == "--list-tests") return "";
    string first = args.length ? args[0] : "";
    if (name == "pytest" || name == "mypy") return name;
    if (name == "ruff" && first == "check") return "ruff check";
    if (name == "python" || name == "python3" || name == "py")
    {
        size_t cursor;
        while (cursor < args.length)
        {
            const option = args[cursor];
            if (option == "-u" || option == "-B" || option == "-E" ||
                option == "-I" || option == "-s" || option == "-S" ||
                option == "-O" || option == "-OO" || option == "-q")
                ++cursor;
            else if ((option == "-X" || option == "-W") && cursor + 1 < args.length)
                cursor += 2;
            else break;
        }
        if (cursor + 1 < args.length && args[cursor] == "-m" &&
            (args[cursor + 1] == "pytest" || args[cursor + 1] == "unittest" ||
                args[cursor + 1] == "mypy"))
            return args[cursor + 1];
    }
    if ((name == "dub" && (first == "test" || first == "build")) ||
        (name == "cargo" && (first == "test" || first == "build" ||
            first == "check" || first == "clippy")) ||
        (name == "go" && (first == "test" || first == "build" || first == "vet")))
        return name ~ " " ~ first;
    if (name == "npm" || name == "pnpm" || name == "yarn")
    {
        const script = first == "run" && args.length >= 2 ? args[1] : first;
        if (script == "test" || script == "build" || script == "lint" ||
            script == "check" || script == "typecheck") return name ~ " " ~ script;
    }
    if (name == "dmd" || name == "ldc2" || name == "gdc")
        foreach (arg; args)
            if (arg.length > 2 && arg[$ - 2 .. $] == ".d") return name ~ " compile";
    return "";
}

unittest
{
    assert(verificationCheck("echo", ["build"]) == "");
    assert(verificationCheck("python", ["-c", "print('test passed')"]) == "");
    assert(verificationCheck("git", ["checkout", "build"]) == "");
    assert(verificationCheck("cargo", ["--version"]) == "");
    assert(verificationCheck("cargo", ["test"]) == "cargo test");
    assert(verificationCheck("python", ["-m", "pytest"]) == "pytest");
    assert(verificationCheck("dmd", ["--help"]) == "");
}
