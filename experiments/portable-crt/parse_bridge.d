// SPDX-License-Identifier: BSL-1.0
// Copyright (c) 2026 Aurora OpenCode contributors
module aurora_portable_crt.parse_bridge;

extern(C)
{
    double aurora_crt_strtod(const char*, char**);

    double strtod(const char* input, char** endPointer)
    {
        return aurora_crt_strtod(input, endPointer);
    }
}
