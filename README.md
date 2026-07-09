<div align="center">

<!-- <img src="docs/screenshots/banner.png" alt="Yanyun on Mac" width="100%"> -->

# Yanyun on Mac

在 Mac 上玩燕云十六声和遗忘之海，不用装 Windows

[![License](https://img.shields.io/badge/license-LGPL--2.1-blue.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey.svg)](#系统要求)
[![Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-success.svg)](#系统要求)
[![Built with Wine](https://img.shields.io/badge/built%20with-Wine%2011-red.svg)](https://www.winehq.org/)
[![Powered by DXMT](https://img.shields.io/badge/powered%20by-DXMT-orange.svg)](https://github.com/3Shain/dxmt)

</div>

<!-- <p align="center"><img src="docs/screenshots/demo.gif" width="720"></p> -->

## 功能

- 🍎 Apple Silicon Mac，通过 Wine + Rosetta 2 运行
- 🎮 DirectX → Metal，基于 DXMT 转译
- 📦 一键启动，自动配置和安装环境
- 🎨 多渲染后端自动切换，窗口层级自动修复
- 🪶 下载即用，开箱无需配置

## 快速开始

到 [Releases](../../releases) 下载对应游戏的 DMG：燕云是 Yanyun.dmg，遗忘之海是 遗忘之海模拟器.dmg。打开后把里面的 .app 拖进 Applications 就行。

> 首次运行 macOS 可能会提示「无法验证开发者」，需要在「系统设置 → 隐私与安全性」中点击「仍要打开」。

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 系统版本 | macOS 15 (Sequoia) 及以上 |
| 处理器 | Apple Silicon（M1 / M2 / M3 / M4） |
| 内存 | 16 GB 以上 |
| 磁盘空间 | 10 GB 以上 |

不支持 Intel Mac。

## 工作原理

```
┌────────────┐     ┌──────┐     ┌──────┐     ┌───────┐
│ Game (.exe)│ ──▶ │ Wine │ ──▶ │ DXMT │ ──▶ │ Metal │
└────────────┘     └──────┘     └──────┘     └───────┘
```

Wine 负责把 Windows 系统调用翻译成 macOS 的，DXMT 把 DirectX 图形指令转成 Metal。

`winecompat` 是我写的一个小组件，负责给不同进程选择渲染后端、处理子进程环境变量注入和窗口层级的问题。

## 常见问题

**启动后长时间没反应？**

第一次启动需要等待 Wine 初始化环境，通常要一到两分钟。

**游戏闪退？**

关掉其他占内存比较多的应用试试，在 Mac 上运行燕云还是需要挺多内存的。

<details>
<summary><b>从源码构建</b></summary>

### 前置依赖

- Xcode Command Line Tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（可选，用于生成 Xcode 项目）

```bash
brew install xcodegen
```

### 构建步骤

```bash
# 克隆仓库
git clone https://github.com/novak037/yanyun-on-mac.git
cd yanyun-on-mac

# 准备 Wine 运行时（需要从 Wine 源码自行编译，放到 output/ 下）
mkdir -p output

# 指定 .app / .dmg 的输出目录
export OUTPUT_DIR=~/Desktop

# 开发构建 + 部署（游戏名填 yanyun 或 ywzh，不带参数会让你选）
bash scripts/dev-deploy.sh yanyun

# 正式打包（签名 + DMG）
bash scripts/build-release.sh yanyun
```

### 编译 winecompat

```bash
bash wine/winecompat/build.sh          # release
bash wine/winecompat/build.sh --debug  # debug（输出调试日志）
```

### 项目结构

```
app/                    # macOS App（Swift / AppKit）
├── Simulator/
│   └── main.swift      # 主程序（两个游戏共用）
└── targets/            # 每个游戏各自的配置、图标、FAQ
    ├── yanyun/
    └── ywzh/
wine/
└── winecompat/         # Wine 进程兼容组件（C，编译为 .so）
scripts/                # 构建脚本
output/
└── wine-release/       # Wine 运行时（需自行编译，不在仓库中）
```

</details>

## 致谢

- [Wine](https://www.winehq.org/) — Windows 兼容层
- [DXMT](https://github.com/3Shain/dxmt) by 3Shain — DirectX → Metal 转译
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) — Vulkan → Metal

完整的组件列表和许可证信息见 [THIRD_PARTY.md](./THIRD_PARTY.md)。

## 许可证

[LGPL-2.1](./LICENSE)
