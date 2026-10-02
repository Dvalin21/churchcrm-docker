#!/usr/bin/env bash
# Build the ChurchCRM production image from the official release artifact.
#
# Why not `docker pull churchcrm/crm`?  The upstream publish workflow
# (.github/workflows/docker-release.yml) has never run, so the tags documented in
# docker/DOCKER_RELEASE.md (latest-php8-apache, <version>-php8-apache) do not exist
# on Docker Hub.  The only images there are from 2018.
#
# This script uses upstream's own CI-validated Dockerfiles
# (docker/Dockerfile.churchcrm-apache-php8, target `prod`) against a release zip
# whose SHA-256 is verified against GitHub's published asset digest.
set -euo pipefail

VERSION="${VERSION:-7.7.1}"
# SHA-256 of ChurchCRM-7.7.1.zip as recorded in the GitHub release API.
SHA256="${SHA256:-81d487bcc205a794433d98be961618b03c52a245dcecff31f101a228e9ba7951}"
# Image namespace is dvalin21 (this packaging repo). Upstream publishes nothing to
# Docker Hub -- their publish workflow has never run -- so the official
# churchcrm/crm tags do not exist. See README.md.
IMAGE="${IMAGE:-dvalin21/churchcrm:7.7.1-apache}"

here="$(cd "$(dirname "$0")" && pwd)"
repo="${REPO:-$here/upstream}"
zip="$here/ChurchCRM-$VERSION.zip"
ctx="$here/build-context"

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
command -v curl     >/dev/null || { echo "curl not found" >&2; exit 1; }

# Upstream Dockerfiles + the release-context extractor.
if [ ! -f "$repo/docker/Dockerfile.churchcrm-apache-php8" ]; then
  echo "==> cloning upstream (shallow)"
  rm -rf "$repo"
  git clone --depth 1 https://github.com/churchcrm/crm.git "$repo"
fi

if [ ! -f "$zip" ]; then
  echo "==> downloading ChurchCRM-$VERSION.zip"
  curl -fsSL -o "$zip" \
    "https://github.com/ChurchCRM/CRM/releases/download/$VERSION/ChurchCRM-$VERSION.zip"
fi

echo "==> verifying checksum"
echo "$SHA256  $zip" | sha256sum -c -

echo "==> preparing build context"
# prepare-release-context.py strips the churchcrm/ wrapper, rejects symlinks and
# refuses to carry a Config.php or any .env into the image.
rm -rf "$ctx"
python3 "$repo/docker/prepare-release-context.py" "$zip" "$ctx"
mkdir -p "$ctx/apache"
cp "$repo/docker/apache/default.conf" "$ctx/apache/default.conf"

echo "==> building $IMAGE"
docker build \
  --target prod \
  -f "$repo/docker/Dockerfile.churchcrm-apache-php8" \
  -t "$IMAGE" \
  "$ctx"

echo
echo "==> built $IMAGE"
docker images "$IMAGE" --format '  {{.Repository}}:{{.Tag}}  {{.Size}}'
echo
echo "Next: cp .env.example .env, edit it, then: docker compose up -d"