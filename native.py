import argparse
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess


ROOT = Path(__file__).resolve().parent
VERSIONS = dict(line.split("=", 1) for line in (ROOT / "versions.env").read_text().splitlines())


def run(*args, cwd=None, env=None):
    result = subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        print(result.stdout, flush=True)
        result.check_returncode()
    return result.stdout.strip()


def checkout(url, revision, destination):
    if not destination.exists():
        run("git", "clone", "--no-checkout", url, destination)
        run("git", "checkout", "--detach", revision, cwd=destination)
    if run("git", "rev-parse", "HEAD", cwd=destination) != revision:
        raise RuntimeError(f"Unexpected source revision in {destination}")


def prepare(work, windows, jobs):
    extension = work / "ext-bedwire"
    checkout("https://github.com/Bedrock-Phanatics/ext-bedwire.git", VERSIONS["EXT_BEDWIRE_COMMIT"], extension)
    if run("zig", "version") != VERSIONS["ZIG_VERSION"]:
        raise RuntimeError("The pinned Zig version is required")
    run("zig", "build", "--fetch", cwd=extension)
    zon = (extension / "build.zig.zon").read_text()
    package = re.search(r'\.nethernet\s*=\s*\.\{.*?\.hash\s*=\s*"([^"]+)"', zon, re.S)
    if package is None:
        raise RuntimeError("Missing pinned nethernet package")
    nethernet = extension / "zig-pkg" / package[1]
    prefix = work / "native"
    env = os.environ.copy()
    for key in ("CFLAGS", "CXXFLAGS", "LDFLAGS", "CPPFLAGS", "LIBRARY_PATH", "PKG_CONFIG_PATH"):
        env.pop(key, None)
    if not windows:
        env["NETHERNET_NATIVE_PREFIX"] = str(prefix)
        subprocess.run(["sh", str(nethernet / "tools/setup-native.sh")], env=env, check=True)
        return

    rtc = work / "libdatachannel"
    tls = work / "mbedtls"
    checkout("https://github.com/paullouisageneau/libdatachannel.git", "443f6934d9007eb7076ab7825ba330f355fcbead", rtc)
    checkout("https://github.com/Mbed-TLS/mbedtls.git", "068ff080b369adfac81509f9b57b2afabaf82dc5", tls)
    for source in (rtc, tls):
        run("git", "submodule", "update", "--init", "--recursive", cwd=source)
    for setting in ("set MBEDTLS_SSL_DTLS_SRTP", "set MBEDTLS_AES_ROM_TABLES", "unset MBEDTLS_DEBUG_C", "unset MBEDTLS_SELF_TEST"):
        run("python", tls / "scripts/config.py", "-f", tls / "include/mbedtls/mbedtls_config.h", *setting.split())
    patches = [nethernet / f"tools/libdatachannel-{name}.patch" for name in (
        "bounds", "mbedtls-link-order", "threadpool", "dtls-timer", "sctp-timer-wheel",
        "juice-timers", "sctp-receive-pause", "dtls-incoming", "juice-mux-routing", "sctp-unacked", "closed-callbacks",
    )]
    # Existing builds must contain exactly the pinned patches.
    if not (work / "patched").exists():
        for patch in patches:
            run("git", "apply", patch, cwd=rtc)
        (work / "patched").touch()
    common = ["-G", "Visual Studio 17 2022", "-A", "x64", "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
              "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL", f"-DCMAKE_INSTALL_PREFIX={prefix}"]
    for source, options in (
        (tls, ["-DENABLE_TESTING=OFF", "-DENABLE_PROGRAMS=OFF", "-DBUILD_SHARED_LIBS=OFF"]),
        (rtc, ["-DNO_TESTS=ON", "-DNO_EXAMPLES=ON", "-DNO_MEDIA=ON", "-DNO_WEBSOCKET=ON",
               "-DUSE_MBEDTLS=ON", "-DBUILD_SHARED_LIBS=ON", f"-DCMAKE_PREFIX_PATH={prefix}"]),
    ):
        build = work / f"{source.name}-build"
        run("cmake", "-S", source, "-B", build, *common, *options, env=env)
        run("cmake", "--build", build, "--config", "Release", "--parallel", jobs, "--target", "install", env=env)
    # Zig consumes this COFF import archive through nethernet's existing build API.
    shutil.copy2(prefix / "lib/datachannel.lib", prefix / "lib/libdatachannel.dll.a")


def install(work, php_source, runtime, windows):
    extension = work / "ext-bedwire"
    prefix = work / "native"
    php = runtime / ("php.exe" if windows else "bin/php")
    if run(php, "-n", "-r", "echo PHP_ZTS ? 'zts' : 'nts';") != "zts":
        raise RuntimeError("Quark requires a ZTS runtime")
    args = ["zig", "build", "-Doptimize=ReleaseSafe", f"-Dnative-prefix={prefix}", "-Dcpu=baseline"]
    if windows:
        args += ["-Dtarget=x86_64-windows-msvc", "-Dwindows-zts=true", f"-Dphp-include-dir={php_source}",
                 f"-Dphp-lib-dir={php_source / 'x64/Release_TS'}"]
        modules = runtime / "ext"
        libraries = runtime
        name = "php_bedwire.dll"
        for library in (prefix / "bin").glob("*.dll"):
            shutil.copy2(library, libraries / library.name)
        vswhere = Path(os.environ["ProgramFiles(x86)"]) / "Microsoft Visual Studio/Installer/vswhere.exe"
        vs = Path(run(vswhere, "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"))
        crt = sorted((vs / "VC/Redist/MSVC").glob("*/x64/Microsoft.VC143.CRT"))
        if not crt:
            raise RuntimeError("MSVC x64 redistributable DLLs are missing")
        for library in crt[-1].glob("*.dll"):
            shutil.copy2(library, libraries / library.name)
        (runtime / "run-php.cmd").write_text('@echo off\nsetlocal\nset "PHPRC=%~dp0php.ini"\n'
                                             'if not defined OPENSSL_CONF set "OPENSSL_CONF=%~dp0extras\\ssl\\openssl.cnf"\n'
                                             'if not defined OPENSSL_MODULES set "OPENSSL_MODULES=%~dp0extras\\ssl"\n'
                                             '"%~dp0php.exe" %*\nexit /b %errorlevel%\n')
    else:
        config = runtime / "bin/php-config"
        args += [f"-Dphp-include-dir={run(config, '--include-dir')}"]
        modules = Path(run(config, "--extension-dir"))
        libraries = runtime / "lib"
        name = "bedwire.so"
        for library in (prefix / "lib").glob("*.so*"):
            target = libraries / library.name
            if target.exists() or target.is_symlink():
                target.unlink()
            if library.is_symlink():
                target.symlink_to(os.readlink(library))
            else:
                shutil.copy2(library, target)
                run("patchelf", "--set-rpath", "$ORIGIN", target)
    subprocess.run(args, cwd=extension, check=True)
    modules.mkdir(parents=True, exist_ok=True)
    shutil.copy2(extension / "zig-out/modules" / name, modules / name)
    if not windows:
        for library in libraries.rglob("*.so*"):
            if library.is_file() and not library.is_symlink():
                relative = os.path.relpath(libraries, library.parent)
                run("patchelf", "--set-rpath", f"$ORIGIN/{relative}", library)
        run("patchelf", "--set-rpath", "$ORIGIN/../lib", php.with_name("php.bin") if php.with_name("php.bin").exists() else php)
    ini = runtime / ("php.ini" if windows else "bin/php.ini")
    lines = [line for line in ini.read_text().splitlines() if line not in (f"extension={name}", 'extension_dir="${QUARK_PHP_EXTENSION_DIR}"')]
    ini.write_text("\n".join(lines) + f"\nextension={name}\n")
    manifest = runtime / "native-versions.txt"
    manifest.write_text("\n".join(f"{key}={VERSIONS[key]}" for key in ("EXT_BEDWIRE_COMMIT", "EXT_WEBRTC_COMMIT", "ZIG_VERSION")) + "\n" +
                        "\n".join(f"ZIG_PACKAGE={package.name}" for package in sorted((extension / "zig-pkg").iterdir()) if package.is_dir()) + "\n")
    licenses = runtime / "licenses/bedwire"
    licenses.mkdir(parents=True, exist_ok=True)
    for source in [extension, *sorted((extension / "zig-pkg").iterdir())]:
        for license in [*source.glob("LICENSE*"), *source.glob("COPYING*"), *source.glob("vendor/libdeflate/COPYING")]:
            shutil.copy2(license, licenses / f"{source.name}-{license.name}")
    for source in ((work / "libdatachannel"), (work / "mbedtls"), *sorted((work / "libdatachannel/deps").glob("*")),
                   *sorted((extension / "zig-pkg").glob("nethernet-*/.deps/*")),
                   *sorted((extension / "zig-pkg").glob("nethernet-*/.deps/libdatachannel/deps/*"))):
        if source.is_dir():
            for license in [*source.glob("LICENSE*"), *source.glob("COPYING*")]:
                destination = licenses / f"{source.name}-{license.name}"
                if license.is_dir():
                    shutil.copytree(license, destination, dirs_exist_ok=True)
                else:
                    shutil.copy2(license, destination)
    subprocess.run([str(php), "-c", str(ini), "-d", f"extension_dir={modules}", str(ROOT / "tests/generic/native.php")], check=True, timeout=60)
    if not windows:
        real_php = php.with_name("php.bin")
        if not real_php.exists():
            php.rename(real_php)
        relative_modules = os.path.relpath(modules, php.parent)
        php.write_text('#!/usr/bin/env sh\n'
                       'dir=$(dirname "$(readlink -f "$0")")\n'
                       f'export QUARK_PHP_EXTENSION_DIR="$dir/{relative_modules}"\n'
                       'export OPENSSL_CONF="${OPENSSL_CONF:-$dir/../openssl.cnf}"\n'
                       'export OPENSSL_MODULES="${OPENSSL_MODULES:-$dir/../lib/ossl-modules}"\n'
                       'export PHPRC="$dir/php.ini"\n'
                       'exec "$dir/php.bin" "$@"\n')
        php.chmod(0o755)
        with ini.open("a") as stream:
            stream.write('\nextension_dir="${QUARK_PHP_EXTENSION_DIR}"\n')
        subprocess.run([str(php), str(ROOT / "tests/generic/native.php")], check=True, timeout=60)
        subprocess.run(["python3", str(ROOT / "tests/check-libraries.py"), str(runtime)], check=True, timeout=60)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", choices=("prepare", "install"))
    parser.add_argument("work", type=Path)
    parser.add_argument("--php-source", type=Path)
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--jobs", default="4")
    args = parser.parse_args()
    windows = platform.system() == "Windows"
    if platform.system() not in ("Linux", "Windows") or platform.machine().lower() not in ("x86_64", "amd64"):
        parser.error("Native Quark packages currently require Linux x86_64 or Windows x64 hosts")
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    if args.stage == "prepare":
        prepare(work, windows, args.jobs)
    else:
        if args.php_source is None or args.runtime is None:
            parser.error("install requires --php-source and --runtime")
        install(work, args.php_source.resolve(), args.runtime.resolve(), windows)


if __name__ == "__main__":
    main()
