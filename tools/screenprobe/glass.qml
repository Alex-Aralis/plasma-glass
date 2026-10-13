// Glass probe: an empty window with the current Plasma Style's dialog background, which KWin blurs
// (PlasmaCore.Window draws it and sets the blur region; unlike PlasmaCore.Dialog it doesn't move
// itself, so a KWin script can place it). Never takes focus.
//   qml6 glass.qml -- CAPTION
import QtQuick
import org.kde.plasma.core as PlasmaCore
PlasmaCore.Window {
    title: Qt.application.arguments[Qt.application.arguments.indexOf("--") + 1]
    flags: Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus
    visible: true
    mainItem: Item { width: 500; height: 240 }
}
