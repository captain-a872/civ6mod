------------------------------------------------------------------------------
--	FILE:	   DiDaWuBo_Debug.lua
--	PURPOSE:   调试工具（非发布内容）——开局全图探索，免去逐回合探图目验地形。
--	结构沿用旧版 RR_Debug.lua（M7 实证版）：
--	  开关 = 创建游戏 → 高级设置 → 「开局全图探索」（配置库 Parameters 行，
--	  Key2 绑定 EastAsiaS1.lua，Domain="bool" 渲染勾选框，存键 EASTASIA_RevealAll）。
--	  读取链路：勾选值随开局存入地图配置 → gameplay 阶段
--	  GameConfiguration.GetValue 读取（MapConfiguration 次级兜底），
--	  pcall 双层兜底，任何一步取不到都按关闭处理（缺省关闭原则）。
--	  揭示用 PlayersVisibility[id]:RevealAllPlots()（AlexanderScenario /
--	  WarMachineScenario / ColdWarScenario 官方先例），只解除战争迷雾，
--	  单位视野照常；副作用同 IGE——立即触发全部自然奇观发现。
------------------------------------------------------------------------------
local REVEAL_ALL_KEY = "EASTASIA_RevealAll";	-- 与 Config/EastAsiaS1_MapsConfig.xml 的 ConfigurationId 一致

-- 文件日志（自搭抓取）：io 可用时同步写工作区日志文件，pcall 兜底
local DEBUG_LOG = "/Users/lyg/Documents/Kimi/Workspaces/文明6/civ6mod/logs/didawubo-debug.log";
local function DLog(msg)
	msg = tostring(msg);
	print(msg);
	local ok, fh = pcall(io.open, DEBUG_LOG, "a");
	if ok and fh ~= nil then
		fh:write(msg .. "\n");
		fh:close();
	end
end

local function IsRevealAllEnabled()
	local ok, v = pcall(function()
		return GameConfiguration.GetValue(REVEAL_ALL_KEY);
	end);
	if (not ok) or (v == nil) then
		ok, v = pcall(function()
			if (MapConfiguration ~= nil) then
				return MapConfiguration.GetValue(REVEAL_ALL_KEY);
			end
			return nil;
		end);
	end
	return ok and (v == true or v == 1);
end

-- 配置在开局时定型，脚本加载时读一次即可
local REVEAL_ALL = IsRevealAllEnabled();
DLog("[DiDaWuBo] reveal-all param = " .. tostring(REVEAL_ALL));

local g_RevealDone = false;

local function RevealAllPlots()
	local aPlayers = PlayerManager.GetAliveMajors();
	for _, pPlayer in ipairs(aPlayers) do
		local pVis = PlayersVisibility[pPlayer:GetID()];
		if (pVis ~= nil) then
			pVis:RevealAllPlots();
		end
	end
	DLog("[DiDaWuBo] map revealed (fog lifted, unit sight unchanged)");
end

local function OnTurnBegin(playerID)
	-- TurnBegin 每个玩家每回合都触发，只在首回合执行一次；
	-- 窗口放宽到回合 2，防御开局流程首回合事件早于脚本就绪的边界。
	if REVEAL_ALL and not g_RevealDone and Game.GetCurrentGameTurn() <= 2 then
		RevealAllPlots();
		g_RevealDone = true;
	end
end

Events.TurnBegin.Add(OnTurnBegin);
DLog("[DiDaWuBo] debug script loaded");
