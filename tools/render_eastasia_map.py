#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""渲染 RR_EastAsiaData.lua（+ RR_EastAsia.lua 河系折线）为目验 PNG。

输出（tools/out/）：
  eastasia_map_120x78.png   精确 120×78 格（每格 1 像素，交付硬性产物）
  eastasia_map.png          6× 放大 + 地带/河流/标注（人工目验用）

渲染逻辑与 RR_EastAsia.lua 消费端一致：海拔双判据 + 邻陆海岸 + 气候地带表。
"""
import os
import re
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
plt.rcParams["font.sans-serif"] = ["Hei", "PingFang HK", "STHeiti",
                                   "Arial Unicode MS", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False
from matplotlib.path import Path
from matplotlib.patches import FancyArrow
from scipy.ndimage import maximum_filter, minimum_filter

ROOT = os.path.join(os.path.dirname(__file__), "..")
DATA_LUA = os.path.join(ROOT, "mod", "Maps", "RR_EastAsiaData.lua")
MAP_LUA = os.path.join(ROOT, "mod", "Maps", "RR_EastAsia.lua")
OUT_DIR = os.path.join(os.path.dirname(__file__), "out")
os.makedirs(OUT_DIR, exist_ok=True)

W, H = 120, 78
LON0, LATN = 70.0, 55.0
DLON = 0.625
DLAT = (LATN - 10.0) / H


def load_grid():
    src = open(DATA_LUA, encoding="utf-8").read()
    me = re.search(r'elev\s*=\s*"((?:[^"\\]|\\.)*)"', src)
    mc = re.search(r'climate\s*=\s*"([0-9]+)"', src)
    elev_s = me.group(1).replace("\\\\", "\\")
    clim_s = mc.group(1)
    elev = np.zeros((H, W))
    for i in range(W * H):
        o = i * 2
        q = (ord(elev_s[o]) - 35) * 90 + (ord(elev_s[o + 1]) - 35)
        elev[i // W, i % W] = q * 20 - 8000
    clim = np.array([int(c) for c in clim_s]).reshape(H, W)
    return elev, clim


def load_rivers():
    """从 RR_EastAsia.lua 抓 RR_EA_RIVERS 折线（name 可空）。"""
    src = open(MAP_LUA, encoding="utf-8").read()
    m = re.search(r"local RR_EA_RIVERS = \{(.*?)\n\};", src, re.S)
    body = m.group(1)
    rivers = []
    # 每条河流条目以 "}}}" 收尾（末点 + pts + entry 三层括号）
    for rm in re.finditer(r"pts = \{(.*?)\}\}\}", body, re.S):
        pts = [(float(a), float(b)) for a, b in
               re.findall(r"\{(\d+\.?\d*),\s*(\d+\.?\d*)\}", rm.group(1))]
        if len(pts) >= 2:
            rivers.append(pts)
    return rivers


def classify(elev):
    relief = maximum_filter(elev, size=5) - minimum_filter(elev, size=5)
    ptype = np.full(elev.shape, -1, dtype=int)  # -1海 0平 1丘 2台地丘 3山
    land = elev >= 0
    ptype[land & (elev >= 2800)] = 3
    ptype[land & (elev >= 700) & (elev < 2800) & (relief >= 600)] = 3
    ptype[land & (elev >= 700) & (elev < 2800) & (relief < 600)] = 2
    ptype[land & (elev >= 200) & (elev < 700)] = 1
    ptype[land & (elev < 200)] = 0
    return ptype


# 地形底色（陆）：按地带 0..7；海：邻陆 COAST 浅 / 深海深
ZONE_COLORS = {
    0: (0.88, 0.70, 0.36),   # 荒漠（沙橙，与草原拉开）
    1: (0.72, 0.74, 0.42),   # 草原
    2: (0.45, 0.68, 0.35),   # 森林
    3: (0.35, 0.52, 0.35),   # 泰加
    4: (0.60, 0.62, 0.58),   # 苔原
    5: (0.92, 0.92, 0.95),   # 极地雪
    6: (0.62, 0.60, 0.55),   # 高山苔原
    7: (0.97, 0.97, 1.00),   # 高山雪线
}
DEEP = (0.16, 0.30, 0.52)
COAST = (0.35, 0.58, 0.78)


def compose_img(ptype, clim):
    """地形底色合成（海/地带/丘陵压暗/山地），供 matplotlib 与 PIL 共用。"""
    img = np.zeros((H, W, 3))
    land_adj = maximum_filter((ptype >= 0).astype(int), size=3) > 0
    water = ptype < 0
    img[water & land_adj] = COAST
    img[water & ~land_adj] = DEEP
    for z, col in ZONE_COLORS.items():
        m = (ptype >= 0) & (clim == z)
        img[m] = col
    img[(ptype == 1)] *= 0.88          # 丘陵压暗
    img[(ptype == 2)] *= 0.94          # 台地丘陵
    img[(ptype == 3)] = np.minimum(img[(ptype == 3)] * 0.55, 1.0)  # 山地
    return img


def render(elev, clim, ptype, rivers, labels=True, scale=6):
    fig, ax = plt.subplots(figsize=(W * scale / 72, H * scale / 72),
                           dpi=72)
    img = compose_img(ptype, clim)
    ax.imshow(img, interpolation="nearest", origin="upper",
              extent=[LON0, LON0 + W * DLON, 10, LATN], aspect="auto")
    # 河流
    for pts in rivers:
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        ax.plot(xs, ys, color=(0.10, 0.45, 0.90), lw=1.6, alpha=0.9,
                solid_capstyle="round", zorder=5)
    if labels:
        LAB = [
            ("西伯利亚", 92, 52.5), ("蒙古高原", 108, 47), ("塔里木盆地", 85, 39.3),
            ("青藏高原", 88, 32.3), ("喜马拉雅", 88.5, 27.5), ("黄土高原", 109, 36.6),
            ("华北平原", 115.5, 37), ("四川盆地", 105.8, 30.5), ("云贵高原", 105, 25.4),
            ("东北平原", 126.5, 45), ("朝鲜半岛", 127.6, 37.6), ("日本列岛", 137.8, 36.2),
            ("台湾岛", 121, 23.4), ("吕宋岛", 120.8, 15.3), ("恒河平原", 84, 26.6),
            ("德干高原", 77.5, 17.5), ("长江", 112.5, 30.9), ("黄河", 107.5, 37.2),
            ("黑龙江", 128, 49.5), ("湄公河", 104.6, 13.2), ("印度河", 71.5, 30.5),
            ("渤海", 119.3, 38.5), ("黄海", 123.3, 36.3), ("东海", 124.5, 28.5),
            ("南海", 113.5, 16.5), ("日本海", 134.5, 40), ("孟加拉湾", 88, 15.5),
            ("泰国湾", 102, 9.5),
        ]
        for name, lon, lat in LAB:
            ax.text(lon, lat, name, ha="center", va="center", fontsize=8,
                    color=(0.05, 0.05, 0.15), zorder=6,
                    bbox=dict(boxstyle="round,pad=0.15", fc="white",
                              ec="none", alpha=0.55))
        for lon in range(75, 146, 10):
            ax.axvline(lon, color="k", lw=0.2, alpha=0.25)
            ax.text(lon, 10.4, "%d°E" % lon, fontsize=6, ha="center",
                    color="k", alpha=0.6)
        for lat in range(15, 56, 10):
            ax.axhline(lat, color="k", lw=0.2, alpha=0.25)
            ax.text(70.4, lat, "%d°N" % lat, fontsize=6, va="center",
                    color="k", alpha=0.6)
    ax.set_xlim(LON0, LON0 + W * DLON)
    ax.set_ylim(10, LATN)
    ax.set_xticks([])
    ax.set_yticks([])
    return fig


def save_exact_120x78(ptype, clim, rivers, path):
    """精确 120×78 像素 PNG（每格 1 像素）——交付硬性产物。
    河流按格网语义栅格化（沿折线走过的格子置河色，与游戏内
    RR_EA_RasterizeRiver 同款走法），避免 1px 直线走样成虚线。"""
    from PIL import Image
    img = (compose_img(ptype, clim) * 255).astype(np.uint8)
    RIV = np.array([26, 115, 230], dtype=np.uint8)
    for pts in rivers:
        for (a_lon, a_lat), (b_lon, b_lat) in zip(pts, pts[1:]):
            steps = int(max(abs(b_lon - a_lon) / DLON,
                            abs(b_lat - a_lat) / DLAT) * 2) + 1
            for s in range(steps + 1):
                t = s / steps
                lon = a_lon + (b_lon - a_lon) * t
                lat = a_lat + (b_lat - a_lat) * t
                x = int((lon - LON0) / DLON)
                y = int((LATN - lat) / DLAT)
                if 0 <= x < W and 0 <= y < H:
                    img[y, x] = RIV
    Image.fromarray(img, "RGB").save(path)
    print("written:", path, "%dx%d" % (W, H))


def main():
    elev, clim = load_grid()
    ptype = classify(elev)
    rivers = load_rivers()
    # 精确 120×78（无标注）
    save_exact_120x78(ptype, clim, rivers,
                      os.path.join(OUT_DIR, "eastasia_map_120x78.png"))
    # 放大带标注版
    fig = render(elev, clim, ptype, rivers, labels=True, scale=10)
    fig.savefig(os.path.join(OUT_DIR, "eastasia_map.png"),
                bbox_inches="tight", pad_inches=0.1)
    plt.close(fig)
    print("written:", os.path.join(OUT_DIR, "eastasia_map.png"))


if __name__ == "__main__":
    main()
