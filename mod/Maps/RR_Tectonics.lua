------------------------------------------------------------------------------
-- 文件:    RR_Tectonics.lua
-- 项目:    地大物博·真实地理（RRMap）—— M1 板块地壳生成（M1 补完里程碑）
-- 依据:    docs/M1-板块地壳生成-设计.md（2026-09-29 v1.0，所有者审阅中）
-- 职责:    板块种子 + Voronoi 归属 + 边界类型判定 + 地貌映射，输出新版
--          g_RR_elevation（海拔场，本文件生成）与 g_RR_form（形态层，
--          RR_Tectonics_BuildForms 生成，插入点同旧 RR_BuildElevationAndForms），
--          并直接产出 plotTypes 取代原版分形海陆。
-- 全局契约:
--   g_RR_elevation / g_RR_form 与旧版逐字段同构（[y*W+x+1] 1-based 表），
--   下游 M2~M8 已验收逻辑零改动消费（河系分级/微地貌/矩阵地形/海洋分级）。
--   新增数据层 g_RR_plateId / g_RR_boundaryType / g_RR_volcano——本轮无消费者，
--   供 M2 后资源地质亲和（策划案 4.2）与灾害标签（策划案 7.1）使用。
-- 确定性:
--   全部随机走 TerrainBuilder.GetRandomNumber（地图种子驱动），单次固定顺序
--   遍历，同种子可复现（调研 A 报告 4.5 同款论证）；不用 os/time/数学 hash。
-- 原版处置:
--   分形海陆完全旁路（InitFractal/Shift/中央裂谷/最大陆块拒绝循环/
--   ApplyTectonics/AddLonelyMountains 均不调用），取舍论证见设计文档 §6.2。
------------------------------------------------------------------------------

-- 参数区（设计文档 §3~§5；调参先看 docs/M1-板块地壳生成-设计.md §8 对照表）
local RR_TEC_PLATE_COUNT = 9;			-- 板块总数（设计基调：8~10 张）
local RR_TEC_CONTINENTAL_MAJOR = 1;		-- 泛大陆级板块数（continental）
local RR_TEC_CONTINENTAL_MED = 2;		-- 中陆块板块数（continental）
										-- 其余 = 大洋板块（oceanic）
-- 海岸线分形破碎参数（第六遍半；根因与判读见该遍注释；近似仿真整定）。
-- 原则：扰动只作用在海陆过渡带，板块归属与消亡边界骨架均不受扰动。
local RR_TEC_COAST_BAND = 4;			-- 过渡带初始带宽（到异类地壳的环数）
local RR_TEC_COAST_BAND_MAX = 8;		-- 带宽上限（回调顶格缺水时逐步加宽到此）
local RR_TEC_COAST_OCTAVES = 4;		-- 分形噪声倍频数（波长 ~W/4 递减至 ~W/28）
local RR_TEC_COAST_T_OL = 0.00;		-- 洋侧成陆阈值基准：噪声 > 此值 → 半岛/岛链
local RR_TEC_COAST_T_LO = 0.10;		-- 陆侧成海阈值基准：噪声 < −此值 → 海湾/溺谷
										-- （回调只压低洋侧阈值，陆侧恒定——carving
										-- 不随陆海比回调消失；基准差即净造陆倾向）
local RR_TEC_COAST_T_SLOPE = 0.18;	-- 阈值随带内距离递增速率：紧贴边界扰动最强，带边缘归零
local RR_TEC_P_CONVERGENT = 45;			-- 消亡边界 roll 概率（%）
local RR_TEC_P_DIVERGENT = 30;			-- 生长边界 roll 概率（%）；转换 = 余数
local RR_TEC_BELT_LLL = 2;				-- 陆陆消亡：山系两侧丘陵裙边环数
local RR_TEC_BELT_OCL = 1;				-- 海陆消亡：陆侧丘陵裙边环数
local RR_TEC_SHELF_RINGS = 3;			-- 大陆架膨胀环数（陆块向洋 2~4 格）
local RR_TEC_CORE_NEIGHBORS = 3;		-- 主脊链核：山邻格 ≥3 抬升 >2800m
local RR_TEC_HOTSPOTS_MIN = 2;			-- 热点数 roll 下界
local RR_TEC_HOTSPOTS_MAX = 4;			-- 热点数 roll 上界

-- 运行期状态（单次建图，Generate 时赋值；全局表见文件头"全局契约"）
local gTecW = 0;
local gTecH = 0;

-- 边界类型枚举（g_RR_boundaryType 的值域）
local RR_TEC_BOUNDARY_NONE = 0;
local RR_TEC_BOUNDARY_CONVERGENT = 1;	-- 消亡
local RR_TEC_BOUNDARY_DIVERGENT = 2;	-- 生长
local RR_TEC_BOUNDARY_TRANSFORM = 3;	-- 转换

local function RR_Tec_IsPolar(y, buffer)
	return y <= buffer or y >= gTecH - buffer - 1;
end

local function RR_Tec_ToroidalDx(dx)
	-- 理由（设计文档 §3.2）：x 方向环向回绕距离，板块横跨东西接缝时连续。
	local half = gTecW / 2;
	if dx > half then
		dx = gTecW - dx;
	elseif dx < -half then
		dx = -gTecW - dx;
	end
	return dx;
end

local function RR_Tec_ForEachNeighbor(x, y, fn)
	for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
		local a = Map.GetAdjacentPlot(x, y, dir);
		if a ~= nil then
			fn(a:GetX(), a:GetY(), a:GetY() * gTecW + a:GetX());
		end
	end
end

-------------------------------------------------------------------------------
function RR_Tectonics_GeneratePlots(world_age)
	-- 理由（插入点见 RR_Continents.lua GeneratePlotTypes）：整体取代原版
	-- 分形海陆。返回 0-based plotTypes（与原版约定一致），并生成海拔场。
	print("Generating Plot Types (RR Tectonics)");
	local W, H = Map.GetGridSize();
	gTecW = W;
	gTecH = H;
	local n = W * H;
	local polarBuffer = math.floor(H / 13.0);

	-- 第一遍：确定性网格噪声（一次性预生成，服务 Voronoi 抖动与全图起伏）。
	-- 理由：固定顺序单次遍历，同种子可复现（文件头"确定性"论证）。
	local noise = {};
	for i = 0, n - 1 do
		noise[i] = TerrainBuilder.GetRandomNumber(1000, "RR Tec Noise") / 1000.0;
	end

	-- 第二遍：板块种子（设计文档 §3.1 配比：泛大陆级 1 + 中陆块 2 + 大洋 6；
	-- 小块由随机位置自然形成）。种子避开两极缓冲带。
	local plates = {};
	for p = 1, RR_TEC_PLATE_COUNT do
		local sx = TerrainBuilder.GetRandomNumber(W, "RR Tec Seed X");
		local sy = polarBuffer + 1 + TerrainBuilder.GetRandomNumber(
			H - 2 * polarBuffer - 2, "RR Tec Seed Y");
		local crust = "O";
		if p <= RR_TEC_CONTINENTAL_MAJOR + RR_TEC_CONTINENTAL_MED then
			crust = "C"; -- 前 N 张为陆壳（1 张 major + 2 张 med，同型不同体量由
						 -- Voronoi 位置自然区分——major 的实际体量优势 v1 不强制，
						 -- 见设计文档 §9 粗糙处 2）
		end
		plates[p] = {x = sx, y = sy, crust = crust, shields = {}};
	end
	-- 地盾：每张陆板 0~2 处古核（设计文档 §5.4 板内低地的唯一隆起来源之一）。
	for p = 1, RR_TEC_PLATE_COUNT do
		if plates[p].crust == "C" then
			local nShields = TerrainBuilder.GetRandomNumber(3, "RR Tec Shield Count");
			for s = 1, nShields do
				local cx = TerrainBuilder.GetRandomNumber(W, "RR Tec Shield X");
				local cy = polarBuffer + 1 + TerrainBuilder.GetRandomNumber(
					H - 2 * polarBuffer - 2, "RR Tec Shield Y");
				local r = 5 + TerrainBuilder.GetRandomNumber(6, "RR Tec Shield R");
				plates[p].shields[s] = {x = cx, y = cy, r = r};
			end
		end
	end

	-- 第三遍：Voronoi 归属（加权距离，设计文档 §3.2）。
	-- 根因记录：旧实现在此叠加抖动项 (noise[i]-0.5)*2*jitterAmp，但该项与候选
	-- 板块 p 无关——对所有候选是相同偏移，不改变 argmin，海岸线因此退化为笔直
	-- 的 Voronoi 边（用户实机截图确认）。海岸线破碎已移至第六遍半的过渡带
	-- 分形扰动实现（只改水/陆判定，板块归属保持本遍的原始 Voronoi 结果）。
	local plateOf = {}; -- 0-based plot index → 板块号 1..N
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local i = y * W + x;
			local bestP = 1;
			local bestScore = nil;
			for p = 1, RR_TEC_PLATE_COUNT do
				local dx = RR_Tec_ToroidalDx(x - plates[p].x);
				local dy = y - plates[p].y;
				local score = dx * dx + dy * dy;
				if bestScore == nil or score < bestScore then
					bestScore = score;
					bestP = p;
				end
			end
			plateOf[i] = bestP;
		end
	end

	-- 第四遍：边界格检测 + 板块对边界类型 roll（设计文档 §4）。
	-- pairType 懒 roll：扫描顺序固定 → 确定性；同对板块全图同型（v1 取舍，
	-- 设计文档 §9 粗糙处 1）。优先级：消亡 > 生长 > 转换。
	local pairType = {};
	local boundaryType = {};	-- 0-based i → RR_TEC_BOUNDARY_*
	local boundaryPair = {};	-- 0-based i → 主导边界的板块对 key（大*256+小）
	local boundaryCount = {0, 0, 0, 0};
	local pairKeyOf = function(pa, pb)
		if pa < pb then return pa * 256 + pb; else return pb * 256 + pa; end
	end
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local i = y * W + x;
			if RR_Tec_IsPolar(y, polarBuffer) then
				boundaryType[i] = RR_TEC_BOUNDARY_NONE;
			else
				local selfP = plateOf[i];
				local bestT = RR_TEC_BOUNDARY_NONE;
				local bestKey = 0;
				RR_Tec_ForEachNeighbor(x, y, function(ax, ay, ai)
					local otherP = plateOf[ai];
					if otherP ~= selfP then
						local key = pairKeyOf(selfP, otherP);
						if pairType[key] == nil then
							local roll = TerrainBuilder.GetRandomNumber(100,
								"RR Tec Pair Type");
							if roll < RR_TEC_P_CONVERGENT then
								pairType[key] = RR_TEC_BOUNDARY_CONVERGENT;
							elseif roll < RR_TEC_P_CONVERGENT + RR_TEC_P_DIVERGENT then
								pairType[key] = RR_TEC_BOUNDARY_DIVERGENT;
							else
								pairType[key] = RR_TEC_BOUNDARY_TRANSFORM;
							end
						end
						local t = pairType[key];
						if bestT == RR_TEC_BOUNDARY_NONE or t < bestT then
							bestT = t;
							bestKey = key;
						end
					end
				end);
				boundaryType[i] = bestT;
				boundaryPair[i] = bestKey;
				if bestT ~= RR_TEC_BOUNDARY_NONE then
					boundaryCount[bestT] = boundaryCount[bestT] + 1;
				end
			end
		end
	end

	-- 第五遍：地貌映射 → 海拔场 + plotTypes（设计文档 §5.1 总表）。
	local plotTypes = {};
	local elev = {}; -- 0-based 暂存；末尾转 1-based 全局表
	local landCount = 0;
	local convMountain = 0;
	local trenchCount = 0;
	local riftCount = 0;
	local islandCount = 0;
	local shieldHit = 0;
	local u = function(i) return noise[(i * 7 + 13) % n]; end -- 次级噪声相位
		-- 理由：同一 noise 表错相位复用，省一次随机遍历；不影响确定性。
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local i = y * W + x;
			local p = plateOf[i];
			local crustC = plates[p].crust == "C";
			local t = boundaryType[i];
			local e = 0;
			local pt = g_PLOT_TYPE_OCEAN;
			if RR_Tec_IsPolar(y, polarBuffer) then
				-- 极地缓冲带：沿用原版不变量强制海洋（纬度气候带的前提）。
				e = -3000 - 1500 * u(i);
			elseif t == RR_TEC_BOUNDARY_CONVERGENT then
				local pa = math.floor(boundaryPair[i] / 256);
				local pb = boundaryPair[i] % 256;
				local ca = plates[pa].crust == "C";
				local cb = plates[pb].crust == "C";
				if ca and cb then
					-- 陆陆消亡 → 造山带（设计文档 §5.2：山脉严格沿消亡边界）。
					e = 1500 + 1200 * u(i);
					pt = g_PLOT_TYPE_MOUNTAIN;
					convMountain = convMountain + 1;
				elseif ca ~= cb then
					if crustC then
						-- 俯冲带陆侧：海岸山链（安第斯型，宽度减半 §5.2）。
						e = 700 + 800 * u(i);
						pt = g_PLOT_TYPE_MOUNTAIN;
						convMountain = convMountain + 1;
					else
						-- 俯冲带洋侧：海沟（全图最深水）。
						e = -4500 - 800 * u(i);
						trenchCount = trenchCount + 1;
					end
				else
					-- 洋洋消亡（洋内俯冲，马里亚纳型）：海沟，无陆。
					e = -4000 - 800 * u(i);
					trenchCount = trenchCount + 1;
				end
			elseif t == RR_TEC_BOUNDARY_DIVERGENT then
				local pa = math.floor(boundaryPair[i] / 256);
				local pb = boundaryPair[i] % 256;
				local ca = plates[pa].crust == "C";
				local cb = plates[pb].crust == "C";
				if ca and cb then
					-- 陆内生长 → 裂谷低地（东非型；湖泊链留给 M2，§9 粗糙处 4）。
					e = 10 + 60 * u(i);
					pt = g_PLOT_TYPE_LAND;
					riftCount = riftCount + 1;
				elseif ca ~= cb then
					if crustC then
						e = 10 + 80 * u(i); -- 张裂海岸陆侧
						pt = g_PLOT_TYPE_LAND;
						riftCount = riftCount + 1;
					else
						e = -400 + 300 * u(i); -- 张裂海岸洋侧（幼海）
					end
				else
					-- 洋内生长 → 海岭浅海链（R5：−600~−150m，恒浅海形态）。
					e = -600 + 450 * u(i);
				end
			elseif t == RR_TEC_BOUNDARY_TRANSFORM then
				-- 转换边界：不改变形态（设计文档 §5.1），轻度起伏即可。
				if crustC then
					e = 30 + 100 * u(i);
					pt = g_PLOT_TYPE_LAND;
				else
					e = -2000 - 2000 * u(i);
				end
			else
				-- 板内（设计文档 §5.4 大片低地的机制保证）。
				if crustC then
					e = 20 + 130 * u(i); -- 地壳平原 20~150m
					pt = g_PLOT_TYPE_LAND;
					-- 地盾古核：平缓隆起 150~350m（不造山，只抬海拔）。
					for s = 1, #plates[p].shields do
						local sh = plates[p].shields[s];
						local dx = RR_Tec_ToroidalDx(x - sh.x);
						local dy = y - sh.y;
						if dx * dx + dy * dy <= sh.r * sh.r then
							e = 150 + 200 * u(i);
							if u(i) > 0.6 then
								pt = g_PLOT_TYPE_HILLS; -- 地盾面上的残丘
							end
							shieldHit = shieldHit + 1;
							break;
						end
					end
				else
					e = -2500 - 2500 * u(i); -- 洋盆 −2500~−5000m
				end
			end
			elev[i] = e;
			plotTypes[i] = pt;
			if pt ~= g_PLOT_TYPE_OCEAN then
				landCount = landCount + 1;
			end
		end
	end

	-- 第六遍：主脊链核（山邻格 ≥3 抬升 >2800m，设计文档 §5.2）。
	local ridgeCore = 0;
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local i = y * W + x;
			if plotTypes[i] == g_PLOT_TYPE_MOUNTAIN then
				local mtn = 0;
				RR_Tec_ForEachNeighbor(x, y, function(ax, ay, ai)
					if plotTypes[ai] == g_PLOT_TYPE_MOUNTAIN then
						mtn = mtn + 1;
					end
				end);
				if mtn >= RR_TEC_CORE_NEIGHBORS then
					elev[i] = 2800 + 700 * u(i); -- 主脊带（雪线换肤照常消费）
					ridgeCore = ridgeCore + 1;
				end
			end
		end
	end

	-- 第六遍半：海岸线分形破碎（修复"海岸线 = 笔直 Voronoi 边"的根因）。
	-- 原则（任务裁决）：扰动只作用在海陆过渡带——板块归属 g_RR_plateId 保持
	-- 第三遍的原始 Voronoi 结果不变，消亡边界的山脉骨架（MOUNTAIN 格）一律不
	-- 翻转，只改过渡带内的水/陆 plot type 判定：洋侧成半岛/岛链，陆侧成海湾/
	-- 溺谷。海沟/海岭/裂谷等边界地形格可翻转（岛弧、张裂海岸），其余不动。
	-- 噪声：RR_TEC_COAST_OCTAVES 个倍频的值噪声（双线性插值），采样自第一遍
	-- noise 表的错位相索引——不新增随机调用，下游随机流与修复前逐次一致
	-- （同种子的种子布局/边界 roll/热点位置全部不变），确定性论证同 u(i)。
	-- 过渡带：到异类地壳（C↔O）的环距 ≤ 带宽；极地缓冲带不入带（纬度气候带
	-- 前提保持，见 §3.1）。
	-- 翻转 + 陆海比回调（近似仿真整定，见提交记录）：coastBias 只压低洋侧成陆
	-- 阈值（陆侧成海阈值不随回调动，保证 carving 始终存在）；每次迭代从快照
	-- 重放（确定性），实测陆地占比落入 35~42% 即停；回调步长 0.025 阈值/百分点、
	-- 幅值 ±1.5、迭代 9 次；回调顶格仍缺水则说明该种子陆壳 Voronoi 面积极小、
	-- 过渡带容量不足——加宽过渡带（上限 RR_TEC_COAST_BAND_MAX）再试；仍不入
	-- 区间则告警并把调参口写进日志（§8 对照表口径）。
	local coastBias = 0.0;
	local peninsulaN = 0;
	local bayN = 0;
	local landPct = 0.0;
	do
		-- 分形噪声：倍频波长 ~W/4 递减至 ~W/28。权重取 1:0.6:0.4:0.28（偏蓝谱）：
		-- 细倍频有足够幅度把直边撕出碎湾/半岛岬角（仿真验证：棕噪声权重下
		-- 盒计数维数近似 D 仍贴 1.0，蓝谱权重升至 1.2~1.6）。
		local octSizes = {};
		local octWeights = {1.0, 0.6, 0.4, 0.28};
		local octNorm = 0;
		for o = 1, RR_TEC_COAST_OCTAVES do
			octSizes[o] = math.max(3, math.floor((W / 4) / (2 ^ (o - 1)) + 0.5));
			octNorm = octNorm + octWeights[o];
		end
		local function coastNoise(x, y)
			local f = 0;
			for o = 1, RR_TEC_COAST_OCTAVES do
				local s = octSizes[o];
				local lw = math.ceil(W / s) + 1; -- +1 列保证插值跨缝回绕
				local lh = math.ceil(H / s) + 1;
				local gx = x / s;
				local gy = y / s;
				local ix = math.floor(gx);
				local iy = math.floor(gy);
				local fx = gx - ix;
				local fy = gy - iy;
				local lat = function(ax, ay)
					-- 理由：格点值取 noise 表错位相（倍频/格点序数错开），
					-- 与 u(i) 同法，不消耗新的随机调用。
					return noise[(((ay % lh) * lw + (ax % lw)) * 131
						+ o * 977) % n];
				end
				f = f + octWeights[o]
					* (lat(ix, iy) * (1 - fx) * (1 - fy)
					+ lat(ix + 1, iy) * fx * (1 - fy)
					+ lat(ix, iy + 1) * (1 - fx) * fy
					+ lat(ix + 1, iy + 1) * fx * fy);
			end
			return (f / octNorm - 0.5) * 2.0; -- 归一到 [-1, 1]
		end

		-- 过渡带距离：多源 BFS，源 = 与异类地壳相邻的海岸格；极地带不入队不扩散。
		-- 做成函数：陆海比回调顶格缺水时按 RR_TEC_COAST_BAND_MAX 上限加宽带宽。
		local function tecCoastDist(band)
			local dist = {};
			local q = {};
			local h, t = 1, 0;
			for y = 0, H - 1 do
				for x = 0, W - 1 do
					local i = y * W + x;
					if not RR_Tec_IsPolar(y, polarBuffer) then
						local selfC = plates[plateOf[i]].crust == "C";
						local isCoast = false;
						RR_Tec_ForEachNeighbor(x, y, function(ax, ay, ai)
							if not isCoast
								and (plates[plateOf[ai]].crust == "C") ~= selfC then
								isCoast = true;
							end
						end);
						if isCoast then
							dist[i] = 0;
							t = t + 1;
							q[t] = i;
						end
					end
				end
			end
			while h <= t do
				local cur = q[h];
				h = h + 1;
				if dist[cur] < band then
					local cx = cur % W;
					local cy = (cur - cx) / W;
					RR_Tec_ForEachNeighbor(cx, cy, function(ax, ay, ai)
						if dist[ai] == nil
							and not RR_Tec_IsPolar(ay, polarBuffer) then
							dist[ai] = dist[cur] + 1;
							t = t + 1;
							q[t] = ai;
						end
					end);
				end
			end
			return dist;
		end

		-- 翻转 + 陆海比回调（说明见本遍头部注释）。
		local pt0 = {};
		local e0 = {};
		for i = 0, n - 1 do
			pt0[i] = plotTypes[i];
			e0[i] = elev[i];
		end
		local band = RR_TEC_COAST_BAND;
		local coastDist = tecCoastDist(band);
		for iter = 1, 9 do
			peninsulaN = 0;
			bayN = 0;
			landCount = 0;
			for i = 0, n - 1 do
				plotTypes[i] = pt0[i];
				elev[i] = e0[i];
			end
			for y = 0, H - 1 do
				for x = 0, W - 1 do
					local i = y * W + x;
					local d = coastDist[i];
					if d ~= nil and plotTypes[i] ~= g_PLOT_TYPE_MOUNTAIN then
						local ns = coastNoise(x, y);
						-- 阈值随带内距离递增：紧贴海岸处扰动最强，带边缘归零，
						-- 板内腹地与远洋深水不受任何影响。coastBias 只压低洋侧
						-- 阈值（多造陆），陆侧成海阈值恒定——carving 不随回调消失。
						local tOL = RR_TEC_COAST_T_OL + d * RR_TEC_COAST_T_SLOPE - coastBias;
						local tLO = RR_TEC_COAST_T_LO + d * RR_TEC_COAST_T_SLOPE;
						if plotTypes[i] == g_PLOT_TYPE_OCEAN and ns > tOL then
							-- 洋侧成陆：半岛头部 / 岛链（紧邻俯冲带者即岛弧）。
							plotTypes[i] = g_PLOT_TYPE_LAND;
							elev[i] = 10 + 110 * u(i); -- 滨海低地 10~120m
							peninsulaN = peninsulaN + 1;
						elseif plotTypes[i] ~= g_PLOT_TYPE_OCEAN and ns < -tLO then
							-- 陆侧成海：海湾 / 溺谷（浅海拔，后续陆棚遍自然接浅海圈）。
							plotTypes[i] = g_PLOT_TYPE_OCEAN;
							elev[i] = -40 - 160 * u(i); -- -40~-200m
							bayN = bayN + 1;
						end
					end
				end
			end
			for i = 0, n - 1 do
				if plotTypes[i] ~= g_PLOT_TYPE_OCEAN then
					landCount = landCount + 1;
				end
			end
			landPct = 100.0 * landCount / n;
			if landPct >= 35.0 and landPct <= 42.0 then
				break;
			end
			coastBias = coastBias + (38.5 - landPct) * 0.025;
			if coastBias > 1.5 then coastBias = 1.5; end
			if coastBias < -1.5 then coastBias = -1.5; end
			if landPct < 35.0 and coastBias >= 1.45 and band < RR_TEC_COAST_BAND_MAX then
				band = math.min(band + 2, RR_TEC_COAST_BAND_MAX);
				coastDist = tecCoastDist(band);
			end
		end
		if landPct < 35.0 or landPct > 42.0 then
			print(string.format("[RRMap M1-Tec] WARNING: 陆海比回调未入 35~42%% 区间"
				.. " (%.1f%%, bias=%.2f, 带宽=%d)——陆壳 Voronoi 面积极小的种子"
				.. " 过渡带容量不足，调 RR_TEC_COAST_T_OL/T_LO 或带宽上限",
				landPct, coastBias, band));
		end
	end

	-- 第七遍：山系裙边——陆陆消亡 2 环 / 海陆消亡 1 环内的板内平地改丘陵
	-- （设计文档 §5.2；与 RR_ApplyFoothills 的一格裙边叠加不冲突）。
	local skirtLLL = {};
	local skirtOCL = {};
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local i = y * W + x;
			if boundaryType[i] == RR_TEC_BOUNDARY_CONVERGENT then
				local pa = math.floor(boundaryPair[i] / 256);
				local pb = boundaryPair[i] % 256;
				local bothC = (plates[pa].crust == "C") and (plates[pb].crust == "C");
				-- 理由：只收 true 条目进种子集——BFS 用 pairs 遍历键，
				-- false 值条目会成为伪种子（海陆消亡格被陆陆裙边误收）。
				if bothC then
					skirtLLL[i] = true;
				else
					skirtOCL[i] = true;
				end
			end
		end
	end
	local skirted = 0;
	local function tecDilateSkirt(seedSet, rings)
		local dist = {};
		local q = {};
		local h, t = 1, 0;
		for i in pairs(seedSet) do
			dist[i] = 0;
			t = t + 1;
			q[t] = i;
		end
		while h <= t do
			local cur = q[h];
			h = h + 1;
			if dist[cur] < rings then
				local cx = cur % W;
				local cy = (cur - cx) / W;
				RR_Tec_ForEachNeighbor(cx, cy, function(ax, ay, ai)
					if dist[ai] == nil and plotTypes[ai] == g_PLOT_TYPE_LAND
						and boundaryType[ai] == RR_TEC_BOUNDARY_NONE then
						dist[ai] = dist[cur] + 1;
						t = t + 1;
						q[t] = ai;
					end
				end);
			end
		end
		for i, d in pairs(dist) do
			if d > 0 and plotTypes[i] == g_PLOT_TYPE_LAND then
				plotTypes[i] = g_PLOT_TYPE_HILLS;
				if elev[i] < 200 then
					elev[i] = 200 + 150 * u(i); -- 山麓带 200~350m
				end
				skirted = skirted + 1;
			end
		end
	end
	tecDilateSkirt(skirtLLL, RR_TEC_BELT_LLL);
	tecDilateSkirt(skirtOCL, RR_TEC_BELT_OCL);

	-- 第八遍：大陆架——陆块向外 2~4 环的洋盆抬到 −100~−350m（§5.3），
	-- 保证海岸线外有浅海圈而非悬崖深海。
	local landSeeds = {};
	for i = 0, n - 1 do
		if plotTypes[i] == g_PLOT_TYPE_LAND and boundaryType[i] == RR_TEC_BOUNDARY_NONE then
			landSeeds[i] = true;
		end
	end
	local shelf = {};
	do
		local dist = {};
		local q = {};
		local h, t = 1, 0;
		for i in pairs(landSeeds) do
			dist[i] = 0;
			t = t + 1;
			q[t] = i;
		end
		while h <= t do
			local cur = q[h];
			h = h + 1;
			if dist[cur] < RR_TEC_SHELF_RINGS then
				local cx = cur % W;
				local cy = (cur - cx) / W;
				RR_Tec_ForEachNeighbor(cx, cy, function(ax, ay, ai)
					-- 理由：只穿过板内洋盆（boundary NONE）——海沟/海岭等
					-- 边界地形不受陆棚膨胀影响（否则俯冲带海沟会被抬浅）。
					if dist[ai] == nil and plotTypes[ai] == g_PLOT_TYPE_OCEAN
						and boundaryType[ai] == RR_TEC_BOUNDARY_NONE then
						dist[ai] = dist[cur] + 1;
						t = t + 1;
						q[t] = ai;
						if elev[ai] < -100 then
							elev[ai] = -100 - 250 * u(ai); -- 陆棚
							shelf[ai] = true;
						end
					end
				end);
			end
		end
	end

	-- 第九遍：热点火山（设计文档 §5.5；数据标记，不触发原版火山特征）。
	local nHot = RR_TEC_HOTSPOTS_MIN + TerrainBuilder.GetRandomNumber(
		RR_TEC_HOTSPOTS_MAX - RR_TEC_HOTSPOTS_MIN + 1, "RR Tec Hotspot Count");
	local volcanoLand = 0;
	local volcanoIsland = 0;
	g_RR_volcano = {};
	for k = 1, nHot do
		local hx = TerrainBuilder.GetRandomNumber(W, "RR Tec Hotspot X");
		local hy = polarBuffer + 2 + TerrainBuilder.GetRandomNumber(
			H - 2 * polarBuffer - 4, "RR Tec Hotspot Y");
		local hi = hy * W + hx;
		if boundaryType[hi] ~= RR_TEC_BOUNDARY_CONVERGENT then
			if plotTypes[hi] == g_PLOT_TYPE_OCEAN then
				-- 洋中热点 → 1 格火山岛（夏威夷型）。
				plotTypes[hi] = g_PLOT_TYPE_LAND;
				elev[hi] = 300 + 500 * u(hi);
				g_RR_volcano[hi + 1] = true;
				volcanoIsland = volcanoIsland + 1;
				islandCount = islandCount + 1;
				landCount = landCount + 1;
			elseif plotTypes[hi] ~= g_PLOT_TYPE_MOUNTAIN then
				-- 板内陆热点 → 火山丘（600~1200m）。
				plotTypes[hi] = g_PLOT_TYPE_HILLS;
				elev[hi] = 600 + 600 * u(hi);
				g_RR_volcano[hi + 1] = true;
				volcanoLand = volcanoLand + 1;
			end
		end
	end

	-- 第十遍：转 1-based 全局契约表（RR_Continents.lua 下游全程消费）。
	g_RR_elevation = {};
	g_RR_plateId = {};
	g_RR_boundaryType = {};
	for i = 0, n - 1 do
		g_RR_elevation[i + 1] = elev[i];
		g_RR_plateId[i + 1] = plateOf[i];
		g_RR_boundaryType[i + 1] = boundaryType[i];
	end

	-- 施工：临时地形（原版同款——陆 DESERT / 水 OCEAN，供 AreaBuilder 算面积），
	-- 真实地形壳由 GenerateTerrainTypes + ApplyBaseTerrain 后续按 plotTypes 赋。
	for i = 0, n - 1 do
		local pPlot = Map.GetPlotByIndex(i);
		if plotTypes[i] == g_PLOT_TYPE_OCEAN then
			TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_OCEAN);
		else
			TerrainBuilder.SetTerrainType(pPlot, g_TERRAIN_TYPE_DESERT);
		end
	end
	AreaBuilder.Recalculate();

	-- 探针（设计文档 §8 对照表；[RRMap M1-Tec] 前缀供 tuner 日志 grep）。
	local contPlates = RR_TEC_CONTINENTAL_MAJOR + RR_TEC_CONTINENTAL_MED;
	print(string.format("[RRMap M1-Tec] 板块: %d 张 (陆 %d/洋 %d), 极地缓冲 %d 行",
		RR_TEC_PLATE_COUNT, contPlates, RR_TEC_PLATE_COUNT - contPlates, polarBuffer));
	print(string.format("[RRMap M1-Tec] 边界: 总 %d 格, 消亡 %d 生长 %d 转换 %d",
		boundaryCount[1] + boundaryCount[2] + boundaryCount[3],
		boundaryCount[1], boundaryCount[2], boundaryCount[3]));
	print(string.format("[RRMap M1-Tec] 山链: 消亡边界山 %d 格 (主脊核 %d), 裙边丘陵 %d 格; 海沟 %d 格",
		convMountain, ridgeCore, skirted, trenchCount));
	local shelfN = 0;
	for _ in pairs(shelf) do shelfN = shelfN + 1; end
	print(string.format("[RRMap M1-Tec] 浅海: 陆棚 %d 格; 裂谷低地 %d 格; 生长边界(洋)浅海链见边界计数与形态分布",
		shelfN, riftCount));
	print(string.format("[RRMap M1-Tec] 热点火山: %d 个 (陆 %d/洋岛 %d, 岛 %d 格)",
		volcanoLand + volcanoIsland, volcanoLand, volcanoIsland, islandCount));
	print(string.format("[RRMap M1-Tec] 陆海: 陆地 %d 格 (%.1f%%), 地盾格 %d; 海岸扰动: 半岛/岛链 +%d, 海湾 -%d (bias=%.2f)",
		landCount, 100.0 * landCount / n, shieldHit, peninsulaN, bayN, coastBias));
	-- 海岸线分形探针（§8 增补；判读见下行注释与本节头部）。
	do
		-- 交界格 = 陆且至少一邻格为水的格；N1/N2 = 交界格 1/2 环膨胀内的格数。
		local coastSeed = {};
		local coastN = 0;
		for y = 0, H - 1 do
			for x = 0, W - 1 do
				local i = y * W + x;
				if plotTypes[i] ~= g_PLOT_TYPE_OCEAN then
					local touchesWater = false;
					RR_Tec_ForEachNeighbor(x, y, function(ax, ay, ai)
						if not touchesWater
							and plotTypes[ai] == g_PLOT_TYPE_OCEAN then
							touchesWater = true;
						end
					end);
					if touchesWater then
						coastSeed[i] = true;
						coastN = coastN + 1;
					end
				end
			end
		end
		local function tecDilateCount(seedSet, rings)
			local seen = {};
			local q = {};
			local h, t = 1, 0;
			for i in pairs(seedSet) do
				seen[i] = 0;
				t = t + 1;
				q[t] = i;
			end
			while h <= t do
				local cur = q[h];
				h = h + 1;
				if seen[cur] < rings then
					local cx = cur % W;
					local cy = (cur - cx) / W;
					RR_Tec_ForEachNeighbor(cx, cy, function(ax, ay, ai)
						if seen[ai] == nil then
							seen[ai] = seen[cur] + 1;
							t = t + 1;
							q[t] = ai;
						end
					end);
				end
			end
			return t; -- 入队总数 = rings 环内格数（含种子）
		end
		local n1 = tecDilateCount(coastSeed, 1);
		local n2 = tecDilateCount(coastSeed, 2);
		-- 分形维数近似（Minkowski 盒计数的一阶差商）：环带面积 A(r)=N(r)−N(r−1)
		-- 满足 A ∝ r^(1−D)，取两环之比 D ≈ 1 − ln(A2/A1)/ln2。
		-- 判读（近似指标，看趋势不看绝对值）：
		--   笔直 Voronoi 边：环带面积不随环距缩水，A2/A1 ≈ 1.0 → D ≈ 1.0；
		--   破碎自然海岸：边界更"充空间"，D 升至 ≈1.15~1.40。
		-- 主指标是交界格占比：巨大三角形直边图 <1.5%，破碎后应显著上升。
		local a1 = n1 - coastN;
		local a2 = n2 - n1;
		local coastDim = 1.0;
		if a1 > 0 and a2 > 0 then
			coastDim = 1.0 - math.log(a2 / a1) / math.log(2.0);
		end
		print(string.format("[RRMap M1-Tec] 海岸线: 交界格 %d (%.1f%%), 盒计数维数近似 D=%.2f (A2/A1=%.2f)",
			coastN, 100.0 * coastN / n, coastDim, a2 / a1));
	end
	print(string.format("[RRMap M1-Tec] world_age=%s 仅影响地形壳纬度细节（撒山已废，见设计文档 §6.2）",
		tostring(world_age)));
	return plotTypes;
end

-------------------------------------------------------------------------------
function RR_Tectonics_BuildForms()
	-- 理由（插入点 = 旧 RR_BuildElevationAndForms 位置，RR_Continents.lua
	-- GenerateMap 注释）：此时 plot 类型与地形均已定稿（ApplyBaseTerrain 后、
	-- 河流前）。形态分类复用 RR_ClassifyForm（阈值沿用 M8 调参值，函数本体
	-- 不动），只换数据源——从分形派生换成板块派生（设计文档 §6.1）。
	if g_RR_elevation == nil then
		print("[RRMap M1-Tec] WARNING: 形态层跳过——海拔场未生成");
		return;
	end
	local W, H = Map.GetGridSize();
	g_RR_form = {};
	local formCounts = {};
	local landForms = 0;
	local lowlandForms = 0;
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local i = y * W + x + 1; -- 1-based 契约
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
			if not isWater then
				landForms = landForms + 1;
				if form == "低地" or form == "隆起" then
					lowlandForms = lowlandForms + 1;
				end
			end
		end
	end

	-- 理由（探针，设计文档 §8）：形态分布 + R4 核心指标"低地占陆地比"。
	print("[RRMap M1-Tec] 形态分布: " .. RR_FormCountsToString(formCounts));
	if landForms > 0 then
		print(string.format("[RRMap M1-Tec] 低地指标: 低地+隆起 %d/%d 陆地格 (%.1f%%, 目标≥70%%)",
			lowlandForms, landForms, 100.0 * lowlandForms / landForms));
	else
		print("[RRMap M1-Tec] WARNING: 全图无陆地——板块配比或生成逻辑异常");
	end
end
