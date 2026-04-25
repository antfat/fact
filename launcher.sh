#!/usr/bin/env bash
set -Eeuo pipefail

USERNAME="${1:-mustfun}"
PASSWORD="${2:-YNr8FUHZ}"

WORKDIR="/root/launcher"
LOGDIR="$WORKDIR/logs"
RUNLOG="$LOGDIR/worker.log"
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
  wget curl ca-certificates bash coreutils procps findutils sed grep rsync screen git patch \
  python3-yaml dmidecode expect libecm1 zstd iproute2 \
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

log "Создаю fake docker, чтобы setup_worker.sh только подготовил файлы"
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
exec "$@"
EOF

chmod +x "$WORKDIR/fakebin/docker" "$WORKDIR/fakebin/systemctl" "$WORKDIR/fakebin/sudo"

log "Запускаю setup_worker.sh без реального Docker"
PATH="$WORKDIR/fakebin:$PATH" bash ./setup_worker.sh "$USERNAME" "$PASSWORD" || true

if [ ! -d "$WORKDIR/fact_dist" ]; then
  echo "Ошибка: $WORKDIR/fact_dist не найден"
  exit 1
fi

log "Раскладываю файлы worker так, как ожидает оригинальный Dockerfile"
rsync -a "$WORKDIR/fact_dist/." / || true

cp "$WORKDIR/application.yml" /application.yml
cp "$WORKDIR/application.yml" "$WORKDIR/fact_dist/application.yml" || true

mkdir -p /logs /reports "$LOGDIR"

cp /etc/machine-id /machine_id.cnf 2>/dev/null || true
cp /machine_id.cnf /worker_id.cfg 2>/dev/null || true

chmod +x /fact_worker 2>/dev/null || true
chmod +x /fact_worker.sh 2>/dev/null || true
chmod +x /start.sh 2>/dev/null || true
chmod +x /yafu 2>/dev/null || true
chmod +x /yafu_noavx 2>/dev/null || true
chmod +x /shim_main.so 2>/dev/null || true

log "Готовлю /cado-nfs с применением cado-client.patch"
rm -rf /cado-nfs

git clone --depth 1 https://github.com/cado-nfs/cado-nfs.git /cado-nfs

cp "$WORKDIR/fact_dist/cado-client.patch" /tmp/cado-client.patch

cd /cado-nfs
patch -p1 -i /tmp/cado-client.patch

mkdir -p "/cado-nfs/build/$(hostname)"
mkdir -p /cado-nfs-fallback1
mkdir -p "/cado-nfs-fallback1/build/$(hostname)"

cp /cado-nfs/cado-nfs-client.py "/cado-nfs/build/$(hostname)/cado-nfs-client.py"
cp /cado-nfs/cado-nfs-client.py /cado-nfs-fallback1/cado-nfs-client.py
cp /cado-nfs/cado-nfs-client.py "/cado-nfs-fallback1/build/$(hostname)/cado-nfs-client.py"

chmod +x /cado-nfs/cado-nfs-client.py
chmod +x "/cado-nfs/build/$(hostname)/cado-nfs-client.py"
chmod +x /cado-nfs-fallback1/cado-nfs-client.py
chmod +x "/cado-nfs-fallback1/build/$(hostname)/cado-nfs-client.py"

cd /

log "Проверка файлов"
ls -lah /application.yml || true
ls -lah /worker_id.cfg || true
ls -lah /fact_worker || true
ls -lah /shim_main.so || true
ls -lah /cado-nfs/cado-nfs-client.py || true
sha256sum /cado-nfs/cado-nfs-client.py || true

log "Останавливаю старые процессы"
pkill -f "/fact_worker" 2>/dev/null || true
pkill -f "fact_worker" 2>/dev/null || true
pkill -f "cado-nfs-client.py" 2>/dev/null || true
sleep 2

log "Отключаю GPU для launcher-процесса"
export CUDA_VISIBLE_DEVICES=""
export NVIDIA_VISIBLE_DEVICES="none"

log "Запускаю worker напрямую без Docker"
cd /

/fact_worker 2>&1 | tee "$RUNLOG"