"""Сторож: pip не должен сломать системный Python, на котором живёт плата.

pip под root ставит в /usr/local/lib/python3.10/dist-packages, и оттуда
пакеты перекрывают apt-овые для ВСЕХ, кто зовёт /usr/bin/python3, —
включая cloud-init, который на первой загрузке создаёт пользователя,
сеть и выполняет команды манифеста. Сломанный cloud-init не даёт ошибки
на сборке: образ собирается, а плата приезжает без пользователя.

Проверяем две вещи:
  1. прямые Python-зависимости пакета cloud-init импортируются из apt,
     а не из /usr/local (перекрытие ИХ — сигнал, что закрепление версий
     в constraints.txt вышло за пределы необходимого);
  2. cloud-init рендерит jinja-шаблон — markupsafe из-под него pip
     перекрывает законно (его тянет werkzeug у tensorboard), и это
     единственный способ убедиться, что пара jinja2/markupsafe живая.
"""

import importlib
import sys

APT_ROOT = "/usr/lib/python3/"
# apt-cache depends cloud-init на jammy: python3-requests, -jinja2, -yaml,
# -jsonschema, -jsonpatch, -oauthlib, -configobj, -serial, -debconf.
CLOUD_INIT_DEPS = (
    "requests",
    "jinja2",
    "yaml",
    "jsonschema",
    "jsonpatch",
    "oauthlib",
    "configobj",
    "serial",
)

failed = []
for name in CLOUD_INIT_DEPS:
    try:
        mod = importlib.import_module(name)
    except ImportError:
        continue  # пакета нет в образе — и перекрывать нечего
    where = getattr(mod, "__file__", "") or ""
    if not where.startswith(APT_ROOT):
        failed.append(f"{name}: импортируется из {where}, а не из apt")

try:
    from cloudinit import templater
except ImportError:
    print("cloud-init в образе нет — шаблон не проверяю")
else:
    out = templater.render_string(
        "## template: jinja\n#cloud-config\nhostname: {{ v1.h }}\n", {"v1": {"h": "ok"}}
    )
    if "hostname: ok" not in out:
        failed.append(f"cloud-init не отрендерил jinja-шаблон: {out!r}")

if failed:
    print("pip перекрыл системный Python так, что это опасно:")
    for line in failed:
        print("  -", line)
    sys.exit(1)
print("системный Python цел: зависимости cloud-init из apt, шаблоны рендерятся")
