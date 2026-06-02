/*
 * winecompat - Wine 进程兼容扩展
 *
 * 功能：
 *   - 根据进程 exe 路径选择图形渲染后端（dxmt / d3dmetal / wined3d）
 *   - 通过 Wine syscall 表 hook 在子进程创建时注入命令行参数和环境变量
 *   - yysls.exe 进程内监控窗口 Level，使跨进程弹窗和进程内弹窗可见
 *
 * 初始化（每个 Wine 进程 dlopen 时通过 constructor 自动执行）：
 *   1. 安装 NtCreateUserProcess hook
 *   2. 根据 exe 路径匹配图形后端；无匹配时检测 Rosetta 自动选择
 *   3. 设置 CX_ACTIVE_GRAPHICS_BACKEND 环境变量，prepend 对应的 DLL 搜索路径
 *   4. 按进程名设置额外环境变量（如 QMLSCENE_DEVICE）
 *   5. yysls.exe 专属：启动游戏窗口 Level 监控后台线程
 *
 * 实现依据：
 *   - Wine ntdll 导出符号（prepend_dll_path、NtCurrentTeb 等）均为 Wine LGPL 公开 API
 *   - Windows NT API 结构体（UNICODE_STRING、OBJECT_ATTRIBUTES、RTL_USER_PROCESS_PARAMETERS）
 *     定义参考 Windows SDK 公开文档及 Wine ntdll 源码（dlls/ntdll/）
   *   - CGSSetWindowLevel：macOS 窗口层级控制接口，macOS 14 可用
 */

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/sysctl.h>
#include <sys/mman.h>
#include <CoreGraphics/CoreGraphics.h>

typedef unsigned short WCHAR;
typedef unsigned int ULONG;
typedef long NTSTATUS;
typedef void *PVOID;
typedef void *HANDLE;
typedef ULONG ACCESS_MASK;

/* ========== 函数指针 ========== */

/*
 * prepend_dll_path: Wine ntdll 导出函数，将路径插入 DLL 搜索列表头部。
 * 源码位置: dlls/ntdll/unix/loader.c 中 "prepend_dll_path" 定义
 * 导出确认: nm ntdll.so | grep prepend_dll_path → T _prepend_dll_path
 */
static void (*prepend_dll_path_fn)(const char *) = NULL;
/* ========== 工具函数 ========== */

/* 宽字符后缀匹配（不区分大小写）*/
static int wstr_ends_with_icase(const WCHAR *str, int str_len, const char *suffix) {
    int suffix_len = strlen(suffix);
    if (str_len < suffix_len) return 0;
    const WCHAR *p = str + str_len - suffix_len;
    for (int i = 0; i < suffix_len; i++) {
        WCHAR c = p[i];
        if (c >= 'A' && c <= 'Z') c += 32;
        char s = suffix[i];
        if (s >= 'A' && s <= 'Z') s += 32;
        if (c != (WCHAR)s) return 0;
    }
    return 1;
}

/* 检测当前进程是否运行在 Rosetta 2 转译层下 */
static int is_rosetta(void) {
    int translated = 0;
    size_t size = sizeof(translated);
    if (sysctlbyname("sysctl.proc_translated", &translated, &size, NULL, 0) == 0) {
        return translated != 0;
    }
    return 0;
}

/* 获取当前进程 exe 路径
 *
 * 通过 TEB → PEB → ProcessParameters → ImagePathName 链式读取。
 * 结构体定义来源：
 *   TEB:  dlls/ntdll/unix/unix_private.h (struct ntdll_thread_data)
 *         x86_64 下 TEB+0x60 = PEB 指针（Windows SDK 公开定义）
 *   PEB:  include/winternl.h (PEB structure)
 *         PEB+0x20 = ProcessParameters 指针
 *   RTL_USER_PROCESS_PARAMETERS: include/winternl.h
 *         +0x60 = ImagePathName.Length (UNICODE_STRING)
 *         +0x68 = ImagePathName.Buffer
 *         +0x70 = CommandLine.Length
 *         +0x72 = CommandLine.MaximumLength
 *         +0x78 = CommandLine.Buffer
 */
static const WCHAR *get_current_exe_path(int *out_wchar_len) {
    PVOID (*NtCurrentTeb_fn)(void) = dlsym(RTLD_DEFAULT, "NtCurrentTeb");
    if (!NtCurrentTeb_fn) return NULL;

    PVOID teb = NtCurrentTeb_fn();
    if (!teb) return NULL;

    /* TEB->ProcessEnvironmentBlock (x86_64 偏移，见 Wine dlls/ntdll/thread.c) */
    PVOID peb = *(PVOID *)((char *)teb + 0x60);
    if (!peb) return NULL;

    /* PEB->ProcessParameters (见 Wine include/winternl.h) */
    PVOID params = *(PVOID *)((char *)peb + 0x20);
    if (!params) return NULL;

    /* RTL_USER_PROCESS_PARAMETERS.ImagePathName (UNICODE_STRING at offset 0x60) */
    unsigned short byte_len = *(unsigned short *)((char *)params + 0x60);
    WCHAR *buffer = *(WCHAR **)((char *)params + 0x68);

    if (!buffer || byte_len == 0) return NULL;
    if (out_wchar_len) *out_wchar_len = byte_len / 2;
    return buffer;
}

/* load_backend_dll_dir: 将图形后端的 DLL 目录加入 Wine 的 DLL 搜索路径 */
static void load_backend_dll_dir(const char *relative_path) {
    if (!prepend_dll_path_fn) {
#ifdef DEBUG
        fprintf(stderr, "[compat] dll path fn missing\n");
#endif
        return;
    }
    const char *cx_root = getenv("CX_ROOT");
    if (!cx_root || !cx_root[0]) {
#ifdef DEBUG
        fprintf(stderr, "[compat] CX_ROOT not set\n");
#endif
        return;
    }

    char *full_path = NULL;
    if (asprintf(&full_path, "%s/%s", cx_root, relative_path) == -1) {
#ifdef DEBUG
        fprintf(stderr, "[compat] alloc failed\n");
#endif
        return;
    }
#ifdef DEBUG
    fprintf(stderr, "[compat] prepend path: %s\n", full_path);
#endif
    prepend_dll_path_fn(full_path);
    /* 注意：不 free full_path，因为 dll_paths 数组会持有这个指针 */
}

/* ========== NtCreateUserProcess Hook ========== */

typedef struct { ULONG TotalLength; } PS_ATTRIBUTE_LIST;
typedef NTSTATUS (*NtCreateUserProcess_t)(
    HANDLE *, HANDLE *, ACCESS_MASK, ACCESS_MASK,
    PVOID, PVOID, ULONG, ULONG, PVOID, PVOID, PS_ATTRIBUTE_LIST *);

static NtCreateUserProcess_t original_NtCreateUserProcess = NULL;

/*
 * 从 PS_ATTRIBUTE_LIST 提取子进程 ImagePathName
 *
 * PS_ATTRIBUTE_LIST 结构参考 Wine dlls/ntdll/process.c 中 NtCreateUserProcess 的实现。
 * 每个 attribute 条目 32 字节（x86_64 对齐）：
 *   +0:  Attribute ID (ULONG_PTR，低 20 位为类型)
 *   +8:  Size (ULONG_PTR)
 *   +16: Value (指针)
 *   +24: ReturnLength
 *
 * 0x20005 = PS_ATTRIBUTE_IMAGE_NAME，定义见 Wine include/ntdef.h 和 Windows SDK。
 */
static const WCHAR *get_image_path_from_attrs(PS_ATTRIBUTE_LIST *attrs, int *out_len) {
    if (!attrs) return NULL;
    char *ptr = (char *)attrs;
    ULONG total_len = *(ULONG *)ptr;
    if (total_len < 8) return NULL;
    ptr += 8;
    char *end = (char *)attrs + total_len;
    while (ptr + 32 <= end) {
        unsigned long long attr = *(unsigned long long *)ptr;
        unsigned long long size = *(unsigned long long *)(ptr + 8);
        WCHAR *value = *(WCHAR **)(ptr + 16);
        if ((attr & 0xFFFFF) == 0x20005) {  /* PS_ATTRIBUTE_IMAGE_NAME */
            if (out_len) *out_len = (int)(size / 2);
            return value;
        }
        ptr += 32;
    }
    return NULL;
}

/*
 * NtCreateUserProcess Hook
 *
 * 拦截子进程创建，按进程名注入：
 * 1. 命令行参数追加：
 *    - webview_support_browser.exe → 追加 "--in-process-gpu --disable-gpu"
 *    - 直接修改 ProcessParameters->CommandLine，调用后恢复
 * 2. 环境变量注入：
 *    - FeverGamesInstaller.exe → QMLSCENE_DEVICE=softwarecontext
 *
 * ProcessParameters 结构偏移参考 Wine ntdll/process.c 中的
 * RTL_USER_PROCESS_PARAMETERS 定义。
 */
static NTSTATUS hook_NtCreateUserProcess(
    HANDLE *ProcessHandle, HANDLE *ThreadHandle,
    ACCESS_MASK ProcessAccess, ACCESS_MASK ThreadAccess,
    PVOID ProcessObjectAttributes, PVOID ThreadObjectAttributes,
    ULONG ProcessFlags, ULONG ThreadFlags,
    PVOID ProcessParameters, PVOID CreateInfo,
    PS_ATTRIBUTE_LIST *AttributeList)
{
    /* 提取子进程 ImagePathName */
    int path_len = 0;
    const WCHAR *image_path = get_image_path_from_attrs(AttributeList, &path_len);

    /* === 命令行参数追加 === */
    /* 要追加的字符串: " --in-process-gpu --disable-gpu" (含前导空格) */
    static const WCHAR append_str[] = {
        ' ','-','-','i','n','-','p','r','o','c','e','s','s','-','g','p','u',
        ' ','-','-','d','i','s','a','b','l','e','-','g','p','u', 0
    };
    static const int append_wchars = 31; /* " --in-process-gpu --disable-gpu" = 31 chars 不含 null */

    WCHAR *saved_cmd_buf = NULL;
    unsigned short saved_cmd_len = 0;
    unsigned short saved_cmd_maxlen = 0;
    WCHAR *new_cmd = NULL;
    int cmd_modified = 0;

    if (image_path && path_len > 0 && ProcessParameters) {
        if (wstr_ends_with_icase(image_path, path_len, "\\webview_support_browser.exe")) {
            /* RTL_USER_PROCESS_PARAMETERS.CommandLine (UNICODE_STRING at offset 0x70) */
            char *pp = (char *)ProcessParameters;
            WCHAR *orig_cmd = *(WCHAR **)(pp + 0x78);            /* CommandLine.Buffer */
            unsigned short orig_len = *(unsigned short *)(pp + 0x70); /* CommandLine.Length (bytes) */

            if (orig_cmd && orig_len > 0) {
                /* 计算新命令行大小 */
                int new_byte_len = orig_len + append_wchars * 2;
                new_cmd = (WCHAR *)malloc(new_byte_len + 2); /* +2 for null terminator */

                if (new_cmd) {
                    /* 拷贝原始命令行 */
                    memcpy(new_cmd, orig_cmd, orig_len);
                    /* 追加字符串（含前导空格） */
                    memcpy((char *)new_cmd + orig_len, append_str, (append_wchars + 1) * 2);

                    /* 保存原始值 */
                    saved_cmd_buf = orig_cmd;
                    saved_cmd_len = orig_len;
                    saved_cmd_maxlen = *(unsigned short *)(pp + 0x72); /* CommandLine.MaximumLength */

                    /* 替换 ProcessParameters->CommandLine */
                    *(WCHAR **)(pp + 0x78) = new_cmd;
                    *(unsigned short *)(pp + 0x70) = (unsigned short)new_byte_len;
                    *(unsigned short *)(pp + 0x72) = (unsigned short)new_byte_len;

                    cmd_modified = 1;
#ifdef DEBUG
                    fprintf(stderr, "[compat] appended cmdline for webview\n");
#endif
                }
            }
        }

        /* === 环境变量设置 === */
        if (wstr_ends_with_icase(image_path, path_len, "\\fevergamesinstaller.exe") ||
            wstr_ends_with_icase(image_path, path_len, "\\yysls\\win32\\deploy\\launcher.exe") ||
            wstr_ends_with_icase(image_path, path_len, "\\wwm\\win32\\deploy\\launcher.exe")) {
            setenv("QMLSCENE_DEVICE", "softwarecontext", 0);
        }
    }

    /* 调用原始 NtCreateUserProcess */
    NTSTATUS status = original_NtCreateUserProcess(
        ProcessHandle, ThreadHandle,
        ProcessAccess, ThreadAccess,
        ProcessObjectAttributes, ThreadObjectAttributes,
        ProcessFlags, ThreadFlags,
        ProcessParameters, CreateInfo,
        AttributeList);

    /* 恢复 ProcessParameters->CommandLine */
    if (cmd_modified && ProcessParameters) {
        char *pp = (char *)ProcessParameters;
        *(WCHAR **)(pp + 0x78) = saved_cmd_buf;
        *(unsigned short *)(pp + 0x70) = saved_cmd_len;
        *(unsigned short *)(pp + 0x72) = saved_cmd_maxlen;
        free(new_cmd);
    }

    return status;
}

    /*
     * 安装 syscall hook (NtCreateUserProcess)
     *
     * Wine 使用 KeServiceDescriptorTable 管理 NT syscall 分发表。
     * 源码位置: dlls/ntdll/unix/loader.c:159 — 全局定义
     *           include/winternl.h — SYSTEM_SERVICE_TABLE 结构体：
     *             { ULONG_PTR *ServiceTable,    [0] 函数指针数组
     *               ULONG_PTR *CounterTable,    [1] 计数器（调试用）
     *               ULONG_PTR  ServiceLimit,    [2] 表中 syscall 数量
     *               BYTE      *ArgumentTable }  [3] 参数字节数
     * 导出确认: nm ntdll.so | grep KeService → T _KeServiceDescriptorTable
     *
     * Hook 方式：遍历 ServiceTable 找到 NtCreateUserProcess 入口地址并替换。
     * NtCreateUserProcess 也是 ntdll 导出符号，可通过 dlsym 获取其地址。
     *
     * 注：syscall hook 是 Wine 生态中的常规互操作性技术。本项目仅 hook
     * NtCreateUserProcess 一个函数，目的是在子进程创建时注入环境变量和
     * 命令行参数（实现 per-process 渲染后端选择）。不修改、不截断其他
     * syscall。所有符号（KeServiceDescriptorTable、NtCreateUserProcess）
     * 均来自 Wine ntdll 公开导出表和 Windows SDK/DDK 文档。
     */
static void install_syscall_hooks(void) {
    void **syscall_table = (void **)dlsym(RTLD_DEFAULT, "KeServiceDescriptorTable");
    if (!syscall_table) return;

    void *target_create_process = dlsym(RTLD_DEFAULT, "NtCreateUserProcess");

    /* SYSTEM_SERVICE_TABLE.ServiceTable (第 0 个字段) */
    void **funcs = (void **)syscall_table[0];
    /* SYSTEM_SERVICE_TABLE.ServiceLimit (第 2 个字段，跳过 CounterTable 指针) */
    unsigned long long count = (unsigned long long)syscall_table[2];
    if (!funcs || count == 0) return;

    /* 先做 mprotect 让整个表可写 */
    long page_size = getpagesize();
    void *page_start = (void *)((unsigned long long)funcs & ~(page_size - 1));
    mprotect(page_start, page_size * 4, PROT_READ | PROT_WRITE | PROT_EXEC);

    for (unsigned long long i = 0; i < count; i++) {
        if (target_create_process && funcs[i] == target_create_process) {
            original_NtCreateUserProcess = (NtCreateUserProcess_t)funcs[i];
            funcs[i] = (void *)hook_NtCreateUserProcess;
            break;
        }
    }
}

/* ========== yysls.exe 弹窗 Level 避让 ========== */

/*
 * yysls.exe 全屏运行时 winemac.drv 将其窗口提升到某个高 Level（独占全屏级别）。
 *
 * Part A - 跨进程弹窗（FeverGamesInstaller）：
 *   FeverGamesInstaller 弹窗处于较低 Level，游戏 Level 更高导致弹窗被压住。
 *   方案：检测到 FeverGamesInstaller Level>0 弹窗 → 把游戏窗口降到 popup_level-1，
 *         弹窗消失后恢复原始 Level。全部动态计算，不依赖硬编码 Level 常量。
 *
 * Part B - 进程内弹窗（MPAY_LOGIN_NOTICE 等）：
 *   游戏内部弹窗与游戏主窗口同在同一 Level，Z-order 低导致被压住。
 *   方案：把小弹窗提升到 game_level+1（动态计算）。
 *
 * 使用 CGSSetWindowLevel 控制窗口 Level（macOS 14 可用）。
 * 为什么不在 FeverGamesInstaller 里激活自己：
 *   macOS 14 起，跨进程 -[NSApp activateIgnoringOtherApps:YES] 被系统 block，无效。
 */

/* CGSSetWindowLevel 函数声明 */
typedef int CGSConnectionID;
extern CGSConnectionID CGSMainConnectionID(void);
extern CGError CGSSetWindowLevel(CGSConnectionID cid, int wid, int level);

/*
 * 把当前进程所有处于 from_level 的窗口批量设置到 to_level
 * 返回成功修改的窗口数量
 */
static int set_my_windows_level(int from_level, int to_level) {
    CFArrayRef win_list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!win_list) return 0;

    CFIndex total = CFArrayGetCount(win_list);
    pid_t my_pid = getpid();
    CGSConnectionID cid = CGSMainConnectionID();
    int changed = 0;

    for (CFIndex i = 0; i < total; i++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(win_list, i);
        if (!info) continue;

        CFNumberRef pid_ref = (CFNumberRef)CFDictionaryGetValue(info, CFSTR("kCGWindowOwnerPID"));
        if (!pid_ref) continue;
        int win_pid = 0;
        CFNumberGetValue(pid_ref, kCFNumberIntType, &win_pid);
        if (win_pid != (int)my_pid) continue;

        CFNumberRef level_ref = (CFNumberRef)CFDictionaryGetValue(info, CFSTR("kCGWindowLayer"));
        if (!level_ref) continue;
        int lv = 0;
        CFNumberGetValue(level_ref, kCFNumberIntType, &lv);
        if (lv != from_level) continue;

        CFNumberRef wid_ref = (CFNumberRef)CFDictionaryGetValue(info, CFSTR("kCGWindowNumber"));
        if (!wid_ref) continue;
        int wid = 0;
        CFNumberGetValue(wid_ref, kCFNumberIntType, &wid);
        if (wid <= 0) continue;

        /* ── CGSSetWindowLevel ──
         * macOS CoreGraphics 私有接口（CGSInternal），非 Apple 公开 API。
         * 作用：直接操作 CoreGraphics 窗口层级，跨进程调整 Wine 生成的窗口 Level。
         * 为什么不用 NSWindow.setLevel：Wine 窗口不是 NSWindow，不受 AppKit 管理。
         * 风险：Apple 不保证此 API 兼容性，未来 macOS 更新可能失效。
         * 替代方案：暂无公开 API 可替代。失效时游戏弹窗层级问题需重新设计。
         */
        CGSSetWindowLevel(cid, wid, to_level);
        changed++;
    }

    CFRelease(win_list);

#ifdef DEBUG
    fprintf(stderr, "[compat] level %d→%d, changed %d windows\n", from_level, to_level, changed);
#endif
    return changed;
}

/* 后台线程：监控弹窗并动态调整游戏窗口 Level */
static void *game_level_monitor_thread(void *arg) {
    (void)arg;

    /* 稍等 Wine 初始化 + winemac.drv 设置好窗口 Level 再开始轮询 */
    sleep(5);

    /*
     * 状态机（完全动态，不依赖硬编码 Level 常量）：
     *   is_lowered=0        正常态
     *   is_lowered=1        已降低：original_game_level 记录降前实测值，
     *                                lowered_to_level 记录降到的值（popup_level-1）
     */
    int is_lowered = 0;
    int original_game_level = -1;
    int lowered_to_level    = -1;

    while (1) {
        usleep(1500000);  /* 1.5 秒轮询一次 */

        /*
         * 一次 CGWindowListCopyWindowInfo 同时处理两件事：
         *   Part A：跨进程检测 FeverGamesInstaller Level>0 弹窗，动态降低/恢复游戏 Level
         *   Part B：进程内检测小弹窗，提升到 game_level+1
         */
        CFArrayRef win_list = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID);
        if (!win_list) continue;

        CFIndex count = CFArrayGetCount(win_list);
        pid_t my_pid = getpid();
        CGSConnectionID cid = CGSMainConnectionID();

        /* ── 第一遍：收集关键信息 ── */
        /* FeverGamesInstaller 所有 Level>0 可见窗口中的最大 Level（-1 表示无弹窗） */
        int installer_popup_level = -1;
        /* 本进程全屏主窗口（宽>=1500）的实际 Level（-1 表示未进入全屏） */
        int game_level = -1;

        for (CFIndex i = 0; i < count; i++) {
            CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(win_list, i);
            if (!info) continue;

            CFNumberRef pid_ref = (CFNumberRef)CFDictionaryGetValue(info, CFSTR("kCGWindowOwnerPID"));
            if (!pid_ref) continue;
            int win_pid = 0;
            CFNumberGetValue(pid_ref, kCFNumberIntType, &win_pid);

            CFNumberRef level_ref = (CFNumberRef)CFDictionaryGetValue(info, CFSTR("kCGWindowLayer"));
            if (!level_ref) continue;
            int lv = 0;
            CFNumberGetValue(level_ref, kCFNumberIntType, &lv);

            if (win_pid != (int)my_pid) {
                /*
                 * 外进程：检测 FeverGamesInstaller Level>0 的可见弹窗
                 * 通过 kCGWindowOwnerName 匹配进程名（Wine 进程名即 exe 名）
                 * Level=0 是 FeverGamesInstaller 主窗口，不算弹窗
                 */
                if (lv <= 0) continue;
                CFStringRef owner = (CFStringRef)CFDictionaryGetValue(
                    info, CFSTR("kCGWindowOwnerName"));
                if (!owner) continue;
                CFRange r = CFStringFind(owner, CFSTR("FeverGamesInstaller"),
                                         kCFCompareCaseInsensitive);
                if (r.location == kCFNotFound) continue;
                /* 记录所有匹配窗口中的最大 Level */
                if (lv > installer_popup_level) installer_popup_level = lv;
            } else {
                /* 本进程：找全屏主窗口（宽>=1500），取实际 Level */
                CFDictionaryRef bounds = (CFDictionaryRef)CFDictionaryGetValue(
                    info, CFSTR("kCGWindowBounds"));
                if (!bounds) continue;
                CFNumberRef w_ref = (CFNumberRef)CFDictionaryGetValue(bounds, CFSTR("Width"));
                if (!w_ref) continue;
                double w = 0;
                CFNumberGetValue(w_ref, kCFNumberDoubleType, &w);
                if (w >= 1500.0 && lv > game_level) game_level = lv;
            }
        }

        /* ── Part A：动态降低/恢复游戏窗口 Level ── */
        /*
         * popup_exists：FeverGamesInstaller 有 Level>0 弹窗（用于驱动状态机）
         * 与 game_level 的大小比较只在"决定是否需要降级"时使用，
         * 不作为 popup_exists 的判断条件——否则降级后 game_level 变小，
         * 条件反转，导致状态机误判弹窗消失，产生反复降级/恢复的闪烁。
         */
        int popup_exists = (installer_popup_level > 0);

        if (popup_exists && !is_lowered) {
            /* 弹窗存在且尚未降级：仅在弹窗 Level 低于游戏时才需要降级 */
            if (game_level > 0 && installer_popup_level < game_level) {
                int target = installer_popup_level - 1;
                int changed = set_my_windows_level(game_level, target);
                if (changed > 0) {
                    original_game_level = game_level;
                    lowered_to_level    = target;
                    is_lowered          = 1;
                    game_level          = target;  /* 同步本轮 Part B 使用的值 */
#ifdef DEBUG
                    fprintf(stderr, "[compat] installer popup lv=%d, lowered game lv %d→%d\n",
                            installer_popup_level, original_game_level, target);
#endif
                }
            }
            /* 若弹窗已在游戏 Level 之上，无需降级，不修改 is_lowered */
        } else if (!popup_exists && is_lowered) {
            /* 弹窗消失 → 恢复到降级前的实测 Level */
            int changed = set_my_windows_level(lowered_to_level, original_game_level);
            if (changed > 0) {
                game_level = original_game_level;
#ifdef DEBUG
                fprintf(stderr, "[compat] installer popup gone, restored game lv %d→%d\n",
                        lowered_to_level, original_game_level);
#endif
            }
            /* 无论是否找到窗口（winemac.drv 可能已自然恢复），都重置状态 */
            is_lowered          = 0;
            original_game_level = -1;
            lowered_to_level    = -1;
        }

        /* ── Part B：把进程内小弹窗提升到 game_level+1 ── */
        /* 游戏主窗口未找到（还未进入全屏）→ 跳过本轮 Part B */
        if (game_level >= 0) {
            int popup_level = game_level + 1;
            for (CFIndex i = 0; i < count; i++) {
                CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(win_list, i);
                if (!info) continue;

                /* 只处理本进程窗口 */
                CFNumberRef pid_ref = (CFNumberRef)CFDictionaryGetValue(info, CFSTR("kCGWindowOwnerPID"));
                if (!pid_ref) continue;
                int win_pid = 0;
                CFNumberGetValue(pid_ref, kCFNumberIntType, &win_pid);
                if (win_pid != (int)my_pid) continue;

                /* 已在 game_level 以上，无需处理 */
                CFNumberRef level_ref = (CFNumberRef)CFDictionaryGetValue(info, CFSTR("kCGWindowLayer"));
                if (!level_ref) continue;
                int lv = 0;
                CFNumberGetValue(level_ref, kCFNumberIntType, &lv);
                if (lv > game_level) continue;

                /* 过滤全屏主窗口和噪音小窗口 */
                CFDictionaryRef bounds = (CFDictionaryRef)CFDictionaryGetValue(info, CFSTR("kCGWindowBounds"));
                if (!bounds) continue;
                CFNumberRef w_ref = (CFNumberRef)CFDictionaryGetValue(bounds, CFSTR("Width"));
                CFNumberRef h_ref = (CFNumberRef)CFDictionaryGetValue(bounds, CFSTR("Height"));
                if (!w_ref || !h_ref) continue;
                double w = 0, h = 0;
                CFNumberGetValue(w_ref, kCFNumberDoubleType, &w);
                CFNumberGetValue(h_ref, kCFNumberDoubleType, &h);
                if (w >= 1500.0 || w < 100.0 || h < 80.0) continue;

                /* 提升到 game_level+1 */
                CFNumberRef wid_ref = (CFNumberRef)CFDictionaryGetValue(info, CFSTR("kCGWindowNumber"));
                if (!wid_ref) continue;
                int wid = 0;
                CFNumberGetValue(wid_ref, kCFNumberIntType, &wid);
                if (wid <= 0) continue;

                CGSSetWindowLevel(cid, wid, popup_level);
#ifdef DEBUG
                fprintf(stderr, "[compat] in-process popup WID=%d (%.0fx%.0f) raised lv %d→%d\n",
                        wid, w, h, lv, popup_level);
#endif
            }
        }

        CFRelease(win_list);
    }
    return NULL;
}

/* 启动游戏窗口 Level 监控线程（仅在 yysls.exe 进程中调用） */
static void start_game_level_monitor(void) {
    pthread_t tid;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&tid, &attr, game_level_monitor_thread, NULL);
    pthread_attr_destroy(&attr);
}

/* ========== 入口点 ========== */

__attribute__((constructor))
static void init_winecompat(void) {
    /* CX_ROOT: Wine 源码约定的运行时根路径环境变量 */
    const char *cx_root = getenv("CX_ROOT");
    if (!cx_root || !cx_root[0]) return;

    /* 获取 ntdll 导出函数 */
    prepend_dll_path_fn = (void (*)(const char *))dlsym(RTLD_DEFAULT, "prepend_dll_path");
    if (!prepend_dll_path_fn) return;

    /* 安装 syscall hooks: NtCreateUserProcess */
    install_syscall_hooks();

    /* ========== 进程内配置 ========== */

    /* 获取当前进程 exe 路径 */
    int wchar_len = 0;
    const WCHAR *exe_path = get_current_exe_path(&wchar_len);

    /*
     * Step 1: 按 exe 路径匹配图形后端
     * yysls.exe 和 wwm.exe 使用 dxmt（Metal 原生图形层）
     */
    int backend = 0;  /* 0=未决定 */

    if (exe_path && wchar_len > 0) {
        if (wstr_ends_with_icase(exe_path, wchar_len, "\\yysls.exe") ||
            wstr_ends_with_icase(exe_path, wchar_len, "\\wwm.exe")) {
            backend = 2;  /* dxmt */
        }
    }

    /*
     * Step 2: 无规则匹配时自动检测
     * 检测 Rosetta → d3dmetal；否则 → wined3d (fallback)
     */
    if (backend == 0) {
        if (is_rosetta()) {
            backend = 3;  /* d3dmetal */
        } else {
            backend = 1;  /* wined3d */
        }
    }

    /*
     * Step 3: 应用 backend
     * 无论什么 backend 都用 overwrite=1 覆盖环境变量，确保子进程继承值被正确覆盖
     */
    const char *backend_name = NULL;
    const char *backend_path = NULL;

    /*
     * add_load_order_override: Wine ntdll 导出函数，动态添加 DLL 加载顺序规则。
     * 源码位置: dlls/ntdll/unix/loadorder.c:255
     * 导出确认: nm ntdll.so | grep add_load_order → T _add_load_order_override
     * 作用：设置 "dxgi=native,builtin" 等规则，让 Wine 优先加载 DXMT 的 PE DLL。
     */
    void (*add_load_order_override_fn)(const WCHAR *) =
        (void (*)(const WCHAR *))dlsym(RTLD_DEFAULT, "add_load_order_override");

    switch (backend) {
    case 2:  /* dxmt */
        backend_name = "dxmt";
        backend_path = "lib/dxmt";
        /*
         * DXMT 通过 PE DLL (x86_64-windows/d3d11.dll) 工作，
         * 需要显式设置 native load order 让 Wine 优先加载 prepend 路径中的 PE DLL。
         * 某些 Wine 构建可能通过内部补丁隐式实现了这一点，
         * 但我们的 build 需要显式调用。
         * 注意：只对 dxmt 调用，d3dmetal 不需要（它通过 Unix .so 层工作）。
         */
        if (add_load_order_override_fn) {
            WCHAR ovr[64];
            /* dxgi=native,builtin */
            const char *s1 = "dxgi=native,builtin";
            for (int i = 0; s1[i]; i++) ovr[i] = (unsigned char)s1[i]; ovr[19] = 0;
            add_load_order_override_fn(ovr);
            /* d3d11=native,builtin */
            const char *s2 = "d3d11=native,builtin";
            for (int i = 0; s2[i]; i++) ovr[i] = (unsigned char)s2[i]; ovr[20] = 0;
            add_load_order_override_fn(ovr);
            /* d3d10core=native,builtin */
            const char *s3 = "d3d10core=native,builtin";
            for (int i = 0; s3[i]; i++) ovr[i] = (unsigned char)s3[i]; ovr[24] = 0;
            add_load_order_override_fn(ovr);
        }
        break;
    case 3:  /* d3dmetal */
        backend_name = "d3dmetal";
        backend_path = "lib64/apple_gptk/wine";
        break;
    case 1:  /* wined3d */
    default:
        backend_name = "wined3d";
        backend_path = NULL;  /* 不 prepend */
        break;
    }

    /* setenv - 每个进程都执行，覆盖继承值 */
    setenv("CX_ACTIVE_GRAPHICS_BACKEND", backend_name, 1);

    /* prepend_dll_path - wined3d 时不 prepend */
    if (backend_path) {
        load_backend_dll_dir(backend_path);
    }

    /*
     * Step 4: 按进程名注入额外环境变量
     * FeverGamesInstaller.exe / launcher.exe → QMLSCENE_DEVICE=softwarecontext
     * （Qt Quick 软件渲染，避免 GPU 初始化冲突）
     */
    if (exe_path && wchar_len > 0) {
        if (wstr_ends_with_icase(exe_path, wchar_len, "\\fevergamesinstaller.exe") ||
            wstr_ends_with_icase(exe_path, wchar_len, "\\yysls\\win32\\deploy\\launcher.exe") ||
            wstr_ends_with_icase(exe_path, wchar_len, "\\wwm\\win32\\deploy\\launcher.exe")) {
            setenv("QMLSCENE_DEVICE", "softwarecontext", 0);
        }

        /* 在 yysls.exe 进程内监控 FeverGamesInstaller 弹窗，主动降低游戏窗口 Level */
        if (wstr_ends_with_icase(exe_path, wchar_len, "\\yysls.exe")) {
            start_game_level_monitor();
        }
    }

    /* Debug 输出 */
#ifdef DEBUG
    if (exe_path && wchar_len > 0) {
        /* 打印 exe 路径最后 60 个字符方便调试 */
        int start = (wchar_len > 60) ? wchar_len - 60 : 0;
        char dbg_path[128] = {0};
        int j = 0;
        for (int i = start; i < wchar_len && j < 126; i++) {
            WCHAR c = exe_path[i];
            dbg_path[j++] = (c > 0 && c < 128) ? (char)c : '?';
        }
        fprintf(stderr, "[compat] [%s] %s | exe=%s\n", backend_name,
                (backend == 2) ? "matched" : "auto", dbg_path);

        /* 对 webview_support_browser.exe 打印完整命令行验证 append 是否生效 */
        if (wstr_ends_with_icase(exe_path, wchar_len, "\\webview_support_browser.exe")) {
            PVOID (*NtCurrentTeb_fn2)(void) = dlsym(RTLD_DEFAULT, "NtCurrentTeb");
            if (NtCurrentTeb_fn2) {
                PVOID teb2 = NtCurrentTeb_fn2();
                if (teb2) {
                    PVOID peb2 = *(PVOID *)((char *)teb2 + 0x60);
                    if (peb2) {
                        PVOID params2 = *(PVOID *)((char *)peb2 + 0x20);
                        if (params2) {
                            unsigned short cmd_len = *(unsigned short *)((char *)params2 + 0x70);
                            WCHAR *cmd_buf = *(WCHAR **)((char *)params2 + 0x78);
                            if (cmd_buf && cmd_len > 0) {
                                int cmd_wchars = cmd_len / 2;
                                char cmd_dbg[512] = {0};
                                int k = 0;
                                int limit = (cmd_wchars > 510) ? 510 : cmd_wchars;
                                for (int i = 0; i < limit && k < 510; i++) {
                                    WCHAR c = cmd_buf[i];
                                    cmd_dbg[k++] = (c > 0 && c < 128) ? (char)c : '?';
                                }
                                fprintf(stderr, "[compat] webview cmdline [%d]: %s\n",
                                        cmd_wchars, cmd_dbg);
                            }
                        }
                    }
                }
            }
        }
    } else {
        fprintf(stderr, "[compat] [%s] auto (no exe path)\n", backend_name);
    }
#endif
}
