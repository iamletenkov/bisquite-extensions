# wrt.cloudinit

`wrt.cloudinit` — init-скрипт OpenWrt, который имитирует упрощённый cloud-init
(NoCloud) для образов, развёртываемых в Proxmox. Он читает ISO-диск
`cloudinit` (`/dev/sr0`), монтирует его в `/mnt/cidata` и выполняет настройки
при каждом полном запуске.

## Возможности

- **user-data** — поддерживает ключи `hostname`/`fqdn`, `user`, `password`.
  Скрипт создаёт системного пользователя, хеширует пароль (через `mkpasswd`,
  `openssl` или встроенный python) и выдаёт права для входа в LuCI/ubus.
- **root в LuCI** — функция `ensure_root_rpcd_login` регистрирует учетку `root`
  в `rpcd`, чтобы веб-интерфейс принимал пароль, пропечённый Bisquite через
  `virt-customize --root-password`.
- **network-config** — парсит YAML из `network-config`, применяет адресацию для
  WAN (`eth0`) и произвольного количества LAN-интерфейсов, пересоздаёт
  `network`, `dhcp`, `firewall`, `uhttpd` и включает доступ к LuCI с WAN.
- **DNS/search** — читает блок `nameserver` и формирует `/etc/resolv.conf`
  перед настройкой сетей.
- **firstboot-команды** — если Bisquite передал `/usr/libexec/bisquite-firstboot.sh`,
  скрипт выполнит его после применения `user-data` и сетей, залогирует вывод в
  `/tmp/bisquite-firstboot.log` и удалит файл.

## Как подключить к образу

В VMFILE добавьте строки из примера `examples/build/openwrt/openwrt.vmfile`:

```dockerfile
UPLOAD ./files/wrt_cloudinit/wrt.cloudinit:/etc/init.d/wrt.cloudinit
RUN_COMMAND chmod +x /etc/init.d/wrt.cloudinit && \
            /etc/init.d/wrt.cloudinit enable
```

После сборки достаточно включить cloud-init ISO в Proxmox (`ide2:
<storage>:cloudinit,media=cdrom`). Bisquite делает это автоматически при
`bs compose up`.

## Формат cloud-init

- `user-data`: минимальный YAML, совместимый с cloud-init NoCloud.
- `network-config`: список `type: physical` интерфейсов и вложенных блоков
  `type: static` или `type: dhcp4`. Скрипт рассматривает первый интерфейс как
  WAN, остальные — LAN (с DHCP-сервером при `static`).

## Отладка

- Логи доступны через `logread -e wrt.cloudinit`.
- Смонтированный ISO — `/mnt/cidata` (удаляется после применения настроек).
- Для повторного запуска без ребута можно выполнить `/etc/init.d/wrt.cloudinit start`.
- Диагностику firstboot смотрите в `/tmp/bisquite-firstboot.log`; если файл не
  создался, убедитесь, что `/usr/libexec/bisquite-firstboot.sh` присутствует в образе.
