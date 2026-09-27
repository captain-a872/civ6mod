------------------------------------------------------------------------------
-- 文件:    RR_Continents.lua
-- 项目:    地大物博·真实地理（RRMap）—— M0 骨架里程碑
-- 用途:    自定义地图生成脚本。M0 阶段完全复用官方 Continents.lua 的原版
--          生成流程（板块噪声 → 海陆 → 地形 → 河流/湖泊 → 地貌 → 资源 → 出生点），
--          保证可加载、可开局，并在 Lua.log 留下验收日志。
--
-- 模板依据: 官方 Continents.lua 的权威副本（经 BBS Mod 逐代跟踪 Firaxis 源码，
--          仓库 d-jackthenarrator/Civ6-BBS，文件 Data/BBS Maps/continents.lua），
--          剔除 BBS 私有改动后还原原版结构。
--
-- 策划案分层对照（M0 全部落在原版机制上，为后续接管预留挂点）:
--   Layer1 形态层 —— GeneratePlotTypes()：大陆分形 + 板块构造山系 + 中心裂谷
--   Layer1 水文层 —— AddRivers() / AddLakes()：原版河流与湖泊
--   Layer2 地带/群系 —— GenerateTerrainTypes() / AddFeatures()：原版气候带与地貌
--   （M1+ 的真实海拔、1:4 网格、河流分级均不触碰，见 docs/模块1-实现计划.md）
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- 标准 include：Firaxis 地图脚本公共库。
-- 前 6 个为任务规定的基础库；后 4 个为官方 Continents.lua（风云变幻版）
-- 原生包含，缺一不可——没有 NaturalWonderGenerator/ResourceGenerator/
-- AssignStartingPlots，地图能生成但游戏无法正常放置出生点与资源。
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

------------------------------------------------------------------------------
-- 全局变量
------------------------------------------------------------------------------
local g_iW, g_iH;                       -- 网格宽、高（GenerateMap 时由引擎赋值）
local g_iFlags = {};                    -- 分形标志（极区等）
local g_continentsFrac = nil;           -- 大陆分形对象
local featureGen = nil;                 -- 地貌生成器实例（AddFeatures 创建，供后续步骤复用）
local world_age_new = 5;                -- 世界年龄参数折算：新（30亿年）→ 5
local world_age_normal = 3;             -- 标准（40亿年）→ 3
local world_age_old = 2;                -- 古老（50亿年）→ 2

------------------------------------------------------------------------------
-- GetMapInitData：引擎在创建地图前直接调用，询问网格尺寸与环绕方式。
-- 返回原版标准尺寸（与官方各尺寸一致）:
--   Duel 44×26 / Tiny 60×36 / Small 74×46 / Standard 84×54 / Large 96×60 / Huge 106×66
-- WrapX=true：东西向环绕，是后续真实地理（经度连续）的前提；
-- WrapY=false：南北向不环绕。
-- 语法对照 YnAMP 真实脚本（Maps/GiantEarth/GiantEarth.lua）的返回结构。
------------------------------------------------------------------------------
function GetMapInitData(worldSize)
	-- 原版标准尺寸表（按 Worlds 表类型名索引，避免依赖 ID/Index 差异）
	local gridSizes = {
		WORLDSIZE_DUEL     = {44, 26},    -- 决斗
		WORLDSIZE_TINY     = {60, 36},    -- 极小
		WORLDSIZE_SMALL    = {74, 46},    -- 小
		WORLDSIZE_STANDARD = {84, 54},    -- 标准
		WORLDSIZE_LARGE    = {96, 60},    -- 大
		WORLDSIZE_HUGE     = {106, 66},   -- 巨大
	};

	local world = GameInfo.Worlds[worldSize];
	local size = nil;
	if world ~= nil then
		size = gridSizes[world.WorldType];
	end
	if size == nil then
		-- 未知尺寸（如其他 Mod 新增）兜底为标准尺寸，保证任何情况下可开局
		print("[RR] Unknown worldSize, fallback to Standard 84x54");
		size = {84, 54};
	end

	return {
		Width  = size[1],
		Height = size[2],
		WrapX  = true,
		WrapY  = false,
	};
end

------------------------------------------------------------------------------
-- GenerateMap：地图生成主流程。引擎在开局时调用。
-- 结构照抄官方 Continents.lua（风云变幻版），M0 不做任何分层接管。
------------------------------------------------------------------------------
function GenerateMap()
	print("[RR] Generating RR Continents Map (M0 vanilla pipeline)");

	local pPlot;

	-- 设置全局量：取网格尺寸与分形标志
	g_iW, g_iH = Map.GetGridSize();
	g_iFlags = TerrainBuilder.GetFractalFlags();

	-- 读取玩家设置的"气温"选项（默认 2=温带；4=随机则折算为 1..3）
	local temperature = MapConfiguration.GetValue("temperature");
	if temperature == 4 then
		temperature = 1 + TerrainBuilder.GetRandomNumber(3, "Random Temperature - Lua");
	end

	-- 读取玩家设置的"世界年龄"选项，折算为官方内部参数（5/3/2）
	local world_age = MapConfiguration.GetValue("world_age");
	if (world_age == 1) then
		world_age = world_age_new;
	elseif (world_age == 2) then
		world_age = world_age_normal;
	elseif (world_age == 3) then
		world_age = world_age_old;
	else
		-- 随机世界年龄
		world_age = 2 + TerrainBuilder.GetRandomNumber(4, "Random World Age - Lua");
	end

	-- Layer1 形态层（原版实现）：板块噪声 + 海陆 + 构造山系 + 孤独山峰
	plotTypes = GeneratePlotTypes(world_age);

	-- Layer2 地带层（原版实现）：按纬度气候带生成平原/草原/沙漠/冻土等
	terrainTypes = GenerateTerrainTypes(plotTypes, g_iW, g_iH, g_iFlags, false, temperature);

	-- 应用基础地形
	ApplyBaseTerrain(plotTypes, terrainTypes, g_iW, g_iH);

	AreaBuilder.Recalculate();
	TerrainBuilder.AnalyzeChokepoints();
	TerrainBuilder.StampContinents();

	-- 沿大陆边界补充丘陵/山地（官方"Add Terrain From Continents"步骤）
	local iContinentBoundaryPlots = GetContinentBoundaryPlotCount(g_iW, g_iH);
	AddTerrainFromContinents(plotTypes, terrainTypes, world_age, g_iW, g_iH, iContinentBoundaryPlots);

	AreaBuilder.Recalculate();

	-- Layer1 水文层（原版实现）：河流生成受地块类型影响（源自高地、流经低地）
	AddRivers();

	-- 湖泊必须晚于河流生成，否则湖泊会截断河流使其无法入海
	local numLargeLakes = GameInfo.Maps[Map.GetMapSize()].Continents;
	AddLakes(numLargeLakes);

	-- Layer2 群系层（原版实现）：森林/雨林/沼泽等地貌
	AddFeatures();
	TerrainBuilder.AnalyzeChokepoints();

	-- 崖岸
	print("[RR] Adding cliffs");
	AddCliffs(plotTypes, terrainTypes);

	-- 自然奇观（数量按地图尺寸表配置）
	local args = {
		numberToPlace = GameInfo.Maps[Map.GetMapSize()].NumNaturalWonders,
	};
	local nwGen = NaturalWonderGenerator.Create(args);
	AddFeaturesFromContinents();
	MarkCoastalLowlands();

	-- 资源生成（密度按玩家"资源"选项）
	resourcesConfig = MapConfiguration.GetValue("resources");
	local startConfig = MapConfiguration.GetValue("start"); -- 出生点均衡配置
	local args = {
		resources = resourcesConfig,
		START_CONFIG = startConfig,
	};
	local resGen = ResourceGenerator.Create(args);

	-- 火山（风云变幻机制；世界年龄越新火山越多）
	AddVolcanos(plotTypes, world_age, g_iW, g_iH);

	-- 出生点分配：没有这一步游戏无法放置文明起点
	print("[RR] Creating start plot database");
	local args = {
		MIN_MAJOR_CIV_FERTILITY = 150,   -- 主要文明最低肥力
		MIN_MINOR_CIV_FERTILITY = 10,    -- 城邦最低肥力
		MIN_BARBARIAN_FERTILITY = 1,     -- 蛮族最低肥力
		START_MIN_Y = 15,                -- 地图上下各 15% 区域不放置主要文明
		START_MAX_Y = 15,
		START_CONFIG = startConfig,
	};
	local start_plot_database = AssignStartingPlots.Create(args);

	-- 部落村庄（ goody huts ）
	local GoodyGen = AddGoodies(g_iW, g_iH);

	AreaBuilder.Recalculate();
	TerrainBuilder.AnalyzeChokepoints();

	-- M0 验收日志：Lua.log 中出现本行即表示生成流程完整跑通
	print("[RR] Map generation done. Grid: " .. g_iW .. "x" .. g_iH);
end

------------------------------------------------------------------------------
-- GeneratePlotTypes：Layer1 形态层（原版实现）。
-- 大陆分形噪声 + 极区收边 + 中心裂谷 + 板块构造山系 + 孤独山峰。
-- 循环重试直到最大陆块不超过总陆地 64%（官方 Continents 规则）。
------------------------------------------------------------------------------
function GeneratePlotTypes(world_age)
	print("[RR] Generating Plot Types");
	local plotTypes = {};

	-- 海平面基准：该百分比以上分形高度为海洋（低/标准/高海平面对应玩家选项）
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

	-- 读取玩家"海平面"选项
	local sea_level = MapConfiguration.GetValue("sea_level");
	if sea_level == 1 then -- 低海平面
		water_percent = sea_level_low;
	elseif sea_level == 2 then -- 标准海平面
		water_percent = sea_level_normal;
	elseif sea_level == 3 then -- 高海平面
		water_percent = sea_level_high;
	else
		water_percent = TerrainBuilder.GetRandomNumber(sea_level_high - sea_level_low, "Random Sea Level - Lua") + sea_level_low + 1;
	end

	-- 按世界年龄调整板块挤压强度：越年轻的山越多
	local adjustment = world_age;
	if world_age <= world_age_old then -- 50 亿年
		adjust_plates = adjust_plates * 0.75;
	elseif world_age >= world_age_new then -- 30 亿年
		adjust_plates = adjust_plates * 1.5;
	else -- 40 亿年
	end

	-- 生成大陆分形并检查最大陆块，直到其不超过总陆地 64% 为止
	local done = false;
	local iAttempts = 0;
	local iWaterThreshold, biggest_area, iNumTotalLandTiles, iNumBiggestAreaTiles, iBiggestID;
	while done == false do
		-- 随机决定大陆颗粒度：2/3 概率细颗粒(2)，否则粗颗粒(1)
		local grain_dice = TerrainBuilder.GetRandomNumber(7, "Continental Grain roll - LUA RR_Continents");
		if grain_dice < 4 then
			grain_dice = 2;
		else
			grain_dice = 1;
		end
		-- 随机决定裂谷颗粒度：1/3 概率不裂(-1)，否则取 0..2
		local rift_dice = TerrainBuilder.GetRandomNumber(3, "Rift Grain roll - LUA RR_Continents");
		if rift_dice < 1 then
			rift_dice = -1;
		end

		InitFractal{continent_grain = grain_dice, rift_grain = rift_dice};
		iWaterThreshold = g_continentsFrac:GetHeight(water_percent);
		local iBuffer = math.floor(g_iH / 13.0);       -- 极区缓冲带（全海洋）
		local iBuffer2 = math.floor(g_iH / 13.0 / 2.0); -- 缓冲带内再随机过渡

		iNumTotalLandTiles = 0;
		for x = 0, g_iW - 1 do
			for y = 0, g_iH - 1 do
				local i = y * g_iW + x;
				local val = g_continentsFrac:GetHeight(x, y);
				local pPlot = Map.GetPlotByIndex(i);

				if (y <= iBuffer or y >= g_iH - iBuffer - 1) then
					-- 极区缓冲带：直接海洋
					plotTypes[i] = g_PLOT_TYPE_OCEAN;
					TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_OCEAN); -- 临时设置以便计算区域
				else
					if (val >= iWaterThreshold) then
						if (y <= iBuffer + iBuffer2) then
							-- 北缘随机过渡带
							local iRandomRoll = y - iBuffer + 1;
							local iRandom = TerrainBuilder.GetRandomNumber(iRandomRoll, "Random Region Edges");
							if (iRandom == 0 and iRandomRoll > 0) then
								plotTypes[i] = g_PLOT_TYPE_LAND;
								TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_DESERT); -- 临时设置
								iNumTotalLandTiles = iNumTotalLandTiles + 1;
							else
								plotTypes[i] = g_PLOT_TYPE_OCEAN;
								TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_OCEAN); -- 临时设置
							end
						elseif (y >= g_iH - iBuffer - iBuffer2 - 1) then
							-- 南缘随机过渡带
							local iRandomRoll = g_iH - y - iBuffer;
							local iRandom = TerrainBuilder.GetRandomNumber(iRandomRoll, "Random Region Edges");
							if (iRandom == 0 and iRandomRoll > 0) then
								plotTypes[i] = g_PLOT_TYPE_LAND;
								TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_DESERT); -- 临时设置
								iNumTotalLandTiles = iNumTotalLandTiles + 1;
							else
								plotTypes[i] = g_PLOT_TYPE_OCEAN;
								TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_OCEAN); -- 临时设置
							end
						else
							plotTypes[i] = g_PLOT_TYPE_LAND;
							TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_DESERT); -- 临时设置
							iNumTotalLandTiles = iNumTotalLandTiles + 1;
						end
					else
						plotTypes[i] = g_PLOT_TYPE_OCEAN;
						TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_OCEAN); -- 临时设置
					end
				end
			end
		end

		ShiftPlotTypes(plotTypes);
		GenerateCenterRift(plotTypes);

		AreaBuilder.Recalculate();
		local biggest_area = Areas.FindBiggestArea(false);
		iNumBiggestAreaTiles = biggest_area:GetPlotCount();

		-- 检查最大陆块占比：≤64% 才接受本次结果
		if iNumBiggestAreaTiles <= iNumTotalLandTiles * 0.64 then
			done = true;
			iBiggestID = biggest_area:GetID();
		end
		iAttempts = iAttempts + 1;

		-- 调试输出（默认注释掉，排查生成问题时打开）
		-- print("-"); print("--- RR_Continents landmass generation, Attempt#", iAttempts, "---");
		-- print("- This attempt successful: ", done);
		-- print("- Total Land Plots in world:", iNumTotalLandTiles);
		-- print("- Land Plots belonging to biggest landmass:", iNumBiggestAreaTiles);
		-- print("- Percentage of land belonging to biggest: ", 100 * iNumBiggestAreaTiles / iNumTotalLandTiles);
		-- print("- Continent Grain for this attempt: ", grain_dice);
		-- print("- Rift Grain for this attempt: ", rift_dice);
		-- print("- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -");
		-- print(".");
	end

	-- 应用板块构造（山脊/丘陵），再补孤独山峰
	local args = {};
	args.world_age = world_age;
	args.iW = g_iW;
	args.iH = g_iH;
	args.iFlags = g_iFlags;
	args.blendRidge = 10;
	args.blendFract = 5;
	args.extra_mountains = 5;
	mountainRatio = 8 + world_age * 3; -- 世界年龄越新，孤独山峰比例越高
	plotTypes = ApplyTectonics(args, plotTypes);
	plotTypes = AddLonelyMountains(plotTypes, mountainRatio);

	return plotTypes;
end

------------------------------------------------------------------------------
-- InitFractal：创建大陆分形对象（含可选裂谷与板块山脊）。
-- 对照官方 Continents.lua 的 InitFractal。
------------------------------------------------------------------------------
function InitFractal(args)

	if (args == nil) then args = {}; end

	local continent_grain = args.continent_grain or 2;
	local rift_grain = args.rift_grain or -1; -- 默认无裂谷；取 1..3 时启用裂谷
	local invert_heights = args.invert_heights or false;
	local polar = args.polar or true;
	local ridge_flags = args.ridge_flags or g_iFlags;

	local fracFlags = {};

	if (invert_heights) then
		fracFlags.FRAC_INVERT_HEIGHTS = true;
	end

	if (polar) then
		fracFlags.FRAC_POLAR = true;
	end

	if (rift_grain > 0 and rift_grain < 4) then
		local riftsFrac = Fractal.Create(g_iW, g_iH, rift_grain, {}, 6, 5);
		g_continentsFrac = Fractal.CreateRifts(g_iW, g_iH, continent_grain, fracFlags, riftsFrac, 6, 5);
	else
		g_continentsFrac = Fractal.Create(g_iW, g_iH, continent_grain, fracFlags, 6, 5);
	end

	-- 用 Brian Wade 的板块山脊法（改良 Voronoi）把山脊织入大陆分形，
	-- 让海岸线与内陆海更自然。板块数量按地图尺寸表取。
	local MapSizeTypes = {};
	for row in GameInfo.Maps() do
		MapSizeTypes[row.MapSizeType] = row.PlateValue;
	end
	local sizekey = Map.GetMapSize();

	local numPlates = MapSizeTypes[sizekey] or 4;

	g_continentsFrac:BuildRidges(numPlates, {}, 1, 2);
end

------------------------------------------------------------------------------
-- AddFeatures：Layer2 群系层（原版实现）。
-- 按玩家"降水"选项创建地貌生成器并放置森林/雨林/沼泽等。
------------------------------------------------------------------------------
function AddFeatures()
	print("[RR] Adding Features");

	-- 读取玩家设置的"降水"选项（默认 2；4=随机则折算为 1..3）
	local rainfall = MapConfiguration.GetValue("rainfall");
	if rainfall == 4 then
		rainfall = 1 + TerrainBuilder.GetRandomNumber(3, "Random Rainfall - Lua");
	end

	local args = {rainfall = rainfall};
	featureGen = FeatureGenerator.Create(args);
	featureGen:AddFeatures(true, true); -- 第二参数：河流是否可发源于内陆
end

------------------------------------------------------------------------------
-- AddFeaturesFromContinents：官方补充步骤，沿大陆边界加地貌变化
------------------------------------------------------------------------------
function AddFeaturesFromContinents()
	print("[RR] Adding Features from Continents");

	featureGen:AddFeaturesFromContinents();
end

------------------------------------------------------------------------------
-- GenerateCenterRift：在地图中部制造南北向裂谷（类似大西洋），
-- 把横跨地图中线的陆块撕开并漂离。官方 Continents 的核心特征之一。
-- 注意：此函数依赖六边形网格几何，仅适用于六边形地图。
------------------------------------------------------------------------------
function GenerateCenterRift(plotTypes)
	-- 先随机决定裂谷"倾斜"方向：0 = 起点偏西、向东倾；1 = 起点偏东、向西倾
	local riftLean = TerrainBuilder.GetRandomNumber(2, "FractalWorld Center Rift Lean - Lua");

	-- 记录裂谷线及每行裂谷两侧边界
	local riftLine = {};
	local westOfRift = {};
	local eastOfRift = {};
	-- 三个行进方向各自的线段最大长度
	local primaryMaxLength = math.max(1, math.floor(g_iH / 8));
	local secondaryMaxLength = math.max(1, math.floor(g_iH / 11));
	local tertiaryMaxLength = math.max(1, math.floor(g_iH / 14));

	-- 裂谷起点与初始方向
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
	-- 裂谷 X 边界（防止裂谷偏出允许范围）
	local riftXBoundary = math.floor(g_iW / 2) - startDistanceFromCenterColumn;

	-- 处理裂谷起点格
	local currentDirection = startingDirection;
	local currentX = startX;
	local currentY = startY;
	table.insert(riftLine, {currentX, currentY});
	local rowIndex = currentY + 1;
	westOfRift[rowIndex] = currentX - 1;
	eastOfRift[rowIndex] = currentX + 1;
	-- 裂谷经过的格子全部变为海洋
	local plotIndex = currentX + 1; -- Lua 数组从 1 开始
	plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;

	-- 生成裂谷线：由一系列线段组成，每段沿三个方向之一行进
	if riftLean == 0 then -- 向东倾
		while currentY < g_iH - 1 do
			local nextDirection = 0;

			if currentDirection == DirectionTypes.DIRECTION_EAST then
				local segmentLength = TerrainBuilder.GetRandomNumber(tertiaryMaxLength + 1, "FractalWorld Center Rift Segment Length - Lua");
				-- 选择下一方向
				if currentX >= riftXBoundary then -- 已到最东，必须折返
					nextDirection = DirectionTypes.DIRECTION_NORTHWEST;
				else
					local dice = TerrainBuilder.GetRandomNumber(3, "FractalWorld Center Rift Direction - Lua");
					if dice == 1 then
						nextDirection = DirectionTypes.DIRECTION_NORTHWEST;
					else
						nextDirection = DirectionTypes.DIRECTION_NORTHEAST;
					end
				end
				-- 处理东行线段
				local plotsToDo = segmentLength;
				while plotsToDo > 0 do
					currentX = currentX + 1; -- 向东，Y 不变
					rowIndex = currentY;
					eastOfRift[rowIndex] = currentX + 1;
					plotIndex = currentY * g_iW + currentX + 1;
					plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
					plotsToDo = plotsToDo - 1;
				end

			elseif currentDirection == DirectionTypes.DIRECTION_NORTHWEST then
				local segmentLength = TerrainBuilder.GetRandomNumber(secondaryMaxLength + 1, "FractalWorld Center Rift Segment Length - Lua");
				-- 选择下一方向
				if currentX >= riftXBoundary then
					nextDirection = DirectionTypes.DIRECTION_NORTHEAST;
				else
					local dice = TerrainBuilder.GetRandomNumber(4, "FractalWorld Center Rift Direction - Lua");
					if dice == 2 then
						nextDirection = DirectionTypes.DIRECTION_EAST;
					else
						nextDirection = DirectionTypes.DIRECTION_NORTHEAST;
					end
				end
				-- 处理西北行线段
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
				-- 选择下一方向
				if currentX >= riftXBoundary then
					nextDirection = DirectionTypes.DIRECTION_NORTHWEST;
				else
					local dice = TerrainBuilder.GetRandomNumber(2, "FractalWorld Center Rift Direction - Lua");
					if dice == 1 and currentY > g_iH * 0.28 then
						nextDirection = DirectionTypes.DIRECTION_EAST;
					else
						nextDirection = DirectionTypes.DIRECTION_NORTHWEST;
					end
				end
				-- 处理东北行线段
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

			-- 线段结束，切换方向
			currentDirection = nextDirection;
		end

	else -- 向西倾
		while currentY < g_iH - 1 do
			local nextDirection = 0;

			if currentDirection == DirectionTypes.DIRECTION_WEST then
				local segmentLength = TerrainBuilder.GetRandomNumber(tertiaryMaxLength + 1, "FractalWorld Center Rift Segment Length - Lua");
				-- 选择下一方向
				if currentX <= riftXBoundary then -- 已到最西，必须折返
					nextDirection = DirectionTypes.DIRECTION_NORTHEAST;
				else
					local dice = TerrainBuilder.GetRandomNumber(3, "FractalWorld Center Rift Direction - Lua");
					if dice == 1 then
						nextDirection = DirectionTypes.DIRECTION_NORTHEAST;
					else
						nextDirection = DirectionTypes.DIRECTION_NORTHWEST;
					end
				end
				-- 处理西行线段
				local plotsToDo = segmentLength;
				while plotsToDo > 0 do
					currentX = currentX - 1; -- 向西，Y 不变
					rowIndex = currentY;
					westOfRift[rowIndex] = currentX - 1;
					plotIndex = currentY * g_iW + currentX + 1;
					plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
					plotsToDo = plotsToDo - 1;
				end

			elseif currentDirection == DirectionTypes.DIRECTION_NORTHEAST then
				local segmentLength = TerrainBuilder.GetRandomNumber(secondaryMaxLength + 1, "FractalWorld Center Rift Segment Length - Lua");
				-- 选择下一方向
				if currentX <= riftXBoundary then
					nextDirection = DirectionTypes.DIRECTION_NORTHWEST;
				else
					local dice = TerrainBuilder.GetRandomNumber(4, "FractalWorld Center Rift Direction - Lua");
					if dice == 2 then
						nextDirection = DirectionTypes.DIRECTION_WEST;
					else
						nextDirection = DirectionTypes.DIRECTION_NORTHWEST;
					end
				end
				-- 处理东北行线段
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
				-- 选择下一方向
				if currentX <= riftXBoundary then
					nextDirection = DirectionTypes.DIRECTION_NORTHEAST;
				else
					local dice = TerrainBuilder.GetRandomNumber(2, "FractalWorld Center Rift Direction - Lua");
					if dice == 1 and currentY > g_iH * 0.28 then
						nextDirection = DirectionTypes.DIRECTION_WEST;
					else
						nextDirection = DirectionTypes.DIRECTION_NORTHEAST;
					end
				end
				-- 处理西北行线段
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

			-- 线段结束，切换方向
			currentDirection = nextDirection;
		end
	end
	-- 处理裂谷最后一格
	westOfRift[g_iH] = currentX - 1;
	eastOfRift[g_iH] = currentX + 1;
	plotIndex = (g_iH - 1) * g_iW + currentX + 1;
	plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;

	-- 加宽裂谷：让裂谷两侧陆地"漂离"（把一侧的地块拷贝到更靠外的位置）
	local horizontalDrift = 3;
	local verticalDrift = 2;

	if riftLean == 0 then
		-- 西侧自上而下处理
		for y = g_iH - 1 - verticalDrift, 0, -1 do
			local thisRowX = westOfRift[y + 1];
			for x = horizontalDrift, thisRowX do
				local sourcePlotIndex = y * g_iW + x + 1;
				local destPlotIndex = (y + verticalDrift) * g_iW + (x - horizontalDrift) + 1;
				plotTypes[destPlotIndex] = plotTypes[sourcePlotIndex];
			end
		end
		-- 东侧自下而上处理
		for y = verticalDrift, g_iH - 1 do
			local thisRowX = eastOfRift[y + 1];
			for x = thisRowX, g_iW - horizontalDrift - 1 do
				local sourcePlotIndex = y * g_iW + x + 1;
				local destPlotIndex = (y - verticalDrift) * g_iW + (x + horizontalDrift) + 1;
				plotTypes[destPlotIndex] = plotTypes[sourcePlotIndex];
			end
		end
		-- 清理剩余地块（全部变为海洋）
		-- 左下角
		for y = 0, verticalDrift - 1 do
			local thisRowX = westOfRift[y + 1];
			for x = 0, thisRowX do
				local plotIndex = y * g_iW + x + 1;
				plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
			end
		end
		-- 右上角
		for y = g_iH - verticalDrift, g_iH - 1 do
			local thisRowX = eastOfRift[y + 1];
			for x = thisRowX, g_iW - 1 do
				local plotIndex = y * g_iW + x + 1;
				plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
			end
		end
		-- 清理裂谷本体
		for y = verticalDrift, g_iH - 1 - verticalDrift do
			local westX = westOfRift[y - verticalDrift + 1] - horizontalDrift + 1;
			local eastX = eastOfRift[y + verticalDrift + 1] + horizontalDrift - 1;
			for x = westX, eastX do
				local plotIndex = y * g_iW + x + 1;
				plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
			end
		end

	else -- riftLean = 1
		-- 西侧自下而上处理
		for y = verticalDrift, g_iH - 1 do
			local thisRowX = westOfRift[y + 1];
			for x = horizontalDrift, thisRowX do
				local sourcePlotIndex = y * g_iW + x + 1;
				local destPlotIndex = (y - verticalDrift) * g_iW + (x - horizontalDrift) + 1;
				plotTypes[destPlotIndex] = plotTypes[sourcePlotIndex];
			end
		end
		-- 东侧自上而下处理
		for y = g_iH - 1 - verticalDrift, 0, -1 do
			local thisRowX = eastOfRift[y + 1];
			for x = thisRowX, g_iW - horizontalDrift - 1 do
				local sourcePlotIndex = y * g_iW + x + 1;
				local destPlotIndex = (y + verticalDrift) * g_iW + (x + horizontalDrift) + 1;
				plotTypes[destPlotIndex] = plotTypes[sourcePlotIndex];
			end
		end
		-- 清理剩余地块（全部变为海洋）
		-- 左上角
		for y = g_iH - verticalDrift, g_iH - 1 do
			local thisRowX = westOfRift[y + 1];
			for x = 0, thisRowX do
				local plotIndex = y * g_iW + x + 1;
				plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
			end
		end
		-- 右下角
		for y = 0, verticalDrift - 1 do
			local thisRowX = eastOfRift[y + 1];
			for x = thisRowX, g_iW - 1 do
				local plotIndex = y * g_iW + x + 1;
				plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
			end
		end
		-- 清理裂谷本体
		for y = verticalDrift, g_iH - 1 - verticalDrift do
			local westX = westOfRift[y + verticalDrift + 1] - horizontalDrift + 1;
			local eastX = eastOfRift[y - verticalDrift + 1] + horizontalDrift - 1;
			for x = westX, eastX do
				local plotIndex = y * g_iW + x + 1;
				plotTypes[plotIndex] = g_PLOT_TYPE_OCEAN;
			end
		end
	end

end
