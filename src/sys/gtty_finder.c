// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Linux: Show in Files and Properties through the desktop's file manager
// (see gtty_finder.h).
#include "gtty_finder.h"

#include <limits.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

// `name` is an executable in $PATH; its full path in `out`.
static bool findInPath(const char *name, char *out, size_t cap) {
    const char *p = getenv("PATH");
    if (p == NULL) return false;
    while (*p) {
        const char *e = strchr(p, ':');
        size_t n = e ? (size_t)(e - p) : strlen(p);
        if (n > 0 && snprintf(out, cap, "%.*s/%s", (int)n, p, name) < (int)cap && access(out, X_OK) == 0) return true;
        if (!e) break;
        p = e + 1;
    }
    return false;
}

// Run argv detached (double fork: gtty reaps the child at once, nobody
// waits for the grandchild). 0: started.
static int spawnDetached(const char *const *argv) {
    pid_t child = fork();
    if (child < 0) return -1;
    if (child == 0) {
        pid_t pid;
        int rc = posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, environ);
        _exit(rc == 0 ? 0 : 1);
    }
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {}
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

static bool hasSessionBus(void) {
    return getenv("DBUS_SESSION_BUS_ADDRESS") != NULL || getenv("XDG_RUNTIME_DIR") != NULL;
}

// `paths` as a GVariant string array of file:// URIs: ['file:///a%20b'].
// Everything but unreserved characters and '/' is %-encoded, so no quote
// or backslash is left to escape. False: too long.
static bool uriArray(const char *const *paths, int n, char *out, size_t cap) {
    static const char hex[] = "0123456789ABCDEF";
    size_t k = 0;
#define PUT(ch) do { if (k + 1 >= cap) return false; out[k++] = (ch); } while (0)
    PUT('[');
    for (int i = 0; i < n; i++) {
        if (i > 0) PUT(',');
        const char *pre = "'file://";
        for (const char *q = pre; *q; q++) PUT(*q);
        for (const unsigned char *s = (const unsigned char *)paths[i]; *s; s++) {
            unsigned char ch = *s;
            if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '.' || ch == '_' || ch == '~' || ch == '/') {
                PUT((char)ch);
            } else {
                PUT('%');
                PUT(hex[ch >> 4]);
                PUT(hex[ch & 15]);
            }
        }
        PUT('\'');
    }
    PUT(']');
#undef PUT
    out[k] = 0;
    return true;
}

// org.freedesktop.FileManager1.<method>(uris, startup id "").
static int fileManager1(const char *method, const char *const *paths, int n) {
    char gdbus[PATH_MAX];
    if (!hasSessionBus() || !findInPath("gdbus", gdbus, sizeof gdbus)) return -1;
    static char uris[64 * 1024];
    if (!uriArray(paths, n, uris, sizeof uris)) return -1;
    char full[128];
    snprintf(full, sizeof full, "org.freedesktop.FileManager1.%s", method);
    const char *argv[] = { gdbus, "call", "--session", "--dest", "org.freedesktop.FileManager1",
                           "--object-path", "/org/freedesktop/FileManager1", "--method", full, uris, "", NULL };
    return spawnDetached(argv);
}

int gtty_reveal(const char *const *paths, int n) {
    if (n <= 0) return -1;
    if (fileManager1("ShowItems", paths, n) == 0) return 0;
    // No FileManager1: the first item's folder, as the folder button.
    char xdg[PATH_MAX];
    if (!findInPath("xdg-open", xdg, sizeof xdg)) return -1;
    char dir[PATH_MAX];
    snprintf(dir, sizeof dir, "%s", paths[0]);
    char *slash = strrchr(dir, '/');
    if (slash == NULL) return -1;
    if (slash == dir) slash[1] = 0; else *slash = 0;
    const char *argv[] = { xdg, dir, NULL };
    return spawnDetached(argv);
}

bool gtty_info_supported(void) {
    char gdbus[PATH_MAX];
    return hasSessionBus() && findInPath("gdbus", gdbus, sizeof gdbus);
}

int gtty_show_info(const char *const *paths, int n) {
    if (n <= 0) return -1;
    return fileManager1("ShowItemProperties", paths, n);
}
