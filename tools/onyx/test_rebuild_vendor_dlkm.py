#!/usr/bin/env python3
"""Offline self-check: test_rebuild_vendor_dlkm.py STOCK_IMAGE FILE_CONTEXTS."""
import hashlib
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

builder = Path(__file__).with_name("rebuild_vendor_dlkm.sh")
stock, contexts = map(lambda p: Path(p).resolve(strict=True), sys.argv[1:])
work = Path(tempfile.mkdtemp(prefix="onyx-builder-test-", dir="/var/tmp"))
print(f"Retained test files: {work}", flush=True)
manifest = work / "modules.manifest"
manifest.write_text("")
output = work / "baseline.img"

def build(target=output, ok=True):
    result = subprocess.run([str(builder), str(stock), str(contexts), str(manifest), str(target)],
                            capture_output=True, text=True)
    assert (result.returncode == 0) == ok, result.stdout + result.stderr
    print(result.stdout + result.stderr, end="")

before = hashlib.sha256(stock.read_bytes()).digest()
build()
for name, image in [("stock", stock), ("rebuilt", output)]:
    subprocess.run(["fsck.erofs", f"--extract={work / name}", "--preserve-perms", str(image)], check=True)

# Read labels from image bytes: extracted security xattrs may not persist under WSL.
def metadata(image, path):
    data = image.read_bytes()
    info = subprocess.check_output(["dump.erofs", f"--path={path}", str(image)], text=True)
    nid = int(re.search(r"NID:\s*(\d+)", info)[1])
    size = int(re.search(r"Inode size:\s*(\d+)", info)[1])
    xsize = int(re.search(r"Xattr size:\s*(\d+)", info)[1])
    meta, shared = struct.unpack_from("<II", data, 1024 + 40)
    pos = meta * 4096 + nid * 32 + size
    end = pos + xsize
    attrs = []
    def entry(offset):
        length, index, value_size = struct.unpack_from("<BBH", data, offset)
        start = offset + 4
        attrs.append((index, data[start:start + length], data[start + length:start + length + value_size]))
        return (4 + length + value_size + 3) & ~3
    if xsize:
        count = data[pos + 4]
        for i in range(count):
            ident = struct.unpack_from("<I", data, pos + 12 + i * 4)[0]
            entry(shared * 4096 + ident * 4)
        pos += 12 + count * 4
        while pos < end:
            pos += entry(pos)
    return (re.search(r"Uid:.*", info)[0], re.search(r"Timestamp:.*", info)[0], sorted(attrs))

original = work / "stock"
rebuilt = work / "rebuilt"
paths = [Path("."), *sorted(p.relative_to(original) for p in original.rglob("*"))]
assert set(paths[1:]) == {p.relative_to(rebuilt) for p in rebuilt.rglob("*")}
for path in paths:
    a, b = original / path, rebuilt / path
    assert a.is_dir() == b.is_dir(), path
    if a.is_file():
        assert a.read_bytes() == b.read_bytes(), path
    assert (a.stat().st_mode & 0o7777) == (b.stat().st_mode & 0o7777), path
    image_path = "/" + (str(path) if str(path) != "." else "")
    old, new = metadata(stock, image_path), metadata(output, image_path)
    assert old == new, (path, old, new)
    assert any(index == 6 and key == b"selinux" for index, key, _ in new[2]), path
print(f"PASS: {len(paths)} paths match content, owner, modes, timestamps and raw xattrs")
build(ok=False)  # Existing output must never be overwritten.
module = next((original / "lib/modules").glob("*.ko"))
manifest.write_text(str(module) + "\n")
build(work / "collision.img", ok=False)
assert not (work / "collision.img").exists()
addition = work / "onyx_audit_addition.ko"
shutil.copyfile(module, addition)
manifest.write_text(str(addition) + "\n" + str(addition) + "\n")
build(work / "duplicate.img", ok=False)
assert not (work / "duplicate.img").exists()
manifest.write_text(str(work / "missing.ko") + "\n")
build(work / "missing.img", ok=False)
assert not (work / "missing.img").exists()
assert hashlib.sha256(stock.read_bytes()).digest() == before
print("PASS: existing output, stock-name collision, duplicate addition, missing module rejected; stock unchanged")
