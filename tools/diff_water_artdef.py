#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""原版 Base Terrains.artdef 与 RR_Terrains.artdef 水地形条目全路径结构化 diff。
M7 调查工具：对每条目输出完整 XML 路径（含父链/集合名/元素名）下的叶值清单，
任何差异（值、路径缺失、元素数量）逐条列出。"""
import xml.etree.ElementTree as ET
import sys

VANILLA = "/Users/lyg/Library/Application Support/Steam/steamapps/common/Sid Meier's Civilization VI/Civ6.app/Contents/Assets/Base/ArtDefs/Terrains.artdef"
OURS = "/Users/lyg/Documents/Kimi/Workspaces/文明6/civ6mod/mod/ArtDefs/RR_Terrains.artdef"

def leaves(elem, path=""):
    """把元素树拍平为 {路径: 值}，路径含元素名与集合上下文。"""
    out = {}
    here = f"{path}/{elem.tag}"
    for k, v in elem.attrib.items():
        out[f"{here}@{k}"] = v
    text = (elem.text or "").strip()
    children = list(elem)
    if text and not children:
        out[here] = text
    for c in children:
        out.update(leaves(c, here))
    return out

def find_entry(root, name):
    for col in root.iter():
        cne = col.find("m_CollectionName") if col.tag == "Element" else None
        if cne is not None and cne.get("text") == "Terrain":
            for e in col.findall("Element"):
                nm = e.find("m_Name")
                if nm is not None and (nm.get("text") or nm.text) == name:
                    return e
    return None

def flatten_entry(entry):
    """条目内以子集合名为锚拍平：Audio/StrategicView/.../TerrainType/Entry 等。
    注意 artdef 结构：集合元素的子条目是 Element 的直接子节点（无
    m_ChildCollections 包裹），须遍历全部直接子 Element。"""
    out = {}
    def rec(elem, chain):
        if elem.tag != "Element":
            return
        cne, nme = elem.find("m_CollectionName"), elem.find("m_Name")
        step = (cne.get("text") if cne is not None else None) or \
               (nme.get("text") if nme is not None else None) or "?"
        newchain = chain + [step]
        vals = elem.find("m_Fields/m_Values")
        if vals is not None:
            for v in vals.findall("Element"):
                pne = v.find("m_ParamName")
                pn = (pne.get("text") if pne is not None else None) or v.tag
                val = None
                for tag in ("m_Value", "m_ElementName"):
                    ve = v.find(tag)
                    if ve is not None and ve.get("text"):
                        val = ve.get("text")
                        break
                if val is None:
                    for tag in ("m_r", "m_g", "m_b", "m_nValue"):
                        ve = v.find(tag)
                        if ve is not None and (ve.text or "").strip():
                            val = (val or "") + f"{tag}={(ve.text or '').strip()};"
                out["/".join(newchain + [pn])] = val
        for c in elem:
            if c.tag == "Element":
                rec(c, newchain)
            else:
                # 非 Element 包裹节点（如 m_ChildCollections）下探一层找集合元素
                for gc in c:
                    if gc.tag == "Element":
                        rec(gc, newchain)
    nm = entry.find("m_Name")
    root = nm.get("text") if nm is not None else "?"
    # 从条目的子集合直接递归（不再以条目自身为步），避免根名在路径里出现两次
    for c in entry:
        if c.tag == "Element":
            rec(c, [root])
        elif c.tag == "m_ChildCollections":
            for gc in c:
                if gc.tag == "Element":
                    rec(gc, [root])
    return out

def main():
    vroot = ET.parse(VANILLA).getroot()
    oroot = ET.parse(OURS).getroot()
    pairs = [
        ("TERRAIN_COAST", "TERRAIN_RR_SHALLOW"),
        ("TERRAIN_COAST", "TERRAIN_RR_RIVER"),
        ("TERRAIN_OCEAN", "TERRAIN_RR_DEEPSEA"),
    ]
    for vname, oname in pairs:
        ve = find_entry(vroot, vname)
        oe = find_entry(oroot, oname)
        print(f"\n===== {vname} (原版)  vs  {oname} (RR) =====")
        if ve is None or oe is None:
            print("  条目缺失!", ve is None, oe is None)
            continue
        vf = flatten_entry(ve)
        of = flatten_entry(oe)
        # 归一化：路径首段是条目自身名（COAST vs RR_SHALLOW），比较前剥掉，
        # 否则两侧键永不相同，diff 失去意义。
        vf = {k.split("/", 1)[1]: v for k, v in vf.items() if "/" in k}
        of = {k.split("/", 1)[1]: v for k, v in of.items() if "/" in k}
        allk = sorted(set(vf) | set(of))
        ndiff = 0
        for k in allk:
            a, b = vf.get(k, "<缺失>"), of.get(k, "<缺失>")
            if a != b:
                ndiff += 1
                print(f"  DIFF {k}\n    原版: {a}\n    RR  : {b}")
        if ndiff == 0:
            print("  完全一致（全路径）")

if __name__ == "__main__":
    main()
