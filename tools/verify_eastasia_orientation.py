#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""方向铁律自检：RR_EastAsiaData.lua 的 y=0 行必须对应北纬 55°（图上方）。

背景（M9 教训）：上一版 DEM 方案在实机观察时南北翻转翻车。本脚本在铺设
任何手工数据之前先验证格网方向约定，并在数据生成后做地标断言——
青藏高原在图中南部、塔里木盆地在其北方、西伯利亚在顶部、恒河大低地在
西南角。任何一条失败都说明格网南北翻转或地标错位，禁止交付。

用法：python tools/verify_eastasia_orientation.py [RR_EastAsiaData.lua]
"""
import re
import sys

LON0, LATN, DLON = 70.0, 55.0, 0.625
DLAT = (55.0 - 10.0) / 78.0
W, H = 120, 78


def lonlat_to_cell(lon, lat):
    """与 RR_EastAsia.lua 的 RR_EA_LonLatToPlot 完全同式。"""
    fx = (lon - LON0) / DLON - 0.5
    fy = (LATN - lat) / DLAT - 0.5
    x = int(fx + 0.5)
    y = int(fy + 0.5)
    return max(0, min(W - 1, x)), max(0, min(H - 1, y))


def cell_lat(y):
    """行 y 的格心纬度（y=0 → 54.71°N，顶行必须是最北）。"""
    return LATN - (y + 0.5) * DLAT


def decode(path):
    src = open(path, encoding="utf-8").read()
    me = re.search(r'elev\s*=\s*"((?:[^"\\]|\\.)*)"', src)
    mc = re.search(r'climate\s*=\s*"([0-9]+)"', src)
    assert me and mc, "未找到 elev/climate 字段"
    elev_s = me.group(1).replace("\\\\", "\\")  # Lua 双写反斜杠还原
    clim_s = mc.group(1)
    assert len(elev_s) == W * H * 2, "elev 长度 %d != %d" % (len(elev_s), W * H * 2)
    assert len(clim_s) == W * H, "climate 长度 %d != %d" % (len(clim_s), W * H)
    elev = []
    for i in range(W * H):
        o = i * 2
        q = (ord(elev_s[o]) - 35) * 90 + (ord(elev_s[o + 1]) - 35)
        elev.append(q * 20 - 8000)
    return elev, [int(c) for c in clim_s]


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "mod/Maps/RR_EastAsiaData.lua"
    elev, clim = decode(path)

    fails = []

    def check(name, cond, detail):
        print(("PASS" if cond else "FAIL"), name, "-", detail)
        if not cond:
            fails.append(name)

    # 1) 行→纬度映射：顶行 55°N、底行 10°N
    check("顶行=北纬55°", abs(cell_lat(0) - 54.71) < 0.05,
          "y=0 格心 lat=%.2f" % cell_lat(0))
    check("底行=北纬10°N", abs(cell_lat(H - 1) - 10.29) < 0.05,
          "y=%d 格心 lat=%.2f" % (H - 1, cell_lat(H - 1)))

    def at(lon, lat):
        x, y = lonlat_to_cell(lon, lat)
        return elev[y * W + x], clim[y * W + x], x, y

    # 2) 地标方向：塔里木（39.5°N）必须比拉萨/藏南（30°N）更靠北（y 更小）
    _, _, _, y_tarim = at(85.0, 39.5)
    _, _, _, y_lhasa = at(91.0, 30.0)
    check("塔里木在藏南以北", y_tarim < y_lhasa,
          "塔里木 y=%d, 藏南 y=%d" % (y_tarim, y_lhasa))

    # 3) 西伯利亚泰加：顶部 8 行（≥49°N）陆地为低海拔（<1000m），不应是海
    top_land = sum(1 for y in range(8) for x in range(W)
                   if elev[y * W + x] > 0)
    check("西伯利亚顶行是陆地", top_land > 8 * W * 0.55,
          "顶部8行陆地 %d/960" % top_land)

    # 4) 最高海拔带（≥4500m）主体必须在北纬37°以南（喜马拉雅/喀喇昆仑），
    #     flipped 网格会把高海拔带甩到北方——"翻转探测器"
    hi = [i for i, e in enumerate(elev) if e >= 4500]
    if hi:
        frac_south = sum(1 for i in hi if cell_lat(i // W) < 37.0) / len(hi)
        check("主脊在图南部", frac_south > 0.6,
              "≥4500m %d格 北纬37°以南占%.0f%%" % (len(hi), frac_south * 100))
    else:
        check("主脊在图南部", False, "没有 ≥4500m 格——数据异常")

    # 5) 恒河大低地在西南角：低海拔陆地点 (85°E, 25°N) 存在且 <300m
    e_gan, c_gan, xg, yg = at(85.0, 25.0)
    check("恒河低地在西南角", 0 < e_gan < 300,
          "(85°E,25°N) elev=%d y=%d" % (e_gan, yg))

    # 6) 日本列岛在东缘中部：本州 (138°E, 36°N) 是陆地
    e_jp, _, _, yj = at(138.0, 36.0)
    check("本州在东缘", e_jp > 0, "(138°E,36°N) elev=%d y=%d" % (e_jp, yj))

    # 7) 渤海湾是海：(119°E, 39°N) 必须是水
    e_bh, _, _, _ = at(119.0, 39.0)
    check("渤海水域", e_bh < 0, "(119°E,39°N) elev=%d" % e_bh)

    print()
    if fails:
        print("方向自检失败 %d 项：%s —— 禁止交付" % (len(fails), ", ".join(fails)))
        sys.exit(1)
    print("方向自检全部通过（y=0 = 北纬55° = 图上方）")


if __name__ == "__main__":
    main()
