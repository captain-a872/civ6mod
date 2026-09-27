# 技术调研 B：海拔地块属性持久化路径（Agent B）

> 调研范围：游戏本体 Lua 源码全量 Grep（Base + 全部 DLC），只读
> 结论：**GameCore Property 系统确定可用且随存档持久化；地图生成环境零先例，需实机验证；存在官方桥梁 `LuaEvents.NewGameInitialized` 兜底**

## 可用 API 清单

### GameCore Property 系统（确定持久化）

- `object:SetProperty(key, value)` / `object:GetProperty(key)`，适用于 Game / Player / Unit / **Plot** / City 任何有 `GetComponentID()` 的对象
- 地块级先例（PiratesScenario / BlackDeathScenario / CivRoyaleScenario）：
  - `treasurePlot:SetProperty(...)`、`plot:GetProperty("Plague")` 等 118+ 处
  - UI 侧读取先例：PlotToolTip / MinimapPanel 替换脚本
- 持久化证据：官方注释 "State for the overall mod is kept as a property on the Game object"（BlackDeathScenario_StateUtils.lua）；黑死病/大逃杀/海盗场景依赖它读档恢复全场状态
- value 限制：仅可序列化标量/表（无函数引用）——海拔用 number 合规
- UI 侧写入需经 `UI.RequestPlayerOperation(..., PlayerOperations.EXECUTE_SCRIPT, ...)` 转发 GameCore

### 不存在的机制

- `SetScriptProperty`/`GetScriptProperty`：全库 0 匹配
- `GameInfo` 运行时写入：0 处（只读数据库）
- Stats/CityProperty 独立系统：不存在，City 数据统一走 Property 系统

## 地图生成环境特殊性

| 全局对象 | 调用次数 | 说明 |
|---|---|---|
| `Map.` | 856 | 地块访问 |
| `TerrainBuilder.` | 805 | 地形/地貌写入 |
| `GameInfo.` | 218 | 只读 |
| `Game.` / `GameEvents` / `ExposedMembers` | **0** | GameCore 属性系统在地图生成环境从未使用 |

**关键桥梁先例**：`LuaEvents.NewGameInitialized.Add(fn)` —— 地图脚本注册后，游戏开局（地图生成完成后）在 GameCore 上下文回调（EarthStandard.lua:5-13 官方用它开局加 Ley Lines）。证明"地图生成脚本 → 游戏开局"存在官方认可的执行延续通道。

## 推荐方案（双保险）

1. 自定义地图脚本中计算海拔 → 存模块级 Lua 表（生成期内使用）
2. 注册 `LuaEvents.NewGameInitialized`，开局回调把海拔表一次性写入 `Game:SetProperty("RR_ElevationMap", {...})`（确定持久化）
3. 实机验证：若生成态 Plot 支持 `plot:SetProperty("Elevation", meters)`（源码无先例），改为逐格写入更符合地块语义；不支持时 Game 级表完全等价

## 风险

1. **最大不确定**：生成态 Plot 是否绑定 SetProperty——源码零先例，需 10 分钟游戏内验证；NewGameInitialized 兜底
2. 读档不重跑地图生成脚本：只存 Lua 模块变量的数据读档必丢，必须走 Property
3. UI 侧只读不能直写（EXECUTE_SCRIPT 转发）
4. 联机/热座：Property 走 GameCore 序列化天然同步
5. key 命名：需前缀防冲突（官方 key 均为短字符串）
