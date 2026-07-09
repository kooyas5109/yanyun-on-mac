/*
 * wineserverfix - wineserver 进程运行时补丁集合
 *
 * 加载方式：通过 DYLD_INSERT_LIBRARIES 注入 wineserver（macOS dyld 预加载机制，
 *           不是 wine 内部按文件名 dlopen 的 compat-db 通道）。因此本库只在被显式
 *           注入的 wineserver 进程中生效。
 *
 * 已包含的补丁：
 *   1. socket() 拦截：为 loopback TCP（AF_INET/AF_INET6 + SOCK_STREAM）把发送缓冲
 *      放大到 2MB，规避 IPC 首次自发自收 1MB 在 macOS 默认 128KB
 *      loopback 发送缓冲下的单线程死锁（典型表现：客户端点下载按钮无反应、界面卡死）。
 *
 * 以后新增 wineserver 侧 hack 时，在本文件内追加 interpose / 函数即可，
 * 不影响客户端进程（客户端走的是另一套加载机制）。
 */

#include <sys/socket.h>
#include <netinet/in.h>

#ifdef DEBUG
#include <stdio.h>
#include <unistd.h>
#endif

/* loopback TCP 发送缓冲目标值：2MB，足以一次吞下 IPC 的 1MB 自发自收包 */
#define WSFIX_TCP_SNDBUF (2 * 1024 * 1024)

/*
 * socket() interpose：wineserver 创建底层 unix socket 后，
 * 对 AF_INET/AF_INET6 的 SOCK_STREAM 设置大发送缓冲。
 * __DATA,__interpose 段仅对经 DYLD_INSERT_LIBRARIES 加载的镜像生效，
 * 天然不会波及以 dlopen 方式加载的其它兼容组件。
 */
static int wsfix_socket(int domain, int type, int protocol) {
    int fd = socket(domain, type, protocol);
    if (fd >= 0 && (domain == AF_INET || domain == AF_INET6) &&
        (type & 0xff) == SOCK_STREAM) {
        int sndbuf = WSFIX_TCP_SNDBUF;
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
#ifdef DEBUG
        int got = 0; socklen_t gl = sizeof(got);
        getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &got, &gl);
        fprintf(stderr, "[wsfix] pid=%d socket fd=%d SO_SNDBUF=%d\n",
                getpid(), fd, got);
#endif
    }
    return fd;
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *original;
} _wsfix_interpose_socket __attribute__((section("__DATA,__interpose"))) = {
    (const void *)wsfix_socket,
    (const void *)socket
};
