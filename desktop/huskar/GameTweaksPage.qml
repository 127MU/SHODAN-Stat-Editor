import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HuskarUI.Basic

Flickable {
    id:page
    required property var store
    contentHeight:body.implicitHeight;clip:true
    boundsBehavior:Flickable.StopAtBounds
    ScrollBar.vertical:HusScrollBar{}
    SmoothWheel { }
    ColumnLayout {
        id:body;width:page.width-18;spacing:18
        HusText { text:"游戏参数";font.pixelSize:30;font.bold:true }
        HusText { Layout.fillWidth:true;text:"调整后点击「写入游戏」生效。";wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
        Repeater {
            model:[{key:"reticle",text:"狙击步枪第三人称准星",group:"瞄准显示"},{key:"bounce",text:"战略球更易附着表面",group:"投掷行为",note:"解除部分战备仅能在导航网格上部署的限制。岩石、高台、陡坡和物体碰撞仍可能使战略球弹开，不保证任意表面黏附。写入后需重新启动游戏。"},{key:"foliage",text:"射弹穿过树冠与灌木",group:"射弹交互"}]
            MaterialCard {
            store:page.store
                required property var modelData
                Layout.fillWidth:true;title:modelData.group
                bodyDelegate:RowLayout {
                    width:parent.width;spacing:16
                    ColumnLayout {
                        Layout.fillWidth:true;Layout.margins:18;spacing:8
                        HusText { Layout.fillWidth:true;text:modelData.text;wrapMode:Text.Wrap }
                        HusText { Layout.fillWidth:true;visible:!!modelData.note;text:modelData.note || "";wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
                    }
                    HusSwitch { Layout.margins:18;checked:!!page.store.tweaks[modelData.key];onClicked:page.store.call("tweaks",[modelData.key,checked],d=>page.store.tweaks=d) }
                }
            }
        }
    }
}
