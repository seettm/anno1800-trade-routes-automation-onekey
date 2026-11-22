#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
打包 Release 压缩包。

产物: <mod 目录的上两级>/_build/TradeRoutesAutomation_OneKey_v<版本>.zip
结构: TradeRoutesAutomation_OneKey/modinfo.json
      TradeRoutesAutomation_OneKey/LICENSE
      TradeRoutesAutomation_OneKey/data/...

【为什么输出不在 mod 目录里】
2026-11-22 实测踩过的坑：把 zip 放在 <mod>/dist/ 下，游戏内置加载器会**递归扫描**，
把 zip 也当成一个 mod 加载（loader 日志里出现第二条
`Load ..._v1.9.7 (unversioned) from ...\dist\...zip`）。
结果是同一个 mod 被加载两遍、两份相同 GUID 的 Trigger（1475200100）互相冲突，
主脚本 _main.lua 干脆不执行 —— 表现为所有热键 require 失败、"按了没反应"。
所以输出目录必须在 mods 树之外，且脚本会主动拒绝写到 mod 目录内。

只打 modinfo.json + LICENSE + data/，不夹带 README、.git 等杂物。

用法:
    python tools/build_release.py
    python tools/build_release.py D:\\some\\out\\dir     # 或指定输出目录
"""

import json
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD_DIR_NAME = os.path.basename(ROOT)
INCLUDE_FILES = ["modinfo.json", "LICENSE"]
INCLUDE_DIRS = ["data"]

# 默认输出到 mod 目录的上两级（即 mods 的上一级），绝不落在 mods 树内
DEFAULT_OUT = os.path.abspath(os.path.join(ROOT, "..", "..", "_build"))


def read_version():
    with open(os.path.join(ROOT, "modinfo.json"), encoding="utf-8") as f:
        return json.load(f)["Version"]


def guard(out_dir):
    """输出目录一旦落在 mod 目录内，加载器会把 zip 当第二个 mod 加载。"""
    out_abs = os.path.abspath(out_dir)
    root_abs = os.path.abspath(ROOT)
    if out_abs == root_abs or out_abs.startswith(root_abs + os.sep):
        sys.exit(
            "[拒绝] 输出目录在 mod 目录内: {}\n"
            "       游戏加载器会把这个 zip 当成第二个 mod 加载，\n"
            "       两份相同 GUID 的 Trigger 冲突会导致主脚本不执行（热键全部失效）。\n"
            "       请改用 mod 目录之外的路径。".format(out_abs)
        )


def main():
    version = read_version()
    out_dir = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    guard(out_dir)
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, "{}_v{}.zip".format(MOD_DIR_NAME, version))

    if os.path.exists(out):
        os.remove(out)

    count = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name in INCLUDE_FILES:
            src = os.path.join(ROOT, name)
            if os.path.exists(src):
                z.write(src, "{}/{}".format(MOD_DIR_NAME, name))
                count += 1

        for d in INCLUDE_DIRS:
            base = os.path.join(ROOT, d)
            if not os.path.isdir(base):
                continue
            for dirpath, _dirnames, filenames in os.walk(base):
                for fn in filenames:
                    src = os.path.join(dirpath, fn)
                    rel = os.path.relpath(src, ROOT).replace("\\", "/")
                    z.write(src, "{}/{}".format(MOD_DIR_NAME, rel))
                    count += 1

    size = os.path.getsize(out)
    print("version : {}".format(version))
    print("output  : {}".format(out))
    print("files   : {}".format(count))
    print("size    : {:.2f} MB".format(size / 1024.0 / 1024.0))
    assert count > 0, "打包结果为空"
    return 0


if __name__ == "__main__":
    sys.exit(main())
