#!/usr/bin/env bash
# Подготовка Ubuntu Server 22.04 amd64 к запуску Docker-контейнеров.
# Источник: https://docs.docker.com/engine/install/ubuntu/

if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' 'Запустите скрипт через Bash: sudo bash install-docker.sh' >&2
    exit 1
fi

set -Eeuo pipefail
umask 022

ASSUME_YES=0
WORK_DIR=''
STAGED_FILE=''
REPO_FILE=/etc/apt/sources.list.d/docker.sources
KEY_FILE=/etc/apt/keyrings/docker.asc
PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

say() { printf '\n%s\n' "$*"; }
die() { printf '\nОшибка: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [[ -n "$STAGED_FILE" ]]; then rm -f -- "$STAGED_FILE"; fi
    if [[ -n "$WORK_DIR" ]]; then rm -rf -- "$WORK_DIR"; fi
}

on_error() {
    local status=$1 line=$2
    printf '\nОшибка на строке %s (код %s).\n' "$line" "$status" >&2
    printf '%s\n' \
        'Причина указана выше. Автоматический откат не выполняется.' \
        'Исправьте причину и повторите запуск. Блокировки APT вручную не удаляйте.' >&2
    exit "$status"
}

trap cleanup EXIT
trap 'on_error "$?" "$LINENO"' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
    cat <<'EOF'
Установка Docker Engine и плагина Compose для Ubuntu 22.04 LTS amd64.

Запуск от root:       bash install-docker.sh
Запуск через sudo:   sudo bash install-docker.sh
Без подтверждения:   sudo bash install-docker.sh --yes
Справка:             bash install-docker.sh --help

IP-адреса, домен и ключи не нужны. Если не знаете ОС сервера, выполните:
  cat /etc/os-release
  uname -m

Скрипт использует официальный APT-репозиторий Docker и проверяет запуск
hello-world. VPN и резервные копии данных на этом этапе не настраиваются.
EOF
}

package_installed() {
    local status
    status=$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) || return 1
    [[ "$status" == installed ]]
}

# Готовим файл в каталоге назначения и заменяем его одним rename.
# Прерванное скачивание не повредит действующий ключ или APT-источник.
atomic_install() {
    local source=$1 destination=$2
    STAGED_FILE=$(mktemp "${destination}.tmp.XXXXXX")
    install -m 0644 -- "$source" "$STAGED_FILE"
    mv -f -- "$STAGED_FILE" "$destination"
    STAGED_FILE=''
}

check_platform() {
    [[ $(uname -s) == Linux ]] || die 'Нужен сервер Linux с Ubuntu 22.04 LTS.'
    [[ $(id -u) == 0 ]] || die 'Нужны права root. Выполните: sudo bash install-docker.sh'
    [[ -r /etc/os-release ]] || die 'Не найден /etc/os-release: невозможно определить ОС.'

    # shellcheck source=/dev/null
    . /etc/os-release
    [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 22.04 && "${VERSION_CODENAME:-}" == jammy ]] ||
        die "Поддерживается только Ubuntu 22.04 LTS (jammy). Обнаружено: ${PRETTY_NAME:-неизвестная ОС}."

    local required
    for required in apt-get dpkg dpkg-query systemctl flock mktemp install cmp grep; do
        command -v "$required" >/dev/null 2>&1 || die "Не найдена системная команда: $required. Нужна стандартная Ubuntu Server."
    done
    [[ $(dpkg --print-architecture) == amd64 ]] || die 'Поддерживается только архитектура amd64 / x86_64.'
    [[ -d /run/systemd/system ]] || die 'Система не запущена под systemd. Ограниченные контейнерные VPS не поддерживаются.'
}

check_conflicts() {
    local package source_file docker_path
    local conflicts=()
    for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
        if package_installed "$package"; then conflicts+=("$package"); fi
    done
    if (( ${#conflicts[@]} > 0 )); then
        die "Найдены конфликтующие пакеты: ${conflicts[*]}. Проверьте их через apt-cache policy и решите, можно ли их удалить. Скрипт ничего не удаляет автоматически."
    fi
    if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
        die 'Найден Docker из Snap. Проверьте: snap list docker. Миграция существующей установки выполняется отдельно.'
    fi
    docker_path=$(command -v docker || true)
    if [[ -n "$docker_path" ]]; then
        [[ "$docker_path" == /usr/bin/docker || "$docker_path" == /bin/docker ]] ||
            die "Команда docker найдена в $docker_path. Нужна отдельная проверка этой установки перед использованием APT."
        dpkg-query -S "$docker_path" 2>/dev/null | grep -q '^docker-ce-cli: ' ||
            die "Команда $docker_path не принадлежит пакету docker-ce-cli. Проверьте: dpkg-query -S $docker_path"
    fi

    for source_file in "$REPO_FILE" "$KEY_FILE"; do
        [[ ! -L "$source_file" ]] || die "Символическая ссылка: $source_file. Проверьте её вручную."
        [[ ! -e "$source_file" || -f "$source_file" ]] || die "Ожидался обычный файл: $source_file."
    done
    if [[ -e "$REPO_FILE" ]] && ! cmp -s "$WORK_DIR/docker.sources" "$REPO_FILE"; then
        die "В $REPO_FILE уже есть другая настройка. Посмотрите: cat $REPO_FILE. Скрипт её не перезаписывает."
    fi
    for source_file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$source_file" && "$source_file" != "$REPO_FILE" ]] || continue
        if grep -Eq '^[[:space:]]*[^#[:space:]].*download[.]docker[.]com/linux/' "$source_file"; then
            die "Найдена другая запись репозитория Docker: $source_file. Проверьте файл и устраните дублирование вручную."
        fi
    done
}

main() {
    while (( $# > 0 )); do
        case "$1" in
            --yes|-y) ASSUME_YES=1 ;;
            --help|-h) usage; return 0 ;;
            *) die "Неизвестный аргумент: $1. Справка: bash install-docker.sh --help" ;;
        esac
        shift
    done

    check_platform
    # Не допускаем два одновременных запуска этого установщика.
    exec 9>/run/install-docker.lock
    flock -n 9 || die 'Другой экземпляр скрипта уже работает. Дождитесь его завершения.'
    WORK_DIR=$(mktemp -d)
    cat > "$WORK_DIR/docker.sources" <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: jammy
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    check_conflicts

    local package answer
    local missing=()
    for package in "${PACKAGES[@]}"; do
        if ! package_installed "$package"; then missing+=("$package"); fi
    done
    local setup_repository=0
    if (( ${#missing[@]} > 0 )) || [[ ! -s "$KEY_FILE" || ! -f "$REPO_FILE" ]]; then
        setup_repository=1
    fi
    say 'ОС: Ubuntu 22.04 LTS. Архитектура: amd64.'
    if (( ${#missing[@]} > 0 )); then
        say "Будут установлены недостающие пакеты: ${missing[*]}"
        printf '%s\n' 'Нужен доступ к репозиториям Ubuntu, download.docker.com и Docker Hub.'
    else
        say 'Все пакеты Docker уже установлены. Их переустановка и обновление будут пропущены.'
    fi
    if (( setup_repository == 1 )); then
        printf '%s\n' 'Будет настроен официальный APT-репозиторий Docker.'
    fi
    printf '%s\n' \
        'Будет включён и запущен локальный Docker, затем выполнен hello-world.' \
        'Docker управляет сетевыми правилами; настройка VPN выполняется отдельно.'

    if (( ASSUME_YES == 0 )); then
        printf '\nПродолжить? [д/Н]: '
        if ! read -r answer; then
            die 'Ответ не получен. Запускайте из терминала; для автоматического запуска есть --yes.'
        fi
        case "$answer" in
            д|Д|да|Да|ДА|y|Y|yes|YES) ;;
            *) say 'Отменено. Установка и запуск Docker не выполнялись.'; return 0 ;;
        esac
    fi

    if (( setup_repository == 1 )); then
        say '1/3. Устанавливаем curl и корневые сертификаты через APT.'
        apt-get -o DPkg::Lock::Timeout=120 update
        apt-get -o DPkg::Lock::Timeout=120 install -y --no-remove ca-certificates curl

        say '2/3. Подключаем официальный репозиторий Docker.'
        curl --fail --silent --show-error --location --proto '=https' \
            --connect-timeout 15 --max-time 120 --retry 3 \
            --output "$WORK_DIR/docker.asc" https://download.docker.com/linux/ubuntu/gpg
        grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----' "$WORK_DIR/docker.asc" ||
            die 'Сервер не вернул ожидаемый GPG-ключ. Проверьте доступ к https://download.docker.com/linux/ubuntu/gpg'
        install -m 0755 -d /etc/apt/keyrings /etc/apt/sources.list.d
        atomic_install "$WORK_DIR/docker.asc" "$KEY_FILE"
        atomic_install "$WORK_DIR/docker.sources" "$REPO_FILE"
    fi

    if (( ${#missing[@]} > 0 )); then
        say '3/3. Устанавливаем Docker Engine, Buildx и плагин Compose.'
        apt-get -o DPkg::Lock::Timeout=120 update
        # Не удаляем пакеты и не запрашиваем обновление уже установленных
        # компонентов Docker. APT может установить/обновить их зависимости.
        apt-get -o DPkg::Lock::Timeout=120 install -y --no-remove --no-upgrade "${PACKAGES[@]}"
    fi

    say 'Включаем автозапуск и запускаем Docker.'
    systemctl enable --now containerd.service docker.service
    systemctl is-active --quiet docker.service || die 'Docker не запустился. Диагностика: journalctl -u docker.service -n 100 --no-pager'
    systemctl is-enabled --quiet docker.service || die 'Автозапуск Docker не включён. Проверьте: systemctl status docker.service'

    say 'Проверяем локальный Docker Engine и Compose.'
    # Проверяем этот сервер, даже если пользователь настроил удалённый контекст.
    unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH
    /usr/bin/docker --host unix:///var/run/docker.sock version
    /usr/bin/docker --host unix:///var/run/docker.sock compose version
    /usr/bin/docker --host unix:///var/run/docker.sock buildx version
    say 'Запускаем тестовый контейнер hello-world.'
    if ! /usr/bin/docker --host unix:///var/run/docker.sock run --rm --pull=always hello-world; then
        die 'Docker установлен, но hello-world не прошёл. Проверьте вывод выше, DNS и HTTPS-доступ к Docker Hub. Установка не откатывается; после исправления причины повторите запуск.'
    fi
    say 'Готово: локальный Docker работает, Compose доступен, автозапуск включён.'
    printf '%s\n' 'Тестовый контейнер удалён. Образ hello-world оставлен в локальном кеше.'
}

main "$@"
