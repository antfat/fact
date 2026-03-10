#!/usr/bin/env bash
set -Eeuo pipefail

USERNAME="${1:-mustfun}"
PASSWORD="${2:-YNr8FUHZ}"
WORKDIR="/root/launch"
DOCKERD_LOG="/tmp/dockerd-fact.log"

log() {
  echo
  echo "[$(date '+%F %T')] $*"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

sanitize_file() {
  local f="$1"
  [ -f "$f" ] || return 0

  # убрать CRLF
  sed -i 's/\r$//' "$f"

  # убрать sudo в начале строки
  sed -i -E 's/^([[:space:]]*)sudo([[:space:]]+)/\1/g' "$f"

  # убрать sudo внутри $(sudo docker ...)
  sed -i -E 's/\$\(([^)]*)sudo[[:space:]]+/\$(\1/g' "$f"

  # убрать оставшиеся "sudo " в середине строки
  sed -i -E 's/[[:space:]]sudo[[:space:]]+/ /g' "$f"
}

sanitize_all_sh() {
  find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
    sanitize_file "$f"
  done
}

patch_start_worker() {
  local f="./start_worker.sh"
  [ -f "$f" ] || return 0

  sanitize_file "$f"

  # сделать docker stop/rm безопасными, если контейнера ещё нет
  sed -i -E \
    's#^([[:space:]]*)docker stop \$\(docker ps -aq -f name=fact-worker\); docker rm \$\(docker ps -aq -f name=fact-worker\);#\1CID="$(docker ps -aq -f name=fact-worker || true)"; [ -n "$CID" ] \&\& docker stop $CID || true; [ -n "$CID" ] \&\& docker rm $CID || true;#' \
    "$f" || true

  chmod +x "$f"
}

install_docker_hiveos() {
  log "Проверка Docker CLI"
  if ! have_cmd docker; then
    log "Docker CLI не найден, пробую установить"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update

    # Для HiveOS/Clore возможен конфликт containerd ↔ containerd.io
    apt-get remove -y docker docker-engine docker.io containerd runc containerd.io || true
    apt-get autoremove -y || true
    apt-get update
    apt-get install -y docker.io || apt-get install -y docker-ce docker-ce-cli containerd.io
  else
    log "Docker CLI уже установлен: $(docker --version || true)"
  fi
}

start_dockerd_manual() {
  if docker info >/dev/null 2>&1; then
    log "Docker daemon уже работает"
    return 0
  fi

  if ! have_cmd dockerd; then
    echo "Ошибка: dockerd не найден. Docker daemon нельзя запустить."
    exit 1
  fi

  log "Останавливаю старые процессы dockerd/containerd, если есть"
  pkill -f dockerd || true
  pkill -f containerd || true
  sleep 2

  rm -f /var/run/docker.pid /var/run/docker.sock || true

  log "Запускаю dockerd вручную"
  nohup dockerd >"$DOCKERD_LOG" 2>&1 &
  sleep 8

  if ! docker info >/dev/null 2>&1; then
    echo "Ошибка: Docker daemon не запустился."
    echo "Последние строки лога:"
    tail -50 "$DOCKERD_LOG" || true
    exit 1
  fi

  log "Docker daemon успешно запущен"
}

download_setup() {
  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  log "Скачиваю setup_worker.sh"
  wget -O setup_worker.sh "https://github.com/filthz/fact-worker-public/releases/download/base_files/setup_worker.sh"
  chmod +x setup_worker.sh
  sanitize_file setup_worker.sh
}

run_setup() {
  cd "$WORKDIR"

  log "Запускаю setup_worker.sh"
  bash setup_worker.sh "$USERNAME" "$PASSWORD" || true

  log "Санитизация всех .sh после распаковки"
  sanitize_all_sh

  log "Патчу start_worker.sh"
  patch_start_worker

  log "Проверка оставшихся sudo"
  grep -RIn "sudo" . --include="*.sh" || true
}

start_worker_manual() {
  cd "$WORKDIR"

  if [ ! -f ./start_worker.sh ]; then
    echo "Ошибка: start_worker.sh не найден."
    exit 1
  fi

  chmod +x ./start_worker.sh

  log "Собираю образ fact-worker вручную, если нужно"
  if [ -f ./Dockerfile ]; then
    docker build --network=host -t fact-worker -f Dockerfile . || {
      echo "Ошибка сборки Docker image."
      exit 1
    }
  fi

  log "Запускаю start_worker.sh"
  bash ./start_worker.sh || true
}

show_status() {
  log "Состояние Docker"
  docker ps -a || true

  echo
  echo "Файлы логов:"
  ls -lah "$WORKDIR"/logs 2>/dev/null || true

  if [ -f "$WORKDIR/logs/worker.log" ]; then
    echo
    echo "Показываю лог воркера:"
    tail -100 "$WORKDIR/logs/worker.log"
  else
    echo
    echo "logs/worker.log пока не найден"
  fi
}

main() {
  log "Старт run.sh для CLORE HiveOS"

  install_docker_hiveos
  start_dockerd_manual
  download_setup
  run_setup
  start_dockerd_manual
  start_worker_manual
  show_status

  log "Готово"
}

main "$@"