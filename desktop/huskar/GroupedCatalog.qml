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
    property real qaBeforeHeight:0
    property real qaBeforeY:0
    property var rows:{let out=[];for(let i=0;i<groups.length;i+=columns)out.push(groups.slice(i,i+columns));return out}
    clip:true
    spacing:14
    model:rows
    boundsBehavior:Flickable.StopAtBounds
    ScrollBar.vertical:HusScrollBar{}
    SmoothWheel{}
    onGroupsChanged:if(picker)picker.close()
    onWidthChanged:if(picker)picker.close()
    function qaOpen(){for(const item of contentItem.children)if(item.objectName==="catalogGroupRow" && item.qaOpen())return true;return false}
    function qaPopupStable(){return picker.opened && Math.abs(picker.width-selectedCardWidth)<1 && Math.abs(contentHeight-qaBeforeHeight)<1 && Math.abs(contentY-qaBeforeY)<1 && qaAligned()}
    function qaClose(){picker.close()}
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
        function qaOpen(){
            for(let i=0;i<cardRepeater.count;i++){
                const card=cardRepeater.itemAt(i)
                if(card && card.modelData.entries.length>1){list.qaBeforeHeight=list.contentHeight;list.qaBeforeY=list.contentY;list.openGroup(card,card.modelData);return true}
            }
            return false
        }
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
                    property bool opened:picker.opened && list.selectedGroup && list.selectedGroup.id===modelData.id
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
                            HusText {Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;text:card.modelData.entries.length>1?card.modelData.entries.length+" 个关联条目"+(card.modelData.changed?" · 已修改":""):card.modelData.changed?"已修改":"原版参数";color:HusTheme.Primary.colorTextSecondary}
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
                                    if(card.opened){picker.close();return}
                                    list.openGroup(card,card.modelData)
                                }
                            }
                        }

                    }
                }
            }
        }
    }
    property var selectedGroup:null
    property real selectedCardWidth:0
    function openGroup(card,group){
        selectedGroup=group
        selectedCardWidth=card.width
        const point=card.mapToItem(picker.parent,0,card.height+8)
        picker.x=Math.max(16,Math.min(point.x,picker.parent.width-picker.width-16))
        picker.y=point.y+picker.height<picker.parent.height-16?point.y:Math.max(16,point.y-card.height-picker.height-16)
        picker.open()
    }
    HusPopup {
        id:picker
        parent:Overlay.overlay
        padding:18
        focus:true
        modal:false
        closePolicy:Popup.CloseOnEscape | Popup.CloseOnPressOutside
        width:Math.min(list.selectedCardWidth || list.cardWidth,parent?parent.width-32:list.cardWidth)
        height:Math.min(links.implicitHeight+heading.implicitHeight+54,parent?parent.height*0.7:500)
        contentItem:ColumnLayout {
            spacing:14
            RowLayout {
                id:heading;Layout.fillWidth:true
                HusText { Layout.fillWidth:true;Layout.minimumWidth:0;text:(list.selectedGroup?list.selectedGroup.name:"")+" · 关联条目";font.bold:true;wrapMode:Text.Wrap }
                HusButton { text:"关闭";onClicked:picker.close() }
            }
            Flickable {
                Layout.fillWidth:true;Layout.fillHeight:true
                contentHeight:links.implicitHeight
                clip:true
                ScrollBar.vertical:HusScrollBar{}
                SmoothWheel{}
                ColumnLayout {
                    id:links;width:parent.width;spacing:10
                    Repeater {
                        model:list.selectedGroup?list.selectedGroup.entries:[]
                        delegate:HusButton {
                            id:entryButton
                            required property var modelData
                            objectName:"group_item_"+modelData.id
                            Layout.fillWidth:true;Layout.minimumWidth:0
                            text:CatalogGroups.entryLabel(list.selectedGroup,modelData)+(modelData.changed?" · 已修改":"")
                            contentItem:HusText { text:entryButton.text;font:entryButton.font;wrapMode:Text.Wrap;horizontalAlignment:Text.AlignHCenter;verticalAlignment:Text.AlignVCenter;color:entryButton.colorText }
                            onClicked:{picker.close();list.store.select(modelData)}
                        }
                    }
                }
            }
        }
    }
}
