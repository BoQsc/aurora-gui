module v3_module_main;

version (ModuleV1)
{
    private enum label = "v1";
    private enum versionNumber = 1;
}
else
{
    private enum label = "v2";
    private enum versionNumber = 2;
}

extern(C) export uint aurora_v3_module_version()
{
    return versionNumber;
}

extern(C) export const(char)* aurora_v3_module_label()
{
    return label.ptr;
}

extern(C) export uint aurora_v3_module_abi()
{
    return 1;
}

int main()
{
    import std.stdio : writeln;
    writeln("MODULE ", versionNumber, " ", label, " ABI 1");
    return 0;
}
