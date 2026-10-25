import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HuskarUI.Basic

ColumnLayout {
    id:page
    required property var store
    property string section:""
    property string query:""
    property bool changedOnly:false
    property var filtered:store.rows.filter(x=>(!section || x.section===section) && (!changedOnly || x.changed) && (!query || x.label.toLowerCase().indexOf(query.toLowerCase())>=0))
    property var sections: {
        let out=[{label:"全部",value:""}];let seen={}
        for(let r of store.rows)if(r.section&&!seen[r.section]){seen[r.section]=true;out.push({label:r.section,value:r.section})}
        return out
    }
    signal choose(var row)
    signal shared(var row)
    signal presetsRequested()
    spacing:18
    RowLayout {
        Layout.fillWidth:true
        HusIconButton { iconSource:HusIcon.ArrowLeftOutlined;onClicked:{page.forceActiveFocus();store.screen="catalog"} }
        ColumnLayout {
            Layout.fillWidth:true
            HusText { text:store.current.name || "参数工作区";font.pixelSize:28;font.bold:true;wrapMode:Text.Wrap }
            HusText { text:"回车或离开输入框自动保存 · 写入游戏后生效";color:HusTheme.Primary.colorTextSecondary }
        }
        HusButton { text:"装备预设";onClicked:page.presetsRequested() }
        HusButton { text:"恢复本项";onClicked:store.call("reset",[],()=>store.refreshRows()) }
    }
    RowLayout {
        Layout.fillWidth:true
        HusSelect {
            Layout.preferredWidth:230
            model:page.sections;textRole:"label";valueRole:"value";clearEnabled:false;defaultPopupMaxHeight:320
            onActivated:page.section=currentValue
        }
        HusInput { Layout.fillWidth:true;placeholderText:"在当前条目中查找参数";iconSource:HusIcon.SearchOutlined;clearEnabled:true;onTextEdited:page.query=text }
        HusCheckBox { text:"仅已修改";checked:page.changedOnly;onClicked:page.changedOnly=checked }
    }
    Flickable {
        objectName:"parameterScroll"
        Layout.fillWidth:true
        Layout.fillHeight:true
        contentHeight:sectionColumn.height
        clip:true
        boundsBehavior:Flickable.StopAtBounds
        ScrollBar.vertical:HusScrollBar{}
        SmoothWheel { }
        Column {
            id:sectionColumn
            width:parent.width-16
            spacing:18
            Repeater {
                model:page.sections.slice(1).filter(s=>page.filtered.some(r=>r.section===s.value)).concat(page.filtered.some(r=>!r.section)?[{label:"通用",value:""}]:[])
                MaterialCard {
            store:page.store
                    id:groupCard
                    required property var modelData
                    width:sectionColumn.width
                    title:modelData.label
                    showShadow:false
                    bodyDelegate:GridLayout {
                        property var groupRows:page.filtered.filter(x=>(x.section || "")===groupCard.modelData.value)
                        width:parent.width
                        columns:width>1000?3:width>630?2:1
                        columnSpacing:28
                        rowSpacing:22
                        Repeater {
                            model:parent.groupRows
                            FieldEditor {
                                required property var modelData
                                Layout.fillWidth:true
                                Layout.margins:16
                                Layout.alignment:Qt.AlignTop
                                row:modelData
                                store:page.store
                                onChoose:row=>page.choose(row)
                                onShared:row=>page.shared(row)
                            }
                        }
                    }
                }
            }
            HusEmpty { visible:page.filtered.length===0;description:"没有匹配参数";anchors.horizontalCenter:parent.horizontalCenter }
        }
    }
}
