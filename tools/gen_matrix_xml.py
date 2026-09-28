#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RRMap M3 矩阵地形 XML 生成器。
从游戏原版 XML（Base + 风云变幻必需扩展）逐列提取壳地形行，生成
Data/RR_Terrains_Matrix.xml —— 14 个形态×地带具名地形卡 + 壳等价适地表。
"""
import xml.etree.ElementTree as ET
from pathlib import Path

CIV6 = Path("/Users/lyg/Library/Application Support/Steam/steamapps/common/"
            "Sid Meier's Civilization VI/Civ6.app/Contents/Assets")
BASE = CIV6 / "Base/Assets/Gameplay/Data"
E1 = CIV6 / "DLC/Expansion1/Data"
E2 = CIV6 / "DLC/Expansion2/Data"

OUT = Path(__file__).resolve().parent.parent / "mod/Data/RR_Terrains_Matrix.xml"

# ---------------------------------------------------------------- 壳地形提取
def parse_rows(path, section):
    tree = ET.parse(path)
    root = tree.getroot()
    sec = root.find(section)
    if sec is None:
        return []
    return [dict(r.attrib) for r in sec.findall("Row")]

# Terrains 表：壳地形属性列（逐列照抄的依据）
terrains = {r["TerrainType"]: r for r in parse_rows(BASE / "Terrains.xml", "Terrains")}
yields_by_terrain = {}
for r in parse_rows(BASE / "Terrains.xml", "Terrain_YieldChanges"):
    yields_by_terrain.setdefault(r["TerrainType"], []).append(r)
class_by_terrain = {}
for r in parse_rows(BASE / "Terrains.xml", "TerrainClass_Terrains"):
    class_by_terrain.setdefault(r["TerrainType"], []).append(r["TerrainClassType"])

# Resource_ValidTerrains：Base + 迭起兴衰(风云变幻必需) —— 去重
res_rows = []
seen = set()
for p in [BASE / "Resources.xml",
          E1 / "Expansion1_Resources.xml",
          E2 / "Expansion1_Resources.xml"]:
    for r in parse_rows(p, "Resource_ValidTerrains"):
        key = (r["ResourceType"], r["TerrainType"])
        if key not in seen:
            seen.add(key)
            res_rows.append(r)

# Feature_ValidTerrains：Base + 两个扩展（含自然奇观/地热/火山等全部行）
feat_rows = []
seen = set()
for p in [BASE / "Features.xml",
          E1 / "Expansion1_Features.xml",
          E2 / "Expansion2_Features.xml"]:
    for r in parse_rows(p, "Feature_ValidTerrains"):
        key = (r["FeatureType"], r["TerrainType"])
        if key not in seen:
            seen.add(key)
            feat_rows.append(r)

# ---------------------------------------------------------------- 矩阵定义
# (矩阵地形, LOC名, 壳地形)。壳决定 Terrains 属性列 / 产出 / 地形类 / 适地表。
MATRIX = [
    # 低地形态（平地壳）
    ("TERRAIN_RR_LOW_FOREST",  "TERRAIN_GRASS"),
    ("TERRAIN_RR_LOW_STEPPE",  "TERRAIN_PLAINS"),
    ("TERRAIN_RR_LOW_DESERT",  "TERRAIN_DESERT"),
    ("TERRAIN_RR_LOW_TUNDRA",  "TERRAIN_TUNDRA"),
    # 隆起形态（丘陵壳）
    ("TERRAIN_RR_RISE_FOREST", "TERRAIN_GRASS_HILLS"),
    ("TERRAIN_RR_RISE_STEPPE", "TERRAIN_PLAINS_HILLS"),
    ("TERRAIN_RR_RISE_DESERT", "TERRAIN_DESERT_HILLS"),
    ("TERRAIN_RR_RISE_TUNDRA", "TERRAIN_TUNDRA_HILLS"),
    # 山麓形态（丘陵壳）
    ("TERRAIN_RR_FOOT_FOREST", "TERRAIN_GRASS_HILLS"),
    ("TERRAIN_RR_FOOT_STEPPE", "TERRAIN_PLAINS_HILLS"),
    ("TERRAIN_RR_FOOT_DESERT", "TERRAIN_DESERT_HILLS"),
    ("TERRAIN_RR_FOOT_TUNDRA", "TERRAIN_TUNDRA_HILLS"),
    # 山地 / 雪线主脊
    # 理由（壳选型偏离记录）：策划案说"借 GRASS_HILLS 壳"，但丘陵壳 Hills="true"，
    # 按 ApplyFoothills 实证 SetTerrainType 会把 plot type 同步为丘陵，会把山脉降级；
    # 故照抄 GRASS_MOUNTAIN 属性列（原版全部 *_MOUNTAIN 行逐列同值，数值等价不破）。
    ("TERRAIN_RR_MOUNTAIN",    "TERRAIN_GRASS_MOUNTAIN"),
    ("TERRAIN_RR_RIDGE",       "TERRAIN_SNOW_MOUNTAIN"),
]

# 壳 → 由它派生的矩阵地形（适地表复制目标）
matrix_by_shell = {}
for m, shell in MATRIX:
    matrix_by_shell.setdefault(shell, []).append(m)

# RR_MOUNTAIN 额外补原版山地壳的地貌适地表（火山/珠峰/乞力马扎罗等自然奇观
# 只挂在 *_MOUNTAIN 地形上；不补则这些地貌在矩阵地形上山后静默丢失）。
MOUNTAIN_SHELLS = ["TERRAIN_GRASS_MOUNTAIN", "TERRAIN_PLAINS_MOUNTAIN",
                   "TERRAIN_DESERT_MOUNTAIN", "TERRAIN_TUNDRA_MOUNTAIN",
                   "TERRAIN_SNOW_MOUNTAIN"]
mountain_feats = []
seen = set()
# 理由：GRASS_MOUNTAIN 壳的常规复制已带给 RR_MOUNTAIN 一部分山地地貌
# （火山/珠峰等），并集补录时去重，避免重复行。
already = {r["FeatureType"] for r in feat_rows
           if r["TerrainType"] == "TERRAIN_GRASS_MOUNTAIN"}
for r in feat_rows:
    if r["TerrainType"] in MOUNTAIN_SHELLS:
        f = r["FeatureType"]
        if f not in seen and f not in already:
            seen.add(f)
            mountain_feats.append(f)

# ---------------------------------------------------------------- 生成 XML
L = []
A = L.append
A('<?xml version="1.0" encoding="utf-8"?>')
A('<!-- ============================================================================')
A('     RRMap M3 形态×地带具名矩阵地形（具名卡片化里程碑）。')
A('     生成器：tools/gen_matrix_xml.py（从游戏原版 XML 逐列提取，勿手改本文件）。')
A('     壳等价原则：每个矩阵地形的 Terrains 属性列 / Terrain_YieldChanges /')
A('     TerrainClass_Terrains / Resource_ValidTerrains / Feature_ValidTerrains')
A('     均照抄其壳地形；产出/移动力/魅力与壳逐值相等，本轮不改任何机制数值。')
A('     适地表复制来源：Base + Expansion1 + Expansion2（去重）；玛雅等可选')
A('     DLC 资源（MAIZE/HONEY 等）不复制——引用不存在资源类型有整表加载失败风险。')
A('     ============================================================================ -->')
A('<GameData>')
A('\t<Types>')
for m, _ in MATRIX:
    A(f'\t\t<Row Type="{m}" Kind="KIND_TERRAIN"/>')
A('\t</Types>')
A('\t<Terrains>')
for m, shell in MATRIX:
    attrs = dict(terrains[shell])
    attrs["TerrainType"] = m
    attrs["Name"] = f"LOC_{m}_NAME"
    cols = " ".join(f'{k}="{v}"' for k, v in attrs.items())
    A(f'\t\t<Row {cols}/>')
A('\t</Terrains>')
A('\t<Terrain_YieldChanges>')
for m, shell in MATRIX:
    for y in yields_by_terrain.get(shell, []):
        A(f'\t\t<Row TerrainType="{m}" YieldType="{y["YieldType"]}" YieldChange="{y["YieldChange"]}"/>')
A('\t</Terrain_YieldChanges>')
A('\t<TerrainClass_Terrains>')
for m, shell in MATRIX:
    for c in class_by_terrain.get(shell, []):
        A(f'\t\t<Row TerrainClassType="{c}" TerrainType="{m}"/>')
A('\t</TerrainClass_Terrains>')
A('\t<Resource_ValidTerrains>')
n_res = 0
for r in res_rows:
    for m in matrix_by_shell.get(r["TerrainType"], []):
        A(f'\t\t<Row ResourceType="{r["ResourceType"]}" TerrainType="{m}"/>')
        n_res += 1
A('\t</Resource_ValidTerrains>')
A('\t<Feature_ValidTerrains>')
n_feat = 0
for r in feat_rows:
    for m in matrix_by_shell.get(r["TerrainType"], []):
        A(f'\t\t<Row FeatureType="{r["FeatureType"]}" TerrainType="{m}"/>')
        n_feat += 1
for f in mountain_feats:
    A(f'\t\t<Row FeatureType="{f}" TerrainType="TERRAIN_RR_MOUNTAIN"/>')
    n_feat += 1
A('\t</Feature_ValidTerrains>')
A('</GameData>')

OUT.write_text("\n".join(L) + "\n", encoding="utf-8")

# ---------------------------------------------------------------- 统计
print(f"矩阵地形行: {len(MATRIX)}")
print(f"产出行: {sum(len(yields_by_terrain.get(s, [])) for _, s in MATRIX)}")
print(f"地形类行: {sum(len(class_by_terrain.get(s, [])) for _, s in MATRIX)}")
print(f"资源适地表复制行: {n_res}")
print(f"地貌适地表复制行(含 RR_MOUNTAIN 山地壳补录 {len(mountain_feats)}): {n_feat}")
print("\n各壳资源适地表行数:")
for shell, ms in matrix_by_shell.items():
    cnt = sum(1 for r in res_rows if r["TerrainType"] == shell)
    print(f"  {shell}: {cnt} 行 -> {', '.join(ms)}")
print("\nRR_MOUNTAIN 补录地貌:", ", ".join(mountain_feats))
missing = [f for f in ["FEATURE_FOREST"] ]
print("\n未复制的可选DLC资源行（玛雅包）: MAIZE/HONEY（引用不存在类型有整表失败风险，权衡放弃）")
