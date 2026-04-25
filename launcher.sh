#!/usr/bin/env bash
set -Eeuo pipefail

USERNAME="${1:-mustfun}"
PASSWORD="${2:-YNr8FUHZ}"

WORKDIR="/root/launcher"
LOGDIR="$WORKDIR/logs"
DOCKER_LOG="/tmp/dockerd.log"

log() {
  echo
  echo "[$(date '+%F %T')] $*"
}

mkdir -p "$WORKDIR" "$LOGDIR"
cd "$WORKDIR"

# =========================
# 1. FIX DOCKER (CRITICAL)
# =========================
log "Чищу старый docker state"
pkill -f dockerd 2>/dev/null || true
pkill -f containerd 2>/dev/null || true

rm -f /var/run/docker.pid || true
rm -f /var/run/docker.sock || true

log "Запускаю dockerd вручную"
nohup dockerd \
  --host=unix:///var/run/docker.sock \
  --iptables=false \
  --ip6tables=false \
  > "$DOCKER_LOG" 2>&1 &

sleep 8

if ! docker info >/dev/null 2>&1; then
  echo
  echo "❌ Docker daemon НЕ запустился"
  echo "Лог:"
  tail -50 "$DOCKER_LOG"
  exit 1
fi

log "✅ Docker работает"

# =========================
# 2. Скачиваем setup
# =========================
log "Скачиваю setup_worker.sh"
wget -O setup_worker.sh \
https://github.com/filthz/fact-worker-public/releases/download/base_files/setup_worker.sh

chmod +x setup_worker.sh
sed -i 's/\r$//' setup_worker.sh

# =========================
# 3. FIX HiveOS проблемы
# =========================
log "Фикс iptables (HiveOS проблема)"
apt-get update || true
apt-get install -y iptables arptables ebtables || true

update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true

# =========================
# 4. Запуск official setup
# =========================
log "Запускаю официальный installer"

bash setup_worker.sh "$USERNAME" "$PASSWORD"

# =========================
# 5. Проверка
# =========================
log "Проверяю контейнер"

docker ps -a | grep fact-worker || {
  echo "❌ контейнер не создался"
  exit 1
}

log "Смотрю логи"

docker logs -f fact-worker