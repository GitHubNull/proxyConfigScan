#!/usr/bin/env bash
# 生成代理配置测试二维码（Python 依赖只装进仓库内 uv 虚拟环境）
#
# 用法：script/gen-test-qr.sh <host> [port]   默认端口 8080
# 产物：tmp/qr-<host>-<port>.png，并用 xdg-open 预览
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:?用法: $0 <host> [port]}"
PORT="${2:-8080}"

VENV="$ROOT_DIR/tmp/.venv"
if [ ! -x "$VENV/bin/python" ]; then
    echo ">> 创建 uv 虚拟环境（仓库内 tmp/.venv）..."
    (cd "$ROOT_DIR/tmp" && uv venv .venv)
    uv pip install --python "$VENV/bin/python" "qrcode[pil]"
fi

OUT="$ROOT_DIR/tmp/qr-${HOST//[^a-zA-Z0-9_.-]/_}-$PORT.png"
"$VENV/bin/python" - "$HOST" "$PORT" "$OUT" <<'PY'
import sys
import qrcode

host, port, out = sys.argv[1], sys.argv[2], sys.argv[3]
uri = f"http://{host}:{port}"
img = qrcode.make(uri)
img.save(out)
print(f"二维码内容: {uri}")
print(f"已生成: {out}")
PY

xdg-open "$OUT" >/dev/null 2>&1 || true
