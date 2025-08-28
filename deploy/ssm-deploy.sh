#!/usr/bin/env bash
set -Eeuo pipefail

# Args from CI
BUCKET="${1?bucket}"
KEY="${2?key}"               # e.g., releases/<sha>.zip
PARAM_PATH="${3?/ssm/path}" # e.g., /simple-node-backend/prod
APP_DIR="${4?/app/dir}"     # e.g., /opt/apps/simple-node-backend
SERVICE_PORT="${5?port}"    # e.g., 3000

RELEASE_SHA="$(basename "$KEY" .zip)"
RELEASE_DIR="$APP_DIR/releases/$RELEASE_SHA"
CURRENT_LINK="$APP_DIR/current"
PREV_TARGET="$(readlink -f "$CURRENT_LINK" || true)"

echo "==> Deploying $KEY to $RELEASE_DIR"

mkdir -p "$RELEASE_DIR"
aws s3 cp "s3://$BUCKET/$KEY" "/tmp/$RELEASE_SHA.zip"
unzip -o "/tmp/$RELEASE_SHA.zip" -d "$RELEASE_DIR"
rm -f "/tmp/$RELEASE_SHA.zip"

# Render .env from Parameter Store
echo "==> Rendering .env from $PARAM_PATH"
aws ssm get-parameters-by-path --path "$PARAM_PATH" --with-decryption \
  --query "Parameters[].{Name:Name,Value:Value}" --output text > /tmp/params.txt

rm -f "$RELEASE_DIR/.env"
while IFS=$'\t' read -r name value; do
  key="$(basename "$name")"
  printf "%s=%s\n" "$key" "$value" >> "$RELEASE_DIR/.env"
done < /tmp/params.txt
rm -f /tmp/params.txt

# Install prod deps
cd "$RELEASE_DIR"
npm ci --omit=dev

# Atomic symlink swap
ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"

# Start/reload PM2
export PATH="$PATH:/usr/bin:/usr/local/bin"
if pm2 describe simple-node-backend >/dev/null 2>&1; then
  pm2 reload simple-node-backend --update-env
else
  pm2 start "$CURRENT_LINK/ecosystem.config.js"
fi
pm2 save || true

# Health check
echo "==> Health check on port $SERVICE_PORT"
sleep 2
set +e
curl -fsS "http://localhost:$SERVICE_PORT/health" >/dev/null
HC=$?
set -e

if [ "$HC" -ne 0 ]; then
  echo "!! Health check FAILED, rolling back"
  if [ -n "$PREV_TARGET" ] && [ -d "$PREV_TARGET" ]; then
    ln -sfn "$PREV_TARGET" "$CURRENT_LINK"
    pm2 reload simple-node-backend || true
  fi
  exit 1
fi

echo "==> Deploy success: $RELEASE_SHA"
