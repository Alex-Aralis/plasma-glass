#!/usr/bin/env python3
"""Semantic file search with EmbeddingGemma 2 on the Intel GPU (OpenVINO, float16), exposed to KRunner.

    embedsearch index            update the index (only new/changed files are embedded)
    embedsearch search QUERY     print the best matching files
    embedsearch status           show what is indexed
    embedsearch serve            KRunner D-Bus runner + periodic re-indexing (run by systemd)

Settings live in ~/.config/embedsearch/config.toml (created with defaults on first run).
"""

import asyncio
import hashlib
import html
import os
import re
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import tomllib
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SIGNALS = {signal.SIGTERM, signal.SIGINT, signal.SIGHUP}


def take_signals():
    """Exit on SIGTERM/SIGINT/SIGHUP no matter what handlers native code installs. Intel's GPU compiler
    (libigdfcl) installs a crash handler that longjmps into its compiler and leaves it in place, so a
    later `systemctl stop` aborted with a core dump. The signals are blocked in every thread and taken
    by one waiting thread instead, so no handler runs. Threads inherit the mask: call this first."""
    signal.pthread_sigmask(signal.SIG_BLOCK, SIGNALS)

    def wait():
        sig = signal.sigwait(SIGNALS)
        os._exit(0 if sig == signal.SIGTERM else 128 + sig)  # the index commits per batch
    threading.Thread(target=wait, name="signals", daemon=True).start()


if __name__ == "__main__":
    take_signals()  # before numpy, which starts its threads on import

import numpy as np
import openvino as ov
from tokenizers import Tokenizer

APP_DIR = Path(__file__).resolve().parent
MODEL_XML = APP_DIR / "model" / "embeddinggemma2_text.xml"
TOKENIZER_JSON = APP_DIR / "model" / "tokenizer.json"
OV_CACHE = APP_DIR / "ov_cache"
DB_PATH = APP_DIR / "index.sqlite"
CONFIG_PATH = Path.home() / ".config" / "embedsearch" / "config.toml"
BUS_NAME = "local.embedsearch"

QUERY_PROMPT = "task: search result | query: "
DIM = 768
LAST_QUERY = [0.0]  # monotonic time of the latest KRunner query; indexing pauses around it


def wait_while_searching(quiet_seconds=2.0):
    while time.monotonic() - LAST_QUERY[0] < quiet_seconds:
        time.sleep(0.1)

DEFAULT_CONFIG = """\
# Folders to index (searched recursively; hidden folders are always skipped).
folders = ["~/Projects", "~/Documents", "~/Downloads", "~/Desktop"]

# File types to index.
extensions = ["md", "txt", "org", "rst", "tex", "pdf", "docx", "odt", "html", "htm"]

# Folder names to skip anywhere in the tree.
exclude_dirs = ["node_modules", "venv", "__pycache__", "target", "build", "dist", "site-packages"]

# Only the first this-many characters of a file's text are indexed (big books stay manageable).
max_chars_per_file = 2000000

# Chunk size in tokens and the overlap between neighbouring chunks.
chunk_tokens = 384
chunk_overlap = 48

# How often the background service looks for new or changed files.
reindex_minutes = 15

# Results shown in KRunner, and the minimum similarity (0-1) for a result to show at all.
max_results = 5
min_score = 0.45

# "GPU" (the Intel GPU) with "f16" is fastest here; falls back to CPU/f32 if the GPU is unavailable.
# Other vendors' GPUs are skipped; an OpenVINO name like "GPU.1" picks a device explicitly.
device = "GPU"
precision = "f16"
"""


def load_config():
    if not CONFIG_PATH.exists():
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        CONFIG_PATH.write_text(DEFAULT_CONFIG)
    cfg = tomllib.loads(DEFAULT_CONFIG)
    cfg.update(tomllib.loads(CONFIG_PATH.read_text()))
    cfg["folders"] = [Path(f).expanduser() for f in cfg["folders"]]
    cfg["extensions"] = {"." + e.lower().lstrip(".") for e in cfg["extensions"]}
    cfg["exclude_dirs"] = set(cfg["exclude_dirs"])
    return cfg


def log(*args):
    print(time.strftime("%H:%M:%S"), *args, flush=True)


# ---------------------------------------------------------------------------- model


def intel_gpu(core):
    """OpenVINO's name for the Intel GPU ("GPU" or "GPU.N"), or None. OpenVINO also lists other
    vendors' OpenCL GPUs (an NVIDIA card through its ICD), which can't run this model in f16."""
    for d in core.available_devices:
        try:
            if d.startswith("GPU") and "vendor=0x8086" in str(core.get_property(d, "DEVICE_ARCHITECTURE")):
                return d
        except RuntimeError:
            pass
    return None


class Embedder:
    """EmbeddingGemma 2 text encoder: tokenize, run the OpenVINO model, return unit vectors."""

    def __init__(self, cfg):
        core = ov.Core()
        device, precision = cfg["device"], cfg["precision"]
        if device == "GPU":
            device = intel_gpu(core)
        if device not in core.available_devices:
            log(f"{cfg['device']} not available, using CPU/f32")
            device, precision = "CPU", "f32"
        t = time.perf_counter()
        try:
            self.compiled = self._compile(core, device, precision)
        except RuntimeError as e:
            if device == "CPU":
                raise
            log(f"{device} can't run the model, using CPU/f32: {str(e).strip().splitlines()[-1]}")
            device, precision = "CPU", "f32"
            self.compiled = self._compile(core, device, precision)
        self.device = f"{device}/{precision}"
        log(f"model ready on {self.device} ({core.get_property(device, 'FULL_DEVICE_NAME')})"
            f" in {time.perf_counter() - t:.1f} s")
        self.output = self.compiled.output(0)
        self.tok = Tokenizer.from_file(str(TOKENIZER_JSON))
        self.pad_id = self.tok.token_to_id("<pad>")
        self._local = threading.local()  # one infer request per thread

    @staticmethod
    def _compile(core, device, precision):
        return core.compile_model(str(MODEL_XML), device, {
            "INFERENCE_PRECISION_HINT": precision,
            "PERFORMANCE_HINT": "LATENCY",
            "CACHE_DIR": str(OV_CACHE),
        })

    def _request(self):
        if not hasattr(self._local, "req"):
            self._local.req = self.compiled.create_infer_request()
        return self._local.req

    def embed(self, texts, batch_size=16, max_tokens=1024, pause=None):
        """Embed texts (prompts already applied). Returns float32 array (n, 768), unit length.

        pause, if given, is called before each batch (used to let interactive queries go first).
        """
        encs = self.tok.encode_batch(texts)
        ids = [e.ids[:max_tokens] for e in encs]
        order = sorted(range(len(ids)), key=lambda i: len(ids[i]))  # similar lengths share a batch
        out = np.zeros((len(ids), DIM), dtype=np.float32)
        req = self._request()
        for b in range(0, len(order), batch_size):
            if pause:
                pause()
            idx = order[b : b + batch_size]
            width = max(len(ids[i]) for i in idx)
            input_ids = np.full((len(idx), width), self.pad_id, dtype=np.int64)
            mask = np.zeros((len(idx), width), dtype=np.int64)
            for row, i in enumerate(idx):
                input_ids[row, : len(ids[i])] = ids[i]
                mask[row, : len(ids[i])] = 1
            out[idx] = req.infer({"input_ids": input_ids, "attention_mask": mask})[self.output]
        out /= np.linalg.norm(out, axis=1, keepdims=True).clip(min=1e-9)  # f16 leaves it slightly off 1
        return out

    def embed_query(self, query):
        return self.embed([QUERY_PROMPT + query], max_tokens=256)[0]


# ---------------------------------------------------------------------------- text extraction


def _xml_text(xml, para_tags):
    for tag in para_tags:
        xml = xml.replace(f"</{tag}>", "\n")
    return html.unescape(re.sub(r"<[^>]+>", "", xml))


def extract_text(path):
    ext = path.suffix.lower()
    if ext == ".pdf":
        r = subprocess.run(["pdftotext", "-q", "-enc", "UTF-8", str(path), "-"],
                           capture_output=True, timeout=300)
        return r.stdout.decode("utf-8", errors="replace")
    if ext == ".docx":
        with zipfile.ZipFile(path) as z:
            return _xml_text(z.read("word/document.xml").decode("utf-8", errors="replace"), ["w:p"])
    if ext == ".odt":
        with zipfile.ZipFile(path) as z:
            return _xml_text(z.read("content.xml").decode("utf-8", errors="replace"), ["text:p", "text:h"])
    text = path.read_text(encoding="utf-8", errors="replace")
    if ext in (".html", ".htm"):
        text = re.sub(r"(?is)<(script|style)\b.*?</\1>", " ", text)
        text = _xml_text(text, ["p", "div", "li", "h1", "h2", "h3", "h4", "tr"])
    return text


def chunk_text(tok, text, size, overlap):
    """Split text into windows of `size` tokens, returned as (start_char, end_char, text)."""
    offsets = tok.encode(text, add_special_tokens=False).offsets
    chunks, step = [], max(1, size - overlap)
    for i in range(0, len(offsets), step):
        j = min(i + size, len(offsets))
        start, end = offsets[i][0], offsets[j - 1][1]
        chunk = text[start:end].strip()
        if len(chunk) >= 20:
            chunks.append((start, end, chunk))
        if j == len(offsets):
            break
    return chunks


def iter_files(cfg):
    for root in cfg["folders"]:
        if not root.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if not d.startswith(".") and d not in cfg["exclude_dirs"]]
            for name in filenames:
                p = Path(dirpath, name)
                if p.suffix.lower() in cfg["extensions"] and not name.startswith("."):
                    yield p


# ---------------------------------------------------------------------------- index storage


def launch(args, env=None):
    """Start a program in its own session, with the signal mask and dispositions it would normally get."""
    pid = os.posix_spawnp(args[0], args, os.environ if env is None else env, setsid=True,
                          setsigmask=(), setsigdef=(signal.SIGPIPE, signal.SIGXFSZ))
    threading.Thread(target=os.waitpid, args=(pid, 0), daemon=True).start()


def connect():
    db = sqlite3.connect(DB_PATH, timeout=30, check_same_thread=False)
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript("""
        CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, mtime REAL, size INTEGER, chunks INTEGER);
        CREATE TABLE IF NOT EXISTS chunks(id INTEGER PRIMARY KEY, path TEXT, start INTEGER, "end" INTEGER,
                                          text TEXT, hash TEXT, vec BLOB);
        CREATE INDEX IF NOT EXISTS chunks_path ON chunks(path);
        CREATE INDEX IF NOT EXISTS chunks_hash ON chunks(hash);
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
    """)
    return db


def index_version(db):
    row = db.execute("SELECT value FROM meta WHERE key='version'").fetchone()
    return int(row[0]) if row else 0


def bump_version(db):
    db.execute("INSERT INTO meta VALUES('version', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
               (str(index_version(db) + 1),))


def update_index(emb, cfg, flush_chunks=64):
    """Embed new/changed files, drop deleted ones. Safe to interrupt: progress is committed per batch."""
    db = connect()
    known = {p: (m, s) for p, m, s in db.execute("SELECT path, mtime, size FROM files")}
    todo, seen = [], set()
    for p in iter_files(cfg):
        try:
            st = p.stat()
        except OSError:
            continue
        seen.add(str(p))
        if known.get(str(p)) != (st.st_mtime, st.st_size):
            todo.append((p, st))
    removed = set(known) - seen
    if removed:
        db.executemany("DELETE FROM chunks WHERE path=?", [(p,) for p in removed])
        db.executemany("DELETE FROM files WHERE path=?", [(p,) for p in removed])
        bump_version(db)
        db.commit()
    if not todo:
        if removed:
            log(f"removed {len(removed)} deleted files")
        return
    total_chars = 0
    log(f"indexing {len(todo)} new/changed files ({len(removed)} removed) on {emb.device}")

    pending, n_pending, done, t0, n_embedded = [], 0, 0, time.perf_counter(), 0

    def flush():
        nonlocal pending, n_pending, done, n_embedded
        if not pending:
            return
        need =[(f, k) for f, item in enumerate(pending) for k, h in enumerate(item["hashes"])
                if item["vecs"][k] is None]
        if need:
            vecs = emb.embed([pending[f]["prompts"][k] for f, k in need], batch_size=4, pause=wait_while_searching)
            for (f, k), v in zip(need, vecs):
                pending[f]["vecs"][k] = v.astype(np.float16).tobytes()
            n_embedded += len(need)
        for item in pending:
            path = str(item["path"])
            db.execute("DELETE FROM chunks WHERE path=?", (path,))
            db.executemany(
                'INSERT INTO chunks(path, start, "end", text, hash, vec) VALUES(?,?,?,?,?,?)',
                [(path, s, e, t, h, v) for (s, e, t), h, v in zip(item["chunks"], item["hashes"], item["vecs"])])
            db.execute("INSERT OR REPLACE INTO files VALUES(?,?,?,?)",
                       (path, item["st"].st_mtime, item["st"].st_size, len(item["chunks"])))
        bump_version(db)
        db.commit()
        done += len(pending)
        rate = n_embedded / (time.perf_counter() - t0)
        log(f"  {done}/{len(todo)} files, {n_embedded} chunks embedded ({rate:.1f} chunks/s)")
        pending, n_pending = [], 0

    for p, st in todo:
        try:
            text = extract_text(p)[: cfg["max_chars_per_file"]]
        except Exception as e:  # unreadable/corrupt file: record it so it isn't retried every run
            log(f"  skip {p}: {e}")
            text = ""
        total_chars += len(text)
        chunks = chunk_text(emb.tok, text, cfg["chunk_tokens"], cfg["chunk_overlap"]) if text.strip() else []
        title = p.stem.replace("_", " ")
        prompts = [f"title: {title} | text: {c[2]}" for c in chunks]
        hashes = [hashlib.sha1(pr.encode()).hexdigest() for pr in prompts]
        vecs = []
        for h in hashes:  # identical chunk already embedded (copies, re-saves): reuse its vector
            row = db.execute("SELECT vec FROM chunks WHERE hash=? LIMIT 1", (h,)).fetchone()
            vecs.append(row[0] if row else None)
        pending.append({"path": p, "st": st, "chunks": chunks, "prompts": prompts, "hashes": hashes, "vecs": vecs})
        n_pending += sum(v is None for v in vecs)
        if n_pending >= flush_chunks or len(pending) >= 200:
            flush()
    flush()
    log(f"index up to date: {len(todo)} files, {total_chars / 1e6:.1f} MB text, "
        f"{n_embedded} chunks embedded in {time.perf_counter() - t0:.0f} s")


class Index:
    """All chunk vectors in memory for brute-force cosine search; reloads when the DB changes."""

    def __init__(self):
        self.version = -1
        self.data = None
        self.last_check = 0.0
        self.lock = threading.Lock()

    def refresh(self, force=False):
        if not force and time.monotonic() - self.last_check < 30:
            return
        with self.lock:
            self.last_check = time.monotonic()
            db = connect()
            v = index_version(db)
            if v == self.version:
                return
            rows = db.execute("SELECT id, path, text, hash, vec FROM chunks ORDER BY id").fetchall()
            db.close()
            # Fingerprint each file by all of its chunk texts, so renamed copies ("x(1).docx") show once.
            digests = {}
            for r in rows:
                digests.setdefault(r[1], hashlib.sha1()).update(r[2].encode())
            fingerprints = {path: d.hexdigest() for path, d in digests.items()}
            vecs = (np.frombuffer(b"".join(r[4] for r in rows), dtype=np.float16).reshape(-1, DIM).astype(np.float32)
                    if rows else np.zeros((0, DIM), np.float32))
            self.data = ([r[0] for r in rows], [r[1] for r in rows], [r[2] for r in rows], [r[3] for r in rows], vecs,
                         fingerprints)
            self.version = v

    def search(self, qvec, max_results=5, min_score=0.0):
        """Best chunk per file, files ranked by that chunk's similarity. Copies of the same text show once."""
        ids, paths, texts, hashes, vecs, fingerprints = self.data
        if not ids:
            return []
        scores = vecs @ qvec
        top = np.argsort(-scores)[: max(50, max_results * 20)]
        results, seen = [], set()
        for i in top:
            if scores[i] < min_score:
                break
            fp = fingerprints[paths[i]]
            if fp in seen or hashes[i] in seen:
                continue
            seen.update((fp, hashes[i]))
            results.append({"id": ids[i], "path": paths[i], "text": texts[i], "score": float(scores[i])})
            if len(results) == max_results:
                break
        return results


def snippet(text, n=140):
    s = " ".join(text.split())
    return s if len(s) <= n else s[: n - 1].rsplit(" ", 1)[0] + "…"


def pretty(path):
    home = str(Path.home())
    return "~" + path[len(home):] if path.startswith(home) else path


# ---------------------------------------------------------------------------- KRunner D-Bus runner

ICONS = {".pdf": "application-pdf", ".md": "text-markdown", ".docx": "x-office-document",
         ".odt": "x-office-document", ".html": "text-html", ".htm": "text-html", ".tex": "text-x-tex"}


def serve():
    from dbus_fast import Variant
    from dbus_fast.aio import MessageBus
    from dbus_fast.service import ServiceInterface, method

    cfg = load_config()
    emb = Embedder(cfg)
    index = Index()
    index.refresh(force=True)
    log(f"loaded {len(index.data[0])} chunks")
    query_pool = ThreadPoolExecutor(max_workers=1)

    class Runner(ServiceInterface):
        def __init__(self):
            super().__init__("org.kde.krunner1")
            self.seq = 0
            self.matches = {}  # match id -> path, for Run
            self.token = ""

        @method()
        def Config(self) -> "a{sv}":
            return {"MinLetterCount": Variant("i", 4)}

        @method()
        def Actions(self) -> "a(sss)":
            return [["folder", "Open containing folder", "document-open-folder"],
                    ["copy", "Copy path", "edit-copy"]]

        @method()
        def Teardown(self):
            self.matches.clear()

        @method()
        def SetActivationToken(self, token: "s"):
            self.token = token

        @method()
        async def Match(self, query: "s") -> "a(sssida{sv})":
            self.seq += 1
            mine = self.seq
            LAST_QUERY[0] = time.monotonic()
            await asyncio.sleep(0.15)  # wait for typing to pause; newer queries supersede this one
            if mine != self.seq or len(query.strip()) < 4:
                return []
            loop = asyncio.get_running_loop()

            def work():
                index.refresh()
                return index.search(emb.embed_query(query), cfg["max_results"], cfg["min_score"])

            results = await loop.run_in_executor(query_pool, work)
            LAST_QUERY[0] = time.monotonic()
            if mine != self.seq:
                return []
            out = []
            for r in results:
                mid = str(r["id"])
                self.matches[mid] = r["path"]
                p = Path(r["path"])
                # 70 = KRunner "High" category relevance, the same as browser history; within a tie,
                # KRunner orders by the relevance value, where our similarity (~0.6-0.8) usually wins.
                out.append([mid, p.name, ICONS.get(p.suffix.lower(), "text-plain"), 70, r["score"], {
                    "subtext": Variant("s", f"{snippet(r['text'])}  —  {pretty(str(p.parent))}"),
                    "urls": Variant("as", [p.as_uri()]),
                    "category": Variant("s", "Semantic Search"),
                }])
            return out

        @method()
        def Run(self, match_id: "s", action_id: "s"):
            path = self.matches.get(match_id)
            if not path:
                return
            env = dict(os.environ, XDG_ACTIVATION_TOKEN=self.token) if self.token else None
            if action_id == "folder":
                launch(["dolphin", "--select", path], env)
            elif action_id == "copy":
                launch(["qdbus6", "org.kde.klipper", "/klipper", "setClipboardContents", path])
            else:
                launch(["xdg-open", path], env)
            self.token = ""

    def reindex_loop():
        reindex_emb = emb  # same compiled model; each thread gets its own infer request
        while True:
            try:
                update_index(reindex_emb, load_config())
            except Exception as e:
                log(f"indexing failed: {e!r}")
            time.sleep(cfg["reindex_minutes"] * 60)

    async def main():
        bus = await MessageBus().connect()
        bus.export("/runner", Runner())
        await bus.request_name(BUS_NAME)
        log(f"KRunner runner on D-Bus as {BUS_NAME}")
        # set by tools/preview so a second instance never races the real service on the index
        if not os.environ.get("EMBEDSEARCH_NO_REINDEX"):
            threading.Thread(target=reindex_loop, daemon=True).start()
        await bus.wait_for_disconnect()

    asyncio.run(main())


# ---------------------------------------------------------------------------- CLI


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    if cmd == "serve":
        serve()
    elif cmd == "index":
        cfg = load_config()
        update_index(Embedder(cfg), cfg)
    elif cmd == "search" and len(sys.argv) > 2:
        cfg = load_config()
        emb = Embedder(cfg)
        index = Index()
        index.refresh(force=True)
        q = " ".join(sys.argv[2:])
        t = time.perf_counter()
        results = index.search(emb.embed_query(q), max_results=10)
        log(f"{len(index.data[0])} chunks searched in {(time.perf_counter() - t) * 1000:.0f} ms")
        for r in results:
            print(f"{r['score']:.3f}  {pretty(r['path'])}\n       {snippet(r['text'], 160)}")
    elif cmd == "status":
        db = connect()
        files, chunks = db.execute("SELECT COUNT(*), COALESCE(SUM(chunks), 0) FROM files").fetchone()
        empty = db.execute("SELECT COUNT(*) FROM files WHERE chunks=0").fetchone()[0]
        print(f"{files} files indexed ({empty} with no extractable text), {chunks} chunks")
        print(f"index: {DB_PATH} ({DB_PATH.stat().st_size / 1e6:.0f} MB)" if DB_PATH.exists() else "no index yet")
        print(f"config: {CONFIG_PATH}")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
