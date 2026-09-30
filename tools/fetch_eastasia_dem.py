#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""M9 东亚真实地图 DEM 抓取与编译工具。

数据源：AWS Open Data「Terrain Tiles」（Mapzen/Tilezen 项目）z6 Web-Mercator
GeoTIFF 瓦片（512x512 int16 米）。该数据集全球融合 SRTM（陆地）与 ETOPO1
（海底/补洞），公开免费。z6 全图 64x64 瓦片，本工具只下载覆盖
东经 70~145°、北纬 10~55° 的 14x11 块瓦片（约 20MB），双线性重采样到
120x78（= MAPSIZE_RR_STD10 网格），按 20m 步进量化 + base-90 双字符编码
（值域 -8000~+8800m），连同气候分类格网（1 字符/格）写入
mod/Maps/RR_EastAsiaData.lua。

同时渲染目验 PNG（海拔晕渲 + 主要河系折线）供人工核对海陆轮廓。

用法：python3 tools/fetch_eastasia_dem.py
输出：mod/Maps/RR_EastAsiaData.lua、docs/reviews/M9-easasia-dem.png
"""
import io
import math
import os
import sys
import urllib.request
import concurrent.futures as cf

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_LUA = os.path.join(ROOT, "mod", "Maps", "RR_EastAsiaData.lua")
OUT_PNG = os.path.join(ROOT, "docs", "reviews", "M9-eastasia-dem.png")

# ---- 地理范围（与 RR_EastAsia.lua 头注释严格一致）----
LON0, LON1 = 70.0, 145.0
LAT0, LAT1 = 55.0, 10.0          # 北→南
W, H = 120, 78                   # MAPSIZE_RR_STD10

ZOOM = 5                        # z5：40 块瓦片即可覆盖（分辨率仍 10 倍于目标网格）
NT = 2 ** ZOOM                   # 32
TILE = 512                       # geotiff 瓦片边长（像素）
URL = "https://s3.amazonaws.com/elevation-tiles-prod/geotiff/%d/%d/%d.tif"
CACHE = os.path.join(ROOT, "tools", ".dem_cache")


def lonlat_to_global_px(lon, lat):
    """经纬度 → z 级全局像素坐标（浮点，Web Mercator）。"""
    x = (lon + 180.0) / 360.0 * NT * TILE
    s = math.sin(math.radians(lat))
    y = (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * NT * TILE
    return x, y


def tile_range():
    x0 = int((LON0 + 180) / 360 * NT)
    x1 = int((LON1 + 180) / 360 * NT)
    _, y_top = lonlat_to_global_px(0, LAT0)     # 纬度大 = y 小
    _, y_bot = lonlat_to_global_px(0, LAT1)
    return x0, x1, int(y_top / TILE), int(y_bot / TILE)


def fetch(tx, ty):
    path = os.path.join(CACHE, "%d_%d.tif" % (tx, ty))
    if os.path.exists(path):
        with open(path, "rb") as f:
            data = f.read()
    else:
        url = URL % (ZOOM, tx, ty)
        for attempt in range(3):
            try:
                with urllib.request.urlopen(url, timeout=90) as r:
                    data = r.read()
                break
            except Exception:  # noqa: BLE001
                if attempt == 2:
                    raise
        os.makedirs(CACHE, exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
    im = Image.open(io.BytesIO(data))
    a = np.array(im).astype(np.float32)   # int16 → float32，米
    if a.shape != (TILE, TILE):
        raise ValueError("bad tile shape %s" % (a.shape,))
    return tx, ty, a


def build_grid():
    x0, x1, y0, y1 = tile_range()
    print("tiles x %d..%d, y %d..%d (%d 块)" % (x0, x1, y0, y1,
          (x1 - x0 + 1) * (y1 - y0 + 1)))
    grid = np.full(((y1 - y0 + 1) * TILE, (x1 - x0 + 1) * TILE), np.nan,
                   dtype=np.float32)
    with cf.ThreadPoolExecutor(max_workers=6) as ex:
        futs = [ex.submit(fetch, tx, ty) for ty in range(y0, y1 + 1)
                for tx in range(x0, x1 + 1)]
        done = 0
        for f in cf.as_completed(futs):
            tx, ty, a = f.result()
            gy, gx = (ty - y0) * TILE, (tx - x0) * TILE
            grid[gy:gy + TILE, gx:gx + TILE] = a
            done += 1
            if done % 20 == 0:
                print("  downloaded %d/%d" % (done, len(futs)))
    return grid, x0, y0


def sample_cell(grid, gx0, gy0, lon, lat):
    """对瓦片拼接网格做双线性采样。"""
    gx, gy = lonlat_to_global_px(lon, lat)
    fx, fy = gx - gx0, gy - gy0
    x1, y1 = int(fx), int(fy)
    dx, dy = fx - x1, fy - y1
    x2, y2 = min(x1 + 1, grid.shape[1] - 1), min(y1 + 1, grid.shape[0] - 1)
    v = (grid[y1, x1] * (1 - dx) * (1 - dy) + grid[y1, x2] * dx * (1 - dy)
         + grid[y2, x1] * (1 - dx) * dy + grid[y2, x2] * dx * dy)
    return float(v)


# ---- 气候分类（0..7，与 RR_EastAsia.lua 的 RR_EA_CLIMATE_* 常量一致）----
C_DESERT, C_STEPPE, C_FOREST, C_TAIGA, C_TUNDRA, C_SNOW = 0, 1, 2, 3, 4, 5
C_ALPINE_T, C_ALPINE_S = 6, 7

# 荒漠多边形（lon, lat 顶点序列，闭合）
DESERT_POLYS = [
    # 塔克拉玛干 + 巴丹吉林/腾格里（塔里木—阿拉善）
    [(74, 41.5), (80, 43.5), (88, 44.5), (95, 43), (98, 42), (96, 39.5),
     (90, 37.5), (84, 37), (78, 38)],
    # 戈壁（内蒙古中西部）
    [(96, 46.5), (104, 47.5), (112, 45.5), (116, 43), (112, 40.5),
     (105, 40.5), (100, 42.5)],
    # 卡拉库姆/克孜勒库姆（中亚）
    [(60, 44), (66, 44.5), (70, 42), (69, 38.5), (64, 38), (60, 40)],
    # 塔尔沙漠（印度西北部）
    [(69.5, 29.5), (74, 29.8), (76.5, 27.5), (75, 24.5), (71, 24.5),
     (69.5, 26.5)],
    # 柴达木盆地
    [(90, 39.5), (96, 39.5), (98, 37), (94, 36.5), (90, 37.5)],
]
# 半干旱草原覆盖（戈壁外围一圈等由纬度基线给出，不再单独多边形）


def in_poly(lon, lat, poly):
    inside = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > lat) != (yj > lat):
            xint = (xj - xi) * (lat - yi) / (yj - yi) + xi
            if lon < xint:
                inside = not inside
        j = i
    return inside


def climate(lon, lat, elev):
    # 海拔优先：高山苔原 / 高山雪线（青藏高原、帕米尔、天山、喜马拉雅）
    if elev >= 4600:
        return C_ALPINE_S
    if elev >= 3000:
        return C_ALPINE_T
    # 荒漠多边形
    for poly in DESERT_POLYS:
        if in_poly(lon, lat, poly):
            return C_DESERT
    # 纬度基线 + 海陆/季风格局
    if lat >= 51:
        return C_TAIGA                    # 西伯利亚泰加林南缘
    if lat >= 46:
        # 蒙古高原—中亚草原带（大兴安岭西麓西）
        return C_STEPPE
    if lat >= 33:
        # 东亚季风西界约 105°E（青藏高原东缘—大兴安岭），西为欧亚草原
        return C_FOREST if lon >= 105 else C_STEPPE
    if lat >= 25:
        # 华北—藏南—横断：东森林，西干（高原雨影，已被海拔/荒漠接管）；
        # 印度恒河平原（76~96°E, 22~30°N）属南亚季风区，同为森林
        if lon >= 98 or (76 <= lon <= 96 and lat <= 30):
            return C_FOREST
        return C_STEPPE
    # 南亚/东南亚季风区：总体湿润森林
    return C_FOREST


def encode_elev(v):
    q = int(round((v + 8000.0) / 20.0))
    q = max(0, min(840, q))
    return chr(35 + q // 90) + chr(35 + q % 90)


def main():
    grid, gx0, gy0 = build_grid()
    elev = np.zeros((H, W), dtype=np.float32)
    clim = np.zeros((H, W), dtype=np.int8)
    dlon = (LON1 - LON0) / W
    dlat = (LAT0 - LAT1) / H
    for iy in range(H):
        lat = LAT0 - (iy + 0.5) * dlat
        for ix in range(W):
            lon = LON0 + (ix + 0.5) * dlon
            e = sample_cell(grid, gx0 * TILE, gy0 * TILE, lon, lat)
            if not np.isfinite(e):
                e = -1000.0   # 缺数据按浅海处理
            elev[iy, ix] = e
            clim[iy, ix] = climate(lon, lat, e)

    # ---- 统计与 Lua 编码 ----
    land = (elev > 0).mean() * 100
    print("陆海比: %.1f%%  海拔范围: %.0f..%.0f m"
          % (land, elev.min(), elev.max()))
    enc_e = "".join(encode_elev(float(v)) for v in elev.flatten())
    enc_c = "".join(str(v) for v in clim.flatten())
    assert len(enc_e) == W * H * 2 and len(enc_c) == W * H

    # ---- 目验 PNG ----
    os.makedirs(os.path.dirname(OUT_PNG), exist_ok=True)
    img = np.zeros((H, W, 3), dtype=np.uint8)
    for iy in range(H):
        for ix in range(W):
            e = elev[iy, ix]
            c = clim[iy, ix]
            if e < 0:
                d = min(1.0, -e / 6000.0)
                img[iy, ix] = (30, int(60 + 100 * (1 - d)),
                               int(120 + 120 * (1 - d)))
            elif e >= 4600:
                img[iy, ix] = (250, 250, 255)
            elif e >= 3000:
                img[iy, ix] = (180, 170, 160)
            elif e >= 700:
                img[iy, ix] = (150, 120, 95)
            elif e >= 200:
                img[iy, ix] = (120, 160, 90)
            else:
                palette = {C_DESERT: (230, 205, 130), C_STEPPE: (200, 190, 110),
                           C_FOREST: (90, 160, 90), C_TAIGA: (60, 110, 70),
                           C_TUNDRA: (170, 170, 150), C_SNOW: (245, 245, 250),
                           C_ALPINE_T: (175, 165, 155),
                           C_ALPINE_S: (250, 250, 255)}
                img[iy, ix] = palette.get(int(c), (128, 128, 128))
    im = Image.fromarray(img).resize((W * 8, H * 8), Image.NEAREST)
    im.save(OUT_PNG)
    print("目验图: " + OUT_PNG)

    # ---- 写 Lua 数据文件 ----
    header = """------------------------------------------------------------------------------
-- 文件:    RR_EastAsiaData.lua
-- 项目:    地大物博·真实地理（RRMap）—— M9 东亚真实地图（数据层，机器生成）
-- 生成:    tools/fetch_eastasia_dem.py（数据源：AWS Open Data Terrain Tiles，
--          z5 Web-Mercator GeoTIFF，陆地 SRTM + 海底 ETOPO1 融合；经双线性
--          重采样至 0.625°x0.577°、20m 步进量化、base-90 双字符编码）
--          【请勿手改】重跑工具即可再生成；手改请在工具里改。
-- 范围:    东经 70~145°、北纬 10~55°，网格 120x78（北行 y=0）。
-- 契约:    RR_EASTASIA_DATA 全局表，RR_EastAsia.lua 消费：
--            elev    海拔字符串，W*H*2 字符（base-90 双字符/格，\n--                    值域 -8000~+8800m，步进 20m；字节 92 的反斜杠\n--                    在 Lua 字面量中已双写转义，解析后还原，解码无需\n--                    特殊处理）\n------------------------------------------------------------------------------
RR_EASTASIA_DATA = {
\tlon0 = 70.0, latNorth = 55.0,
\tdlon = 0.625, dlat = 0.57692307692308,
\tw = %d, h = %d,
\telev = "%s",
\tclimate = "%s",
};
"""
    # 理由：字符 92（'\\'）在 Lua 字符串字面量中必须双写，否则与后继字符
    # 组成转义序列（如 \n）破坏解码；Lua 解析器会把 \\ 还原为单个 \。
    enc_e_lua = enc_e.replace("\\", "\\\\")
    with open(OUT_LUA, "w", encoding="utf-8") as f:
        f.write(header % (W, H, enc_e_lua, enc_c))
    print("数据文件: %s (%d 字节)" % (OUT_LUA, os.path.getsize(OUT_LUA)))
    # 控制台速览：若干地标海拔抽查（验证数据合理性）
    probes = [("喜马拉雅", 84.0, 28.5), ("青藏高原", 88.0, 33.0),
              ("塔里木", 84.0, 40.0), ("四川盆地", 105.0, 30.0),
              ("长江口", 121.5, 31.5), ("华北平原", 116.5, 38.0),
              ("日本山地", 138.0, 36.0), ("西西伯利亚", 75.0, 54.0),
              ("日本海沟", 142.5, 38.0), ("恒河平原", 84.0, 26.0)]
    for name, lon, lat in probes:
        iy = int((LAT0 - lat) / dlat)
        ix = int((lon - LON0) / dlon)
        print("  %s (%g,%g): %.0f m 气候=%d"
              % (name, lon, lat, elev[iy, ix], clim[iy, ix]))
    return 0


if __name__ == "__main__":
    # 【已废弃】用户裁定放弃 DEM 真实数据方案：RR_EastAsiaData.lua 改为
    # tools/draw_eastasia_map.py 手工编纂。重跑本工具会覆盖手工格网——
    # 除非显式传 --force-dem，否则拒绝执行。
    if "--force-dem" not in sys.argv:
        sys.stderr.write(
            "[已废弃] DEM 方案已放弃，数据层由 tools/draw_eastasia_map.py "
            "手工编纂。\n如确需重建 DEM 基线，请显式加 --force-dem。\n")
        sys.exit(2)
    sys.exit(main())
