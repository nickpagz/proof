#!/bin/bash
# Uploads a test image and a test video to the mock CloudUp, S3, WordPress.com and VideoPress
# server and checks every step.
# Usage: Scripts/test-sharing.sh   (after make build)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Proof.app/Contents/MacOS/Proof"
PORT="${PORT:-8765}"
TMP="$(mktemp -d)"
trap 'kill $SERVER 2>/dev/null || true; rm -rf "$TMP"' EXIT

python3 -I "$ROOT/Scripts/mock-share-server.py" "$PORT" &
SERVER=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT/log" >/dev/null && break; sleep 0.1; done

# A small real PNG to upload.
python3 -I -c 'import zlib,struct,sys
def chunk(t,d): return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d))
raw=b"".join(b"\0"+b"\xff\x00\x00"*40 for _ in range(30))
sys.stdout.buffer.write(b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",40,30,8,2,0,0,0))+chunk(b"IDAT",zlib.compress(raw))+chunk(b"IEND",b""))' > "$TMP/test shot.png"

# Stand-in video bytes; the server checks sizes and order, not the codec.
head -c 12000000 /dev/urandom > "$TMP/test clip.mp4"

echo "== CloudUp"
PROOF_CLOUDUP_API="http://127.0.0.1:$PORT/1" PROOF_CLOUDUP_USER=tester PROOF_CLOUDUP_PASSWORD=secret \
    "$APP" --share "$TMP/test shot.png" --to cloudup --title "Test shot" --delete-after
echo "== CloudUp, wrong password (should fail cleanly)"
if PROOF_CLOUDUP_API="http://127.0.0.1:$PORT/1" PROOF_CLOUDUP_USER=tester PROOF_CLOUDUP_PASSWORD=wrong \
    "$APP" --share "$TMP/test shot.png" --to cloudup 2>&1; then echo "FAIL: accepted a wrong password"; exit 1; fi
echo "== CloudUp video"
PROOF_CLOUDUP_API="http://127.0.0.1:$PORT/1" PROOF_CLOUDUP_USER=tester PROOF_CLOUDUP_PASSWORD=secret \
    "$APP" --share "$TMP/test clip.mp4" --to cloudup --title "Test clip" --delete-after
echo "== WordPress.com"
PROOF_WPCOM_API="http://127.0.0.1:$PORT" PROOF_WPCOM_TOKEN=wptoken PROOF_WPCOM_SITE=123 \
    "$APP" --share "$TMP/test shot.png" --to wordpress --title "Test shot" --delete-after
echo "== WordPress.com video (VideoPress)"
PROOF_WPCOM_API="http://127.0.0.1:$PORT" PROOF_WPCOM_TOKEN=wptoken PROOF_WPCOM_SITE=123 \
    "$APP" --share "$TMP/test clip.mp4" --to wordpress --title "Test clip" --delete-after
echo "== WordPress.com video, site without VideoPress (media library)"
PROOF_WPCOM_API="http://127.0.0.1:$PORT" PROOF_WPCOM_TOKEN=wptoken PROOF_WPCOM_SITE=124 \
    "$APP" --share "$TMP/test clip.mp4" --to wordpress --title "Test clip" --delete-after

echo "== Server log"
curl -s "http://127.0.0.1:$PORT/log" | python3 -I -c '
import json, sys
log = json.load(sys.stdin)
events = [e.get("event") for e in log if "event" in e]
errors = [e for e in log if "error" in e and e["error"] != "bad credentials"]
for e in log: print("  ", e)
want = ["cloudup.stream", "cloudup.item", "s3.upload", "cloudup.complete", "cloudup.delete", "wp.upload", "wp.delete",
        "vp.jwt", "vp.create", "vp.chunk", "vp.done", "wp.title", "vp.nojwt"]
missing = [w for w in want if w not in events]
order = [events.index(w) for w in want if w in events]
uploads = [e for e in log if e.get("event") in ("wp.upload", "vp.done", "s3.upload")]
sizes = sorted({e["bytes"] for e in uploads})
ok = (not missing and not errors and order == sorted(order) and all(e.get("png", True) for e in log)
      and 12000000 in sizes and events.count("vp.chunk") == 2 and events.count("wp.upload") == 2 and events.count("wp.delete") == 3)
print("PASS" if ok else f"FAIL missing={missing} errors={errors}")
sys.exit(0 if ok else 1)'
