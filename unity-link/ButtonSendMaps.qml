import AlgWidgets.Style 1.0
import QtQuick 2.7
import QtQuick.Controls 1.4
import QtQuick.Controls.Styles 1.4

Button {
  id: root
  height: 30
  width: 70
  tooltip: "Send all materials to Unity"

  style: ButtonStyle {
    background: Rectangle {
        color: (root.enabled && hovered)? AlgStyle.background.color.gray : "#141414"
    }
    label: Item {
      Image {
        height: parent.height
        antialiasing: true
        fillMode:Image.PreserveAspectFit
        source: "icons/unity_logo.png"
        opacity: root.enabled? (hovered? 0.9 : 0.7) : 0.4
      }
    }
  }
}
