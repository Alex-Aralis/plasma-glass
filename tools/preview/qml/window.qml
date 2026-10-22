import QtQuick
import QtQuick.Window
// An ordinary window for the preview (panel.sh maximizes it, so a floating panel docks)
// usage: qml6 window.qml [-- COLOR]
Window {
    id: window
    readonly property var args: Qt.application.arguments.slice(Qt.application.arguments.indexOf("--") + 1)
    visible: true
    width: 760
    height: 460
    title: "Preview window"
    color: args.length > 0 && Qt.application.arguments.indexOf("--") >= 0 ? args[0] : "#2a2e32"
    Text {
        anchors.centerIn: parent
        text: "Preview window"
        color: window.color.hslLightness < 0.5 ? "#fcfcfc" : "#232629"
        font.pixelSize: 28
    }
}
