#!/bin/bash
# Claude Code auto-update script (launchd 每日调度)
export PATH="$HOME/local/node-v22.14.0-darwin-arm64/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

LOG_FILE="$HOME/.claude/auto-update.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# ---- 1. 获取版本 ----
CURRENT=$(claude --version 2>/dev/null | awk '{print $1}') || true
LATEST=$(npm view @anthropic-ai/claude-code version 2>/dev/null) || true

# ---- 2. claude 未安装 — 尝试恢复 ----
if [ -z "$CURRENT" ]; then
    if [ -z "$LATEST" ]; then
        log "ERROR: claude not installed and cannot reach npm registry"
        exit 1
    fi
    log "WARN: claude not found, attempting install $LATEST..."
    if npm install -g @anthropic-ai/claude-code@latest >> "$LOG_FILE" 2>&1; then
        log "Installed $LATEST"
    else
        log "ERROR: install failed. Run manually: ~/claude/upgrade-claude.sh"
    fi
    exit 0
fi

# ---- 3. 无法获取远程版本 ----
if [ -z "$LATEST" ]; then
    log "WARN: cannot reach npm registry (current=$CURRENT), skipping check"
    exit 0
fi

# ---- 4. 升级判断 ----
if [ "$CURRENT" != "$LATEST" ]; then
    log "Update available: $CURRENT -> $LATEST. Installing..."
    if npm install -g @anthropic-ai/claude-code@latest >> "$LOG_FILE" 2>&1; then
        NEW_VERSION=$(claude --version 2>/dev/null | awk '{print $1}')
        log "Updated to $NEW_VERSION"
    else
        log "ERROR: upgrade failed. Run manually: ~/claude/upgrade-claude.sh"
    fi
else
    log "Already up to date ($CURRENT)"
fi
