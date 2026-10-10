module auroraopencode.verification;

import std.path : baseName, stripExtension;
import std.string : toLower;

public struct VerificationEvidence
{
    string check;
    string workspace;
    ulong revision;
    bool passed;
    int exitCode = int.min;
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
