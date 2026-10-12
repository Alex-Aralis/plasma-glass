import QtQuick
import QtQuick.Window
// usage: qml6 wallpaper.qml -- /path/to/image
Window {
    visible: true
    visibility: Window.FullScreen
    color: "black"
    Image {
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        source: "file://" + Qt.application.arguments[Qt.application.arguments.length - 1]
    }
}
