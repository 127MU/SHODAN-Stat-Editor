import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HuskarUI.Basic

ColumnLayout {
    id:page
    required property var store
    property var projectile:store.rows.find(x=>x.projectile_source) || null
    property var nameText:({available:false})
    property var descriptionText:({available:false})
    function loadGameText(){
        store.call("game_text",["name"],x=>page.nameText=x)
        store.call("game_text",["desc"],x=>page.descriptionText=x)
    }
    Connections { target:page.store;function onSelectionReady(){page.folded={};page.section="";page.query="";page.loadGameText()} }
    Component.onCompleted:{syncGroupModel();layoutReady=true;if(store.rows.length>0)loadGameText()}
    property string section:""
    property string query:""
    property bool changedOnly:false
    property string parameterLayout:Backend.setting("parameterLayout","classic")
    onParameterLayoutChanged:{if(layoutReady){rememberScroll();parameterDetail.close();Backend.saveSetting("parameterLayout",parameterLayout);restoreScroll.restart()}}
    property bool layoutReady:false
    property real savedScroll:0
    property string savedGroup:""
    property real savedOffset:0
    function rememberScroll(){
        savedScroll=parameterList.contentY;savedGroup="";savedOffset=0
        const card=parameterList.contentItem.children.find(c=>String(c.objectName).startsWith("parameterGroup_") && c.y+c.height>parameterList.contentY && c.y<=parameterList.contentY+parameterList.height)
        if(card){savedGroup=card.modelData.value;savedOffset=parameterList.contentY-card.y}
    }
    Timer {
        id:restoreScroll;interval:30
        onTriggered:{
            const index=page.groupModel.findIndex(g=>g.value===page.savedGroup)
            if(index>=0)parameterList.positionViewAtIndex(index,ListView.Beginning)
            Qt.callLater(function(){
                if(page.dialogView && parameterDetail.visible)page.dialogView.contentY=Math.max(0,Math.min(page.dialogScroll,page.dialogView.contentHeight-page.dialogView.height))
                const card=parameterList.contentItem.children.find(c=>String(c.objectName).startsWith("parameterGroup_") && c.modelData.value===page.savedGroup)
                const target=card?card.y+page.savedOffset:page.savedScroll
                const origin=parameterList.originY
                parameterList.contentY=Math.max(origin,Math.min(target,Math.max(origin,origin+parameterList.contentHeight-parameterList.height)))
            })
        }
    }
    Connections { target:page.store;function onRowsRefreshing(){page.rememberScroll();if(page.dialogView)page.dialogScroll=page.dialogView.contentY} function onRowsRefreshed(){restoreScroll.restart()} }
    property var filtered:{const revision=changedOnly?store.rowRevision:0;return store.rows.filter(x=>(!section || x.section===section) && (!changedOnly || x.changed) && (!query || (x.label+" "+(x.inline_note || "")).toLowerCase().indexOf(query.toLowerCase())>=0))}
    property var folded:({})
    property var groupModel:[]
    function syncGroupModel(){
        if(!sections || !filtered)return
        const next=sections.slice(1).filter(s=>filtered.some(r=>r.section===s.value)).concat(filtered.some(r=>!r.section)?[{label:"通用",value:""}]:[])
        const previous=groupModel || []
        if(next.length!==previous.length || next.some((g,i)=>g.value!==previous[i].value || g.label!==previous[i].label))groupModel=next
    }
    onFilteredChanged:syncGroupModel()
    onSectionsChanged:syncGroupModel()
    function focusParameter(id){
        const row=store.rows.find(r=>r.id===id)
        if(!row)return false
        section=row.section || "";query="";changedOnly=false;folded={}
        parameterList.positionViewAtBeginning()
        return true
    }
    property var qaGroup:null
    property real qaExpandedHeight:0
    property real qaScrollBefore:0
    function qaFold(action){
        function cards(){return parameterList.contentItem.children.filter(c=>String(c.objectName).startsWith("parameterGroup_"))}
        if(action==="openStatus"){
            const row=store.rows.find(r=>r.choice_kind==="status")
            const group=row && groupModel.find(g=>g.value===row.section)
            if(!group)return false
            openGroup(group);return true
        }
        if(action==="statusCheck")return parameterDetail.visible && dialogRows.filter(r=>r.choice_kind==="status").length===4 && dialogRows.filter(r=>!r.choice && typeof r.value==="number").length===4
        if(action==="statusEnd"){
            if(!dialogView)return false
            dialogView.contentY=Math.max(0,dialogView.contentHeight-dialogView.height);return true
        }
        if(action==="single"){
            qaGroup=cards().find(c=>c.expanded && c.height>120)
            if(!qaGroup)return false
            qaExpandedHeight=qaGroup.height
            return Backend.qaCheck("foldGroup_"+qaGroup.modelData.value,true)
        }
        if(action==="singleCheck")return qaGroup && !qaGroup.expanded && qaGroup.height<90 && qaGroup.height<qaExpandedHeight-50
        if(action==="all")return Backend.qaCheck("foldAllParameters",true)
        if(action==="allCheck")return cards().length>0 && cards().every(c=>!c.expanded && c.height<90)
        if(action==="expand")return Backend.qaCheck("expandAllParameters",true)
        if(action==="expandedCheck")return cards().some(c=>c.expanded && c.height>120)
        if(action==="classic"){parameterLayout="classic";return true}
        if(action==="cards"){parameterLayout="cards";return true}
        if(action==="scrollSnapshot"){
            parameterList.positionViewAtEnd();qaScrollBefore=parameterList.contentY
            return qaScrollBefore>50
        }
        if(action==="scrollCheck")return parameterList.contentY>50 && Math.abs(parameterList.contentY-qaScrollBefore)<30
        if(action==="openCategory"){
            const group=groupModel[0];if(!group)return false
            return Backend.qaCheck("openParameterGroup_"+group.value,true)
        }
        if(action==="openMount"){
            const row=store.rows.find(r=>r.choice_kind==="mountside")
            const group=row && groupModel.find(g=>g.value===row.section)
            if(!group)return false
            openGroup(group);return true
        }
        if(action==="categoryCheck")return parameterDetail.visible && dialogRows.length>0
        if(action==="closeCategory"){parameterDetail.close();return true}
        if(action==="dialogScroll"){
            if(!dialogView)return false
            dialogView.contentY=Math.max(0,dialogView.contentHeight-dialogView.height);qaScrollBefore=dialogView.contentY
            return qaScrollBefore>20
        }
        if(action==="dialogScrollCheck")return dialogView && dialogView.contentY>20 && Math.abs(dialogView.contentY-qaScrollBefore)<30
        return false
    }
    property var sections: {
        let out=[{label:"全部",value:""}];let seen={}
        for(let r of store.rows)if(r.section&&!seen[r.section]){seen[r.section]=true;out.push({label:r.section,value:r.section})}
        return out
    }
    signal choose(var row)
    signal shared(var row)
    signal presetsRequested()
    signal diagnosticRequested(string mode)
    property var activeGroup:null
    property string groupQuery:""
    property var dialogView:null
    property real dialogScroll:0
    property var dialogRows:{const revision=changedOnly?store.rowRevision:0;return store.rows.filter(r=>activeGroup && (r.section || "")===activeGroup.value && (!changedOnly || r.changed) && (!groupQuery || r.label.toLowerCase().includes(groupQuery.toLowerCase())))}
    function openGroup(group){activeGroup=group;groupQuery=page.query;dialogScroll=0;parameterDetail.open()}
    HusModal {
        id:parameterDetail;width:Math.min(1080,page.width-24);modal:true
        title:page.activeGroup?page.activeGroup.label+" · "+page.dialogRows.length+" 项参数":"参数分类"
        confirmText:"完成";cancelText:"关闭";onConfirm:close();onCancel:close()
        bodyDelegate:ColumnLayout {
            width:parameterDetail.width-48;spacing:14
            RowLayout {
                Layout.fillWidth:true
                HusText { Layout.fillWidth:true;text:"回车或离开输入框保存；可在此撤销本次编辑。";wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
                HusButton { objectName:"undoCategoryEdit";text:"撤销";enabled:store.editHistory.undo>0;onClicked:store.replayHistory(false) }
                HusButton { text:"重做";enabled:store.editHistory.redo>0;onClicked:store.replayHistory(true) }
            }
            HusInput { Layout.fillWidth:true;placeholderText:"在此分类中搜索参数";text:page.groupQuery;clearEnabled:true;onTextEdited:page.groupQuery=text }
            Flickable {
                id:dialogFields;objectName:"groupParameterScroll"
                Layout.fillWidth:true;Layout.preferredHeight:Math.min(520,page.height*0.58,Math.max(100,dialogGrid.implicitHeight))
                clip:true;contentHeight:dialogGrid.height;boundsBehavior:Flickable.StopAtBounds
                Component.onCompleted:page.dialogView=dialogFields
                ScrollBar.vertical:HusScrollBar{}
                SmoothWheel{}
                GridLayout {
                    id:dialogGrid;width:parent.width-16;columns:width>850?3:width>550?2:1;uniformCellWidths:true
                    columnSpacing:22;rowSpacing:18
                    Repeater {
                        model:parameterDetail.visible?page.dialogRows:[]
                        FieldEditor { required property var modelData;Layout.fillWidth:true;Layout.minimumWidth:0;Layout.margins:12;Layout.alignment:Qt.AlignTop;row:modelData;store:page.store;onChoose:row=>page.choose(row);onShared:row=>page.shared(row) }
                    }
                }
                HusEmpty { visible:page.dialogRows.length===0;anchors.centerIn:parent;description:"此分类中没有匹配参数" }
            }
        }
    }
    spacing:18
    RowLayout {
        Layout.fillWidth:true
        HusIconButton { iconSource:HusIcon.ArrowLeftOutlined;onClicked:{page.forceActiveFocus();store.screen="catalog"} }
        ColumnLayout {
            Layout.fillWidth:true
            HusText { text:store.current.name || "参数工作区";font.pixelSize:28;font.bold:true;wrapMode:Text.Wrap }
            HusText { text:"回车或离开输入框自动保存 · 写入游戏后生效";color:HusTheme.Primary.colorTextSecondary }
        }
    }
    Flow {
        Layout.fillWidth:true;spacing:8
        HusButton { text:"装备预设";onClicked:page.presetsRequested() }
        HusButton { text:"修改记录";onClicked:store.reviewHistory() }
        HusButton { objectName:"openReferenceChain";text:"射击引用链";onClicked:page.diagnosticRequested("chain") }
        HusButton { objectName:"openResourceDiagnostic";text:"资源诊断";onClicked:page.diagnosticRequested("resources") }
        HusButton { objectName:"undoEdit";text:"撤销";enabled:store.editHistory.undo>0;onClicked:store.replayHistory(false);HusToolTip{visible:parent.hovered;text:page.store.editHistory.undo_label || "本次启动尚无参数编辑"} }
        HusButton { objectName:"redoEdit";text:"重做";enabled:store.editHistory.redo>0;onClicked:store.replayHistory(true);HusToolTip{visible:parent.hovered;text:page.store.editHistory.redo_label || "没有可重做的编辑"} }
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
            currentIndex:Math.max(0,page.sections.findIndex(s=>s.value===page.section))
            onActivated:page.section=currentValue
        }
        HusInput { Layout.fillWidth:true;placeholderText:"在当前条目中查找参数";iconSource:HusIcon.SearchOutlined;clearEnabled:true;onTextEdited:page.query=text }
        HusCheckBox { text:"仅已修改";checked:page.changedOnly;onClicked:page.changedOnly=checked }
    }
    RowLayout {
        Layout.fillWidth:true
        HusText { Layout.fillWidth:true;text:{const revision=store.rowRevision;return page.filtered.length+" 项参数 · "+store.rows.filter(r=>r.changed).length+" 项已修改"} color:HusTheme.Primary.colorTextSecondary }
        HusSelect { objectName:"parameterLayoutSwitch";model:[{label:"旧版",value:"classic"},{label:"新版",value:"cards"}];textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:page.parameterLayout==="cards"?1:0;onActivated:page.parameterLayout=currentValue }
        HusButton { visible:page.parameterLayout==="classic";objectName:"expandAllParameters";text:"全部展开";type:HusButton.Type_Text;onClicked:page.folded={} }
        HusButton { visible:page.parameterLayout==="classic";objectName:"foldAllParameters";text:"全部收起";type:HusButton.Type_Text;onClicked:{const next={};for(const g of page.groupModel)next[g.value]=true;page.folded=next} }
    }
    GridView {
        id:categoryCards;objectName:"parameterCategories"
        visible:page.parameterLayout==="cards";Layout.fillWidth:true;Layout.fillHeight:true;clip:true
        model:page.groupModel
        cellWidth:width/Math.max(1,Math.min(4,Math.floor(width/240)))
        cellHeight:250
        ScrollBar.vertical:HusScrollBar{}
        SmoothWheel{}
        delegate:MaterialCard {
            id:categoryCard;required property var modelData
            store:page.store;width:categoryCards.cellWidth-16;height:categoryCards.cellHeight-16
            readonly property color accentColor:["#1677ff","#ff4d4f","#52c41a","#faad14"][Math.max(0,page.groupModel.findIndex(g=>g.value===modelData.value))%4]
            titleDelegate:Item { implicitHeight:0 }
            borderBg.color:HusThemeFunctions.alpha(accentColor,0.3)
            bodyDelegate:ColumnLayout {
                width:parent.width;spacing:12
                RowLayout {
                    Layout.fillWidth:true;Layout.margins:18
                    Rectangle { width:40;height:40;radius:20;color:HusThemeFunctions.alpha(categoryCard.accentColor,0.12);HusIconText { anchors.centerIn:parent;iconSource:HusIcon.EditOutlined;iconSize:21;colorIcon:categoryCard.accentColor } }
                    Item { Layout.fillWidth:true }
                }
                HusText { Layout.leftMargin:18;Layout.rightMargin:18;Layout.fillWidth:true;text:categoryCard.modelData.label;font.bold:true;font.pixelSize:20;wrapMode:Text.Wrap }
                HusText { Layout.leftMargin:18;Layout.rightMargin:18;Layout.fillWidth:true;text:page.filtered.filter(r=>(r.section || "")===categoryCard.modelData.value).length+" 项参数";color:HusTheme.Primary.colorTextSecondary }
                HusButton { objectName:"openParameterGroup_"+categoryCard.modelData.value;Layout.leftMargin:18;Layout.bottomMargin:18;text:"打开";onClicked:page.openGroup(categoryCard.modelData) }
            }
        }
        HusEmpty { visible:categoryCards.count===0;anchors.centerIn:parent;description:"没有匹配分类" }
    }
    ListView {
        id:parameterList
        visible:page.parameterLayout==="classic"
        objectName:"parameterScroll"
        Layout.fillWidth:true
        Layout.fillHeight:true
        model:page.parameterLayout==="classic"?page.groupModel:[]
        cacheBuffer:500
        spacing:16
        clip:true
        boundsBehavior:Flickable.StopAtBounds
        ScrollBar.vertical:HusScrollBar{}
        SmoothWheel { }
        header:Column {
            id:sectionColumn
            width:parameterList.width-16
            spacing:18
            HusCollapse {
                id:gameTextPanel
                objectName:"gameTextPanel"
                width:sectionColumn.width
                visible:page.nameText.available
                initModel:[{key:"text",title:"游戏内名称与说明（可选）"}]
                titleFont.pixelSize:18
                titleFont.weight:Font.DemiBold
                animationEnabled:page.store.cardMotion
                contentDelegate:Item {
                    implicitHeight:gameTextForm.implicitHeight+40
                    ColumnLayout {
                        id:gameTextForm
                        anchors.left:parent.left;anchors.right:parent.right;anchors.top:parent.top
                        anchors.margins:20
                        spacing:12
                        HusText { Layout.fillWidth:true;wrapMode:Text.Wrap;text:"只修改游戏中显示的文字，不影响伤害等参数。写入游戏后对所有语言生效。";color:HusTheme.Primary.colorTextSecondary }
                        HusText { text:"名称";font.bold:true }
                        RowLayout {
                            Layout.fillWidth:true;spacing:12
                            HusInput { Layout.fillWidth:true;placeholderText:"输入游戏内名称";text:page.nameText.value || "";onEditingFinished:page.store.call("game_text",["name",text],x=>page.nameText=x) }
                            HusButton { text:"恢复原名";type:HusButton.Type_Text;onClicked:page.store.call("game_text",["name",""],x=>page.nameText=x) }
                        }
                        HusText { text:"说明";font.bold:true }
                        RowLayout {
                            Layout.fillWidth:true;spacing:12
                            HusInput { Layout.fillWidth:true;placeholderText:"输入游戏内说明";text:page.descriptionText.value || "";onEditingFinished:page.store.call("game_text",["desc",text],x=>page.descriptionText=x) }
                            HusButton { text:"恢复原文";type:HusButton.Type_Text;onClicked:page.store.call("game_text",["desc",""],x=>page.descriptionText=x) }
                        }
                        HusText { Layout.fillWidth:true;wrapMode:Text.Wrap;text:"回车或离开输入框自动保存。名称最多 60 字节、说明最多 400 字节；中文通常每字占 3 字节。";font.pixelSize:13;color:HusTheme.Primary.colorTextSecondary }
                    }
                }
            }
        }
        delegate:MaterialCard {
            id:groupCard
            required property var modelData
            store:page.store
            width:parameterList.width-16
            height:implicitHeight
            objectName:"parameterGroup_"+modelData.value
            title:modelData.label
            property bool expanded:!page.folded[modelData.value]
            extraDelegate:HusButton {
                objectName:"foldGroup_"+groupCard.modelData.value
                text:groupCard.expanded?"收起":"展开"
                type:HusButton.Type_Text
                onClicked:{const next=Object.assign({},page.folded);next[groupCard.modelData.value]=groupCard.expanded;page.folded=next}
            }
            bodyDelegate:Item {
                id:groupBody
                width:parent.width
                implicitHeight:groupCard.expanded && fieldsLoader.item?fieldsLoader.item.implicitHeight:0
                height:implicitHeight
                clip:true
                property bool ready:false
                Component.onCompleted:Qt.callLater(function(){if(groupBody)groupBody.ready=true})
                Behavior on implicitHeight { enabled:groupBody.ready;NumberAnimation { duration:page.store.cardMotion?160:0;easing.type:Easing.OutCubic } }
                Loader {
                    id:fieldsLoader
                    width:parent.width
                    active:groupCard.expanded || groupBody.height>1
                    sourceComponent:GridLayout {
                    width:parent.width
                    columns:width>1080?3:width>650?2:1;uniformCellWidths:true
                    columnSpacing:20;rowSpacing:12
                    Repeater {
                        model:page.filtered.filter(x=>(x.section || "")===groupCard.modelData.value)
                        FieldEditor {
                            required property var modelData
                            Layout.fillWidth:true;Layout.minimumWidth:0;Layout.margins:16;Layout.alignment:Qt.AlignTop
                            row:modelData;store:page.store
                            onChoose:row=>page.choose(row)
                            onShared:row=>page.shared(row)
                        }
                    }
                }
                }
            }
        }
        HusEmpty { visible:page.filtered.length===0;description:page.changedOnly?"当前条目没有已修改参数":"没有匹配参数";anchors.centerIn:parent }
    }
}
