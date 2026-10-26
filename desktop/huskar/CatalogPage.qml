import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HuskarUI.Basic
import "CatalogGroups.js" as CatalogGroups

ColumnLayout {
    id: page
    required property var store
    signal hiddenRequested()
    property var grouped:CatalogGroups.build(store.library,store.catalogs[store.tab] || [],store.tab)
    spacing:18
    RowLayout {
        Layout.fillWidth:true
        ColumnLayout {
            Layout.fillWidth:true
            HusText { text:store.destinations.find(x=>x.key===store.module)?.name || "资源库";font.pixelSize:30;font.bold:true }
            HusText { text:"浏览条目，选择后进入独立的参数工作区。";color:HusTheme.Primary.colorTextSecondary }
        }
        HusSelect { model:[{label:"三列",value:3},{label:"四列",value:4}];textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:store.catalogColumns===4?1:0;onActivated:store.setCatalogColumns(currentValue) }
        HusTag { text:store.library.length+" 个条目" }
    }
    RowLayout {
        Layout.fillWidth:true
        HusSegmented {
            visible:store.types.length>0
            options:store.types
            currentIndex:Math.max(0,store.types.findIndex(x=>x.value===store.tab))
            onCurrentValueChanged:Qt.callLater(function(){
                // HusSegmented rebuilds its internal model when categories
                // change. Wait until its index/value bindings have settled.
                if(Backend.ready && currentValue && store.types.some(x=>x.value===currentValue) && currentValue!==store.tab)store.setTab(currentValue)
            })
        }
        Item { Layout.fillWidth:true }
        HusCheckBox { objectName:"catalog_only_modified";text:"仅已修改";checked:store.catalogOnlyModified;onClicked:store.catalogOnlyModified=checked }
        HusInput {
            Layout.preferredWidth:Math.min(340,page.width*0.35)
            placeholderText:"搜索名称、型号或 ID"
            iconSource:HusIcon.SearchOutlined
            clearEnabled:true
            text:store.search
            onTextEdited:store.search=text
            onAccepted:if(text.toLowerCase()==="mu7" && !store.modsUnlocked)page.hiddenRequested()
        }
    }
    GroupedCatalog {
        Layout.fillWidth:true;Layout.fillHeight:true
        visible:page.grouped.length>0
        store:page.store;groups:page.grouped
    }
    GridView {
        id: library
        objectName:"catalogGrid"
        visible:page.grouped.length===0
        Layout.fillWidth:true
        Layout.fillHeight:true
        clip:true
        model:store.library
        cellWidth:width/Math.min(store.catalogColumns,Math.max(1,Math.floor(width/230)))
        cellHeight:162
        boundsBehavior:Flickable.StopAtBounds
        ScrollBar.vertical:HusScrollBar{}
        SmoothWheel { }
        delegate:MaterialCard {
            store:page.store
            required property var modelData
            width:library.cellWidth-14
            height:148
            hoverable:false
            showShadow:false
            title:modelData.name
            titleFont.pixelSize:16
            titleFont.bold:true
            bodyAvatarIcon:store.module==="vehicle"?HusIcon.CarOutlined:store.module==="enemy"?HusIcon.BugOutlined:store.module==="records"?HusIcon.DatabaseOutlined:HusIcon.AimOutlined
            bodyTitle:modelData.changed?"已修改":"游戏数据"
            bodyDescription:(modelData.note || "").split("\n")[0]
            bodyDelegate:RowLayout {
                implicitHeight:80
                width:parent.width
                HusIconText { Layout.leftMargin:16;iconSource:store.module==="vehicle"?HusIcon.CarOutlined:store.module==="enemy"?HusIcon.BugOutlined:HusIcon.AimOutlined;iconSize:28;colorIcon:HusTheme.Primary.colorPrimary }
                HusText { Layout.fillWidth:true;text:modelData.changed?"已修改":"原版参数";color:HusTheme.Primary.colorTextSecondary }
                HusButton { Layout.rightMargin:16;text:"编辑";type:HusButton.Type_Primary;onClicked:store.select(modelData) }
            }
        }
        HusEmpty { anchors.centerIn:parent;visible:library.count===0;description:"没有匹配条目" }
    }
}
