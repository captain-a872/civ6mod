# RRMap（地大物博·真实地理）—— M0 骨架

本目录是《文明6》Mod「地大物博·真实地理」的 M0 里程碑：一个游戏内可加载、可开局的自定义地图脚本 Mod。M0 完全复用原版 `Continents.lua` 生成流程，不实现任何 M1+ 功能（真实海拔、1:4 网格、河流分级均未触碰）。

## 目录结构

```
mod/
├── RRMap.modinfo          # Mod 身份证（GUID、组件声明、文件清单）
├── Data/
│   └── RR_Config.xml      # 向配置库 Maps 表注册地图脚本（出现在"地图类型"列表）
├── Maps/
│   └── RR_Continents.lua  # 地图生成脚本（对照官方 Continents.lua 流程）
├── Text/
│   └── RR_Text.xml        # 地图名称/描述中英文本地化
└── README.md              # 本文件
```

## 安装

把 `mod/` 目录（保持内部结构不变）整体复制到对应平台的 Mods 文件夹：

| 平台 | 路径 |
|------|------|
| **macOS（Aspyr 移植版，实测）** | `~/Library/Application Support/Sid Meier's Civilization VI/Sid Meier's Civilization VI/Mods/`（注意是**双层嵌套**，外层目录只有 Aspyr/Firaxis Games 子目录） |
| **Windows** | `C:\Users\<用户名>\Documents\My Games\Sid Meier's Civilization VI\Mods\` |

复制后形如 `.../Mods/mod/RRMap.modinfo`（外层文件夹名随意，可改成 `RRMap`）。开发期推荐用符号链接代替复制（改代码立即生效，无需重新拷贝）：

```bash
ln -s "/Users/lyg/Documents/Kimi/Workspaces/文明6/civ6mod/mod" \
  ~/Library/Application\ Support/Sid\ Meier\'s\ Civilization\ VI/Sid\ Meier\'s\ Civilization\ VI/Mods/RRMap
```

> 跨平台要点：所有 mod 文件为纯文本、UTF-8 编码、LF 换行、正斜杠路径，Mac/Windows 通用。

## 验证加载成功

1. 启动游戏，主菜单 → **额外内容（Additional Content）** → **模组（Mods）**，列表中应出现 **地大物博·真实地理（开发中）/ Real Geography (Dev)**，且已勾选启用。
2. 回到主菜单 → **创建游戏（Create Game）** → 地图类型（Map Type）下拉列表，应出现 **地大物博：大陆（开发中）/ Real Geography: Continents (Dev)**。
3. 选中该地图类型，任意标准尺寸开一局（单人、标准规则或迭起兴衰/风云变幻规则均可），能进入游戏即 M0 验收通过。

## 日志验收（Lua.log）

> **Mac 实测修正（2026-09-28，M0 验证）**：Aspyr 移植版**没有 Lua.log**，地图脚本里的 `print()` 不落任何日志；日志实际路径为
> `~/Library/Application Support/Sid Meier's Civilization VI/Firaxis Games/Sid Meier's Civilization VI/Logs/`
> （Mods/Saves 在双层嵌套目录，Logs 在外层 Firaxis Games 下，三处路径各不相同）。
> Mac 端验收替代方案：① `Modding.log` 查 "Map Script: RR_Continents.lua"（注册+选用）② `GameCore.log` 的 Pathfinder Allocation 行列数=网格实际尺寸（证明 GetMapInitData 生效）③ 游戏内直接观察。Windows 端仍可正常用 Lua.log。

开启一局后 Windows 查看 `Lua.log`，应能看到如下生成日志（按出现顺序）：

```
[RR] Generating RR Continents Map (M0 vanilla pipeline)
[RR] Generating Plot Types
[RR] Adding Features
[RR] Adding cliffs
[RR] Creating start plot database
[RR] Map generation done. Grid: 84x54
```

最后一行的格数随所选尺寸变化（决斗 44×26 … 巨大 106×66）。

### 日志位置

| 平台 | 路径 |
|------|------|
| **macOS（Aspyr 移植版，实测）** | `~/Library/Application Support/Sid Meier's Civilization VI/Sid Meier's Civilization VI/Logs/Lua.log` |
| **Windows** | `Documents\My Games\Sid Meier's Civilization VI\Logs\Lua.log` |

同目录下 `Database.log` 可排查注册问题（Maps 表行是否写入配置库）。

## 常见问题

- **模组列表里看不到 Mod**：检查 `mod/` 是否多嵌套了一层目录（应直接包含 `RRMap.modinfo`）；确认游戏已重启（模组列表只在启动时扫描）。
- **能看到 Mod 但地图类型列表没有新地图**：`Database.log` 中查 `Maps` 表相关报错；确认 `Data/RR_Config.xml` 与 `Text/RR_Text.xml` 在 `<Files>` 清单中且文件真实存在。
- **开局卡在"正在生成地图"**：多半是 `RR_Continents.lua` 运行报错，看 `Lua.log` 最后的错误栈；最常见原因是文件被改成非 UTF-8 编码导致中文注释乱码报错。
- **中文显示为方框/乱码**：文件必须以 UTF-8（无 BOM）保存，且保持 LF 换行。
- **与其他地图 Mod 冲突**：本 Mod 的文件名（`RR_Continents.lua`、`RR_*.xml`）带 RR 前缀，正常不会冲突；若整个地图类型列表异常，先停用其他地图类 Mod 排查。

## M0 边界声明

- 地图生成流程 = 官方 Continents.lua 原版流程（仅文件名、日志前缀、注释与 `GetMapInitData` 显式尺寸表为自定义）。
- `GetMapInitData` 返回各标准尺寸的原版格数，东西向环绕（WrapX=true），南北向不环绕。
- 不包含：海拔属性、8 种形态层、1:4 网格、河流分级、地带/群系卡、资源成片——这些属于 M1+ 里程碑（见仓库 `docs/模块1-实现计划.md`）。

## 已知风险

- 脚本结构对齐**风云变幻（Gathering Storm, 2.0）**版官方 Continents.lua，使用了 `CoastalLowlands`、`AddVolcanos`、`MarkCoastalLowlands` 等风云变幻 API。若在无风云变幻的旧版游戏/规则下运行，这些 include 或函数调用可能报错——遇到时请回报运行环境。
