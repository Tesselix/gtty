// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Starting an extension as a child process (chips/Proc.zig,
// docs/protocol.md): its socket on fd 3, stdout and stderr on pipes,
// stdin /dev/null, its own process group, in its folder. On Linux it gets
// SIGTERM when gtty dies; everywhere the socket closing tells it.
#pragma once
#include <sys/types.h>

// `path` is the program (a full path), `argv` / `env` NULL-terminated
// (`env` the whole environment). Returns the pid, or -errno; `*sock`,
// `*out`, `*err` are gtty's ends, non-blocking and close-on-exec.
int gtty_ext_spawn(const char *path, const char *const argv[], const char *const env[],
                   const char *cwd, int *sock, int *out, int *err);

// No more writes on the socket: the extension reads its end.
void gtty_ext_shutdown_write(int sock);

// Signal the extension's process group (and the process itself).
void gtty_ext_signal(int pid, int sig);

// 1: it has ended (reaped; `*status` its exit code, or 128 + signal),
// 0: still running, -1: not our child.
int gtty_ext_reap(int pid, int *status);

// The developer socket (docs/protocol.md "Development"): an extension the
// IDE started connects to it. Listen on `path` (removed first, then 0600):
// the listening fd, non-blocking, or -errno.
int gtty_ext_listen(const char *path);

// One waiting connection from a process of this user: its fd
// (non-blocking, close-on-exec) and `*pid` (0 when unknown); -1 when none
// waits. Another user's connection is closed and skipped.
int gtty_ext_accept(int lfd, int *pid);
