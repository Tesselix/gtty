// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// gtty's control socket: messages with file descriptors between gtty
// processes of one user (see gtty_ctl.h).

#define _GNU_SOURCE
#include "gtty_ctl.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#define MAX_FDS 4
#define TIMEOUT_S 3

static void set_cloexec(int fd) {
    int fdfl = fcntl(fd, F_GETFD);
    if (fdfl >= 0) fcntl(fd, F_SETFD, fdfl | FD_CLOEXEC);
}

// Sockets only: O_NONBLOCK belongs to the open file, which a descriptor
// passed to another gtty shares with the sender (a PTY made blocking
// would block both).
static void set_flags(int fd, int nonblock) {
    int fl = fcntl(fd, F_GETFL);
    if (fl >= 0) fcntl(fd, F_SETFL, nonblock ? (fl | O_NONBLOCK) : (fl & ~O_NONBLOCK));
    set_cloexec(fd);
}

static void set_timeouts(int fd) {
    struct timeval tv = {.tv_sec = TIMEOUT_S, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
}

static int fill_addr(struct sockaddr_un *a, const char *path) {
    memset(a, 0, sizeof *a);
    a->sun_family = AF_UNIX;
    size_t n = strlen(path);
    if (n == 0 || n >= sizeof a->sun_path) return -1;
    memcpy(a->sun_path, path, n);
    return 0;
}

// The other end runs as the same user.
static int same_user(int fd) {
#if defined(__APPLE__)
    uid_t uid;
    gid_t gid;
    if (getpeereid(fd, &uid, &gid) != 0) return 0;
    return uid == getuid();
#else
    struct ucred cr;
    socklen_t len = sizeof cr;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cr, &len) != 0) return 0;
    return cr.uid == getuid();
#endif
}

int gtty_ctl_listen(const char *path) {
    struct sockaddr_un a;
    if (fill_addr(&a, path) != 0) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    unlink(path);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0 || listen(fd, 4) != 0) {
        close(fd);
        return -1;
    }
    set_flags(fd, 1);
    return fd;
}

int gtty_ctl_accept(int listen_fd) {
    if (listen_fd < 0) return -1;
    for (;;) {
        int fd = accept(listen_fd, NULL, NULL);
        if (fd < 0) return -1; // EAGAIN: nobody waiting
        set_flags(fd, 0);
        if (!same_user(fd)) {
            close(fd);
            continue;
        }
        set_timeouts(fd);
        return fd;
    }
}

int gtty_ctl_connect(const char *path) {
    struct sockaddr_un a;
    if (fill_addr(&a, path) != 0) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    set_flags(fd, 0);
    set_timeouts(fd);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0 || !same_user(fd)) {
        close(fd);
        return -1;
    }
    return fd;
}

static int write_all(int fd, const char *p, size_t len) {
    while (len > 0) {
#ifdef MSG_NOSIGNAL
        ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
#else
        ssize_t n = send(fd, p, len, 0);
#endif
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

int gtty_ctl_send(int fd, const char *buf, unsigned long len, const int *fds, int nfds) {
    if (nfds < 0 || nfds > MAX_FDS || len > UINT32_MAX) return -1;
    uint32_t n = (uint32_t)len;
    // The length goes in the first sendmsg, with the descriptors.
    struct iovec iov = {.iov_base = &n, .iov_len = sizeof n};
    union {
        struct cmsghdr h;
        char space[CMSG_SPACE(sizeof(int) * MAX_FDS)];
    } ctl;
    memset(&ctl, 0, sizeof ctl);
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_iov = &iov;
    m.msg_iovlen = 1;
    if (nfds > 0) {
        m.msg_control = ctl.space;
        m.msg_controllen = CMSG_SPACE(sizeof(int) * nfds);
        struct cmsghdr *c = CMSG_FIRSTHDR(&m);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int) * nfds);
        memcpy(CMSG_DATA(c), fds, sizeof(int) * nfds);
    }
    ssize_t r;
#ifdef MSG_NOSIGNAL
    while ((r = sendmsg(fd, &m, MSG_NOSIGNAL)) < 0 && errno == EINTR) {
    }
#else
    while ((r = sendmsg(fd, &m, 0)) < 0 && errno == EINTR) {
    }
#endif
    if (r != (ssize_t)sizeof n) return -1;
    return write_all(fd, buf, len);
}

long gtty_ctl_recv(int fd, char *buf, unsigned long cap, int *fds, int maxfds, int *nfds) {
    *nfds = 0;
    uint32_t n = 0;
    struct iovec iov = {.iov_base = &n, .iov_len = sizeof n};
    union {
        struct cmsghdr h;
        char space[CMSG_SPACE(sizeof(int) * MAX_FDS)];
    } ctl;
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_iov = &iov;
    m.msg_iovlen = 1;
    m.msg_control = ctl.space;
    m.msg_controllen = sizeof ctl.space;
    ssize_t r;
    while ((r = recvmsg(fd, &m, MSG_WAITALL)) < 0 && errno == EINTR) {
    }
    // The descriptors (also on a bad message: closed then).
    int got = 0;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&m); c; c = CMSG_NXTHDR(&m, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS) continue;
        int k = (int)((c->cmsg_len - CMSG_LEN(0)) / sizeof(int));
        int tmp[MAX_FDS * 2];
        if (k > MAX_FDS * 2) k = MAX_FDS * 2;
        memcpy(tmp, CMSG_DATA(c), sizeof(int) * (size_t)k);
        for (int i = 0; i < k; i++) {
            if (got < maxfds && got < MAX_FDS) {
                set_cloexec(tmp[i]);
                fds[got++] = tmp[i];
            } else close(tmp[i]);
        }
    }
    *nfds = got;
    if (r != (ssize_t)sizeof n || n > cap || (m.msg_flags & MSG_CTRUNC)) goto bad;
    size_t have = 0;
    while (have < n) {
        ssize_t k = recv(fd, buf + have, n - have, 0);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) goto bad;
        have += (size_t)k;
    }
    return (long)n;
bad:
    for (int i = 0; i < got; i++) close(fds[i]);
    *nfds = 0;
    return -1;
}
