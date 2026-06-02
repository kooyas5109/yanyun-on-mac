# Security

## 报告安全问题

如果发现安全漏洞，请通过 Issue 联系。如果涉及敏感细节，先提一个不含具体信息的 Issue 标题，我会私下联系你。

## App 权限说明

本 App 需要以下 macOS entitlements 才能正常运行 Wine 环境：

| Entitlement | 用途 | 必要性 |
|-------------|------|--------|
| `disable-library-validation` | 加载未签名的 Wine .so/.dylib | Wine 社区编译的库没有 Apple 签名 |
| `allow-unsigned-executable-memory` | Rosetta 2 运行 x86_64 Wine 需要 JIT | Wine 翻译 Windows 程序时需要动态生成代码 |
| `allow-dyld-environment-variables` | 传递 `DYLD_FALLBACK_LIBRARY_PATH` 给 Wine 进程 | Wine 运行时库的搜索路径 |
| `network.client` | 下载游戏安装器 | 仅在用户点击下载时发起请求 |
| `files.user-selected.read-write` | 访问 Wine prefix 和游戏文件 | 游戏数据读写 |

**App 不会：**
- 注入系统进程或修改系统文件
- 访问其他应用的数据
- 在后台发起网络请求
- 读取 Wine prefix 和游戏目录之外的文件

## Wine Z: 盘映射

Wine 默认将 macOS 根目录映射为 `Z:` 盘，这是 Wine 的标准行为。游戏进程运行在 Wine 环境内，受 Wine 的文件系统层限制。

## 依赖的开源组件

安全问题如涉及以下组件，建议直接向上游报告：

| 组件 | 来源 |
|------|------|
| Wine | [winehq.org](https://www.winehq.org) |
| DXMT | [github.com/3Shain/dxmt](https://github.com/3Shain/dxmt) |
| MoltenVK | [github.com/KhronosGroup/MoltenVK](https://github.com/KhronosGroup/MoltenVK) |
