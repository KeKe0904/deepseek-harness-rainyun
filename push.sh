#!/bin/bash
# push.sh — tag the local image for Docker Hub and push (rc + latest).
#
# Usage:
#   DOCKERHUB_USERNAME=<user> DOCKERHUB_TOKEN=<token> ./push.sh
#   ./push.sh <username> <access-token>          # positional alternative
#   DSH_VERSION=0.1.0-rc.5 ./push.sh ...          # push a different build
#
# An access token is a "Personal Access Token" with Read/Write/Delete scope,
# created at https://hub.docker.com/settings/security.
set -euo pipefail

USERNAME="${1:-${DOCKERHUB_USERNAME:-}}"
TOKEN="${2:-${DOCKERHUB_TOKEN:-}}"
DSH_VERSION="${DSH_VERSION:-0.1.0-rc.6-6}"
LOCAL_IMAGE="deepseek-harness:${DSH_VERSION}"
REMOTE_IMAGE="${USERNAME}/deepseek-harness"

if [ -z "$USERNAME" ] || [ -z "$TOKEN" ]; then
  echo "usage: DOCKERHUB_USERNAME=... DOCKERHUB_TOKEN=... ./push.sh  (or: ./push.sh <user> <token>)" >&2
  exit 1
fi

if ! docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
  echo "error: local image $LOCAL_IMAGE not found — run: docker build -t $LOCAL_IMAGE ." >&2
  exit 1
fi

echo "==> tagging $REMOTE_IMAGE:${DSH_VERSION} and :latest"
docker tag "$LOCAL_IMAGE" "$REMOTE_IMAGE:${DSH_VERSION}"
docker tag "$LOCAL_IMAGE" "$REMOTE_IMAGE:latest"

echo "==> logging in to Docker Hub (token)"
echo "$TOKEN" | docker login --username "$USERNAME" --password-stdin

echo "==> pushing"
docker push "$REMOTE_IMAGE:${DSH_VERSION}"
docker push "$REMOTE_IMAGE:latest"

echo "==> done:"
echo "   ${REMOTE_IMAGE}:${DSH_VERSION}"
echo "   ${REMOTE_IMAGE}:latest"
echo "用此地址在雨云 RCA 模板「镜像」字段填写: docker.io/${REMOTE_IMAGE}:${DSH_VERSION}"
