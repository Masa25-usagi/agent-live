#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")" && pwd)"
TASK_CLIENT="${1:-$HOME/.config/gws/client_secret.json}"
if [[ ! -f "$TASK_CLIENT" ]]; then
  echo 'GoogleのデスクトップOAuthクライアントJSONが見つかりません。導入ガイドのGoogle Drive接続を確認してください。'
  exit 1
fi
exec python3 "$TASK_ROOT/script/setup_drive.py" "$TASK_CLIENT"
