from pathlib import Path
import re
import subprocess
import sys


root = Path(sys.argv[1]).resolve()
system = {"libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1",
          "libstdc++.so.6", "libgcc_s.so.1", "libresolv.so.2", "libutil.so.1", "libcrypt.so.1"}
libraries = [root / "bin/php.bin", *sorted((root / "lib").rglob("*.so*"))]
for library in libraries:
    if library.is_symlink():
        if not library.resolve().is_file() or not library.resolve().is_relative_to(root):
            raise RuntimeError(f"Broken or external runtime symlink: {library}")
        continue
    output = subprocess.check_output(["ldd", str(library)], text=True, stderr=subprocess.STDOUT)
    for name, target in re.findall(r"^\s*(\S+)\s+=>\s+(\S+)", output, re.M):
        if target == "not" or (name not in system and not Path(target).resolve().is_relative_to(root)):
            raise RuntimeError(f"{library} has an unbundled dependency: {name} => {target}")
print(f"{len(libraries)} runtime files checked for missing or external libraries")
