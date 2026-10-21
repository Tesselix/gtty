// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Files on the system clipboard, as file managers put them there: one
// Copy that the app pasting into reads its own way (Finder / Files: the
// files; a text field: the paths).
//   macOS: NSPasteboard, one item per file (public.file-url), the first
//   also with the paths as text.
//   Linux: SDL's clipboard with text/uri-list,
//   x-special/gnome-copied-files and the paths as text.
#pragma once

// Put `n` absolute paths on the clipboard (files + their paths as text,
// one per line). 0: done.
int gtty_fileclip_set(const char *const *paths, int n);

// The local files on the clipboard (copied in gtty, Finder, Files…):
// their paths, one per line (malloc'd, the caller frees), or NULL when
// it holds no files.
char *gtty_fileclip_get(void);
