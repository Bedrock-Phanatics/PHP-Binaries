# Quark PHP binaries

PHP 8.4 ZTS builds for Quark v6. Source versions are pinned in `versions.env`, source archives are checked against `sources.sha256`, and Windows SDK dependencies are checked against `windows-deps.sha256`.

## Downloads

Native packaging targets Linux x86_64 and Windows x64. Existing releases may predate native packaging and must not be used unless their extension versions satisfy Quark's Composer requirements. The `pm5-latest` and `pm5-php-8.4-latest` tags and `PHP-8.4-...-PM5` filenames remain for existing installers. All runtime archives extract to `bin/`.

Use the Linux `-hosting.tar.gz` archive when a host or file manager cannot preserve symlinks. It contains the same runtime files with library links resolved. Replace the existing server `bin/` directory before extracting a new archive.

The release workflow includes `SHA256SUMS` and separate `Quark-PHP-...-symbols` archives. Production archives omit those debug symbols. Windows packages include the app-local MSVC runtime DLLs.

## Runtime

The build uses PHP 8.4 ZTS, OPcache for CLI, and qthreads as the `pmmpthread` module. JIT is disabled. LevelDB, chunkutils2, crypto, encoding, igbinary, libdeflate, morton, snappy, TOML, and the other bundled extensions remain available for Quark and plugins. `ext-bedwire` and the transitional `ext-webrtc` bindings share the pinned, patched libdatachannel runtime. Zig and extension revisions are recorded in `versions.env` and `native-versions.txt`. Quark requires ZTS even though ext-bedwire can also be built against NTS PHP.

## Building

On Linux x86_64, install the platform build tools, Python 3, patchelf and the Zig version from `versions.env`, then run:

```sh
./compile.sh -t linux64 -j 4 -P5 -z 8.4 -D -c ./download_cache
```

ARM64, macOS, static and cross builds are not enabled for native packages. `-P5` is the retained build target selector for compatibility with existing automation. `-D` separates debug symbols into `bin-debug/`; the runtime is installed under `bin/`.

On Windows x64, install Visual Studio 2022 with C++ tools, CMake, Python 3, Git and the pinned Zig version, then set `PM_VERSION_MAJOR=5` and `PHP_VERSION_BASE=8.4` before running `windows-compile-vs.ps1`. The Windows build writes `bin/` and a separate PHP debug pack.

## Verification

CI gates both packaging targets on checks of the exact PHP version, architecture, ZTS, required extensions, OPcache, thread and worker behavior, and packaged runtime startup. It repeats thread tests from extracted archives and blocks releases on a failed build or test. Linux hosting archives are checked for broken symlinks. Release jobs reject missing native DLLs/SOs, runtime DLLs, licenses or manifests, verify the complete archive set, and write SHA-256 checksums before publishing. A successful extension compilation alone does not validate a package.

To test a Unix build locally, run `bash tests/test.sh generic bin/php7/bin/php`. On Windows, run `bin\php\php.exe -c bin\php\php.ini tests\generic\smoke.php`. `benchmarks/baseline.php` records startup, throughput, and memory baselines; `Compare PHP compiler options` compares O2 and O3 without changing the release setting.

The Linux `bin/php7/bin/php` launcher resolves the relocated extension directory and runs `php.bin`. Use the launcher for Composer and Quark so subprocesses inherit the same configuration. Linux SOs use relative loader paths, and Windows runtime DLLs sit beside `php.exe`.

The launchers also select the bundled OpenSSL configuration and provider directory. On Windows, use `bin\php\run-php.cmd` for CLI tools, or set `OPENSSL_CONF` to `bin\php\extras\ssl\openssl.cnf` and `OPENSSL_MODULES` to `bin\php\extras\ssl` before invoking `php.exe` directly. Quark's Windows launchers configure these defaults.
