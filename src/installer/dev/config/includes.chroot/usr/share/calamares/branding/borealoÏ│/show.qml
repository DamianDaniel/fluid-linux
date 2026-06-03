import QtQuick 2.0
import calamares.slideshow 1.0

Presentation {
    id: presentation
    Slide {
        Image {
            id: background
            source: "logo.svg"
            fillMode: Image.PreserveAspectFit
            anchors.centerIn: parent
            width: 200
            height: 200
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: background.bottom
            anchors.topMargin: 20
            text: "Welcome to BorealOS"
            color: "#ffffff"
            font.pixelSize: 24
        }
    }
}
