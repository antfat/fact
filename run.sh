#!/usr/bin/env bash
set -euo pipefail

USERNAME="${1:-mustfun}"
PASSWORD="${2:-YNr8FUHZ}"

mkdir -p ~/launch
cd ~/launch

echo "[1/8] Download setup_worker.sh"
wget -O setup_worker.sh "https://github.com/filthz/fact-worker-public/releases/download/base_files/setup_worker.sh"
chmod +x setup_worker.sh

echo "[2/8] Install Docker"
apt-get update
apt-get install -y docker.io

echo "[3/8] Start Docker"
systemctl enable docker || true
systemctl start docker || true

echo "[4/8] Remove CRLF and sudo from setup_worker.sh"
sed -i 's/\r$//' setup_worker.sh
sed -i 's/sudo[[:space:]]\+/ /g' setup_worker.sh
sed -i 's/^[[:space:]]*sudo[[:space:]]*//g' setup_worker.sh
sed -i 's/(\s*sudo[[:space:]]*/(/g' setup_worker.sh || true

echo "[5/8] Run setup_worker.sh"
bash setup_worker.sh "$USERNAME" "$PASSWORD" || true

echo "[6/8] Sanitize all shell scripts after extraction"
find . -type f -name "*.sh" -print0 | while IFS= read -r -d '' file; do
  sed -i 's/\r$//' "$file"
  sed -i 's/sudo[[:space:]]\+/ /g' "$file"
  sed -i 's/^[[:space:]]*sudo[[:space:]]*//g' "$file"
done

echo "[7/8] Show remaining sudo occurrences, if any"
grep -RIn "sudo" . --include="*.sh" || true

echo "[8/8] Start worker manually if present"
if [ -f ./start_worker.sh ]; then
  chmod +x ./start_worker.sh
  bash ./start_worker.sh || true
fi

echo
echo "Done. Showing worker log if it exists..."
if [ -f logs/worker.log ]; then
  tail -f logs/worker.log
else
  echo "logs/worker.log not found"
fi