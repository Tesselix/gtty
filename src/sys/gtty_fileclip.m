// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// macOS: files on the general pasteboard (see gtty_fileclip.h).
#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <string.h>
#include "gtty_fileclip.h"

int gtty_fileclip_set(const char *const *paths, int n) {
    @autoreleasepool {
        if (paths == NULL || n <= 0) return -1;
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:n];
        NSMutableArray *lines = [NSMutableArray arrayWithCapacity:n];
        for (int i = 0; i < n; i++) {
            NSString *p = [NSString stringWithUTF8String:paths[i]];
            if (p == nil) continue;
            [lines addObject:p];
            NSPasteboardItem *it = [[NSPasteboardItem alloc] init];
            [it setString:[[NSURL fileURLWithPath:p] absoluteString] forType:NSPasteboardTypeFileURL];
            [items addObject:it];
        }
        if (items.count == 0) return -1;
        // Text apps read the first item's string: every path, one per line.
        [items[0] setString:[lines componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        return [pb writeObjects:items] ? 0 : -1;
    }
}

char *gtty_fileclip_get(void) {
    @autoreleasepool {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        NSArray *urls = [pb readObjectsForClasses:@[ [NSURL class] ]
                                          options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];
        NSMutableArray *lines = [NSMutableArray array];
        for (NSURL *u in urls) {
            NSString *p = u.path;
            if (p.length > 0 && [p rangeOfString:@"\n"].location == NSNotFound) [lines addObject:p];
        }
        if (lines.count == 0) return NULL;
        return strdup([[lines componentsJoinedByString:@"\n"] UTF8String]);
    }
}
