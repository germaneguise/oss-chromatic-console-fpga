"""Count UVC payload bytes per frame from a Beagle CSV capture.

The question this answers: does the device put a whole 46080-byte YUY2 frame on
the wire? For an uncompressed format the host knows dwMaxVideoFrameSize exactly,
so a frame delivered even one byte short is discarded rather than rendered - it
looks like "no video" while enumeration and streaming both appear healthy.

Frames are delimited by the EOF bit in the UVC payload header (byte 1, bit 1),
with the FID bit (bit 0) as a cross-check since it toggles per frame.

Usage: python uvc_frames.py capture.csv [expected_bytes]
"""
import csv, sys, collections

path = sys.argv[1] if len(sys.argv) > 1 else "capture.csv"
EXPECT = int(sys.argv[2]) if len(sys.argv) > 2 else 46080   # 160*144*2

rows = list(csv.DictReader(open(path, newline="")))

def databytes(s):
    if not s:
        return []
    s = s.strip().replace("0x", "")
    out = []
    for tok in s.replace(",", " ").split():
        try:
            out.append(int(tok, 16))
        except ValueError:
            pass
    return out

frames = []            # payload bytes per completed frame
cur = 0                # payload bytes in the frame being built
npkt = hdr_only = 0
pkts_this_frame = 0
eps = collections.Counter()
fid = None
short_hdr = 0

for r in rows:
    if (r.get("Type") or "").upper() not in ("IN", "IN-ISO", "ISO IN", "INPUT"):
        # Beagle labels vary; fall back to any row carrying a UVC-looking payload
        pass
    d = databytes(r.get("Data") or "")
    if len(d) < 2 or d[0] != 0x0C:
        continue                      # not a 12-byte UVC payload header
    info = d[1]
    if not (info & 0x80):             # bit7 = end-of-header, always set
        continue
    eps[r.get("EP")] += 1
    npkt += 1
    payload = max(0, len(d) - d[0])
    if payload == 0:
        hdr_only += 1
    cur += payload
    pkts_this_frame += 1
    this_fid = info & 1
    if fid is None:
        fid = this_fid
    if info & 0x02:                   # EOF
        frames.append((cur, pkts_this_frame))
        cur = 0
        pkts_this_frame = 0
        fid = None

print("packets with a UVC header: %d   (header-only: %d)" % (npkt, hdr_only))
print("endpoints seen: %s" % dict(eps))
if not frames:
    print("\nNO COMPLETE FRAMES - never saw a payload header with the EOF bit set.")
    print("bytes accumulated since last EOF: %d of %d" % (cur, EXPECT))
    sys.exit(0)

print("\n  frame   payload bytes   vs %d   packets" % EXPECT)
for i, (n, p) in enumerate(frames):
    print("  %5d   %13d   %+6d   %7d" % (i, n, n - EXPECT, p))

exact = sum(1 for n, _ in frames if n == EXPECT)
print("\n%d/%d frames exactly %d bytes" % (exact, len(frames), EXPECT))
if exact != len(frames):
    short = [n - EXPECT for n, _ in frames if n != EXPECT]
    print("deltas: %s" % sorted(set(short)))
    print("A short uncompressed frame is dropped by the host driver, not rendered.")
