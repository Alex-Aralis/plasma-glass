import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.plasma.extras as PlasmaExtras
// A notification-like Plasma dialog: frame, padding, header buttons, text field, highlight, scrollbar.
PlasmaCore.Dialog {
    visible: true
    mainItem: ColumnLayout {
        width: Kirigami.Units.gridUnit * 20
        height: Kirigami.Units.gridUnit * 14
        RowLayout {
            Kirigami.Icon { source: "internet-chat"; Layout.preferredWidth: Kirigami.Units.iconSizes.small; Layout.preferredHeight: width }
            PC3.Label { text: "Preview"; Layout.fillWidth: true }
            PC3.ToolButton { icon.name: "configure" }
            PC3.ToolButton { icon.name: "window-close" }
        }
        PC3.TextField { Layout.fillWidth: true; text: "search field"; focus: true }
        Item {  // KRunner, Kickoff and other popups draw their current row with PlasmaExtras.Highlight
            Layout.fillWidth: true
            implicitHeight: row.implicitHeight + Kirigami.Units.largeSpacing * 2
            PlasmaExtras.Highlight { anchors.fill: parent; hovered: true }  // set automatically inside a ListView
            PC3.Label { id: row; x: Kirigami.Units.largeSpacing; anchors.verticalCenter: parent.verticalCenter; text: "Highlighted row" }
        }
        PC3.ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true
            PC3.Label {
                width: Kirigami.Units.gridUnit * 18
                wrapMode: Text.WordWrap
                text: "Body text long enough to need scrolling. ".repeat(20)
            }
        }
    }
}
