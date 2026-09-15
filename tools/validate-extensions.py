#!/usr/bin/env python3
"""Валидатор манифестов расширений (extension.yaml).

Что проверяется — по пунктам, потому что каждый закрывает конкретный дефект:

1.  У каждого расширения есть extension.yaml.
    Расширением считается каталог `extensions/<группа>/<имя>/`, в котором лежит
    `install.sh`. Каталоги без него (`extensions/openwrt/*`) расширениями по
    текущей конвенции не являются — они доставляются `UPLOAD`/`COPY_IN` по
    фиксированным путям, а не инструкцией `EXTENSION` (каталог в
    `/opt/bisquite/<имя>/` плюс `install.sh`).
    Они печатаются списком «пропущено», а не молча игнорируются.

2.  Набор полей ровно тот, что задан спекой: name, version, layout, family,
    arch, phase, provides, requires, conflicts. Лишнее поле — ошибка, а не
    «задел на будущее»: неизвестное поле молча ничего не делает.

3.  Поля заполнены и осмысленны: `name` совпадает с именем каталога, `version`
    — semver, `layout` ровно 2, `family` из известного набора, `arch`
    непустой, `phase` из {build, firstboot}.

    `layout: 2` — раскладка в госте: расширение ставится в
    `/opt/bisquite/<имя>/` и зовёт общий код через `$SCRIPT_DIR/lib/`.
    bisquite отказывает расширению без него ещё до сборки, поэтому
    пропущенное поле ловится здесь, а не на хосте сборки. Значение сверяется
    точно и по типу: `layout: "2"` — строка, и это тоже ошибка.

4.  Каждая способность из `requires` кем-то предоставляется. Именно это
    отношение сегодня держится только порядком слоёв в VMFILE.

5.  В графе requires→provides нет циклов.

6.  `conflicts` симметричны: если A конфликтует с B, то B обязан объявить
    конфликт с A. Односторонний конфликт — это конфликт, о котором узнает
    только один из двух авторов.

7.  Настройки — через библиотеку `lib/bisquite-conf` (docs/extensions.md,
    раздел про настройки):
    - схема (`knobs` расширения, `lib/knobs/<домен>`) разбирается той же
      библиотекой, что читает её в госте, — второй реализации грамматики
      здесь нет, иначе валидатор и гость разошлись бы молча;
    - `knobs` расширения регистрирует его `install.sh` (`conf_init <домен>
      "$SCRIPT_DIR/knobs"`): схема, которую никто не ставит, — мёртвая;
    - скрипты расширения не пишут `/etc/bisquite/<домен>/config` мимо
      библиотеки (`>`, `>>`, `tee`, `sed -i`, `install`, `cp`, `mv` — в том
      числе через переменную с этим путём): повторная установка стирала
      правки оператора ровно так;
    - скрипты не исполняют файл настроек (`source`/`.`);
    - хуки `.apply`/`.secret` не зовут блокирующий `systemctl start|restart`:
      `bisquite-conf set` бывает внутри `cloud-final`, а службы с
      `After=cloud-final` ждали бы его — взаимная блокировка
      (`--no-block` обязателен).

Дополнительно (не ошибка, а предупреждение): расширение, которое объявляет
`phase: firstboot`, но не содержит `configure.sh`, и наоборот.

Код возврата: 0 — всё в порядке, 1 — есть ошибки, 2 — не удалось запуститься.
"""

from __future__ import annotations

import re
import subprocess
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
CONF_LIB = REPO_ROOT / "lib" / "bisquite-conf"
LIB_KNOBS = REPO_ROOT / "lib" / "knobs"

CONFIG_PATH = r"/etc/bisquite/[a-z0-9-]+/config(?:\.yaml)?\b"
# A write operation somewhere before the path on the same logical line.
WRITE_OP = re.compile(
    r"(?:>>?|\btee\b|\bsed\s+(?:-[a-zA-Z]*\s+)*-i|\binstall\b|\bcp\b|\bmv\b|\btruncate\b)"
)
SOURCE_OP = re.compile(r"(?:^|[\s;&|(])(?:source|\.)\s+[\"']?$")
BLOCKING_SYSTEMCTL = re.compile(
    r"\bsystemctl\b.*\b(?:start|restart|try-restart|reload-or-restart|condrestart|isolate)\b"
)
CONF_INIT_OWN = re.compile(
    r'\bconf_init\s+([a-z0-9-]+)\s+"\$(?:\{SCRIPT_DIR\}|SCRIPT_DIR)/knobs"'
)

REQUIRED_FIELDS = (
    "name",
    "version",
    "layout",
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
# Guest layout this repository targets: /opt/bisquite/<name>/ with lib/ linked
# in by the build. bisquite refuses any other value, so the validator does too.
SUPPORTED_LAYOUT = 2


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

        if "layout" in declared:
            layout = data.get("layout")
            # bool is an int subclass: `layout: true` must not pass as 1.
            if (
                isinstance(layout, bool)
                or not isinstance(layout, int)
                or layout != SUPPORTED_LAYOUT
            ):
                report.error(
                    rel,
                    f"`layout: {layout!r}` — ожидается ровно {SUPPORTED_LAYOUT} "
                    "(раскладка /opt/bisquite, общий код через $SCRIPT_DIR/lib/)",
                )

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


def shell_lines(path: Path) -> list[tuple[int, str]]:
    """Logical lines of a shell script without comments (continuations joined)."""
    out: list[tuple[int, str]] = []
    buf = ""
    start = 0
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = raw.strip()
        if not buf and (not stripped or stripped.startswith("#")):
            continue
        if not buf:
            start = number
        # Drop a trailing comment only when `#` starts a word.
        line = re.sub(r"(^|\s)#.*$", "", raw)
        if line.rstrip().endswith("\\"):
            buf += line.rstrip()[:-1] + " "
            continue
        out.append((start, buf + line))
        buf = ""
    if buf:
        out.append((start, buf))
    return out


def is_shell(path: Path) -> bool:
    if path.suffix == ".sh":
        return True
    try:
        head = path.read_bytes()[:64]
    except OSError:
        return False
    return head.startswith(b"#!") and b"sh" in head.split(b"\n", 1)[0]


def schema_loads(domain: str, schema: Path) -> str | None:
    """Load the schema with lib/bisquite-conf itself; return the error text or None."""
    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1" && _conf_schema_load "$2" "$3"',
            "_",
            str(CONF_LIB),
            domain,
            str(schema),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return None
    return result.stderr.strip() or f"код {result.returncode}"


def check_knobs(manifests: dict[str, dict], report: Report) -> None:
    if not CONF_LIB.is_file():
        report.error("lib/bisquite-conf", "нет библиотеки настроек")
        return

    schemas: list[tuple[str, str, Path]] = []
    if LIB_KNOBS.is_dir():
        for schema in sorted(LIB_KNOBS.iterdir()):
            if schema.is_file() and "." not in schema.name:
                schemas.append(
                    (schema.relative_to(REPO_ROOT).as_posix(), schema.name, schema)
                )

    for rel, data in manifests.items():
        ext_dir: Path = data["__dir__"]
        knobs = ext_dir / "knobs"
        install = ext_dir / "install.sh"
        owned = {
            m.group(1)
            for _, line in shell_lines(install)
            for m in CONF_INIT_OWN.finditer(line)
        }
        if knobs.is_file():
            if not owned:
                report.error(
                    rel,
                    "есть knobs, но install.sh не регистрирует его "
                    '(conf_init <домен> "$SCRIPT_DIR/knobs")',
                )
            for domain in sorted(owned):
                schemas.append((f"{rel}/knobs", domain, knobs))
        elif owned:
            report.error(rel, "install.sh регистрирует $SCRIPT_DIR/knobs, а файла нет")

        for hook in ("knobs.apply", "knobs.secret"):
            if (ext_dir / hook).is_file() and not knobs.is_file():
                report.error(rel, f"{hook} без knobs — хук никто не зарегистрирует")

        for path in sorted(
            p for p in ext_dir.rglob("*") if p.is_file() and is_shell(p)
        ):
            check_script(path, report)

    for rel, domain, schema in schemas:
        error = schema_loads(domain, schema)
        if error:
            report.error(rel, f"схема не разбирается: {error}")

    hooks = [
        p
        for p in [
            *EXTENSIONS_ROOT.rglob("knobs.apply"),
            *EXTENSIONS_ROOT.rglob("knobs.secret"),
        ]
        if p.is_file()
    ]
    if LIB_KNOBS.is_dir():
        hooks += [p for p in LIB_KNOBS.iterdir() if p.suffix in (".apply", ".secret")]
    for hook in sorted(hooks):
        rel = hook.relative_to(REPO_ROOT).as_posix()
        for number, line in shell_lines(hook):
            if BLOCKING_SYSTEMCTL.search(line) and "--no-block" not in line:
                report.error(
                    f"{rel}:{number}",
                    "хук зовёт systemctl start/restart без --no-block — "
                    "из cloud-final это взаимная блокировка",
                )


def check_script(path: Path, report: Report) -> None:
    rel = path.relative_to(REPO_ROOT).as_posix()
    lines = shell_lines(path)
    variables: set[str] = set()
    for _, line in lines:
        for m in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)=[\"']?" + CONFIG_PATH, line):
            variables.add(m.group(1))
    targets = [CONFIG_PATH] + [
        rf"\$\{{?{re.escape(v)}\b\}}?" for v in sorted(variables)
    ]
    target = re.compile("(?:" + "|".join(targets) + ")")
    for number, line in lines:
        for m in target.finditer(line):
            before = line[: m.start()]
            if WRITE_OP.search(before) and not re.search(r"\brm\b", before):
                report.error(
                    f"{rel}:{number}",
                    "пишет файл настроек мимо lib/bisquite-conf "
                    "(conf_init/conf_set) — повторная установка сотрёт правки",
                )
                break
            if SOURCE_OP.search(before):
                report.error(
                    f"{rel}:{number}",
                    "исполняет файл настроек (source/.) — читать через conf_load",
                )
                break


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
        check_knobs(manifests, report)

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
