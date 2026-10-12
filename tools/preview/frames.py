# Frame capture for the preview (used by unfold.sh).
#   frames.py grab DIR SECONDS   capture the screen through KWin's ScreenShot2 as fast as it renders
#                                (the preview's KWin runs with KWIN_SCREENSHOT_NO_PERMISSION_CHECKS)
#   frames.py track DIR          per frame, KRunner's top edge and the first result lines; prints the
#                                changes and a summary. Expects the light style on a flat wallpaper.
import asyncio
import glob
import json
import os
import sys
import time


async def grab(outdir, seconds):
    from dbus_fast import Message, MessageType, Variant
    from dbus_fast.aio import MessageBus
    bus = await MessageBus(negotiate_unix_fd=True).connect()
    t0, n = time.monotonic(), 0
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
            json.dump(meta, open(os.path.join(outdir, "meta.json"), "w"))
        with open(os.path.join(outdir, f"{n:04d}-{int((time.monotonic() - t0) * 1000):05d}.raw"), "wb") as f:
            f.write(data)
        n += 1
    print(f"{n} frames in {seconds} s")


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
        lines, run = [], False
        for y in range(top + 100, bottom):
            dark = sum(1 for x in range(left + 65, min(right, left + 215)) if gray.getpixel((x, y)) < 110)
            if dark >= 3 and not run:
                lines.append(y)
            run = dark >= 3
        ms = int(os.path.basename(f)[5:10])
        state = (rim, tuple(lines[:4]))
        rows.append((ms, bottom, rim, tuple(lines[:4])))
        if state != prev:
            print(f"{ms:5d} ms  bottom {bottom:4d}  top edge {rim}  first lines {list(lines[:4])}")
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
    print(f"summary: {len(rows)} frames, top edge misplaced in {misplaced} (offset glitches), "
          f"{layouts} distinct text layouts (1 = no stretch/flicker)")


if __name__ == "__main__":
    if sys.argv[1] == "grab":
        asyncio.run(grab(sys.argv[2], float(sys.argv[3])))
    else:
        track(sys.argv[2])
