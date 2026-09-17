#!/usr/bin/env python3
"""Привести Selkies 2.0.0rc0 к тому pixelflux, который живёт в main апстрима.

ЭТОТ ФАЙЛ — ОТДЕЛЯЕМАЯ ПОЛОВИНА РАСШИРЕНИЯ. Он существует только потому, что
последний релиз Selkies (2.0.0rc0 от 12.09.2026) старше pixelflux с бэкендом
Tegra. Апстримный main все эти правки уже содержит, ишью #395 спрашивает про
сроки релиза: как только релиз выйдет, файл удаляется целиком, а расширение
сводится к подкладке libxcb.

Правок девять, в двух группах.

Три переименования в питоне (пять строк). `pixelflux.SOFTWARE_H264_ENCODER`
стал словарём `SOFTWARE_ENCODERS`, числовой `CaptureSettings.output_mode` стал
строковым `codec`, и та же пара имён сверяется при ресайзе. Переименование
`output_mode` молчит: класс объявлен `#[pyclass(dict)]`, поэтому присваивание
ложится в словарь объекта и никем не читается — сессия, запросившая h264enc,
тихо стримит JPEG.

Смена формата кадра на проводе (четыре строки). `push_video_header` в main
пишет 12 байт вместо 10 (добавлено поле `reference`), а байт типа несёт
идентификатор кодека в старшем полубайте — опорный кадр H.264 читается как
0x11, а не 0x01. Старый разбор отказывает молча и по-разному: гейт реле
Selkies не признаёт ни один кадр опорным и не отдаёт на сокет ВООБЩЕ ничего
(сервер при этом пишет «Encoder: TEGRA» и занимает NVENC), а клиент в браузере
скармливает декодеру два байта `reference` как начало битстрима.

Каждая правка — точная строка, и промах фатален: молчаливая половина правок
даёт «работающую» сессию без картинки. --check только сообщает.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

# (файл относительно site-packages, что заменить, на что заменить)
EDITS: list[tuple[str, str, str]] = [
    # --- переименованный питоний API -----------------------------------------
    ("selkies/settings.py",
     "return str(pixelflux.SOFTWARE_H264_ENCODER)",
     'return str(pixelflux.SOFTWARE_ENCODERS.get("h264", "x264"))'),
    ("selkies/selkies.py",
     "            cs.output_mode = 0\n",
     '            cs.codec = "jpeg"\n'),
    ("selkies/selkies.py",
     "            cs.output_mode = 1\n",
     '            cs.codec = "h264"\n'),
    ("selkies/selkies.py",
     "for k in ('output_mode', 'use_cpu',",
     "for k in ('codec', 'use_cpu',"),
    ("selkies/media_pipeline.py",
     "        cs.output_mode = 1\n",
     '        cs.codec = "h264"\n'),
    # --- формат кадра: байт типа ---------------------------------------------
    ("selkies/selkies.py",
     "        is_idr = is_h264 and data[1] == 0x01",
     "        is_idr = is_h264 and (data[1] & 0x0F) == 0x01"),
    ("selkies/media_pipeline.py",
     "keyframe = view[0] != 0x04 or view[1] == 0x01",
     "keyframe = view[0] != 0x04 or (view[1] & 0x0F) == 0x01"),
]

# Клиентский бандл: правка одна и та же в исходнике и в собранном файле, но имя
# собранного несёт хеш сборки AppImage, поэтому ищется маской, а не именем.
JS_GLOBS = ["selkies/selkies_web/src/selkies-core.js",
            "selkies/selkies_web/assets/selkies-core-*.js"]
JS_EDITS: list[tuple[str, str]] = [
    ("if(e.byteLength<10)return;let n=t.getUint8(1),r=t.getUint16(2,!1);",
     "if(e.byteLength<12)return;let n=t.getUint8(1)&15,r=t.getUint16(2,!1);"),
    ("o=t.getUint16(8,!1),s=e.slice(10)",
     "o=t.getUint16(8,!1),s=e.slice(12)"),
]


def apply_to(path: Path, edits: list[tuple[str, str]], check_only: bool,
             failures: list[str]) -> None:
    """Применить набор точных правок к одному файлу, посчитав совпадения."""
    text = path.read_text()
    out = text
    for old, new in edits:
        if new in out and old not in out:
            print(f"уже применено: {path.name}: {old.strip()[:56]}")
            continue
        found = out.count(old)
        if found != 1:
            failures.append(
                f"{path}: строка {old.strip()[:56]!r} встречается {found} раз, ожидался ровно 1")
            continue
        out = out.replace(old, new)
        print(f"{'надо править' if check_only else 'исправлено'}: {path.name}: {old.strip()[:56]}")
    if not check_only and out != text:
        path.write_text(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site", required=True,
                        help="каталог site-packages питона AppImage")
    parser.add_argument("--check", action="store_true",
                        help="только сообщить, ничего не менять")
    args = parser.parse_args()
    site = Path(args.site)
    failures: list[str] = []

    by_file: dict[str, list[tuple[str, str]]] = {}
    for name, old, new in EDITS:
        by_file.setdefault(name, []).append((old, new))
    for name, edits in by_file.items():
        path = site / name
        if not path.is_file():
            failures.append(f"{path}: файла нет — раскладка AppImage сменилась")
            continue
        apply_to(path, edits, args.check, failures)

    for pattern in JS_GLOBS:
        # Маска обязана дать хотя бы один файл: молча пропущенный клиент —
        # это пустое окно в браузере при исправном сервере.
        parent = site / Path(pattern).parent
        matches = sorted(parent.glob(Path(pattern).name)) if parent.is_dir() else []
        if not matches:
            failures.append(f"{site / pattern}: ни одного файла — клиент Selkies не найден")
            continue
        for path in matches:
            apply_to(path, JS_EDITS, args.check, failures)

    for line in failures:
        print("ОТКАЗ:", line, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
