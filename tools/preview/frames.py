# Frame capture for the preview (used by unfold.sh and record.sh).
#   frames.py grab DIR SECONDS   capture the screen through KWin's ScreenShot2 as fast as it renders
#                                (the preview's KWin runs with KWIN_SCREENSHOT_NO_PERMISSION_CHECKS)
#   frames.py track DIR          per frame, KRunner's top edge, the query text's top (relative to the
#                                edge) and the first result lines; prints the changes and a summary.
#                                Expects the light style on a flat wallpaper. With BOTTOMS=1 it also
#                                prints every change of the bottom edge (how the height animates).
#   frames.py record OUT SECONDS AREA [FPS]
#                                capture AREA (JSON with x, y, width, height in logical px, as a KWin
#                                script prints frameGeometry; PAD px are added around it) through
#                                ScreenShot2.CaptureArea at a steady FPS (default 60) into OUT, a
#                                lossless video (ffmpeg)
import asyncio
import glob
import json
import os
import subprocess
import sys
import time


async def grab(outdir, seconds):
    from dbus_fast import Message, MessageType, Variant
    from dbus_fast.aio import MessageBus
    bus = await MessageBus(negotiate_unix_fd=True).connect()
    t0, t0_wall, n = time.monotonic(), time.time(), 0
    while time.monotonic() - t0 < seconds:
        r, w = os.pipe()
        reply = await bus.call(Message(
            destination="org.kde.KWin", path="/org/kde/KWin/ScreenShot2", interface="org.kde.KWin.ScreenShot2",
            member="CaptureActiveScreen", signature="a{sv}h",
            body=[{"native-resolution": Variant("b", True)}, 0], unix_fds=[w]))  # 'h' is an index into unix_fds
        os.close(w)
        if reply.message_type == MessageType.ERROR:
            sys.exit(f"screenshot failed: {reply.error_name} {reply.body}")
        with os.fdopen(r, "rb") as f:
            data = f.read()
        if n == 0:  # raw image: width, height, stride, format 6 (ARGB32 premultiplied, BGRA in memory)
            meta = {k: v.value for k, v in reply.body[0].items()}
            meta["t0_wall"] = t0_wall  # wall clock at 0 ms, to line frames up with WAYLAND_DEBUG logs
            json.dump(meta, open(os.path.join(outdir, "meta.json"), "w"))
        with open(os.path.join(outdir, f"{n:04d}-{int((time.monotonic() - t0) * 1000):05d}.raw"), "wb") as f:
            f.write(data)
        n += 1
    print(f"{n} frames in {seconds} s")


async def record(out, seconds, area, fps):
    from dbus_fast import Message, MessageType, Variant
    from dbus_fast.aio import MessageBus
    bus = await MessageBus(negotiate_unix_fd=True).connect()
    g = json.loads(area[area.index("{"):])
    pad = int(os.environ.get("PAD", "24"))
    x, y, w, h = int(g["x"]) - pad, int(g["y"]) - pad, int(g["width"]) + 2 * pad, int(g["height"]) + 2 * pad

    async def capture():
        r, wfd = os.pipe()
        reply = await bus.call(Message(
            destination="org.kde.KWin", path="/org/kde/KWin/ScreenShot2", interface="org.kde.KWin.ScreenShot2",
            member="CaptureArea", signature="iiuua{sv}h",
            body=[x, y, w, h, {"native-resolution": Variant("b", True)}, 0], unix_fds=[wfd]))
        os.close(wfd)
        if reply.message_type == MessageType.ERROR:
            sys.exit(f"screenshot failed: {reply.error_name} {reply.body}")
        with os.fdopen(r, "rb") as f:
            data = f.read()
        meta = {k: v.value for k, v in reply.body[0].items()}
        width, height, stride = meta["width"], meta["height"], meta["stride"]
        if stride != width * 4:  # rows without their padding
            data = b"".join(data[i * stride:i * stride + width * 4] for i in range(height))
        return width, height, data

    # A steady clock of ticks: each capture is the screen as KWin has it at that tick (KWin renders it at
    # once, with the clients' latest buffers). One that comes in late also stands for the ticks it missed,
    # so the video keeps real time.
    total = round(seconds * fps)
    ffmpeg, n, late, t0 = None, 0, 0, time.monotonic()
    while n < total:
        delay = t0 + n / fps - time.monotonic()
        if delay > 0:
            await asyncio.sleep(delay)
        width, height, data = await capture()
        if ffmpeg is None:  # format 6: ARGB32 premultiplied, BGRA in memory (opaque: it's the screen)
            ffmpeg = subprocess.Popen(
                ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", f"{width}x{height}",
                 "-r", str(fps), "-i", "-", "-c:v", "libx264rgb", "-qp", "0", "-preset", "ultrafast", out],
                stdin=subprocess.PIPE)
        upto = min(total, int((time.monotonic() - t0) * fps) + 1)
        late += max(0, upto - n - 1)
        for _ in range(max(1, upto - n)):
            ffmpeg.stdin.write(data)
        n = max(n + 1, upto)
    ffmpeg.stdin.close()
    ffmpeg.wait()
    print(f"{total} frames at {fps} fps, {w}x{h} logical px at ({x}, {y}); {late} stood in for late captures")


def track(outdir):
    from PIL import Image
    meta = json.load(open(os.path.join(outdir, "meta.json")))
    w, h, stride = meta["width"], meta["height"], meta["stride"]
    frames = sorted(glob.glob(os.path.join(outdir, "*.raw")))
    load = lambda f: Image.frombuffer("RGBA", (w, h), open(f, "rb").read(), "raw", "BGRA", stride, 1).convert("RGB")
    wallpaper = load(frames[0]).getpixel((5, 5))
    rows, prev = [], None
    for f in frames:
        im = load(f)
        gray = im.convert("L")
        diff = Image.merge("RGB", [c.point(lambda v, b=b: 255 if abs(v - b) > 6 else 0) for c, b in zip(im.split(), wallpaper)]).convert("L")
        box = diff.getbbox()
        if not box:
            continue
        left, top, right, bottom = box
        cx = (left + right) // 2
        col = [sum(im.getpixel((cx, y))) for y in range(h)]
        rim = next((y for y in range(top + 1, bottom) if col[y] > 3 * 235 and col[y - 1] < 3 * 225), None)
        # the query text's first dark row, below the top edge (none for the light placeholder)
        query = None
        if rim is not None:
            query = next((y - rim for y in range(rim + 4, min(bottom, rim + 90))
                          if sum(1 for x in range(left + 65, min(right, left + 215)) if gray.getpixel((x, y)) < 110) >= 3), None)
        lines, run = [], False
        for y in range(top + 100, bottom):
            dark = sum(1 for x in range(left + 65, min(right, left + 215)) if gray.getpixel((x, y)) < 110)
            if dark >= 3 and not run:
                lines.append(y)
            run = dark >= 3
        ms = int(os.path.basename(f)[5:10])
        state = (rim, query, tuple(lines[:4]))
        rows.append((ms, bottom, rim, tuple(lines[:4]), query))
        if state != prev or (os.environ.get("BOTTOMS") and bottom != (rows[-2][1] if len(rows) > 1 else None)):
            print(f"{ms:5d} ms  bottom {bottom:4d}  top edge {rim}  query at +{query}  first lines {list(lines[:4])}")
            prev = state
    tops = [r[2] for r in rows if r[2] is not None]
    steady = max(set(tops), key=tops.count) if tops else None
    misplaced = sum(1 for r in rows if r[2] != steady)
    # a new layout = a line both frames show sits elsewhere (more lines appearing as it unfolds is fine)
    layouts, last = 0, None
    for r in rows:
        if r[3] and (last is None or any(a != b for a, b in zip(r[3], last))):
            layouts += 1
        if r[3]:
            last = r[3]
    queries = [r[4] for r in rows if r[4] is not None]
    query_steady = max(set(queries), key=queries.count) if queries else None
    query_moved = sum(1 for q in queries if abs(q - query_steady) > 2)  # the cursor blinking moves it 1 px
    print(f"summary: {len(rows)} frames, top edge misplaced in {misplaced} (offset glitches), "
          f"{layouts} distinct text layouts (1 = no stretch/flicker), query text moved in {query_moved}")


if __name__ == "__main__":
    if sys.argv[1] == "grab":
        asyncio.run(grab(sys.argv[2], float(sys.argv[3])))
    elif sys.argv[1] == "record":
        asyncio.run(record(sys.argv[2], float(sys.argv[3]), sys.argv[4], int(sys.argv[5]) if len(sys.argv) > 5 else 60))
    else:
        track(sys.argv[2])
