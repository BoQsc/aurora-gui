module v3_module_entry;

version (ModuleV1)
{
    private immutable string label = "v1";
    private immutable uint version = 1;
}
else
{
    private immutable string label = "v2";
    private immutable uint version = 2;
}

extern(C) export uint aurora_v3_module_version()
{
    return version;
}

extern(C) export const(char)* aurora_v3_module_label()
{
    return label.ptr;
}

extern(C) export uint aurora_v3_module_abi()
{
    return 1;
}
