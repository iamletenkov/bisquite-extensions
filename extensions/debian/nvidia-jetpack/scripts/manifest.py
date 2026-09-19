#!/usr/bin/env python3
"""Манифесты пары: внутренний (в rootfs) и внешний (рядом с артефактами).

Хеш архива во ВНУТРЕННИЙ манифест не кладётся никогда: у Xavier пакет
загрузчика содержит rootfs (манифест должен был бы знать хеш архива, в
который входит сам), а tar.gz недетерминирован. Пара опознаётся по sha256
двоичных файлов загрузчика. Спека 2026-09-19-jetson-build-and-bootloader.md.

The "rootfs" object records where the system half came from. It is NOT part
of the pair: step 14 compares PROFILE_KEYS only, so AGX packages built before
this object existed stay valid, and the origin of the system has nothing to
do with flashing a bootloader. Spec 2026-09-19-jetson-nano-mixed-pair.md.
"""

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

PROFILE_KEYS = [
    "JETSON",
    "L4T",
    "SOC",
    "BOARD_TARGET",
    "BOARDID",
    "FAB",
    "BOARD_SKU",
    "BOARDREV",
    "BOOTLOADER_PACKAGE",
    "BSP_FILE",
    "BSP_SHA1",
]
ROOTFS_SOURCES = ("nvidia-bsp", "vendor-image")


def profile() -> dict:
    missing = [k for k in PROFILE_KEYS if not os.environ.get(k)]
    if missing:
        sys.exit("ОТКАЗ: профиль не загружен, нет " + ", ".join(missing))
    return {k.lower(): os.environ[k] for k in PROFILE_KEYS}


def rootfs() -> dict:
    source = os.environ.get("ROOTFS_SOURCE", "")
    if source not in ROOTFS_SOURCES:
        sys.exit(
            f"ОТКАЗ: ROOTFS_SOURCE={source!r}, ждали одно из: "
            + ", ".join(ROOTFS_SOURCES)
        )
    l4t = os.environ.get("ROOTFS_L4T", "")
    if not l4t:
        sys.exit("ОТКАЗ: ROOTFS_L4T пуст — профиль не загружен?")
    doc = {"source": source, "l4t": l4t}
    if source == "vendor-image":
        # The vendor's sum is the sum of the INPUT image, not of system.qcow2.
        sha = os.environ.get("VENDOR_IMG_SHA256", "")
        if len(sha) != 64:
            sys.exit("ОТКАЗ: у vendor-image нет VENDOR_IMG_SHA256 в профиле пары")
        doc["vendor_img_sha256"] = sha
    return doc


def read_hash_list(path: str) -> dict:
    files = {}
    for line in Path(path).read_text().splitlines():
        if not line.strip():
            continue
        digest, name = line.split(None, 1)
        files[name.strip().lstrip("*")] = digest
    if not files:
        sys.exit(f"ОТКАЗ: {path} пуст — пакет загрузчика не собран?")
    return files


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("kind", choices=["internal", "outer"])
    ap.add_argument("--bootloader-files", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--artifact", action="append", default=[])
    a = ap.parse_args()

    doc = {
        "schema": 1,
        "pair": profile(),
        "rootfs": rootfs(),
        "bootloader_files": read_hash_list(a.bootloader_files),
    }
    if a.kind == "internal":
        if a.artifact:
            sys.exit("ОТКАЗ: хеши архивов во внутренний манифест не кладутся")
    else:
        if not a.artifact:
            sys.exit("ОТКАЗ: внешнему манифесту нужны --artifact")
        doc["artifacts"] = {Path(p).name: sha256(p) for p in a.artifact}

    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
