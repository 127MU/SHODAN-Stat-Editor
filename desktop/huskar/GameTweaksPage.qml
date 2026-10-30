import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HuskarUI.Basic

Flickable {
    id:page
    required property var store
    property bool ragdollOn:false
    property bool displayedRagdollChecked:false
    property bool checkingRagdoll:false
    property bool wantedRagdoll:false
    property string ragdollStatus:"版本核对后才能安装或恢复；不影响已编辑的数值。"
    function qa(action){
        if(action==="ready")return !checkingRagdoll
        if(action==="scroll"){contentY=Math.max(0,contentHeight-height);return true}
        if(action==="toggle")return Backend.qaCheck("enableRagdoll",true)
        if(action==="confirm")return ragdollConfirm.visible && !checkingRagdoll
        if(action==="cancel"){ragdollConfirm.close();return true}
        if(action==="state")return !ragdollConfirm.visible && displayedRagdollChecked===ragdollOn
        return false
    }
    Component.onCompleted:{
        checkingRagdoll=true
        store.call("ragdoll_preview",[],function(result){checkingRagdoll=false;ragdollOn=result.enabled;ragdollStatus=result.message},function(text){checkingRagdoll=false;ragdollStatus=text})
    }
    function previewRagdoll(on){
        checkingRagdoll=true;wantedRagdoll=on
        store.call("ragdoll_preview",[],function(result){checkingRagdoll=false;ragdollOn=result.enabled;ragdollStatus=result.message;ragdollConfirm.open()},function(text){checkingRagdoll=false;ragdollStatus=text})
    }
    HusModal {
        id:ragdollConfirm;width:560;modal:true;title:page.wantedRagdoll?"启用布娃娃优化（实验性）":"恢复布娃娃优化";confirmText:"确认";cancelText:"取消";onCancel:close()
        description:"此项会立即更改资源补丁，请先完全退出游戏。其他数值修改仍通过顶部「写入游戏」安装。"+page.ragdollStatus
        onConfirm:{close();page.checkingRagdoll=true;page.store.call("ragdoll_apply",[page.wantedRagdoll],function(text){page.checkingRagdoll=false;page.ragdollOn=page.wantedRagdoll;page.ragdollStatus=text;page.store.status=text},function(text){page.checkingRagdoll=false;page.ragdollStatus=text})}
    }
    contentHeight:body.implicitHeight;clip:true
    boundsBehavior:Flickable.StopAtBounds
    ScrollBar.vertical:HusScrollBar{}
    SmoothWheel { }
    ColumnLayout {
        id:body;width:page.width-18;spacing:18
        HusText { text:"游戏参数";font.pixelSize:30;font.bold:true }
        HusText { Layout.fillWidth:true;text:"调整后点击「写入游戏」生效。";wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
        Repeater {
            model:[{key:"reticle",text:"狙击步枪第三人称准星",group:"瞄准显示"},{key:"bounce",text:"策略球部署限制放宽",group:"投掷行为",note:"解除部分战备仅能在导航网格上部署的限制。岩石、高台、陡坡和物体碰撞仍可能使策略球弹开，不保证任意表面粘附。写入后需重新启动游戏。"},{key:"foliage",text:"射弹穿过树冠与灌木",group:"射弹交互"}]
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
        MaterialCard {
            store:page.store;Layout.fillWidth:true;title:"受击与布娃娃（实验性）"
            bodyDelegate:RowLayout {
                width:parent.width;spacing:16
                HusText { Layout.fillWidth:true;Layout.margins:18;text:page.checkingRagdoll?"正在核对资源与补丁，请稍候…":page.ragdollStatus;wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
                    HusSwitch {
                        Layout.margins:18
                        objectName:"enableRagdoll";checked:page.ragdollOn
                        onCheckedChanged:page.displayedRagdollChecked=checked
                        checkedText:"开";uncheckedText:"关";enabled:!page.checkingRagdoll
                        onClicked:{checked=Qt.binding(function(){return page.ragdollOn});page.previewRagdoll(!page.ragdollOn)}
                    }
            }
        }
    }
}
