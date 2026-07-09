# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/)，版本号遵循 [Semantic Versioning](https://semver.org/)。

## [Unreleased]

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
