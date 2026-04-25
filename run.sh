/root/run_fact_cpu.sh

#!/usr/bin/env bash
set -Eeuo pipefail

USERNAME="${1:-mustfun}"
PASSWORD="${2:-YNr8FUHZ}"

WORKDIR="/root/fact-cpu"
LOGDIR="$WORKDIR/logs"
REPORTDIR="$WORKDIR/reports"
RUNLOG="$LOGDIR/fact-direct.log"
SETUP_URL="https://github.com/filthz/fact-worker-public/releases/download/base_files/setup_worker.sh"

log() {
  echo
  echo "[$(date '+%F %T')] $*"
}

mkdir -p "$WORKDIR" "$LOGDIR" "$REPORTDIR"
cd "$WORKDIR"

log "Устанавливаю минимальные зависимости"
apt-get update || true
apt-get install -y wget curl ca-certificates bash coreutils procps findutils sed grep || true

log "Скачиваю официальный setup_worker.sh"
wget -O setup_worker.sh "$SETUP_URL"
chmod +x setup_worker.sh
sed -i 's/\r$//' setup_worker.sh

log "Создаю безопасные заглушки, чтобы setup_worker.sh НЕ ставил Docker и НЕ запускал docker run"
mkdir -p "$WORKDIR/fakebin"

cat > "$WORKDIR/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
echo "[fake docker] docker $*" >&2
exit 0
EOF

cat > "$WORKDIR/fakebin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "[fake systemctl] systemctl $*" >&2
exit 0
EOF

cat > "$WORKDIR/fakebin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "bash" && "$2" == *"install_docker_slave.sh"* ]]; then
  echo "[fake sudo] skip Docker installer: $*" >&2
  exit 0
fi

exec "$@"
EOF

chmod +x "$WORKDIR/fakebin/docker" "$WORKDIR/fakebin/systemctl" "$WORKDIR/fakebin/sudo"

log "Запускаю setup_worker.sh только для подготовки файлов FACT"
PATH="$WORKDIR/fakebin:$PATH" bash ./setup_worker.sh "$USERNAME" "$PASSWORD" || true

log "Проверяю полученные файлы"
ls -lah "$WORKDIR" || true
ls -lah "$WORKDIR/fact_dist" 2>/dev/null || true

log "Отключаю GPU для FACT CPU-процесса"
export CUDA_VISIBLE_DEVICES=""
export NVIDIA_VISIBLE_DEVICES="none"

log "Пробую обновить FACT worker"
if [ -x "$WORKDIR/fact-worker-updater" ]; then
  "$WORKDIR/fact-worker-updater" >> "$RUNLOG" 2>&1 || true
elif [ -f "$WORKDIR/fact-worker-updater" ]; then
  chmod +x "$WORKDIR/fact-worker-updater"
  "$WORKDIR/fact-worker-updater" >> "$RUNLOG" 2>&1 || true
fi

log "Ищу прямой исполняемый файл FACT"

CANDIDATES=""

if [ -x "$WORKDIR/start.sh" ]; then
  if ! grep -q "docker" "$WORKDIR/start.sh"; then
    CANDIDATES="$CANDIDATES $WORKDIR/start.sh"
  fi
fi

if [ -d "$WORKDIR/fact_dist" ]; then
  FOUND="$(find "$WORKDIR/fact_dist" -maxdepth 4 -type f -perm -111 2>/dev/null | grep -Ei 'fact|worker|slave|miner' || true)"
  CANDIDATES="$CANDIDATES $FOUND"
fi

if [ -z "$(echo "$CANDIDATES" | xargs echo)" ]; then
  echo
  echo "Не найден прямой исполняемый FACT worker."
  echo "Это значит, что текущий архив рассчитан только на запуск через Dockerfile/start.sh внутри fact-worker image."
  echo
  echo "Покажи вывод:"
  echo "  ls -lah $WORKDIR"
  echo "  find $WORKDIR -maxdepth 4 -type f -perm -111 -print"
  echo "  cat $WORKDIR/Dockerfile"
  exit 1
fi

FACT_CMD="$(echo "$CANDIDATES" | xargs -n1 | head -1)"

log "Найден кандидат запуска: $FACT_CMD"

chmod +x "$FACT_CMD" || true

log "Запускаю FACT CPU worker в фоне"
nohup "$FACT_CMD" >> "$RUNLOG" 2>&1 &

sleep 5

log "Проверяю процесс"
ps aux | grep -Ei "fact|worker|slave|miner" | grep -v grep || true

log "Последние строки лога"
tail -100 "$RUNLOG" || true

log "Готово"
echo
echo "Лог FACT:"
echo "$RUNLOG"