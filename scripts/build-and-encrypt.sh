#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_REPO:?}"
: "${PRIVATE_READ_TOKEN:?}"
: "${DISPATCH_DECRYPT_KEY:?}"
: "${INPUT_CERTIFICATE_B64:?}"
: "${SEALED_PAYLOAD_B64:?}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
base64 -d <<< "$INPUT_CERTIFICATE_B64" > "$work/input-cert.pem"
printf '%s\n' "$DISPATCH_DECRYPT_KEY" > "$work/input-key.pem"
base64 -d <<< "$SEALED_PAYLOAD_B64" > "$work/manifest.cms"
if ! openssl cms -decrypt -binary -inform DER -in "$work/manifest.cms" \
  -recip "$work/input-cert.pem" -inkey "$work/input-key.pem" \
  -out "$work/manifest.json" >/dev/null 2>&1; then
  echo 'Could not decrypt private build parameters.'
  exit 1
fi
unset DISPATCH_DECRYPT_KEY
rm -f "$work/input-key.pem"
source_sha="$(jq -r .source_sha "$work/manifest.json")"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || exit 1
jq -r .return_certificate_b64 "$work/manifest.json" | base64 -d > "$work/return-cert.pem"

mkdir private
git -C private init -q > "$work/build.log" 2>&1
git -C private remote add origin "https://github.com/${PRIVATE_REPO}.git" >> "$work/build.log" 2>&1
auth_b64="$(printf 'x-access-token:%s' "$PRIVATE_READ_TOKEN" | base64 -w0)"
set +e
git -C private -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${auth_b64}" \
  fetch --no-tags --depth=1 -q origin "$source_sha" > "$work/build.log" 2>&1
build_status=$?
if [[ "$build_status" == 0 ]]; then
  git -C private checkout --detach -q FETCH_HEAD >> "$work/build.log" 2>&1
  build_status=$?
fi
unset auth_b64 PRIVATE_READ_TOKEN

# Nothing from the private build is written to this public step's stdout/stderr.
if [[ "$build_status" == 0 ]]; then
  ( cd private && bash build.sh ) >> "$work/build.log" 2>&1
  build_status=$?
fi
set -e
printf '%s\n' "$build_status" > "$work/status.txt"
if [[ -d private/dist ]]; then
  tar -czf "$work/artifact.tar.gz" -C private dist
else
  tar -czf "$work/artifact.tar.gz" --files-from /dev/null
fi
tar -cf "$work/result.tar" -C "$work" build.log status.txt artifact.tar.gz
openssl cms -encrypt -binary -aes256 -in "$work/result.tar" \
  -out result.cms -outform DER "$work/return-cert.pem" >/dev/null 2>&1
echo 'Encrypted build result is ready.'
