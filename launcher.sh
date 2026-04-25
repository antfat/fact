#!/usr/bin/env bash
set -Eeuo pipefail

USERNAME="${1:-mustfun}"
PASSWORD="${2:-YNr8FUHZ}"

WORKDIR="/root/launcher"
LOGDIR="$WORKDIR/logs"
RUNLOG="$LOGDIR/launcher.log"
SETUP_URL="https://github.com/filthz/fact-worker-public/releases/download/base_files/setup_worker.sh"

log() {
  echo
  echo "[$(date '+%F %T')] $*"
}

mkdir -p "$WORKDIR" "$LOGDIR"
cd "$WORKDIR"

log "Устанавливаю зависимости"
apt-get update || true
apt-get install -y \
  wget curl ca-certificates bash coreutils procps findutils sed grep \
  python3-yaml dmidecode expect libecm1 zstd iproute2 screen \
  cado-nfs \
  || true

log "Создаю application.yml"
cat > "$WORKDIR/application.yml" <<EOF
username: "$USERNAME"
password: "$PASSWORD"
EOF

cp "$WORKDIR/application.yml" /application.yml

log "Скачиваю setup_worker.sh"
wget -O setup_worker.sh "$SETUP_URL"
chmod +x setup_worker.sh
sed -i 's/\r$//' setup_worker.sh

log "Создаю заглушки Docker/systemctl"
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

log "Запускаю setup_worker.sh только для подготовки файлов"
PATH="$WORKDIR/fakebin:$PATH" bash ./setup_worker.sh "$USERNAME" "$PASSWORD" || true

log "Копирую файлы worker в корень, как ожидает оригинальный Dockerfile"
if [ ! -d "$WORKDIR/fact_dist" ]; then
  echo "Ошибка: $WORKDIR/fact_dist не найден"
  exit 1
fi

cp -a "$WORKDIR/fact_dist/." /

cp "$WORKDIR/application.yml" /application.yml
cp "$WORKDIR/application.yml" "$WORKDIR/fact_dist/application.yml" || true

mkdir -p /logs /reports
cp /etc/machine-id /machine_id.cnf 2>/dev/null || true

chmod +x /fact_worker 2>/dev/null || true
chmod +x /fact_worker.sh 2>/dev/null || true
chmod +x /start.sh 2>/dev/null || true
chmod +x /yafu 2>/dev/null || true
chmod +x /yafu_noavx 2>/dev/null || true

log "Исправляю путь /shim_main.so"
if [ -f "$WORKDIR/fact_dist/shim_main.so" ]; then
  ln -sf "$WORKDIR/fact_dist/shim_main.so" /shim_main.so
fi

log "Исправляю путь /cado-nfs/cado-nfs-client.py"
mkdir -p /cado-nfs

CADO_CLIENT="$(find / -path '*cado-nfs-client.py' -type f 2>/dev/null | head -1 || true)"

if [ -n "$CADO_CLIENT" ]; then
  ln -sf "$CADO_CLIENT" /cado-nfs/cado-nfs-client.py
else
  log "ВНИМАНИЕ: cado-nfs-client.py не найден. Пробую установить cado-nfs повторно"
  apt-get update || true
  apt-get install -y cado-nfs || true

  CADO_CLIENT="$(find / -path '*cado-nfs-client.py' -type f 2>/dev/null | head -1 || true)"

  if [ -n "$CADO_CLIENT" ]; then
    ln -sf "$CADO_CLIENT" /cado-nfs/cado-nfs-client.py
  else
    log "ВНИМАНИЕ: cado-nfs-client.py всё ещё не найден"
  fi
fi

log "Проверка критичных файлов"
ls -lah /application.yml || true
ls -lah /fact_worker || true
ls -lah /shim_main.so || true
ls -lah /cado-nfs/cado-nfs-client.py || true

log "Останавливаю старые процессы"
pkill -f "/fact_worker" || true
pkill -f "fact_worker" || true
sleep 2

log "Отключаю GPU для процесса"
export CUDA_VISIBLE_DEVICES=""
export NVIDIA_VISIBLE_DEVICES="none"

log "Запускаю launcher"
cd /

/fact_worker 2>&1 | tee "$RUNLOG"