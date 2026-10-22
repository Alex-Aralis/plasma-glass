#!/usr/bin/env python3
"""Build search/settings-index.json: every option, section and tab label inside the installed System
Settings pages, read from the source tarballs of the packages that install them.

    settings_index.py [OUT.json]

KRunner's own System Settings runner only knows each page's name, description and keywords, so
"focus stealing" or "tap to click" find nothing. This lists the labels in each page's .ui, .qml and
.kcfg files with the page (and for Window Behavior, the tab) they're on; embedsearch searches them.
The sources come from /var/cache/distfiles (Portage keeps them), matching the installed versions.
Re-run after a Plasma upgrade.

The Shortcuts page's Common Actions (Copy, Find, Zoom In: KStandardShortcut, from kconfig's source) are
listed too, with their default keys, and Qt's key names, which embedsearch uses to write out the keys
of the global shortcuts it lists itself (those depend on what's installed and running).

Pages installed on another machine but not this one keep their entries from the existing OUT, so
the list built on either machine covers both.
"""

import json
import re
import subprocess
import sys
import tarfile
import xml.etree.ElementTree as ET
from pathlib import Path

DISTFILES = Path("/var/cache/distfiles")
KCM_DIRS = [Path("/usr/lib64/qt6/plugins/plasma/kcms/systemsettings"),
            Path("/usr/lib64/qt6/plugins/plasma/kcms/systemsettings_qwidgets")]
OUT = Path(__file__).resolve().parent / "settings-index.json"

# Pages built from tabs, which open on a tab given as an argument (`systemsettings kcm --args KEY`; the
# kwin patch adds that to Window Behavior): source file -> (tab title, argument)
TABS = {
    "kcm_kwinoptions": {
        "focus.ui": ("Focus", "focus"),
        "mouse.ui": ("Titlebar Actions", "titlebar-actions"),
        "actions.ui": ("Window Actions", "window-actions"),
        "moving.ui": ("Movement", "movement"),
        "advanced.ui": ("Advanced", "advanced"),  # (pip.ui's tab only shows with KWIN_WAYLAND_SUPPORT_XX_PIP_V1)
    },
}

# Pages that share a source folder: which of its files are whose
SHARED = {
    "kcm_kwintouchscreen": re.compile(r"touch", re.I),
}

I18N = re.compile(r'\bi18n(c|d|dc|p|cp|dp|dcp)?\s*\(\s*((?:"(?:[^"\\]|\\.)*"\s*,\s*)*)"((?:[^"\\]|\\.)*)"')
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
# Buttons and words that say nothing without the control beside them
GENERIC = {"none", "none selected", "details", "modify", "get new", "apply", "add", "remove", "edit", "configure", "default",
           "defaults", "custom", "delete", "ok", "cancel", "close", "name", "description", "type", "reset",
           "change", "browse", "select", "open", "save", "new", "other", "more", "help", "test", "preview",
           "enabled", "disabled", "on", "off", "yes", "no", "auto", "automatic", "manual", "always", "never"}
NOISE = re.compile(r"^(could not|couldn't|cannot|can't|failed|unable|error|an error|no |loading|please wait)", re.I)


def installed_kcms():
    return {p.stem for d in KCM_DIRS if d.is_dir() for p in d.glob("*.so")}


def installed_pv(pkg):
    """The installed CATEGORY/NAME's name and version without the revision ("kconfig-6.31.0"), or None."""
    cpv = subprocess.run(["qlist", "-Iv", "-e", pkg], capture_output=True, text=True).stdout.split()
    return re.sub(r"-r\d+$", "", cpv[0].split("/", 1)[1]) if cpv else None


def tarballs():
    """The source tarball of each package that installs a System Settings page."""
    pkgs = set()
    for d in KCM_DIRS:
        for so in d.glob("*.so"):
            out = subprocess.run(["qfile", "-qC", str(so)], capture_output=True, text=True).stdout.split()
            pkgs.update(out[:1])
    found = []
    for pkg in sorted(pkgs):
        pv = installed_pv(pkg)
        if not pv:
            continue
        tar = next((t for t in sorted(DISTFILES.glob(pv + ".tar.*"))), None)
        if tar:
            found.append(tar)
        else:
            print(f"no source for {pv}", file=sys.stderr)
    return found


def source_file(pkg, path, top="{pv}"):
    """The text of PATH in the installed PKG's source tarball, whose top folder is TOP ("{pv}" is the
    package's name-version; Qt's are "qtbase-everywhere-src-6.11.2")."""
    pv = installed_pv(pkg) or sys.exit(f"{pkg} is not installed")
    top = top.format(pv=pv, v=pv.rsplit("-", 1)[1])
    tar = next(iter(sorted(DISTFILES.glob(top + ".tar.*"))), None) or sys.exit(f"no source for {top} in {DISTFILES}")
    with tarfile.open(tar, "r|*") as t:  # a stream: stops reading once the file has gone by
        for m in t:
            if m.name == f"{top}/{path}":
                return t.extractfile(m).read().decode("utf-8", "replace")
    sys.exit(f"{path} not in {tar}")


def qt_keys():
    """Qt's key codes and the English names QKeySequence gives them ("PgUp", "Volume Down"), for the
    keys that aren't one printable character or F1-F35. Values from the installed qnamespace.h, names
    from QKeySequence's own table."""
    header = Path("/usr/include/qt6/QtCore/qnamespace.h").read_text()
    codes = {name: int(value, 0) for name, value in re.findall(r"\b(Key_\w+)\s*=\s*(0x[0-9a-fA-F]+|\d+)", header)}
    table = source_file("dev-qt/qtbase", "src/gui/kernel/qkeysequence.cpp", "qtbase-everywhere-src-{v}")
    names = {}
    for key, name in re.findall(r'\{\s*Qt::(Key_\w+),\s*QT_TRANSLATE_NOOP\("QShortcut",\s*"([^"]*)"\)\s*\}', table):
        if key in codes:
            names.setdefault(codes[key], name)  # QKeySequence takes the first one listed
    return codes, names


def split_top(s):
    """S's comma-separated parts, not splitting inside (), {} or strings."""
    parts, depth, cur, quote = [], 0, "", False
    for i, c in enumerate(s):
        if c == '"' and s[i - 1] != "\\":
            quote = not quote
        elif not quote and c in "({":
            depth += 1
        elif not quote and c in ")}":
            depth -= 1
        elif not quote and c == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
            continue
        cur += c
    return parts + [cur.strip()] if cur.strip() else parts


def standard_shortcuts(codes, page):
    """The Shortcuts page's Common Actions: KStandardShortcut's table (kconfig's kstandardshortcut.cpp),
    the Linux side of its #ifs, with each action's name (its key in kdeglobals' [Shortcuts], where a
    changed one is kept), label, category and default keys as Qt key codes."""
    src = source_file("kde-frameworks/kconfig", "src/gui/kstandardshortcut.cpp")
    mods = {"CTRL": 0x04000000, "SHIFT": 0x02000000, "ALT": 0x08000000, "META": 0x10000000}
    macros = {name: sum(mods[m] for m in re.findall(r"Qt::(CTRL|SHIFT|ALT|META)\b", body))
              for name, body in re.findall(r"#define (\w+)\(x\) (.*)", src)}
    body = src[src.index("g_infoStandardShortcut[] = {"):]
    body = body[body.index("{") + 1: body.index("};")]  # (entries end in "},")
    kept, skip = [], []
    for line in body.splitlines():
        s = line.strip()
        if s.startswith("#if"):
            skip.append("Q_OS_MACOS" in s and "!" not in s)
        elif s.startswith("#else"):
            skip[-1] = not skip[-1]
        elif s.startswith("#endif"):
            skip.pop()
        elif not any(skip) and not s.startswith("//"):
            kept.append(line)
    rows, depth, start = [], 0, 0
    text = "\n".join(kept)
    for i, c in enumerate(text):  # each top-level {...} is one shortcut
        if c == "{":
            depth += 1
            if depth == 1:
                start = i + 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                rows.append(split_top(text[start:i]))
    entries = []
    for f in rows:
        label = re.findall(r'"((?:[^"\\]|\\.)*)"', f[2])
        category = re.match(r"Category::(\w+)", f[-1])
        if not f[1].startswith('"') or len(label) < 2 or not category or category[1] == "InvalidCategory":
            continue
        keys = [macros[m] | codes["Key_" + k] if m else codes[q]
                for m, k, q in re.findall(r"\b(\w+)\((\w+)\)|Qt::(Key_\w+)", f[3]) if (m in macros and "Key_" + k in codes) or q in codes]
        entries.append({"kcm": "kcm_keys", "text": label[1], "where": f"{page} › Common Actions › {category[1]}",
                        "args": f"{category[1]} {label[1]}", "detail": f"keyboard shortcut, Common Actions › {category[1]}",
                        "shortcut": f[1].strip('"'), "default_keys": keys})
    return entries


def clean(s):
    s = s.replace('\\"', '"').replace("\\n", " ").replace("&&", "\0").replace("&", "").replace("\0", "&")
    s = re.sub(r"<[^>]+>", " ", s)
    s = " ".join(s.split()).strip()
    return s.rstrip(":").strip()


def keep(s, section=""):
    bare = s.rstrip("…").rstrip(".").strip().lower()
    if bare in GENERIC or not s[:1].isupper() and not s[:1].isdigit():  # "repeats/s", "focus": units, roles
        return False
    if " " not in bare and not section:  # a lone word needs its group to mean anything
        return False
    return (3 <= len(s) <= 90 and re.search(r"[A-Za-z]{3}", s) and "%" not in s and not NOISE.match(s)
            and not s.startswith(("http", "@", "kcm_")))


def context_hint(args):
    """The translators' context of an i18nc call, unless it's only a markup tag like "@label"."""
    ctx = [clean(m) for m in STRING.findall(args)]
    ctx = [c for c in ctx if c and not re.fullmatch(r"@[\w:]+", c)]
    return re.sub(r"^@[\w:]+\s*", "", ctx[-1]) if ctx else ""


def from_qml(text):
    """(label, section, context) for each translated string, in order. The section is the last group
    title (an "@title" context or a FormData section) above it."""
    out, section = [], ""
    for m in I18N.finditer(text):
        kind, args, s = m.group(1) or "", m.group(2), clean(m.group(3))
        if "d" in kind:  # i18nd/i18ndc: the first argument is the catalog
            args = STRING.sub("", args, count=1)
        ctx = context_hint(args) if "c" in kind else ""
        line = text[text.rfind("\n", 0, m.start()) + 1: text.find("\n", m.end())]
        if "@title" in args or "isSection" in text[m.start() - 200: m.start()] or "Heading" in line:
            section = s
            out.append((s, "", ctx))
            continue
        out.append((s, section, ctx))
    return out


def from_ui(text):
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        return []
    out = []

    def walk(node, section):
        if node.tag == "widget":
            props = {p.get("name"): clean("".join(p.itertext())) for p in node.findall("property")}
            title = props.get("title") or ""
            label = props.get("text") or ""
            detail = props.get("toolTip") or props.get("whatsThis") or ""
            if label:
                out.append((label, section, detail[:300]))
            if title:
                out.append((title, "", detail[:300]))
                section = title
        for child in node:
            walk(child, section)
        if node.tag == "attribute" and node.get("name") == "title":  # QTabWidget page titles
            out.append((clean("".join(node.itertext())), "", ""))

    walk(root, "")
    return out


def from_kcfg(text):
    try:
        root = ET.fromstring(re.sub(r'\sxmlns="[^"]+"', "", text, count=1))
    except ET.ParseError:
        return []
    return [(clean(e.findtext("label") or ""), "", clean(e.findtext("whatsthis") or "")[:300])
            for e in root.iter("entry") if e.findtext("label")]


def build(codes):
    kcms = installed_kcms()
    pages = {}  # kcm id -> {"name", "icon", "description", "dir"}
    files = {}  # path in tarball -> text
    for tar in tarballs():
        with tarfile.open(tar) as t:
            for m in t.getmembers():
                if not m.isfile() or "/test" in m.name or "/autotests/" in m.name or "/po/" in m.name:
                    continue
                if m.name.endswith((".ui", ".qml", ".kcfg")) or (m.name.endswith(".json") and Path(m.name).stem in kcms):
                    files[m.name] = t.extractfile(m).read().decode("utf-8", "replace")
    for path, text in files.items():
        if not path.endswith(".json"):
            continue
        try:
            meta = json.loads(text)
        except ValueError:
            continue
        kp = meta.get("KPlugin", {})
        if "Name" not in kp:
            continue
        # the pages System Settings shows in a Plasma Wayland session on a desktop (kcmmetadatahelpers.h)
        platforms = meta.get("X-KDE-OnlyShowOnQtPlatforms", [])
        if platforms and not any(p.startswith("wayland") for p in platforms):
            continue
        if kp.get("FormFactors") and not {"desktop", "all"} & set(kp["FormFactors"]):
            continue
        pages[Path(path).stem] = {"name": kp["Name"], "icon": kp.get("Icon", "preferences-system"),
                                  "description": kp.get("Description", ""), "dir": str(Path(path).parent)}

    # each file belongs to the page whose folder is its nearest ancestor
    by_dir = {}
    for kcm, p in pages.items():
        by_dir.setdefault(p["dir"], []).append(kcm)
    entries, seen = [], set()

    def add(kcm, text, section="", detail="", tab=None):
        page = pages[kcm]
        key = (kcm, text.lower(), tab and tab[1])
        if not keep(text, section or (tab and tab[0]) or "") or key in seen:
            return
        seen.add(key)
        where = [page["name"]] + ([tab[0]] if tab else []) + ([section] if section and section != text else [])
        entries.append({"kcm": kcm, "text": text, "where": " › ".join(where), "icon": page["icon"],
                        "args": tab[1] if tab else "", "detail": detail if detail != text else ""})

    for path in sorted(files):
        if path.endswith(".json"):
            continue
        d = str(Path(path).parent)
        while d not in by_dir and "/" in d:
            d = d.rsplit("/", 1)[0]
        owners = by_dir.get(d)
        if not owners:
            continue
        name = Path(path).name
        kcm = next((k for k in owners if k in SHARED and SHARED[k].search(name)), None) or \
            next((k for k in owners if k not in SHARED), owners[0])
        tab = TABS.get(kcm, {}).get(name)
        if kcm in TABS and tab is None and name.endswith(".ui"):
            continue  # a tabbed page's file that isn't one of its tabs
        text = files[path]
        rows = from_ui(text) if name.endswith(".ui") else from_qml(text) if name.endswith(".qml") else from_kcfg(text)
        for label, section, detail in rows:
            add(kcm, label, section, detail, tab)

    for kcm, tabs in TABS.items():
        if kcm in pages:
            for title, arg in tabs.values():
                add(kcm, title, "", f"{pages[kcm]['name']} tab", (title, arg))
    if "kcm_keys" in pages:
        entries += [dict(e, icon=pages["kcm_keys"]["icon"]) for e in standard_shortcuts(codes, pages["kcm_keys"]["name"])]
    return entries, pages


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else OUT
    codes, keys = qt_keys()
    entries, pages = build(codes)
    pages = {k: {"name": v["name"], "icon": v["icon"]} for k, v in pages.items()}
    try:  # the pages this machine lacks (or has no source for) keep their entries from the last list
        old = json.loads((out if out.exists() else OUT).read_text())
    except (OSError, ValueError):
        old = {"pages": {}, "entries": []}
    kept = sorted(k for k in old["pages"] if k not in pages)
    pages.update({k: old["pages"][k] for k in kept})
    entries += [e for e in old["entries"] if e["kcm"] in kept]
    entries.sort(key=lambda e: (e["kcm"], e["args"], e["where"], e["text"]))
    out.write_text(json.dumps({"pages": dict(sorted(pages.items())), "keys": {str(c): n for c, n in sorted(keys.items())},
                               "entries": entries}, indent=0, ensure_ascii=False) + "\n")
    print(f"{len(entries)} settings from {len(pages)} pages -> {out}" + (f" ({', '.join(kept)} kept from the last list)" if kept else ""))


if __name__ == "__main__":
    main()
