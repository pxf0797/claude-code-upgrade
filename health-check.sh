#!/bin/bash
# Claude Code 健康检查
# 用法: bash ~/claude/health-check.sh
# cron: 0 9 * * 1 ~/claude/health-check.sh

BIN="/opt/homebrew/bin/claude"
NPM_PKG="/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code"

echo "=== Claude Code 健康检查 $(date) ==="

# 运行验证
bash ~/claude/upgrade-claude.sh --verify-only 2>/dev/null || {
    echo "⚠️  健康检查未通过，尝试自动修复..."
    bash ~/claude/upgrade-claude.sh --quiet
}

echo ""
