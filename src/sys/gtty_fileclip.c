// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Linux: files on SDL's clipboard (X11 / Wayland; see gtty_fileclip.h).
#include <SDL3/SDL.h>
#include <stdlib.h>
#include <string.h>
#include "gtty_fileclip.h"

// What the clipboard offers while gtty owns it (freed by SDL's cleanup).
struct offer {
    char *uris;  // text/uri-list: file:// URIs, CRLF after each
    char *gnome; // x-special/gnome-copied-files: "copy\n" + URIs, \n apart
    char *text;  // the paths, one per line
};

static const char *const mimes[] = {
    "text/uri-list", "x-special/gnome-copied-files", "text/plain;charset=utf-8", "text/plain", "UTF8_STRING",
};

static const void *offer_data(void *ud, const char *mime, size_t *size) {
    struct offer *o = ud;
    const char *d = o->text;
    if (strcmp(mime, "text/uri-list") == 0) d = o->uris;
    else if (strcmp(mime, "x-special/gnome-copied-files") == 0) d = o->gnome;
    *size = strlen(d);
    return d;
}

static void offer_free(void *ud) {
    struct offer *o = ud;
    free(o->uris);
    free(o->gnome);
    free(o->text);
    free(o);
}

// `p` as a file:// URI (unreserved characters and / kept, the rest %XX).
static size_t uri_append(char *out, const char *p) {
    static const char hex[] = "0123456789ABCDEF";
    size_t n = 0;
    memcpy(out, "file://", 7);
    n = 7;
    for (const unsigned char *s = (const unsigned char *)p; *s; s++) {
        unsigned char ch = *s;
        if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || strchr("/-._~", ch)) {
            out[n++] = (char)ch;
        } else {
            out[n++] = '%';
            out[n++] = hex[ch >> 4];
            out[n++] = hex[ch & 15];
        }
    }
    return n;
}

int gtty_fileclip_set(const char *const *paths, int n) {
    if (paths == NULL || n <= 0) return -1;
    size_t cap = 16, tcap = 1;
    for (int i = 0; i < n; i++) {
        cap += strlen(paths[i]) * 3 + 10;
        tcap += strlen(paths[i]) + 1;
    }
    struct offer *o = calloc(1, sizeof *o);
    if (o == NULL) return -1;
    o->uris = malloc(cap);
    o->gnome = malloc(cap + 8);
    o->text = malloc(tcap);
    if (!o->uris || !o->gnome || !o->text) {
        offer_free(o);
        return -1;
    }
    size_t u = 0, g = 0, t = 0;
    memcpy(o->gnome, "copy", 4);
    g = 4;
    for (int i = 0; i < n; i++) {
        o->gnome[g++] = '\n';
        g += uri_append(o->gnome + g, paths[i]);
        u += uri_append(o->uris + u, paths[i]);
        o->uris[u++] = '\r';
        o->uris[u++] = '\n';
        if (i > 0) o->text[t++] = '\n';
        size_t l = strlen(paths[i]);
        memcpy(o->text + t, paths[i], l);
        t += l;
    }
    o->uris[u] = 0;
    o->gnome[g] = 0;
    o->text[t] = 0;
    if (!SDL_SetClipboardData(offer_data, offer_free, o, mimes, sizeof mimes / sizeof mimes[0])) {
        offer_free(o);
        return -1;
    }
    return 0;
}

static int unhex(char ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

char *gtty_fileclip_get(void) {
    if (!SDL_HasClipboardData("text/uri-list")) return NULL;
    size_t size = 0;
    char *raw = SDL_GetClipboardData("text/uri-list", &size);
    if (raw == NULL) return NULL;
    char *out = malloc(size + 1);
    size_t n = 0;
    if (out != NULL) {
        const char *s = raw, *end = raw + size;
        while (s < end) {
            const char *e = s;
            while (e < end && *e != '\n' && *e != '\r') e++;
            // file:///path or file://host/path (a local file either way).
            if (e - s > 7 && *s != '#' && strncmp(s, "file://", 7) == 0) {
                const char *p = s + 7;
                while (p < e && *p != '/') p++;
                size_t start = n;
                if (n > 0) out[n++] = '\n';
                size_t first = n;
                int bad = 0;
                for (; p < e; p++) {
                    if (*p == '%' && e - p > 2 && unhex(p[1]) >= 0 && unhex(p[2]) >= 0) {
                        char ch = (char)(unhex(p[1]) * 16 + unhex(p[2]));
                        if (ch == '\n' || ch == 0) bad = 1;
                        out[n++] = ch;
                        p += 2;
                    } else out[n++] = *p;
                }
                if (bad || n == first) n = start;
            }
            s = e;
            while (s < end && (*s == '\n' || *s == '\r')) s++;
        }
        out[n] = 0;
    }
    SDL_free(raw);
    if (out != NULL && n == 0) {
        free(out);
        return NULL;
    }
    return out;
}
