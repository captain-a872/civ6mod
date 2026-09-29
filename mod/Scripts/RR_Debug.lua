------------------------------------------------------------------------------
--	FILE:	   RR_Debug.lua
--	PURPOSE: 调试工具（非发布内容）——开局全图探索，免去逐回合探图目验地形。
--	依据（官方先例）：
--	  AlexanderScenario.lua SetInitialVisibility / WarMachineScenario.lua L78
--	  均用 PlayersVisibility[id]:RevealAllPlots()（GameplayScript 上下文）；
--	  事件挂钩照 AlexanderScenario 的 Events.TurnBegin + 首回合判定。
--	注意：RevealAllPlots 只解除战争迷雾（全图变为"已探索"），单位视野
--	  照常工作；与 IGE 全图揭示同款副作用——立即触发全部自然奇观发现。
--	M7 开关机制改版（取代 M6 的手改文件布尔开关）：
--	  开关 = 创建游戏 → 高级设置里的地图参数"开局全图探索"
--	  （Data/RR_Config.xml 向配置库 Parameters 表插行，照原版
--	  MapSettings.xml 的 temperature/雨量同机制：Key1="Map"
--	  Key2="RR_Continents.lua" 绑定本地图，Domain="bool" 渲染勾选框，
--	  ConfigurationGroup="Map" ConfigurationId="RR_RevealAll" 决定存键）。
--	  读取链路：勾选值随开局存入地图配置 → gameplay 阶段
--	  GameConfiguration.GetValue("RR_RevealAll") 读取（MapConfiguration
--	  作次级通路兜底），任何一步取不到都按关闭处理。
--	  既有教训（M2，RR_PersistElevation 首测实证）：建图期 MapConfiguration
--	  SetValue 在本环境必失败（0/5 块），GameplayScript 上下文亦无可靠
--	  写通路——所以只走"前端 UI 写配置 → gameplay 只读"的单向链路，
--	  脚本绝不回写配置。
------------------------------------------------------------------------------
local RR_REVEAL_ALL_KEY = "RR_RevealAll";	-- 与 RR_Config.xml 的 ConfigurationId 一致

-- M7：读取高级设置参数。pcall 双层兜底——配置库缺行、上下文差异、
-- 全局对象不存在等任何异常都按"关闭"处理（缺省关闭原则）。
local function RR_IsRevealAllEnabled()
	local ok, v = pcall(function()
		return GameConfiguration.GetValue(RR_REVEAL_ALL_KEY);
	end);
	if (not ok) or (v == nil) then
		ok, v = pcall(function()
			if (MapConfiguration ~= nil) then
				return MapConfiguration.GetValue(RR_REVEAL_ALL_KEY);
			end
			return nil;
		end);
	end
	return ok and (v == true or v == 1);
end

-- 配置在开局时定型，脚本加载时读一次即可（M6 性能顾虑保持不变：
-- 默认关闭，只有显式勾选才全图揭示）。
local RR_REVEAL_ALL = RR_IsRevealAllEnabled();
print("[RRMap DEBUG] 开局全图探索参数 = " .. tostring(RR_REVEAL_ALL));

local g_RR_RevealDone = false;

local function RR_RevealAllPlots()
	local aPlayers = PlayerManager.GetAliveMajors();
	for _, pPlayer in ipairs(aPlayers) do
		local pVis = PlayersVisibility[pPlayer:GetID()];
		if (pVis ~= nil) then
			pVis:RevealAllPlots();
		end
	end
	print("[RRMap DEBUG] 全图探索已开启（战争迷雾解除，视野照常）");
end

local function OnRRTurnBegin(playerID)
	-- 理由：TurnBegin 每个玩家每回合都触发，只在首个回合触发一次。
	-- 窗口放宽到回合 2——防御个别开局流程首回合事件早于脚本就绪的边界。
	-- 存档中途读取不重新触发（TurnBegin 只在回合推进时发）——调试够用。
	if RR_REVEAL_ALL and not g_RR_RevealDone and Game.GetCurrentGameTurn() <= 2 then
		RR_RevealAllPlots();
		g_RR_RevealDone = true;
	end
end

Events.TurnBegin.Add(OnRRTurnBegin);
