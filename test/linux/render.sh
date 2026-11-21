#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# For 06-render.gt: one screen of what gtty draws, then cursor shapes.
printf 'plain \033[1mbold\033[0m \033[3mitalic\033[0m \033[1;3mbold italic\033[0m \033[2mdim\033[0m \033[4munder\033[0m \033[7minverse\033[0m\n'
printf '\033[31mred \033[1;31mbright\033[0m \033[32mgreen \033[33myellow \033[34mblue \033[35mmagenta \033[36mcyan\033[0m\n'
printf '\033(0lqqqqwqqqqk\nx    x    x\ntqqqqnqqqqu\nmqqqqvqqqqj\033(B  A\033[9bZ\n'
printf '┌──┬──┐ ┏━━┳━━┓ ╭──╮ ╔══╗\n│  │  │ ┃  ┃  ┃ │  │ ║  ║\n└──┴──┘ ┗━━┻━━┛ ╰──╯ ╚══╝\n'
i=16; while [ $i -lt 52 ]; do printf '\033[48;5;%dm  ' $i; i=$((i + 1)); done; printf '\033[0m\n'
i=0; while [ $i -lt 36 ]; do printf '\033[48;2;%d;%d;200m  ' $((i * 7)) $((255 - i * 7)); i=$((i + 1)); done; printf '\033[0m\n'
printf 'emoji 😀 👍 ✅ 🚀 | 漢字 かな 한글 | café é ñ | ✓ → ★ ⚠\n'
printf '\033[1mBOLD\033[3D\033[2 q'; sleep 3
printf '\n\033[4 q'; sleep 3; echo
