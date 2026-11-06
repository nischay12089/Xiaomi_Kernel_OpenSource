#!/usr/bin/env python3
"""Rebuild an onyx vendor_boot v4 image with one module removed from the first-stage modules.load.

Usage: vb_drop_module.py IN.img OUT.img MODULE.ko
       vb_drop_module.py IN.img OUT.img --replace lib/modules/NAME.ko NEWFILE
Edits only lib/modules/modules.load (or the one replaced file) inside the (single) LZ4-legacy
vendor ramdisk, byte-for-byte
in place in the newc cpio, so every other entry keeps its exact uid/gid/mode/mtime. Header,
DTB, ramdisk table, bootconfig and the AVB footer/vbmeta are carried over; both ramdisk size
fields are set to the new stream length (the stock table entry under-reports it).
"""
import struct, subprocess, sys

PAGE = 4096
al = lambda x: (x + PAGE - 1) // PAGE * PAGE


def parse(img):
    assert img[:8] == b"VNDRBOOT", "not a vendor_boot"
    ver, page, _, _, vrsz = struct.unpack_from("<5I", img, 8)
    assert ver == 4 and page == PAGE, (ver, page)
    o = 8 + 20 + 2048
    hsz, dtbsz = struct.unpack_from("<2I", img, o + 20)
    tsz, tnum, tesz, bcsz = struct.unpack_from("<4I", img, o + 36)
    assert tnum == 1, "only single-fragment vendor_boot supported"
    rd = al(hsz); dt = rd + al(vrsz); tb = dt + al(dtbsz); bc = tb + al(tsz)
    return dict(o=o, hsz=hsz, vrsz=vrsz, dtbsz=dtbsz, tsz=tsz, tesz=tesz, bcsz=bcsz,
                rd=rd, dt=dt, tb=tb, bc=bc, end=bc + al(bcsz))


def cpio_edit(data, path, fn):
    """Apply fn(old_bytes)->new_bytes to one newc entry; return (new_cpio, old, new)."""
    out, i, hit = bytearray(), 0, None
    while True:
        assert data[i:i + 6] == b"070701", f"bad cpio magic at {i}"
        hdr = data[i:i + 110]
        namesz = int(hdr[94:102], 16); filesz = int(hdr[54:62], 16)
        nstart = i + 110; nend = nstart + namesz
        dstart = (nend + 3) & ~3; dend = dstart + filesz
        name = data[nstart:nend - 1].decode()
        body = data[dstart:dend]
        if name == path:
            new = fn(body); hit = (body, new)
            hdr = hdr[:54] + b"%08X" % len(new) + hdr[62:]
            body = new
        out += hdr + data[nstart:nend]
        out += b"\0" * (((len(out) + 3) & ~3) - len(out))
        out += body
        out += b"\0" * (((len(out) + 3) & ~3) - len(out))
        i = (dend + 3) & ~3
        if name == "TRAILER!!!":
            out += data[i:]  # keep any trailing padding as-is
            break
    assert hit, f"{path} not found"
    return bytes(out), hit[0], hit[1]


def main(src, dst, path, fn):
    img = open(src, "rb").read()
    p = parse(img)
    lz = img[p["rd"]:p["rd"] + p["vrsz"]]
    cpio = subprocess.run(["lz4", "-dc"], input=lz, capture_output=True, check=True).stdout

    new_cpio, old, new = cpio_edit(cpio, path, fn)
    new_lz = subprocess.run(["lz4", "-l", "-12", "-c"], input=new_cpio, capture_output=True,
                            check=True).stdout
    # self-check: the new stream decompresses back to exactly the edited cpio
    assert subprocess.run(["lz4", "-dc"], input=new_lz, capture_output=True,
                          check=True).stdout == new_cpio

    hdr = bytearray(img[:p["hsz"]])
    struct.pack_into("<I", hdr, 8 + 16, len(new_lz))           # vendor_ramdisk_size
    table = bytearray(img[p["tb"]:p["tb"] + p["tsz"]])
    struct.pack_into("<I", table, 0, len(new_lz))              # entry0 ramdisk_size
    pad = lambda b: bytes(b) + b"\0" * (al(len(b)) - len(b))
    body = (pad(hdr) + pad(new_lz) + pad(img[p["dt"]:p["dt"] + p["dtbsz"]]) + pad(table)
            + pad(img[p["bc"]:p["bc"] + p["bcsz"]]))

    out = bytearray(len(img))
    foot = img[-64:]
    if foot[:4] == b"AVBf":
        orig_sz, vb_off, vb_sz = struct.unpack_from(">QQQ", foot, 12)
        # vbmeta blob goes right after the (page-aligned) image data, as avbtool lays it out
        new_off = max(vb_off, len(body))
        assert new_off + vb_sz <= len(img) - 64, "no room for the vbmeta blob"
        out[new_off:new_off + vb_sz] = img[vb_off:vb_off + vb_sz]
        foot = bytearray(foot); struct.pack_into(">QQ", foot, 12, len(body), new_off)
        out[-64:] = foot
    out[:len(body)] = body
    open(dst, "wb").write(out)
    print(f"{path} {len(old)} -> {len(new)} bytes; ramdisk {p['vrsz']} -> {len(new_lz)}; "
          f"image data {p['end']} -> {len(body)}")


def drop_line(module):
    def fn(b):
        lines = b.decode().splitlines(keepends=True)
        kept = [l for l in lines if l.strip() != module]
        assert len(kept) == len(lines) - 1, f"{module} must appear exactly once"
        return "".join(kept).encode()
    return fn


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 3:
        main(a[0], a[1], "lib/modules/modules.load", drop_line(a[2]))
    elif len(a) == 5 and a[2] == "--replace":
        new = open(a[4], "rb").read()
        main(a[0], a[1], a[3], lambda old: new)
    else:
        sys.exit(__doc__)
