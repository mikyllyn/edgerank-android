# CDN EdgeRank (Android)

Android-порт скрипта `edgerank-allinone.sh` — тестирует и ранжирует CDN edge-IP
прямо с телефона. Веб-морда (та же форма + таблица) работает внутри приложения
через WebView + встроенный локальный сервер (NanoHTTPD, `127.0.0.1:8088`).

## Что делает
- Пробит список IP-эджей: HTTPS-запрос к домену **с подменой резолва**
  (OkHttp custom `Dns` = аналог `curl --resolve domain:443:IP`), SNI/Host = домен.
- Меряет: успех %, медиану / p95 / jitter задержки, коды ответа; ранжирует по score
  (`succ*100 - med*20 - jit*15`), две фазы (screening → full).
- Определение бэкенд-ASN по домену (connected edge IP → RIPEstat).
- Подтяжка реальных BGP-префиксов ASN из RIPEstat (fallback — встроенный список CDNvideo).
- Загрузка своего списка IP (файл или вставка).
- Показ vantage-IP (внешний IP + регион/провайдер/ASN) — детект включённого VPN.
- Экспорт результатов в CSV.

## Отличия от роутерной версии
- Доступ только с телефона (сервер на `127.0.0.1`, управление через WebView).
- Замер идёт с сети телефона (LTE/Wi-Fi), а не роутера.

## Сборка
Через GitHub Actions (`.github/workflows/build.yml`): `Actions → Build APK → Run`.
APK — в артефакте `edgerank-apk`. Требует INTERNET; root не нужен.
