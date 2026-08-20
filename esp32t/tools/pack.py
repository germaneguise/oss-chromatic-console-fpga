#!/usr/bin/env python3
"""Package a Chromatic FPGA bitstream into the flat 1 MiB flash image with an
on-device provenance blob, plus a release manifest; or verify an image / dump.

Layout of the 1 MiB image (flash 0x000000..0x0FFFFF):

  0x000000  bitstream (uncompressed, size varies slightly build to build)
  ......    0xFF padding
  0x0FF000  metadata sector (4 KiB, erase-aligned)
  ......    0xFF padding
            blob data: ASCII key=value lines, grows downward
  0x0FFFF0  16-byte footer: "CHRM" ver rsvd len[2,LE] crc32[4,LE] pad[4]
  0x100000  end

The blob records the bitstream's exact length and a CRC-32 (IEEE, zlib
polynomial) over exactly those bytes, which the MCU can measure over the
flash bridge (`fpgaflash verify`) and anyone can recompute from a dump. It
lives in the top sector, outside the bitstream, so re-tagging never changes
the recorded CRC. Flashing is always the whole 1 MiB image - that rule is
what keeps the blob and the bitstream in lockstep: a bare bitstream written
by another tool leaves a stale blob behind, which verify then reports as a
mismatch. The `source=` line is a full GitHub commit URL - anyone with a
flash dump can paste their way to the exact source.

  pack.py pack   --bitstream impl/pnr/evt1_x2_v07.bin --out image.flash [--tag <release-tag>]
  pack.py verify --image image.flash

Accepts .fs (ASCII) or .bin (binary) bitstreams; they pack to identical
bytes. Needs only the Python standard library.
"""

import argparse
import binascii
import datetime
import hashlib
import pathlib
import re
import subprocess
import sys

IMAGE_SIZE  = 0x100000
FOOTER_OFS  = IMAGE_SIZE - 16
BLOB_SECTOR = 0x0FF000  # the bitstream must end below this
MAGIC       = b"CHRM"
BLOB_VER    = 1


def read_bitstream(path: pathlib.Path) -> bytes:
    raw = path.read_bytes()
    if not raw.lstrip().startswith(b"//"):
        return raw  # already binary
    bits = []
    for line in raw.decode("ascii", "replace").splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        bits.append(line)
    bitstr = "".join(bits)
    if len(bitstr) % 8 != 0:
        sys.exit(f"error: .fs config bit count {len(bitstr)} is not byte aligned")
    return int(bitstr, 2).to_bytes(len(bitstr) // 8, "big")


def git_field(repo: pathlib.Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def source_url(repo: pathlib.Path, commit: str) -> str:
    """Turn the repo's origin remote into a https commit URL."""
    try:
        remote = git_field(repo, "config", "--get", "remote.origin.url")
    except subprocess.CalledProcessError:
        return ""
    m = re.match(r"(?:git@([^:]+):|https?://([^/]+)/)(.+?)(?:\.git)?/?$", remote)
    if not m:
        return ""
    host = m.group(1) or m.group(2)
    return f"https://{host}/{m.group(3)}/commit/{commit}"


def build_blob(fields: dict) -> bytes:
    data = "".join(f"{k}={v}\n" for k, v in fields.items()).encode("ascii")
    footer = (
        MAGIC
        + bytes([BLOB_VER, 0])
        + len(data).to_bytes(2, "little")
        + binascii.crc32(data).to_bytes(4, "little")
        + b"\xff" * 4
    )
    assert len(footer) == 16
    if len(data) + len(footer) > IMAGE_SIZE - BLOB_SECTOR:
        sys.exit("error: metadata blob does not fit in its sector")
    return data + footer


def cmd_pack(args) -> int:
    bs_path = pathlib.Path(args.bitstream)
    bitstream = read_bitstream(bs_path)
    if len(bitstream) > BLOB_SECTOR:
        sys.exit(f"error: bitstream ({len(bitstream)} bytes) overruns the metadata sector (0x{BLOB_SECTOR:X})")

    image = bytearray(b"\xff" * IMAGE_SIZE)
    image[: len(bitstream)] = bitstream

    repo = pathlib.Path(args.repo) if args.repo else bs_path.resolve().parent
    commit = git_field(repo, "rev-parse", "HEAD")
    dirty = bool(git_field(repo, "status", "--porcelain"))
    if dirty:
        print("WARNING: working tree is dirty; recorded commit does not identify this bitstream exactly", file=sys.stderr)

    fields = {
        "board": "evt1_x2",
        "origin": args.origin,
        "commit": commit + ("-dirty" if dirty else ""),
        "built": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "bitstream_len": len(bitstream),
        "bitstream_crc32": f"0x{binascii.crc32(bitstream):08x}",
        "bitstream_sha256": hashlib.sha256(bitstream).hexdigest(),
    }
    url = args.source_url if args.source_url else source_url(repo, commit)
    if url:
        fields["source"] = url
    if args.tag:
        fields["release"] = args.tag

    blob = build_blob(fields)
    image[IMAGE_SIZE - len(blob):] = blob
    pathlib.Path(args.out).write_bytes(bytes(image))

    fields["image_sha256"] = hashlib.sha256(bytes(image)).hexdigest()
    manifest_path = pathlib.Path(args.manifest) if args.manifest else pathlib.Path(args.out + ".manifest")
    manifest_path.write_text("".join(f"{k}={v}\n" for k, v in fields.items()), encoding="ascii")

    print(f"packed {bs_path.name}: {len(bitstream)} bytes bitstream")
    print(f"  bitstream_crc32 = {fields['bitstream_crc32']} over {len(bitstream)} bytes  (fpgaflash verify measures this on the device)")
    print(f"  source          = {fields.get('source', '(no origin remote)')}")
    print(f"wrote {args.out} ({IMAGE_SIZE} bytes) and {manifest_path}")
    return 0


def cmd_verify(args) -> int:
    image = pathlib.Path(args.image).read_bytes()
    if len(image) < IMAGE_SIZE:
        sys.exit(f"error: image is {len(image)} bytes, need at least {IMAGE_SIZE} - flashing must always cover the full 1 MiB")
    image = image[:IMAGE_SIZE]

    footer = image[FOOTER_OFS:]
    if footer[:4] != MAGIC:
        sys.exit("FAIL: no CHRM footer at 0x0FFFF0")
    ver, data_len = footer[4], int.from_bytes(footer[6:8], "little")
    blob_crc = int.from_bytes(footer[8:12], "little")
    data = image[FOOTER_OFS - data_len:FOOTER_OFS]
    if binascii.crc32(data) != blob_crc:
        sys.exit("FAIL: metadata blob CRC mismatch")

    fields = dict(line.split("=", 1) for line in data.decode("ascii").splitlines() if "=" in line)
    print(f"blob v{ver} OK:")
    for k, v in fields.items():
        print(f"  {k} = {v}")

    ok = True
    bs_len = int(fields.get("bitstream_len", "0"))
    if not 0 < bs_len <= BLOB_SECTOR:
        sys.exit(f"FAIL: blob bitstream_len {bs_len} is not plausible")
    measured = binascii.crc32(image[:bs_len])
    expected = int(fields.get("bitstream_crc32", "0"), 16)
    if measured != expected:
        print(f"FAIL: bitstream CRC32 measured 0x{measured:08x} over {bs_len} bytes, blob says 0x{expected:08x} - "
              f"the blob does not describe this bitstream (stale blob or modified flash)")
        ok = False
    else:
        print(f"bitstream CRC32 0x{measured:08x} over {bs_len} bytes matches (what fpgaflash verify measures on the device)")

    sha = hashlib.sha256(image[:bs_len]).hexdigest()
    if sha != fields.get("bitstream_sha256"):
        print("FAIL: bitstream sha256 mismatch")
        ok = False
    else:
        print("bitstream sha256 matches")

    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    pk = sub.add_parser("pack", help="build the 1 MiB flash image and manifest from a bitstream")
    pk.add_argument("--bitstream", required=True, help=".fs or .bin bitstream")
    pk.add_argument("--out", required=True, help="output image path")
    pk.add_argument("--tag", help="release tag to record")
    pk.add_argument("--source-url", help="override the source commit URL (default: derived from origin remote)")
    pk.add_argument("--origin", default="build",
                    help="how this image came to be: 'build' (packed from a source build of <commit>, the default) "
                         "or e.g. 'official' for a vendor release asset repacked unchanged")
    pk.add_argument("--manifest", help="manifest path (default: <out>.manifest)")
    pk.add_argument("--repo", help="git repo for provenance (default: bitstream's directory)")
    pk.set_defaults(func=cmd_pack)

    vf = sub.add_parser("verify", help="verify a packed image or flash dump")
    vf.add_argument("--image", required=True, help="1 MiB image (or larger flash dump)")
    vf.set_defaults(func=cmd_verify)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
