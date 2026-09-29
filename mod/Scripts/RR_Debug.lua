------------------------------------------------------------------------------
--	FILE:	   RR_Debug.lua
--	PURPOSE: 调试工具（非发布内容）——开局全图探索，免去逐回合探图目验地形。
--	依据（官方先例）：
--	  AlexanderScenario.lua SetInitialVisibility / WarMachineScenario.lua L78
--	  均用 PlayersVisibility[id]:RevealAllPlots()（GameplayScript 上下文）；
--	  事件挂钩照 AlexanderScenario 的 Events.TurnBegin + 首回合判定。
--	注意：RevealAllPlots 只解除战争迷雾（全图变为"已探索"），单位视野
--	  照常工作；与 IGE 全图揭示同款副作用——立即触发全部自然奇观发现。
--	M6 性能整改：全图探索 9360~18144 格同时渲染，开局风扇即响（未过回合）。
--	  改为默认关闭——仅当本文件内开关 RR_DEBUG_REVEAL_ALL 手动置 true 才探索。
--	  不用 MapConfiguration 做运行时开关：建图期 SetValue 在本环境必失败
--	  （RR_PersistElevation M2 首测实证 0/5 块），GameplayScript 上下文
--	  同样无可靠读写通路，故保留文件内布尔开关（改后需重启游戏生效）。
------------------------------------------------------------------------------
local RR_DEBUG_REVEAL_ALL = false;	-- M6：默认 false（性能）。需要全图目验时手动改 true 并重启游戏

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
	if RR_DEBUG_REVEAL_ALL and not g_RR_RevealDone and Game.GetCurrentGameTurn() <= 2 then
		RR_RevealAllPlots();
		g_RR_RevealDone = true;
	end
end

Events.TurnBegin.Add(OnRRTurnBegin);
