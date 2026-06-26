#!/usr/bin/env bash
set -u

reward=0

if [ -f /app/hello.txt ] && [ "$(cat /app/hello.txt)" = "Hello, world!" ]; then
  reward=1
fi

echo "$reward" > /logs/verifier/reward.txt

if [ "$reward" -eq 1 ]; then
  exit 0
fi

echo "expected /app/hello.txt to contain exactly 'Hello, world!'" >&2
exit 1
