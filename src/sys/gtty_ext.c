// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

#ifdef __linux__
#define _GNU_SOURCE // struct ucred
#endif
#include "gtty_ext.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif
#ifdef __APPLE__
#include <sys/ucred.h>
#endif

static void nonblock_cloexec(int fd) {
    int fl = fcntl(fd, F_GETFL);
    if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    int fdfl = fcntl(fd, F_GETFD);
    if (fdfl >= 0) fcntl(fd, F_SETFD, fdfl | FD_CLOEXEC);
}

int gtty_ext_spawn(const char *path, const char *const argv[], const char *const env[],
                   const char *cwd, int *sock, int *out, int *err) {
    int sv[2], o[2], e[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) return -errno;
    if (pipe(o) != 0) {
        int x = errno;
        close(sv[0]); close(sv[1]);
        return -x;
    }
    if (pipe(e) != 0) {
        int x = errno;
        close(sv[0]); close(sv[1]); close(o[0]); close(o[1]);
        return -x;
    }
#ifdef __linux__
    pid_t parent = getpid();
#endif
    pid_t pid = fork();
    if (pid < 0) {
        int x = errno;
        close(sv[0]); close(sv[1]); close(o[0]); close(o[1]); close(e[0]); close(e[1]);
        return -x;
    }
    if (pid == 0) {
#ifdef __linux__
        prctl(PR_SET_PDEATHSIG, SIGTERM);
        if (getppid() != parent) _exit(0);
#endif
        setpgid(0, 0);
        int devnull = open("/dev/null", O_RDONLY);
        // Above 3 first, so the dup2s below can't clobber one another.
        int s = fcntl(sv[1], F_DUPFD, 10);
        int so = fcntl(o[1], F_DUPFD, 10);
        int se = fcntl(e[1], F_DUPFD, 10);
        if (devnull >= 0) dup2(devnull, 0);
        dup2(so, 1);
        dup2(se, 2);
        dup2(s, 3);
        for (int fd = 4; fd < 1024; fd++) close(fd);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);
        if (cwd && cwd[0] && chdir(cwd) != 0) _exit(126);
        execve(path, (char *const *)argv, (char *const *)env);
        _exit(127);
    }
    close(sv[1]); close(o[1]); close(e[1]);
    nonblock_cloexec(sv[0]);
    nonblock_cloexec(o[0]);
    nonblock_cloexec(e[0]);
    *sock = sv[0];
    *out = o[0];
    *err = e[0];
    return pid;
}

void gtty_ext_shutdown_write(int sock) {
    if (sock >= 0) shutdown(sock, SHUT_WR);
}

void gtty_ext_signal(int pid, int sig) {
    if (pid <= 0) return;
    kill(-pid, sig);
    kill(pid, sig);
}

int gtty_ext_reap(int pid, int *status) {
    int st = 0;
    pid_t r = waitpid(pid, &st, WNOHANG);
    if (r == 0) return 0;
    if (r < 0) return -1;
    *status = WIFEXITED(st) ? WEXITSTATUS(st) : WIFSIGNALED(st) ? 128 + WTERMSIG(st) : 0;
    return 1;
}

int gtty_ext_listen(const char *path) {
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof a.sun_path) return -ENAMETOOLONG;
    strcpy(a.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -errno;
    unlink(path);
    // Only this user, from the first moment.
    mode_t old = umask(0177);
    int r = bind(fd, (struct sockaddr *)&a, sizeof a);
    umask(old);
    if (r != 0 || listen(fd, 8) != 0) {
        int x = errno;
        close(fd);
        return -x;
    }
    chmod(path, 0600);
    nonblock_cloexec(fd);
    return fd;
}

int gtty_ext_accept(int lfd, int *pid) {
    *pid = 0;
    for (;;) {
        int fd = accept(lfd, NULL, NULL);
        if (fd < 0) return -1;
        uid_t uid = (uid_t)-1;
#ifdef __APPLE__
        gid_t gid;
        if (getpeereid(fd, &uid, &gid) != 0) uid = (uid_t)-1;
        pid_t p = 0;
        socklen_t len = sizeof p;
        if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &p, &len) == 0) *pid = p;
#elif defined(__linux__)
        struct ucred cr;
        socklen_t len = sizeof cr;
        if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cr, &len) == 0) {
            uid = cr.uid;
            *pid = cr.pid;
        }
#endif
        if (uid != getuid()) {
            close(fd);
            continue;
        }
        nonblock_cloexec(fd);
        return fd;
    }
}
