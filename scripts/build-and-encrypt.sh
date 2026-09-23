#!/usr/bin/env bash
set -euo pipefail
: "${CERTIFICATE_B64:?}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
base64 -d <<< "$CERTIFICATE_B64" > "$work/cert.pem"

# Nothing from the private build is written to this public step's stdout/stderr.
set +e
( cd private && bash build.sh ) > "$work/build.log" 2>&1
build_status=$?
set -e
printf '%s\n' "$build_status" > "$work/status.txt"
if [[ -d private/dist ]]; then
  tar -czf "$work/artifact.tar.gz" -C private dist
else
  tar -czf "$work/artifact.tar.gz" --files-from /dev/null
fi
tar -cf "$work/result.tar" -C "$work" build.log status.txt artifact.tar.gz
openssl cms -encrypt -binary -aes256 -in "$work/result.tar" \
  -out result.cms -outform DER "$work/cert.pem" >/dev/null 2>&1
echo 'Encrypted build result is ready.'
