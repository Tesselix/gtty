#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# For test/mouse.gt: asks for mouse reports (drags, SGR), reads what
# comes until 2 s pass with nothing, prints it (ESC as "\033"), turns
# the reports off again.
printf '\033[?1002h\033[?1006h'
old=$(stty -g)
stty -icanon -echo min 0 time 20
got=$(cat | od -An -c | tr -d ' \n')
stty "$old"
printf '\033[?1002l\033[?1006l'
echo "got: $got"
