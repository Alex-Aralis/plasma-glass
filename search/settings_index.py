#!/usr/bin/env python3
"""Build search/settings-index.json: every option, section and tab label inside the installed System
Settings pages, read from the source tarballs of the packages that install them.

    settings_index.py [OUT.json]

KRunner's own System Settings runner only knows each page's name, description and keywords, so
"focus stealing" or "tap to click" find nothing. This lists the labels in each page's .ui, .qml and
.kcfg files with the page (and for Window Behavior, the tab) they're on; embedsearch searches them.
The sources come from /var/cache/distfiles (Portage keeps them), matching the installed versions.
Re-run after a Plasma upgrade.
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


def tarballs():
    """The source tarball of each package that installs a System Settings page."""
    pkgs = set()
    for d in KCM_DIRS:
        for so in d.glob("*.so"):
            out = subprocess.run(["qfile", "-qC", str(so)], capture_output=True, text=True).stdout.split()
            pkgs.update(out[:1])
    found = []
    for pkg in sorted(pkgs):
        cpv = subprocess.run(["qlist", "-Iv", "-e", pkg], capture_output=True, text=True).stdout.split()
        if not cpv:
            continue
        pv = re.sub(r"-r\d+$", "", cpv[0].split("/", 1)[1])
        tar = next((t for t in sorted(DISTFILES.glob(pv + ".tar.*"))), None)
        if tar:
            found.append(tar)
        else:
            print(f"no source for {pv}", file=sys.stderr)
    return found


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


def build():
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
    return sorted(entries, key=lambda e: (e["kcm"], e["args"], e["where"], e["text"])), pages


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else OUT
    entries, pages = build()
    out.write_text(json.dumps({"pages": {k: {"name": v["name"], "icon": v["icon"]} for k, v in sorted(pages.items())},
                               "entries": entries}, indent=0, ensure_ascii=False) + "\n")
    print(f"{len(entries)} settings from {len(pages)} pages -> {out}")


if __name__ == "__main__":
    main()
