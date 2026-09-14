# selkies

X-сессия, которая на мониторе, — в браузере. [Selkies](https://github.com/selkies-project/selkies)
2.0 подключается к существующему дисплею `:0`, кодирует экран в H.264 и отдаёт
картинку, звук, ввод, буфер обмена и файлы через **один WebSocket-порт**.
Поэтому его можно опубликовать веб-приложением Teleport или ssh-туннелем:
WebRTC, UDP и TURN не нужны.

По умолчанию слушает `127.0.0.1:8080` без пароля: снаружи — только через того,
кто проксирует.

## Манифест

| Поле | Значение |
|---|---|
| `phase` | `build` (AppImage, юниты, настройки), `firstboot` (`selkies@<пользователь>`) |
| `arch` | `amd64`, `arm64` |
| `provides` | `web-remote-desktop` |
| `requires` | `x11-server`, `display-manager` |
| `conflicts` | пусто — с `x11vnc` работает параллельно, проверено |

## Подключение в VMFILE

```vmfile
EXTENSION gnome
EXTENSION selkies
FIRSTBOOT_COMMAND "bisquite-desktop set DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1"
```

**Без `DESKTOP_AUTOLOGIN=1` показывать нечего до входа человека:** Selkies
подключается к сессии пользователя, а не к экрану входа. Служба в это время
ждёт и пишет об этом в журнал одну строку.

Любая настройка Selkies — параметром расширения, родным именем переменной:

```vmfile
EXTENSION selkies SELKIES_PORT=8090 SELKIES_FRAMERATE=60,8-60 SELKIES_FILE_TRANSFERS=download
```

## Что внутри

- **AppImage** Selkies 2.0.0rc0 с GitHub, sha256 закреплён на архитектуру,
  распакован на сборке в `/opt/selkies/2.0.0rc0` (**+1.7 ГБ**, 6 с;
  `/opt/selkies/current` — ссылка). Пакеты Selkies собраны под Ubuntu 26.04
  и Debian trixie; AppImage несёт своё окружение и на Ubuntu 22.04
  (Jetson L4T 36.4) работает. Распакован, чтобы не зависеть от FUSE.
- **`/etc/bisquite/selkies/config`** (0600) — переменные `SELKIES_*`, читает юнит.
  До 2.0.0 файл лежал в `/etc/default/bisquite-selkies`; старый путь не читается,
  `install.sh` его удаляет.
- **`selkies@.service`** + **`run-selkies.sh`** — запуск от пользователя сессии.
- **`configure-selkies.service`** — на первой загрузке включает
  `selkies@<пользователь cloud-init>`.

Первой загрузке сеть не нужна: скачивание — только на сборке.

## Умолчания

| Переменная | Умолчание | Почему |
|---|---|---|
| `SELKIES_ADDR` | `127.0.0.1` | снаружи — через Teleport или ssh |
| `SELKIES_PORT` | `8080` | |
| `SELKIES_ENABLE_BASIC_AUTH` | `false` | на петле аутентификацию делает прокси; наружу без пароля обёртка не запустится |
| `SELKIES_ENABLE_HTTPS` | `false` | TLS завершает прокси; открывая наружу — `true` (см. «Открыть в сеть») |
| `SELKIES_ENABLE_RESIZE` | `false` | **иначе Selkies меняет разрешение монитора** под окно браузера |
| `SELKIES_ENCODER` | `h264enc` | NVENC/VA-API, если есть, иначе x264 |
| `SELKIES_FRAMERATE` | `30,8-60` | 30 при старте, пользователь может поднять до 60 |
| `SELKIES_AUDIO_ENABLED` | `true` | звук сессии; обёртка ждёт сокет PulseAudio пользователя до 30 с |
| `SELKIES_AUDIO_DEVICE_NAME` | monitor sink'а по умолчанию | обёртка подставляет `<sink по умолчанию>.monitor`: собственное умолчание Selkies `output.monitor` — пустой sink для контейнера, в него на роботе никто не играет |
| `SELKIES_ENABLE_CLIPBOARD` | `true` | обе стороны; `in`/`out`/`false` — по направлениям |
| `SELKIES_FILE_TRANSFERS` | `upload,download` | в `~/Downloads` пользователя (`SELKIES_FILE_MANAGER_PATH`) |
| `SELKIES_MICROPHONE_ENABLED`, `SELKIES_WEBCAM_ENABLED`, `SELKIES_GAMEPAD_ENABLED` | `false` | роботу не нужны |
| `SELKIES_COMMAND_ENABLED` | `false` | API выполнения команд |
| `SELKIES_ENABLE_SHARING`, `SELKIES_SECOND_SCREEN` | `false` | ссылки для просмотра, второй монитор |
| `SELKIES_MODE` | `websockets` | WebRTC через веб-приложение Teleport не проходит |
| `BISQUITE_SELKIES_ALLOW_NO_AUTH` | `false` | ручка обёртки, не Selkies: `true` разрешает адрес не петли без пароля |

## Что ещё умеет Selkies

Всё — родными переменными (полный список: `/opt/selkies/current/usr/conda/bin/selkies --help`).

| Возможность | Переменные |
|---|---|
| только просмотр по второму паролю | `SELKIES_ENABLE_BASIC_AUTH=true`, `SELKIES_BASIC_AUTH_PASSWORD`, `SELKIES_BASIC_AUTH_VIEWONLY_PASSWORD` |
| ссылки для просмотра и совместная работа | `SELKIES_ENABLE_SHARING`, `SELKIES_ENABLE_SHARED`, `SELKIES_ENABLE_COLLAB`, `SELKIES_MASTER_TOKEN` |
| качество и поток | `SELKIES_VIDEO_CRF`, `SELKIES_VIDEO_BITRATE`, `SELKIES_RATE_CONTROL_MODE` (crf/cbr), `SELKIES_VIDEO_FULLCOLOR` (4:4:4), `SELKIES_USE_PAINT_OVER_QUALITY` |
| кодер | `SELKIES_ENCODER=h264enc`, `h264enc-striped`, `jpeg` |
| ограничение скорости передачи файлов | `SELKIES_FILE_TRANSFER_LIMIT_MBPS` |
| микрофон и веб-камера из браузера на робота | `SELKIES_MICROPHONE_ENABLED`, `SELKIES_WEBCAM_ENABLED` (+ v4l2loopback) |
| водяной знак на картинке | `SELKIES_WATERMARK_PATH`, `SELKIES_WATERMARK_LOCATION` |
| команда при подключении/отключении | `SELKIES_RUN_AFTER_CONNECT`, `SELKIES_RUN_AFTER_DISCONNECT` |
| запись потока H.264 в сокет | `SELKIES_RECORDING_SOCKET` |
| адрес за прокси с путём | `SELKIES_SUBFOLDER` |
| разрешённые Origin | `SELKIES_ALLOWED_ORIGINS` |
| что показывать в боковой панели | `SELKIES_UI_SIDEBAR_SHOW_*`, `SELKIES_UI_TITLE` |

**SFTP у Selkies нет** — только передача файлов через браузер. Для SFTP — ssh
робота (в Teleport это ресурс сервера, а не приложения).

## Безопасность

- **Чужие страницы.** WebSocket Selkies принимает только тот же Origin, что у
  страницы, плюс клиентов без Origin. Проверено: `Origin: http://evil.example`
  → `403`. То есть страница, открытая в браузере на самом роботе, к
  `127.0.0.1:8080` не подключится. Локальный **процесс** (не браузер) —
  подключится, как и к x11vnc на петле.
- **За Teleport.** Если Teleport передаёт Selkies свой `Host`, а браузер — свой
  `Origin`, соединение получит `403` и в журнале будет
  `Rejected WebSocket upgrade from disallowed Origin`. Тогда:
  `SELKIES_ALLOWED_ORIGINS=https://<приложение>.<teleport>`.
- **Наружу — с паролем или явным решением.** `SELKIES_ADDR` не на петле без
  `SELKIES_ENABLE_BASIC_AUTH=true` — обёртка отказывается стартовать, если не
  задано `BISQUITE_SELKIES_ALLOW_NO_AUTH=true`. С ним стартует и пишет
  в журнал предупреждение: рабочий стол, буфер обмена, файлы и API команд
  получает любой, кто достаёт до робота по сети.
- **Пароль не в VMFILE.** Строка VMFILE хранится в образе и уезжает в реестр.
  Задавайте пароль на устройстве, например командой первой загрузки манифеста
  записи:

  ```yaml
  firstboot-commands:
    - "printf 'SELKIES_ENABLE_BASIC_AUTH=true\nSELKIES_BASIC_AUTH_PASSWORD=...\n' >> /etc/bisquite/selkies/config"
    - "systemctl restart 'selkies@*' || true"
  ```

  Файл `0600`, читает его systemd.
- **Файлы и буфер обмена** включены: тот, кто получил доступ к приложению,
  может читать и писать `~/Downloads` и буфер обмена сессии. Не нужно —
  `SELKIES_FILE_TRANSFERS=none`, `SELKIES_ENABLE_CLIPBOARD=out`.

## Открыть в сеть

Профиль стенда: все функции, без пароля, на всех интерфейсах.

```
EXTENSION selkies SELKIES_ADDR=0.0.0.0 SELKIES_ENABLE_HTTPS=true \
    BISQUITE_SELKIES_ALLOW_NO_AUTH=true …
```

**HTTPS обязателен для «всех функций».** Браузер даёт буфер обмена,
микрофон, камеру и геймпады только защищённому контексту; `http://<адрес>`
им не является (исключение — `localhost`, то есть туннель).

**Сертификат выпускается на устройстве.** Без `SELKIES_HTTPS_CERT` обёртка
направляет путь в `~/.local/state/selkies/selkies.{pem,key}` пользователя
сессии: файла там нет, и Selkies при первом старте создаёт самоподписанную
пару (SAN: `localhost`, имя хоста, `127.0.0.1`, `::1`; срок 10 лет) и дальше
её переиспользует. Путь по умолчанию самого Selkies —
`/etc/ssl/certs/ssl-cert-snakeoil.pem`; на Ubuntu сертификат там есть, а ключ
пользователю не читается, и Selkies падает с `[SSL] PEM lib` вместо генерации
(замер на AGX Orin 2026-09-14). Браузер один раз попросит исключение для
сертификата; пара не меняется между перезапусками, так что исключение
держится. В образ ключ не попадает.

С манифеста записи то же — строками в конфиг:

```yaml
firstboot-commands:
  - "sed -i -e 's/^SELKIES_ADDR=.*/SELKIES_ADDR=0.0.0.0/' -e 's/^SELKIES_ENABLE_HTTPS=.*/SELKIES_ENABLE_HTTPS=true/' -e 's/^BISQUITE_SELKIES_ALLOW_NO_AUTH=.*/BISQUITE_SELKIES_ALLOW_NO_AUTH=true/' /etc/bisquite/selkies/config"
  - "systemctl restart 'selkies@*' || true"
```

## Веб-приложение Teleport

С 2.1.0 `install.sh` кладёт объявление для расширения `teleport-agent` —
`/etc/bisquite/teleport/apps.d/selkies.conf` с `NAME=selkies` и
`URI=<http|https>://127.0.0.1:<SELKIES_PORT>` (схема — по
`SELKIES_ENABLE_HTTPS`). С ним Selkies публикуется как
`https://selkies.<нода>.<хост прокси>`; кому видно — метка `env` ноды и
`tpApps: selkies` пользователя. Не публиковать —
`bisquite-teleport set TELEPORT_APPS_DISABLE=selkies`.

WebSocket через Teleport проходит, потому что `teleport-agent` переписывает
приложению на петле `Host` на публичный адрес, и Origin браузера с ним
совпадает. Без этого (или за другим прокси, который передаёт `Host` петли)
Selkies отвечает `403` и пишет `Rejected WebSocket upgrade from disallowed
Origin` — тогда `SELKIES_ALLOWED_ORIGINS=https://<публичный адрес>`.

## Жизненный цикл службы

- **Нет сессии** — обёртка ждёт (`жду X-сессию 'robot' на :0`), Selkies не запущен.
- **Сессия пропала** (выход пользователя): Selkies сам не завершается —
  замер: процесс жив, в журнале только `X11 clipboard monitor thread exited`.
  Обёртка проверяет дисплей раз в 10 с, при двух неудачах гасит Selkies и
  выходит; юнит перезапускает, обёртка ждёт новую сессию. Проверено: выход →
  перезапуск через ~15 с → новый вход → Selkies снова отдаёт экран.
- **Перезапуск gdm** — служба останавливается вместе с ним (`Requires=`) и
  поднимается снова.
- **Мимо `AppRun`.** Штатный вход AppImage при отсутствии дисплея запускает
  Xvfb и стримил бы пустой экран, а при отсутствии звука — свой PulseAudio.
  Обёртка ставит те же переменные и зовёт бинарь сама.

## Проверено (Jetson AGX Orin, L4T 36.4.3, 2026-09-14)

`install.sh` на живой плате (скачивание 43 с, распаковка 1.7 ГБ), служба
поднята `configure.sh`, x11vnc рядом работает, разрешение монитора не
изменилось. Браузер через ssh-туннель, экран 3840×1080:

| Сцена | Цель | fps | Поток | CPU Selkies (из 1200%) |
|---|---|---|---|---|
| статичный стол | 30 | 30 | 0.03–0.09 Мбит/с | ~225% |
| движение 1080p | 30 | 30 | ~1.0 Мбит/с | ~146% |
| живая камера 1080p | 60 | 41–56 | ~1.8 Мбит/с | ~220% |

Мышь из браузера доходит в X с точным пересчётом координат. Кодер
программный: аппаратный кодер Jetson (nvv4l2) Selkies не поддерживает.

Открытый профиль (`SELKIES_ADDR=0.0.0.0`, `SELKIES_ENABLE_HTTPS=true`,
  `BISQUITE_SELKIES_ALLOW_NO_AUTH=true`): обёртка стартует с предупреждением,
  Selkies выпустил пару в `~/.local/state/selkies/`, страница отвечает `200`
  по `https://<адрес робота>` с другой машины. Без ручки — отказ старта.

Через Teleport (tp2, 2026-09-14): WebSocket `101`, картинка и звук в браузере;
звук робота (`paplay` в сессии) слышен в Selkies после захвата monitor
sink'а по умолчанию.

**Не проверено:** amd64 AppImage на Ubuntu 22.04; клавиатура и буфер обмена
отдельно; микрофон и камера клиента.

## Известное

- **Шум в журнале на Jetson** при подключённом клиенте:
  `WARNING:NvidiaGPUMonitor:Invalid process ID: [N/A]` раз в 2 с — встроенный
  сбор статистики GPU спрашивает `nvidia-smi`, а на Jetson он заглушка. На
  работу не влияет.
- **Браузер с запретом автовоспроизведения** не начнёт поток, пока по
  странице не кликнут (у Selkies есть кнопка запуска).
- Релиз-кандидат: обновление — правкой `SELKIES_VERSION` и sha256 в `install.sh`.

## Диагностика

```bash
systemctl status selkies@robot
journalctl -u selkies@robot -b | grep -E 'selkies:|running on|Origin|ERROR'
sudo cat /etc/bisquite/selkies/config
ss -ltnp | grep 8080
```
