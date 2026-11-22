// SPDX-License-Identifier: 0BSD
/// Zero-CRT probe: Aurora's `exit` must terminate with the requested code.
module exit_probe;

import core.stdc.stdlib : exit;

void main()
{
    exit(7);
}
