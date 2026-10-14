import QtQuick
import QtQuick.Window
// usage: qml6 wallpaper.qml -- /path/to/image [px/s]
// With a speed, the image scrolls up and down behind the windows at it (content moving behind the glass).
Window {
    id: window
    visible: true
    visibility: Window.FullScreen
    color: "black"
    readonly property var args: Qt.application.arguments.slice(Qt.application.arguments.indexOf("--") + 1)
    readonly property real pan: args.length > 1 ? Number(args[1]) : 0
    property real scrolled: 0 // px
    property real direction: 1
    // stepped each frame, not animated from/to: those would be fixed before the window has its size
    FrameAnimation {
        running: window.pan > 0
        onTriggered: {
            const travel = picture.height - window.height;
            window.scrolled += window.direction * window.pan * frameTime;
            if (window.scrolled >= travel) {
                window.scrolled = travel;
                window.direction = -1;
            } else if (window.scrolled <= 0) {
                window.scrolled = 0;
                window.direction = 1;
            }
        }
    }
    Image {
        id: picture
        y: -window.scrolled
        width: parent.width
        height: window.pan > 0 ? parent.height * 1.5 : parent.height
        fillMode: Image.PreserveAspectCrop
        source: "file://" + window.args[0]
    }
}
