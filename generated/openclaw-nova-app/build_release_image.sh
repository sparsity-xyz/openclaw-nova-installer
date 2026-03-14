#!/usr/bin/env bash

set -euo pipefail

MANIFEST_FILE="${1:-enclaver.yaml}"
TARGET_IMAGE="${TARGET_IMAGE:-openclaw-manager:latest}"
SLEEVE_IMAGE="${SLEEVE_IMAGE:-public.ecr.aws/d4t4u8d2/sparsity-ai/sleeve:latest}"

build_dir="$(mktemp -d /tmp/openclaw-release-build.XXXXXX)"
cleanup() {
  rm -rf "${build_dir}"
}
trap cleanup EXIT

eif_path="${build_dir}/application.eif"
cp "${MANIFEST_FILE}" "${build_dir}/enclaver.yaml"

enclaver build -f "${MANIFEST_FILE}" --eif-only "${eif_path}"

cat > "${build_dir}/Dockerfile" <<DOCKERFILE
FROM ${SLEEVE_IMAGE}
COPY enclaver.yaml /enclave/enclaver.yaml
COPY application.eif /enclave/application.eif
DOCKERFILE

docker build -t "${TARGET_IMAGE}" "${build_dir}"
docker image inspect "${TARGET_IMAGE}" --format '{{.Id}} {{.Created}}'
