import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import zipfile


spec = importlib.util.spec_from_file_location("validate_package", Path(__file__).with_name("validate-package.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = "bin/php/"
files = {root + name: b"fixture" for name in (
    "php.exe", "php.ini", "php8ts.dll", "datachannel.dll", "vcruntime140.dll",
    "vcruntime140_1.dll", "msvcp140.dll", "ext/php_bedwire.dll",
    "ext/php_opcache.dll", "licenses/bedwire/LICENSE", "extras/ssl/openssl.cnf", "extras/ssl/legacy.dll", "run-php.cmd",
)}
files[root + "native-versions.txt"] = (Path(__file__).resolve().parents[1] / "versions.env").read_bytes()
with tempfile.TemporaryDirectory() as directory:
    for suffix in ("zip", "tar.gz"):
        archive = Path(directory) / f"runtime.{suffix}"
        for missing in (None, "datachannel.dll", "ext/php_bedwire.dll", "vcruntime140.dll", "native-versions.txt", "extras/ssl/openssl.cnf"):
            with zipfile.ZipFile(archive, "w") if suffix == "zip" else tarfile.open(archive, "w:gz") as output:
                for name, data in files.items():
                    if name == root + str(missing):
                        continue
                    if suffix == "zip":
                        output.writestr(name, data)
                    else:
                        member = tarfile.TarInfo(name)
                        member.size = len(data)
                        output.addfile(member, io.BytesIO(data))
            try:
                module.validate(archive)
            except ValueError:
                assert missing is not None
            else:
                assert missing is None, f"Accepted missing {missing}"
print("Incomplete native packages are rejected")
