#!/bin/sh
set -e

HOST="ec2-user@35.160.70.19"
KEY="../auto-server.pem"
REMOTE_DIR="/home/writegrader/app"

echo "Syncing source..."
rsync -avz  \
  -e "ssh -i $KEY" \
  --exclude='.zig-cache' \
  --exclude='zig-out' \
  --exclude='.git' \
    --exclude='config.json' \
  --exclude='.env' \
  --exclude='*.db' \
  --exclude='*.db-shm' \
  --exclude='*.db-wal' \
  . "$HOST:$REMOTE_DIR"

echo "Building on server..."
ssh -i "$KEY" "$HOST" "cd $REMOTE_DIR && zig build -Doptimize=ReleaseFast"

echo "Deploy complete."
