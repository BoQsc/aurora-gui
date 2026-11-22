// SPDX-License-Identifier: 0BSD
/// COFF reader probe: a module with a function and a data symbol.
module probe;

int counter = 3;

int add(int left, int right)
{
    return left + right + counter;
}
