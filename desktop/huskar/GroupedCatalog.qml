import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HuskarUI.Basic
import "CatalogGroups.js" as CatalogGroups

ListView {
    id: list
    objectName:"groupedCatalog"
    required property var store
    required property var groups
    property int columns:Math.min(store.catalogColumns,Math.max(1,Math.floor(width/230)))
    readonly property real cardWidth:Math.max(1,(width-(columns-1)*14)/columns)
    property var expanded:({})
    property var rows:{let out=[];for(let i=0;i<groups.length;i+=columns)out.push(groups.slice(i,i+columns));return out}
    clip:true
    spacing:14
    model:rows
    boundsBehavior:Flickable.StopAtBounds
    ScrollBar.vertical:HusScrollBar{}
    SmoothWheel{}
    function qaAligned(){
        let checked=0
        for(let item of contentItem.children){
            if(item.objectName!=="catalogGroupRow")continue
            if(!item.qaAligned())return false
            checked++
        }
        return checked>0
    }
    delegate:Item {
        objectName:"catalogGroupRow"
        required property var modelData
        width:list.width
        height:cards.implicitHeight
        function qaAligned(){
            for(let i=0;i<cardRepeater.count;i++){
                const card=cardRepeater.itemAt(i)
                if(!card || Math.abs(card.x-i*(list.cardWidth+14))>1 || Math.abs(card.width-list.cardWidth)>1 || Math.abs(card.y)>1 || card.x+card.width>list.width+1)return false
            }
            return true
        }
        Row {
            id:cards
            width:parent.width
            spacing:14
            Repeater {
                id:cardRepeater
                model:modelData
                delegate:MaterialCard {
                    id:card
                    required property var modelData
                    property bool opened:!!list.expanded[modelData.id] || list.store.search.trim().length>0
                    width:list.cardWidth
                    height:implicitHeight
                    store:list.store
                    title:modelData.name
                    titleFont.pixelSize:16
                    titleFont.bold:true
                    bodyDelegate:ColumnLayout {
                        width:parent.width
                        spacing:0
                        RowLayout {
                            Layout.fillWidth:true;Layout.margins:14
                            HusText {Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;text:card.modelData.entries.length>1?card.modelData.entries.length+" 个关联条目":card.modelData.changed?"已修改":"原版参数";color:HusTheme.Primary.colorTextSecondary}
                            HusButton {
                                text:card.modelData.entries.length>1?(card.opened?"收起":"展开"):"编辑"
                                contentItem:RowLayout {
                                    HusText {text:parent.parent.text;color:parent.parent.colorText}
                                    HusIconText {
                                        visible:card.modelData.entries.length>1
                                        iconSource:HusIcon.DownOutlined
                                        rotation:card.opened?180:0
                                        Behavior on rotation {NumberAnimation {duration:list.store.cardMotion?180:0;easing.type:Easing.OutCubic}}
                                    }
                                }
                                onClicked:{
                                    if(card.modelData.entries.length===1){list.store.select(card.modelData.entries[0]);return}
                                    let next=Object.assign({},list.expanded);next[card.modelData.id]=!card.opened;list.expanded=next
                                }
                            }
                        }
                        Item {
                            Layout.fillWidth:true
                            implicitHeight:card.opened && card.modelData.entries.length>1?childrenList.implicitHeight:0
                            clip:true
                            Behavior on implicitHeight {NumberAnimation {duration:list.store.cardMotion?180:0;easing.type:Easing.OutCubic}}
                            ColumnLayout {
                                id:childrenList
                                width:parent.width
                                spacing:6
                                Repeater {
                                    model:card.modelData.entries
                                    delegate:HusButton {
                                        required property var modelData
                                        objectName:"group_item_"+modelData.id
                                        Layout.fillWidth:true;Layout.leftMargin:12;Layout.rightMargin:12;Layout.bottomMargin:6
                                        text:CatalogGroups.entryLabel(card.modelData,modelData)+(modelData.changed?" · 已修改":"")
                                        onClicked:list.store.select(modelData)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
