// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// macOS: the window under a screen point (see gtty_ctl.h). The window
// server's list, front to back: bounds and owner need no permission
// (only window titles would ask for screen recording).
#import <Cocoa/Cocoa.h>
#include <unistd.h>
#include "gtty_ctl.h"

int gtty_window_at(void *sdl_window, double x, double y, int *pid) {
    (void)sdl_window;
    @autoreleasepool {
        CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
        if (list == NULL) return -1;
        int self = (int)getpid();
        int found = 0;
        for (CFIndex i = 0; i < CFArrayGetCount(list) && !found; i++) {
            NSDictionary *w = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
            // Normal windows only (menus, the Dock, overlays have others).
            if ([w[(id)kCGWindowLayer] intValue] != 0) continue;
            if ([w[(id)kCGWindowAlpha] doubleValue] <= 0) continue;
            int owner = [w[(id)kCGWindowOwnerPID] intValue];
            if (owner == self) continue;
            CGRect r;
            if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r)) continue;
            if (CGRectContainsPoint(r, CGPointMake(x, y))) {
                *pid = owner;
                found = 1;
            }
        }
        CFRelease(list);
        return found;
    }
}
