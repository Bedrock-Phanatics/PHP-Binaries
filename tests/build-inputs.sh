#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$root/compile.sh" "$work/compile.sh"
if (cd "$work" && bash compile.sh > output 2>&1); then
	echo "Accepted missing versions.env" >&2
	exit 1
fi
grep -F versions.env "$work/output"
cp "$root/versions.env" "$work/versions.env"
if (cd "$work" && bash compile.sh > output 2>&1); then
	echo "Accepted missing sources.sha256" >&2
	exit 1
fi
grep -F 'Missing sources.sha256' "$work/output"
