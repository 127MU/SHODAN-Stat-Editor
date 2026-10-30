import QtQuick
import QtQuick.Layouts
import HuskarUI.Basic

ColumnLayout {
    id: field
    required property var row
    required property var store
    property bool armor:false
    property int passiveId:0
    property string saved:armor || row.flag?String(row.value):String(row.text ?? "")
    property string error:""
    signal choose(var row)
    signal shared(var row)
    spacing:8
    function commit(text){
        if(text===saved)return
        const done=function(){if(field){field.saved=text;field.error=""}}
        const failed=function(text){if(field)field.error=text}
        if(armor)store.call("armor_set",[passiveId,row.key,text],done,failed)
        else store.save(row,text,done,failed)
    }
    Connections {
        target:field.store
        function onRowUpdated(updated){if(!field.armor && updated.id===field.row.id){field.row=updated;field.saved=updated.flag?String(updated.value):String(updated.text)}}
        function onHistoryReplayed(){if(field.armor)field.store.call("armor_rows",[field.passiveId],function(rows){const updated=rows.find(r=>r.key===field.row.key);if(updated){field.row=updated;field.saved=String(updated.value)}})}
    }
    RowLayout {
        Layout.fillWidth:true
        HusText { text:row.label;Layout.fillWidth:true;wrapMode:Text.Wrap }
        HusText { visible:field.row.choice_kind!=="resomode";text:"基准 "+(field.armor?field.row.default:field.row.default_text);color:HusTheme.Primary.colorTextSecondary;font.pixelSize:12;Layout.maximumWidth:160;elide:Text.ElideRight;HoverHandler { id:originalHover } HusToolTip { visible:originalHover.hovered;text:field.armor?parent.text:(field.row.baseline_source || "恢复基准")+"："+field.row.default_text+"\n启动时文件："+(field.row.loaded_text || "未知")+"\n待写入值："+(field.row.text || "未知")+"\n启动时文件可能已被其他工具修改，不作为游戏原版值。" } }
        HusIconButton {
            iconSource:HusIcon.QuestionCircleOutlined
            type:HusButton.Type_Text
            visible:(row.help || []).length>0
            HusToolTip { visible:parent.hovered;delay:300;text:(row.help || []).join("\n");width:Math.min(420,implicitWidth) }
        }
    }
    RowLayout {
        Layout.fillWidth:true
        HusInput {
            id:input
            objectName:"field_"+(field.armor?field.row.key:field.row.id)
            Layout.fillWidth:true
            text:field.saved
            visible:!field.row.flag && !field.row.choice && !field.row.code
            selectByMouse:true
            onEditingFinished:field.commit(text)
        }
        HusButton {
            Layout.fillWidth:true
            visible:!!field.row.choice || !!field.row.code
            text:field.row.code?String(field.row.text)+" · 录入指令":(field.row.choice_name || "选择条目")+(field.row.reference?"":" · #"+field.row.value)
            onClicked:field.choose(field.row)
        }
        HusSwitch {
            objectName:"toggle_"+field.row.id
            visible:!!field.row.flag
            checked:Number(field.row.value)>=0.5
            checkedText:"开";uncheckedText:"关"
            onClicked:field.commit(checked?"1":"0")
        }
        HusButton {
            objectName:"reset_"+field.row.id
            visible:field.row.choice_kind!=="resomode"
            text:"恢复";type:HusButton.Type_Text
            onClicked:{
                if(field.armor){store.call("armor_set",[field.passiveId,field.row.key,field.row.default],function(){field.saved=String(field.row.default);field.error=""})}
                else store.resetField(field.row)
            }
        }
    }
    RowLayout {
        visible:(field.row.shared || []).length>0
        Layout.fillWidth:true
        HusText { visible:!!field.row.changed;text:"已修改";color:HusTheme.Primary.colorPrimary;font.pixelSize:12 }
        Item { Layout.fillWidth:true }
        HusButton { visible:(field.row.shared || []).length>0;text:"共享影响 "+(field.row.shared || []).length+" 项";type:HusButton.Type_Link;onClicked:field.shared(field.row);HusToolTip { visible:parent.hovered;text:(field.row.shared || []).map(x=>x.name).join("\n") } }
    }
    HusText { visible:!field.armor && (field.row.shared || []).length>0;Layout.fillWidth:true;text:"同时影响："+(field.row.shared || []).slice(0,2).map(x=>x.name).join("、")+((field.row.shared || []).length>2?" 等":"");font.pixelSize:12;wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
    HusText { visible:!field.armor && field.row.loaded_text!==undefined;Layout.fillWidth:true;text:"启动文件："+(field.row.loaded_text || "未知")+"  ·  待写入："+(field.row.text || "未知");font.pixelSize:12;wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
    HusText { visible:!!field.row.inline_note;Layout.fillWidth:true;text:field.row.inline_note || "";wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
    HusText { visible:!!field.error;Layout.fillWidth:true;text:field.error;wrapMode:Text.Wrap;color:HusTheme.Primary.colorError }
}
