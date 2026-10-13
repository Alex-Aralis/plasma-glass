// A flat grey window that never takes focus: a known background for the glass probe.
//   qml6 band.qml -- CAPTION GRAY
import QtQuick
Window {
    readonly property var args: Qt.application.arguments.slice(Qt.application.arguments.indexOf("--") + 1)
    title: args[0]
    flags: Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus
    width: 400; height: 200; visible: true
    color: Qt.rgba(args[1] / 255, args[1] / 255, args[1] / 255, 1)
}
