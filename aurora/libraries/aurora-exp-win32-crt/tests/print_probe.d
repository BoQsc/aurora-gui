// SPDX-License-Identifier: 0BSD
/// Zero-CRT probe: Aurora's formatter writes to stdout without Microsoft stdio.
module print_probe;

extern(C) int printf(const char* format, ...);

void main()
{
    printf("zero-crt %d\n", 7);
}
