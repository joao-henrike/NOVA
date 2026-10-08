#!/usr/bin/env bash
set -euo pipefail

VERSION="8.29.1"
ARCHIVE="$RUNNER_TEMP/gitleaks_${VERSION}_linux_x64.tar.gz"
URL="https://github.com/gitleaks/gitleaks/releases/download/v${VERSION}/gitleaks_${VERSION}_linux_x64.tar.gz"
SHA256="e4eb209d04e20339d77122a3bdf9cd41351255cfb27ebcb75e85325e04f88924"

curl --fail --silent --show-error --location "$URL" -o "$ARCHIVE"
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | sha256sum -c -
tar -xzf "$ARCHIVE" -C "$RUNNER_TEMP"
"$RUNNER_TEMP/gitleaks" git --no-banner --redact --verbose .
