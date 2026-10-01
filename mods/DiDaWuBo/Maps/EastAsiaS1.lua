------------------------------------------------------------------------------
-- FILE: EastAsiaS1.lua
-- 东亚-西太平洋 S1 实测图（120x78 编纂格网，数据内嵌）
-- 由 tools/s1_eastasia.py --export 生成，勿手改（改 Python 源）
-- S1 阶段只呈现：海陆二分（深海/浅海）、低地、克拉通台地丘陵。
-- 无山脉（S2）、无河流（S4）、无地貌与资源（S5/S2 矿物带）——刻意留白。
-- 测试便利：开局对全部主要文明 RevealAllPlots（冷战场景官方先例）。
------------------------------------------------------------------------------
include "MapEnums"
include "MapUtilities"
include "MountainsCliffs"
include "AssignStartingPlots"

EASTASIA_W = 120
EASTASIA_H = 78
EASTASIA_ROWS = {
        "OOOOOOOOOOOggggggggggggggggggggggggggggggggggggOOcgccccOOOOOOOOOOOOcOOOOOOOOgOOOOOOgOOOOOgOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOOOOOOOhggggggggggggggggggggggggggggggggggggggcccccccggggOOOOOOOOOOOOOOOOggOOOOOggOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOOOOOOOhggggggggggggggggggggggggggggggggggggggcccccggggggggOOOOOOOOOOOOOOOggOOOOgggOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOOOOOOhhggggggggggggggggggggggggggggggggggggggccccccggggggggOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOOOOOOhhggggggggggggggggggggggggggggggggggggggOOcccgggggggggOOOOOOOOOOOOOOOOOOgOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOOOOOhhhhgggggggggggggggggggggggggggggggggggggOOOcggggggggggccOOOOOOOOOOOOOOOOgOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOOOOOhhhhgggggggggggggggggggggggggggggggggggggggggggggggggggcgOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOOOOhhhhhgggggggggggggggggggggggggggggggggggggggggggggggggggccOOOOOOOOOOOOOOOggOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOOOOhhhhhgggggggggggggggggggggggggggggggggggggggggggggggggggccOOOOOOOOOOOOOOOggOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOOOhhhhhhggggggggggggggggggggggggggggggggggggggggggggggggggcccOOOOOOOOOOOOOOOggOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOOhhhhhhhggggggggggggggggggggggggggggggggggggggggggggggggggccccOOOOOOOOOOOOOcgggOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOOhhhhhhhhggggggggggggggggggggggggggggggggggggggggggggggggccccccOOOOOOOOOOOccOggOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOhhhhhhhhhggggggggggggggggggggggggggggggggggggggggggggggggcccccccOOOOOOOOOOcgOggOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOhhhhhhhhggggggggggggggggggggggggggggggggggggggggggggggggccccgcccccOOOOOOccgcgOgOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOhhhhhhhhgggggggggggggggggggggggggggggggggggggggggggggggcccgggccgccccgOccccgccOggOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOhhhhhhhgggggggggggggggggggggggggggggggggggggggggggggggccccggggcccccccgccccccgOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOhhhhhhhgggggggggggggggggggggggggggggggggggggggggggggggOcccgggcccccccccccccccccOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "OOOOhhhhhhggggggggggggggggggggggggggggggggggggggggggggggggOOOccgcgccccgcccccccccccOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "hOOOhhhhggggggggggggggggggggggggggggggggggggggggggggggggggOOOOccgcccccccgcccccccgcOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "gghhhhgggggggggggggggggggggggggggggggggggggggggggggggggggggOOOgggccccccccccccccccgOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggccccgccccccgcgOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggcccccccccggOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggccccccgggOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggcccccgggOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhggggggggOccOOggOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhhhhhhggggggOOOggOOOOggOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhhhhhhhhhggggOOOccOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhhhhhhhhhhhggggccccccOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhhhhhhhhhhhhhggOccccccOOOOOgOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhhhhhhhhhhhhhhggccccgcccOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhhhhhhhhhhhhhhggOcccccgccOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhhhhhhhhhhhhhhggccccgccccOOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhhhhhhhhhhhggggcgcccccccOOOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhhhhhhhhhgggggccccccccgccOOOOOOOOOOOOOOOOOOOOOOOOOO",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhhhhhggggggOcccccccccccOOOOOOOOOOOOOOOOOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghggggggggggggOccccggcccgccgOOOOOOOOOOOOOOOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggOOccccccccgccOOOOOOOOOOOOOOOOOOOOOOOO",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggOOOOcccccccccgggOOOOOOOOOOOOOOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggOOOOOOccccccgcgggOOOOOOOOOOOOOOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggOOOOOOOcgccccccgggOOOOOOOOOOOOOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggOOOOOOOOcgcccgOggOOOOOOOOOOOOOOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggOOOOOOOOOOOcOOOOOgOOggOOOOOOOOOOOOOOOOO",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggOccgOOOOOOOOOOOOOOOOOOOgOOOOOOOOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghgcccccOOOOOOggggOOOOOOOOOOOgggggOOOOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhcccgccOOOOggggOOOOOOOOOOOOOOgggOOOOOOOO",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhcccgcOOOgggggOOOOOOOOOOOOOOOgggOOOOOOO",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhggccgOOgggggOOOOOOOOOOOOOOOOgggOOOOOO",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhggccccOOgggggOOOOOOOOOOOOOOOOgggOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghggcccgOOggggggOOOOOOOOOOOOOOOOOggOOOOOO",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggcccccgcOgggggggOOOOOOOOOOOOOOOOOggOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggcccgccccccOgggggggOOOOOOOOOOOOOOOOOgggOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggccccccccggggggggOOOOOOOOOOOOOOOOOggOOOOOO",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggccccchhOgggggggOOOOOOOOOOOOOOOOOggOOOOOO",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhggggggOOOOOOOOOOOOOOOOOggOOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhggggggggOOOOOOOOOOOOOOOOgggOOOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggOOOOOOOOOOOOOOOgggggOOO",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggOOOOOOOOOOOOOOOgggggggg",
        "hhhgggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggOOOOOOOOOOOOOggggggg",
        "hhhhhhhhggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggOOOOOOOOOOOcgggggO",
        "hhhhhhhhhggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggOOOOOOOccccccgccc",
        "hhhhhhhhhggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggOOOcccccccccccc",
        "hhhhhhhhhgggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggcccccccccccccc",
        "hhhhhhhhhhgggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggccccccccccccc",
        "hhhhhhhhhgggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggcccccccgcccc",
        "hhhhhhhhgggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggccccgcgcccc",
        "hhhhhhhgggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggcccccgcccc",
        "hhhhhhhggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggccccggccc",
        "hggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggccccggccc",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggccggccc",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhggggggggggggggcccggccc",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhhhhhhhhhhgggggggcgcccc",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhhhhhhhhhhhhhhhhhhhgccgcccc",
        "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhhhhhhhhhhhhhhhhhhhhhhhhccgcccc",
        "ggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggghhhhhhhhhhhhhhhhhhhhhhhhhhhhhOccgcccc",
        "gggggggggggggggggggggggggggggggggggghhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhgggggghhhhhhhhhhhhhhhhhhhhhhhhhhhhhOOcchcccc",
        "ggggggggggggggggggggghhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhgggghhhhhhhhhhhhhhhhhhhhhhhhhhhhhhOOchcccc",
        "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhgghhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhOchcccc",
        "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhccccc"

}

------------------------------------------------------------------------------
function GenerateMap()
	print("EastAsiaS1: GenerateMap begin");

	local iW, iH = Map.GetGridSize();
	if iW ~= EASTASIA_W or iH ~= EASTASIA_H then
		print("EastAsiaS1: [WARN] grid " .. iW .. "x" .. iH ..
		      " != data " .. EASTASIA_W .. "x" .. EASTASIA_H ..
		      "; overflow plots filled with ocean. Pick map size 'East Asia Test 120x78'.");
	end

	local tOcean  = GetGameInfoIndex("Terrains", "TERRAIN_OCEAN");
	local tCoast  = GetGameInfoIndex("Terrains", "TERRAIN_COAST");
	local tGrass  = GetGameInfoIndex("Terrains", "TERRAIN_GRASS");
	local tGrassH = GetGameInfoIndex("Terrains", "TERRAIN_GRASS_HILLS");

	local plotTypes = {};
	local terrainTypes = {};

	for y = 0, iH - 1 do
		for x = 0, iW - 1 do
			local i = y * iW + x;
			local c = "O";
			if x < EASTASIA_W and y < EASTASIA_H then
				c = string.sub(EASTASIA_ROWS[y + 1], x + 1, x + 1);
			end
			if c == "O" then
				plotTypes[i] = g_PLOT_TYPE_OCEAN;
				terrainTypes[i] = tOcean;
			elseif c == "c" then
				plotTypes[i] = g_PLOT_TYPE_OCEAN;
				terrainTypes[i] = tCoast;
			elseif c == "h" then
				plotTypes[i] = g_PLOT_TYPE_HILLS;
				terrainTypes[i] = tGrassH;
			else
				plotTypes[i] = g_PLOT_TYPE_LAND;
				terrainTypes[i] = tGrass;
			end
			TerrainBuilder.SetTerrainType(Map.GetPlotByIndex(i), terrainTypes[i]);
		end
	end
	print("EastAsiaS1: terrain applied");
	AreaBuilder.Recalculate();

	-- 台地海岸海蚀崖（S1 唯一允许的"成形"工序）
	AddCliffs(plotTypes, terrainTypes);

	AreaBuilder.Recalculate();
	TerrainBuilder.AnalyzeChokepoints();
	TerrainBuilder.StampContinents();

	-- 出生点：S1 无河无资源，肥力评分天然均匀，阈值放低保证落位
	local startConfig = MapConfiguration.GetValue("start");
	local args = {
		MIN_MAJOR_CIV_FERTILITY = 80,
		MIN_MINOR_CIV_FERTILITY = 25,
		MIN_BARBARIAN_FERTILITY = 1,
		START_MIN_Y = 10,
		START_MAX_Y = 10,
		START_CONFIG = startConfig,
	};
	local start_plot_database = AssignStartingPlots.Create(args)

	local GoodyGen = AddGoodies(iW, iH);
	print("EastAsiaS1: GenerateMap done");
end

------------------------------------------------------------------------------
-- 开局后（GameCore 上下文）：全图揭示，方便测试看图
function InitializeNewGame()
	print("EastAsiaS1: NewGameInitialized - reveal all plots");
	local aPlayers = PlayerManager.GetAliveMajors();
	for _, pPlayer in ipairs(aPlayers) do
		local pVis = PlayersVisibility[pPlayer:GetID()];
		if (pVis ~= nil) then
			pVis:RevealAllPlots();
		end
	end
end
LuaEvents.NewGameInitialized.Add(InitializeNewGame);
