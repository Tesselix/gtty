#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# For test/keys.gt: reads the keys until 2 s pass with nothing, prints
# what came (ESC as 033), one od line.
old=$(stty -g)
stty -icanon -echo min 0 time 20
got=$(cat | od -An -c | tr -d ' \n')
stty "$old"
echo "got: $got"
