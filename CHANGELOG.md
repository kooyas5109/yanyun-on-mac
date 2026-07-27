# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/)，版本号遵循 [Semantic Versioning](https://semver.org/)。

## [Unreleased]

### Added
- 增加 Wine/DXMT 组件版本锁、v0.1.1 全文件 SHA-256 基线和运行时装配/验证脚本
- 增加一键导出脱敏日志、环境信息、运行时哈希和相关崩溃报告
- 增加 Swift 单元测试、macOS CI、签名校验和自动公证工作流
- 增加固定到 DXMT v0.80 提交的源码补丁

### Changed
- prefix、mshtml 和游戏平台成功标记只在命令返回码与真实文件校验通过后写入
- Wine 进程检测和退出改为当前 WINEPREFIX、受管 PID 及其子进程范围
- 缺少初始化标记时改为原地修复，不再自动删除已有 Wine prefix
- DXMT 旧版内存补丁只对 SHA-256 精确匹配的 v0.1.1 二进制启用

## [0.1.1] - 2026-07-09

### Added
- 增加支持遗忘之海

### Changed
- 构建脚本改成按游戏出包，dev-deploy.sh / build-release.sh 后面加游戏名，每个游戏数据目录和 Wine 环境各自独立

### Fixed
- 修复登录时偶尔弹出的网页窗口会闪退的问题（Wine 内置 mshtml 的类型库没注册进注册表，补上就可以了）
- 修复游戏内语音之前用不了的问题，加上了麦克风权限申请

## [0.1.0] - 2026-06-02

第一个公开版本。

### Added
- macOS 15+ / Apple Silicon 启动器（Swift / AppKit）
- Wine 11 运行时（自行编译，含 macOS 适配修改）
- DXMT 0.80，D3D11/12 → Metal
- winecompat 兼容组件：自动选渲染后端、处理子进程环境、修复窗口层级
- 一键构建脚本（`dev-deploy.sh`、`build-release.sh`）

[Unreleased]: ../../compare/v0.1.1...HEAD
[0.1.1]: ../../releases/tag/v0.1.1
[0.1.0]: ../../releases/tag/v0.1.0
