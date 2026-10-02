#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <time.h>
#include <signal.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <spawn.h>
#include <poll.h>
static int ok = 0, bad = 0;
#define T(name, cond) do { if (cond) { ok++; printf("  ok   %s\n", name); } else { bad++; printf("  FAIL %s (errno %d)\n", name, errno); } } while (0)
static volatile int got;
static void h(int s) { got = s; }
extern char **environ;
int main(int argc, char **argv)
{
    struct timespec ts; struct stat st; char buf[256]; int fd, p[2], status, n;
    printf("LexOS Linux syscall test (musl, 64-bit time)\n");
    T("clock_gettime", clock_gettime(CLOCK_REALTIME, &ts) == 0 && ts.tv_sec > 1700000000);
    T("monotonic", clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
    { struct timeval tv; T("gettimeofday", gettimeofday(&tv, 0) == 0 && tv.tv_sec > 1700000000); }
    T("getcwd", getcwd(buf, sizeof buf) != 0);
    T("mkdir", mkdir("/TMP/LXT", 0755) == 0 || errno == EEXIST);
    T("chdir", chdir("/TMP/LXT") == 0);
    fd = open("data.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    T("open create", fd >= 0);
    T("write", write(fd, "hello world\n", 12) == 12);
    T("close", close(fd) == 0);
    T("stat size", stat("data.txt", &st) == 0 && st.st_size == 12 && S_ISREG(st.st_mode));
    T("stat dir", stat("/TMP", &st) == 0 && S_ISDIR(st.st_mode));
    T("stat missing", stat("nothere", &st) == -1 && errno == ENOENT);
    fd = open("data.txt", O_RDWR);
    T("lseek end", lseek(fd, 0, SEEK_END) == 12);
    T("append via rdwr", write(fd, "more\n", 5) == 5);
    T("lseek set", lseek(fd, 6, SEEK_SET) == 6);
    n = read(fd, buf, 5); buf[n > 0 ? n : 0] = 0;
    T("read back", n == 5 && !strcmp(buf, "world"));
    T("ftruncate", ftruncate(fd, 5) == 0 && fstat(fd, &st) == 0 && st.st_size == 5);
    close(fd);
    { DIR *d = opendir("/DEMOS"); struct dirent *e; int c = 0, dots = 0;
      if (d) { while ((e = readdir(d))) { c++; if (!strcmp(e->d_name, "..")) dots = 1; } closedir(d); }
      T("readdir /DEMOS", c > 5 && dots); }
    T("rename", rename("data.txt", "moved.txt") == 0 && access("moved.txt", F_OK) == 0 && access("data.txt", F_OK) == -1);
    T("unlink", unlink("moved.txt") == 0 && access("moved.txt", F_OK) == -1);
    T("rmdir", chdir("/") == 0 && rmdir("/TMP/LXT") == 0);
    { char *m = malloc(20 * 1024 * 1024); T("malloc 20MB", m != 0); if (m) { memset(m, 7, 20 * 1024 * 1024); T("touch 20MB", m[20 * 1024 * 1024 - 1] == 7); free(m); } }
    { void *m = mmap(0, 1 << 20, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0); T("mmap", m != MAP_FAILED && ((unsigned long)m & 4095) == 0 && munmap(m, 1 << 20) == 0); }
    T("pipe", pipe(p) == 0);
    { pid_t pid = fork();
      if (pid == 0) { close(p[0]); write(p[1], "from child", 10); _exit(7); }
      close(p[1]); n = read(p[0], buf, sizeof buf); buf[n > 0 ? n : 0] = 0; close(p[0]);
      T("fork+pipe", n == 10 && !strcmp(buf, "from child"));
      T("waitpid", waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 7); }
    { pid_t pid; char *av[] = { "busybox", "true", 0 };
      int r = posix_spawn(&pid, "/LINUX/BUSYBOX", 0, 0, av, environ);
      T("posix_spawn", r == 0 && waitpid(pid, &status, 0) == pid && WEXITSTATUS(status) == 0); }
    signal(SIGUSR1, h); raise(SIGUSR1);
    T("raise+handler", got == SIGUSR1);
    { struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = h; sigaction(SIGALRM, &sa, 0); got = 0; kill(getpid(), SIGALRM); T("kill self", got == SIGALRM); }
    { struct timespec a, b, d = { 0, 200000000 }; clock_gettime(CLOCK_MONOTONIC, &a); nanosleep(&d, 0); clock_gettime(CLOCK_MONOTONIC, &b);
      long ms = (b.tv_sec - a.tv_sec) * 1000 + (b.tv_nsec - a.tv_nsec) / 1000000; T("nanosleep 200ms", ms >= 180 && ms < 600); }
    { struct pollfd pf = { 0, POLLIN, 0 }; T("poll stdin timeout", poll(&pf, 1, 50) == 0); }
    T("isatty", isatty(1));
    T("environ PATH", getenv("PATH") != 0);
    { FILE *f = fopen("/etc/passwd", "r"); T("/etc/passwd", f && fgets(buf, sizeof buf, f) && !strncmp(buf, "root:", 5)); if (f) fclose(f); }
    T("/dev/null", (fd = open("/dev/null", O_WRONLY)) >= 0 && write(fd, "x", 1) == 1 && close(fd) == 0);
    printf("%d passed, %d failed\n", ok, bad);
    return bad;
}
