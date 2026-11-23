module policy_module;

extern(C) export int _DllMainCRTStartup(void*, uint, void*)
{
    return 1;
}

extern(C) export int aurora_module_abi()
{
    return 2;
}

extern(C) export int aurora_module_protect()
{
    return 1;
}
