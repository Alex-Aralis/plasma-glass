import QtQuick
import org.kde.ksvg as KSvg
import org.kde.plasma.core as PlasmaCore
// usage: qml6 elements.qml -- IMAGEPATH id...   prints each element's rect as Plasma measures it
Item {
    readonly property var args: Qt.application.arguments.slice(Qt.application.arguments.indexOf("--") + 1)
    KSvg.Svg { id: svg; imagePath: args[0] }
    Component.onCompleted: {
        for (const id of args.slice(1)) {
            const r = svg.elementRect(id);
            console.info("ELEMENT " + id + " " + (svg.hasElement(id)
                ? r.x.toFixed(2) + "," + r.y.toFixed(2) + " " + r.width.toFixed(2) + "x" + r.height.toFixed(2) : "missing"));
        }
        Qt.quit();
    }
}
