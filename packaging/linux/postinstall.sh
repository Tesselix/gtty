#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# Let the desktop see the new / removed launcher and icons at once.
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
# The repository's key, renewed: only where the user set up gtty's apt
# repository (README), and only when it changed.
if [ -f /usr/share/keyrings/gtty.asc ] && [ -f /usr/share/gtty/gtty.asc ] &&
    ! cmp -s /usr/share/gtty/gtty.asc /usr/share/keyrings/gtty.asc; then
    cp /usr/share/gtty/gtty.asc /usr/share/keyrings/gtty.asc || true
fi
exit 0
