#!/bin/sh
set -e

HOST="ec2-user@35.160.70.19"
KEY="../auto-server.pem"
REMOTE_DIR="/home/writegrader/app"
STAGING="/tmp/wg-staging"

echo "Syncing source to staging..."
rsync -avz \
  -e "ssh -i $KEY" \
  --exclude='.zig-cache' \
  --exclude='zig-out' \
  --exclude='.git' \
  --exclude='run.sh' \
  --exclude='config.json' \
  --exclude='.env' \
  --exclude='*.db' \
  --exclude='*.db-shm' \
  --exclude='*.db-wal' \
  . "$HOST:$STAGING/"

echo "Copying to beta dir..."
ssh -i "$KEY" "$HOST" "doas rsync -a --exclude='run.sh' --exclude='config.json' --exclude='.env' --exclude='*.db' --exclude='*.db-shm' --exclude='*.db-wal' $STAGING/ $REMOTE_DIR/"

#echo "Building on server..."
#ssh -i "$KEY" "$HOST" "cd $REMOTE_DIR && doas -u writegrader zig build -Doptimize=ReleaseFast"

echo "Deploy complete."

