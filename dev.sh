#!/usr/bin/env bash
set -m
source .env
start_server() {
    zig build run &
    SERVER_PID=$!
}

stop_server() {
    kill -- -$SERVER_PID 2>/dev/null
    sleep 2
}

trap 'stop_server; exit' EXIT INT TERM

start_server
now=$(date +%s)

while true; do
    sleep 1
    changed=0
    for filename in $(fd | grep -E "\.(html|zig|js|sh|css)$"); do
        [ -f "$filename" ] || continue
        mtime=$(stat -c %Y "$filename" 2>/dev/null || stat -f %m "$filename" 2>/dev/null)
        if [ "$mtime" -gt "$now" ]; then
            echo "$filename modified"
            changed=1
            break
        fi
    done
    if [ "$changed" -eq 1 ]; then
        stop_server
        now=$(date +%s)
        start_server
        echo "restarted: $SERVER_PID"
    fi
done
