# Quark PHP binaries

PHP 8.4 ZTS builds for Quark v6. Source versions are pinned in `versions.env`, source archives are checked against `sources.sha256`, and Windows SDK dependencies are checked against `windows-deps.sha256`.

## Downloads

The [latest release](https://github.com/Bedrock-Phanatics/PHP-Binaries/releases/tag/pm5-latest) contains Linux x86_64/ARM64, macOS x86_64/ARM64, and Windows x64 builds. The `pm5-latest` and `pm5-php-8.4-latest` tags and `PHP-8.4-...-PM5` filenames remain for existing installers. All runtime archives extract to `bin/`.

Use the Linux `-hosting.tar.gz` archive when a host or file manager cannot preserve symlinks. It contains the same runtime files with library links resolved. Replace the existing server `bin/` directory before extracting a new archive.

The release workflow includes `SHA256SUMS` and separate `Quark-PHP-...-symbols` archives. Production archives omit those debug symbols. Windows requires the [Visual C++ Redistributable](https://aka.ms/vs/17/release/vc_redist.x64.exe).

## Runtime

The build uses PHP 8.4 ZTS, OPcache for CLI, and qthreads as the `pmmpthread` module. JIT is disabled. LevelDB, chunkutils2, crypto, encoding, igbinary, libdeflate, morton, snappy, TOML, and the other bundled extensions remain available for Quark and plugins. `ext-bedwire` is not packaged while its platform support and Quark integration remain unverified.

## Building

On Linux or macOS, install the platform build tools and run:

```sh
./compile.sh -t linux64 -j 4 -P5 -z 8.4 -D -c ./download_cache
```

Use `linux-arm64`, `mac-x86-64`, or `mac-arm64` for other supported targets. `-P5` is the retained build target selector for compatibility with existing automation. `-D` separates debug symbols into `bin-debug/`; the runtime is installed under `bin/`.

On Windows, install Visual Studio 2022, CMake, and Git, then set `PM_VERSION_MAJOR=5` and `PHP_VERSION_BASE=8.4` before running `windows-compile-vs.ps1`. The Windows build writes `bin/` and a separate PHP debug pack.

## Verification

CI builds every supported platform, checks the exact PHP version, architecture, ZTS, required extensions, OPcache, thread and worker behavior, and packaged runtime startup. It repeats thread tests from extracted archives and blocks releases on a failed build or test. Linux hosting archives are checked for broken symlinks. Release jobs verify the complete archive set and write SHA-256 checksums before publishing.

To test a Unix build locally, run `bash tests/test.sh generic bin/php7/bin/php`. On Windows, run `bin\php\php.exe -c bin\php\php.ini tests\generic\smoke.php`. `benchmarks/baseline.php` records startup, throughput, and memory baselines; `Compare PHP compiler options` compares O2 and O3 without changing the release setting.
