------------------------------------------------------------------------------
-- 文件:    RR_Continents.lua
-- 项目:    地大物博·真实地理（RRMap）—— M1 海拔与形态层里程碑
-- 基线说明: 本文件以游戏内置 Expansion2（风云变幻）Continents.lua 的逐字节
--          副本为基线（M0 排障结论，见 docs/模块1-实现计划.md 风险登记）。
--          M1 改动（每处 diff 均有"理由"注释，可用原版 Continents.lua 做 diff 审查）：
--            T1 GenerateMap 全程阶段探针 [RRMap M1]（os.clock 计时）
--            T2 确定性连续海拔场（米）→ MapConfiguration 分块持久化（双保险：纯种子可重算）
--            T3 形态层 8 类分类 + 山麓带落地（邻山平地强制丘陵，照官方 Tilted_Axis 写法）
--            T4 自定义 1:4 尺寸（MAPSIZE_RR_STD14，168×108）配套查询兜底
--            M2  水文分级：河面（TERRAIN_RR_RIVER）+ 急流/漫滩/三角洲标记
--            M2.5 Layer3 微地貌特征卡（三角洲/急流/漫滩 + 绿洲/沼泽原版直放）
--            M3  形态×地带具名矩阵地形卡：RR_ApplyTerrainMatrix（14 卡，壳等价，
--                惰性解析回落原版壳，见 Data/RR_Terrains_Matrix.xml）
--          原版版权: Copyright (c) 2014 Firaxis Games, Inc. All rights reserved.
------------------------------------------------------------------------------
------------------------------------------------------------------------------
--	FILE:	 Continents.lua
--	AUTHOR:  
--	PURPOSE: Base game script - Produces widely varied continents.
------------------------------------------------------------------------------
--	Copyright (c) 2014 Firaxis Games, Inc. All rights reserved.
------------------------------------------------------------------------------

include "MapEnums"
include "MapUtilities"
include "MountainsCliffs"
include "RiversLakes"
include "FeatureGenerator"
include "TerrainGenerator"
include "NaturalWonderGenerator"
include "ResourceGenerator"
include "CoastalLowlands"
include "AssignStartingPlots"

local g_iW, g_iH;
local g_iFlags = {};
local g_continentsFrac = nil;
local featureGen = nil;
local world_age_new = 5;
local world_age_normal = 3;
local world_age_old = 2;

-- RR M1 T2：海拔场所需的捕获量。
-- 理由：海平面阈值 water_percent / 分形阈值 iWaterThreshold 在 GeneratePlotTypes
-- 内部算出（局部变量），海拔场需要复用同一阈值才能与海陆结果严格一致；在此处
-- 捕获不消耗任何随机数流（避免扰动原版生成结果的可复现性——调研 A 报告 4.5：
-- 改动随机调用顺序会破坏同种子复现）。
local g_RR_waterPercent = nil;		-- 海平面百分比（1-100），GeneratePlotTypes 捕获
local g_RR_waterThreshold = nil;	-- 最终分形海平面阈值（分形高度单位），GeneratePlotTypes 捕获
local g_RR_elevation = nil;			-- 海拔表：[y*g_iW+x+1] = 米（Lua 1-based），T2 生成
local g_RR_form = nil;				-- 形态表：[y*g_iW+x+1] = 形态名（策划案 1.2 的 8 类），T2/T3 生成

-- RR M6 海洋分级阈值（实测调参）：
-- 理由：旧值 深海≤-2000 / 浅海 -2000~-200（策划案 1.2 原始分界）在 168×108
-- 实图上导致海岸+浅海占比过大、深海隔不开大陆（用户实测反馈）。新值把深海
-- 分界抬到 -800、浅海上限收到 -100——大陆之间呈深蓝，近岸只留一小圈浅色。
-- 海拔公式振幅（-25~-5825m）未动，只改分类阈值；陆侧阈值（200/500/3500）不变。
-- 诚实标注：本地无法实机验证比例，新图请以 "[RRMap M1] 海洋分级阈值" 与
-- "形态分布" 两条探针 + 3D 观感复核；不满意只改这两个常量即可。
local RR_SEA_DEEP_ELEV = -800;			-- 深海分界（旧值 -2000）
local RR_SEA_SHALLOW_MAX_ELEV = -100;	-- 浅海上限（旧值 -200）；>-100 的离岸浅水归海岸观感

-- RR M2 水文分级：参数与状态。
-- 理由（取值）：168×108（1:4 精细度）下的初始梯度，策划案 2.3"数值为默认倾向，
-- 数值框架阶段统一调参"；分级用流域连通块尺寸（支流并入干流，天然契合流域概念）。
local RR_RIVER_MIN_SIZE_R2 = 8;		-- 连通河段 ≥8 格且通海 → 大河 R2（水面 1 格宽）
local RR_RIVER_MIN_SIZE_R3 = 16;	-- ≥16 → R3（入海口段向两侧拓宽）
local RR_RIVER_MIN_SIZE_R4 = 28;	-- ≥28 → R4（亚马逊级，拓宽距离更长）
local RR_RIVER_WATER_ELEV = 300;	-- 河道格原海拔 <300m 才可转为水面（下游平原段）
									-- ≥300m 的上游段保持边缘河并标急流（策划案：
									-- 瀑布/急流宿主=河道且高程突变，纯功能标记）
local RR_RIVER_WIDEN_ELEV = 50;		-- 拓宽候选邻格原海拔须 <50m（真低地，防淹丘陵）
local RR_RIVER_WIDEN_DIST_R3 = 2;	-- R3：距河口 BFS 距离 ≤2 的河道格才触发拓宽
local RR_RIVER_WIDEN_DIST_R4 = 4;	-- R4：≤4
-- 理由（M2 首测数据修正）：并集近似会把多条河并成超大流域（首测单块 247 格），
-- 若不限制，中上游全被转成水面（首测河道 1923 格=全图 10%）。加"距河口 BFS
-- 距离"上限——只把下游一段转为水面，中上游保持边缘河（正是策划案
-- "上游急流段/下游水面段"的表达）。
local RR_RIVER_CHANNEL_DIST_R2 = 10;	-- R2：距河口 ≤10 格的河道转水面
local RR_RIVER_CHANNEL_DIST_R3 = 16;	-- R3：≤16
local RR_RIVER_CHANNEL_DIST_R4 = 24;	-- R4：≤24（亚马逊级干流的下游水面段）
local RR_MARK_RAPIDS = 1;			-- g_RR_riverMark 位：急流/瀑布
local RR_MARK_FLOODPLAIN = 2;		-- 位：河漫滩
local RR_MARK_DELTA = 4;			-- 位：三角洲
local g_RR_river = nil;				-- 河流等级表：[y*g_iW+x+1] = 0 无 / 1 R1 / 2 R2 / 3 R3 / 4 R4
local g_RR_riverMark = nil;			-- 水文标记表：位组合（RR_MARK_*）

local function RR_Clock()
	-- 理由（T1）：防御——若地图生成沙盒裁剪了 os 库，探针退化为 0 值计时而非崩溃。
	if os ~= nil and os.clock ~= nil then
		return os.clock();
	else
		return 0;
	end
end

local function RR_Probe(stageName, sinceClock)
	-- 理由（T1）：阶段探针统一出口。带版本前缀 "[RRMap M1]"，供 tuner 日志
	-- grep 定位中止点（tools/README.md 流程）；string.format 防 nil 拼接崩溃。
	local now = RR_Clock();
	print(string.format("[RRMap M1] %s (%.2fs)", stageName, now - sinceClock));
	return now;
end

-------------------------------------------------------------------------------
function GenerateMap()
	print("Generating Continents Map");
	local pPlot;

	-- Set globals
	g_iW, g_iH = Map.GetGridSize();
	g_iFlags = TerrainBuilder.GetFractalFlags();
	-- 理由（T1）：开始探针。打印网格尺寸与尺寸类型，是 tuner 日志里本脚本
	-- 存活的第一证据（没有这一行 = 脚本没被加载，按 SKILL 第三节 SOP 先查注册链路）。
	local rrStartClock = RR_Clock();
	local rrStageClock = RR_Probe(string.format("开始 %dx%d size=%s", g_iW, g_iH, tostring(Map.GetMapSize())), rrStartClock);
	local temperature = MapConfiguration.GetValue("temperature"); -- Default setting is Temperate.
	if temperature == 4 then
		temperature  =  1 + TerrainBuilder.GetRandomNumber(3, "Random Temperature- Lua");
	end
	
	--	local world_age
	local world_age = MapConfiguration.GetValue("world_age");
	if (world_age == 1) then
		world_age = world_age_new;
	elseif (world_age == 2) then
		world_age = world_age_normal;
	elseif (world_age == 3) then
		world_age = world_age_old;
	else
		world_age = 2 + TerrainBuilder.GetRandomNumber(4, "Random World Age - Lua");
	end

	plotTypes = GeneratePlotTypes(world_age);
	-- 理由（T1）：分形海陆阶段探针（含 ApplyTectonics/孤立山在内的全部 plot 类型定稿）。
	rrStageClock = RR_Probe("分形海陆", rrStageClock);
	terrainTypes = GenerateTerrainTypes(plotTypes, g_iW, g_iH, g_iFlags, false, temperature);
	ApplyBaseTerrain(plotTypes, terrainTypes, g_iW, g_iH);

	AreaBuilder.Recalculate();
	TerrainBuilder.AnalyzeChokepoints();
	TerrainBuilder.StampContinents();

	local iContinentBoundaryPlots = GetContinentBoundaryPlotCount(g_iW, g_iH);
	local biggest_area = Areas.FindBiggestArea(false);
	print("After Adding Hills: ", biggest_area:GetPlotCount());
	AddTerrainFromContinents(plotTypes, terrainTypes, world_age, g_iW, g_iH, iContinentBoundaryPlots);

	AreaBuilder.Recalculate();
	rrStageClock = RR_Probe("地形", rrStageClock);

	-- RR M1 T2/T3：海拔场 + 形态层 + 山麓带。
	-- 理由（插入点）：此时 plot 类型与地形均已定稿（AddTerrainFromContinents 之后），
	-- 且仍在 AddRivers 之前——满足原版不变量"河流发源于高地，丘陵/山地布局须在
	-- 河流前定稿"（调研 A 报告 M1 节），山麓带改动才能被河流/特征/资源全程看到。
	RR_BuildElevationAndForms();
	RR_ApplyFoothills();
	RR_ApplySnowRidge();
	RR_PersistElevation();
	RR_PrintElevationSamples();
	rrStageClock = RR_Probe("海拔/形态层", rrStageClock);

	-- River generation is affected by plot types, originating from highlands and preferring to traverse lowlands.
	AddRivers();
	rrStageClock = RR_Probe("河流", rrStageClock);
	
	-- Lakes would interfere with rivers, causing them to stop and not reach the ocean, if placed any sooner.
	-- 理由（T4 兜底）：自定义尺寸（MAPSIZE_RR_*）在 GameInfo.Maps 的行若匹配失败
	-- （row 为 nil，即 SKILL 所述 Hash 匹配失败坑的同类风险），回落到标准尺寸的默认值，
	-- 避免 nil 解引用崩溃；标准尺寸行存在时行为与原版逐字节一致。
	local rrMapRow = GameInfo.Maps[Map.GetMapSize()];
	local numLargeLakes = 4;
	if rrMapRow ~= nil and rrMapRow.Continents ~= nil and rrMapRow.Continents > 0 then
		numLargeLakes = rrMapRow.Continents;
	end
	AddLakes(numLargeLakes);
	rrStageClock = RR_Probe("湖泊", rrStageClock);

	-- RR M2 T4：水文分级（小河=边缘属性保留 / 大河=水面）+ 急流·河漫滩·三角洲标记。
	-- 理由（插入点）：AddRivers/AddLakes 之后、AddFeatures 之前——河道已存在，
	-- 转为水面的格子会被特征/资源生成器按水格对待（水产资源可入河），
	-- 陆改水机制照 AddLakes 先例（SetTerrainType COAST + AreaBuilder.Recalculate）。
	RR_ClassifyAndConvertRivers(plotTypes, terrainTypes);
	rrStageClock = RR_Probe("大河分级", rrStageClock);

	-- RR M2.5 Layer3：把分级阶段的三角洲/急流标记转成真实特征卡。
	-- 理由（插入点）：大河分级写标记 → 特征卡落地 → AddFeatures——
	-- 先占位后原版生成器会跳过这些格子，保证标记不被官方特征覆盖。
	RR_PlaceLayer3Features();
	rrStageClock = RR_Probe("Layer3特征", rrStageClock);

	-- RR M3：形态×地带具名矩阵地形卡落地。
	-- 理由（插入点）：Layer3 特征直放（绿洲/沼泽判定读原版地形 ID）之后、
	-- AddFeatures 之前——原版特征生成器随后按 Feature_ValidTerrains
	-- （已复制到矩阵地形）在矩阵卡上正常生林/雨林，资源生成同理。
	RR_ApplyTerrainMatrix();
	rrStageClock = RR_Probe("矩阵地形", rrStageClock);

	AddFeatures();
	TerrainBuilder.AnalyzeChokepoints();
	
	print("Adding cliffs");
	AddCliffs(plotTypes, terrainTypes);
	rrStageClock = RR_Probe("崖岸", rrStageClock);

	-- 理由（T1）：基线 Continents.lua 没有独立火山阶段（GS 火山由特征生成器统一处理，
	-- 对照 BBS 版 L125 的 AddVolcanos 才知差异），此处打印说明性探针避免 tuner 日志
	-- 出现"阶段缺失=中止"的误读。
	rrStageClock = RR_Probe("火山(跳过:基线无独立火山阶段)", rrStageClock);

	-- 理由（T4 兜底）：同 numLargeLakes，自定义尺寸行匹配失败时回落标准值 5。
	local rrNumNW = 5;
	if rrMapRow ~= nil and rrMapRow.NumNaturalWonders ~= nil and rrMapRow.NumNaturalWonders > 0 then
		rrNumNW = rrMapRow.NumNaturalWonders;
	end
	local args = {
		numberToPlace = rrNumNW,
	};
	local nwGen = NaturalWonderGenerator.Create(args);

	AddFeaturesFromContinents();
	MarkCoastalLowlands();
	rrStageClock = RR_Probe("特征", rrStageClock);
	
	resourcesConfig = MapConfiguration.GetValue("resources");
	local startConfig = MapConfiguration.GetValue("start");-- Get the start config
	local args = {
		resources = resourcesConfig,
		START_CONFIG = startConfig,
	};
	local resGen = ResourceGenerator.Create(args);
	rrStageClock = RR_Probe("资源", rrStageClock);

	print("Creating start plot database.");
	
	-- START_MIN_Y and START_MAX_Y is the percent of the map ignored for major civs' starting positions.
	local args = {
		MIN_MAJOR_CIV_FERTILITY = 150,
		MIN_MINOR_CIV_FERTILITY = 50, 
		MIN_BARBARIAN_FERTILITY = 1,
		START_MIN_Y = 15,
		START_MAX_Y = 15,
		START_CONFIG = startConfig,
	};
	local start_plot_database = AssignStartingPlots.Create(args)
	rrStageClock = RR_Probe("出生点", rrStageClock);

	local GoodyGen = AddGoodies(g_iW, g_iH);
	-- 理由（T1/T4）：完成探针，打印生成总耗时（T4 性能冒烟数据源，无硬阈值，先拿数据）
	-- 与形态分布计数（T3 肉眼可见性的事后核对）。
	RR_Probe(string.format("完成 总耗时=%.2fs", RR_Clock() - rrStartClock), rrStageClock);
	RR_PrintFormStats();
end

-------------------------------------------------------------------------------
function GeneratePlotTypes(world_age)
	print("Generating Plot Types");
	local plotTypes = {};

	local sea_level_low = 57;
	local sea_level_normal = 62;
	local sea_level_high = 66;

	local extra_mountains = 0;
	local grain_amount = 3;
	local adjust_plates = 1.0;
	local shift_plot_types = true;
	local tectonic_islands = false;
	local hills_ridge_flags = g_iFlags;
	local peaks_ridge_flags = g_iFlags;
	local has_center_rift = true;
	local water_percent;

	--	local sea_level
    	local sea_level = MapConfiguration.GetValue("sea_level");
	if sea_level == 1 then -- Low Sea Level
		water_percent = sea_level_low
	elseif sea_level == 2 then -- Normal Sea Level
		water_percent =sea_level_normal
	elseif sea_level == 3 then -- High Sea Level
		water_percent = sea_level_high
	else
		water_percent = TerrainBuilder.GetRandomNumber(sea_level_high - sea_level_low, "Random Sea Level - Lua") + sea_level_low  + 1;
	end
	-- 理由（T2）：捕获海平面百分比供海拔场复用同一阈值（不重复调用随机数，
	-- 避免扰动原版随机流顺序）。
	g_RR_waterPercent = water_percent;

	-- Set values for hills and mountains according to World Age chosen by user.
	local adjustment = world_age;
	if world_age <= world_age_old  then -- 5 Billion Years
		adjust_plates = adjust_plates * 0.75;
	elseif world_age >= world_age_new then -- 3 Billion Years
		adjust_plates = adjust_plates * 1.5;
	else -- 4 Billion Years
	end

	-- Generate continental fractal layer and examine the largest landmass. Reject
	-- the result until the largest landmass occupies 58% or less of the total land.
	local done = false;
	local iAttempts = 0;
	local iWaterThreshold, biggest_area, iNumTotalLandTiles, iNumBiggestAreaTiles, iBiggestID;
	while done == false do
		local grain_dice = TerrainBuilder.GetRandomNumber(7, "Continental Grain roll - LUA Continents");
		if grain_dice < 4 then
			grain_dice = 2;
		else
			grain_dice = 1;
		end
		local rift_dice = TerrainBuilder.GetRandomNumber(3, "Rift Grain roll - LUA Continents");
		if rift_dice < 1 then
			rift_dice = -1;
		end
		
		InitFractal{continent_grain = grain_dice, rift_grain = rift_dice};
		iWaterThreshold = g_continentsFrac:GetHeight(water_percent);
		local iBuffer = math.floor(g_iH/13.0);
		local iBuffer2 = math.floor(g_iH/13.0/2.0);

		iNumTotalLandTiles = 0;
		for x = 0, g_iW - 1 do
			for y = 0, g_iH - 1 do
				local i = y * g_iW + x;
				local val = g_continentsFrac:GetHeight(x, y);
				local pPlot = Map.GetPlotByIndex(i);

				if(y <= iBuffer or y >= g_iH - iBuffer - 1) then
					plotTypes[i] = g_PLOT_TYPE_OCEAN;
					TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_OCEAN);  -- temporary setting so can calculate areas
				else
					if(val >= iWaterThreshold) then
						if(y <= iBuffer + iBuffer2) then
							local iRandomRoll = y - iBuffer + 1;
							local iRandom = TerrainBuilder.GetRandomNumber(iRandomRoll, "Random Region Edges");
							if(iRandom == 0 and iRandomRoll > 0) then
								plotTypes[i] = g_PLOT_TYPE_LAND;
								TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_DESERT);  -- temporary setting so can calculate areas
								iNumTotalLandTiles = iNumTotalLandTiles + 1;
							else 
								plotTypes[i] = g_PLOT_TYPE_OCEAN;
								TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_OCEAN);  -- temporary setting so can calculate areas
							end
						elseif (y >= g_iH - iBuffer - iBuffer2 - 1) then
							local iRandomRoll = g_iH - y - iBuffer;
							local iRandom = TerrainBuilder.GetRandomNumber(iRandomRoll, "Random Region Edges");
							if(iRandom == 0 and iRandomRoll > 0) then
								plotTypes[i] = g_PLOT_TYPE_LAND;
								TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_DESERT);  -- temporary setting so can calculate areas
								iNumTotalLandTiles = iNumTotalLandTiles + 1;
							else
								plotTypes[i] = g_PLOT_TYPE_OCEAN;
								TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_OCEAN);  -- temporary setting so can calculate areas
							end
						else
							plotTypes[i] = g_PLOT_TYPE_LAND;
							TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_DESERT);  -- temporary setting so can calculate areas
							iNumTotalLandTiles = iNumTotalLandTiles + 1;
						end
					else
						plotTypes[i] = g_PLOT_TYPE_OCEAN;
						TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_OCEAN);  -- temporary setting so can calculate areas
					end
				end
			end
		end

		ShiftPlotTypes(plotTypes);
		GenerateCenterRift(plotTypes);

		AreaBuilder.Recalculate();
		local biggest_area = Areas.FindBiggestArea(false);
		iNumBiggestAreaTiles = biggest_area:GetPlotCount();
		
		-- Now test the biggest landmass to see if it is large enough.
		if iNumBiggestAreaTiles <= iNumTotalLandTiles * 0.64 then
			done = true;
			iBiggestID = biggest_area:GetID();
		end
		iAttempts = iAttempts + 1;
		
		-- Printout for debug use only
		-- print("-"); print("--- Continents landmass generation, Attempt#", iAttempts, "---");
		-- print("- This attempt successful: ", done);
		-- print("- Total Land Plots in world:", iNumTotalLandTiles);
		-- print("- Land Plots belonging to biggest landmass:", iNumBiggestAreaTiles);
		-- print("- Percentage of land belonging to biggest: ", 100 * iNumBiggestAreaTiles / iNumTotalLandTiles);
		-- print("- Continent Grain for this attempt: ", grain_dice);
		-- print("- Rift Grain for this attempt: ", rift_dice);
		-- print("- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -");
		-- print(".");
	end

	-- 理由（T2）：捕获最终生效的海陆分形阈值（最后一次尝试的 iWaterThreshold，
	-- 与最终 plotTypes 严格同阈值），供海拔场把分形高度换算为水深/陆高。
	g_RR_waterThreshold = iWaterThreshold;
	
	local args = {};
	args.world_age = world_age;
	args.iW = g_iW;
	args.iH = g_iH
	args.iFlags = g_iFlags;
	args.blendRidge = 10;
	args.blendFract = 5;
	args.extra_mountains = 5;
	mountainRatio = 8 + world_age * 3;
	plotTypes = ApplyTectonics(args, plotTypes);
	plotTypes = AddLonelyMountains(plotTypes, mountainRatio);

	return plotTypes;
end

function InitFractal(args)

	if(args == nil) then args = {}; end

	local continent_grain = args.continent_grain or 2;
	local rift_grain = args.rift_grain or -1; -- Default no rifts. Set grain to between 1 and 3 to add rifts. - Bob
	local invert_heights = args.invert_heights or false;
	local polar = args.polar or true;
	local ridge_flags = args.ridge_flags or g_iFlags;

	local fracFlags = {};
	
	if(invert_heights) then
		fracFlags.FRAC_INVERT_HEIGHTS = true;
	end
	
	if(polar) then
		fracFlags.FRAC_POLAR = true;
	end
	
	if(rift_grain > 0 and rift_grain < 4) then
		local riftsFrac = Fractal.Create(g_iW, g_iH, rift_grain, {}, 6, 5);
		g_continentsFrac = Fractal.CreateRifts(g_iW, g_iH, continent_grain, fracFlags, riftsFrac, 6, 5);
	else
		g_continentsFrac = Fractal.Create(g_iW, g_iH, continent_grain, fracFlags, 6, 5);	
	end

	-- Use Brian's tectonics method to weave ridgelines in to the continental fractal.
	-- Without fractal variation, the tectonics come out too regular.
	--
	--[[ "The principle of the RidgeBuilder code is a modified Voronoi diagram. I 
	added some minor randomness and the slope might be a little tricky. It was 
	intended as a 'whole world' modifier to the fractal class. You can modify 
	the number of plates, but that is about it." ]]-- Brian Wade - May 23, 2009
	--
	local MapSizeTypes = {};
	for row in GameInfo.Maps() do
		MapSizeTypes[row.MapSizeType] = row.PlateValue;
	end
	local sizekey = Map.GetMapSize();

	local numPlates = MapSizeTypes[sizekey] or 4

	-- Blend a bit of ridge into the fractal.
	-- This will do things like roughen the coastlines and build inland seas. - Brian

	g_continentsFrac:BuildRidges(numPlates, {}, 1, 2);
end

function AddFeatures()
	print("Adding Features");

	-- Get Rainfall setting input by user.
	local rainfall = MapConfiguration.GetValue("rainfall");
	if rainfall == 4 then
		rainfall = 1 + TerrainBuilder.GetRandomNumber(3, "Random Rainfall - Lua");
	end
	
	local args = {rainfall = rainfall}
	featuregen = FeatureGenerator.Create(args);
	featuregen:AddFeatures(true, true);  --second parameter is whether or not rivers start inland);
end

function AddFeaturesFromContinents()
	print("Adding Features from Continents");

	featuregen:AddFeaturesFromContinents();
end

function GenerateCenterRift(plotTypes)
	-- Causes a rift to break apart and separate any landmasses overlaying the map center.
	-- Rift runs south to north ala the Atlantic Ocean.
	-- Any land plots in the first or last map columns will be lost, overwritten.
	-- This rift function is hex-dependent. It would have to be adapted to work with squares tiles.
	-- Center rift not recommended for non-oceanic worlds or with continent grains higher than 2.
	-- 
	-- First determine the rift "lean". 0 = Starts west, leans east. 1 = Starts east, leans west.
	local riftLean = TerrainBuilder.GetRandomNumber(2, "FractalWorld Center Rift Lean - Lua");
	
	-- Set up tables recording the rift line and the edge plots to each side of the rift line.
	local riftLine = {};
	local westOfRift = {};
	local eastOfRift = {};
	-- Determine minimum and maximum length of line segments for each possible direction.
	local primaryMaxLength = math.max(1, math.floor(g_iH / 8));
	local secondaryMaxLength = math.max(1, math.floor(g_iH / 11));
	local tertiaryMaxLength = math.max(1, math.floor(g_iH / 14));
	
	-- Set rift line starting plot and direction.
	local startDistanceFromCenterColumn = math.floor(g_iH / 8);
	if riftLean == 0 then
		startDistanceFromCenterColumn = -(startDistanceFromCenterColumn);
	end
	local startX = math.floor(g_iW / 2) + startDistanceFromCenterColumn;
	local startY = 0;
	local startingDirection = DirectionTypes.DIRECTION_NORTHWEST;
	if riftLean == 0 then
		startingDirection = DirectionTypes.DIRECTION_NORTHEAST;
	end
	-- Set rift X boundary.
	local riftXBoundary = math.floor(g_iW / 2) - startDistanceFromCenterColumn;
	
	-- Rift line is defined by a series of line segments traveling in one of three directions.
	-- East-leaning lines move NE primarily, NW secondarily, and E tertiary.
	-- West-leaning lines move NW primarily, NE secondarily, and W tertiary.
	-- Any E or W segments cause a wider gap on that row, requiring independent storage of data regarding west or east of rift.
	--
	-- Key variables need to be defined here so they persist outside of the various loops that follow.
	-- This requires that the starting plot be processed outside of those loops.
	local currentDirection = startingDirection;
	local currentX = startX;
	local currentY = startY;
	table.insert(riftLine, {currentX, currentY});
	-- Record west and east of the rift for this row.
	local rowIndex = currentY + 1;
	westOfRift[rowIndex] = currentX - 1;
	eastOfRift[rowIndex] = currentX + 1;
	-- Set this rift plot as type Ocean.
	local plotIndex = currentX + 1; -- Lua arrays starting at 1 sure makes for a lot of extra work and chances for bugs.
	plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN; -- Tiles crossed by the rift all turn in to water.
	
	-- Generate the rift line.
	if riftLean == 0 then -- Leans east
		while currentY < g_iH - 1 do
			-- Generate a line segment
			local nextDirection = 0;

			if currentDirection == DirectionTypes.DIRECTION_EAST then
				local segmentLength = TerrainBuilder.GetRandomNumber(tertiaryMaxLength + 1, "FractalWorld Center Rift Segment Length - Lua");
				-- Choose next direction
				if currentX >= riftXBoundary then -- Gone as far east as allowed, must turn back west.
					nextDirection = DirectionTypes.DIRECTION_NORTHWEST;
				else
					local dice = TerrainBuilder.GetRandomNumber(3, "FractalWorld Center Rift Direction - Lua");
					if dice == 1 then
						nextDirection = DirectionTypes.DIRECTION_NORTHWEST;
					else
						nextDirection = DirectionTypes.DIRECTION_NORTHEAST;
					end
				end
				-- Process the line segment
				local plotsToDo = segmentLength;
				while plotsToDo > 0 do
					currentX = currentX + 1; -- Moving east, no change to Y.
					rowIndex = currentY;
					-- westOfRift[rowIndex] does not change.
					eastOfRift[rowIndex] = currentX + 1;
					plotIndex = currentY * g_iW + currentX + 1;
					plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
					plotsToDo = plotsToDo - 1;
				end

			elseif currentDirection == DirectionTypes.DIRECTION_NORTHWEST then
				local segmentLength = TerrainBuilder.GetRandomNumber(secondaryMaxLength + 1, "FractalWorld Center Rift Segment Length - Lua");
				-- Choose next direction
				if currentX >= riftXBoundary then -- Gone as far east as allowed, must turn back west.
					nextDirection = DirectionTypes.DIRECTION_NORTHWEST;
				else
					local dice = TerrainBuilder.GetRandomNumber(4, "FractalWorld Center Rift Direction - Lua");
					if dice == 2 then
						nextDirection = DirectionTypes.DIRECTION_EAST;
					else
						nextDirection = DirectionTypes.DIRECTION_NORTHEAST;
					end
				end
				-- Process the line segment
				local plotsToDo = segmentLength;
				while plotsToDo > 0 and currentY < g_iH - 1 do
					local nextPlot = Map.GetAdjacentPlot(currentX, currentY, currentDirection);
					currentX = nextPlot:GetX();
					currentY = currentY + 1;
					rowIndex = currentY;
					westOfRift[rowIndex] = currentX - 1;
					eastOfRift[rowIndex] = currentX + 1;
					plotIndex = currentY * g_iW + currentX + 1;
					plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
					plotsToDo = plotsToDo - 1;
				end
				
			else -- NORTHEAST
				local segmentLength = TerrainBuilder.GetRandomNumber(primaryMaxLength + 1, "FractalWorld Center Rift Segment Length - Lua");
				-- Choose next direction
				if currentX >= riftXBoundary then -- Gone as far east as allowed, must turn back west.
					nextDirection = DirectionTypes.DIRECTION_NORTHWEST;
				else
					local dice = TerrainBuilder.GetRandomNumber(2, "FractalWorld Center Rift Direction - Lua");
					if dice == 1 and currentY > g_iH * 0.28 then
						nextDirection = DirectionTypes.DIRECTION_EAST;
					else
						nextDirection = DirectionTypes.DIRECTION_NORTHWEST;
					end
				end
				-- Process the line segment
				local plotsToDo = segmentLength;
				while plotsToDo > 0 and currentY < g_iH - 1 do
					local nextPlot = Map.GetAdjacentPlot(currentX, currentY, currentDirection);
					currentX = nextPlot:GetX();
					currentY = currentY + 1;
					rowIndex = currentY;
					westOfRift[rowIndex] = currentX - 1;
					eastOfRift[rowIndex] = currentX + 1;
					plotIndex = currentY * g_iW + currentX + 1;
					plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
					plotsToDo = plotsToDo - 1;
				end
			end
			
			-- Line segment is done, set next direction.
			currentDirection = nextDirection;
		end

	else -- Leans west
		while currentY < g_iH - 1 do
			-- Generate a line segment
			local nextDirection = 0;

			if currentDirection == DirectionTypes.DIRECTION_WEST then
				local segmentLength = TerrainBuilder.GetRandomNumber(tertiaryMaxLength + 1, "FractalWorld Center Rift Segment Length - Lua");
				-- Choose next direction
				if currentX <= riftXBoundary then -- Gone as far west as allowed, must turn back east.
					nextDirection = DirectionTypes.DIRECTION_NORTHEAST;
				else
					local dice = TerrainBuilder.GetRandomNumber(3, "FractalWorld Center Rift Direction - Lua");
					if dice == 1 then
						nextDirection = DirectionTypes.DIRECTION_NORTHEAST;
					else
						nextDirection = DirectionTypes.DIRECTION_NORTHWEST;
					end
				end
				-- Process the line segment
				local plotsToDo = segmentLength;
				while plotsToDo > 0 do
					currentX = currentX - 1; -- Moving west, no change to Y.
					rowIndex = currentY;
					westOfRift[rowIndex] = currentX - 1;
					-- eastOfRift[rowIndex] does not change.
					plotIndex = currentY * g_iW + currentX + 1;
					plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
					plotsToDo = plotsToDo - 1;
				end

			elseif currentDirection == DirectionTypes.DIRECTION_NORTHEAST then
				local segmentLength = TerrainBuilder.GetRandomNumber(secondaryMaxLength + 1, "FractalWorld Center Rift Segment Length - Lua");
				-- Choose next direction
				if currentX <= riftXBoundary then -- Gone as far west as allowed, must turn back east.
					nextDirection = DirectionTypes.DIRECTION_NORTHEAST;
				else
					local dice = TerrainBuilder.GetRandomNumber(4, "FractalWorld Center Rift Direction - Lua");
					if dice == 2 then
						nextDirection = DirectionTypes.DIRECTION_WEST;
					else
						nextDirection = DirectionTypes.DIRECTION_NORTHWEST;
					end
				end
				-- Process the line segment
				local plotsToDo = segmentLength;
				while plotsToDo > 0 and currentY < g_iH - 1 do
					local nextPlot = Map.GetAdjacentPlot(currentX, currentY, currentDirection);
					currentX = nextPlot:GetX();
					currentY = currentY + 1;
					rowIndex = currentY;
					westOfRift[rowIndex] = currentX - 1;
					eastOfRift[rowIndex] = currentX + 1;
					plotIndex = currentY * g_iW + currentX + 1;
					plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
					plotsToDo = plotsToDo - 1;
				end
				
			else -- NORTHWEST
				local segmentLength = TerrainBuilder.GetRandomNumber(primaryMaxLength + 1, "FractalWorld Center Rift Segment Length - Lua");
				-- Choose next direction
				if currentX <= riftXBoundary then -- Gone as far west as allowed, must turn back east.
					nextDirection = DirectionTypes.DIRECTION_NORTHEAST;
				else
					local dice = TerrainBuilder.GetRandomNumber(2, "FractalWorld Center Rift Direction - Lua");
					if dice == 1 and currentY > g_iH * 0.28 then
						nextDirection = DirectionTypes.DIRECTION_WEST;
					else
						nextDirection = DirectionTypes.DIRECTION_NORTHEAST;
					end
				end
				-- Process the line segment
				local plotsToDo = segmentLength;
				while plotsToDo > 0 and currentY < g_iH - 1 do
					local nextPlot = Map.GetAdjacentPlot(currentX, currentY, currentDirection);
					currentX = nextPlot:GetX();
					currentY = currentY + 1;
					rowIndex = currentY;
					westOfRift[rowIndex] = currentX - 1;
					eastOfRift[rowIndex] = currentX + 1;
					plotIndex = currentY * g_iW + currentX + 1;
					plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
					plotsToDo = plotsToDo - 1;
				end
			end
			
			-- Line segment is done, set next direction.
			currentDirection = nextDirection;
		end
	end
	-- Process the final plot in the rift.
	westOfRift[g_iH] = currentX - 1;
	eastOfRift[g_iH] = currentX + 1;
	plotIndex = (g_iH - 1) * g_iW + currentX + 1;
	plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;

	-- Now force the rift to widen, causing land on either side of the rift to drift apart.
	local horizontalDrift = 3;
	local verticalDrift = 2;
	--
	if riftLean == 0 then
		-- Process Western side from top down.
		for y = g_iH - 1 - verticalDrift, 0, -1 do
			local thisRowX = westOfRift[y+1];
			for x = horizontalDrift, thisRowX do
				local sourcePlotIndex = y * g_iW + x + 1;
				local destPlotIndex = (y + verticalDrift) * g_iW + (x - horizontalDrift) + 1;
				plotTypes[destPlotIndex] = plotTypes[sourcePlotIndex]
			end
		end
		-- Process Eastern side from bottom up.
		for y = verticalDrift, g_iH - 1 do
			local thisRowX = eastOfRift[y+1];
			for x = thisRowX, g_iW - horizontalDrift - 1 do
				local sourcePlotIndex = y * g_iW + x + 1;
				local destPlotIndex = (y - verticalDrift) * g_iW + (x + horizontalDrift) + 1;
				plotTypes[destPlotIndex] = plotTypes[sourcePlotIndex]
			end
		end
		-- Clean up remainder of tiles (by turning them all to Ocean).
		-- Clean up bottom left.
		for y = 0, verticalDrift - 1 do
			local thisRowX = westOfRift[y+1];
			for x = 0, thisRowX do
				local plotIndex = y * g_iW + x + 1;
				plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
			end
		end
		-- Clean up top right.
		for y = g_iH - verticalDrift, g_iH - 1 do
			local thisRowX = eastOfRift[y+1];
			for x = thisRowX, g_iW - 1 do
				local plotIndex = y * g_iW + x + 1;
				plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
			end
		end
		-- Clean up the rift.
		for y = verticalDrift, g_iH - 1 - verticalDrift do
			local westX = westOfRift[y-verticalDrift+1] - horizontalDrift + 1;
			local eastX = eastOfRift[y+verticalDrift+1] + horizontalDrift - 1;
			for x = westX, eastX do
				local plotIndex = y * g_iW + x + 1;
				plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
			end
		end

	else -- riftLean = 1
		-- Process Western side from bottom up.
		for y = verticalDrift, g_iH - 1 do
			local thisRowX = westOfRift[y+1];
			for x = horizontalDrift, thisRowX do
				local sourcePlotIndex = y * g_iW + x + 1;
				local destPlotIndex = (y - verticalDrift) * g_iW + (x - horizontalDrift) + 1;
				plotTypes[destPlotIndex] = plotTypes[sourcePlotIndex]
			end
		end
		-- Process Eastern side from top down.
		for y = g_iH - 1 - verticalDrift, 0, -1 do
			local thisRowX = eastOfRift[y+1];
			for x = thisRowX, g_iW - horizontalDrift - 1 do
				local sourcePlotIndex = y * g_iW + x + 1;
				local destPlotIndex = (y + verticalDrift) * g_iW + (x + horizontalDrift) + 1;
				plotTypes[destPlotIndex] = plotTypes[sourcePlotIndex]
			end
		end
		-- Clean up remainder of tiles (by turning them all to Ocean).
		-- Clean up top left.
		for y = g_iH - verticalDrift, g_iH - 1 do
			local thisRowX = westOfRift[y+1];
			for x = 0, thisRowX do
				local plotIndex = y * g_iW + x + 1;
				plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
			end
		end
		-- Clean up bottom right.
		for y = 0, verticalDrift - 1 do
			local thisRowX = eastOfRift[y+1];
			for x = thisRowX, g_iW - 1 do
				local plotIndex = y * g_iW + x + 1;
				plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
			end
		end
		-- Clean up the rift.
		for y = verticalDrift, g_iH - 1 - verticalDrift do
			local westX = westOfRift[y+verticalDrift+1] - horizontalDrift + 1;
			local eastX = eastOfRift[y-verticalDrift+1] + horizontalDrift - 1;
			for x = westX, eastX do
				local plotIndex = y * g_iW + x + 1;
				plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
			end
		end
	end


end
-------------------------------------------------------------------------------
-- RR M1 海拔场与形态层（T2/T3 实现块）
--
-- 确定性论证（M1 纪律：双保险）：
--   本块全部函数是【纯函数】——只读取本局已生成的 g_continentsFrac 分形高度与
--   地块状态，不创建新 Fractal、不调用 GetRandomNumber。因此：
--     (a) 不扰动原版随机流/分形创建顺序 → 同种子下原版生成结果与基线逐格一致；
--     (b) 海拔场是"同种子地图状态"的确定函数 → 读档/重开可由种子精确重算。
--   MapConfiguration 持久化（RR_PersistElevation）是锦上添花的第一保险；
--   种子重算是第二保险。两者皆失败也不影响地图生成本身（全程 pcall 防御）。
-------------------------------------------------------------------------------

-- 海拔模型公式（T2，单位米）：
--   记 h = g_continentsFrac:GetHeight(x,y)（海陆分形原始高度），
--       thr = g_RR_waterThreshold（海平面阈值，GeneratePlotTypes 捕获）。
--   陆侧归一 u = clamp((h - thr) / thr, 0, 1)（海岸带 u≈0，分形高处 u→1）
--   水侧归一 d = clamp((thr - h) / thr, 0, 1)（海岸线 d=0，远洋 d→1）
--
--   平地（PLOT_TYPE_LAND）  elev =   5 + 180*u          →    5~185m（<200m 低地）
--     其中沿海平地（IsCoastalLand）额外压到 ≤50m（海岸≈0）
--   丘陵（PLOT_TYPE_HILLS）  elev = 120 + 360*u          →  120~480m（起伏带）
--   山地（PLOT_TYPE_MOUNTAIN）elev = 1500 + 2000*u       → 1500~3500m（策划案山地带）
--     主脊升级：u>0.92 或 ≥5 个邻格为山地（山体内部）→ elev = 3500 + 1000*u（>3500m）
--   海洋                     elev = -25 - 5800*d^1.3    →  -25m（岸）~-5825m（深海沟）
--     水深分级负值（M6 实测调参后）：海岸≈0、浅海 -800~-100、深海 ≤-800
--     （旧分界：浅海 -2000~-200、深海 ≤-2000——浅海带过宽，见常量区注释）
--
--   参数选取理由：振幅对齐策划案 1.2 陆侧阈值（200/500/3500）；海洋分级阈值
--   自策划案值（-200/-2000）调整为 -100/-800（M6 实测比例失衡调参，理由见
--   常量区注释），公式幂 1.3 不变。u 用 (h-thr)/thr 是因为陆侧分形高度典型
--   区间为 [thr, 2*thr]，归一后覆盖 0~1；海洋幂 1.3 让浅段（大陆架）过渡
--   更缓——分级观感现由分类阈值主导，幂值不再肩负重任。
--
-- 形态层 8 类（判定完备无空档；RR_ClassifyForm 实现）：
--   水：邻陆 → 海岸/水面（与大河可航行段共用的形态，M2 复用此格）；
--       否则 elev ≤ -800 → 深海；-800 < elev ≤ -100 → 浅海；
--       elev > -100（离岸极浅水）→ 海岸/水面观感（M6：不建卡，保持原版
--       COAST 壳，构成"近岸一小圈浅色"）。
--   陆：elev > 3500 → 主脊；500~3500 → 山地；200~500 → 山麓；
--       <200 且邻格最大高差 ≥50m → 隆起（岗地/丘陵）；否则 → 低地。
-------------------------------------------------------------------------------

function RR_CountMountainNeighbors(x, y)
	-- 理由（T2 主脊判定）：统计 6 邻格中 PLOT_TYPE_MOUNTAIN 的数量，
	-- 山体内部的格子升级为主脊（>3500m），山脉边缘保持 1500~3500m 山地。
	-- 理由（API 选型）：建图上下文的 plot userdata 不暴露 GetPlotType/SetPlotType
	-- （原版地图脚本中这两方法只出现在 allow_mountains_on_coast==false 的死分支，
	-- 活跃代码一律用 IsMountain/IsHills，见 TerrainGenerator.lua GetNumberAdjacentMountains；
	-- M1 首测 895 行 pPlot:GetPlotType() 报 function expected instead of nil 实证）。
	local count = 0;
	for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
		local pAdj = Map.GetAdjacentPlot(x, y, dir);
		if pAdj ~= nil and pAdj:IsMountain() then
			count = count + 1;
		end
	end
	return count;
end

function RR_HasAdjacentLand(x, y)
	-- 理由（T2 海岸/水面判定）：水格任一邻格为陆地即归"海岸/水面"。
	for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
		local pAdj = Map.GetAdjacentPlot(x, y, dir);
		if pAdj ~= nil and not pAdj:IsWater() then
			return true;
		end
	end
	return false;
end

function RR_MaxNeighborElevDiff(x, y)
	-- 理由（T2 隆起判定）：策划案 1.2"邻格高差≥50m"。只统计陆地邻格
	-- （水侧高差无地形意义）；邻格海拔尚未全表算出时跳过该邻格。
	local pPlot = Map.GetPlot(x, y);
	local selfElev = g_RR_elevation[y * g_iW + x + 1];
	local maxDiff = 0;
	for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
		local pAdj = Map.GetAdjacentPlot(x, y, dir);
		if pAdj ~= nil and not pAdj:IsWater() then
			local adjElev = g_RR_elevation[pAdj:GetY() * g_iW + pAdj:GetX() + 1];
			if adjElev ~= nil and selfElev ~= nil then
				local diff = math.abs(adjElev - selfElev);
				if diff > maxDiff then
					maxDiff = diff;
				end
			end
		end
	end
	return maxDiff;
end

function RR_ClassifyForm(elev, isWater, hasAdjacentLand, maxNeighborDiff)
	-- 理由（T2/T3）：策划案 1.2 形态层 8 类的完整判定。返回字符串键，
	-- 与 RR_PrintFormStats 的统计表一一对应。
	if isWater then
		if hasAdjacentLand then
			return "海岸/水面";
		elseif elev <= RR_SEA_DEEP_ELEV then
			return "深海";
		elseif elev <= RR_SEA_SHALLOW_MAX_ELEV then
			return "浅海";
		else
			-- 理由（M6 浅海上限落地）：>-100m 的离岸极浅水（不邻陆）归入
			-- 海岸观感——不建具名卡（RR_ApplyTerrainMatrix 无此形态分支，
			-- 保持原版 COAST 壳），正好构成"近岸一小圈浅色"的目标观感。
			return "海岸/水面";
		end
	end
	if elev > 3500 then
		return "主脊";
	elseif elev >= 500 then
		return "山地";
	elseif elev >= 200 then
		return "山麓";
	elseif maxNeighborDiff >= 50 then
		return "隆起";
	else
		return "低地";
	end
end

function RR_BuildElevationAndForms()
	-- 理由（T2）：插入点见 GenerateMap 注释（地形定稿后、河流前）。
	-- 全程无随机数消耗（确定性论证见本块头部）。
	if g_continentsFrac == nil or g_RR_waterThreshold == nil or g_RR_waterThreshold <= 0 then
		-- 理由：防御——阈值捕获失败时跳过海拔场（如未来从其他入口调用），
		-- 绝不允许海拔场反过来弄崩地图生成。
		print("[RRMap M1] WARNING: 海拔场跳过——分形阈值未捕获");
		return;
	end

	local thr = g_RR_waterThreshold;
	g_RR_elevation = {};
	g_RR_form = {};

	-- 第一遍：海拔。海洋与陆地分别用 d / u 归一化（公式见本块头部注释）。
	for y = 0, g_iH - 1 do
		for x = 0, g_iW - 1 do
			local i = y * g_iW + x + 1; -- Lua 1-based
			local pPlot = Map.GetPlot(x, y);
			local h = g_continentsFrac:GetHeight(x, y);
			local elev = 0;
			if pPlot:IsWater() then
				local d = (thr - h) / thr;
				if d < 0 then d = 0; elseif d > 1 then d = 1; end
				elev = -25 - 5800 * (d ^ 1.3);
			else
				local u = (h - thr) / thr;
				if u < 0 then u = 0; end
				if u > 1 then u = 1; end
				-- 理由（API 选型）：建图上下文用 IsMountain/IsHills 判定，不用
				-- GetPlotType（该方法在建图上下文未绑定，实证见
				-- RR_CountMountainNeighbors 头部注释）。
				if pPlot:IsMountain() then
					if u > 0.92 or RR_CountMountainNeighbors(x, y) >= 5 then
						elev = 3500 + 1000 * u; -- 主脊带
					else
						elev = 1500 + 2000 * u; -- 山地带
					end
				elseif pPlot:IsHills() then
					elev = 120 + 360 * u;
				else
					elev = 5 + 180 * u;
					if pPlot:IsCoastalLand() then
						-- 海岸≈0：沿海平地压到 50m 以下
						local cap = 30 + 20 * u;
						if elev > cap then
							elev = cap;
						end
					end
				end
			end
			g_RR_elevation[i] = elev;
		end
	end

	-- 第二遍：形态。需要全表海拔（邻格高差），故分两遍。
	local formCounts = {};
	for y = 0, g_iH - 1 do
		for x = 0, g_iW - 1 do
			local i = y * g_iW + x + 1;
			local pPlot = Map.GetPlot(x, y);
			local isWater = pPlot:IsWater();
			local hasLand = false;
			local maxDiff = 0;
			if isWater then
				hasLand = RR_HasAdjacentLand(x, y);
			else
				maxDiff = RR_MaxNeighborElevDiff(x, y);
			end
			local form = RR_ClassifyForm(g_RR_elevation[i], isWater, hasLand, maxDiff);
			g_RR_form[i] = form;
			formCounts[form] = (formCounts[form] or 0) + 1;
		end
	end

	-- 理由（T2）：形态分布一次性打印，tuner 日志里可立即核对 8 类是否完备无空档。
	-- 理由（M6）：分级阈值随分布一并打印——本地无法实机验证海洋比例，
	-- 新图以本条 + 下条的形态分布复核深海/浅海占比是否显著上升。
	print(string.format("[RRMap M1] 海洋分级阈值: 深海≤%dm, 浅海≤%dm（M6 实测调参，旧值 -2000/-200）",
		RR_SEA_DEEP_ELEV, RR_SEA_SHALLOW_MAX_ELEV));
	print("[RRMap M1] 形态分布: " .. RR_FormCountsToString(formCounts));
end

function RR_FormCountsToString(formCounts)
	-- 理由：统计表序列化，供探针打印；tostring 防 nil。
	local parts = {};
	local order = {"深海", "浅海", "海岸/水面", "低地", "隆起", "山麓", "山地", "主脊"};
	for _, form in ipairs(order) do
		table.insert(parts, form .. "=" .. tostring(formCounts[form] or 0));
	end
	return table.concat(parts, " ");
end

function RR_PrintFormStats()
	-- 理由（T3）：完成探针后打印山麓带改动后的最终形态分布，
	-- 与 Build 阶段的分布对比即可看出山麓带吞并了多少低地（调参数据源）。
	if g_RR_form == nil then
		return;
	end
	local formCounts = {};
	for i = 1, g_iW * g_iH do
		local form = g_RR_form[i];
		if form ~= nil then
			formCounts[form] = (formCounts[form] or 0) + 1;
		end
	end
	print("[RRMap M1] 形态分布(山麓落地后): " .. RR_FormCountsToString(formCounts));
end

function RR_ApplyFoothills()
	-- 理由（T3 最小可见改动）：把策划案"山麓带"落到原版枚举上——与山地相邻的
	-- 原版平地强制改为丘陵，使 主脊(>3500m)→山麓→低地 的过渡带在游戏中肉眼可见。
	-- 只动这一步：不改分形、不改山地本体、不重构流程。
	-- 理由（API 选型，M1 首测修正）：建图上下文 plot userdata 不暴露
	-- GetPlotType/SetPlotType（原版仅死分支引用；活跃代码用 IsMountain/IsHills/
	-- 地形变体），故平地判定用 not IsHills and not IsMountain，丘陵提交用
	-- ApplyBaseTerrain 同款机制——基础地形 + g_TERRAIN_BASE_TO_HILLS_DELTA(=1)
	-- 写回（MapEnums 定义，GRASS+1=GRASS_HILLS 等五对）。循环结束后统一
	-- AreaBuilder.Recalculate()（官方注释同款做法）。
	if g_RR_form == nil or g_RR_elevation == nil then
		print("[RRMap M1] WARNING: 山麓带跳过——形态层未生成");
		return;
	end

	local converted = 0;
	local delayed = 0;
	for y = 0, g_iH - 1 do
		for x = 0, g_iW - 1 do
			local i = y * g_iW + x + 1;
			if g_RR_form[i] == "低地" or g_RR_form[i] == "隆起" then
				-- 理由（判定条件）：只收"原版平地"（丘陵本来就是丘陵，不动），
				-- 且只看与山地相邻这一格——一格宽的山麓裙边，最小侵入。
				local pPlot = Map.GetPlot(x, y);
				if (not pPlot:IsHills()) and (not pPlot:IsMountain()) and RR_CountMountainNeighbors(x, y) > 0 then
					TerrainBuilder.SetTerrainType(pPlot, pPlot:GetTerrainType() + g_TERRAIN_BASE_TO_HILLS_DELTA);
					if not pPlot:IsHills() then
						-- 理由：防御引擎状态延迟——提交后 IsHills 应为真，若仍未生效
						-- 只计数告警（下一个 AreaBuilder.Recalculate 后引擎会同步），
						-- 不让单格异常中断整个建图。
						delayed = delayed + 1;
					end
					-- 理由：海拔/形态表同步到丘陵带，保证后续打印与持久化一致。
					g_RR_elevation[i] = 200 + (g_RR_elevation[i] or 0) * 0.5; -- 200~300m 山麓
					g_RR_form[i] = "山麓";
					converted = converted + 1;
				end
			end
		end
	end

	-- 理由：批量改完统一重算区域（官方 Tilted_Axis 注释：与其反复重算，不如循环末尾一次），
	-- 否则后续河流/特征/资源生成会读到脏 Area 缓存（调研 A 报告 4.5）。
	AreaBuilder.Recalculate();
	print(string.format("[RRMap M1] 山麓带: 平地改丘陵 %d 格 (IsHills延迟生效 %d 格)", converted, delayed));
end

function RR_ApplySnowRidge()
	-- 理由（M1.5 可见性补完，M2 二测用户点破"大片无法通行山脉无层次"）：
	-- 主脊带（>3500m，形态层判定）换雪山地形变体 TERRAIN_SNOW_MOUNTAIN
	-- （原版雪顶皮肤）——高海拔山系呈现雪线核心，与外围山地肉眼分层。
	-- 只改地形变体不改地块类型（仍为不可通行山脉），对河流/特征/资源零扰动。
	-- 理由（M3 具名卡片化）：雪顶皮肤升级为具名卡 TERRAIN_RR_RIDGE"雪线主脊"，
	-- 惰性解析（同 RR_PlaceLayer3Features lazyId 模式），解析失败回落
	-- SNOW_MOUNTAIN——雪顶视觉与悬停描述退回原版，地图必可生成。
	if g_RR_form == nil then
		print("[RRMap M1] WARNING: 雪线主脊跳过——形态层未生成");
		return;
	end
	-- 理由：lazyId 就地定义而非上提全局——解析时机须在 GenerateMap 内
	-- （游戏库此时已就绪），全局位置无法保证。
	local function lazyTerrainId(name)
		local ok, v = pcall(function() return GetGameInfoIndex("Terrains", name); end);
		if ok and v ~= nil and v >= 0 then return v; end
		return -1;
	end
	local ridgeId = lazyTerrainId("TERRAIN_RR_RIDGE");
	if ridgeId < 0 then
		ridgeId = g_TERRAIN_TYPE_SNOW_MOUNTAIN; -- 回落：原版雪顶（M1.5 行为）
	end
	local capped = 0;
	for y = 0, g_iH - 1 do
		for x = 0, g_iW - 1 do
			local i = y * g_iW + x + 1;
			if g_RR_form[i] == "主脊" then
				local pPlot = Map.GetPlot(x, y);
				if pPlot:IsMountain() and pPlot:GetTerrainType() ~= ridgeId then
					TerrainBuilder.SetTerrainType(pPlot, ridgeId);
					capped = capped + 1;
				end
			end
		end
	end
	print(string.format("[RRMap M3] 雪线主脊: 具名卡 %d 格 (地形=%d)", capped, ridgeId));
end

function RR_PersistElevation()
	-- 理由（T2 双保险之一）：海拔表写入 MapConfiguration，键 RR_Elevation_N 分块
	-- （每块 4096 格、约 20-30KB 字符串）+ RR_Elevation_Count 块数。
	-- 诚实标注：MapConfiguration.SetValue 在建图上下文的存在性【无官方先例】
	-- （调研 A 报告 4.2 只证实 GetValue；YnAMP 快照零使用），故全程 pcall——
	-- 写不进去不致命，海拔是纯种子确定函数可由种子重算（双保险之二），
	-- 写日志供 tuner 确认实际走了哪条路。
	if g_RR_elevation == nil then
		return;
	end

	local n = g_iW * g_iH;
	local chunk = 4096;
	local chunks = math.ceil(n / chunk);
	local okCount = 0;
	local failCount = 0;
	local totalBytes = 0;
	for c = 1, chunks do
		local lo = (c - 1) * chunk + 1;
		local hi = math.min(c * chunk, n);
		local parts = {};
		for i = lo, hi do
			parts[i - lo + 1] = tostring(math.floor((g_RR_elevation[i] or 0) + 0.5));
		end
		local s = table.concat(parts, ",");
		local ok = pcall(function()
			MapConfiguration.SetValue("RR_Elevation_" .. (c - 1), s);
		end);
		if ok then
			okCount = okCount + 1;
			totalBytes = totalBytes + string.len(s);
		else
			failCount = failCount + 1;
		end
	end
	-- 理由（M2 首测实证）：SetValue 在建图上下文必失败（0/5 块），
	-- 双保险之二=种子确定性重算；失败只汇总一行，不逐块刷屏。
	if failCount > 0 then
		print(string.format("[RRMap M1] WARNING: 海拔 SetValue 失败 %d/%d 块（建图上下文不支持，走种子重算）", failCount, chunks));
	end
	local okMeta = pcall(function()
		MapConfiguration.SetValue("RR_Elevation_Count", tostring(okCount));
	end);
	print(string.format("[RRMap M1] 海拔持久化: 成功 %d/%d 块, %d 字节, 元数据写入 %s",
		okCount, chunks, totalBytes, tostring(okMeta)));

	-- 理由：回读校验——若同上下文 GetValue 能取回首块，证明写通路真实存在。
	local roundTrip = "未做";
	if okCount > 0 then
		local okRT, back = pcall(function()
			return MapConfiguration.GetValue("RR_Elevation_0");
		end);
		if okRT then
			if back ~= nil then
				roundTrip = string.format("成功(首块%d字节)", string.len(back));
			else
				roundTrip = "失败(读回nil)";
			end
		else
			roundTrip = "失败(pcall报错)";
		end
	end
	print("[RRMap M1] 海拔持久化回读: " .. roundTrip);
end

function RR_PrintElevationSamples()
	-- 理由（T2）：开局后 tuner 日志抽样核对——每 2000 格打印一格的海拔与形态，
	-- 覆盖全图约 1/2000 的样点，足以核对量级（海岸≈0/低地<200/山地1500+）
	-- 与海陆分界是否正确，而不刷屏。
	if g_RR_elevation == nil then
		return;
	end
	local n = g_iW * g_iH;
	for y = 0, g_iH - 1 do
		for x = 0, g_iW - 1 do
			local i = y * g_iW + x + 1;
			if i % 2000 == 1 then
				print(string.format("[RRMap M1] elev sample %d,%d=%.0f (%s)",
					x, y, g_RR_elevation[i], tostring(g_RR_form[i])));
			end
		end
	end
end


-------------------------------------------------------------------------------
-- RR M2：水文分级与河面
-- 依据：
--   陆改水机制 = AddLakes 先例（RiversLakes.lua L387 SetTerrainType(COAST)
--                + AreaBuilder.Recalculate()）。
--   河网连通   = plot:IsRiver()（AddLakes L363 活跃使用）+ 并查集；
--                引擎虽在 SetWOfRiver 等接口收 riverID，但不向 Lua 暴露
--                读取口（Base+GS 全图脚本无 GetRiverID 先例），故自建图。
--   淡水       = 河道边缘原样保留，河岸格仍 IsRiverAdjacent（策划案大河卡
--                "淡水可用性：可用"由此满足；水面本身属海水区不给淡水，
--                与河口现实一致）。
-- 诚实标注：并集用"相邻且有河沿"近似连通——两条贴邻并行的独立小河会被
-- 合并为一个流域（尺寸偏大一级）；语义上它们即将汇流，可接受。
-- 分级的流域尺寸以"格数"计（策划案集水面积的网格化近似：168×108 上
-- 1 格≈8.5km×8.5km，8 格流域≈宽两格的中等河，28 格≈亚马逊级干流）。
-------------------------------------------------------------------------------

function RR_UnionFind(parent, a)
	local r = a;
	while parent[r] ~= r do
		r = parent[r];
	end
	while parent[a] ~= r do
		local nxt = parent[a];
		parent[a] = r;
		a = nxt;
	end
	return r;
end

function RR_UnionRiver(parent, a, b)
	local ra = RR_UnionFind(parent, a);
	local rb = RR_UnionFind(parent, b);
	if ra ~= rb then
		parent[rb] = ra;
	end
end

function RR_ClassifyAndConvertRivers(plotTypes, terrainTypes)
	-- 理由（插入点见 GenerateMap）：AddRivers/AddLakes 后、AddFeatures 前。
	if g_RR_elevation == nil or g_RR_form == nil then
		print("[RRMap M1] WARNING: 大河分级跳过——海拔/形态层未生成");
		return;
	end

	local n = g_iW * g_iH;
	local stats = {comps = 0, inland = 0, r1 = 0, r2 = 0, r3 = 0, r4 = 0,
		channel = 0, rapids = 0, widened = 0, floodplain = 0, delta = 0,
		lakesRemoved = 0, lakesKept = 0, stubsRemoved = 0};
	g_RR_river = {};
	g_RR_riverMark = {};

	-- 第零遍：孤儿小湖回填（理由：AddLakes 随机撒湖与河网无关，出现"水点无河"
	-- 的违和——M2 二测用户反馈；策划案轻量因果要求水系连通。与河相连的
	-- 小湖保留（首测好评的景观）。判定：小湖=水格且所属 Area 格数 ≤8
	-- （海湾/河面所属面积极大，天然排除）；无河=周边 2 格内无 IsRiver 格。
	local riverTerrainType0 = g_TERRAIN_TYPE_COAST;
	local okRT0, rtIdx0 = pcall(function()
		return GetGameInfoIndex("Terrains", "TERRAIN_COAST");
	end);
	if okRT0 and rtIdx0 ~= nil and rtIdx0 >= 0 then
		riverTerrainType0 = rtIdx0;
	end
	local nearRiver = {};
	local q2 = {};
	local h2, t2 = 1, 0;
	for i = 0, n - 1 do
		local p = Map.GetPlotByIndex(i);
		if p:IsRiver() then
			nearRiver[i] = 0;
			t2 = t2 + 1;
			q2[t2] = i;
		end
	end
	while h2 <= t2 do
		local cur = q2[h2];
		h2 = h2 + 1;
		if nearRiver[cur] < 2 then
			local x = cur % g_iW;
			local y = (cur - x) / g_iW;
			for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
				local a = Map.GetAdjacentPlot(x, y, dir);
				if a ~= nil then
					local ai = a:GetY() * g_iW + a:GetX();
					if nearRiver[ai] == nil then
						nearRiver[ai] = nearRiver[cur] + 1;
						t2 = t2 + 1;
						q2[t2] = ai;
					end
				end
			end
		end
	end
	for i = 0, n - 1 do
		local p = Map.GetPlotByIndex(i);
		if p:IsWater() and p:GetTerrainType() ~= riverTerrainType0 then
			local area = p:GetArea();
			if area ~= nil and area:GetPlotCount() <= 8 then
				if nearRiver[i] == nil then
					-- 回填陆地：纬度带基础地形（仿 TerrainGenerator 带：雪/苔原/草原）
					local y = math.floor(i / g_iW);
					local lat = math.abs((g_iH / 2) - y) / (g_iH / 2);
					local t = g_TERRAIN_TYPE_GRASS;
					if lat >= 0.8 then
						t = g_TERRAIN_TYPE_SNOW;
					elseif lat >= 0.65 then
						t = g_TERRAIN_TYPE_TUNDRA;
					end
					TerrainBuilder.SetTerrainType(p, t);
					plotTypes[i] = g_PLOT_TYPE_LAND;
					terrainTypes[i] = t;
					g_RR_elevation[i + 1] = 20;
					g_RR_form[i + 1] = "低地";
					stats.lakesRemoved = stats.lakesRemoved + 1;
				else
					stats.lakesKept = stats.lakesKept + 1;
				end
			end
		end
	end

	-- 第一遍：河网并查集（0-based plot index，与 plotTypes 对齐）
	local parent = {};
	for i = 1, n do
		parent[i] = i;
	end
	local isRiver = {};
	for i = 0, n - 1 do
		local p = Map.GetPlotByIndex(i);
		if p:IsRiver() then
			isRiver[i] = true;
			local x = p:GetX();
			local y = p:GetY();
			for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
				local a = Map.GetAdjacentPlot(x, y, dir);
				if a ~= nil and a:IsRiver() then
					RR_UnionRiver(parent, i + 1, a:GetY() * g_iW + a:GetX() + 1);
				end
			end
		end
	end

	-- 第二遍：连通块聚合 + 通海口判定
	local comps = {};
	for i = 0, n - 1 do
		if isRiver[i] then
			local r = RR_UnionFind(parent, i + 1);
			local c = comps[r];
			if c == nil then
				c = {size = 0, mouth = false, plots = {}};
				comps[r] = c;
			end
			c.size = c.size + 1;
			c.plots[c.size] = i;
			if not c.mouth then
				local x = i % g_iW;
				local y = (i - x) / g_iW;
				for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
					local a = Map.GetAdjacentPlot(x, y, dir);
					if a ~= nil and a:IsWater() then
						c.mouth = true;
						break;
					end
				end
			end
		end
	end

	-- 第三遍：分级（策划案"河流·大河（水面+等级卡）"：R2+ 才构成水面；
	-- 1-based index 对齐 g_RR_* 表）
	local function clearRiverEdges(i)
		-- 理由：清除夭折河流的河沿。签名无官方清除先例，pcall 兜底——
		-- 参数少了（flow/id 为 nil）C 绑定通常容忍；失败也只是留点。
		local p = Map.GetPlotByIndex(i);
		pcall(function() TerrainBuilder.SetWOfRiver(p, false); end);
		pcall(function() TerrainBuilder.SetNWOfRiver(p, false); end);
		pcall(function() TerrainBuilder.SetNEOfRiver(p, false); end);
	end
	for r, c in pairs(comps) do
		stats.comps = stats.comps + 1;
		local cls = 1;
		if c.mouth then
			if c.size >= RR_RIVER_MIN_SIZE_R4 then
				cls = 4;
			elseif c.size >= RR_RIVER_MIN_SIZE_R3 then
				cls = 3;
			elseif c.size >= RR_RIVER_MIN_SIZE_R2 then
				cls = 2;
			end
		else
			stats.inland = stats.inland + 1; -- 内流河：全段保持边缘属性
		end
		if cls == 1 and c.size == 1 and not c.mouth then
			-- 理由（M2.5 退化河点清除）：单格且不出海的分支=只画出源头的
			-- 夭折河流，呈现"格子端点水点却无河道"（M2 二测用户反馈的
			-- 端点水点正是此类）；清除河沿，水系图面干净了再看真短缺。
			clearRiverEdges(c.plots[1]);
			stats.stubsRemoved = stats.stubsRemoved + 1;
			g_RR_river[c.plots[1] + 1] = 0;
		else
			if cls == 1 then stats.r1 = stats.r1 + c.size;
			elseif cls == 2 then stats.r2 = stats.r2 + c.size;
			elseif cls == 3 then stats.r3 = stats.r3 + c.size;
			else stats.r4 = stats.r4 + c.size; end
			for k = 1, c.size do
				g_RR_river[c.plots[k] + 1] = cls;
			end
		end
	end

	-- 第四遍：河道转化判定（先判定完全集，再施工——第五遍的
	-- IsCoastalLand 语义必须是施工前真值，否则三角洲判不出来）
	local channel = {};
	for i = 0, n - 1 do
		local cls = g_RR_river[i + 1];
		if cls ~= nil and cls >= 2 then
			if (g_RR_elevation[i + 1] or 0) < RR_RIVER_WATER_ELEV then
				channel[i] = true;
			else
				-- 理由（策划案瀑布/急流卡）：上游高海拔段保持边缘河，标急流——
				-- 航运阻断的功能标记（数据层，M2 不改通行规则）。
				g_RR_riverMark[i + 1] = RR_MARK_RAPIDS;
				stats.rapids = stats.rapids + 1;
			end
		end
	end

	-- 水面段长度上限（按等级）
	local function channelCap(cls)
		if cls == 2 then return RR_RIVER_CHANNEL_DIST_R2;
		elseif cls == 3 then return RR_RIVER_CHANNEL_DIST_R3;
		elseif cls >= 4 then return RR_RIVER_CHANNEL_DIST_R4; end
		return 0;
	end

	-- 第五遍：河口距离（多源 BFS，限河道格之间通行）——先于一切施工，
	-- 是水面段长度上限与漫滩标记的统一判定基础。
	local mouthDist = {};
	local queue = {};
	local qh, qt = 1, 0;
	for i = 0, n - 1 do
		if channel[i] then
			local x = i % g_iW;
			local y = (i - x) / g_iW;
			local atOpenWater = false;
			for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
				local a = Map.GetAdjacentPlot(x, y, dir);
				if a ~= nil and a:IsWater()
					and not channel[a:GetY() * g_iW + a:GetX()] then
					atOpenWater = true;
					break;
				end
			end
			if atOpenWater then
				mouthDist[i] = 0;
				qt = qt + 1;
				queue[qt] = i;
			end
		end
	end
	while qh <= qt do
		local cur = queue[qh];
		qh = qh + 1;
		local x = cur % g_iW;
		local y = (cur - x) / g_iW;
		for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
			local a = Map.GetAdjacentPlot(x, y, dir);
			if a ~= nil then
				local ai = a:GetY() * g_iW + a:GetX();
				if channel[ai] and mouthDist[ai] == nil then
					mouthDist[ai] = mouthDist[cur] + 1;
					qt = qt + 1;
					queue[qt] = ai;
				end
			end
		end
	end

	-- 第六遍：河漫滩/三角洲标记（施工前判定；只标将转水面的下游河道两岸；
	-- IsCoastalLand 此时还是施工前真值，三角洲判据才成立）
	for i = 0, n - 1 do
		if channel[i] and mouthDist[i] ~= nil and mouthDist[i] <= channelCap(g_RR_river[i + 1]) then
			local x = i % g_iW;
			local y = (i - x) / g_iW;
			for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
				local a = Map.GetAdjacentPlot(x, y, dir);
				if a ~= nil and not a:IsWater() then
					local ai = a:GetY() * g_iW + a:GetX() + 1;
					local f = g_RR_form[ai];
					if (f == "低地" or f == "隆起") and g_RR_riverMark[ai] == nil then
						if a:IsCoastalLand() then
							g_RR_riverMark[ai] = RR_MARK_DELTA;
							stats.delta = stats.delta + 1;
						else
							g_RR_riverMark[ai] = RR_MARK_FLOODPLAIN;
							stats.floodplain = stats.floodplain + 1;
						end
					end
				end
			end
		end
	end

	-- 第七遍：施工——下游河道格陆改水（AddLakes 机制：SetTerrainType + 台账同步）。
	-- 理由（惰性解析自定义地形）：TERRAIN_RR_RIVER 由本 mod 的 UpdateDatabase
	-- 加载，但 include 时机不保证晚于它，调用点查询最稳；失败回退 COAST——
	-- 水面功能不受影响，仅描述退回"海岸"。
	local riverTerrainType = g_TERRAIN_TYPE_COAST;
	local okRT, rtIdx = pcall(function()
		return GetGameInfoIndex("Terrains", "TERRAIN_COAST");
	end);
	if okRT and rtIdx ~= nil and rtIdx >= 0 then
		riverTerrainType = rtIdx;
	end
	for i = 0, n - 1 do
		if channel[i] and mouthDist[i] ~= nil and mouthDist[i] <= channelCap(g_RR_river[i + 1]) then
			local p = Map.GetPlotByIndex(i);
			if not p:IsWater() then
				TerrainBuilder.SetTerrainType(p, riverTerrainType);
				plotTypes[i] = g_PLOT_TYPE_OCEAN;
				terrainTypes[i] = riverTerrainType;
				g_RR_elevation[i + 1] = -5; -- ≈0m 水面
				g_RR_form[i + 1] = "海岸/水面";
				stats.channel = stats.channel + 1;
			end
		end
	end

	-- 第八遍：R3/R4 入海口拓宽。
	-- 理由（策划案大河卡"河口多格水面"）：只有下游近河口段拓宽，
	-- 中上游保持 1 格宽航道——亚马逊河口 300km 宽由此表达。
	for i = 0, n - 1 do
		if channel[i] and mouthDist[i] ~= nil then
			local cls = g_RR_river[i + 1];
			local maxD = 0;
			if cls == 3 then
				maxD = RR_RIVER_WIDEN_DIST_R3;
			elseif cls >= 4 then
				maxD = RR_RIVER_WIDEN_DIST_R4;
			end
			if mouthDist[i] <= maxD then
				local x = i % g_iW;
				local y = (i - x) / g_iW;
				for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
					local a = Map.GetAdjacentPlot(x, y, dir);
					if a ~= nil and not a:IsWater() and not a:IsNaturalWonder() then
						local ai = a:GetY() * g_iW + a:GetX() + 1;
						local f = g_RR_form[ai];
						if (f == "低地" or f == "隆起")
							and (g_RR_elevation[ai] or 9999) < RR_RIVER_WIDEN_ELEV then
							TerrainBuilder.SetTerrainType(a, riverTerrainType);
							plotTypes[ai - 1] = g_PLOT_TYPE_OCEAN;
							terrainTypes[ai - 1] = riverTerrainType;
							g_RR_elevation[ai] = -5;
							g_RR_form[ai] = "海岸/水面";
							stats.widened = stats.widened + 1;
						end
					end
				end
			end
		end
	end

	-- 第八遍半：陆改水后区域重算（AddLakes 同款；回填湖与新增水面都要）
	if stats.channel + stats.widened + stats.lakesRemoved > 0 then
		AreaBuilder.Recalculate();
	end

	print(string.format("[RRMap M2] 流域: %d 个(内流 %d), 格数 R1=%d R2=%d R3=%d R4=%d",
		stats.comps, stats.inland, stats.r1, stats.r2, stats.r3, stats.r4));
	print(string.format("[RRMap M2] 水面: 河道 %d 格, 拓宽 %d 格, 急流 %d, 漫滩 %d, 三角洲 %d",
		stats.channel, stats.widened, stats.rapids, stats.floodplain, stats.delta));
	print(string.format("[RRMap M2] 湖泊: 保留(邻河) %d 格, 回填(孤儿) %d 格; 退化河点清除 %d 处",
		stats.lakesKept, stats.lakesRemoved, stats.stubsRemoved));

	RR_PersistRiverData();
end

function RR_PersistRiverData()
	-- 理由（T2 同款双保险）：等级/标记各为每格一位数字（0-4 / 0-7），
	-- 分块写 MapConfiguration；写不进去不致命——水文数据 gameplay 阶段
	-- 主要靠开局事件桥接重推（同海拔，见审查报告B）。
	if g_RR_river == nil then
		return;
	end
	local n = g_iW * g_iH;
	local classParts = {};
	local markParts = {};
	for i = 1, n do
		classParts[i] = tostring(g_RR_river[i] or 0);
		markParts[i] = tostring(g_RR_riverMark[i] or 0);
	end
	local chunk = 4096;
	local function writeChunks(prefix, s)
		local total = string.len(s);
		local chunks = math.ceil(total / chunk);
		local okCount = 0;
		for c = 1, chunks do
			local lo = (c - 1) * chunk + 1;
			local hi = math.min(c * chunk, total);
			local ok = pcall(function()
				MapConfiguration.SetValue(string.format("%s_%d", prefix, c - 1), string.sub(s, lo, hi));
			end);
			if ok then
				okCount = okCount + 1;
			end
		end
		pcall(function()
			MapConfiguration.SetValue(prefix .. "_Count", tostring(okCount));
		end);
		return okCount, chunks;
	end
	local okC, chC = writeChunks("RR_River", table.concat(classParts));
	local okM, chM = writeChunks("RR_RiverMark", table.concat(markParts));
	print(string.format("[RRMap M2] 水文持久化: 等级 %d/%d 块, 标记 %d/%d 块", okC, chC, okM, chM));
end

function RR_PlaceLayer3Features()
	-- 理由（M2.5 Layer3 落地）：把已有数据标记转成真实特征卡——
	-- 三角洲标→FEATURE_RR_DELTA；急流标→FEATURE_RR_RAPIDS；
	-- 漫滩标→FEATURE_RR_FLOODPLAIN。外加两种"原版即策划案"的地貌
	-- 直放原版特征（视觉零风险）：荒漠邻河→FEATURE_OASIS（绿洲），
	-- 低地多水邻格→FEATURE_MARSH（沼泽/湿地，策划案排水不畅判据的
	-- 最简实现：平地草原/平原且 ≥3 邻水）。
	-- 放在 AddFeatures 前：先占位，原版生成器跳过已有特征的格子。
	local deltaId, rapidsId, floodId, oasisId, marshId = -1, -1, -1, -1, -1;
	local function lazyId(name)
		local ok, v = pcall(function() return GetGameInfoIndex("Features", name); end);
		if ok and v ~= nil and v >= 0 then return v; end
		return -1;
	end
	deltaId = lazyId("FEATURE_RR_DELTA");
	rapidsId = lazyId("FEATURE_RR_RAPIDS");
	floodId = lazyId("FEATURE_RR_FLOODPLAIN");
	oasisId = lazyId("FEATURE_OASIS");
	marshId = lazyId("FEATURE_MARSH");
	if g_RR_riverMark == nil then
		print("[RRMap M2] WARNING: Layer3特征跳过——水文标记未生成");
		return;
	end
	local placedDelta, placedRapids, placedFlood, placedOasis, placedMarsh, skipped =
		0, 0, 0, 0, 0, 0;
	-- 内嵌放置器：宿主不适（水/山/奇观/已有特征）计数跳过
	local function tryPlace(pPlot, id)
		if id < 0 then return false; end
		if (not pPlot:IsWater()) and (not pPlot:IsMountain())
			and (not pPlot:IsNaturalWonder())
			and pPlot:GetFeatureType() == g_FEATURE_NONE then
			TerrainBuilder.SetFeatureType(pPlot, id);
			return true;
		end
		skipped = skipped + 1;
		return false;
	end
	for y = 0, g_iH - 1 do
		for x = 0, g_iW - 1 do
			local i = y * g_iW + x + 1;
			local pPlot = Map.GetPlot(x, y);
			-- 第一层：水文标记卡（每格最多一个标记，赋值处已保证）
			local m = g_RR_riverMark[i];
			if m == RR_MARK_DELTA and tryPlace(pPlot, deltaId) then placedDelta = placedDelta + 1;
			elseif m == RR_MARK_RAPIDS and tryPlace(pPlot, rapidsId) then placedRapids = placedRapids + 1;
			elseif m == RR_MARK_FLOODPLAIN and tryPlace(pPlot, floodId) then placedFlood = placedFlood + 1; end
			-- 第二层：原版特征直放（只在没有水文卡时）
			if pPlot:GetFeatureType() == g_FEATURE_NONE then
				local t = pPlot:GetTerrainType();
				if t == g_TERRAIN_TYPE_DESERT then
					-- 绿洲：平地荒漠 且 邻河（小河边缘河或河面都算水源）
					if pPlot:IsRiver() then
						if tryPlace(pPlot, oasisId) then placedOasis = placedOasis + 1; end
					else
						for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
							local a = Map.GetAdjacentPlot(x, y, dir);
							if a ~= nil and a:IsWater() then
								if tryPlace(pPlot, oasisId) then placedOasis = placedOasis + 1; end
								break;
							end
						end
					end
				elseif (t == g_TERRAIN_TYPE_GRASS or t == g_TERRAIN_TYPE_PLAINS)
					and (not pPlot:IsHills()) then
					-- 沼泽：平地草原/平原 且 ≥3 邻水（排水不畅）
					local waterN = 0;
					for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
						local a = Map.GetAdjacentPlot(x, y, dir);
						if a ~= nil and a:IsWater() then waterN = waterN + 1; end
					end
					if waterN >= 3 and tryPlace(pPlot, marshId) then placedMarsh = placedMarsh + 1; end
				end
			end
		end
	end
	print(string.format("[RRMap M2] Layer3特征: 三角洲 %d, 急流 %d, 漫滩 %d, 绿洲 %d, 沼泽 %d, 跳过(宿主不适) %d",
		placedDelta, placedRapids, placedFlood, placedOasis, placedMarsh, skipped));
end

-------------------------------------------------------------------------------
-- RR M3：形态×地带具名矩阵地形卡（具名卡片化里程碑）
-- 依据：
--   引擎事实（已验证）：一块地只有一个 terrain type；丘陵性内建于地形
--   （*_HILLS 地形要求 plot type 为 hills，SetTerrainType 会同步 plot type，
--   ApplyFoothills 实证）；山地格渲染由 plot type 管，悬停显示 terrain 名
--   （先例 SNOW_MOUNTAIN 显示"雪山"）。
--   壳等价原则：每个矩阵地形借对应原版壳（属性列/产出/适地表逐值照抄，
--   见 Data/RR_Terrains_Matrix.xml 头注释），本轮不改任何机制数值；
--   悬停从"草原/平原"等隐式表达变为"低地·森林/隆起·草原"等具名卡。
-- 诚实标注：
--   (a) 隆起/山麓落在原版平地上的格子，写丘陵壳地形时 plot type 同步为
--       hills（与 ApplyFoothills 同款机制）——这些格产出由平地壳变丘陵壳，
--       是"形态=岗地丘陵"的设计落地，不是数值偷改；
--   (b) 极地低地（TERRAIN_SNOW/SNOW_HILLS）不建卡，保持原版"雪原"；
--   (c) terrainTypes 台账（GenerateTerrainTypes 返回值）在本函数后不再刷新，
--       后续 AddCliffs 等只按陆/水大类读它，矩阵改动不跨陆水边界，安全；
--   (d) 海洋三级具名化：深海/浅海形态 → TERRAIN_RR_DEEPSEA/RR_SHALLOW 具名水卡
--       （壳等价：分别借 TERRAIN_OCEAN/TERRAIN_COAST 壳）；"海岸/水面"形态保持
--       原版 COAST 不建卡，河面 TERRAIN_RR_RIVER 由 RR_ClassifyAndConvertRivers
--       另行处理，两者互不动。
-------------------------------------------------------------------------------

function RR_ApplyTerrainMatrix()
	-- 理由（插入点见 GenerateMap）：Layer3 特征直放后、AddFeatures 前。
	-- 全程无随机数消耗（只读形态表 + SetTerrainType），不扰动原版随机流。
	if g_RR_form == nil then
		print("[RRMap M3] WARNING: 矩阵地形跳过——形态层未生成");
		return;
	end

	-- 理由（惰性解析）：照 RR_PlaceLayer3Features lazyId 模式——自定义地形由
	-- UpdateDatabase 加载，调用点查询最稳；解析失败(-1)回落原版壳地形，
	-- 保证地图必可生成（回落时该组合保持隐式表达，功能零损失）。
	local function lazyTerrainId(name)
		local ok, v = pcall(function() return GetGameInfoIndex("Terrains", name); end);
		if ok and v ~= nil and v >= 0 then return v; end
		return -1;
	end

	-- 地带判定表：原版地形 → 地带键（策划案 Layer2 五带中除雪线外的四带；
	-- 雪原/雪丘不建卡，不进表）。壳的平地/丘陵两个变体同地带。
	local zoneByTerrain = {};
	local zoneDefs = {
		{"FOREST", {"TERRAIN_GRASS", "TERRAIN_GRASS_HILLS"}},
		{"STEPPE", {"TERRAIN_PLAINS", "TERRAIN_PLAINS_HILLS"}},
		{"DESERT", {"TERRAIN_DESERT", "TERRAIN_DESERT_HILLS"}},
		{"TUNDRA", {"TERRAIN_TUNDRA", "TERRAIN_TUNDRA_HILLS"}},
	};
	for _, zd in ipairs(zoneDefs) do
		for _, tname in ipairs(zd[2]) do
			local tid = lazyTerrainId(tname);
			if tid >= 0 then zoneByTerrain[tid] = zd[1]; end
		end
	end

	-- 矩阵查表：(形态, 地带) → {矩阵地形名, 壳地形名}；壳名仅作解析失败回落
	-- 的对照与探针标注（回落=不动格子，保持原版壳地形原样）。
	local matrix = {
		["低地"] = {
			FOREST = {"TERRAIN_RR_LOW_FOREST", "TERRAIN_GRASS"},
			STEPPE = {"TERRAIN_RR_LOW_STEPPE", "TERRAIN_PLAINS"},
			DESERT = {"TERRAIN_RR_LOW_DESERT", "TERRAIN_DESERT"},
			TUNDRA = {"TERRAIN_RR_LOW_TUNDRA", "TERRAIN_TUNDRA"},
		},
		["隆起"] = {
			FOREST = {"TERRAIN_RR_RISE_FOREST", "TERRAIN_GRASS_HILLS"},
			STEPPE = {"TERRAIN_RR_RISE_STEPPE", "TERRAIN_PLAINS_HILLS"},
			DESERT = {"TERRAIN_RR_RISE_DESERT", "TERRAIN_DESERT_HILLS"},
			TUNDRA = {"TERRAIN_RR_RISE_TUNDRA", "TERRAIN_TUNDRA_HILLS"},
		},
		["山麓"] = {
			FOREST = {"TERRAIN_RR_FOOT_FOREST", "TERRAIN_GRASS_HILLS"},
			STEPPE = {"TERRAIN_RR_FOOT_STEPPE", "TERRAIN_PLAINS_HILLS"},
			DESERT = {"TERRAIN_RR_FOOT_DESERT", "TERRAIN_DESERT_HILLS"},
			TUNDRA = {"TERRAIN_RR_FOOT_TUNDRA", "TERRAIN_TUNDRA_HILLS"},
		},
	};

	-- 预解析矩阵地形 ID：循环内只做数组查表，不在热路径反复 pcall。
	local matrixId = {};
	for form, zones in pairs(matrix) do
		matrixId[form] = {};
		for zone, names in pairs(zones) do
			matrixId[form][zone] = lazyTerrainId(names[1]);
		end
	end

	-- 海洋三级具名化（M6 实测调参后：深海 ≤-800m / 浅海 -800~-100m / 海岸·水面≈0m；
	-- 旧分界 -2000/-200 见常量区注释）。
	-- 水形态度卡表：形态 → {具名水卡名, 壳地形名}。壳名仅作解析失败回落的对照。
	-- M7 根因定论：浅水具名卡（RR_SHALLOW）3D 棕色为引擎浅水路径不解析自定义
	-- 地形条目（证据链 docs/水面棕色3D-根因调查.md）；若所有者裁决走替代方案 a，
	-- 本行改为 {"TERRAIN_COAST", "TERRAIN_COAST"} 即恢复 3D 蓝色。深海卡
	-- （RR_DEEPSEA）不受此限，保留具名。
	-- 理由（回落语义）：具名卡解析失败(-1)时回落写壳地形——深海回落 OCEAN 对该格
	-- 是恒等写（现状即 OCEAN，零损失）；浅海回落 COAST 会把该格升级为浅水
	-- （ShallowWater/Appeal 列随壳变化），仅在数据库注册整体失败时发生（届时陆地
	-- 具名卡同样缺失），属降级可玩性兜底而非常态路径。
		-- 理由（M7 引擎限制，见 docs/水面棕色3D-根因调查.md）：浅水 3D 路径不解析
		-- Mod 自定义水地形一律棕（深水也如此，用户实机纠正）：水全部直落原版
		-- OCEAN/COAST 保 3D 蓝色；深海/浅海/大河的具名走地块属性+悬停UI覆盖回收。
	local waterMatrix = {
		["深海"] = {"TERRAIN_OCEAN", "TERRAIN_OCEAN"},
		["浅海"] = {"TERRAIN_COAST", "TERRAIN_COAST"},
	};
	-- 预解析水卡 ID 与回落壳 ID（同陆地卡：循环内只做数组查表）。
	local waterMatrixId = {};
	local waterFallbackId = {};
	for form, names in pairs(waterMatrix) do
		waterMatrixId[form] = lazyTerrainId(names[1]);
		waterFallbackId[form] = lazyTerrainId(names[2]);
	end
	-- 山地/主脊：不查地带，按形态直落。主脊通常已被 RR_ApplySnowRidge
	-- 写成具名卡，此处兜底防御（如该函数因形态表缺失跳过）。
	local mountainId = lazyTerrainId("TERRAIN_RR_MOUNTAIN");
	local ridgeId = lazyTerrainId("TERRAIN_RR_RIDGE");
	local ridgeFallback = g_TERRAIN_TYPE_SNOW_MOUNTAIN;

	-- 探针统计：每个形态×地带组合的落地格数 + 例外路径计数。
	local counts = {};
	local flatToHills = 0;	-- 隆起/山麓的平地格同步转为 hills 的格数
	local fallbackCount = 0;	-- 矩阵 ID 解析失败回落壳（格子未动）的格数
	local skippedSnow = 0;		-- 极地（雪原/雪丘）不建卡保持原版的格数
	local waterFallback = 0;	-- 水卡 ID 解析失败走壳回落的格数
	local waterNotWater = 0;	-- 形态表判为水但 plot 已非水的防御计数（不应发生）

	for y = 0, g_iH - 1 do
		for x = 0, g_iW - 1 do
			local i = y * g_iW + x + 1;
			local form = g_RR_form[i];
			local pPlot = Map.GetPlot(x, y);
			if form == "山地" then
				if mountainId >= 0 and pPlot:IsMountain()
					and pPlot:GetTerrainType() ~= mountainId then
					-- 理由：所有非雪线山地统一"山地"具名卡；plot type 本为
					-- mountain，RR_MOUNTAIN 壳行 Mountain="true" 与之相容。
					TerrainBuilder.SetTerrainType(pPlot, mountainId);
					counts["山地"] = (counts["山地"] or 0) + 1;
				end
			elseif waterMatrix[form] ~= nil then
				-- 理由（海洋三级具名化）：深海/浅海形态的水格写具名水卡。
				-- IsWater 防御：形态表生成后本阶段不改 plot 类型，水格恒为水，
				-- 非水即上游异常，跳过并计数，不写地形防崩。
				if pPlot:IsWater() then
					local wid = waterMatrixId[form];
					local target = wid;
					if wid < 0 then
						-- 回落壳（见 waterMatrix 定义处注释：深海恒等、浅海降级）。
						target = waterFallbackId[form];
						waterFallback = waterFallback + 1;
					end
					if target ~= nil and target >= 0
						and pPlot:GetTerrainType() ~= target then
						TerrainBuilder.SetTerrainType(pPlot, target);
					end
					counts[form] = (counts[form] or 0) + 1;
				else
					waterNotWater = waterNotWater + 1;
				end
			elseif form == "主脊" then
				if pPlot:IsMountain() then
					local target = ridgeId >= 0 and ridgeId or ridgeFallback;
					if pPlot:GetTerrainType() ~= target then
						TerrainBuilder.SetTerrainType(pPlot, target);
						counts["主脊"] = (counts["主脊"] or 0) + 1;
					end
				end
			elseif matrix[form] ~= nil then
				local zone = zoneByTerrain[pPlot:GetTerrainType()];
				if zone ~= nil then
					local mid = matrixId[form][zone];
					if mid >= 0 then
						if (form == "隆起" or form == "山麓")
							and (not pPlot:IsHills()) and (not pPlot:IsMountain()) then
							-- 理由（丘陵壳配平）：丘陵壳地形要求 plot type 为
							-- hills（引擎事实）；写 *_HILLS 壳地形即由引擎同步
							-- plot type（ApplyFoothills 同款机制），把"岗地丘陵"
							-- 形态在平地格上落地为真丘陵。
							flatToHills = flatToHills + 1;
						end
						TerrainBuilder.SetTerrainType(pPlot, mid);
						local key = form .. "·" .. zone;
						counts[key] = (counts[key] or 0) + 1;
					else
						-- 理由：矩阵 ID 未注册（如 modinfo 动作加载失败）——
						-- 保持原版壳地形不动，功能与数值完全等价，仅少一张名卡。
						fallbackCount = fallbackCount + 1;
					end
				else
					-- 理由：雪原/雪丘等不建卡地带（极地低地保持原版"雪原"）。
					skippedSnow = skippedSnow + 1;
				end
			end
		end
	end

	-- 理由：批量改完统一重算区域（ApplyFoothills 同款官方注释），否则后续
	-- 特征/资源生成器会读到脏 Area 缓存。
	AreaBuilder.Recalculate();

	-- 理由（探针）：按固定顺序逐组合打印落地格数，tuner 日志可立即核对
	-- 12 个形态×地带组合 + 山地/主脊 + 深海/浅海是否全覆盖、回落路径是否被意外触发。
	local order = {"深海", "浅海", "低地·FOREST", "低地·STEPPE", "低地·DESERT", "低地·TUNDRA",
		"隆起·FOREST", "隆起·STEPPE", "隆起·DESERT", "隆起·TUNDRA",
		"山麓·FOREST", "山麓·STEPPE", "山麓·DESERT", "山麓·TUNDRA",
		"山地", "主脊"};
	local parts = {};
	for _, key in ipairs(order) do
		table.insert(parts, key .. "=" .. tostring(counts[key] or 0));
	end
	print("[RRMap M3] 矩阵地形落地: " .. table.concat(parts, " "));
	print(string.format("[RRMap M3] 矩阵地形例外: 平地转丘陵 %d, 回落原版壳 %d, 极地保持原版 %d, 水卡壳回落 %d, 水形态非水格 %d",
		flatToHills, fallbackCount, skippedSnow, waterFallback, waterNotWater));
end
