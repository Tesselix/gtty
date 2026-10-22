// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// macOS: Show in Finder and Get Info (see gtty_finder.h).
#import <Cocoa/Cocoa.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include "gtty_finder.h"

extern char **environ;

int gtty_reveal(const char *const *paths, int n) {
    @autoreleasepool {
        NSMutableArray<NSURL *> *urls = [NSMutableArray array];
        for (int i = 0; i < n; i++) {
            NSString *p = [NSString stringWithUTF8String:paths[i]];
            if (p != nil) [urls addObject:[NSURL fileURLWithPath:p]];
        }
        if ([urls count] == 0) return -1;
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:urls];
        return 0;
    }
}

bool gtty_info_supported(void) { return true; }

// Finder's information window for each path (the paths go in as the
// script's arguments: no quoting). osascript runs detached: the first
// time, macOS asks the user whether gtty may control Finder, and gtty
// must not wait for that answer.
int gtty_show_info(const char *const *paths, int n) {
    if (n <= 0) return -1;
    enum { max_paths = 32 };
    if (n > max_paths) n = max_paths;
    const char *argv[8 + max_paths + 1];
    int k = 0;
    argv[k++] = "/usr/bin/osascript";
    argv[k++] = "-e";
    argv[k++] = "on run argv";
    argv[k++] = "-e";
    argv[k++] = "tell application \"Finder\"\nrepeat with p in argv\nopen information window of (POSIX file (p as text) as alias)\nend repeat\nactivate\nend tell";
    argv[k++] = "-e";
    argv[k++] = "end run";
    for (int i = 0; i < n; i++) argv[k++] = paths[i];
    argv[k] = NULL;

    pid_t child = fork();
    if (child < 0) return -1;
    if (child == 0) {
        // The grandchild runs osascript; this child ends at once so gtty
        // reaps it now and the grandchild is nobody's zombie.
        pid_t pid;
        int rc = posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, environ);
        _exit(rc == 0 ? 0 : 1);
    }
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {}
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}
