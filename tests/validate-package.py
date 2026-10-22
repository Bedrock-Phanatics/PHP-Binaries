import argparse
from pathlib import Path, PurePosixPath
import tarfile
import zipfile


def validate(path):
    is_zip = path.suffix == ".zip"
    with zipfile.ZipFile(path) if is_zip else tarfile.open(path) as archive:
        entries = archive.namelist() if is_zip else archive.getnames()
        members = {name.removeprefix("./").replace("\\", "/"): name for name in entries}
        names = set(members)
        windows = "bin/php/php.exe" in names
        root = "bin/php" if windows else "bin/php7"
        required = {f"{root}/php.exe" if windows else f"{root}/bin/php",
                    f"{root}/php.ini" if windows else f"{root}/bin/php.ini",
                    f"{root}/native-versions.txt"}
        if windows:
            required.update(f"{root}/{name}" for name in ("php8ts.dll", "datachannel.dll", "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll"))
            required.update(f"{root}/ext/php_{name}.dll" for name in ("bedwire", "webrtc", "opcache"))
        else:
            required.add(f"{root}/bin/php.bin")
            for module in ("bedwire.so", "webrtc.so", "opcache.so"):
                if not any(name.startswith(f"{root}/lib/php/extensions/") and name.endswith(f"/{module}") for name in names):
                    raise ValueError(f"{path}: missing {module}")
            if not any(name.startswith(f"{root}/lib/libdatachannel.so.") for name in names):
                raise ValueError(f"{path}: missing libdatachannel runtime")
            for member in archive.getmembers():
                if member.issym() and (PurePosixPath(member.linkname).is_absolute() or ".." in PurePosixPath(member.linkname).parts):
                    raise ValueError(f"{path}: non-local library symlink {member.name}")
        missing = required - names
        if missing:
            raise ValueError(f"{path}: missing {sorted(missing)}")
        manifest_name = members[f"{root}/native-versions.txt"]
        manifest = archive.read(manifest_name) if is_zip else archive.extractfile(manifest_name).read()
        versions = dict(line.split("=", 1) for line in (Path(__file__).resolve().parents[1] / "versions.env").read_text().splitlines())
        for key in ("EXT_BEDWIRE_COMMIT", "EXT_WEBRTC_COMMIT", "ZIG_VERSION"):
            if f"{key}={versions[key]}" not in manifest.decode().splitlines():
                raise ValueError(f"{path}: mismatched {key}")
        if not any(name.startswith(f"{root}/licenses/bedwire/") for name in names):
            raise ValueError(f"{path}: native licenses are missing")
    print(f"{path}: native runtime files present")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("archives", nargs="+", type=Path)
    for archive in parser.parse_args().archives:
        validate(archive)
