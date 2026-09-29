#!/bin/sh
# 理由：游戏 ArtDefProvider 不跟随符号链接进子目录扫描，开发目录必须用
# 真实文件夹部署。每次提交后同步 civ6mod/mod → 游戏 Mods/RRMap。
SRC="/Users/lyg/Documents/Kimi/Workspaces/文明6/civ6mod/mod"
DST="$HOME/Library/Application Support/Sid Meier's Civilization VI/Sid Meier's Civilization VI/Mods/RRMap"
[ -L "$DST" ] && rm "$DST"
mkdir -p "$DST"
rsync -a --delete "$SRC/" "$DST/"
echo "synced: $DST"
