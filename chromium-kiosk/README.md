# chromium-kiosk

Ставит полноэкранный Chromium в режиме kiosk через [cage](https://github.com/cage-kiosk/cage)
(минималистичный wayland-композитор) и включает его systemd-юнитом.

| Параметр (env) | По умолчанию | Описание |
|----------------|--------------|----------|
| `KIOSK_URL` | `https://example.com` | Стартовый URL |
| `KIOSK_USER` | `kiosk` | Пользователь сессии |

**ОС:** Debian ≥12. **Зависимости:** нет.

> ⚠️ Киоску нужна графическая база и GPU/DRM-seat. На разном железе может
> требоваться тюнинг (драйверы, seat, tty). Считайте это стартовой точкой.

## Использование в VMFILE

```dockerfile
COPY_IN extensions/chromium-kiosk:/opt/ext/chromium-kiosk
RUN_COMMAND KIOSK_URL="https://dashboard.local" bash /opt/ext/chromium-kiosk/install.sh
```
