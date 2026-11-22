#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
打包 Release 压缩包。

产物: dist/TradeRoutesAutomation_OneKey_v<版本>.zip
结构: TradeRoutesAutomation_OneKey/modinfo.json
      TradeRoutesAutomation_OneKey/data/...

只打 modinfo.json + data/，不夹带 README、.git、dist 等杂物 ——
加载器虽然只读 modinfo，但减少目录内文件数可以避免各种玄学问题。

用法:
    python tools/build_release.py
"""

import json
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD_DIR_NAME = os.path.basename(ROOT)
INCLUDE_FILES = ["modinfo.json", "LICENSE"]
INCLUDE_DIRS = ["data"]


def read_version():
    with open(os.path.join(ROOT, "modinfo.json"), encoding="utf-8") as f:
        return json.load(f)["Version"]


def main():
    version = read_version()
    dist = os.path.join(ROOT, "dist")
    os.makedirs(dist, exist_ok=True)
    out = os.path.join(dist, "{}_v{}.zip".format(MOD_DIR_NAME, version))

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
