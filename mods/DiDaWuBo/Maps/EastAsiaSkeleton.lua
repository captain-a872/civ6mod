------------------------------------------------------------------------------
--	FILE:	 EastAsiaSkeleton.lua
--	PURPOSE: 骨架自检图（二分对照试验用）——最小生成路径：全图平原+边缘海洋。
--	判定逻辑：
--	  本图能开局  → 注册/环境层完好，东亚S1图的崩点在生成逻辑内，逐段二分；
--	  本图也报错  → 问题在 mod 环境/注册层，与生成内容无关。
--	只调用 Continents.lua 实证过的 API 子集，无任何自造机制。
------------------------------------------------------------------------------
include "MapEnums"
include "MapUtilities"
include "AssignStartingPlots"

function GenerateMap()
	print("Skeleton: GenerateMap begin");
	local iW, iH = Map.GetGridSize();
	local tGrass = GetGameInfoIndex("Terrains", "TERRAIN_GRASS");
	local tOcean = GetGameInfoIndex("Terrains", "TERRAIN_OCEAN");

	for y = 0, iH - 1 do
		for x = 0, iW - 1 do
			local pPlot = Map.GetPlotByIndex(y * iW + x);
			if (x < 3 or y < 3 or x >= iW - 3 or y >= iH - 3) then
				TerrainBuilder.SetTerrainType(pPlot, tOcean);
			else
				TerrainBuilder.SetTerrainType(pPlot, tGrass);
			end
		end
	end

	AreaBuilder.Recalculate();
	TerrainBuilder.AnalyzeChokepoints();
	TerrainBuilder.StampContinents();

	local args = {
		MIN_MAJOR_CIV_FERTILITY = 50,
		MIN_MINOR_CIV_FERTILITY = 20,
		MIN_BARBARIAN_FERTILITY = 1,
		START_MIN_Y = 10,
		START_MAX_Y = 10,
		START_CONFIG = MapConfiguration.GetValue("start"),
	};
	AssignStartingPlots.Create(args);
	print("Skeleton: GenerateMap done");
end
