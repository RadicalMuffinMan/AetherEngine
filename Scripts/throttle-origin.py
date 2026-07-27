#!/usr/bin/env python3
"""Range-preserving throttling proxy: puts a real origin behind a shaped link.

Some reader defects only appear at a MODERATE multiple of media rate. A fast LAN origin
fills the socket buffer, TCP throttles the sender, and client-side backpressure never has
to hold anything, so everything looks correct. #220 lived in that blind spot for weeks: the
same box, file and start position killed at 2.6x media rate and ran clean at 1.0x, and no
amount of repeating the run without shaping the link would have separated them.

This forwards Range requests upstream verbatim and re-serves the body at a fixed rate, so
real content from a real server can be played over a link of a chosen shape without
touching the server. Per-connection byte totals are logged on close, which is the
client-independent ground truth: a healthy reader measures at media rate, and a connection
running above it is reading further ahead than the consumer is draining.

  python3 Scripts/throttle-origin.py <upstream-url> <port> <MB/s>

To pick the rate, take the source's media rate (bit_rate / 8) and multiply. For a 53.5
Mbit/s remux that is 6.7 MB/s, so 17 is roughly 2.5x. Point the player at
http://127.0.0.1:<port>/anything, the path is ignored.
"""
import re
import socket
import sys
import threading
import time
import urllib.request

UPSTREAM = sys.argv[1]
PORT = int(sys.argv[2])
RATE = float(sys.argv[3]) * 1e6

conns = {}
lock = threading.Lock()
t0 = time.time()


def upstream_size():
    req = urllib.request.Request(UPSTREAM, headers={"Range": "bytes=0-1"})
    with urllib.request.urlopen(req, timeout=30) as r:
        cr = r.headers.get("Content-Range", "")
        m = re.search(r"/(\d+)$", cr)
        if m:
            return int(m.group(1))
        raise RuntimeError("upstream did not answer Range with Content-Range: " + cr)


SIZE = upstream_size()


def reporter():
    while True:
        time.sleep(10.0)
        with lock:
            snap = list(conns.items())
        now = time.time()
        for cid, c in snap:
            dur = now - c["start"]
            pos = c["range_start"] + c["sent"]
            print("[proxy t=%5.1fs] conn#%d range=%d+ sent=%.1fMB pos=%.2fGB (%.1f%%) %.2f MB/s"
                  % (now - t0, cid, c["range_start"], c["sent"] / 1e6, pos / 1e9,
                     100.0 * pos / SIZE, (c["sent"] / dur) / 1e6 if dur > 0 else 0.0),
                  flush=True)


def handle(sock, cid):
    sock.settimeout(120)
    f = sock.makefile("rb")
    up = None
    try:
        while True:
            line = f.readline()
            if not line:
                return
            req = line.decode("latin-1").strip()
            headers = {}
            while True:
                h = f.readline()
                if not h or h in (b"\r\n", b"\n"):
                    break
                k, _, v = h.decode("latin-1").partition(":")
                headers[k.strip().lower()] = v.strip()
            if not req.startswith(("GET", "HEAD")):
                sock.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
                return

            rng = headers.get("range", "bytes=0-")
            m = re.match(r"bytes=(\d*)-(\d*)", rng)
            start = int(m.group(1)) if m and m.group(1) else 0
            end = int(m.group(2)) if m and m.group(2) else SIZE - 1
            end = min(end, SIZE - 1)
            length = end - start + 1

            hdr = ["HTTP/1.1 206 Partial Content",
                   "Content-Type: video/x-matroska",
                   "Accept-Ranges: bytes",
                   "Content-Length: %d" % length,
                   "Content-Range: bytes %d-%d/%d" % (start, end, SIZE),
                   "Connection: keep-alive"]
            sock.sendall(("\r\n".join(hdr) + "\r\n\r\n").encode())
            if req.startswith("HEAD"):
                continue

            upreq = urllib.request.Request(
                UPSTREAM, headers={"Range": "bytes=%d-%d" % (start, end)})
            up = urllib.request.urlopen(upreq, timeout=60)

            with lock:
                conns[cid] = {"range_start": start, "sent": 0, "start": time.time()}
            sent = 0
            began = time.time()
            while sent < length:
                chunk = up.read(min(262144, length - sent))
                if not chunk:
                    break
                sock.sendall(chunk)
                sent += len(chunk)
                with lock:
                    if cid in conns:
                        conns[cid]["sent"] = sent
                if RATE > 0:
                    owed = sent / RATE - (time.time() - began)
                    if owed > 0:
                        time.sleep(min(owed, 0.5))
            up.close()
            up = None
    except Exception:
        pass
    finally:
        if up is not None:
            try:
                up.close()
            except Exception:
                pass
        with lock:
            c = conns.pop(cid, None)
        if c and c["sent"] > 0:
            dur = time.time() - c["start"]
            pos = c["range_start"] + c["sent"]
            print("[proxy CLOSE] conn#%d range=bytes=%d- %d bytes / %.2fs = %.2f MB/s "
                  "final pos=%.2fGB (%.1f%%)"
                  % (cid, c["range_start"], c["sent"], dur,
                     (c["sent"] / dur) / 1e6 if dur > 0 else 0.0, pos / 1e9,
                     100.0 * pos / SIZE), flush=True)
        try:
            sock.close()
        except OSError:
            pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(16)
    print("proxying %.2f GB upstream at %.1f MB/s on port %d" % (SIZE / 1e9, RATE / 1e6, PORT),
          flush=True)
    threading.Thread(target=reporter, daemon=True).start()
    cid = 0
    while True:
        sock, _ = srv.accept()
        cid += 1
        threading.Thread(target=handle, args=(sock, cid), daemon=True).start()


main()
