# Claude Code 安装/升级脚本

覆盖**全新安装**、**版本升级**、**PATH 修复**、**残留清理**，同时支持 launchd **每日自动更新**。

## 文件说明

| 文件 | 用途 | 运行方式 |
|------|------|----------|
| `upgrade-claude.sh` | 手动安装/升级脚本 | 用户手动执行 |
| `auto-update.sh` | 每日自动更新 | launchd 定时调度 |

## 快速开始

```bash
# 下载
git clone https://github.com/pxf0797/claude-code-upgrade.git
cd claude-code-upgrade

# 手动安装或升级
chmod +x upgrade-claude.sh
./upgrade-claude.sh
```

## upgrade-claude.sh — 6 阶段流程

```
0. 环境检测  → Node.js ≥ 22 · npm 可用 · 网络可达
1. 状态检测  → 远程最新版 · 本地版本 · 残留扫描
2. 安装/升级 → 全新安装 / 版本升级 / 已最新跳过
               npm 失败自动诊断：权限 / 网络 / 路径
3. 符号链接  → 检测缺失/错误/brew残留，自动修复
4. 验证      → 二进制可运行 · 版本一致 · 唯一入口
5. 清理      → brew cask 残留 · 多入口警告
6. 汇总      → 版本 · 路径 · 日志
```

### 覆盖的边界场景

- 完全卸载后全新安装
- 手动升级到最新版本
- launchd 受限 PATH 下执行
- npm install 失败（EACCES / ENOENT / ETIMEDOUT）
- 符号链接缺失或指向错误路径
- Homebrew Cask 与 npm 双头管理冲突
- PATH 中缺少 npm bin 目录
- Node.js 版本不兼容
- 网络/代理问题

## auto-update.sh — launchd 每日调度

部署为 launchd agent（`~/Library/LaunchAgents/com.anthropic.claude-code-update.plist`），每天定时检查更新。

### 增强特性

- PATH 兼容 launchd 受限环境
- Claude Code 未安装时自动恢复安装
- npm registry 不通时跳过（不误报）
- 升级失败时引导手动运行 `upgrade-claude.sh`

## 环境要求

- macOS（ARM64 或 Intel）
- Node.js ≥ 22
- npm ≥ 9

## License

MIT
