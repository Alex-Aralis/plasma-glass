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
import mimetypes
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

# File types whose text is indexed.
extensions = ["md", "txt", "org", "rst", "tex", "pdf", "docx", "odt", "html", "htm"]

# Find every file in the folders by its name and path, not just the types above: "glass agents"
# finds plasma-glass/AGENTS.md, "pragconv" pragmatic-convalescence.md. false: only those types.
all_file_names = true

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

    def embed(self, texts, batch_size=16, max_tokens=1024, pause=None, progress=None):
        """Embed texts (prompts already applied). Returns float32 array (n, 768), unit length.

        pause, if given, is called before each batch (used to let interactive queries go first);
        progress, after each one, with the number of texts embedded so far.
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
            if progress:
                progress(b + len(idx))
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
    """(path, whether its text is indexed) for each file that can be found, by its text or its name."""
    for root in cfg["folders"]:
        if not root.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if not d.startswith(".") and d not in cfg["exclude_dirs"]]
            for name in filenames:
                p = Path(dirpath, name)
                text = p.suffix.lower() in cfg["extensions"]
                if (text or cfg["all_file_names"]) and not name.startswith("."):
                    yield p, text


def name_prompt(path):
    """What a file's name and path are embedded as, so a query can find it by meaning too."""
    return f"title: {Path(path).name} | text: {pretty(path).removeprefix('~/')}"


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
        CREATE TABLE IF NOT EXISTS names(path TEXT PRIMARY KEY, vec BLOB);
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
    """)
    return db


def index_version(db):
    row = db.execute("SELECT value FROM meta WHERE key='version'").fetchone()
    return int(row[0]) if row else 0


def bump_version(db):
    db.execute("INSERT INTO meta VALUES('version', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
               (str(index_version(db) + 1),))


def update_index(emb, cfg, flush_chunks=64, progress=None):
    """Embed new/changed files, drop deleted ones. Safe to interrupt: progress is committed per batch.

    progress, if given, is called with the share of the files done (0-1) while there are any to index,
    then with None. Returns the numbers of files indexed (by text or name) and removed.
    """
    try:
        return _update_index(emb, cfg, flush_chunks, progress or (lambda share: None))
    finally:
        if progress:
            progress(None)


def _update_index(emb, cfg, flush_chunks, progress):
    db = connect()
    known = {p: (m, s) for p, m, s in db.execute("SELECT path, mtime, size FROM files")}
    known_names = {p for p, in db.execute("SELECT path FROM names")}
    todo, seen, names = [], set(), set()
    for p, text in iter_files(cfg):
        names.add(str(p))
        if not text:
            continue
        try:
            st = p.stat()
        except OSError:
            continue
        seen.add(str(p))
        if known.get(str(p)) != (st.st_mtime, st.st_size):
            todo.append((p, st))
    removed, new_names, gone_names = set(known) - seen, sorted(names - known_names), known_names - names
    if removed or gone_names:
        db.executemany("DELETE FROM chunks WHERE path=?", [(p,) for p in removed])
        db.executemany("DELETE FROM files WHERE path=?", [(p,) for p in removed])
        db.executemany("DELETE FROM names WHERE path=?", [(p,) for p in gone_names])
        bump_version(db)
        db.commit()
    indexed, removed_count = len({str(p) for p, _ in todo} | set(new_names)), len(removed | gone_names)
    if new_names:  # a short prompt each, so even the first run's thousands take seconds
        log(f"indexing the names of {len(new_names)} new files")
        if not todo:
            progress(0.0)
        for b in range(0, len(new_names), 256):
            batch = new_names[b : b + 256]
            vecs = emb.embed([name_prompt(n) for n in batch], batch_size=16, max_tokens=128, pause=wait_while_searching)
            db.executemany("INSERT OR REPLACE INTO names VALUES(?,?)",
                           [(n, v.astype(np.float16).tobytes()) for n, v in zip(batch, vecs)])
            bump_version(db)
            db.commit()
            if not todo:
                progress((b + len(batch)) / len(new_names))
    if not todo:
        if new_names or removed_count:
            log(f"index up to date: {len(new_names)} names indexed, {removed_count} deleted files removed")
        return indexed, removed_count
    total_chars = 0
    log(f"indexing {len(todo)} new/changed files ({len(removed)} removed) on {emb.device}")
    progress(0.0)

    pending, n_pending, done, t0, n_embedded = [], 0, 0, time.perf_counter(), 0

    def flush():
        nonlocal pending, n_pending, done, n_embedded
        if not pending:
            return
        need =[(f, k) for f, item in enumerate(pending) for k, h in enumerate(item["hashes"])
                if item["vecs"][k] is None]
        if need:
            vecs = emb.embed([pending[f]["prompts"][k] for f, k in need], batch_size=4, pause=wait_while_searching,
                             progress=lambda n: progress((done + len(pending) * n / len(need)) / len(todo)))
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
        progress(done / len(todo))
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
    return indexed, removed_count


SEPARATORS = set("/-_. ")


def word_start(s, i):
    """Whether a word starts at s[i]: after a separator, or where lower case turns upper or letters digits."""
    if i == 0:
        return True
    a, b = s[i - 1], s[i]
    return a in SEPARATORS or (a.islower() and b.isupper()) or (a.isalnum() and b.isalnum() and a.isalpha() != b.isalpha())


def match_word(word, s, low, name_start):
    """How well word (lower case) shows in s (low is s lowered), 0-1, and whether that's in the file's name:
    whole at a word's start 1, inside a word 0.8, or its letters in order from a word's start, fzf-like (0.7
    when each starts a word or follows the one before, and none if under 3 in 4 do; "lore" isn't in
    "vaelor-estate"). In the folders it counts 0.85 of that."""
    best, in_name, i = 0.0, False, low.find(word)
    while i >= 0:
        q = (1.0 if word_start(s, i) else 0.8) * (1.0 if i >= name_start else 0.85)
        if q > best:
            best, in_name = q, i >= name_start
        i = low.find(word, i + 1)
    if best or len(word) < 3:
        return best, in_name
    k = -1  # the earliest place the letters end in order, then the latest they start before it (fzf's v1)
    for c in word:
        k = low.find(c, k + 1)
        if k < 0:
            return 0.0, False
    pos = []
    for c in reversed(word):
        k = low.rfind(c, 0, k + 1)
        pos.append(k)
        k -= 1
    pos.reverse()
    if not word_start(s, pos[0]):
        return 0.0, False
    good = sum(i == 0 or pos[i] == pos[i - 1] + 1 or word_start(s, pos[i]) for i in range(len(pos))) / len(pos)
    if good < 0.75:
        return 0.0, False
    return 0.7 * good * (1.0 if pos[0] >= name_start else 0.85), pos[0] >= name_start


def match_path(word, s, low):
    """How well a word with slashes ("02/020/030") follows the path's folders, 0-1: each part counts
    1 where a folder or the file's name starts with it (0.8 where a word inside one does; a number only
    as a whole number, so "02" isn't in "020-x"), half as much
    again where it's in the folder right after the last part's, and a quarter if the last part is in
    the file's name. Earlier parts weigh more (1.5 for the first down to 1 for the last), since they say
    where: "02/020/030" is nearer 02/020/010 than 01/020/030. Parts may go unmatched ("02/020/030" still finds 02/020-x/010-y.md), but at least
    half of them (two of three, both of two) have to match, in order."""
    parts = [x for x in word.split("/") if x]
    if not parts or not any(x in low for x in parts):
        return 0.0
    comps, lows = s.split("/"), low.split("/")

    def part(x, k):  # a number only matches a whole number: "02" isn't in "020-morning-praxis"
        c, i = lows[k], lows[k].find(x)
        while i >= 0:
            j = i + len(x)
            if (i == 0 or word_start(comps[k], i)) and not (x[-1].isdigit() and j < len(c) and c[j].isdigit()):
                return 1.0 if i == 0 else 0.8
            i = c.find(x, i + 1)
        return 0.0

    memo = {}

    def best(i, j, chained):  # parts i.. in folders j..; chained: part i-1 matched folder j-1
        if i == len(parts):
            return 0.0
        if (i, j, chained) not in memo:
            r = best(i + 1, j, False)
            for k in range(j, len(comps)):
                if q := part(parts[i], k) * weights[i]:
                    q += (0.5 if chained and k == j else 0) + (0.25 if i == len(parts) - 1 and k == len(comps) - 1 else 0)
                    r = max(r, q + best(i + 1, k + 1, True))
            memo[i, j, chained] = r
        return memo[i, j, chained]

    n = len(parts)
    weights = [1 + 0.5 * (n - 1 - i) / max(1, n - 1) for i in range(n)]
    score = best(0, 0, False)
    return score / (sum(weights) + 0.5 * (n - 1) + 0.25) if score >= 0.8 * min(n, max(2, -(-n // 2))) else 0.0


def match_name(words, entry):
    """Score (0-1) of a file whose name or path holds every word, at least one in the name or one a path
    (with slashes); else 0."""
    s, low, name_start = entry
    total, any_in_name = 0.0, False
    for w in words:
        q, in_name = (match_path(w, s, low), True) if "/" in w else match_word(w, s, low, name_start)
        if not q:
            return 0.0
        total += q
        any_in_name |= in_name
    return total / len(words) if any_in_name else 0.0


class Index:
    """All chunk and name vectors in memory for brute-force cosine search, and every file's path for
    matching names; reloads when the DB changes."""

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
            names = db.execute("SELECT path, vec FROM names ORDER BY path").fetchall()
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
            first_chunk = {}
            for r in rows:
                first_chunk.setdefault(r[1], r[2])
            rels = [pretty(n[0]).removeprefix("~/") for n in names]
            self.names = ([n[0] for n in names], [(r, r.lower(), r.rfind("/") + 1) for r in rels],
                          np.frombuffer(b"".join(n[1] for n in names), dtype=np.float16).reshape(-1, DIM).astype(np.float32)
                          if names else np.zeros((0, DIM), np.float32), first_chunk)
            self.version = v

    def search(self, qvec, max_results=5, min_score=0.0):
        """Best chunk or name per file, files ranked by its similarity. Copies of the same text show once."""
        ids, paths, texts, hashes, vecs, fingerprints = self.data
        name_paths, _, name_vecs, first_chunk = self.names
        n = max(50, max_results * 20)
        scores, name_scores = vecs @ qvec, name_vecs @ qvec
        top = sorted([(float(scores[i]), i, False) for i in np.argsort(-scores)[:n]] +
                     [(float(name_scores[i]), i, True) for i in np.argsort(-name_scores)[:n]], reverse=True)
        results, seen = [], set()
        for score, i, by_name in top:
            if score < min_score:
                break
            if by_name:
                path = name_paths[i]
                fp, h, text = fingerprints.get(path, path), path, first_chunk.get(path, "")
            else:
                path, fp, h, text = paths[i], fingerprints[paths[i]], hashes[i], texts[i]
            if fp in seen or h in seen or path in seen:
                continue
            seen.update((fp, h, path))
            results.append({"path": path, "text": text, "score": score})
            if len(results) == max_results:
                break
        return results

    def match_names(self, query, max_results=3):
        """Files whose name and path hold every word of the query, fuzzily, at least one in the name; best
        (score 0-1) first, then shorter paths."""
        words = query.lower().split()
        if not words:
            return []
        name_paths, entries, _, first_chunk = self.names
        hits = sorted(((q, len(e[0]), i) for i, e in enumerate(entries) if (q := match_name(words, e))),
                      key=lambda h: (-h[0], h[1]))
        return [{"path": name_paths[i], "text": first_chunk.get(name_paths[i], ""), "score": q}
                for q, _, i in hits[:max_results]]

    def find(self, query, qvec, max_results=5, min_score=0.0, max_names=3):
        """Up to max_names files matched by name first ("by_name"), then the closest by meaning."""
        names = self.match_names(query, max_names)
        for r in names:
            r["by_name"] = True
        shown = {r["path"] for r in names}
        return names + [r for r in self.search(qvec, max_results + len(names), min_score)
                        if r["path"] not in shown][: max(0, max_results - len(names))]


def snippet(text, n=140):
    s = " ".join(text.split())
    return s if len(s) <= n else s[: n - 1].rsplit(" ", 1)[0] + "…"


def pretty(path):
    home = str(Path.home())
    return "~" + path[len(home):] if path.startswith(home) else path


def locations(paths, folders):
    """Short labels for where each file sits that tell the results apart: its project (the first folder
    under the indexed folder it's in), its own folder, and the folders between that differ from another
    result's in the same project at the same depth; runs of shared ones of 4 letters or more become "…"
    ("fso/…/drafts/02/020-morning-praxis" beside "fso/…/outlines/02"). The indexed folder ("~/Projects")
    shows only when the results come from more than one, or the file sits right in it. Files outside
    them count from home ("~") or "/", so ~/src and /src stay apart."""
    home = str(Path.home())
    roots = sorted({str(f).rstrip("/") for f in folders} | {home}, key=len, reverse=True)
    split = []
    for p in paths:
        parent = str(Path(p).parent)
        root = next((r for r in roots if parent == r or parent.startswith(r + "/")), "")
        rel = parent[len(root):].strip("/")
        split.append((root, rel.split("/") if rel else []))
    many_roots = len({r for r, _ in split}) > 1
    labels = []
    for root, parts in split:
        same = [q for r, q in split if r == root and q[:1] == parts[:1]]
        out, run = [], []
        for i, seg in enumerate(parts):
            if 0 < i < len(parts) - 1 and all(len(q) > i and q[i] == seg for q in same):
                run.append(seg)
                continue
            if run:
                out += ["…"] if len("/".join(run)) >= 4 else run
                run = []
            out.append(seg)
        label = "/".join(out)
        if many_roots or not parts:
            label = (pretty(root) or "") + "/" + label if label else pretty(root) or "/"
        labels.append(label)
    return labels


# ---------------------------------------------------------------------------- KRunner D-Bus runner

ICONS = {".pdf": "application-pdf", ".md": "text-markdown", ".docx": "x-office-document",
         ".odt": "x-office-document", ".html": "text-html", ".htm": "text-html", ".tex": "text-x-tex"}


def icon(path):
    if path.suffix.lower() in ICONS:
        return ICONS[path.suffix.lower()]
    mime = mimetypes.guess_type(path.name)[0]
    return mime.replace("/", "-") if mime else "text-plain"


def serve():
    from dbus_fast import Message, Variant
    from dbus_fast.aio import MessageBus
    from dbus_fast.constants import PropertyAccess
    from dbus_fast.service import ServiceInterface, dbus_property, method

    cfg = load_config()
    emb = Embedder(cfg)
    index = Index()
    index.refresh(force=True)
    log(f"loaded {len(index.data[0])} chunks, {len(index.names[0])} names")
    query_pool = ThreadPoolExecutor(max_workers=1)

    class Runner(ServiceInterface):
        def __init__(self):
            super().__init__("org.kde.krunner1")
            self.seq = 0
            self.matches = {}  # match id -> path, for Run
            self.session_over = False
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
            # KRunner ends the session as its window hides, which can be just before it sends Run for the
            # clicked result, so the matches are only forgotten when the next session starts
            self.session_over = True

        @method()
        def SetActivationToken(self, token: "s"):
            self.token = token

        @method()
        async def Match(self, query: "s") -> "a(sssida{sv})":
            if self.session_over:
                self.matches.clear()
                self.session_over = False
            self.seq += 1
            mine = self.seq
            LAST_QUERY[0] = time.monotonic()
            await asyncio.sleep(0.15)  # wait for typing to pause; newer queries supersede this one
            if mine != self.seq or len(query.strip()) < 4:
                return []
            loop = asyncio.get_running_loop()

            def work():
                index.refresh()
                return index.find(query, emb.embed_query(query), cfg["max_results"], cfg["min_score"])

            results = await loop.run_in_executor(query_pool, work)
            LAST_QUERY[0] = time.monotonic()
            if mine != self.seq:
                return []
            out = []
            where = locations([r["path"] for r in results], cfg["folders"])
            for r, folder in zip(results, where):
                mid = r["path"]
                self.matches[mid] = r["path"]
                p = Path(r["path"])
                # 70 = KRunner "High" category relevance, the same as browser history; within a tie,
                # KRunner orders by the relevance value, where our similarity (~0.6-0.8) usually wins.
                # Matches by name (0.9-1) go above those by meaning.
                out.append([mid, p.name, icon(p), 70, 0.9 + 0.1 * r["score"] if r.get("by_name") else r["score"], {
                    # where it is, and for a match by meaning the passage that matched: milou shows the first
                    # line in the row and the rest in the row's tooltip, under the full path
                    "subtext": Variant("s", folder if r.get("by_name") or not r["text"] else f"{folder}\n{snippet(r['text'], 200)}"),
                    "urls": Variant("as", [p.as_uri()]),
                    "category": Variant("s", "Semantic Search"),
                }])
            return out

        @method()
        def Run(self, match_id: "s", action_id: "s"):
            path = self.matches.get(match_id)
            if not path:
                log(f"run {action_id or 'open'}: unknown match {match_id!r} ({len(self.matches)} known)")
                return
            log(f"run {action_id or 'open'}: {path}")
            env = dict(os.environ, XDG_ACTIVATION_TOKEN=self.token) if self.token else None
            try:  # D-Bus would swallow the exception
                if action_id == "folder":
                    launch(["dolphin", "--select", path], env)
                elif action_id == "copy":
                    launch(["qdbus6", "org.kde.klipper", "/klipper", "setClipboardContents", path])
                else:
                    launch(["xdg-open", path], env)
            except OSError as e:
                log(f"run {action_id or 'open'} failed: {e}")
            self.token = ""

    index_now = threading.Event()  # set by Indexer.Index: run without waiting for the next interval

    class Indexer(ServiceInterface):
        """For KRunner's indexing bar: Progress is the share of the files done (0-1) while new or
        changed files are being indexed, -1 otherwise. Index() (the "Index" launcher) indexes now and
        says so in a notification when it's done."""

        def __init__(self):
            super().__init__(BUS_NAME + ".Indexer")
            self.progress = -1.0

        @method()
        def Index(self):
            index_now.set()

        @dbus_property(access=PropertyAccess.READ)
        def Progress(self) -> "d":
            return self.progress

        def set_progress(self, value):
            if value != self.progress:
                self.progress = value
                self.emit_properties_changed({"Progress": value})

    async def notify(bus, summary, body):
        await bus.call(Message(
            destination="org.freedesktop.Notifications", path="/org/freedesktop/Notifications",
            interface="org.freedesktop.Notifications", member="Notify", signature="susssasa{sv}i",
            body=["Semantic Search", 0, "edit-find", summary, body, [], {}, -1]))

    def files(n):
        return f"{n} file" if n == 1 else f"{n} files"

    def reindex_loop(indexer, loop, bus):
        reindex_emb = emb  # same compiled model; each thread gets its own infer request
        last = [0.0]

        def report(share):  # from this thread to the bus, at most 4 times a second while it goes on
            now = time.monotonic()
            if share is not None and share > 0 and now - last[0] < 0.25:
                return
            last[0] = now
            loop.call_soon_threadsafe(indexer.set_progress, -1.0 if share is None else share)

        while True:
            asked = index_now.is_set()  # (a request during a run gets a run of its own afterwards)
            index_now.clear()
            try:
                indexed, removed = update_index(reindex_emb, load_config(), progress=report)
                done = ([f"{files(indexed)} indexed"] if indexed else []) + ([f"{files(removed)} removed"] if removed else [])
                summary, body = "Index up to date", ", ".join(done) or "No new or changed files"
            except Exception as e:
                log(f"indexing failed: {e!r}")
                summary, body = "Indexing failed", str(e)
            if asked:
                asyncio.run_coroutine_threadsafe(notify(bus, summary, body), loop)
            index_now.wait(cfg["reindex_minutes"] * 60)

    async def main():
        bus = await MessageBus().connect()
        bus.export("/runner", Runner())
        indexer = Indexer()
        bus.export("/indexer", indexer)
        await bus.request_name(BUS_NAME)
        log(f"KRunner runner on D-Bus as {BUS_NAME}")
        # set by tools/preview so a second instance never races the real service on the index
        if not os.environ.get("EMBEDSEARCH_NO_REINDEX"):
            threading.Thread(target=reindex_loop, args=(indexer, asyncio.get_running_loop(), bus), daemon=True).start()
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
        results = index.find(q, emb.embed_query(q), max_results=10)
        log(f"{len(index.data[0])} chunks and {len(index.names[0])} names searched"
            f" in {(time.perf_counter() - t) * 1000:.0f} ms")
        for r in results:
            print(f"{r['score']:.3f}{' name' if r.get('by_name') else '     '}  {pretty(r['path'])}\n"
                  f"             {snippet(r['text'], 160)}")
    elif cmd == "status":
        db = connect()
        files, chunks = db.execute("SELECT COUNT(*), COALESCE(SUM(chunks), 0) FROM files").fetchone()
        empty = db.execute("SELECT COUNT(*) FROM files WHERE chunks=0").fetchone()[0]
        names = db.execute("SELECT COUNT(*) FROM names").fetchone()[0]
        print(f"{files} files indexed ({empty} with no extractable text), {chunks} chunks; {names} files by name")
        print(f"index: {DB_PATH} ({DB_PATH.stat().st_size / 1e6:.0f} MB)" if DB_PATH.exists() else "no index yet")
        print(f"config: {CONFIG_PATH}")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
