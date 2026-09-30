------------------------------------------------------------------------------
-- 文件:    RR_EastAsia.lua
-- 项目:    地大物博·真实地理（RRMap）—— M9 东亚真实学习型地图
-- 依据:    docs/M9-东亚真实地图-学习笔记.md（本文件生成的学习结论归档处）；
--          数据层 mod/Maps/RR_EastAsiaData.lua（tools/fetch_eastasia_dem.py
--          机器生成，真实 DEM：AWS Open Data Terrain Tiles，陆地 SRTM +
--          海底 ETOPO1 融合，双线性重采样至 0.625°x0.577°）。
-- 职责:    一张"东亚—西太平洋"真实地理静态图（东经 70°~145°、北纬
--          10°~55°，MAPSIZE_RR_STD10 = 120x78）。定位：生成器
--          （RR_Tectonics）的 ground truth 教材——真实板块-气候-地形
--          对应关系以数据形式固化，供逐区域比对校准。
-- 架构:    include "RR_Continents" 复用其全部落地机制（形态分类/雪线主脊/
--          大河分级/微地貌/矩阵地形/海拔持久化——依赖 M9 把 g_iW/g_iH
--          提升为全局，见该文件常量区注释），本文件只替换三个数据源：
--            1) 海陆与地块类型 ← 真实 DEM（RR_EastAsia_GeneratePlots）
--            2) 地带地形壳     ← 编纂气候格网（RR_EastAsia_GenerateTerrain）
--            3) 主要河系       ← 折线点列栅格化（RR_EastAsia_AddMajorRivers）
--          原版分形管线（InitFractal/GenerateCenterRift/AddLakes 等）不用。
-- 诚实标注: (a) 本图不使用随机海陆——世界全随机种子只影响原版 AddRivers
--          补充支流与特征/资源/奇观摆放；(b) 真实 DEM 在 0.6° 均质化下，
--          地块类型按"海拔 + 局部起伏"双判据派生（高原≠山，见学习笔记），
--          形态层 8 类名与下游契约不变；(c) 东亚图关闭东西卷轴
--          （GetMapInitData WrapX=false，InlandSea/Tilted_Axis 官方先例）。
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
-- 理由（M9）：复用 RR_Continents 的全部落地函数（RR_* 系列与 AddFeatures/
-- AddFeaturesFromContinents）。include 顺序在本文件自身枚举消费之前。
include "RR_Continents"
-- 理由（M9）：真实 DEM + 气候格网数据（机器生成，见头注释）。
include "RR_EastAsiaData"

-- RR M9 东亚图常量区
local RR_EA_LON0 = RR_EASTASIA_DATA.lon0;		-- 数据网格西界（东经 70°）
local RR_EA_LATN = RR_EASTASIA_DATA.latNorth;	-- 数据网格北界（北纬 55°）
local RR_EA_DW = RR_EASTASIA_DATA.dlon;			-- 0.625°/格
local RR_EA_DH = RR_EASTASIA_DATA.dlat;			-- 0.5769°/格
local RR_EA_DATA_W = RR_EASTASIA_DATA.w;		-- 120
local RR_EA_DATA_H = RR_EASTASIA_DATA.h;		-- 78

-- 地块类型派生阈值（真实 DEM → Civ6 三类陆地地块；依据见学习笔记 §1）：
-- 高原/盆地 issue——塔里木 1000m、蒙古高原 1500m 是"高而平"的台地，
-- 不能按 RR 纯海拔门槛（≥700 即山地）整片判不可通行山；必须叠加
-- 局部起伏（5x5 邻域 max-min，≈190km 窗）区分"台地"与"山脉"。
local RR_EA_PLOT_MOUNTAIN_MIN_ELEV = 2800;	-- 极高海拔：无条件山地（青藏、帕米尔）
local RR_EA_PLOT_HILL_MIN_ELEV = 200;		-- 丘陵下限（山麓带同 RR）
local RR_EA_PLOT_MOUNTAIN_MIN_RELIEF = 600;	-- 700~2800m 段：局部起伏 ≥600m 才为山
-- 形态层（与 RR 8 类同名同契约；低地/隆起分界复用任务2 的 100m 门槛，
-- 真实 DEM 下平原格间高差极小，50m 会把整张西伯利亚/华北平原刷成隆起）。
local RR_EA_RISE_MIN_DIFF = 100;
local RR_EA_ALPINE_SNOW_MIN_ELEV = 2800;	-- ≥2800m 形态一律主脊（雪线主脊换肤照常消费）

-- 气候分类（与 RR_EastAsiaData.lua 生成器的 0..7 编码一一对应）：
-- 0 荒漠 / 1 草原 / 2 森林(季风) / 3 泰加 / 4 苔原 / 5 极地雪
-- 6 高山苔原 / 7 高山雪线。地形壳映射见 RR_EastAsia_GenerateTerrain。
local RR_EA_CLIMATE_TERRAIN = nil; -- 惰性建于首次调用（读 g_TERRAIN_TYPE_* 全局）

-- 主要河系折线点列（source→mouth，经纬度；name = RR_EA_RIVER_NAMES 键或 nil）。
-- 编纂依据：真实河道在 0.6° 网格下的可辨识走线（学习笔记 §4 附走向）。
-- 下游由 RR 分级逻辑 reused 决定哪些河段转水面（连通 ≥8 格且通海 → R2+）。
local RR_EA_RIVER_NAMES = {
	"NAMED_RIVER_RR_YANGTZE", "NAMED_RIVER_RR_YELLOWRIVER",
	"NAMED_RIVER_RR_AMUR", "NAMED_RIVER_RR_MEKONG",
	"NAMED_RIVER_RR_SALWEEN", "NAMED_RIVER_RR_BRAHMAPUTRA",
	"NAMED_RIVER_RR_INDUS", "NAMED_RIVER_RR_GANGES",
	"NAMED_RIVER_RR_PEARL", "NAMED_RIVER_RR_AMUDARYA",
	"NAMED_RIVER_RR_IRRAWADDY", "NAMED_RIVER_RR_REDRIVER",
};
local RR_EA_RIVERS = {
	{name = "NAMED_RIVER_RR_YANGTZE", pts = {
		{91.0, 33.2}, {94.0, 32.8}, {97.0, 31.2}, {99.5, 28.8}, {102.0, 28.5},
		{104.5, 28.5}, {106.5, 29.3}, {108.0, 30.4}, {110.0, 30.6}, {112.0, 30.4},
		{112.8, 29.7}, {114.3, 30.6}, {116.5, 29.9}, {117.9, 30.5}, {119.5, 31.5},
		{121.0, 31.6}}},
	{name = "NAMED_RIVER_RR_YELLOWRIVER", pts = {
		{96.0, 35.5}, {99.5, 36.5}, {101.5, 36.4}, {103.8, 36.1}, {105.5, 37.5},
		{106.8, 39.5}, {107.3, 40.6}, {109.5, 40.6}, {111.3, 40.3}, {110.8, 38.8},
		{110.4, 37.0}, {110.2, 35.2}, {110.3, 34.7}, {112.0, 34.9}, {113.6, 34.8},
		{115.0, 35.7}, {116.8, 36.4}, {118.0, 37.2}, {118.9, 37.7}}},
	{name = "NAMED_RIVER_RR_AMUR", pts = {
		{120.5, 53.8}, {124.0, 52.7}, {128.0, 51.3}, {131.5, 50.2}, {134.5, 48.6},
		{136.8, 47.2}, {138.8, 48.2}, {140.8, 50.0}, {141.6, 52.5}}},
	{name = "NAMED_RIVER_RR_MEKONG", pts = {
		{94.2, 33.2}, {95.5, 31.0}, {97.0, 28.5}, {99.0, 26.5}, {100.5, 24.5},
		{101.8, 21.5}, {103.2, 19.5}, {104.8, 17.5}, {105.8, 15.0}, {106.0, 12.5},
		{106.3, 10.3}}},
	{name = "NAMED_RIVER_RR_SALWEEN", pts = {
		{98.2, 28.5}, {98.4, 25.0}, {98.6, 21.0}, {98.8, 17.5}, {98.0, 14.5},
		{98.0, 11.5}}},
	{name = "NAMED_RIVER_RR_BRAHMAPUTRA", pts = {
		{82.0, 29.5}, {85.5, 28.0}, {89.0, 27.2}, {92.5, 27.3}, {95.0, 26.8},
		{94.0, 25.2}, {92.0, 24.0}, {90.3, 23.0}}},
	{name = "NAMED_RIVER_RR_INDUS", pts = { -- 三角洲在 68°E 以西，出图
		{81.5, 31.0}, {79.5, 32.0}, {77.0, 33.0}, {75.0, 32.0}, {72.5, 31.8},
		{70.5, 30.8}, {70.0, 29.0}, {70.0, 27.5}}},
	{name = "NAMED_RIVER_RR_GANGES", pts = {
		{79.3, 30.8}, {80.5, 28.8}, {82.5, 26.8}, {84.5, 25.8}, {86.5, 24.8},
		{88.5, 23.8}, {89.8, 22.2}}},
	{name = "NAMED_RIVER_RR_PEARL", pts = {
		{104.0, 24.8}, {106.0, 23.8}, {108.0, 23.5}, {110.0, 22.8}, {112.0, 22.5},
		{113.6, 22.6}}},
	{name = "NAMED_RIVER_RR_AMUDARYA", pts = {
		{72.5, 38.0}, {70.0, 38.0}, {67.5, 38.3}, {66.0, 40.0}, {64.5, 41.5},
		{62.5, 43.0}, {61.2, 44.8}}},
	{name = "NAMED_RIVER_RR_IRRAWADDY", pts = {
		{96.8, 26.2}, {95.8, 23.5}, {94.8, 21.5}, {95.0, 19.5}, {95.5, 17.5},
		{94.8, 15.8}}},
	{name = "NAMED_RIVER_RR_REDRIVER", pts = {
		{100.3, 23.8}, {101.5, 22.8}, {103.5, 21.8}, {105.0, 20.0}, {105.9, 17.5},
		{106.1, 15.0}, {106.5, 12.5}, {106.7, 10.4}}},
	-- 以下支流/次级河：name = nil（不参与专名分配，只补水系密度）。
	{name = nil, pts = { -- 渭河（黄河最大支流）
		{106.0, 34.5}, {108.5, 34.5}, {110.2, 34.6}}},
	{name = nil, pts = { -- 汾河
		{111.0, 36.5}, {111.5, 35.5}, {111.0, 34.8}}},
	{name = nil, pts = { -- 岷江
		{103.5, 30.5}, {104.5, 29.8}, {105.0, 28.9}}},
	{name = nil, pts = { -- 嘉陵江
		{105.8, 32.2}, {106.3, 30.8}, {106.6, 29.6}}},
	{name = nil, pts = { -- 汉江
		{107.8, 33.2}, {110.5, 32.5}, {112.2, 30.9}}},
	{name = nil, pts = { -- 湘江（入洞庭接长江）
		{111.3, 25.8}, {112.3, 27.3}, {112.9, 28.7}}},
	{name = nil, pts = { -- 赣江（入鄱阳接长江）
		{114.9, 25.9}, {115.6, 27.4}, {116.0, 28.8}}},
	{name = nil, pts = { -- 雅砻江
		{100.5, 27.8}, {102.5, 27.0}, {104.0, 28.2}}},
	{name = nil, pts = { -- 乌江
		{106.2, 27.3}, {107.0, 28.4}, {107.3, 29.4}}},
	{name = nil, pts = { -- 塔里木河（内流河，不出海）
		{75.5, 40.0}, {79.0, 40.8}, {83.0, 40.5}, {86.5, 40.8}, {89.5, 40.6}}},
	{name = nil, pts = { -- 伊犁河（西出图外，内流）
		{81.8, 42.8}, {79.0, 43.3}, {76.0, 43.8}, {73.5, 44.3}}},
	{name = nil, pts = { -- 雅穆纳河（恒河支流）
		{77.6, 30.6}, {77.8, 28.5}, {79.0, 27.0}, {80.5, 25.8}}},
	{name = nil, pts = { -- 戈达瓦里河（印度半岛）
		{73.8, 19.5}, {76.5, 17.5}, {79.5, 16.8}, {81.8, 16.9}}},
	{name = nil, pts = { -- 克里希纳河（印度半岛）
		{74.5, 17.2}, {76.5, 16.5}, {78.8, 16.2}, {80.9, 15.9}}},
	{name = nil, pts = { -- 湄南河（泰国）
		{99.0, 17.0}, {100.0, 14.5}, {100.5, 12.8}}},
	{name = nil, pts = { -- 淮河
		{112.5, 32.8}, {115.0, 32.6}, {117.5, 33.2}, {119.5, 34.2}}},
	{name = nil, pts = { -- 海河
		{114.0, 37.8}, {115.8, 38.4}, {117.5, 38.9}}},
	{name = nil, pts = { -- 辽河
		{119.8, 42.3}, {121.5, 41.3}, {122.2, 40.9}}},
};

local g_RR_eaRiverPlots = nil;	-- 栅格化记录：每河走过的 plot 索引表（命名用）

-------------------------------------------------------------------------------
-- 工具函数
-------------------------------------------------------------------------------

local function RR_EA_Clock()
	if os ~= nil and os.clock ~= nil then
		return os.clock();
	end
	return 0;
end

local function RR_EA_Probe(stageName, sinceClock)
	local now = RR_EA_Clock();
	print(string.format("[RRMap M9] %s (%.2fs)", stageName, now - sinceClock));
	return now;
end

-- 数据格网解码：base-90 双字符 → 米（与 tools/fetch_eastasia_dem.py 的
-- encode_elev 严格互逆：q=(b1-35)*90+(b2-35)，elev=q*20-8000）。
local function RR_EA_DecodeElev()
	local d = RR_EASTASIA_DATA;
	local out = {};
	local s = d.elev;
	for i = 1, d.w * d.h do
		local o = (i - 1) * 2;
		local b1, b2 = string.byte(s, o + 1), string.byte(s, o + 2);
		out[i] = ((b1 - 35) * 90 + (b2 - 35)) * 20 - 8000;
	end
	return out;
end

local function RR_EA_DecodeClimate()
	local d = RR_EASTASIA_DATA;
	local out = {};
	local s = d.climate;
	for i = 1, d.w * d.h do
		out[i] = string.byte(s, i) - 48;
	end
	return out;
end

-- 数据格网（120x78）→ 实际网格（当前即 120x78，恒等采样；函数保留双线性
-- 重采样以兜住非注册尺寸的加载）。fx/fy 为数据格网浮点坐标（0..w-1）。
local function RR_EA_Bilinear(grid, w, h, fx, fy)
	if fx < 0 then fx = 0; elseif fx > w - 1 then fx = w - 1; end
	if fy < 0 then fy = 0; elseif fy > h - 1 then fy = h - 1; end
	local x1 = math.floor(fx);
	local y1 = math.floor(fy);
	local x2 = math.min(x1 + 1, w - 1);
	local y2 = math.min(y1 + 1, h - 1);
	local dx = fx - x1;
	local dy = fy - y1;
	return grid[y1 * w + x1 + 1] * (1 - dx) * (1 - dy)
		+ grid[y1 * w + x2 + 1] * dx * (1 - dy)
		+ grid[y2 * w + x1 + 1] * (1 - dx) * dy
		+ grid[y2 * w + x2 + 1] * dx * dy;
end

-- 网格格心 → 数据格网坐标。
local function RR_EA_PlotToData(x, y, w, h)
	local fx = (x + 0.5) / w * RR_EA_DATA_W - 0.5;
	local fy = (y + 0.5) / h * RR_EA_DATA_H - 0.5;
	return fx, fy;
end

-- 经纬度 → 最近网格格心索引。出界时钳到最近边列/边行（-1 仅在钳后
-- 仍无合法格时返回）：河流出图（印度河三角洲西界外、伊犁河入巴尔喀什）
-- 应贴着图边走完，而不是中途消失。
local function RR_EA_LonLatToPlot(lon, lat, w, h)
	local fx = (lon - RR_EA_LON0) / RR_EA_DW - 0.5;
	local fy = (RR_EA_LATN - lat) / RR_EA_DH - 0.5;
	local x = math.floor(fx + 0.5);
	local y = math.floor(fy + 0.5);
	if x < 0 then x = 0; elseif x >= w then x = w - 1; end
	if y < 0 then y = 0; elseif y >= h then y = h - 1; end
	return y * w + x;
end

-------------------------------------------------------------------------------
-- GetMapInitData：关闭东西卷轴（WrapX=false）。
-- 理由（M9）：本图是区域图（70°E 印度河 — 145°E 西太平洋），东西接缝
-- 横跨 75° 经度，卷轴会把太平洋东缘接到印度西岸，海陆/河流全错位。
-- 官方先例：InlandSea.lua / Tilted_Axis.lua 同款（WrapX=false），
-- 宽高仍读 GameInfo.Maps 行（MAPSIZE_RR_STD10 = 120x78 已注册）。
-- M0 曾对 RR_Continents 禁用本函数（引擎走 Maps 表读宽高），本图需要
-- WrapX 开关故按官方范式恢复定义。
-------------------------------------------------------------------------------
function GetMapInitData(MapSize)
	local Width = 0;
	local Height = 0;
	for row in GameInfo.Maps() do
		if (MapSize == row.Hash) then
			Width = row.GridWidth;
			Height = row.GridHeight;
		end
	end
	local WrapX = false;
	return {Width = Width, Height = Height, WrapX = WrapX,};
end

-------------------------------------------------------------------------------
-- M9 阶段1：真实 DEM → plotTypes + g_RR_elevation（全局契约表，1-based）。
-- 地块类型双判据（学习笔记 §1）：
--   海拔 ≥2800m            → 山地（青藏高原/帕米尔/喜马拉雅主体）
--   700~2800m 且局部起伏≥600m → 山地（天山/昆仑/阿尔泰/日本阿尔卑斯底）
--   700~2800m 且起伏 <600m → 丘陵（塔里木盆地缘、蒙古高原、云贵高原面）
--   200~700m               → 丘陵（山麓带）
--   0~200m                 → 平地（平原/盆地底）
--   <0                     → 海洋（真实海深：深海/浅海分界沿用 RR 阈值）
-- 局部起伏 = 5x5 邻域海拔 max-min（≈190km 窗，与 0.6° 格网匹配）。
-------------------------------------------------------------------------------
function RR_EastAsia_GeneratePlots()
	print("Generating Plot Types (RR EastAsia real DEM)");
	local W, H = g_iW, g_iH;
	local n = W * H;
	local elevData = RR_EA_DecodeElev();

	-- 重采样到实际网格（1-based 契约表 + 0-based 施工暂存共用一份）。
	local elev = {};
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local fx, fy = RR_EA_PlotToData(x, y, W, H);
			elev[y * W + x + 1] = RR_EA_Bilinear(elevData, RR_EA_DATA_W,
				RR_EA_DATA_H, fx, fy);
		end
	end

	-- 局部起伏（5x5 窗 max-min），只算陆地候选（海洋不需要）。
	local relief = {};
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local i = y * W + x + 1;
			local lo = nil;
			local hi = nil;
			for dy = -2, 2 do
				for dx = -2, 2 do
					local ax, ay = x + dx, y + dy;
					if ax >= 0 and ax < W and ay >= 0 and ay < H then
						local e = elev[ay * W + ax + 1];
						if lo == nil or e < lo then lo = e; end
						if hi == nil or e > hi then hi = e; end
					end
				end
			end
			relief[i] = (hi ~= nil and lo ~= nil) and (hi - lo) or 0;
		end
	end

	local plotTypes = {};
	local landCount = 0;
	local mountainCount = 0;
	local plateauHillCount = 0;
	for i0 = 0, n - 1 do
		local i = i0 + 1;
		local e = elev[i];
		local pt = g_PLOT_TYPE_OCEAN;
		if e >= RR_EA_PLOT_MOUNTAIN_MIN_ELEV then
			pt = g_PLOT_TYPE_MOUNTAIN;
			mountainCount = mountainCount + 1;
		elseif e >= 700 then
			if relief[i] >= RR_EA_PLOT_MOUNTAIN_MIN_RELIEF then
				pt = g_PLOT_TYPE_MOUNTAIN;
				mountainCount = mountainCount + 1;
			else
				pt = g_PLOT_TYPE_HILLS; -- 高原/盆地台地面
				plateauHillCount = plateauHillCount + 1;
			end
		elseif e >= RR_EA_PLOT_HILL_MIN_ELEV then
			pt = g_PLOT_TYPE_HILLS;
		elseif e >= 0 then
			pt = g_PLOT_TYPE_LAND;
		end
		plotTypes[i0] = pt;
		if pt ~= g_PLOT_TYPE_OCEAN then
			landCount = landCount + 1;
		end
	end

	-- 转全局契约表 + 施工临时地形（照 RR_Tectonics 第十遍先例：
	-- 水 OCEAN / 陆 DESERT，供 AreaBuilder 算面积；真实壳后续赋）。
	g_RR_elevation = {};
	g_RR_form = nil;
	for i0 = 0, n - 1 do
		g_RR_elevation[i0 + 1] = elev[i0 + 1];
		local pPlot = Map.GetPlotByIndex(i0);
		if plotTypes[i0] == g_PLOT_TYPE_OCEAN then
			TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_OCEAN);
		else
			TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_DESERT);
		end
	end
	AreaBuilder.Recalculate();

	print(string.format("[RRMap M9] DEM: 陆地 %d 格 (%.1f%%), 山 %d 格, 台地丘陵 %d 格",
		landCount, 100.0 * landCount / n, mountainCount, plateauHillCount));
	return plotTypes;
end

-------------------------------------------------------------------------------
-- M9 阶段2：编纂气候格网 → 地形壳（替代原版纬度分带 GenerateTerrainTypes）。
-- 水格：邻陆 → COAST，否则 OCEAN；陆格：气候分类 → GRASS/PLAINS/DESERT/
-- TUNDRA/SNOW（ApplyBaseTerrain 负责 +1 丘陵变体，机制同原版）。
-------------------------------------------------------------------------------
function RR_EastAsia_GenerateTerrain(plotTypes)
	print("Generating Terrain Types (RR EastAsia climate)");
	local W, H = g_iW, g_iH;
	if RR_EA_CLIMATE_TERRAIN == nil then
		RR_EA_CLIMATE_TERRAIN = {
			[0] = g_TERRAIN_TYPE_DESERT,	-- 荒漠
			[1] = g_TERRAIN_TYPE_PLAINS,	-- 草原
			[2] = g_TERRAIN_TYPE_GRASS,		-- 森林（季风/湿润）
			[3] = g_TERRAIN_TYPE_TUNDRA,	-- 泰加林
			[4] = g_TERRAIN_TYPE_TUNDRA,	-- 苔原
			[5] = g_TERRAIN_TYPE_SNOW,		-- 极地雪
			[6] = g_TERRAIN_TYPE_TUNDRA,	-- 高山苔原
			[7] = g_TERRAIN_TYPE_SNOW,		-- 高山雪线
		};
	end
	local climData = RR_EA_DecodeClimate();
	local terrainTypes = {};
	local zoneCounts = {};
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local i0 = y * W + x;
			local t;
			if plotTypes[i0] == g_PLOT_TYPE_OCEAN then
				-- 海岸判定：任一邻格为陆地（与 RR_ClassifyForm 水形态同语义）。
				t = g_TERRAIN_TYPE_OCEAN;
				for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
					local a = Map.GetAdjacentPlot(x, y, dir);
					if a ~= nil and not a:IsWater() then
						t = g_TERRAIN_TYPE_COAST;
						break;
					end
				end
			else
				local fx, fy = RR_EA_PlotToData(x, y, W, H);
				local c = RR_EA_Bilinear(climData, RR_EA_DATA_W, RR_EA_DATA_H,
					fx, fy);
				c = math.floor(c + 0.5);
				t = RR_EA_CLIMATE_TERRAIN[c] or g_TERRAIN_TYPE_GRASS;
				zoneCounts[c] = (zoneCounts[c] or 0) + 1;
			end
			terrainTypes[i0] = t;
		end
	end
	local parts = {};
	for c = 0, 7 do
		table.insert(parts, string.format("%d=%d", c, zoneCounts[c] or 0));
	end
	print("[RRMap M9] 气候地带: " .. table.concat(parts, " "));
	return terrainTypes;
end

-------------------------------------------------------------------------------
-- M9 阶段3：形态层（8 类名与下游契约不变；水形态直接复用 RR_ClassifyForm）。
-- 陆形态判据（真实地图修正版，学习笔记 §1/§2）：
--   ≥2800m → 主脊；其余山地地块 → 山地；200~700m → 山麓；
--   <200m 邻格高差 ≥100m → 隆起（任务2 同款门槛）；否则低地。
-- 不调用 RR_ApplyFoothills：该函数会把邻山平地强制改丘陵并覆写海拔为
-- 200~270m——真实 DEM 的海拔场是 ground truth，不允许被裙边逻辑破坏；
-- 邻山过渡已由"海拔+起伏"双判据在地块类型层表达。
-------------------------------------------------------------------------------
function RR_EastAsia_BuildForms()
	if g_RR_elevation == nil then
		print("[RRMap M9] WARNING: 形态层跳过——海拔场未生成");
		return;
	end
	local W, H = g_iW, g_iH;
	g_RR_form = {};
	local formCounts = {};
	local landForms = 0;
	local lowlandForms = 0;
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local i = y * W + x + 1;
			local pPlot = Map.GetPlot(x, y);
			local e = g_RR_elevation[i];
			local form;
			if pPlot:IsWater() then
				form = RR_ClassifyForm(e, true, RR_HasAdjacentLand(x, y), 0);
			elseif e >= RR_EA_ALPINE_SNOW_MIN_ELEV then
				form = "主脊";
			elseif pPlot:IsMountain() then
				form = "山地";
			elseif e >= 200 then
				form = "山麓";
			elseif RR_MaxNeighborElevDiff(x, y) >= RR_EA_RISE_MIN_DIFF then
				form = "隆起";
			else
				form = "低地";
			end
			g_RR_form[i] = form;
			formCounts[form] = (formCounts[form] or 0) + 1;
			if not pPlot:IsWater() then
				landForms = landForms + 1;
				if form == "低地" or form == "隆起" then
					lowlandForms = lowlandForms + 1;
				end
			end
		end
	end
	print("[RRMap M9] 形态分布: " .. RR_FormCountsToString(formCounts));
	if landForms > 0 then
		print(string.format("[RRMap M9] 低地指标: 低地+隆起 %d/%d 陆地格 (%.1f%%)",
			lowlandForms, landForms, 100.0 * lowlandForms / landForms));
	else
		print("[RRMap M9] WARNING: 全图无陆地——DEM 解码异常");
	end
end

-------------------------------------------------------------------------------
-- M9 阶段4：主要河系栅格化（折线点列 → 地块边缘河）。
-- 河沿模型照原版 DoRiver（RiversLakes.lua）的六向语义：
--   地块边 = W / NW / NE 三条边（TerrainBuilder.SetWOfRiver/NWOfRiver/
--   NEOfRiver），每条边两个合法流向：
--     W 边：NORTH / SOUTH（两端角邻格 = 本格 NW / SW 邻格）
--     NW 边：NORTHEAST / SOUTHWEST（两端 = 本格 NE / W 邻格）
--     NE 边：NORTHWEST / SOUTHEAST（两端 = 本格 NW / E 邻格）
--   流向由两端角邻格的海拔决定（水视为 -10000，取低者——河往低处流）。
-- 折线两点间走线：细密插值取最近格序列，非相邻格用限定步数 BFS 桥接
-- （只走陆地；遇水即截断——河已入海）。全程无随机数，确定性。
-------------------------------------------------------------------------------
local function RR_EA_DirectionTo(px, py, qx, qy)
	for d = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
		local a = Map.GetAdjacentPlot(px, py, d);
		if a ~= nil and a:GetX() == qx and a:GetY() == qy then
			return d;
		end
	end
	return -1;
end

-- BFS 桥接两段非相邻格（只穿陆地）；失败返回 nil（上游截断处理）。
local function RR_EA_Bridge(ax, ay, bx, by)
	local W, H = g_iW, g_iH;
	local startI = ay * W + ax;
	local goalI = by * W + bx;
	local prev = {};
	prev[startI] = startI;
	local q = {startI};
	local qh, qt = 1, 1;
	local visited = 1;
	while qh <= qt and visited < 900 do
		local cur = q[qh];
		qh = qh + 1;
		if cur == goalI then
			break;
		end
		local cx = cur % W;
		local cy = (cur - cx) / W;
		for d = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
			local a = Map.GetAdjacentPlot(cx, cy, d);
			if a ~= nil then
				local ai = a:GetY() * W + a:GetX();
				if prev[ai] == nil and not a:IsWater() then
					prev[ai] = cur;
					qt = qt + 1;
					q[qt] = ai;
					visited = visited + 1;
				end
			end
		end
	end
	if prev[goalI] == nil then
		return nil;
	end
	local path = {};
	local cur = goalI;
	while cur ~= startI do
		table.insert(path, 1, cur);
		cur = prev[cur];
	end
	return path;
end

-- 河口延拓：末格不邻水时，BFS 穿过陆地接到最近邻水格（返回补路后的序列）。
local function RR_EA_AdjacentToWater(idx)
	local W = g_iW;
	local x = idx % W;
	local y = (idx - x) / W;
	for d = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
		local a = Map.GetAdjacentPlot(x, y, d);
		if a ~= nil and a:IsWater() then
			return true;
		end
	end
	return false;
end

local function RR_EA_ExtendToWater(plots)
	if #plots == 0 or RR_EA_AdjacentToWater(plots[#plots]) then
		return plots;
	end
	local W = g_iW;
	local startI = plots[#plots];
	local prev = {};
	prev[startI] = startI;
	local q = {startI};
	local qh, qt = 1, 1;
	local best = nil;
	while qh <= qt and qt < 4000 do
		local cur = q[qh];
		qh = qh + 1;
		if RR_EA_AdjacentToWater(cur) then
			best = cur;
			break;
		end
		local cx = cur % W;
		local cy = (cur - cx) / W;
		for d = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
			local a = Map.GetAdjacentPlot(cx, cy, d);
			if a ~= nil then
				local ai = a:GetY() * W + a:GetX();
				if prev[ai] == nil and not a:IsWater() then
					prev[ai] = cur;
					qt = qt + 1;
					q[qt] = ai;
				end
			end
		end
	end
	if best == nil then
		return plots; -- 内流河/出图河：保持原样
	end
	local path = {};
	local cur = best;
	while cur ~= startI do
		table.insert(path, 1, cur);
		cur = prev[cur];
	end
	for _, p in ipairs(path) do
		table.insert(plots, p);
	end
	return plots;
end

-- 单步 p→q 设置共享边河沿（p、q 必须相邻）。
local g_RR_eaRiverID = 0;
local function RR_EA_SetRiverEdge(pi, qi)
	local W = g_iW;
	local px = pi % W;
	local py = (pi - px) / W;
	local qx = qi % W;
	local qy = (qi - qx) / W;
	local d = RR_EA_DirectionTo(px, py, qx, qy);
	if d < 0 then
		return false;
	end
	-- host = 承载该边的地块；kind = 边型（W/NW/NE）。
	local host, kind;
	local t1d1, t2d1; -- 两个端点角的第三邻格方向
	if d == DirectionTypes.DIRECTION_EAST then
		host = qi; kind = "W";
		t1d1 = DirectionTypes.DIRECTION_NORTHWEST; -- NW 角
		t2d1 = DirectionTypes.DIRECTION_SOUTHWEST; -- SW 角
	elseif d == DirectionTypes.DIRECTION_NORTHEAST then
		host = qi; kind = "NW";
		t1d1 = DirectionTypes.DIRECTION_NORTHEAST; -- NE 角
		t2d1 = DirectionTypes.DIRECTION_WEST;      -- W 角
	elseif d == DirectionTypes.DIRECTION_NORTHWEST then
		host = pi; kind = "NW";
		t1d1 = DirectionTypes.DIRECTION_NORTHEAST;
		t2d1 = DirectionTypes.DIRECTION_WEST;
	elseif d == DirectionTypes.DIRECTION_WEST then
		host = pi; kind = "W";
		t1d1 = DirectionTypes.DIRECTION_NORTHWEST;
		t2d1 = DirectionTypes.DIRECTION_SOUTHWEST;
	elseif d == DirectionTypes.DIRECTION_SOUTHWEST then
		host = qi; kind = "NE";
		t1d1 = DirectionTypes.DIRECTION_NORTHWEST; -- NW 角
		t2d1 = DirectionTypes.DIRECTION_EAST;      -- E 角
	else -- DIRECTION_SOUTHEAST
		host = qi; kind = "NW";
		t1d1 = DirectionTypes.DIRECTION_NORTHEAST;
		t2d1 = DirectionTypes.DIRECTION_WEST;
	end
	local hx = host % W;
	local hy = (host - hx) / W;
	local function cornerElev(dir)
		local a = Map.GetAdjacentPlot(hx, hy, dir);
		if a == nil then
			return nil;
		end
		if a:IsWater() then
			return -10000; -- 水角 = 下游方向
		end
		return g_RR_elevation[a:GetY() * W + a:GetX() + 1] or 0;
	end
	local e1, e2 = cornerElev(t1d1), cornerElev(t2d1);
	local pPlot = Map.GetPlotByIndex(host);
	if kind == "W" then
		local flow = FlowDirectionTypes.FLOWDIRECTION_NORTH;
		if e1 == nil or (e2 ~= nil and e2 < e1) then
			flow = FlowDirectionTypes.FLOWDIRECTION_SOUTH;
		end
		TerrainBuilder.SetWOfRiver(pPlot, true, flow, g_RR_eaRiverID);
	elseif kind == "NW" then
		local flow = FlowDirectionTypes.FLOWDIRECTION_NORTHEAST;
		if e1 == nil or (e2 ~= nil and e2 < e1) then
			flow = FlowDirectionTypes.FLOWDIRECTION_SOUTHWEST;
		end
		TerrainBuilder.SetNWOfRiver(pPlot, true, flow, g_RR_eaRiverID);
	else -- "NE"
		local flow = FlowDirectionTypes.FLOWDIRECTION_NORTHWEST;
		if e1 == nil or (e2 ~= nil and e2 < e1) then
			flow = FlowDirectionTypes.FLOWDIRECTION_SOUTHEAST;
		end
		TerrainBuilder.SetNEOfRiver(pPlot, true, flow, g_RR_eaRiverID);
	end
	return true;
end

-- 一条折线 → 连续地块序列 + 逐边落河。返回走过的 plot 索引表（0-based）。
local function RR_EA_RasterizeRiver(pts)
	local W, H = g_iW, g_iH;
	local walk = {};
	local function appendPlot(idx)
		if idx >= 0 and walk[#walk] ~= idx then
			table.insert(walk, idx);
		end
	end
	for k = 1, #pts - 1 do
		local a = RR_EA_LonLatToPlot(pts[k][1], pts[k][2], W, H);
		local b = RR_EA_LonLatToPlot(pts[k + 1][1], pts[k + 1][2], W, H);
		appendPlot(a);
		if b ~= a then
			-- 细密插值（0.33 格步长）取最近格序列。
			local ax, ay = a % W, (a - a % W) / W;
			local bx, by = b % W, (b - b % W) / W;
			local steps = math.ceil(math.max(math.abs(bx - ax), math.abs(by - ay)) * 3) + 1;
			for s = 1, steps - 1 do
				local t = s / steps;
				local x = math.floor(ax + (bx - ax) * t + 0.5);
				local y = math.floor(ay + (by - ay) * t + 0.5);
				appendPlot(y * W + x);
			end
			appendPlot(b);
		end
	end
	-- BFS 桥接相邻序列中的断点；穿水失败则截断。
	local plots = {};
	for k = 1, #walk do
		local idx = walk[k];
		if #plots == 0 then
			table.insert(plots, idx);
		else
			local prev = plots[#plots];
			if prev ~= idx then
				local px, py = prev % W, (prev - prev % W) / W;
				local ix, iy = idx % W, (idx - idx % W) / W;
				if RR_EA_DirectionTo(px, py, ix, iy) >= 0 then
					table.insert(plots, idx);
				else
					local bridge = RR_EA_Bridge(px, py, ix, iy);
					if bridge == nil then
						break; -- 无法桥接（越海/越障）：河流到此为止
					end
					for _, bi in ipairs(bridge) do
						table.insert(plots, bi);
					end
				end
			end
		end
	end
	-- 河口延拓：0.6° DEM 的海岸格心量化使河口距真实水面常差 1~3 格，
	-- 而 RR 分级的"通海"判据要求河道格邻水——从末格 BFS 到最近邻水格
	-- 接上（内流河找不到则保持原样，塔里木/阿姆/印度河正是如此）。
	plots = RR_EA_ExtendToWater(plots);
	-- 逐边落河（water plot 不画边，截断于末个陆格）。
	local drawn = 0;
	for k = 1, #plots - 1 do
		local p = Map.GetPlotByIndex(plots[k]);
		local q = Map.GetPlotByIndex(plots[k + 1]);
		if p:IsWater() or q:IsWater() then
			break;
		end
		if RR_EA_SetRiverEdge(plots[k], plots[k + 1]) then
			drawn = drawn + 1;
		end
	end
	return plots, drawn;
end

function RR_EastAsia_AddMajorRivers()
	local W, H = g_iW, g_iH;
	g_RR_eaRiverID = 0;
	g_RR_eaRiverPlots = {};
	local totalEdges = 0;
	for r, river in ipairs(RR_EA_RIVERS) do
		g_RR_eaRiverID = r; -- 每河独立 id（河系在引擎侧可区分，也便于调试日志）
		local plots, drawn = RR_EA_RasterizeRiver(river.pts);
		g_RR_eaRiverPlots[r] = plots;
		totalEdges = totalEdges + drawn;
		if drawn == 0 then
			print(string.format("[RRMap M9] WARNING: 河流 #%d (%s) 未画出任何河沿",
				r, tostring(river.name)));
		end
	end
	print(string.format("[RRMap M9] 主要河系: %d 条, 河沿 %d 段",
		#RR_EA_RIVERS, totalEdges));
end

-------------------------------------------------------------------------------
-- M9 阶段5：真实河名分配（长江/黄河/…，注册于 Data/RR_Rivers.xml M9 组）。
-- 理由（不复用 RR_AssignRiverNames）：其河名池是 RR_Continents 文件 local，
-- 且按流域规模盲配——东亚图要的是"这条折线就叫长江"的确定性指派。
-- 顺序：先支流后干流（表序即此序），汇流共享格由干流覆盖。
-- 原版 AddRivers 补画的支流保持无名（预期行为）。
-------------------------------------------------------------------------------
function RR_EastAsia_AssignRiverNames()
	if g_RR_eaRiverPlots == nil or g_RR_river == nil then
		print("[RRMap M9] WARNING: 河名分配跳过——栅格化记录或分级表缺失");
		return;
	end
	g_RR_riverName = {};
	local nameIndex = {};
	for i, n in ipairs(RR_EA_RIVER_NAMES) do
		nameIndex[n] = i;
	end
	local assigned = {};
	for r, river in ipairs(RR_EA_RIVERS) do
		local ni = river.name ~= nil and nameIndex[river.name] or nil;
		if ni ~= nil then
			local plots = g_RR_eaRiverPlots[r];
			if plots ~= nil then
				local cnt = 0;
				for _, p in ipairs(plots) do
					if (g_RR_river[p + 1] or 0) >= 1 then
						g_RR_riverName[p + 1] = ni;
						cnt = cnt + 1;
					end
				end
				assigned[ni] = cnt;
			end
		end
	end
	local parts = {};
	for ni, cnt in pairs(assigned) do
		table.insert(parts, string.format("%s=%d格", RR_EA_RIVER_NAMES[ni], cnt));
	end
	table.sort(parts);
	print("[RRMap M9] 河流命名: " .. table.concat(parts, " "));
	-- 理由：分级阶段已持久化过一次（含旧名池结果），此处按真实河名重写
	-- 名字表后再持久化一遍（等级/标记表值不变，重写无害）。
	RR_PersistRiverData();
end

-------------------------------------------------------------------------------
-- GenerateMap（东亚真实图主线；阶段探针 [RRMap M9] 前缀）。
-------------------------------------------------------------------------------
function GenerateMap()
	print("Generating East Asia Real Map (RR M9)");

	g_iW, g_iH = Map.GetGridSize();
	-- 理由（M9）：RR_Continents 的地块/形态阈值常量是文件 local，本图的地块
	-- 派生自真实 DEM（见 RR_EastAsia_GeneratePlots 双判据），不消费那些
	-- 常量；此处只对齐 sea_level 之类原版配置读取惯例（本图无海平面概念）。
	local rrStartClock = RR_EA_Clock();
	local rrStageClock = RR_EA_Probe(string.format("开始 %dx%d size=%s",
		g_iW, g_iH, tostring(Map.GetMapSize())), rrStartClock);

	-- 阶段1：真实 DEM 海陆 + 地块类型。
	plotTypes = RR_EastAsia_GeneratePlots();
	rrStageClock = RR_EA_Probe("真实DEM地块", rrStageClock);

	-- 阶段2：气候格网地形壳。
	terrainTypes = RR_EastAsia_GenerateTerrain(plotTypes);
	ApplyBaseTerrain(plotTypes, terrainTypes, g_iW, g_iH);

	AreaBuilder.Recalculate();
	TerrainBuilder.AnalyzeChokepoints();
	TerrainBuilder.StampContinents();
	-- 理由（M9）：AddTerrainFromContinents 旁路理由同 RR_Continents（陆内
	-- 随机撒丘陵破坏真实地形）；批量改动后统一重算。
	AreaBuilder.Recalculate();
	rrStageClock = RR_EA_Probe("地形", rrStageClock);

	-- 阶段3：形态层（真实 DEM 修正版判据）。
	RR_EastAsia_BuildForms();
	RR_ApplySnowRidge();	-- 复用：主脊（≥2800m）换雪线主脊具名卡
	RR_PersistElevation();	-- 复用：海拔场持久化（河流改水面前的 ground truth 快照）
	RR_PrintElevationSamples();
	rrStageClock = RR_EA_Probe("海拔/形态层", rrStageClock);

	-- 阶段4：河系。原版 AddRivers 先跑（它按 山>丘>平>水 的伪高程走水，
	-- 在真实地形上近似真实支流，补手工折线之外的密度）；再叠加主要河系
	-- 折线栅格化（保证长江/黄河/湄公河等必现且走线正确）。
	AddRivers();
	RR_EastAsia_AddMajorRivers();
	rrStageClock = RR_EA_Probe("河流", rrStageClock);

	-- 阶段5：大河分级（复用 RR：连通块 ≥8 格且通海 → R2+ 转水面/漫滩/
	-- 三角洲标记；内流河（塔里木/伊犁）保持边缘河——正是真实行为）。
	RR_ClassifyAndConvertRivers(plotTypes, terrainTypes);
	rrStageClock = RR_EA_Probe("大河分级", rrStageClock);

	-- 阶段6：真实河名 + Layer3 微地貌卡 + 矩阵地形（全部复用 RR）。
	RR_EastAsia_AssignRiverNames();
	RR_PlaceLayer3Features();
	RR_ApplyTerrainMatrix();
	rrStageClock = RR_EA_Probe("微地貌/矩阵地形", rrStageClock);

	AddFeatures();
	TerrainBuilder.AnalyzeChokepoints();

	print("Adding cliffs");
	AddCliffs(plotTypes, terrainTypes);
	rrStageClock = RR_EA_Probe("崖岸", rrStageClock);
	rrStageClock = RR_EA_Probe("火山(跳过:基线无独立火山阶段)", rrStageClock);

	-- 自然奇观数：照 RR_Continents 从 GameInfo.Maps 行读（MAPSIZE_RR_STD10
	-- 行 = 6），行缺失回落 5（原版默认）。
	local rrMapRow = GameInfo.Maps[Map.GetMapSize()];
	local rrNumNW = 5;
	if rrMapRow ~= nil and rrMapRow.NumNaturalWonders ~= nil
		and rrMapRow.NumNaturalWonders > 0 then
		rrNumNW = rrMapRow.NumNaturalWonders;
	end
	local nwGen = NaturalWonderGenerator.Create({numberToPlace = rrNumNW});

	AddFeaturesFromContinents();
	MarkCoastalLowlands();
	rrStageClock = RR_EA_Probe("特征", rrStageClock);

	local resourcesConfig = MapConfiguration.GetValue("resources");
	local startConfig = MapConfiguration.GetValue("start");
	local resGen = ResourceGenerator.Create({
		resources = resourcesConfig,
		START_CONFIG = startConfig,
	});
	rrStageClock = RR_EA_Probe("资源", rrStageClock);

	print("Creating start plot database.");
	local start_plot_database = AssignStartingPlots.Create({
		MIN_MAJOR_CIV_FERTILITY = 150,
		MIN_MINOR_CIV_FERTILITY = 50,
		MIN_BARBARIAN_FERTILITY = 1,
		START_MIN_Y = 15,
		START_MAX_Y = 15,
		START_CONFIG = startConfig,
	});
	rrStageClock = RR_EA_Probe("出生点", rrStageClock);

	local GoodyGen = AddGoodies(g_iW, g_iH);
	RR_EA_Probe(string.format("完成 总耗时=%.2fs", RR_EA_Clock() - rrStartClock),
		rrStageClock);
	RR_PrintFormStats();
end
