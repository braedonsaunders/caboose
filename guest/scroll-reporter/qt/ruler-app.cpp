// The Qt scroll reporter check's application (check.py qt6-scroll-reports): a ListView whose
// every 16 px band shows its index down the left edge in 16 black or white 8 px blocks, the
// ruler guest/display/probe/src/scroll.rs reads back.
#include <QtGui/QGuiApplication>
#include <QtQml/QQmlApplicationEngine>

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    QQmlApplicationEngine engine;
    engine.loadData(R"(
        import QtQuick
        Window {
            width: 900; height: 800; visible: true; title: "ruler"; color: "#808080"
            ListView {
                anchors.fill: parent
                model: 750
                delegate: Item {
                    required property int index
                    width: ListView.view.width; height: 16
                    Row {
                        x: 8
                        Repeater {
                            model: 16
                            Rectangle {
                                required property int index
                                width: 8; height: 16
                                color: ((parent.parent.index >> (15 - index)) & 1) ? "white" : "black"
                            }
                        }
                    }
                }
            }
        })");
    return engine.rootObjects().isEmpty() ? 1 : app.exec();
}
