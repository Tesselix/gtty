// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Linux, X11: the window under a screen point (see gtty_ctl.h), from the
// window manager's stacking list (EWMH _NET_CLIENT_LIST_STACKING, bottom
// to top) and each window's _NET_WM_PID. libX11 is opened with dlopen
// (SDL has loaded it already under X11; no headers needed). Wayland
// doesn't tell a client where other windows are: -1 there (window drags
// use drag and drop instead, gtty_drag.c).

#include "gtty_ctl.h"

#include <SDL3/SDL.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>

typedef unsigned long XID;
typedef XID Window;
typedef XID Atom;
typedef struct _XDisplay Display;

static struct {
    Atom (*intern)(Display *, const char *, int);
    int (*get_prop)(Display *, Window, Atom, long, long, int, Atom, Atom *, int *, unsigned long *, unsigned long *, unsigned char **);
    int (*free_)(void *);
    Window (*root)(Display *);
    int (*translate)(Display *, Window, Window, int, int, int *, int *, Window *);
    int (*geometry)(Display *, Window, Window *, int *, int *, unsigned *, unsigned *, unsigned *, unsigned *);
} X;

static int load(void) {
    static int loaded = -1;
    if (loaded >= 0) return loaded;
    loaded = 0;
    void *lib = dlopen("libX11.so.6", RTLD_NOW | RTLD_GLOBAL);
    if (lib == NULL) return 0;
#define SYM(field, name)                       \
    do {                                       \
        *(void **)&X.field = dlsym(lib, name); \
        if (X.field == NULL) return 0;         \
    } while (0)
    SYM(intern, "XInternAtom");
    SYM(get_prop, "XGetWindowProperty");
    SYM(free_, "XFree");
    SYM(root, "XDefaultRootWindow");
    SYM(translate, "XTranslateCoordinates");
    SYM(geometry, "XGetGeometry");
#undef SYM
    loaded = 1;
    return 1;
}

// A property of 32-bit items (returned as longs by Xlib); free with XFree.
static unsigned long *prop(Display *d, Window w, const char *name, unsigned long *n) {
    Atom type;
    int format;
    unsigned long after;
    unsigned char *data = NULL;
    *n = 0;
    if (X.get_prop(d, w, X.intern(d, name, 0), 0, 4096, 0, 0 /* AnyPropertyType */, &type, &format, n, &after, &data) != 0) return NULL;
    if (data == NULL || format != 32) {
        if (data) X.free_(data);
        *n = 0;
        return NULL;
    }
    return (unsigned long *)data;
}

static int has_atom(Display *d, Window w, const char *list, const char *name) {
    unsigned long n;
    unsigned long *v = prop(d, w, list, &n);
    if (v == NULL) return 0;
    Atom a = X.intern(d, name, 0);
    int yes = 0;
    for (unsigned long i = 0; i < n; i++)
        if (v[i] == a) yes = 1;
    X.free_(v);
    return yes;
}

int gtty_window_at(void *sdl_window, double x, double y, int *pid) {
    const char *drv = SDL_GetCurrentVideoDriver();
    if (drv == NULL || strcmp(drv, "x11") != 0) return -1;
    Display *d = SDL_GetPointerProperty(SDL_GetWindowProperties((SDL_Window *)sdl_window), SDL_PROP_WINDOW_X11_DISPLAY_POINTER, NULL);
    if (d == NULL || !load()) return -1;
    Window root = X.root(d);
    unsigned long n;
    unsigned long *list = prop(d, root, "_NET_CLIENT_LIST_STACKING", &n);
    if (list == NULL) return -1;
    unsigned long cur_n;
    unsigned long *cur = prop(d, root, "_NET_CURRENT_DESKTOP", &cur_n);
    long desktop = cur && cur_n > 0 ? (long)cur[0] : -1;
    if (cur) X.free_(cur);
    int self = (int)getpid();
    int found = 0;
    for (unsigned long i = n; i > 0 && !found; i--) {
        Window w = list[i - 1];
        // On another workspace, or minimized: not on screen.
        unsigned long k;
        unsigned long *on = prop(d, w, "_NET_WM_DESKTOP", &k);
        int elsewhere = on && k > 0 && desktop >= 0 && on[0] != 0xFFFFFFFFul && (long)on[0] != desktop;
        if (on) X.free_(on);
        if (elsewhere || has_atom(d, w, "_NET_WM_STATE", "_NET_WM_STATE_HIDDEN")) continue;
        Window r, child;
        int gx, gy, rx, ry;
        unsigned gw, gh, border, depth;
        if (!X.geometry(d, w, &r, &gx, &gy, &gw, &gh, &border, &depth)) continue;
        if (!X.translate(d, w, root, 0, 0, &rx, &ry, &child)) continue;
        if (x < rx || y < ry || x >= rx + (double)gw || y >= ry + (double)gh) continue;
        // The desktop's own window (icons on the desktop) counts as none.
        if (has_atom(d, w, "_NET_WM_WINDOW_TYPE", "_NET_WM_WINDOW_TYPE_DESKTOP")) break;
        unsigned long *p = prop(d, w, "_NET_WM_PID", &k);
        int owner = p && k > 0 ? (int)p[0] : 0;
        if (p) X.free_(p);
        if (owner == self) continue;
        *pid = owner;
        found = 1;
    }
    X.free_(list);
    return found;
}
