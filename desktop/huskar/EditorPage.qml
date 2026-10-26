import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HuskarUI.Basic

ColumnLayout {
    id:page
    required property var store
    property var projectile:store.rows.find(x=>x.projectile_source) || null
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
        visible:!!page.projectile
        Layout.fillWidth:true
        ColumnLayout {
            Layout.fillWidth:true
            HusText { Layout.fillWidth:true;wrapMode:Text.Wrap;text:page.projectile ? (page.projectile.projectile_conflict ? "射弹引用不一致，请重新选择射弹或恢复原配" : "当前发射：#"+page.projectile.value+" · "+page.projectile.choice_name) : "" }
            HusText { Layout.fillWidth:true;wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary;text:page.projectile && page.projectile.value!==page.projectile.original ? "本页伤害等参数仍属于原配射弹。特效资源包只加载资源，不会改变发射类型。" : "特效资源包只加载资源；更换发射类型请使用「更换射弹」。" }
        }
        HusButton { objectName:"restore_projectile";visible:!!page.projectile && (page.projectile.changed || page.projectile.projectile_conflict);text:"恢复原配射弹";onClicked:store.call("reset",[page.projectile.id],()=>store.refreshRows()) }
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
