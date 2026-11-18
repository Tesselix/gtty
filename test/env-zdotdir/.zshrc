# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
PROMPT='%1~ %# '
export EDITOR=nvim
path=($HOME/gtty-demo-bin $path)
alias ll='ls -l'
[[ -f $ZDOTDIR/.aliases ]] && source $ZDOTDIR/.aliases
export GTTY_DEMO_VAR="${GTTY_DEMO_VAR}:second"
if gtty-no-such-tool --check 2>/dev/null; then export GTTY_MAYBE=yes; else export GTTY_MAYBE=no; fi
eval "$(gtty-no-such-tool init zsh 2>/dev/null)"
