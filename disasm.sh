#!/bin/sh

if [ $# -lt 2 ]; then
    echo "usage: $(basename "$0") <binary> <function-pattern>" >&2
    exit 1
fi

binary="$1"
pattern="$2"

if [ ! -f "$binary" ]; then
    echo "binary not found: $binary" >&2
    exit 1
fi

matches=$(nm "$binary" 2>/dev/null | grep "$pattern" | awk '{print $3}')

if [ -z "$matches" ]; then
    echo "no symbols matching '$pattern'" >&2
    exit 1
fi

count=$(echo "$matches" | wc -l | tr -d ' ')

output=$(echo "$matches" | while IFS= read -r sym; do
    objdump -d -M intel --no-show-raw-insn --disassemble="$sym" "$binary"
    echo ""
done)

echo "$output" | nvim - -c 'set filetype=nasm' -c 'set nomodified' -c 'set noswapfile'
