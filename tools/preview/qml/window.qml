import QtQuick
import QtQuick.Window
// An ordinary window for the preview (panel.sh maximizes it, so a floating panel docks)
Window {
    visible: true
    width: 760
    height: 460
    title: "Preview window"
    color: "#2a2e32"
    Text {
        anchors.centerIn: parent
        text: "Preview window"
        color: "#fcfcfc"
        font.pixelSize: 28
    }
}
