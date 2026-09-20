#!/usr/bin/env bash
set -euo pipefail

PROJECT_REF="${SUPABASE_PROJECT_REF:-}"
PROJECT_URL="${SUPABASE_URL:-}"
PUBLISHABLE_KEY="${SUPABASE_PUBLISHABLE_KEY:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_TOOLS_DIR="$SCRIPT_DIR/.tools"
LOCAL_SUPABASE_BIN="$LOCAL_TOOLS_DIR/supabase"
SUPABASE_CLI_VERSION="2.111.0"

if [[ -z "$PROJECT_REF" ]]; then
  read -r -p "Supabase project reference: " PROJECT_REF
fi
if [[ -z "$PROJECT_URL" ]]; then
  PROJECT_URL="https://${PROJECT_REF}.supabase.co"
fi
if [[ -z "$PUBLISHABLE_KEY" ]]; then
  read -r -p "Supabase publishable key: " PUBLISHABLE_KEY
fi

install_local_supabase_cli() {
  local machine_arch release_arch expected_sha256
  local archive_name download_url temp_dir archive_path

  machine_arch="$(uname -m)"
  case "$machine_arch" in
    arm64|aarch64)
      release_arch="arm64"
      expected_sha256="f2cd4fbfcdf5bd6753ab85468b3e1711f80d1b212f4a43f1a998fafb19962762"
      ;;
    x86_64|amd64)
      release_arch="amd64"
      expected_sha256="42ef21b0c2ef52cc40597490260dfbbe6f484fa1ba5cea26475281f0e3eefef4"
      ;;
    *)
      echo "暂不支持这台 Mac 的处理器架构：$machine_arch"
      exit 1
      ;;
  esac

  for required_command in curl tar shasum; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
      echo "缺少系统命令：$required_command，无法自动安装 Supabase CLI。"
      exit 1
    fi
  done

  archive_name="supabase_${SUPABASE_CLI_VERSION}_darwin_${release_arch}.tar.gz"
  download_url="https://github.com/supabase/cli/releases/download/v${SUPABASE_CLI_VERSION}/${archive_name}"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/fridge-supabase-cli.XXXXXX")"
  archive_path="$temp_dir/$archive_name"

  echo "未找到 Supabase CLI，正在下载官方版本 v${SUPABASE_CLI_VERSION} 到项目内部……"
  curl --fail --location --retry 3 --output "$archive_path" "$download_url"
  printf '%s  %s\n' "$expected_sha256" "$archive_path" | shasum -a 256 --check

  mkdir -p "$LOCAL_TOOLS_DIR"
  tar -xzf "$archive_path" -C "$temp_dir"
  mv "$temp_dir/supabase" "$LOCAL_SUPABASE_BIN"
  chmod 755 "$LOCAL_SUPABASE_BIN"
  rm -rf -- "$temp_dir"
  echo "Supabase CLI 已安装：$LOCAL_SUPABASE_BIN"
}

if command -v supabase >/dev/null 2>&1; then
  SUPABASE_BIN="$(command -v supabase)"
elif [[ -x "$LOCAL_SUPABASE_BIN" ]]; then
  SUPABASE_BIN="$LOCAL_SUPABASE_BIN"
else
  install_local_supabase_cli
  SUPABASE_BIN="$LOCAL_SUPABASE_BIN"
fi

echo "Supabase 会要求登录；只在官方 CLI 中输入 Personal Access Token。"
"$SUPABASE_BIN" login

cd "$SCRIPT_DIR"
"$SUPABASE_BIN" link --project-ref "$PROJECT_REF"
"$SUPABASE_BIN" db push --dry-run
"$SUPABASE_BIN" db push

read -r -p "请输入 Authentication > Users 中唯一账号的 User UID: " FRIDGE_OWNER_ID
read -r -s -p "请输入 Qwen / DashScope API Key（输入不会显示）: " DASHSCOPE_API_KEY
echo

TOKEN_FILE="$SCRIPT_DIR/.fridge_device_token"
if [[ -f "$TOKEN_FILE" ]]; then
  FRIDGE_DEVICE_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
else
  FRIDGE_DEVICE_TOKEN="$(openssl rand -hex 32)"
  umask 077
  printf '%s\n' "$FRIDGE_DEVICE_TOKEN" > "$TOKEN_FILE"
fi

APP_TOKEN_FILE="$SCRIPT_DIR/.fridge_app_token"
if [[ -f "$APP_TOKEN_FILE" ]]; then
  FRIDGE_APP_TOKEN="$(tr -d '\r\n' < "$APP_TOKEN_FILE")"
else
  FRIDGE_APP_TOKEN="$(openssl rand -hex 32)"
  umask 077
  printf '%s\n' "$FRIDGE_APP_TOKEN" > "$APP_TOKEN_FILE"
fi

"$SUPABASE_BIN" secrets set \
  "DASHSCOPE_API_KEY=$DASHSCOPE_API_KEY" \
  "DASHSCOPE_BASE_URL=https://dashscope-intl.aliyuncs.com/compatible-mode/v1" \
  "QWEN_TEXT_MODEL=qwen-plus" \
  "QWEN_VISION_MODEL=qwen3-vl-plus" \
  "FRIDGE_OWNER_ID=$FRIDGE_OWNER_ID" \
  "FRIDGE_DEVICE_TOKEN=$FRIDGE_DEVICE_TOKEN" \
  "FRIDGE_APP_TOKEN=$FRIDGE_APP_TOKEN" \
  --project-ref "$PROJECT_REF"

unset DASHSCOPE_API_KEY

"$SUPABASE_BIN" functions deploy generate-recipe --project-ref "$PROJECT_REF" --use-api --no-verify-jwt
"$SUPABASE_BIN" functions deploy ingest-event --project-ref "$PROJECT_REF" --use-api --no-verify-jwt
"$SUPABASE_BIN" functions deploy app-api --project-ref "$PROJECT_REF" --use-api --no-verify-jwt

PI_ENV="$ROOT_DIR/pi/fridge_cloud.env"
umask 077
{
  printf 'SUPABASE_URL=%s\n' "$PROJECT_URL"
  printf 'SUPABASE_PUBLISHABLE_KEY=%s\n' "$PUBLISHABLE_KEY"
  printf 'FRIDGE_DEVICE_TOKEN=%s\n' "$FRIDGE_DEVICE_TOKEN"
} > "$PI_ENV"

echo
echo "部署完成。树莓派环境文件已生成：$PI_ENV"
echo "手机 App Token 已保存：$APP_TOKEN_FILE"
echo "把该文件内容填入 iOS 的 AppSecrets.swift，但不要提交真实值。"
echo "请不要上传 .fridge_device_token、.fridge_app_token 或 fridge_cloud.env。"
