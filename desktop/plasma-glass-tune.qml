/*
    SPDX-FileCopyrightText: 2026 Alex Aralis

    SPDX-License-Identifier: GPL-2.0-or-later
*/

// Liquid Glass Tuning: the liquid in KRunner's glass and the Liquid Glass styles' glass, live. Each change
// goes to ~/.config/plasma-glassrc within a tenth of a second, and plasma-glass's KWin takes it at once. While
// this is open (and "Keep stirring" is on), KRunner's liquid is stirred all the time and KRunner stays open
// when you click here: open it (Meta+Space) and tune beside it.
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

    // KRunner is stirred and stays open while this heartbeat is fresh: it runs out 5 s after the last one, so
    // a crash here doesn't leave KRunner stirring
    Timer {
        interval: 2000
        repeat: true
        triggeredOnStart: true
        running: keepStirring.checked
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
        stir.set(0);
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
            text: "Changes apply as you move the sliders. Open KRunner (Meta+Space) to see them; it stays open, and stirred, while you work here."
        }

        Kirigami.FormLayout {
            QQC2.Switch {
                id: keepStirring
                Kirigami.FormData.label: "KRunner:"
                text: "Keep stirring while this is open"
                checked: true
            }
            Hint { text: "KRunner's glass holds a liquid, simulated: while KRunner is busy a stretch of its rim pushes into it again and again, and when you move KRunner, or its dropdown opens or closes, the liquid sloshes. What's behind the glass bends under its waves." }

            Kirigami.Separator {
                Kirigami.FormData.isSection: true
                Kirigami.FormData.label: "Ripples"
            }
            Tuner {
                Kirigami.FormData.label: "Speed:"
                key: "Ripple/speed"; fallback: 120; from: 20; to: 400; stepSize: 5; unit: "px/s"
            }
            Tuner {
                Kirigami.FormData.label: "Width:"
                key: "Ripple/width"; fallback: 21; from: 4; to: 80; stepSize: 1; unit: "px"
            }
            Hint { text: "Half the width of the wave each push makes: wider, and the rim takes longer to push in." }
            Tuner {
                Kirigami.FormData.label: "A push every:"
                key: "Ripple/interval"; fallback: 1.2; from: 0.3; to: 5; stepSize: 0.1; decimals: 1; unit: "s"
            }
            Tuner {
                Kirigami.FormData.label: "Damping:"
                key: "Ripple/damping"; fallback: 36; from: 1; to: 120; stepSize: 1; unit: "s"
            }
            Hint { text: "How long the ripples take to fall to about a third of their height, on their own." }
            Tuner {
                Kirigami.FormData.label: "Rim reflection:"
                key: "Ripple/reflection"; fallback: 0.3; from: 0; to: 1; stepSize: 0.05; percent: true
            }
            Hint { text: "How much of a ripple the rim sends back; the rest soaks into it. At 100% they bounce around the glass until they die down." }
            Tuner {
                Kirigami.FormData.label: "Amplitude:"
                key: "Ripple/amplitude"; fallback: 1; from: 0; to: 2; stepSize: 0.05; decimals: 2
            }
            Hint { text: "How far a wave's steepest slope leans the glass, against the bevel at its edge (1); goes for the sloshing too." }
            Tuner {
                Kirigami.FormData.label: "Colour split:"
                key: "Ripple/aberration"; fallback: 3; from: 0; to: 10; stepSize: 0.5; decimals: 1; unit: "px"
            }
            Hint { text: "Each way, where a wave leans the glass fully (the bevel's is set below)." }
            Tuner {
                Kirigami.FormData.label: "Breeze:"
                key: "Ripple/chop"; fallback: 0.3; from: 0; to: 1.5; stepSize: 0.05; decimals: 2
            }
            Hint { text: "While KRunner is busy, gusts press on the surface here and there, coming and going, and raise small waves all over." }
            Tuner {
                Kirigami.FormData.label: "Gust size:"
                key: "Ripple/chopScale"; fallback: 40; from: 8; to: 120; stepSize: 1; unit: "px"
            }
            Tuner {
                Kirigami.FormData.label: "Jitter:"
                key: "Ripple/jitter"; fallback: 0.6; from: 0; to: 1; stepSize: 0.05; decimals: 2
            }
            Hint { text: "No two pushes alike: each lands a little up or down the side, comes a little early or late, and pushes harder or softer, longer or shorter." }

            Kirigami.Separator {
                Kirigami.FormData.isSection: true
                Kirigami.FormData.label: "Where the pushes land"
            }
            QQC2.ComboBox {
                id: stir
                Kirigami.FormData.label: "Stir by:"
                readonly property var keys: ["push", "press"]
                model: ["Pushing the rim in", "Pressing on the surface"]
                currentIndex: Math.max(0, keys.indexOf(String(store.value("Ripple/stir", "push"))))
                function set(index: int): void {
                    currentIndex = index;
                    window.put("Ripple/stir", keys[index]);
                }
                onActivated: index => set(index)
            }
            Hint { text: "A stretch of the rim pushes in and eases back out; or a press on the surface just inside it, which rings out in circles." }
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
            Tuner {
                Kirigami.FormData.label: "Push width:"
                key: "Ripple/strike"; fallback: 1; from: 1; to: 300; stepSize: 1; unit: "px"
            }
            Hint { text: "How much of the side pushes in as one (the rest bows in less, the further along); wider, and the wave sets out as a flatter front." }

            Kirigami.Separator {
                Kirigami.FormData.isSection: true
                Kirigami.FormData.label: "Momentum"
            }
            Tuner {
                Kirigami.FormData.label: "Momentum:"
                key: "Ripple/momentum"; fallback: 1; from: 0; to: 2; stepSize: 0.05; decimals: 2
            }
            Hint { text: "How much the liquid sloshes when the glass moves or grows: KRunner dragged or its dropdown opening, a popup sliding up, the panel docking. It lags behind as the glass speeds up and runs on as it stops. Works when KRunner isn't busy too. The ripples it stirs are as wide as the pushes' (Width)." }
            Tuner {
                Kirigami.FormData.label: "Slosh speed:"
                key: "Ripple/sloshSpeed"; fallback: 900; from: 200; to: 2000; stepSize: 50; unit: "px/s"
            }
            Hint { text: "How fast the long waves run, as in a deeper liquid: faster, and it rocks back and forth quicker." }
            Tuner {
                Kirigami.FormData.label: "Slosh damping:"
                key: "Ripple/sloshDamping"; fallback: 1.5; from: 0.3; to: 6; stepSize: 0.1; decimals: 1; unit: "s"
            }
            Hint { text: "How long the sloshing takes to die down to about a third." }

            Kirigami.Separator {
                Kirigami.FormData.isSection: true
                Kirigami.FormData.label: "Clicks"
            }
            Tuner {
                Kirigami.FormData.label: "Click press:"
                key: "Ripple/click"; fallback: 1; from: 0; to: 3; stepSize: 0.05; decimals: 2
            }
            Hint { text: "How hard a click presses down on the liquid of the glass it lands on (the panel, its popups, KRunner): a dimple under the pointer while the button is held, dragged through the liquid with it, rings as it's pressed and let go. 0: clicks don't stir it." }
            Tuner {
                Kirigami.FormData.label: "Click width:"
                key: "Ripple/clickWidth"; fallback: 24; from: 4; to: 80; stepSize: 1; unit: "px"
            }
            Hint { text: "How wide the press is. Under Liquid Glass Light's heavier frost, narrow ones blur away." }

            Kirigami.Separator {
                Kirigami.FormData.isSection: true
                Kirigami.FormData.label: "Shore and floor"
            }
            Tuner {
                Kirigami.FormData.label: "Shore bends:"
                key: "Ripple/shore"; fallback: 8; from: 0; to: 30; stepSize: 1; unit: "px"
            }
            Hint { text: "How far the liquid's edge wanders, a little in from the rim, so the waves it sends off and sends back aren't straight. 0 follows the rim." }
            Tuner {
                Kirigami.FormData.label: "Shore bend length:"
                key: "Ripple/shoreScale"; fallback: 120; from: 30; to: 400; stepSize: 5; unit: "px"
            }
            Tuner {
                Kirigami.FormData.label: "Uneven floor:"
                key: "Ripple/floor"; fallback: 0.35; from: 0; to: 0.8; stepSize: 0.05; percent: true
            }
            Hint { text: "How much deeper and shallower the liquid gets. Waves run faster where it's deeper, so their fronts bend as they cross. 0 is a flat floor." }
            Tuner {
                Kirigami.FormData.label: "Floor swell length:"
                key: "Ripple/floorScale"; fallback: 220; from: 50; to: 800; stepSize: 10; unit: "px"
            }

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

            Kirigami.Separator {
                Kirigami.FormData.isSection: true
                Kirigami.FormData.label: "Liquid Glass Light"
            }
            Hint { text: "The waves go beneath the frost here: what's behind bends under them, and an etched diffraction foil lights up in shards of colour where they crest; then the frost softens it all." }
            Tuner {
                Kirigami.FormData.label: "Frost:"
                key: "Light/frost"; fallback: 5; from: 1; to: 15; stepSize: 1
            }
            Hint { text: "Blur strength over the waves, as in KWin's Blur settings; never more than yours there." }
            Tuner {
                Kirigami.FormData.label: "Refraction:"
                key: "Light/refraction"; fallback: 16; from: 0; to: 40; stepSize: 0.5; decimals: 1; unit: "px"
            }
            Hint { text: "How far what's behind bends beneath the frost, where a wave leans fully." }
            Tuner {
                Kirigami.FormData.label: "Diffraction:"
                key: "Light/diffraction"; fallback: 1.2; from: 0; to: 3; stepSize: 0.05; decimals: 2
            }
            Hint { text: "How bright the foil's colours are where the waves crest." }
            Tuner {
                Kirigami.FormData.label: "Etch size:"
                key: "Light/etch"; fallback: 32; from: 4; to: 120; stepSize: 1; unit: "px"
            }
            Hint { text: "The size of the foil's shards of colour. Under heavier frost they need to be bigger to show apart." }
            Tuner {
                Kirigami.FormData.label: "Saturation:"
                key: "Light/saturation"; fallback: 0.8; from: 0; to: 1; stepSize: 0.05; decimals: 2
            }
            Tuner {
                Kirigami.FormData.label: "Bevel width:"
                key: "Light/bevelWidth"; fallback: 24; from: 4; to: 60; stepSize: 1; unit: "px"
            }
            Tuner {
                Kirigami.FormData.label: "Bevel refraction:"
                key: "Light/bevelRefraction"; fallback: 0; from: 0; to: 30; stepSize: 0.5; decimals: 1; unit: "px"
            }
            Tuner {
                Kirigami.FormData.label: "Bevel colour split:"
                key: "Light/bevelDispersion"; fallback: 0; from: 0; to: 8; stepSize: 0.5; decimals: 1; unit: "px"
            }
            Tuner {
                Kirigami.FormData.label: "Bevel sharpness:"
                key: "Light/bevelSharpness"; fallback: 0; from: 0; to: 1; stepSize: 0.05; decimals: 2
            }
            Hint { text: "Liquid Glass Light is flat by default; give it a bevel like the dark glass's here." }

            Kirigami.Separator {
                Kirigami.FormData.isSection: true
                Kirigami.FormData.label: "Liquid Glass Dark Frost"
            }
            Hint { text: "Liquid Glass Light's glass in the dark: the same frost, with the waves and the foil beneath it, under a dark tint." }
            Tuner {
                Kirigami.FormData.label: "Frost:"
                key: "DarkFrost/frost"; fallback: 5; from: 1; to: 15; stepSize: 1
            }
            Hint { text: "Blur strength over the waves, as in KWin's Blur settings; never more than yours there." }
            Tuner {
                Kirigami.FormData.label: "Refraction:"
                key: "DarkFrost/refraction"; fallback: 16; from: 0; to: 40; stepSize: 0.5; decimals: 1; unit: "px"
            }
            Tuner {
                Kirigami.FormData.label: "Diffraction:"
                key: "DarkFrost/diffraction"; fallback: 1.2; from: 0; to: 3; stepSize: 0.05; decimals: 2
            }
            Tuner {
                Kirigami.FormData.label: "Etch size:"
                key: "DarkFrost/etch"; fallback: 32; from: 4; to: 120; stepSize: 1; unit: "px"
            }
            Tuner {
                Kirigami.FormData.label: "Saturation:"
                key: "DarkFrost/saturation"; fallback: 1; from: 0; to: 1; stepSize: 0.05; decimals: 2
            }
            Hint { text: "Fully saturated by default: against the dark, Light's 80% comes out a little paler and greyer." }
            Tuner {
                Kirigami.FormData.label: "Bevel width:"
                key: "DarkFrost/bevelWidth"; fallback: 24; from: 4; to: 60; stepSize: 1; unit: "px"
            }
            Tuner {
                Kirigami.FormData.label: "Bevel refraction:"
                key: "DarkFrost/bevelRefraction"; fallback: 0; from: 0; to: 30; stepSize: 0.5; decimals: 1; unit: "px"
            }
            Tuner {
                Kirigami.FormData.label: "Bevel colour split:"
                key: "DarkFrost/bevelDispersion"; fallback: 0; from: 0; to: 8; stepSize: 0.5; decimals: 1; unit: "px"
            }
            Tuner {
                Kirigami.FormData.label: "Bevel sharpness:"
                key: "DarkFrost/bevelSharpness"; fallback: 0; from: 0; to: 1; stepSize: 0.05; decimals: 2
            }
            Hint { text: "Flat by default too, as Light is." }
        }
    }
}
