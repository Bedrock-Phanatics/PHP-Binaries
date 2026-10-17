#!/usr/bin/env bash
set -u

if [ "$#" -ne 2 ]; then
	echo "Usage: $0 <suite> <php binary>" >&2
	exit 2
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$DIR/$1"
PHP_BINARIES="$2"

if [ ! -d "$TEST_DIR" ] || [ ! -x "$PHP_BINARIES" ]; then
	echo "Test suite or PHP binary is missing" >&2
	exit 2
fi

PHP_BINARIES="$(cd "$(dirname "$PHP_BINARIES")" && pwd)/$(basename "$PHP_BINARIES")"
export PHP_BINARIES
php_dir="$(dirname "$PHP_BINARIES")"
php_args=(-c "$php_dir/php.ini")
if [[ "$PHP_BINARIES" != *.exe ]]; then
	opcache="$(find "$php_dir/../lib/php/extensions" -name opcache.so -print -quit)"
	if [ -z "$opcache" ]; then
		echo "OPcache library is missing" >&2
		exit 2
	fi
	php_args+=(-d "extension_dir=$(dirname "$opcache")")
fi

shopt -s nullglob
tests=("$TEST_DIR"/*.php "$TEST_DIR"/*.sh)
if [ "${#tests[@]}" -eq 0 ]; then
	echo "No tests found in $TEST_DIR" >&2
	exit 2
fi

failed=0
for test in "${tests[@]}"; do
	echo "Running $(basename "$test")"
	if [[ "$test" == *.php ]]; then
		"$PHP_BINARIES" "${php_args[@]}" "$test" || failed=$((failed + 1))
	else
		bash "$test" || failed=$((failed + 1))
	fi
done

echo "Ran ${#tests[@]} tests, $failed failed."
if [ "$failed" -ne 0 ]; then
	exit 1
fi
