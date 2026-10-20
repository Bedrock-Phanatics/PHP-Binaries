#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
	echo "Usage: $0 <legacy PM major version>" >&2
	exit 2
fi

source "$(dirname "$0")/../versions.env"
base="${PHP_VERSION%.*}"
major="$1"
mkdir -p release-assets

for arch in x86_64 arm64; do
	for suffix in '' '-hosting'; do
		name="PHP-$base-Linux-$arch-PM$major$suffix.tar.gz"
		cp "PHP-$base-Linux-$arch-PM$major/$name" "release-assets/$name"
	done
	name="Quark-PHP-$PHP_VERSION-linux-$arch-symbols.tar.gz"
	cp "PHP-$base-Linux-$arch-PM$major/$name" "release-assets/$name"
	name="PHP-$base-MacOS-$arch-PM$major.tar.gz"
	cp "PHP-$base-MacOS-$arch-PM$major/$name" "release-assets/$name"
	name="Quark-PHP-$PHP_VERSION-macos-$arch-symbols.tar.gz"
	cp "PHP-$base-MacOS-$arch-PM$major/$name" "release-assets/$name"
done
name="PHP-$base-Windows-x64-PM$major.zip"
cp "PHP-$base-Windows-x64-PM$major/$name" "release-assets/$name"
name="Quark-PHP-$PHP_VERSION-windows-x64-symbols.zip"
cp "PHP-$base-Windows-x64-PM$major/$name" "release-assets/$name"

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
