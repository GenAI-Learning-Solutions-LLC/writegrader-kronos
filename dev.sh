#!/usr/bin/env sh
trap 'kill $SERVER_PID 2>/dev/null; exit' EXIT INT TERM
zig build run &
SERVER_PID=$!
now=$(date +%s)
while true; do
    sleep 1
    for filename in $(fd | grep -E "(\.html|\.zig|\.js|\.sh|\.css)"); do
        [ -f "$filename" ] || continue
        mtime=$(stat -c %Y "$filename" 2>/dev/null || stat -f %m "$filename" 2>/dev/null)
        if [ "$mtime" -gt "$now" ]; then
            echo "$filename modified"
            kill $SERVER_PID
            zig build run &
            SERVER_PID=$!
            now=$(date +%s)
        fi
    done
done
