# plasma-glass (install-system.sh puts this in /etc/portage/env/kde-plasma/kwin, which Portage sources for
# KWin's own merges): the Liquid Glass effect, a KWin plugin of its own, only loads into the KWin it was built
# against, so it's built again for each KWin that's merged. Without it KWin runs with no blur at all (kwinrc
# has the built-in one off).
post_pkg_postinst() {
    local tool=/usr/local/share/plasma-glass/tools/kwin-effect.sh
    [[ -x ${tool} ]] || return 0
    einfo "plasma-glass: building the Liquid Glass effect for this KWin"
    if XDG_CACHE_HOME=/var/cache/plasma-glass "${tool}" install; then
        einfo "plasma-glass: it loads from the next login (or now: tools/kwin-effect.sh reload, as the desktop user)"
    else
        ewarn "plasma-glass: the Liquid Glass effect didn't build for this KWin: see"
        ewarn "/var/cache/plasma-glass/plasma-glass/effect/build.log. Until it does, KWin has no blur (the built-in"
        ewarn "one back: tools/kwin-effect.sh disable, as the desktop user)"
    fi
}
