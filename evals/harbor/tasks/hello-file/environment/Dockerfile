FROM golang:1.26-bookworm

ENV DEBIAN_FRONTEND=noninteractive
ENV GOCACHE=/tmp/go-cache
ENV GOMODCACHE=/tmp/go-mod
ENV GOPATH=/tmp/go-path

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash build-essential ca-certificates curl git python3 \
    && rm -rf /var/lib/apt/lists/*

RUN printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'cd /ollama-src' \
    'exec go run . run --auto-approve-tools "$@"' \
    > /usr/local/bin/ollama-agent-branch \
    && chmod +x /usr/local/bin/ollama-agent-branch

WORKDIR /app
