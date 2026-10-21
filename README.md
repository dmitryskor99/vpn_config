# vpn_config
Конфиги и скрипты для VPN

# НЕ ЗАБУДЬ ОТКРЫТЬ РЕПОЗИТОРИЙ

Требования и совместимость

1. ОС	Ubuntu Server 22.04 LTS, кодовое имя jammy
2. Архитектура	amd64 / x86_64, 64 бита
3. Права	Запуск от root, в том числе через sudo bash
4. Оболочка	Bash
5. Управление пакетами	APT
6. Управление службами	systemd
7. Сеть	Работающие DNS и HTTPS-доступ к репозиториям Ubuntu, Docker и Docker Hub
8. Состояние сервера	Предпочтительно свежая установка ОС без существующей контейнерной инфраструктуры

# проверка, на каком ip мой домен
`dig +short wg.dmitryskor.ru A`


# скрипт - install-docker.sh
Скрипт устанавливает Docker и Docker Compose на Ubuntu 22.04 amd64, включает автозапуск и проверяет работу тестовым контейнером.
Установка
```
curl -fL --proto '=https' \
  'https://raw.githubusercontent.com/dmitryskor99/vpn_config/main/install-docker.sh' \
  -o install-docker.sh &&
bash install-docker.sh
```
