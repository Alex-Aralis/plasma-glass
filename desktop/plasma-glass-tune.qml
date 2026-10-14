/*
    SPDX-FileCopyrightText: 2026 Alex Aralis

    SPDX-License-Identifier: GPL-2.0-or-later
*/

// Liquid Glass Tuning: KRunner's busy ripple and the dark Liquid Glass, live. Each change goes to
// ~/.config/plasma-glassrc within a tenth of a second; plasma-glass's KRunner takes it with its next knock,
// its KWin at once. While this is open (and "Keep rippling" is on), KRunner's ripple runs all the time and
// KRunner stays open when you click here: open it (Meta+Space) and tune beside it.
//   qml6 -a widget plasma-glass-tune.qml        (install.sh installs it as plasma-glass-tune)
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.ApplicationWindow {
    id: window
    title: "Liquid Glass Tuning"
    width: Kirigami.Units.gridUnit * 34
    height: Kirigami.Units.gridUnit * 46
    minimumWidth: Kirigami.Units.gridUnit * 26
    minimumHeight: Kirigami.Units.gridUnit * 20

    Settings {
        id: store
        location: StandardPaths.writableLocation(StandardPaths.ConfigLocation) + "/plasma-glassrc"
    }

    // changes go out together, at most ten times a second, so a drag reaches KRunner and KWin as it goes
    property var pending: ({})
    function put(key: string, value: var): void {
        pending[key] = value;
        if (!flush.running) {
            flush.start();
        }
    }
    function write(): void {
        for (const key in pending) {
            store.setValue(key, pending[key]);
        }
        pending = {};
        store.sync();
    }
    Timer {
        id: flush
        interval: 100
        onTriggered: window.write()
    }

    // KRunner ripples and stays open while this heartbeat is fresh: it runs out 5 s after the last one, so a
    // crash here doesn't leave KRunner rippling
    Timer {
        interval: 2000
        repeat: true
        triggeredOnStart: true
        running: keepRippling.checked
        onTriggered: window.put("Ripple/tuning", Math.round(Date.now() / 1000) + 5)
        onRunningChanged: if (!running) {
            window.put("Ripple/tuning", 0);
        }
    }
    onClosing: {
        put("Ripple/tuning", 0);
        write();
    }

    property list<Item> tuners
    function resetAll(): void {
        for (const tuner of tuners) {
            tuner.set(tuner.fallback);
        }
        side.set(0);
    }

    // one setting: a slider, its value, and a button back to its default
    component Tuner: RowLayout {
        id: tuner
        required property string key
        required property real fallback
        property real from: 0
        property real to: 1
        property real stepSize: 0
        property int decimals: 0
        property string unit: ""
        property bool percent: false
        property real value: key ? Number(store.value(key, fallback)) : fallback
        function show(v: real): string {
            return percent ? Math.round(v * 100) + "%" : v.toFixed(decimals) + (unit ? " " + unit : "");
        }
        function set(v: real): void {
            value = v;
            window.put(key, v);
        }
        // to the step, done here: a slider with a step draws a tick for each
        function snap(v: real): real {
            return stepSize > 0 ? Number((Math.round(v / stepSize) * stepSize).toFixed(6)) : v;
        }
        Component.onCompleted: window.tuners.push(tuner)
        spacing: Kirigami.Units.smallSpacing
        QQC2.Slider {
            Layout.fillWidth: true
            Layout.minimumWidth: Kirigami.Units.gridUnit * 10
            from: tuner.from
            to: tuner.to
            value: tuner.value
            onMoved: tuner.set(tuner.snap(value))
        }
        QQC2.Label {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 4
            horizontalAlignment: Text.AlignRight
            text: tuner.show(tuner.value)
        }
        QQC2.ToolButton {
            icon.name: "edit-reset"
            display: QQC2.AbstractButton.IconOnly
            text: "Back to " + tuner.show(tuner.fallback)
            enabled: Math.abs(tuner.value - tuner.fallback) > 1e-6
            onClicked: tuner.set(tuner.fallback)
            QQC2.ToolTip.text: text
            QQC2.ToolTip.visible: hovered
            QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
        }
    }
    // a note under a setting
    component Hint: QQC2.Label {
        Layout.fillWidth: true
        Layout.maximumWidth: Kirigami.Units.gridUnit * 22
        wrapMode: Text.Wrap
        font: Kirigami.Theme.smallFont
        opacity: 0.75
    }

    pageStack.initialPage: Kirigami.ScrollablePage {
        title: "Liquid Glass Tuning"
        actions: [
            Kirigami.Action {
                text: "Reset All"
                icon.name: "edit-reset"
                onTriggered: window.resetAll()
            }
        ]
        header: Kirigami.InlineMessage {
            visible: true
            position: Kirigami.InlineMessage.Position.Header
            text: "Changes apply as you move the sliders: KRunner takes them with its next knock, KWin at once. Open KRunner (Meta+Space) to see them; it stays open while you work here."
        }

        Kirigami.FormLayout {
            QQC2.Switch {
                id: keepRippling
                Kirigami.FormData.label: "KRunner:"
                text: "Keep rippling while this is open"
                checked: true
            }

            Kirigami.Separator {
                Kirigami.FormData.isSection: true
                Kirigami.FormData.label: "Waves"
            }
            Tuner {
                Kirigami.FormData.label: "Speed:"
                key: "Ripple/speed"; fallback: 120; from: 20; to: 400; stepSize: 5; unit: "px/s"
            }
            Tuner {
                Kirigami.FormData.label: "Width:"
                key: "Ripple/width"; fallback: 21; from: 4; to: 80; stepSize: 1; unit: "px"
            }
            Hint { text: "Half the width of a fresh wave." }
            Tuner {
                Kirigami.FormData.label: "Widening:"
                key: "Ripple/widening"; fallback: 8; from: 0; to: 40; stepSize: 0.5; decimals: 1; unit: "px/s"
            }
            Tuner {
                Kirigami.FormData.label: "Damping:"
                key: "Ripple/damping"; fallback: 36; from: 1; to: 120; stepSize: 1; unit: "s"
            }
            Hint { text: "How long a wave takes to fall to about a third of its height." }
            Tuner {
                id: lifetime
                Kirigami.FormData.label: "Lifetime:"
                key: "Ripple/lifetime"; fallback: 9.5; from: 1; to: 20; stepSize: 0.5; decimals: 1; unit: "s"
            }
            Hint {
                visible: lifetime.value > 8 * interval.value - 0.05
                text: "KRunner keeps 8 waves at most: with a knock every %1 s, each lasts %2 s."
                    .arg(interval.value.toFixed(1)).arg((8 * interval.value - 0.05).toFixed(1))
            }
            Tuner {
                id: interval
                Kirigami.FormData.label: "A knock every:"
                key: "Ripple/interval"; fallback: 1.2; from: 0.3; to: 5; stepSize: 0.1; decimals: 1; unit: "s"
            }
            Tuner {
                Kirigami.FormData.label: "Amplitude:"
                key: "Ripple/amplitude"; fallback: 1; from: 0; to: 2; stepSize: 0.05; decimals: 2
            }
            Hint { text: "How far a fresh wave leans the glass, against the bevel at its edge (1); also how strong Liquid Glass Light's sheen is." }
            Tuner {
                Kirigami.FormData.label: "Colour split:"
                key: "Ripple/aberration"; fallback: 3; from: 0; to: 10; stepSize: 0.5; decimals: 1; unit: "px"
            }
            Hint { text: "Each way, where a wave leans the glass fully (the bevel's is set below)." }
            Tuner {
                Kirigami.FormData.label: "Ringing:"
                key: "Ripple/ringing"; fallback: 1.7; from: 0.3; to: 6; stepSize: 0.1; decimals: 1
            }
            Hint { text: "Half-widths over which the ripples behind each crest fade to about a third." }
            Tuner {
                Kirigami.FormData.label: "Edge fade:"
                key: "Ripple/edgeFade"; fallback: 3; from: 0.5; to: 20; stepSize: 0.5; decimals: 1; unit: "px"
            }
            Hint { text: "Heading into the rim, a wave fades out over about twice this." }

            Kirigami.Separator {
                Kirigami.FormData.isSection: true
                Kirigami.FormData.label: "Where they start"
            }
            QQC2.ComboBox {
                id: side
                Kirigami.FormData.label: "Side:"
                readonly property var keys: ["left", "right", "top", "bottom"]
                model: ["Left", "Right", "Top", "Bottom"]
                currentIndex: Math.max(0, keys.indexOf(String(store.value("Ripple/side", "left"))))
                function set(index: int): void {
                    currentIndex = index;
                    window.put("Ripple/side", keys[index]);
                }
                onActivated: index => set(index)
            }
            Tuner {
                Kirigami.FormData.label: "Position:"
                key: "Ripple/position"; fallback: 1 / 3; from: 0; to: 1; stepSize: 0.01; percent: true
            }
            Hint { text: "Left or right: beside the search field while the dropdown is collapsed, and this far down once results show (never above the search field). Top or bottom: this far across." }

            Kirigami.Separator {
                Kirigami.FormData.isSection: true
                Kirigami.FormData.label: "Glass (dark Liquid Glass)"
            }
            Tuner {
                Kirigami.FormData.label: "Frost:"
                key: "Glass/frost"; fallback: 2; from: 1; to: 15; stepSize: 1
            }
            Hint { text: "Blur strength, as in KWin's Blur settings (15 is the heaviest); never more than yours there." }
            Tuner {
                Kirigami.FormData.label: "Bevel width:"
                key: "Glass/bevelWidth"; fallback: 24; from: 4; to: 60; stepSize: 1; unit: "px"
            }
            Tuner {
                Kirigami.FormData.label: "Refraction:"
                key: "Glass/refraction"; fallback: 9; from: 0; to: 30; stepSize: 0.5; decimals: 1; unit: "px"
            }
            Hint { text: "How far in what's behind is seen at the very edge; past half the bevel's width the view folds over." }
            Tuner {
                Kirigami.FormData.label: "Colour split:"
                key: "Glass/dispersion"; fallback: 2; from: 0; to: 8; stepSize: 0.5; decimals: 1; unit: "px"
            }
            Tuner {
                Kirigami.FormData.label: "Sharpness:"
                key: "Glass/sharpness"; fallback: 1; from: 0; to: 1; stepSize: 0.05; decimals: 2
            }
            Hint { text: "How much of what's behind shows sharp at the rim, rather than frosted." }
        }
    }
}
