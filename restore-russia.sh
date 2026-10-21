#!/usr/bin/env bash
# Самостоятельный скрипт: вспомогательные компоненты встроены в этот файл.
set -Eeuo pipefail
umask 077
recovery_code_dir=$(mktemp -d)
trap 'rm -rf -- "$recovery_code_dir"' EXIT

cat > "$recovery_code_dir/recovery-common.sh" <<'RECOVERY_EMBED_AC43028E99F78DD719CB'
#!/usr/bin/env bash
# Общая часть двух скриптов восстановления. Отдельно не запускается.

umask 077
RESTORE_STAGE=''
RESTORE_COMMITTED=0

say() { printf '\n%s\n' "$*"; }
fail() { printf '\nОшибка: %s\n' "$*" >&2; exit 1; }
dc() { docker --host unix:///var/run/docker.sock "$@"; }
compose_at() { local directory=$1; shift; dc compose --project-directory "$directory" -f "$directory/compose.yaml" "$@"; }

cleanup_restore() {
    if [[ -n "$RESTORE_STAGE" ]]; then rm -rf -- "$RESTORE_STAGE"; fi
}

restore_error() {
    local status=$1 line=$2
    printf '\nВосстановление остановлено: строка %s, код %s.\n' "$line" "$status" >&2
    if (( RESTORE_COMMITTED == 1 )); then
        printf '%s\n' 'Распакованные данные оставлены в /opt. Автоматического удаления и отката нет.' >&2
    else
        printf '%s\n' 'Конфигурации VPN в /opt ещё не заменялись.' >&2
    fi
    exit "$status"
}

ask() {
    local message=$1 default=${2:-} result
    if [[ -n "$default" ]]; then printf '%s [%s]: ' "$message" "$default" >&2;
    else printf '%s: ' "$message" >&2; fi
    read -r result || fail 'Ввод прерван. Запускайте скрипт в интерактивном SSH-терминале.'
    printf '%s' "${result:-$default}"
}

ask_ipv4() {
    local message=$1 default=${2:-} result
    while true; do
        result=$(ask "$message" "$default") || return 1
        if python3 "$RECOVERY_DIR/archive-helper.py" ipv4 "$result" >/dev/null 2>&1; then
            printf '%s' "$result"; return
        fi
        printf '%s\n' 'Введите публичный IPv4, например адрес из раздела «Сеть / IPv4» в панели хостера.' >&2
    done
}

confirm() {
    local answer
    answer=$(ask "$1 — введите ДА")
    [[ "$answer" == ДА || "$answer" == да || "$answer" == YES || "$answer" == yes ]] || fail 'Действие отменено.'
}

meta() {
    python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$METADATA" "$1"
}

usage_restore() {
    cat <<EOF
Восстановление узла $1 из личного архива .tar.gz.

  sudo bash $2 /root/backup.tar.gz
  bash $2 --check /path/to/backup.tar.gz

Обычный запуск: только чистая Ubuntu 22.04 LTS amd64 с systemd, от root.
Нужны python3, доступ к репозиториям Ubuntu и реестрам Docker.
Python при необходимости: apt-get update && apt-get install -y python3
Проверка архивов и установщик Docker встроены; достаточно одного файла скрипта.

Сначала загрузите на новый сервер собственный архив через scp/SFTP.
Скрипт проверяет и сам распаковывает его, сохраняет ключи и спрашивает IP-адреса.
Существующие каталоги и контейнеры не перезаписываются и не удаляются.
Docker устанавливается/проверяется при помощи приложенного install-docker.sh.
Используются образы из сохранённого Compose; их точные версии не закреплены.
IPv6 клиентов остаётся заблокированным, как в нашей работающей схеме.

--check: проверка структуры, обязательных файлов и целостности архива без
установки, распаковки и изменения сервера; работает также на Mac с python3.
Архивы с символическими/жёсткими ссылками и устройствами не поддерживаются.
Резервная копия содержит секреты. Не загружайте её в публичный репозиторий.
EOF
}

check_platform_restore() {
    [[ $(uname -s) == Linux && $(id -u) == 0 ]] || fail 'Нужны Linux и root: sudo bash restore-....sh'
    [[ -r /etc/os-release ]] || fail 'Не найден /etc/os-release.'
    . /etc/os-release
    [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 22.04 && "${VERSION_CODENAME:-}" == jammy ]] ||
        fail 'Поддерживается только Ubuntu 22.04 LTS (jammy).'
    [[ $(dpkg --print-architecture) == amd64 && -d /run/systemd/system ]] || fail 'Нужны amd64 и systemd.'
    local command
    for command in python3 flock modprobe ss; do
        if ! command -v "$command" >/dev/null; then
            case "$command" in
                python3) fail 'Нужен Python: apt-get update && apt-get install -y python3' ;;
                modprobe) fail 'Нужен kmod: apt-get update && apt-get install -y kmod' ;;
                flock) fail 'Нужен util-linux: apt-get update && apt-get install -y util-linux' ;;
                ss) fail 'Нужен iproute2: apt-get update && apt-get install -y iproute2' ;;
            esac
        fi
    done
}

check_destinations() {
    local directory
    # Защита и от случайного запуска скрипта Амстердама на действующем РФ-узле.
    for directory in wg-easy caddy wg-exit; do
        [[ ! -e "/opt/$directory" && ! -L "/opt/$directory" ]] ||
            fail "Каталог /opt/$directory уже существует. Нужен чистый сервер; скрипт не перезаписывает действующий VPN."
    done
}

allow_host_firewall() {
    local role=$1 udp_port=$2
    if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status | grep -q '^Status: active'; then
        say 'Добавляем правила в уже включённый UFW.'
        ufw allow "$udp_port/udp"
        if [[ "$role" == russia ]]; then ufw allow 80/tcp; ufw allow 443/tcp; fi
    fi
}

check_port() {
    local transport=$1 port=$2 output
    if [[ "$transport" == tcp ]]; then output=$(ss -H -ltn "( sport = :$port )");
    else output=$(ss -H -lun "( sport = :$port )"); fi
    [[ -z "$output" ]] || fail "Порт $port/$transport уже занят на новом сервере."
}

wait_tunnel() {
    local container=$1 i
    for ((i=0; i<60; i++)); do
        if dc exec "$container" wg show wg-exit >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    fail "Интерфейс wg-exit не появился. Проверьте: docker logs --tail=100 $container"
}

restore_node() {
    local role=$1; shift
    local filename="restore-$role.sh" archive='' command
    for command in recovery-common.sh archive-helper.py install-docker.sh; do
        [[ -f "$RECOVERY_DIR/$command" ]] || fail "Рядом со скриптом не найден $command. Распакуйте весь комплект."
    done
    if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage_restore "$role" "$filename"; return; fi
    if [[ "${1:-}" == --check ]]; then
        [[ $# == 2 ]] || fail "Использование: bash $filename --check /path/backup.tar.gz"
        command -v python3 >/dev/null || fail 'Для проверки нужен python3.'
        python3 "$RECOVERY_DIR/archive-helper.py" inspect "$2" "$role"
        say 'Архив прошёл проверку структуры и целостности. Никакие файлы не распакованы.'
        return
    fi
    [[ $# -le 1 ]] || fail "Использование: bash $filename /root/backup.tar.gz"
    check_platform_restore
    trap cleanup_restore EXIT
    trap 'restore_error "$?" "$LINENO"' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    exec 9>/run/vpn-restore.lock
    flock -n 9 || fail 'Другой процесс восстановления уже работает.'

    local TARGET_DIRS=() CONTAINERS=()
    if [[ "$role" == amsterdam ]]; then TARGET_DIRS=(wg-exit); CONTAINERS=(wg-exit);
    else TARGET_DIRS=(wg-easy caddy); CONTAINERS=(wg-easy wg-caddy); fi
    check_destinations
    say "Восстановление: $role. Используйте только собственную доверенную копию."
    printf '%s\n' 'Архив берётся из Documents/vpn-backups на вашем Mac. Загрузите его на новый сервер через scp/SFTP.'
    archive=${1:-}
    if [[ -z "$archive" ]]; then archive=$(ask 'Полный путь к архиву на ЭТОМ сервере, например /root/backup.tar.gz'); fi
    [[ -f "$archive" && -r "$archive" ]] || fail "Архив не найден или не читается: $archive"
    RESTORE_STAGE=$(mktemp -d /opt/.vpn-restore.XXXXXX)
    cp -- "$archive" "$RESTORE_STAGE/source.tar.gz"
    chmod 600 "$RESTORE_STAGE/source.tar.gz"
    METADATA=$(python3 "$RECOVERY_DIR/archive-helper.py" inspect "$RESTORE_STAGE/source.tar.gz" "$role")
    local server_ip exit_ip='' service_port domain=''
    server_ip=$(ask_ipv4 'Публичный IPv4 НОВОГО сервера — посмотрите в панели хостера')
    service_port=$(meta port)
    if [[ "$role" == russia ]]; then
        exit_ip=$(ask_ipv4 'Актуальный публичный IPv4 Амстердама — панель хостера этого узла' "$(meta exit_ip)")
        domain=$(meta domain)
        check_port tcp 80
        check_port tcp 443
        check_port udp "$(meta vpn_port)"
    else
        check_port udp "$service_port"
    fi
    printf '\nНовый узел: %s, IPv4: %s. Ключи будут взяты из архива.\n' "$role" "$server_ip"
    if [[ "$role" == russia ]]; then printf 'Амстердам: %s:%s. Домен панели: %s.\n' "$exit_ip" "$service_port" "$domain"; fi
    printf '%s\n' 'Если UFW уже включён, будут добавлены разрешения для портов этого узла.'
    confirm 'Подготовить этот чистый сервер, проверить/установить Docker и распаковать архив'

    bash "$RECOVERY_DIR/install-docker.sh" --yes
    # Проверки и команды далее всегда обращаются к локальному Docker.
    unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS DOCKER_TLS_VERIFY DOCKER_CERT_PATH
    local container directory
    for container in wg-easy wg-caddy wg-exit; do
        if dc container inspect "$container" >/dev/null 2>&1; then
            fail "Контейнер $container уже существует. Автоматического удаления нет."
        fi
    done
    modprobe wireguard
    python3 "$RECOVERY_DIR/archive-helper.py" extract "$RESTORE_STAGE/source.tar.gz" "$role" "$RESTORE_STAGE" >/dev/null
    if [[ "$role" == russia ]]; then
        python3 "$RECOVERY_DIR/archive-helper.py" prepare-russia "$RESTORE_STAGE" "$exit_ip"
    fi
    for directory in "${TARGET_DIRS[@]}"; do
        compose_at "$RESTORE_STAGE/$directory" config -q
        compose_at "$RESTORE_STAGE/$directory" pull
    done
    say 'Конфигурации проверены, образы скачаны. Перед запуском остановите СТАРЫЙ узел.'
    if [[ "$role" == amsterdam ]]; then printf '%s\n' 'На СТАРОМ Амстердаме: docker stop wg-exit';
    else printf '%s\n' 'На СТАРОМ российском сервере: docker stop wg-easy wg-caddy'; fi
    printf '%s\n' 'Если старый сервер утрачен/недоступен и его контейнеры уже не работают, переходите дальше.'
    confirm 'Старый узел остановлен; запускать восстановленный узел'

    check_destinations
    RESTORE_COMMITTED=1
    for directory in "${TARGET_DIRS[@]}"; do mv -- "$RESTORE_STAGE/$directory" "/opt/$directory"; done
    if [[ "$role" == russia ]]; then allow_host_firewall "$role" "$(meta vpn_port)";
    else allow_host_firewall "$role" "$service_port"; fi
    for directory in "${TARGET_DIRS[@]}"; do compose_at "/opt/$directory" up -d; done

    if [[ "$role" == amsterdam ]]; then
        wait_tunnel wg-exit
        dc exec wg-exit wg show wg-exit
        say "Амстердам восстановлен. В firewall хостера разрешите входящий UDP $service_port."
        printf '\nНа РОССИЙСКОМ сервере обновите только Endpoint и перезапустите wg-easy:\n\n'
        printf "sed -i 's/^Endpoint[[:space:]]*=.*/Endpoint = %s:%s/' /opt/wg-easy/data/wg-exit.conf\n" "$server_ip" "$service_port"
        printf '%s\n' 'docker restart wg-easy'
        say "Переустанавливать российский сервер и менять QR-коды не требуется. На телефоне ожидаемый IP: $server_ip."
    else
        wait_tunnel wg-easy
        dc exec wg-easy sh -ec 'ip -4 rule show | grep -q "^10000:.*iif wg0 lookup 51830"; iptables -C FORWARD -i wg0 ! -o wg-exit -j REJECT; ip6tables -C FORWARD -i wg0 -j REJECT; ip -4 route get 1.1.1.1 from 10.8.0.2 iif wg0 | grep -q "dev wg-exit"'
        dc exec wg-easy wg show wg-exit
        say 'Российский узел и правила маршрутизации восстановлены.'
        printf 'В DNS домена %s установите A-запись на %s. Это делается у вашего DNS-провайдера.\n' "$domain" "$server_ip"
        printf 'В firewall хостера разрешите TCP 80, TCP 443 и UDP %s.\n' "$(meta vpn_port)"
        printf 'После обновления DNS откройте https://%s и переподключите VPN на телефоне.\n' "$domain"
        printf 'Ожидаемый внешний IPv4 на телефоне: %s. Амстердам переустанавливать не требуется.\n' "$exit_ip"
    fi
    say 'Проверьте доступ с телефона. Локальный запуск интерфейса ещё не гарантирует handshake и доступность интернета.'
}
RECOVERY_EMBED_AC43028E99F78DD719CB

cat > "$recovery_code_dir/archive-helper.py" <<'RECOVERY_EMBED_F90E316894C3AF4B9320'
#!/usr/bin/env python3
"""Проверка и распаковка архивов нашей схемы; секреты не печатаются."""
import gzip
import ipaddress
import json
import re
import sqlite3
import sys
import tarfile
from pathlib import Path, PurePosixPath

ROOTS = {"amsterdam": {"wg-exit"}, "russia": {"wg-easy", "caddy"}}
REQUIRED = {
    "amsterdam": {"wg-exit/compose.yaml", "wg-exit/config/wg_confs/wg-exit.conf"},
    "russia": {"wg-easy/compose.yaml", "wg-easy/data/wg-easy.db",
               "wg-easy/data/wg-exit.key", "wg-easy/data/wg-exit.conf",
               "wg-easy/data/wg0.conf", "caddy/compose.yaml", "caddy/Caddyfile"},
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def ipv4(value):
    address = ipaddress.ip_address(value)
    require(address.version == 4, "Требуется IPv4 из панели хостера.")
    require(address.is_global, "Требуется публичный IPv4, а не адрес внутренней сети.")
    return str(address)


def field(text, name):
    matches = re.findall(r"^\s*" + re.escape(name) + r"\s*=\s*([^\r\n]+)", text, re.M)
    require(len(matches) == 1, "В конфигурации отсутствует или повторяется поле " + name)
    return matches[0].strip()


def port(value):
    require(value.isdigit() and 1 <= int(value) <= 65535, "Некорректный порт в конфигурации.")
    return int(value)


def checked_archive(path, role):
    require(role in ROOTS, "Неизвестная роль сервера.")
    # Читаем до конца, чтобы проверить gzip CRC, включая конец сжатого потока.
    with gzip.open(path, "rb") as compressed:
        while compressed.read(1024 * 1024):
            pass
    archive = tarfile.open(path, "r:gz")
    try:
        members = archive.getmembers()
        require(bool(members), "Архив пуст.")
        seen, files, roots = set(), set(), set()
        for member in members:
            raw = member.name
            name = PurePosixPath(raw)
            require(raw and not name.is_absolute() and ".." not in raw.split("/")
                    and "\\" not in raw and not any(ord(c) < 32 for c in raw),
                    "Архив содержит недопустимый путь.")
            require(bool(name.parts) and name.parts[0] in ROOTS[role],
                    "Архив относится к другому узлу или содержит лишние каталоги.")
            normalized = str(name)
            require(normalized not in seen, "В архиве повторяется путь.")
            seen.add(normalized)
            require(member.isdir() or member.isfile(),
                    "Поддерживаются только обычные файлы и каталоги, без ссылок и устройств.")
            roots.add(name.parts[0])
            if member.isfile():
                files.add(normalized)
        require(roots == ROOTS[role], "В архиве отсутствует каталог нужного узла.")
        require(REQUIRED[role] <= files, "Не найдены обязательные файлы конфигурации или база клиентов.")
        for name in REQUIRED[role]:
            require(archive.getmember(name).size > 0, "Обязательный файл в архиве пуст.")

        def text(name):
            member = archive.getmember(name)
            require(member.size < 1024 * 1024, "Конфигурационный файл имеет неожиданный размер.")
            return archive.extractfile(member).read().decode("utf-8")

        metadata = {"role": role, "entries": len(members)}
        if role == "amsterdam":
            conf = text("wg-exit/config/wg_confs/wg-exit.conf")
            metadata["port"] = port(field(conf, "ListenPort"))
        else:
            conf = text("wg-easy/data/wg-exit.conf")
            host, separator, service_port = field(conf, "Endpoint").rpartition(":")
            require(separator and host, "Непонятный формат Endpoint.")
            metadata["exit_ip"] = ipv4(host)
            metadata["port"] = port(service_port)
            metadata["vpn_port"] = port(field(text("wg-easy/data/wg0.conf"), "ListenPort"))
            caddy = text("caddy/Caddyfile")
            matches = re.findall(r"^\s*([a-zA-Z0-9.-]+)\s*\{\s*$", caddy, re.M)
            require(len(matches) == 1 and "." in matches[0], "Не удалось определить домен панели.")
            metadata["domain"] = matches[0]
        return archive, members, metadata
    except Exception:
        archive.close()
        raise


def prepare_russia(directory, new_exit_ip):
    root = Path(directory)
    new_exit_ip = ipv4(new_exit_ip)
    database = root / "wg-easy/data/wg-easy.db"
    # Резервная копия сделана при остановленном wg-easy, проверяем SQLite до запуска.
    with sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True) as db:
        require(db.execute("PRAGMA quick_check").fetchall() == [("ok",)], "База клиентов SQLite повреждена.")
    conf = root / "wg-easy/data/wg-exit.conf"
    contents = conf.read_text()
    service_port = port(field(contents, "Endpoint").rpartition(":")[2])
    updated, count = re.subn(r"^\s*Endpoint\s*=\s*[^\r\n]+", f"Endpoint = {new_exit_ip}:{service_port}", contents, flags=re.M)
    require(count == 1, "Не удалось однозначно заменить Endpoint.")
    conf.write_text(updated)
    conf.chmod(0o600)


def main():
    action = sys.argv[1]
    if action == "ipv4":
        print(ipv4(sys.argv[2]))
        return
    if action == "prepare-russia":
        prepare_russia(sys.argv[2], sys.argv[3])
        return
    action, path, role = sys.argv[1:4]
    require(action in {"inspect", "extract"}, "Неизвестная команда.")
    archive, members, metadata = checked_archive(path, role)
    with archive:
        if action == "extract":
            target = Path(sys.argv[4])
            require(target.is_dir(), "Каталог подготовки не существует.")
            require(all(not (target / root).exists() for root in ROOTS[role]), "Каталог подготовки уже занят.")
            for member in members:
                member.mode &= 0o777  # Не восстанавливаем setuid/setgid.
            # Пути и типы всех записей проверены ДО распаковки; ссылок в архиве нет.
            archive.extractall(path=target, members=members, numeric_owner=True)
    print(json.dumps(metadata, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, tarfile.TarError, EOFError, sqlite3.Error, UnicodeError) as exc:
        print("Ошибка проверки архива: " + str(exc), file=sys.stderr)
        sys.exit(1)
RECOVERY_EMBED_F90E316894C3AF4B9320

cat > "$recovery_code_dir/install-docker.sh" <<'RECOVERY_EMBED_CBE7A55168FEAFD482CA'
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
RECOVERY_EMBED_CBE7A55168FEAFD482CA

RECOVERY_DIR="$recovery_code_dir" bash -c '
set -Eeuo pipefail
source "$RECOVERY_DIR/recovery-common.sh"
restore_node "$1" "${@:2}"
' _ russia "$@"
