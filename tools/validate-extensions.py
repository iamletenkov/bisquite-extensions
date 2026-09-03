#!/usr/bin/env python3
"""Валидатор манифестов расширений (extension.yaml).

Что проверяется — по пунктам, потому что каждый закрывает конкретный дефект:

1.  У каждого расширения есть extension.yaml.
    Расширением считается каталог `extensions/<группа>/<имя>/`, в котором лежит
    `install.sh`. Каталоги без него (`extensions/openwrt/*`) расширениями по
    текущей конвенции не являются — они доставляются `UPLOAD`/`COPY_IN` по
    фиксированным путям, а не `COPY_IN <ext>:/opt/vmsetup/` плюс `install.sh`.
    Они печатаются списком «пропущено», а не молча игнорируются.

2.  Набор полей ровно тот, что задан спекой: name, version, family, arch,
    phase, provides, requires, conflicts. Лишнее поле — ошибка, а не «задел
    на будущее»: неизвестное поле молча ничего не делает.

3.  Поля заполнены и осмысленны: `name` совпадает с именем каталога, `version`
    — semver, `family` из известного набора, `arch` непустой, `phase` из
    {build, firstboot}.

4.  Каждая способность из `requires` кем-то предоставляется. Именно это
    отношение сегодня держится только порядком слоёв в VMFILE.

5.  В графе requires→provides нет циклов.

6.  `conflicts` симметричны: если A конфликтует с B, то B обязан объявить
    конфликт с A. Односторонний конфликт — это конфликт, о котором узнает
    только один из двух авторов.

Дополнительно (не ошибка, а предупреждение): расширение, которое объявляет
`phase: firstboot`, но не содержит `configure.sh`, и наоборот.

Код возврата: 0 — всё в порядке, 1 — есть ошибки, 2 — не удалось запуститься.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError:  # pragma: no cover - зависит от окружения
    sys.stderr.write(
        "Нужен PyYAML: pip install pyyaml (или apt install python3-yaml)\n"
    )
    raise SystemExit(2) from None

REPO_ROOT = Path(__file__).resolve().parent.parent
EXTENSIONS_ROOT = REPO_ROOT / "extensions"

REQUIRED_FIELDS = (
    "name",
    "version",
    "family",
    "arch",
    "phase",
    "provides",
    "requires",
    "conflicts",
)
LIST_FIELDS = ("arch", "provides", "requires", "conflicts")
KNOWN_FAMILIES = {"deb", "rpm", "apk", "openwrt"}
KNOWN_PHASES = {"build", "firstboot"}
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, where: str, message: str) -> None:
        self.errors.append(f"{where}: {message}")

    def warn(self, where: str, message: str) -> None:
        self.warnings.append(f"{where}: {message}")


def discover(report: Report) -> tuple[dict[str, dict], list[str]]:
    """Найти каталоги расширений. Возвращает (манифесты, пропущенные каталоги)."""
    manifests: dict[str, dict] = {}
    skipped: list[str] = []

    if not EXTENSIONS_ROOT.is_dir():
        report.error("extensions/", "каталог не найден")
        return manifests, skipped

    for group in sorted(p for p in EXTENSIONS_ROOT.iterdir() if p.is_dir()):
        for ext_dir in sorted(p for p in group.iterdir() if p.is_dir()):
            rel = ext_dir.relative_to(REPO_ROOT).as_posix()
            manifest_path = ext_dir / "extension.yaml"

            if not (ext_dir / "install.sh").is_file():
                if manifest_path.is_file():
                    report.error(
                        rel,
                        "есть extension.yaml, но нет install.sh — "
                        "по текущей конвенции это не расширение",
                    )
                else:
                    skipped.append(rel)
                continue

            if not manifest_path.is_file():
                report.error(rel, "нет extension.yaml")
                continue

            try:
                data = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
            except yaml.YAMLError as exc:
                report.error(rel, f"extension.yaml не разбирается: {exc}")
                continue

            if not isinstance(data, dict):
                report.error(rel, "extension.yaml не является отображением (mapping)")
                continue

            data["__dir__"] = ext_dir
            data["__rel__"] = rel
            manifests[rel] = data

    return manifests, skipped


def check_fields(manifests: dict[str, dict], report: Report) -> None:
    for rel, data in manifests.items():
        declared = {k for k in data if not k.startswith("__")}

        for field in REQUIRED_FIELDS:
            if field not in declared:
                report.error(rel, f"нет обязательного поля `{field}`")

        for extra in sorted(declared - set(REQUIRED_FIELDS)):
            report.error(rel, f"неизвестное поле `{extra}` — оно ничего не делает")

        name = data.get("name")
        expected = Path(rel).name
        if name is not None and name != expected:
            report.error(
                rel, f"`name: {name}` не совпадает с именем каталога `{expected}`"
            )

        version = data.get("version")
        if version is not None and not SEMVER.match(str(version)):
            report.error(rel, f"`version: {version}` не semver (ожидается X.Y.Z)")

        family = data.get("family")
        if family is not None and family not in KNOWN_FAMILIES:
            report.error(
                rel,
                f"`family: {family}` вне известного набора {sorted(KNOWN_FAMILIES)}",
            )

        for field in LIST_FIELDS:
            value = data.get(field)
            if field not in declared:
                continue
            if value is None:
                report.error(
                    rel,
                    f"`{field}` пустое; пустой список пишется как `[]`, "
                    "а не оставляется без значения",
                )
                continue
            if not isinstance(value, list):
                report.error(rel, f"`{field}` должно быть списком")
                continue
            if any(not isinstance(item, str) or not item.strip() for item in value):
                report.error(rel, f"`{field}` содержит пустой или нестроковый элемент")

        if isinstance(data.get("arch"), list) and not data["arch"]:
            report.error(rel, "`arch` пуст: расширение неприменимо нигде")

        phases = normalize_phase(data.get("phase"))
        if phases is None:
            report.error(rel, "`phase` должно быть строкой или списком строк")
        else:
            if not phases:
                report.error(rel, "`phase` пуст")
            for phase in phases:
                if phase not in KNOWN_PHASES:
                    report.error(
                        rel,
                        f"`phase: {phase}` вне набора {sorted(KNOWN_PHASES)}",
                    )
            check_phase_matches_files(rel, data, phases, report)


def normalize_phase(value: object) -> list[str] | None:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return list(value)
    return None


def check_phase_matches_files(
    rel: str, data: dict, phases: list[str], report: Report
) -> None:
    ext_dir: Path = data["__dir__"]
    has_configure = (ext_dir / "configure.sh").is_file()
    if "firstboot" in phases and not has_configure:
        report.warn(rel, "объявлен phase firstboot, но configure.sh рядом нет")
    if "firstboot" not in phases and has_configure:
        report.warn(rel, "рядом есть configure.sh, но phase firstboot не объявлен")


def check_capabilities(manifests: dict[str, dict], report: Report) -> None:
    providers: dict[str, list[str]] = {}
    for _rel, data in manifests.items():
        name = data.get("name")
        for capability in as_list(data.get("provides")):
            providers.setdefault(capability, []).append(str(name))
        # Имя расширения — тоже способность: на него ссылаются conflicts.
        if isinstance(name, str):
            providers.setdefault(name, []).append(name)

    for rel, data in manifests.items():
        for capability in as_list(data.get("requires")):
            if capability not in providers:
                report.error(
                    rel,
                    f"`requires: {capability}` — эту способность никто не предоставляет",
                )


def check_conflicts(manifests: dict[str, dict], report: Report) -> None:
    by_name = {
        data["name"]: (rel, data)
        for rel, data in manifests.items()
        if isinstance(data.get("name"), str)
    }
    for rel, data in manifests.items():
        me = data.get("name")
        for other in as_list(data.get("conflicts")):
            if other == me:
                report.error(rel, "расширение конфликтует само с собой")
                continue
            if other not in by_name:
                report.error(rel, f"`conflicts: {other}` — такого расширения нет")
                continue
            _, other_data = by_name[other]
            if me not in as_list(other_data.get("conflicts")):
                report.error(
                    rel,
                    f"конфликт с `{other}` односторонний: "
                    f"{other}/extension.yaml не объявляет конфликт с `{me}`",
                )


def check_cycles(manifests: dict[str, dict], report: Report) -> None:
    """Цикл в графе расширений: A требует способность, которую даёт B, и наоборот."""
    providers: dict[str, set[str]] = {}
    for data in manifests.values():
        for capability in as_list(data.get("provides")):
            providers.setdefault(capability, set()).add(str(data.get("name")))

    edges: dict[str, set[str]] = {}
    for data in manifests.values():
        name = str(data.get("name"))
        deps: set[str] = set()
        for capability in as_list(data.get("requires")):
            deps |= providers.get(capability, set())
        deps.discard(name)
        edges[name] = deps

    WHITE, GREY, BLACK = 0, 1, 2
    color = dict.fromkeys(edges, WHITE)
    stack: list[str] = []

    def visit(node: str) -> None:
        color[node] = GREY
        stack.append(node)
        for nxt in sorted(edges.get(node, ())):
            if color.get(nxt, WHITE) == GREY:
                cycle = [*stack[stack.index(nxt) :], nxt]
                report.error("граф зависимостей", "цикл: " + " -> ".join(cycle))
            elif color.get(nxt, WHITE) == WHITE:
                visit(nxt)
        stack.pop()
        color[node] = BLACK

    for node in sorted(edges):
        if color[node] == WHITE:
            visit(node)


def as_list(value: object) -> list[str]:
    if isinstance(value, list):
        return [item for item in value if isinstance(item, str)]
    return []


def main() -> int:
    report = Report()
    manifests, skipped = discover(report)

    if manifests:
        check_fields(manifests, report)
        check_capabilities(manifests, report)
        check_conflicts(manifests, report)
        check_cycles(manifests, report)

    print(f"расширений с манифестом: {len(manifests)}")
    if skipped:
        print(
            "пропущено (нет install.sh, доставка через UPLOAD — см. docs/extensions.md):"
        )
        for rel in skipped:
            print(f"  {rel}")

    for line in report.warnings:
        print(f"WARN: {line}")
    for line in report.errors:
        print(f"FAIL: {line}", file=sys.stderr)

    if report.errors:
        print(f"\nвалидация не прошла: ошибок {len(report.errors)}", file=sys.stderr)
        return 1
    print("валидация прошла")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
