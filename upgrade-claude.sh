#!/bin/bash
set -euo pipefail
# ============================================================
# Claude Code 安装/升级脚本
# 覆盖场景：全新安装 / 版本升级 / 已是最新 / PATH修复 / 残留清理
# ============================================================

# 防御：确保 homebrew 路径在 PATH 中（launchd/非交互式环境兼容），仅当缺失时前插，避免制造重复项
for _d in /opt/homebrew/bin /usr/local/bin; do
    case ":$PATH:" in
        *":$_d:"*) ;;                 # 已在 PATH 中，跳过
        *) PATH="$_d:$PATH" ;;        # 缺失才前插
    esac
done
export PATH
unset _d

readonly PACKAGE="@anthropic-ai/claude-code"
readonly LOG_FILE="$HOME/.claude/upgrade-claude.log"
readonly REQUIRED_NODE_MAJOR=22

# 运行时检测
NPM_PREFIX=""
NPM_BIN=""
NPM_ROOT=""
BREW_RESIDUE=0
BINARY_HEALTHY=0

# ---- 颜色 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
}

success() { echo -e "${GREEN}✅ $1${NC}"; log "SUCCESS: $1"; }
warn()   { echo -e "${YELLOW}⚠️  $1${NC}"; log "WARN: $1"; }
error()  { echo -e "${RED}❌ $1${NC}"; log "ERROR: $1"; }

die() {
    error "$1"
    echo ""
    echo "📋 排查建议："
    echo "   1. 确认 Node.js ≥ ${REQUIRED_NODE_MAJOR}: node --version"
    echo "   2. 确认 npm 可用: npm --version"
    echo "   3. 确认网络可访问: curl -sI https://registry.npmjs.org/ | head -1"
    echo "   4. 日志: cat $LOG_FILE"
    exit 1
}

# ============================================================
# 原生二进制健康检测 / 修复
# ============================================================
# 2.1.x 的 claude = "JS 壳 + 原生二进制"。install.cjs(postinstall) 把 optional 依赖
# (@…-darwin-arm64 等) 里的原生二进制硬链接进 bin/claude.exe。下载失败或 --omit=optional
# 时会留一个 JS 桩，运行时报 "claude native binary not installed"。用 file 类型区分。
is_binary_healthy() {
    local exe="$NPM_ROOT/$PACKAGE/bin/claude.exe"
    [ -f "$exe" ] && file "$exe" 2>/dev/null | grep -qiE 'Mach-O|ELF|PE32'
}

# 修复缺失/损坏的原生二进制：先重跑 postinstall(optional 依赖已在盘上则秒链)，
# 仍不行再 --force 强制重装以重新拉取 optional 依赖。
repair_binary() {
    echo "   → 重跑 postinstall 尝试重链原生二进制…"
    node "$NPM_ROOT/$PACKAGE/install.cjs" 2>&1 | tee -a "$LOG_FILE" || true
    if is_binary_healthy; then
        success "原生二进制已修复 (postinstall 重链)"
        return 0
    fi
    echo "   → optional 依赖疑似缺失，强制重装以重新拉取…"
    if npm install -g "${PACKAGE}@${REMOTE_LATEST}" --force 2>&1 | tee -a "$LOG_FILE" && is_binary_healthy; then
        success "原生二进制已修复 (强制重装)"
        return 0
    fi
    return 1
}

# ============================================================
# 阶段 0: 环境检测
# ============================================================

preflight_check() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Claude Code 安装/升级脚本"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log "========== 执行 =========="

    echo "→ 检测 Node.js…"
    if ! command -v node &>/dev/null; then
        die "Node.js 未安装。请先安装 Node.js ≥ ${REQUIRED_NODE_MAJOR}: brew install node"
    fi
    local node_major
    node_major=$(node --version | sed 's/v//' | cut -d. -f1)
    if [ "$node_major" -lt "$REQUIRED_NODE_MAJOR" ]; then
        die "Node.js v$(node --version) < v${REQUIRED_NODE_MAJOR}。请升级: brew upgrade node"
    fi
    success "Node.js $(node --version)"

    echo "→ 检测 npm…"
    if ! command -v npm &>/dev/null; then
        die "npm 未找到。请安装 Node.js（npm 随 Node.js 一起安装）"
    fi
    success "npm $(npm --version)"

    echo "→ 检测网络…"
    if ! npm ping &>/dev/null; then
        # npm ping 失败，再用 curl 尝试诊断
        local http_code
        http_code=$(curl -sI -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
            https://registry.npmjs.org/ 2>/dev/null || echo "000")
        die "无法连接 npm registry (HTTP $http_code)。请检查网络/代理"
    fi
    success "npm registry 可达"

    NPM_PREFIX=$(npm config get prefix 2>/dev/null || echo "")
    [ -z "$NPM_PREFIX" ] && die "无法确定 npm prefix"
    NPM_BIN="$NPM_PREFIX/bin"
    NPM_ROOT="$NPM_PREFIX/lib/node_modules"

    log "NPM_PREFIX=$NPM_PREFIX"
    echo ""
}

# ============================================================
# 阶段 1: 状态检测 + 残留扫描
# ============================================================

detect_state() {
    echo "→ 获取远程版本…"
    REMOTE_LATEST=$(npm view "$PACKAGE" version 2>/dev/null || echo "")
    [ -z "$REMOTE_LATEST" ] && die "无法获取 $PACKAGE 远程版本"
    log "远程最新: $REMOTE_LATEST"

    # 本地 CLI
    LOCAL_BIN_PATH=""
    CURRENT=""
    if command -v claude &>/dev/null; then
        LOCAL_BIN_PATH=$(command -v claude)
        CURRENT=$(claude --version 2>/dev/null | awk '{print $1}') || true
    elif [ -x "$NPM_ROOT/$PACKAGE/bin/claude.exe" ]; then
        LOCAL_BIN_PATH="$NPM_ROOT/$PACKAGE/bin/claude.exe"
        CURRENT=$("$LOCAL_BIN_PATH" --version 2>/dev/null | awk '{print $1}') || true
    fi

    # npm 包版本
    NPM_PKG_VERSION=""
    if [ -f "$NPM_ROOT/$PACKAGE/package.json" ]; then
        NPM_PKG_VERSION=$(python3 -c "
import json, sys
with open('$NPM_ROOT/$PACKAGE/package.json') as f:
    print(json.load(f).get('version',''))
" 2>/dev/null || echo "")
    fi

    echo ""
    # 原生二进制健康检测
    if is_binary_healthy; then BINARY_HEALTHY=1; else BINARY_HEALTHY=0; fi

    echo "  ┌─────────────────────────────────────────"
    echo "  │ 远程最新:  $REMOTE_LATEST"
    echo "  │ 本地 CLI:  ${CURRENT:-未安装}"
    echo "  │ CLI 路径:  ${LOCAL_BIN_PATH:-无}"
    echo "  │ npm 包:    ${NPM_PKG_VERSION:-未安装}"
    echo "  │ 原生二进制: $([ "$BINARY_HEALTHY" -eq 1 ] && echo '正常' || echo '缺失/损坏')"
    echo "  │ npm bin:   $NPM_BIN"
    echo "  └─────────────────────────────────────────"
    echo ""

    # 残留扫描
    echo "→ 扫描残留…"
    local found=0

    if [ -d "/opt/homebrew/Caskroom/claude-code" ] || \
       [ -d "/usr/local/Caskroom/claude-code" ]; then
        warn "发现 brew cask 残留"
        BREW_RESIDUE=1; found=1
    fi

    local claude_count
    claude_count=$(which -a claude 2>/dev/null | wc -l | tr -d ' ')
    if [ "$claude_count" -gt 1 ]; then
        warn "PATH 中有 $claude_count 个 claude:"
        which -a claude 2>/dev/null | while read -r line; do echo "     $line"; done
        found=1
    fi

    if [ -f "/usr/local/bin/claude" ] && [ "$(uname -m)" = "arm64" ]; then
        warn "Intel 路径残留: /usr/local/bin/claude（ARM Mac 不应使用）"
        found=1
    fi

    [ "$found" -eq 0 ] && success "无残留"
    echo ""
}

# ============================================================
# 阶段 2: 安装/升级
# ============================================================

do_install_or_upgrade() {
    if [ -z "$CURRENT" ]; then
        echo "→ 动作: 全新安装 $PACKAGE@$REMOTE_LATEST"
    elif [ "$CURRENT" != "$REMOTE_LATEST" ]; then
        echo "→ 动作: 升级 $CURRENT → $REMOTE_LATEST"
    else
        if [ "$BINARY_HEALTHY" -eq 1 ]; then
            echo "→ 动作: 已是最新 ($CURRENT)，跳过安装"
            echo ""
            return 0
        fi
        echo "→ 动作: 版本已是最新 ($CURRENT) 但原生二进制缺失/损坏，执行修复"
        echo ""
        if repair_binary; then
            echo ""
            return 0
        fi
        die "原生二进制修复失败。手动: node $NPM_ROOT/$PACKAGE/install.cjs  或  npm install -g ${PACKAGE}@latest --force"
    fi
    echo ""

    echo "⏳ 正在下载 ${PACKAGE} (~250MB，约需 1-5 分钟)..."
    echo "   请勿关闭此窗口"

    log "npm install -g ${PACKAGE}@${REMOTE_LATEST}"
    log "正在安装 ${PACKAGE}@${REMOTE_LATEST} ..."
    local npm_output
    local npm_install_log
    npm_install_log="$HOME/.claude/install-$(date +%Y%m%d-%H%M%S).log"
    set +o pipefail
    npm install -g --loglevel verbose "${PACKAGE}@${REMOTE_LATEST}" 2>&1 | tee "$npm_install_log"
    local npm_exit_code=${PIPESTATUS[0]}
    set -o pipefail
    npm_output="$(<"$npm_install_log")"
    rm -f "$npm_install_log"

    if [ "$npm_exit_code" -ne 0 ]; then
        error "npm install 失败"
        echo ""
        echo "$npm_output" | tail -20
        echo ""

        if echo "$npm_output" | grep -qi "EACCES\|permission denied"; then
            echo "🔧 权限不足。修复方法:"
            echo "   sudo chown -R \$(whoami) $NPM_PREFIX"
        elif echo "$npm_output" | grep -qi "ENOENT"; then
            echo "🔧 目录缺失: mkdir -p $NPM_ROOT"
        elif echo "$npm_output" | grep -qi "ETIMEDOUT\|ENOTFOUND\|network\|ECONNREFUSED"; then
            echo "🔧 网络问题。检查代理: npm config get proxy"
        fi
        die "npm install 失败"
    fi

    echo "✅ 下载完成，正在验证..."
    success "npm install 完成"
    log "npm output: $(echo "$npm_output" | tail -3 | tr '\n' ' ')"

    [ ! -f "$NPM_ROOT/$PACKAGE/package.json" ] && \
        die "安装后未找到 $NPM_ROOT/$PACKAGE/package.json"

    # 安全网：install 后原生二进制仍是桩(optional 下载失败)则就地修复
    if ! is_binary_healthy; then
        warn "npm install 完成但原生二进制缺失，尝试修复…"
        repair_binary || die "原生二进制修复失败。手动: node $NPM_ROOT/$PACKAGE/install.cjs"
    fi

    CURRENT=$(python3 -c "
import json
with open('$NPM_ROOT/$PACKAGE/package.json') as f:
    print(json.load(f).get('version',''))
" 2>/dev/null || echo "$REMOTE_LATEST")
}

# ============================================================
# 阶段 3: 符号链接修复
# ============================================================

fix_symlink() {
    echo "→ 检查符号链接…"

    local claude_exe="$NPM_ROOT/$PACKAGE/bin/claude.exe"
    [ ! -f "$claude_exe" ] && die "找不到 claude.exe: $claude_exe"

    local symlink="$NPM_BIN/claude"
    local target="../lib/node_modules/$PACKAGE/bin/claude.exe"

    if [ -L "$symlink" ]; then
        local current
        current=$(readlink "$symlink" 2>/dev/null || echo "")
        if [ "$current" != "$target" ]; then
            warn "符号链接错误: $current → 修正为 $target"
            rm -f "$symlink"
            ln -s "$target" "$symlink"
            success "符号链接已修正"
        else
            success "符号链接正确"
        fi
    elif [ -e "$symlink" ]; then
        warn "$symlink 不是符号链接（可能为 brew 残留），替换中…"
        rm -f "$symlink"
        ln -s "$target" "$symlink"
        success "已替换为符号链接"
    else
        echo "   创建符号链接 $symlink → $target"
        ln -s "$target" "$symlink"
        success "符号链接已创建"
    fi

    # 确保 PATH 包含 NPM_BIN
    if ! echo "$PATH" | grep -q "$NPM_BIN"; then
        warn "$NPM_BIN 不在 PATH 中!"
        echo ""
        echo "   🔧 请将以下行添加到 ~/.zshrc:"
        echo ""
        echo "      export PATH=\"$NPM_BIN:\$PATH\""
        echo ""
    fi
    echo ""
}

# ============================================================
# 阶段 4: 验证
# ============================================================

verify() {
    echo "→ 验证安装…"

    if ! command -v claude &>/dev/null; then
        die "claude 命令在 PATH 中找不到。请将 $NPM_BIN 加入 PATH 后重试"
    fi

    local verify_version
    verify_version=$(claude --version 2>/dev/null | awk '{print $1}') || {
        die "claude --version 执行失败，二进制可能损坏"
    }

    if [ "$verify_version" != "$REMOTE_LATEST" ]; then
        warn "运行版本 ($verify_version) ≠ 远程最新 ($REMOTE_LATEST)，可能有缓存延迟"
    else
        success "claude --version → $verify_version ✓"
    fi

    local count
    count=$(which -a claude 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt 1 ]; then
        warn "PATH 中有 $count 个 claude，可能运行错误版本:"
        which -a claude 2>/dev/null | while read -r line; do echo "     $line"; done
    else
        success "PATH 仅一个 claude: $(which claude)"
    fi
    echo ""
}

# ============================================================
# 阶段 5: 清理
# ============================================================

cleanup() {
    echo "→ 清理…"

    if [ "$BREW_RESIDUE" -eq 1 ]; then
        echo "   卸载 brew cask…"
        if brew uninstall --cask claude-code 2>/dev/null; then
            success "brew cask 已卸载"
        else
            warn "brew 卸载失败，手动清理: rm -rf /opt/homebrew/Caskroom/claude-code"
        fi
        # brew 卸载时会删除 symlink，重建
        if [ ! -e "$NPM_BIN/claude" ] && [ -f "$NPM_ROOT/$PACKAGE/bin/claude.exe" ]; then
            ln -s "../lib/node_modules/$PACKAGE/bin/claude.exe" "$NPM_BIN/claude"
            log "重建被 brew 删除的符号链接"
        fi
    else
        success "无需清理"
    fi
    echo ""
}

# ============================================================
# 阶段 5.5: 同步到 GitHub
# ============================================================

sync_to_github() {
    log "正在同步到 GitHub ..."

    # 检查是否为 git 仓库
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        warn "当前目录不是 git 仓库，跳过 GitHub 同步"
        return 0
    fi

    # 检查是否有变更
    if git diff --quiet && git diff --cached --quiet; then
        log "没有文件变更，跳过 GitHub 同步"
        return 0
    fi

    # 暂存变更（脚本自身）
    git add upgrade-claude.sh 2>/dev/null || git add -A

    # 生成 commit message（包含版本号）
    local new_version="${1:-latest}"
    local commit_msg="chore: upgrade claude-code to ${new_version}"

    if ! git commit -m "$commit_msg" 2>&1; then
        warn "Git commit 失败，跳过 GitHub 同步"
        return 0
    fi

    # 推送到远程
    if git push 2>&1; then
        success "已同步到 GitHub ($new_version)"
    else
        warn "Git push 失败，请手动推送。commit 已创建"
    fi
}

# ============================================================
# 阶段 6: 汇总
# ============================================================

summary() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  完成"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  版本:     $(claude --version 2>/dev/null || echo '验证失败')"
    echo "  CLI:      $(which claude 2>/dev/null || echo '未找到')"
    echo "  npm 包:   $NPM_ROOT/$PACKAGE"
    echo "  日志:     $LOG_FILE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    success "Claude Code 已就绪"
}

# ============================================================
# 阶段 6.5: 深度安装验证
# ============================================================

verify_install() {
    local BIN="${NPM_BIN}/claude"
    local errors=0

    echo "→ 验证安装..."

    # 1. 检查二进制存在且大小 > 1000 bytes（排除 JS 桩）
    if [ -f "$BIN" ]; then
        local size
        size=$(stat -f%z "$BIN" 2>/dev/null || echo "0")
        if [ "$size" -lt 1000 ]; then
            echo "  ❌ 二进制疑似 JS 桩 (${size} bytes)"
            ((errors++))
        else
            echo "  ✅ 二进制大小正常 (${size} bytes)"
        fi
    else
        echo "  ❌ 二进制不存在"
        ((errors++))
    fi

    # 2. 检查是否为 Mach-O 原生二进制
    if file "$BIN" 2>/dev/null | grep -q "Mach-O"; then
        echo "  ✅ Mach-O 原生二进制"
    else
        echo "  ⚠️  非 Mach-O 格式 ($(file "$BIN" 2>/dev/null))"
    fi

    # 3. 检查可执行性
    if "$BIN" --version >/dev/null 2>&1; then
        local ver
        ver=$("$BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        echo "  ✅ 可执行 (版本: $ver)"
    else
        echo "  ❌ 无法执行"
        ((errors++))
    fi

    # 4. 检查 native addon
    local addon
    addon=$(find /opt/homebrew/lib/node_modules/@anthropic-ai -name "*.node" 2>/dev/null | head -1)
    if [ -n "$addon" ]; then
        echo "  ✅ Native addon: $addon"
    else
        echo "  ❌ Native addon 缺失"
        ((errors++))
    fi

    return $errors
}

# ============================================================
# 主流程
# ============================================================

main() {
    # 处理命令行参数
    for arg in "$@"; do
        case "$arg" in
            --verify-only)
                # 仅运行深度验证，不做安装
                preflight_check
                if verify_install; then
                    echo "✅ 健康检查通过"
                    exit 0
                else
                    echo "❌ 健康检查未通过"
                    exit 1
                fi
                ;;
            --quiet)
                # 静默模式：重定向输出到日志文件
                exec 1> >(tee -a "$LOG_FILE")
                exec 2>&1
                ;;
        esac
    done

    preflight_check
    detect_state
    do_install_or_upgrade
    fix_symlink

    # 深度验证
    if ! verify_install; then
        echo ""
        echo "❌ 安装验证失败。可能原因："
        echo "   1. npm 提取原生二进制包不完整（Node v25 已知问题）"
        echo "   2. 建议降级到 Node 22 LTS: brew install node@22"
        echo ""
        echo "   可以重试: ~/claude/upgrade-claude.sh"
        exit 1
    fi

    verify
    sync_to_github "$REMOTE_LATEST"
    cleanup
    summary
}

main "$@"
