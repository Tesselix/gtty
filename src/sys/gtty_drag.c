// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Linux: drag files out of gtty under Wayland (see gtty_drag.h). Under
// X11 (or without libwayland-client) drag and drop is off.
//
// SDL owns the Wayland connection and keeps the serials of the input
// events to itself, but wl_data_device.start_drag needs the serial of the
// button press that holds the implicit grab. So gtty makes its own objects
// on SDL's wl_display, on a private event queue: a wl_seat, a wl_pointer
// (every pointer object of a seat gets the same events, so the press and
// its serial come here too) and a wl_data_device. SDL's reads fill the
// queue; gtty_drag_tick dispatches it.
//
// No Wayland headers: libwayland-client is opened with dlopen (the release
// binary is cross-compiled and must start without it), and the few
// requests are sent with wl_proxy_marshal_flags and the protocol's opcodes
// (wayland.xml, core protocol: stable, the same on every compositor).

#include "gtty_drag.h"

#include <SDL3/SDL.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct wl_proxy;
struct wl_display;
struct wl_event_queue;
// The start of libwayland's struct wl_interface (only the name is read).
struct wl_interface_head {
    const char *name;
    int version;
};

typedef void (*fn_t)(void);

static struct {
    struct wl_proxy *(*marshal_flags)(struct wl_proxy *, uint32_t, const struct wl_interface_head *, uint32_t, uint32_t, ...);
    int (*add_listener)(struct wl_proxy *, fn_t *, void *);
    uint32_t (*get_version)(struct wl_proxy *);
    void *(*create_wrapper)(void *);
    void (*wrapper_destroy)(void *);
    void (*set_queue)(struct wl_proxy *, struct wl_event_queue *);
    struct wl_event_queue *(*create_queue)(struct wl_display *);
    int (*roundtrip_queue)(struct wl_display *, struct wl_event_queue *);
    int (*dispatch_queue_pending)(struct wl_display *, struct wl_event_queue *);
    int (*flush)(struct wl_display *);
    const struct wl_interface_head *registry_if, *seat_if, *pointer_if, *ddm_if, *dd_if, *ds_if;
} W;

// Opcodes (requests) and flags from wayland.xml / wayland-client-core.h.
enum {
    MARSHAL_DESTROY = 1,
    DISPLAY_GET_REGISTRY = 1,
    REGISTRY_BIND = 0,
    SEAT_GET_POINTER = 0,
    SEAT_CAP_POINTER = 1,
    POINTER_BUTTON_PRESSED = 1,
    DDM_CREATE_DATA_SOURCE = 0,
    DDM_GET_DATA_DEVICE = 1,
    SOURCE_OFFER = 0,
    SOURCE_DESTROY = 1,
    SOURCE_SET_ACTIONS = 2, // since version 3
    DEVICE_START_DRAG = 0,
    OFFER_ACCEPT = 0,
    OFFER_RECEIVE = 1,
    OFFER_DESTROY = 2,
    OFFER_FINISH = 3,      // since version 3
    OFFER_SET_ACTIONS = 4, // since version 3
    ACTION_COPY = 1,
    ACTION_MOVE = 2,
};

static bool ok; // connected: seat, pointer, data device
static struct wl_display *display;
static struct wl_event_queue *queue;
static struct wl_proxy *registry, *seat, *pointer, *ddm, *device, *source;
static uint32_t press_serial;
static bool have_press;
static char *uri_list; // what the active drag offers (text/uri-list)
static bool active;
static bool dropped; // the active drag was dropped on gtty's own window
static bool dropped_move; // ... with the move key held

// Window drags (gtty_wdrag_*). Out: the source and what it carries, how
// it ended. In: the offer of the drag over gtty's window (a gtty window
// only), the one being read after a drop.
#define WIN_MIME "application/x-gtty-window"
static struct wl_proxy *wsource;
static char *wpayload;
static bool wperformed;
static int wresult;
static struct wl_proxy *pending_offer; // announced, not entered yet
static bool pending_win;               // ... carries a gtty window
static struct wl_proxy *offer_now;     // over gtty's window now
static uint32_t enter_serial;
static double at_x, at_y;
static struct wl_proxy *in_offer; // dropped, payload being read
static int in_fd = -1;
static char in_buf[1024];
static size_t in_len;
static bool in_ready;
static double in_x, in_y;

static uint32_t ver(struct wl_proxy *p) { return W.get_version(p); }

static bool load(void) {
    void *lib = dlopen("libwayland-client.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (lib == NULL) return false;
#define SYM(field, name)                         \
    do {                                         \
        *(void **)&W.field = dlsym(lib, name);   \
        if (W.field == NULL) return false;       \
    } while (0)
    SYM(marshal_flags, "wl_proxy_marshal_flags");
    SYM(add_listener, "wl_proxy_add_listener");
    SYM(get_version, "wl_proxy_get_version");
    SYM(create_wrapper, "wl_proxy_create_wrapper");
    SYM(wrapper_destroy, "wl_proxy_wrapper_destroy");
    SYM(set_queue, "wl_proxy_set_queue");
    SYM(create_queue, "wl_display_create_queue");
    SYM(roundtrip_queue, "wl_display_roundtrip_queue");
    SYM(dispatch_queue_pending, "wl_display_dispatch_queue_pending");
    SYM(flush, "wl_display_flush");
    SYM(registry_if, "wl_registry_interface");
    SYM(seat_if, "wl_seat_interface");
    SYM(pointer_if, "wl_pointer_interface");
    SYM(ddm_if, "wl_data_device_manager_interface");
    SYM(dd_if, "wl_data_device_interface");
    SYM(ds_if, "wl_data_source_interface");
#undef SYM
    return true;
}

// ---------------------------------------------------------------- pointer

static void p_enter(void *d, struct wl_proxy *p, uint32_t serial, struct wl_proxy *s, int32_t x, int32_t y) {
    (void)d, (void)p, (void)serial, (void)s, (void)x, (void)y;
}
static void p_leave(void *d, struct wl_proxy *p, uint32_t serial, struct wl_proxy *s) {
    (void)d, (void)p, (void)serial, (void)s;
}
static void p_motion(void *d, struct wl_proxy *p, uint32_t t, int32_t x, int32_t y) {
    (void)d, (void)p, (void)t, (void)x, (void)y;
}
// The press start_drag needs.
static void p_button(void *d, struct wl_proxy *p, uint32_t serial, uint32_t t, uint32_t button, uint32_t state) {
    (void)d, (void)p, (void)t, (void)button;
    if (state == POINTER_BUTTON_PRESSED) {
        press_serial = serial;
        have_press = true;
    }
}
static void p_axis(void *d, struct wl_proxy *p, uint32_t t, uint32_t axis, int32_t v) {
    (void)d, (void)p, (void)t, (void)axis, (void)v;
}
static void p_frame(void *d, struct wl_proxy *p) { (void)d, (void)p; }
static void p_axis_source(void *d, struct wl_proxy *p, uint32_t s) { (void)d, (void)p, (void)s; }
static void p_axis_stop(void *d, struct wl_proxy *p, uint32_t t, uint32_t axis) {
    (void)d, (void)p, (void)t, (void)axis;
}
static void p_axis_discrete(void *d, struct wl_proxy *p, uint32_t axis, int32_t v) {
    (void)d, (void)p, (void)axis, (void)v;
}
static fn_t pointer_listener[] = {
    (fn_t)p_enter, (fn_t)p_leave, (fn_t)p_motion, (fn_t)p_button, (fn_t)p_axis,
    (fn_t)p_frame, (fn_t)p_axis_source, (fn_t)p_axis_stop, (fn_t)p_axis_discrete,
};

// ---------------------------------------------------------------- seat

static void s_caps(void *d, struct wl_proxy *s, uint32_t caps) {
    (void)d;
    if ((caps & SEAT_CAP_POINTER) && pointer == NULL) {
        pointer = W.marshal_flags(s, SEAT_GET_POINTER, W.pointer_if, ver(s), 0, NULL);
        if (pointer) W.add_listener(pointer, pointer_listener, NULL);
    }
}
static void s_name(void *d, struct wl_proxy *s, const char *name) { (void)d, (void)s, (void)name; }
static fn_t seat_listener[] = {(fn_t)s_caps, (fn_t)s_name};

// ---------------------------------------------------------------- data device

// Offers of drags coming in: files and text are SDL's (its own data
// device); here only a gtty window (WIN_MIME) is taken, every other offer
// destroyed. A drop while gtty's own file drag is active lands on gtty's
// window: noted for gtty_drag_take_drop (SDL can't read the URI list
// then: the source's send waits for gtty_drag_tick).
static void dropOffer(struct wl_proxy **o) {
    if (*o) W.marshal_flags(*o, OFFER_DESTROY, NULL, ver(*o), MARSHAL_DESTROY);
    *o = NULL;
}
static void o_offer(void *d, struct wl_proxy *o, const char *mime) {
    (void)d;
    if (o == pending_offer && mime && strcmp(mime, WIN_MIME) == 0) pending_win = true;
}
static void o_actions(void *d, struct wl_proxy *o, uint32_t a) { (void)d, (void)o, (void)a; }
static fn_t offer_listener[] = {(fn_t)o_offer, (fn_t)o_actions, (fn_t)o_actions};

// Taking the gtty window: again on every motion (SDL's data device turns
// the same drag down on its own offer; the last answer counts).
static void acceptWin(void) {
    W.marshal_flags(offer_now, OFFER_ACCEPT, NULL, ver(offer_now), 0, enter_serial, WIN_MIME);
    if (ver(offer_now) >= 3) W.marshal_flags(offer_now, OFFER_SET_ACTIONS, NULL, ver(offer_now), 0, (uint32_t)ACTION_MOVE, (uint32_t)ACTION_MOVE);
}

static void d_offer(void *d, struct wl_proxy *dev, struct wl_proxy *offer) {
    (void)d, (void)dev;
    dropOffer(&pending_offer);
    pending_offer = offer;
    pending_win = false;
    if (offer) W.add_listener(offer, offer_listener, NULL);
}
static void d_enter(void *d, struct wl_proxy *dev, uint32_t serial, struct wl_proxy *s, int32_t x, int32_t y, struct wl_proxy *o) {
    (void)d, (void)dev, (void)s;
    dropOffer(&offer_now);
    if (o != NULL && o == pending_offer && pending_win) {
        offer_now = o;
        pending_offer = NULL;
        enter_serial = serial;
        at_x = x / 256.0;
        at_y = y / 256.0;
        acceptWin();
    } else if (o == pending_offer) {
        dropOffer(&pending_offer);
    }
}
static void d_leave(void *d, struct wl_proxy *dev) {
    (void)d, (void)dev;
    dropOffer(&offer_now);
}
static void d_motion(void *d, struct wl_proxy *dev, uint32_t t, int32_t x, int32_t y) {
    (void)d, (void)dev, (void)t;
    at_x = x / 256.0;
    at_y = y / 256.0;
    if (offer_now) acceptWin();
}
static void d_drop(void *d, struct wl_proxy *dev) {
    (void)d, (void)dev;
    if (active) {
        dropped = true;
        dropped_move = gtty_drag_move_key();
    }
    // A gtty window: read what it carries (the source writes it when its
    // gtty dispatches the request; gtty_drag_tick reads on).
    if (offer_now) {
        int p[2];
        dropOffer(&in_offer);
        if (in_fd >= 0) close(in_fd);
        in_fd = -1;
        if (pipe(p) == 0) {
            W.marshal_flags(offer_now, OFFER_RECEIVE, NULL, ver(offer_now), 0, WIN_MIME, p[1]);
            close(p[1]);
            fcntl(p[0], F_SETFL, fcntl(p[0], F_GETFL) | O_NONBLOCK);
            in_fd = p[0];
            in_len = 0;
            in_ready = false;
            in_x = at_x;
            in_y = at_y;
            in_offer = offer_now;
            offer_now = NULL;
        } else dropOffer(&offer_now);
        W.flush(display);
    }
}
static void d_selection(void *d, struct wl_proxy *dev, struct wl_proxy *o) {
    (void)d, (void)dev;
    if (o != NULL && o == pending_offer) dropOffer(&pending_offer);
}
static fn_t device_listener[] = {(fn_t)d_offer, (fn_t)d_enter, (fn_t)d_leave, (fn_t)d_motion, (fn_t)d_drop, (fn_t)d_selection};

// ---------------------------------------------------------------- data source

static void endDrag(void) {
    if (source) W.marshal_flags(source, SOURCE_DESTROY, NULL, ver(source), MARSHAL_DESTROY);
    source = NULL;
    free(uri_list);
    uri_list = NULL;
    active = false;
}

static void ds_target(void *d, struct wl_proxy *s, const char *mime) { (void)d, (void)s, (void)mime; }
// The drop target reads the files: the URI list into its pipe.
static void ds_send(void *d, struct wl_proxy *s, const char *mime, int32_t fd) {
    (void)d, (void)s;
    if (uri_list && mime && strcmp(mime, "text/uri-list") == 0) {
        const char *p = uri_list;
        size_t left = strlen(p);
        while (left > 0) {
            ssize_t n = write(fd, p, left);
            if (n <= 0) break;
            p += n;
            left -= (size_t)n;
        }
    }
    close(fd);
}
static void ds_cancelled(void *d, struct wl_proxy *s) { (void)d, (void)s, endDrag(); }
static void ds_performed(void *d, struct wl_proxy *s) { (void)d, (void)s; }
static void ds_finished(void *d, struct wl_proxy *s) { (void)d, (void)s, endDrag(); }
static void ds_action(void *d, struct wl_proxy *s, uint32_t a) { (void)d, (void)s, (void)a; }
static fn_t source_listener[] = {(fn_t)ds_target, (fn_t)ds_send, (fn_t)ds_cancelled, (fn_t)ds_performed, (fn_t)ds_finished, (fn_t)ds_action};

// A window drag's source: what it carries, and how it ended. Let go
// without a taker (drop performed, then cancelled) is "outside"; called
// off before a drop is "cancelled".
static void endWin(int result) {
    if (wsource) W.marshal_flags(wsource, SOURCE_DESTROY, NULL, ver(wsource), MARSHAL_DESTROY);
    wsource = NULL;
    free(wpayload);
    wpayload = NULL;
    wresult = result;
}
static void ws_send(void *d, struct wl_proxy *s, const char *mime, int32_t fd) {
    (void)d, (void)s;
    if (wpayload && mime && strcmp(mime, WIN_MIME) == 0) (void)!write(fd, wpayload, strlen(wpayload));
    close(fd);
}
static void ws_cancelled(void *d, struct wl_proxy *s) { (void)d, (void)s, endWin(wperformed ? GTTY_WDRAG_OUTSIDE : GTTY_WDRAG_CANCELLED); }
static void ws_performed(void *d, struct wl_proxy *s) { (void)d, (void)s, wperformed = true; }
static void ws_finished(void *d, struct wl_proxy *s) { (void)d, (void)s, endWin(GTTY_WDRAG_TAKEN); }
static fn_t win_source_listener[] = {(fn_t)ds_target, (fn_t)ws_send, (fn_t)ws_cancelled, (fn_t)ws_performed, (fn_t)ws_finished, (fn_t)ds_action};

// ---------------------------------------------------------------- registry

static void r_global(void *d, struct wl_proxy *r, uint32_t name, const char *iface, uint32_t v) {
    (void)d;
    if (strcmp(iface, "wl_seat") == 0 && seat == NULL) {
        uint32_t bv = v < 5 ? v : 5;
        seat = W.marshal_flags(r, REGISTRY_BIND, W.seat_if, bv, 0, name, W.seat_if->name, bv, NULL);
        if (seat) W.add_listener(seat, seat_listener, NULL);
    } else if (strcmp(iface, "wl_data_device_manager") == 0 && ddm == NULL) {
        uint32_t bv = v < 3 ? v : 3;
        ddm = W.marshal_flags(r, REGISTRY_BIND, W.ddm_if, bv, 0, name, W.ddm_if->name, bv, NULL);
    }
}
static void r_remove(void *d, struct wl_proxy *r, uint32_t name) { (void)d, (void)r, (void)name; }
static fn_t registry_listener[] = {(fn_t)r_global, (fn_t)r_remove};

// ---------------------------------------------------------------- API

void gtty_drag_init(void *sdl_window) {
    if (ok || display) return;
    const char *drv = SDL_GetCurrentVideoDriver();
    if (drv == NULL || strcmp(drv, "wayland") != 0) {
        fprintf(stderr, "gtty: drag and drop doesn't work on X11 (only under Wayland)\n");
        return;
    }
    SDL_PropertiesID props = SDL_GetWindowProperties((SDL_Window *)sdl_window);
    display = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, NULL);
    if (display == NULL || !load()) {
        fprintf(stderr, "gtty: drag and drop off (no Wayland client library)\n");
        display = NULL;
        return;
    }
    queue = W.create_queue(display);
    if (queue == NULL) return;
    // The registry (and every object made from it) on gtty's own queue.
    struct wl_proxy *wrapped = W.create_wrapper(display);
    if (wrapped == NULL) return;
    W.set_queue(wrapped, queue);
    registry = W.marshal_flags(wrapped, DISPLAY_GET_REGISTRY, W.registry_if, ver(wrapped), 0, NULL);
    W.wrapper_destroy(wrapped);
    if (registry == NULL) return;
    W.add_listener(registry, registry_listener, NULL);
    W.roundtrip_queue(display, queue); // the globals
    W.roundtrip_queue(display, queue); // the seat's capabilities
    if (seat == NULL || ddm == NULL || pointer == NULL) {
        fprintf(stderr, "gtty: drag and drop off (no Wayland seat / data device manager)\n");
        return;
    }
    device = W.marshal_flags(ddm, DDM_GET_DATA_DEVICE, W.dd_if, ver(ddm), 0, NULL, seat);
    if (device == NULL) return;
    W.add_listener(device, device_listener, NULL);
    W.flush(display);
    ok = true;
}

bool gtty_drag_supported(void) { return ok; }

void gtty_drag_tick(void) {
    if (!ok) return;
    W.dispatch_queue_pending(display, queue);
    // A gtty window dropped here: its payload, until the source closes.
    while (in_fd >= 0) {
        ssize_t n = read(in_fd, in_buf + in_len, sizeof in_buf - 1 - in_len);
        if (n > 0) {
            in_len += (size_t)n;
            if (in_len < sizeof in_buf - 1) continue;
        } else if (n < 0 && errno == EAGAIN) {
            break;
        }
        // The end (or too long, or an error): done with the offer.
        close(in_fd);
        in_fd = -1;
        in_buf[in_len] = 0;
        in_ready = in_len > 0;
        if (in_offer && ver(in_offer) >= 3) W.marshal_flags(in_offer, OFFER_FINISH, NULL, ver(in_offer), 0);
        dropOffer(&in_offer);
        W.flush(display);
    }
}

bool gtty_drag_active(void) { return active; }

bool gtty_drag_take_drop(bool *move) {
    bool d = dropped;
    if (move) *move = dropped_move;
    dropped = false;
    return d;
}

bool gtty_drag_move_key(void) { return (SDL_GetModState() & SDL_KMOD_SHIFT) != 0; }

// "file:///a%20b\r\n" per path (RFC 3986: unreserved and "/" stay).
static char *uriList(const char *const *paths, int n) {
    size_t cap = 1;
    for (int i = 0; i < n; i++) cap += 9 + 3 * strlen(paths[i]);
    char *out = malloc(cap);
    if (out == NULL) return NULL;
    char *o = out;
    for (int i = 0; i < n; i++) {
        memcpy(o, "file://", 7);
        o += 7;
        for (const unsigned char *p = (const unsigned char *)paths[i]; *p; p++) {
            unsigned char ch = *p;
            if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
                ch == '-' || ch == '.' || ch == '_' || ch == '~' || ch == '/') {
                *o++ = (char)ch;
            } else {
                o += sprintf(o, "%%%02X", ch);
            }
        }
        *o++ = '\r';
        *o++ = '\n';
    }
    *o = 0;
    return out;
}

bool gtty_drag_files(void *sdl_window, const char *const *paths, int n) {
    if (!ok || !have_press || paths == NULL || n <= 0) return false;
    // Whatever pumps came in since the press (its serial).
    W.dispatch_queue_pending(display, queue);
    SDL_PropertiesID props = SDL_GetWindowProperties((SDL_Window *)sdl_window);
    struct wl_proxy *surface = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, NULL);
    if (surface == NULL) return false;
    if (source) endDrag();
    uri_list = uriList(paths, n);
    if (uri_list == NULL) return false;
    source = W.marshal_flags(ddm, DDM_CREATE_DATA_SOURCE, W.ds_if, ver(ddm), 0, NULL);
    if (source == NULL) {
        endDrag();
        return false;
    }
    W.add_listener(source, source_listener, NULL);
    W.marshal_flags(source, SOURCE_OFFER, NULL, ver(source), 0, "text/uri-list");
    if (ver(source) >= 3) W.marshal_flags(source, SOURCE_SET_ACTIONS, NULL, ver(source), 0, (uint32_t)(ACTION_COPY | ACTION_MOVE));
    W.marshal_flags(device, DEVICE_START_DRAG, NULL, ver(device), 0, source, surface, NULL, press_serial);
    W.flush(display);
    active = true;
    dropped = false;
    return true;
}

bool gtty_wdrag_start(void *sdl_window, const char *payload) {
    if (!ok || !have_press || payload == NULL) return false;
    W.dispatch_queue_pending(display, queue);
    SDL_PropertiesID props = SDL_GetWindowProperties((SDL_Window *)sdl_window);
    struct wl_proxy *surface = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, NULL);
    if (surface == NULL) return false;
    if (wsource) endWin(GTTY_WDRAG_NONE);
    wpayload = strdup(payload);
    if (wpayload == NULL) return false;
    wsource = W.marshal_flags(ddm, DDM_CREATE_DATA_SOURCE, W.ds_if, ver(ddm), 0, NULL);
    if (wsource == NULL) {
        endWin(GTTY_WDRAG_NONE);
        return false;
    }
    W.add_listener(wsource, win_source_listener, NULL);
    W.marshal_flags(wsource, SOURCE_OFFER, NULL, ver(wsource), 0, WIN_MIME);
    if (ver(wsource) >= 3) W.marshal_flags(wsource, SOURCE_SET_ACTIONS, NULL, ver(wsource), 0, (uint32_t)ACTION_MOVE);
    W.marshal_flags(device, DEVICE_START_DRAG, NULL, ver(device), 0, wsource, surface, NULL, press_serial);
    W.flush(display);
    wperformed = false;
    wresult = GTTY_WDRAG_NONE;
    return true;
}

int gtty_wdrag_result(void) {
    int r = wresult;
    wresult = GTTY_WDRAG_NONE;
    return r;
}

bool gtty_wdrag_take_incoming(char *buf, int cap, double *x, double *y) {
    if (!in_ready || cap <= 0) return false;
    in_ready = false;
    size_t n = in_len < (size_t)cap - 1 ? in_len : (size_t)cap - 1;
    memcpy(buf, in_buf, n);
    buf[n] = 0;
    *x = in_x;
    *y = in_y;
    return true;
}
