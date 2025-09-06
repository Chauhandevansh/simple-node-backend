#!/usr/bin/env bash
set -euo pipefail

# Args from CI
BUCKET="${1?bucket}"
KEY="${2?key}"               # e.g., releases/<sha>.zip
PARAM_PATH="${3?/ssm/path}"  # e.g., /simple-node-backend/prod
APP_DIR="${4?/app/dir}"      # e.g., /opt/apps/simple-node-backend
SERVICE_PORT="${5?port}"     # e.g., 3000

RELEASE_SHA="$(basename "$KEY" .zip)"
RELEASE_DIR="$APP_DIR/releases/$RELEASE_SHA"
CURRENT_LINK="$APP_DIR/current"
PREV_TARGET="$(readlink -f "$CURRENT_LINK" || true)"

echo "==> Deploying $KEY to $RELEASE_DIR"

# 1️⃣ Prepare release directory
mkdir -p "$RELEASE_DIR"

# 2️⃣ Download and unzip release
aws s3 cp "s3://$BUCKET/$KEY" "/tmp/$RELEASE_SHA.zip"
unzip -o "/tmp/$RELEASE_SHA.zip" -d "$RELEASE_DIR"
rm -f "/tmp/$RELEASE_SHA.zip"

# 2.1️⃣ Ensure clean node_modules
rm -rf "$RELEASE_DIR/node_modules"

# 3️⃣ Render .env from Parameter Store
echo "==> Rendering .env from $PARAM_PATH"
aws ssm get-parameters-by-path --path "$PARAM_PATH" --with-decryption \
  --query "Parameters[].{Name:Name,Value:Value}" --output text > /tmp/params.txt

rm -f "$RELEASE_DIR/.env"
while IFS=$'\t' read -r name value; do
  key="$(basename "$name")"
  printf "%s=%s\n" "$key" "$value" >> "$RELEASE_DIR/.env"
done < /tmp/params.txt
rm -f /tmp/params.txt

# 4️⃣ Install prod dependencies inside release directory
cd "$RELEASE_DIR"
npm ci --omit=dev

# 5️⃣ Atomic swap (update current symlink AFTER installing)
ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"

# 6️⃣ PM2 management
export PATH="$PATH:/usr/bin:/usr/local/bin"

# Stop old process if running
su - ubuntu -c "pm2 delete simple-node-backend || true"

# Start using the symlinked release with updated environment
# su - ubuntu -c "NODE_ENV=production pm2 start '$CURRENT_LINK/dist/server.js' --name simple-node-backend --update-env"
su - ubuntu -c "pm2 start '$CURRENT_LINK/dist/server.js' --name simple-node-backend --env-file '$CURRENT_LINK/.env' --update-env"
su - ubuntu -c "pm2 save" || true

# 7️⃣ Health check with retries
echo "==> Health check on port $SERVICE_PORT"

max_retries=15
retry_delay=3
success=0

for i in $(seq 1 $max_retries); do
    # Check if PM2 process is online
    status=$(su - ubuntu -c "pm2 describe simple-node-backend | grep status | awk '{print \$4}'")
    if [ "$status" = "online" ]; then
        # Try health endpoint
        if curl -fsS "http://127.0.0.1:$SERVICE_PORT/health" >/dev/null; then
            success=1
            break
        fi
    fi
    echo "Health check failed, retrying ($i/$max_retries)..."
    sleep $retry_delay
done

if [ "$success" -ne 1 ]; then
    echo "!! Health check FAILED, rolling back"

    # Rollback to previous release if exists
    if [ -n "$PREV_TARGET" ] && [ -d "$PREV_TARGET" ]; then
        ln -sfn "$PREV_TARGET" "$CURRENT_LINK"
        su - ubuntu -c "pm2 reload simple-node-backend || true"
    fi

    exit 1
fi

echo "==> Deploy success: $RELEASE_SHA"