import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HuskarUI.Basic

ColumnLayout {
    id:page
    required property var store
    signal editValues(var passive)
    spacing:20
    RowLayout {
        Layout.fillWidth:true
        ColumnLayout {
            Layout.fillWidth:true
            HusText { text:"护甲组合";font.pixelSize:30;font.bold:true }
            HusText { text:"配置叠加效果，数值修改在独立弹窗中完成。";color:HusTheme.Primary.colorTextSecondary }
        }
        HusButton { text:"护甲类型参数";onClicked:{store.tab="ArmorWeight";const list=store.catalogs.ArmorWeight || [];if(list.length)store.select(list[0])} }
    }
    MaterialCard {
            store:page.store
        Layout.fillWidth:true
        title:"应用范围与叠加策略"
        bodyDelegate:RowLayout {
            width:parent.width
            implicitHeight:92
            spacing:22
            HusSelect {
                Layout.fillWidth:true;Layout.margins:18
                model:[{label:"所有护甲",value:999}].concat(store.armor.map(x=>({label:x.zh || x.name,value:x.id})))
                textRole:"label";valueRole:"value";defaultPopupMaxHeight:330;clearEnabled:false
                onActivated:{store.armorTarget=currentValue;store.refreshArmor()}
            }
            HusCheckBox { text:"保留原生被动";checked:store.armorProfile.own!==false;onClicked:store.armorChange(null,null,checked,null) }
            HusSelect {
                Layout.rightMargin:18
                model:[{label:"同类效果叠加",value:"stack"},{label:"同类保留最强",value:"strongest"}]
                textRole:"label";valueRole:"value";clearEnabled:false
                currentIndex:store.armorProfile.conflicts==="strongest"?1:0
                onActivated:store.armorChange(null,null,null,currentValue)
            }
        }
    }
    RowLayout {
        Layout.fillWidth:true
        HusText { text:"选择被动";font.pixelSize:20;font.bold:true;Layout.fillWidth:true }
        HusButton { text:"全选";onClicked:{for(let p of store.armor)store.armorChange(p.id,true,null,null)} }
        HusButton { text:"清空";onClicked:{for(let p of store.armor)store.armorChange(p.id,false,null,null)} }
    }
    GridView {
        id:grid
        Layout.fillWidth:true;Layout.fillHeight:true;clip:true
        model:store.armor
        cellWidth:width/Math.max(2,Math.min(4,Math.floor(width/250)))
        cellHeight:128
        ScrollBar.vertical:HusScrollBar{}
        SmoothWheel { }
        delegate:MaterialCard {
            store:page.store
            required property var modelData
            width:grid.cellWidth-12;height:114
            titleDelegate:Item{}
            bodyDelegate:ColumnLayout {
                width:parent.width
                implicitHeight:112
                RowLayout {
                    Layout.fillWidth:true;Layout.margins:14
                    HusCheckBox { text:modelData.zh || modelData.name;checked:!!(store.armorProfile.enabled || {})[String(modelData.id)];onClicked:store.armorChange(modelData.id,checked,null,null) }
                }
                RowLayout {
                    Layout.fillWidth:true;Layout.leftMargin:14;Layout.rightMargin:14;Layout.bottomMargin:12
                    HusText { text:"#"+modelData.id;color:HusTheme.Primary.colorTextSecondary;Layout.fillWidth:true }
                    HusButton { text:"修改数值";type:HusButton.Type_Link;onClicked:page.editValues(modelData) }
                }
            }
        }
    }
}
