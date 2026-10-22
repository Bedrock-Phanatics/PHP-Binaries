#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
	echo "Usage: $0 <legacy PM major version>" >&2
	exit 2
fi

source "$(dirname "$0")/../versions.env"
base="${PHP_VERSION%.*}"
major="$1"
mkdir release-assets

for suffix in '' '-hosting'; do
	name="PHP-$base-Linux-x86_64-PM$major$suffix.tar.gz"
	cp "PHP-$base-Linux-x86_64-PM$major/$name" "release-assets/$name"
done
name="Quark-PHP-$PHP_VERSION-linux-x86_64-symbols.tar.gz"
cp "PHP-$base-Linux-x86_64-PM$major/$name" "release-assets/$name"
name="PHP-$base-Windows-x64-PM$major.zip"
cp "PHP-$base-Windows-x64-PM$major/$name" "release-assets/$name"
name="Quark-PHP-$PHP_VERSION-windows-x64-symbols.zip"
cp "PHP-$base-Windows-x64-PM$major/$name" "release-assets/$name"

python3 "$(dirname "$0")/validate-package.py" release-assets/PHP-*.tar.gz release-assets/PHP-*.zip

for archive in release-assets/*.tar.gz; do
	tar -tzf "$archive" > /dev/null
done
for archive in release-assets/*.zip; do
	unzip -tqq "$archive"
done

(
	cd release-assets
	sha256sum ./*.tar.gz ./*.zip > SHA256SUMS
	sha256sum -c SHA256SUMS
)
