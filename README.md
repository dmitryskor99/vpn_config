# vpn_config
Конфиги и скрипты для VPN

# Порядок действий
1. ставим чистую ubuntu
2. открываем репозиторий на гитхаб
3. устанавливаем докер через install-docker.sh
4. Переносим резервные копии на сервер(а)
5. или устанавливаем скрипт restore-russia.sh на РФ сервак или restore-amsterdam.sh + скачается питон

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

# Перенос архива с копиями на сервер
Копии лежат `/Users/dmitrii_skor/Documents/vpn-backups`

На амстердам:
```
scp ~/Documents/vpn-backups/amsterdam-20261020T235615Z.tar.gz root@IP_НОВОГО_СЕРВЕРА:/root/
```
На РФ:
```
scp ~/Documents/vpn-backups/russia-20261020T235530Z.tar.gz root@IP_НОВОГО_СЕРВЕРА:/root/
```

# restore-amsterdam.sh 
восстанавливает выходной сервер, сохраняет ключи и выдаёт команду переключения российского узла на новый IP.
```
apt-get update && apt-get install -y curl python3 &&
curl -fL https://raw.githubusercontent.com/dmitryskor99/vpn_config/main/restore-amsterdam.sh -o /root/restore-amsterdam.sh &&
bash /root/restore-amsterdam.sh /root/amsterdam-20261020T235615Z.tar.gz
```

# restore-russia.sh 
восстанавливает панель, клиентов, HTTPS и соединение с Амстердамом.
```
apt-get update && apt-get install -y curl python3 &&
curl -fL https://raw.githubusercontent.com/dmitryskor99/vpn_config/main/restore-russia.sh -o /root/restore-russia.sh &&
bash /root/restore-russia.sh /root/russia-20261020T235530Z.tar.gz
```

# Проверка текущего ip на устройстве
https://api.ipify.org/
