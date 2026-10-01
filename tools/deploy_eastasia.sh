#!/bin/bash
# 部署 EastAsiaS1 测试 mod 到游戏 Mods 目录
# 用 rsync 实体复制——Aspyr macOS 端口下符号链接不可靠（实证教训）
set -e
SRC="$(cd "$(dirname "$0")/../mods/EastAsiaS1" && pwd)/"
DST="$HOME/Library/Application Support/Sid Meier's Civilization VI/Sid Meier's Civilization VI/Mods/EastAsiaS1/"
mkdir -p "$DST"
rsync -a --delete "$SRC" "$DST"
echo "已部署: $DST"
ls -la "$DST"
