// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// The system's file manager for the right-click menus' Show in Finder and
// Get Info rows.
//   macOS: Show in Finder = NSWorkspace activateFileViewerSelectingURLs
//   (no permission needed); Get Info = Finder's information window,
//   asked through `osascript` (Apple Events: the first time macOS asks the
//   user to let gtty control Finder).
//   Linux: the desktop's file manager over D-Bus
//   (org.freedesktop.FileManager1 ShowItems / ShowItemProperties, through
//   `gdbus`); no gdbus: Show opens the folder with xdg-open, no
//   properties.
// The helpers run detached (double fork), so gtty never waits for them.
#pragma once
#include <stdbool.h>

// The file manager shows `paths` (absolute), selected in their folder.
// 0: asked.
int gtty_reveal(const char *const *paths, int n);

// The file manager can show an item's info / properties window.
bool gtty_info_supported(void);

// The file manager's info / properties window for each of `paths`
// (absolute). 0: asked.
int gtty_show_info(const char *const *paths, int n);
