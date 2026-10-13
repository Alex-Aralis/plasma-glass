// Frame rate probe: small animated windows that never take focus. Each logs, after a 3 s warm-up
// (screen.sh moves them in the meantime), the mean interval between presented frames and the speed
// of a 1 s looping animation against wall time (1.00 = right).
//   qml6 fps.qml -- CAPTION [COUNT]    windows CAPTION-1 .. CAPTION-COUNT (default 1), 6 s, then quits
import QtQuick
Item {
    id: root
    readonly property var args: Qt.application.arguments.slice(Qt.application.arguments.indexOf("--") + 1)

    component Probe: Window {
        id: win
        flags: Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus
        width: 200; height: 200; visible: true; color: "#bebebe"

        readonly property real startTime: Date.now()
        property real last: 0
        property var gaps: []
        property real p: 0             // 0..1 once a second
        property real prevP: 0
        property real progress: -1     // seconds of animation seen since the warm-up
        property real wallStart: 0
        property real wallEnd: 0
        NumberAnimation on p { from: 0; to: 1; duration: 1000; loops: Animation.Infinite }

        Rectangle {
            width: 40; height: 40; color: "#335"
            NumberAnimation on x { from: 0; to: 160; duration: 1000; loops: Animation.Infinite }
        }
        onFrameSwapped: {
            const now = Date.now();
            if (now - startTime < 3000) { last = now; return; }
            if (progress < 0) { progress = 0; wallStart = now; prevP = p; last = now; return; }
            gaps.push(now - last);
            last = now;
            progress += p >= prevP ? p - prevP : 1 - prevP + p;
            prevP = p;
            wallEnd = now;
        }
        function report() {
            const g = gaps.slice().sort((a, b) => a - b);
            const mean = g.reduce((a, b) => a + b, 0) / g.length;
            console.info("FPS", title, "on", screen.name, ":", (1000 / mean).toFixed(1), "fps, median",
                         g[Math.floor(g.length / 2)], "ms, p95", g[Math.floor(g.length * 0.95)], "ms, speed",
                         (progress * 1000 / (wallEnd - wallStart)).toFixed(2));
        }
    }

    Instantiator {
        id: windows
        model: Number(root.args[1] || 1)
        delegate: Probe { title: root.args[0] + "-" + (index + 1) }
    }
    Timer {
        interval: 6000; running: true
        onTriggered: { for (let i = 0; i < windows.count; ++i) windows.objectAt(i).report(); Qt.quit(); }
    }
}
