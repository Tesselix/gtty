// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Moving job windows between gtty processes (App "window drag",
// core/Handoff.zig).
//
// Every gtty listens on a Unix socket in its temp folder
// (`$TMPDIR/gtty-<pid>/ctl.sock`, the folder is 0700). A message is a
// 4-byte length (host order: both ends are on the same machine) and that
// many bytes of text; open file descriptors (a job's PTY, its keeper's
// status pipe, its output file) travel with it (SCM_RIGHTS). Only
// processes of the same user are answered.
#pragma once

// A non-blocking listening socket at `path` (a stale one is removed
// first), or -1.
int gtty_ctl_listen(const char *path);

// A waiting connection from the same user, blocking with a few seconds'
// timeout for its reads and writes; -1 when there is none.
int gtty_ctl_accept(int listen_fd);

// Connect to another gtty's socket (same timeouts), or -1.
int gtty_ctl_connect(const char *path);

// Send one message with `nfds` descriptors (≤ 4). 0: sent.
int gtty_ctl_send(int fd, const char *buf, unsigned long len, const int *fds, int nfds);

// Read one message (≤ cap bytes) and the descriptors that came with it
// (at most `maxfds`; *nfds how many, each close-on-exec). Its length, or
// -1 (closed, timed out, too long).
long gtty_ctl_recv(int fd, char *buf, unsigned long cap, int *fds, int maxfds, int *nfds);

// The window under the screen point (x, y) (global coordinates, as SDL's
// window positions; macOS points), other than this process's:
// 1 and *pid its process; 0 none (the desktop); -1 can't tell (Wayland:
// see gtty_wdrag_* in gtty_drag.h).
int gtty_window_at(void *sdl_window, double x, double y, int *pid);
