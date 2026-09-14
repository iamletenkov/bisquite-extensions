# firefox

Firefox из APT-репозитория Mozilla (`packages.mozilla.org`) — настоящий
`.deb`, а не снап.

## Зачем

На Ubuntu 22.04 и новее пакет `firefox` из дистрибутива транзитный
(`1:1snap1-0ubuntu2`): он ставит снап при первом запуске. В образах bisquite
snapd не посеян, и без сети на первой загрузке браузера нет. Так было на
роботе AGX Orin: ярлык есть, запуск отвечает «requires the firefox snap».
Chromium на arm64 устроен так же. Mozilla собирает amd64 и arm64 сама,
поэтому браузер ставится на сборке и работает без сети.

## Параметры

| Параметр | Умолчание | Что делает |
|---|---|---|
| `FIREFOX_LANGPACK` | пусто | языковой пакет: `ru` → `firefox-l10n-ru` |

```
EXTENSION firefox FIREFOX_LANGPACK=ru
```

## Что кладётся в образ

| Путь | Что |
|---|---|
| `/etc/apt/keyrings/packages.mozilla.org.asc` | ключ репозитория; отпечаток `35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3` сверяется до записи |
| `/etc/apt/sources.list.d/mozilla.list` | `deb https://packages.mozilla.org/apt mozilla main` |
| `/etc/apt/preferences.d/mozilla` | `Pin-Priority: 1000` для `firefox*` с этого источника |
| `/usr/lib/firefox/` | сам браузер; `x-www-browser` указывает на него |

Пин нужен, чтобы заменить транзитный пакет: у него эпоха `1:`, и без пина
apt считает его новее. Пин ограничен пакетами `firefox*`, чтобы репозиторий
Mozilla не перехватывал ничего другого.

## Обновления

Браузер обновляется обычным `apt upgrade` из того же репозитория. Сборка
фиксирует версию на момент сборки; разные образы, собранные в разные дни,
получат разные версии Firefox.

## Проверено

AGX Orin, L4T 36.4.3 (Ubuntu 22.04, arm64), 2026-09-14: транзитный пакет
заменён, `firefox --version` — `Mozilla Firefox 155.0.1`, установлен
`firefox-l10n-ru`. amd64 не проверялся.
