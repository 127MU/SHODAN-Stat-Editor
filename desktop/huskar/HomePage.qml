// Adapted from HuskarUI Gallery HomePage.qml, copyright mengps, MIT license.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic
import QtQuick.Effects
import HuskarUI.Basic



Item {
    id: root
    clip:true
    required property var store
    property var workspaceModel: [
        {key:'editing',label:'数据编辑',iconSource:HusIcon.EditOutlined,menuChildren:store.destinations.map(d=>({key:d.key,label:d.name,desc:d.description,addVersion:'',updateVersion:''}))},
        {key:'plans',label:'配置方案',iconSource:HusIcon.FolderOpenOutlined,menuChildren:[{key:'presets',label:'全局预设',desc:'保存和复用整套参数修改',addVersion:'',updateVersion:''}]}
    ]

    property int sidePadding: Math.max(32, width * 0.06)
    property int contentMaxWidth: 1220
    property int contentWidth: Math.min(width - sidePadding * 2, contentMaxWidth)
    property int selectedCategoryIndex: 0
    property var accentPalette: [
        HusTheme.Primary.colorInfo,
        HusTheme.Primary.colorError,
        HusTheme.Primary.colorSuccess,
        HusTheme.Primary.colorWarning
    ]
    property var categoryOptions: buildCategoryOptions()
    property string currentCategoryKey: categoryOptions.length > 0
                                        ? categoryOptions[Math.min(selectedCategoryIndex, categoryOptions.length - 1)].value
                                        : 'all'
    property var componentItems: buildComponentItems()
    property var filteredComponentItems: buildFilteredComponentItems()
    property int componentCardWidth: 236
    property int componentCardMinWidth: 150
    property int componentCardHeight: 248
    property int componentGridSpacing: 24
    property int componentPreferredColumns: 4

    function currentMinorVersionPrefix() {
        const parts = `${Backend.version}`.split('.');
        if (parts.length < 2 || !parts[0] || !parts[1]) {
            return '';
        }
        return `${parts[0]}.${parts[1]}`;
    }

    function isCurrentMinorVersion(version) {
        const currentPrefix = currentMinorVersionPrefix();
        if (!currentPrefix || !version) {
            return false;
        }
        const versionParts = `${version}`.split('.');
        return versionParts.length >= 2
                && versionParts[0] === currentPrefix.split('.')[0]
                && versionParts[1] === currentPrefix.split('.')[1];
    }

    function compareComponentItems(a, b) {
        const priorityMap = {
            'new': 0,
            'update': 1,
            '': 2,
        };
        const leftVersionParts = `${a.version || ''}`.split('.').map(part => Number(part) || 0);
        const rightVersionParts = `${b.version || ''}`.split('.').map(part => Number(part) || 0);
        const maxLength = Math.max(leftVersionParts.length, rightVersionParts.length);
        for (let i = 0; i < maxLength; ++i) {
            const leftPart = i < leftVersionParts.length ? leftVersionParts[i] : 0;
            const rightPart = i < rightVersionParts.length ? rightVersionParts[i] : 0;
            if (leftPart !== rightPart) {
                return rightPart - leftPart;
            }
        }
        const leftPriority = Object.prototype.hasOwnProperty.call(priorityMap, a.tagType) ? priorityMap[a.tagType] : 2;
        const rightPriority = Object.prototype.hasOwnProperty.call(priorityMap, b.tagType) ? priorityMap[b.tagType] : 2;
        if (leftPriority !== rightPriority) {
            return leftPriority - rightPriority;
        }
        return a.title.localeCompare(b.title);
    }

    function buildCategoryOptions() {
        const result = [

                         { label: qsTr('全部'), value: 'all' },
                     ];
        const source = root.workspaceModel || [];
        for (let i = 0; i < source.length; ++i) {
            const section = source[i];
            if (section.menuChildren && section.menuChildren.length > 0) {
                result.push({
                                label: section.label,
                                value: section.key,
                            });
            }
        }
        return result;
    }

    function buildComponentItems() {
        const result = [];
        const source = root.workspaceModel || [];
        for (let i = 0; i < source.length; ++i) {
            const section = source[i];
            if (!section.menuChildren || section.menuChildren.length === 0) {
                continue;
            }
            for (let j = 0; j < section.menuChildren.length; ++j) {
                const entry = section.menuChildren[j];
                result.push({
                                categoryKey: section.key,
                                categoryLabel: section.label,
                                iconSource: section.iconSource,
                                key: entry.key,
                                title: entry.label || entry.key,
                                desc: entry.desc || '',
                                tagText: entry.addVersion ? 'NEW' : (entry.updateVersion ? 'HOT' : ''),
                                tagType: entry.addVersion ? 'new' : (entry.updateVersion ? 'update' : ''),
                                version: entry.addVersion || entry.updateVersion || '',
                            });
            }
        }
        result.sort(compareComponentItems);

        return result;
    }

    function buildFilteredComponentItems() {
        const result = [];
        for (let i = 0; i < componentItems.length; ++i) {
            const item = componentItems[i];
            if (currentCategoryKey === 'all'
                    || (currentCategoryKey === 'latest' && isCurrentMinorVersion(item.version))
                    || item.categoryKey === currentCategoryKey) {
                result.push(item);
            }
        }
        result.sort(compareComponentItems);
        return result;
    }

    function openLink(link) {
        if (link && link.length > 0) {
            if(link.indexOf('workspace:')===0)root.store.openModule(link.slice(10));else Backend.openUrl(link);
        }
    }

    function openMenu(key) {
        if (key && key.length > 0) {
            root.store.openModule(key);
        }
    }

    function resolveComponentGridColumns(availableWidth) {
        const maxColumns = Math.max(1, componentPreferredColumns);
        if (availableWidth >= 720) {
            return Math.min(4, maxColumns);
        }
        if (availableWidth >= 520) {
            return Math.min(3, maxColumns);
        }
        if (availableWidth >= 340) {
            return Math.min(2, maxColumns);
        }
        return 1;
    }

    component DropShadow: MultiEffect {
        shadowEnabled: true
        shadowBlur: 0.8
        shadowColor: color
        shadowScale: 1.02
        autoPaddingEnabled: true
        property color color
    }

    component SectionTitle: Column {
        width: parent.width
        spacing: 10

        property string title: ''
        property string subtitle: ''

        HusText {
            width: parent.width
            text: parent.title
            font {
                family: HusTheme.Primary.fontPrimaryFamily
                pixelSize: HusTheme.Primary.fontPrimarySizeHeading3
                bold: true
            }
            color: HusTheme.Primary.colorTextPrimary
        }

        HusText {
            width: parent.width
            text: parent.subtitle
            wrapMode: Text.Wrap
            color: HusTheme.Primary.colorTextSecondary
        }
    }

    component HeroCard: Item {
        id: heroCard
        width: (root.contentWidth - 24) * 0.5
        height: 260
        scale: hovered ? 1.04 : 1.0

        property string eyebrow: ''
        property string title: ''
        property string desc: ''
        property string primaryText: ''
        property string secondaryText: ''
        property string primaryLink: ''
        property string secondaryLink: ''
        property int iconSource: 0
        property color accentColor: HusTheme.Primary.colorPrimary
        property color secondAccentColor: HusTheme.Primary.colorInfo
        property bool hovered: heroHoverHandler.hovered
        property color hoverTint: HusThemeFunctions.alpha(heroCard.secondAccentColor, 0.08)

        Behavior on scale {
            NumberAnimation {
                easing.type: Easing.OutBack
                duration: HusTheme.Primary.durationSlow
            }
        }

        Rectangle {
            id: shaderMask
            anchors.fill: parent
            radius: HusTheme.Primary.radiusPrimary
            layer.enabled: true
            visible: false
        }

        GalleryFlow {
            id: shaderSource
            anchors.fill: parent
            visible: false
        }

        ShaderEffectSource {
            id: shaderTexture
            anchors.fill: parent
            sourceItem: shaderSource
            hideSource: true
            live: true
            recursive: true
            visible: false
        }

        MultiEffect {
            anchors.fill: parent
            maskEnabled: true
            maskSource: shaderMask
            source: shaderTexture
            opacity: 0.2
        }

        HoverHandler {
            id: heroHoverHandler
            cursorShape: Qt.PointingHandCursor
        }

        HusCard {
            anchors.fill: parent
            showShadow: true
            colorShadow: HusThemeFunctions.alpha(heroCard.accentColor, hovered ? 0.38 : 0.28)
            titleDelegate: null
            coverDelegate: null
            actionDelegate: null
            bgDelegate: Item {
                clip:true
                MaterialCard {
                    anchors.fill:parent;store:root.store
                    visible:root.store.cardMaterial!=="solid"
                    titleDelegate:null;coverDelegate:null;bodyDelegate:null;actionDelegate:null
                    showShadow:false
                }
                Rectangle {
                    width: Math.min(parent.width * 0.48,parent.height * 0.9)
                    height: width
                    radius: width * 0.5
                    anchors.right: parent.right
                    anchors.rightMargin: 16
                    anchors.top: parent.top
                    anchors.topMargin: 16
                    color: HusThemeFunctions.alpha(HusTheme.Primary['colorMain-1'], 0.12)
                }

                Rectangle {
                    anchors.fill: parent
                    color: heroCard.hoverTint
                    radius: HusTheme.Primary.radiusPrimary

                    Behavior on opacity { NumberAnimation { duration: HusTheme.Primary.durationFast } }
                }
            }
            bodyDelegate: Item {
                implicitHeight: heroCard.height

                Column {
                    width: parent.width - 56
                    anchors.left: parent.left
                    anchors.leftMargin: 28
                    anchors.right: parent.right
                    anchors.rightMargin: 28
                    anchors.top: parent.top
                    anchors.topMargin: 24
                    spacing: 14

                    HusLabel {
                        text: heroCard.eyebrow
                        leftPadding: 10
                        rightPadding: 10
                        topPadding: 4
                        bottomPadding: 4
                        borderBg.width: 0
                        radiusBg.all: height * 0.5
                        colorBg: HusThemeFunctions.alpha(HusTheme.Primary['colorMain-1'], 0.12)
                    }

                    HusText {
                        width: parent.width - 60
                        text: heroCard.title
                        wrapMode: Text.Wrap
                        font {
                            pixelSize: HusTheme.Primary.fontPrimarySizeHeading3
                            bold: true
                        }
                    }

                    HusText {
                        width: parent.width - 72
                        text: heroCard.desc
                        wrapMode: Text.Wrap
                    }
                }

                HusIconText {
                    anchors.right: parent.right
                    anchors.rightMargin: 28
                    anchors.top: parent.top
                    anchors.topMargin: 24
                    iconSource: heroCard.iconSource
                    iconSize: 24
                    colorIcon: HusThemeFunctions.alpha(HusTheme.Primary['colorMain-1'], 0.88)
                }

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 28
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 26
                    spacing: 12

                    HusButton {
                        text: heroCard.primaryText
                        type: HusButton.Type_Primary
                        onClicked: root.openLink(heroCard.primaryLink);
                    }

                    HusButton {
                        visible: heroCard.secondaryText !== ''
                        text: heroCard.secondaryText
                        type: HusButton.Type_Default
                        onClicked: root.openLink(heroCard.secondaryLink);
                    }
                }
            }
        }
    }

    component ComponentCard: Item {
        id: componentCard
        width: 236
        height: 248
        scale: hovered ? 1.04 : 1.0

        property var itemData
        property color accentColor: HusTheme.Primary.colorPrimary
        property alias hovered: componentHover.hovered
        property color borderColor: hovered
                                    ? HusThemeFunctions.alpha(componentCard.accentColor, 0.22)
                                    : HusTheme.Primary.colorBorderSecondary
        property color badgeBg: itemData && itemData.tagType === 'new'
                                ? HusTheme.Primary.colorInfoBg
                                : HusTheme.Primary.colorErrorBg
        property color badgeText: itemData && itemData.tagType === 'new'
                                  ? HusTheme.Primary.colorInfoText
                                  : HusTheme.Primary.colorErrorText

        Behavior on scale {
            NumberAnimation {
                easing.type: Easing.OutBack
                duration: HusTheme.Primary.durationSlow
            }
        }

        HoverHandler {
            id: componentHover
            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            onTapped: {
                root.openMenu(componentCard.itemData.key);
            }
        }

        MaterialCard {
            store:root.store
            anchors.fill: parent
            showShadow: true
            colorBg: HusThemeFunctions.alpha(HusTheme.Primary.colorBgBase, 0.7)
            colorShadow: componentCard.accentColor
            borderBg.color: componentCard.borderColor
            titleDelegate: null
            coverDelegate: null
            actionDelegate: null
            bodyDelegate: Item {
                implicitHeight: componentCard.height

                Rectangle {
                    anchors.fill: parent
                    radius: HusTheme.Primary.radiusPrimary
                    color: HusThemeFunctions.alpha(componentCard.accentColor, 0.03)
                    opacity: hovered ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: HusTheme.Primary.durationFast } }
                }

                Rectangle {
                    width: 52
                    height: 52
                    radius: width * 0.5
                    anchors.left: parent.left
                    anchors.leftMargin: 22
                    anchors.top: parent.top
                    anchors.topMargin: 22
                    color: HusThemeFunctions.alpha(componentCard.accentColor, 0.14)

                    HusIconText {
                        anchors.centerIn: parent
                        iconSource: componentCard.itemData.iconSource
                        iconSize: 20
                        colorIcon: componentCard.accentColor
                    }
                }

                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: 18
                    anchors.top: parent.top
                    anchors.topMargin: 18
                    spacing: 8

                    HusLabel {
                        leftPadding: 8
                        rightPadding: 8
                        topPadding: 2
                        bottomPadding: 2
                        borderBg.width: 0
                        radiusBg.all: height * 0.5
                        visible: componentCard.itemData.version !== ''
                        text: componentCard.itemData.version
                        colorBg: HusThemeFunctions.alpha(componentCard.accentColor, 0.14)
                        colorText: componentCard.accentColor
                    }

                    HusLabel {
                        leftPadding: 8
                        rightPadding: 8
                        topPadding: 2
                        bottomPadding: 2
                        borderBg.width: 0
                        radiusBg.all: height * 0.5
                        visible: componentCard.itemData.tagText !== ''
                        text: componentCard.itemData.tagText
                        colorBg: componentCard.badgeBg
                        colorText: componentCard.badgeText
                    }
                }

                Item {
                    width: parent.width - 40
                    anchors.left: parent.left
                    anchors.leftMargin: 20
                    anchors.right: parent.right
                    anchors.rightMargin: 20
                    anchors.top: parent.top
                    anchors.topMargin: 94
                    anchors.bottom: progressTrack.top
                    anchors.bottomMargin: 16

                    HusText {
                        id: componentTitle
                        width: parent.width
                        text: componentCard.itemData.title
                        wrapMode: Text.Wrap
                        font {
                            pixelSize: HusTheme.Primary.fontPrimarySizeHeading5
                            bold: true
                        }
                        color: HusTheme.Primary.colorTextPrimary
                    }

                    ScrollView {
                        width: parent.width
                        anchors.top: componentTitle.bottom
                        anchors.topMargin: 10
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        clip: true
                        ScrollBar.vertical: HusScrollBar { }
                        SmoothWheel { }

                        HoverHandler {
                            cursorShape: Qt.PointingHandCursor
                        }

                        TapHandler {
                            onTapped: {
                                root.openMenu(componentCard.itemData.key);
                            }
                        }

                        HusText {
                            width: parent.width
                            text: componentCard.itemData.desc
                            wrapMode: Text.Wrap
                            color: HusTheme.Primary.colorTextSecondary
                        }
                    }
                }

                Rectangle {
                    id: progressTrack
                    width: parent.width - 40
                    height: 6
                    radius: height * 0.5
                    anchors.left: parent.left
                    anchors.leftMargin: 20
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 18
                    color: HusTheme.Primary.colorFillSecondary

                    Rectangle {
                        width: hovered ? Math.max(parent.width * 0.44, 96) : Math.max(parent.width * 0.35, 72)
                        height: parent.height
                        radius: parent.radius
                        color: componentCard.accentColor
                        Behavior on width { NumberAnimation { duration: HusTheme.Primary.durationFast } }
                    }
                }
            }
        }
    }

    Item {
        id: background
        anchors.fill: parent

        Rectangle {
            width: root.width * 0.34
            height: width
            radius: width * 0.5
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.top: parent.top
            anchors.topMargin: 16
            color: HusThemeFunctions.alpha(HusTheme.Primary.colorPrimary, 0.08)
        }

        Rectangle {
            width: root.width * 0.28
            height: width
            radius: width * 0.5
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.top: parent.top
            anchors.topMargin: 80
            color: HusThemeFunctions.alpha(HusTheme.Primary.colorInfo, 0.06)
        }
    }

    Flickable {
        anchors.fill: parent
        contentHeight: contentColumn.height
        clip: true
        ScrollBar.vertical: HusScrollBar { }
        SmoothWheel { }

        Column {
            id: contentColumn
            width: parent.width - 80
            anchors.horizontalCenter: parent.horizontalCenter
            topPadding: 10
            bottomPadding: 10
            spacing: 40

            Column {
                width: parent.width
                spacing: 16

                Row {
                    spacing: 20

                    Item {
                        width: HusTheme.Primary.fontPrimarySize + 42
                        height: width
                        anchors.verticalCenter: parent.verticalCenter

                        Image {
                            id: huskaruiIcon
                            width: parent.width
                            height: width
                            anchors.centerIn: parent
                            source: AssetRoot+"shodan.png"
                            layer.enabled:HusTheme.isDark
                            layer.effect:MultiEffect { brightness:0.45 }
                        }
                    }

                    Item {
                        width: huskaruiTitle.width
                        height: huskaruiTitle.height
                        anchors.verticalCenter: parent.verticalCenter

                        HusText {
                            id: huskaruiTitle
                            text: 'SHODAN'
                            font.pixelSize: HusTheme.Primary.fontPrimarySize + 42
                        }

                        DropShadow {
                            anchors.fill: huskaruiTitle
                            shadowHorizontalOffset: 4
                            shadowVerticalOffset: 4
                            color: huskaruiTitle.color
                            source: huskaruiTitle
                            opacity: 0.6

                            Behavior on color { ColorAnimation { duration: HusTheme.Primary.durationMid } }
                            Behavior on opacity { NumberAnimation { duration: HusTheme.Primary.durationMid } }
                        }
                    }
                }

                HusText {
                    width: parent.width * 0.62
                    text: qsTr('绝地潜兵 2 数值编辑工作台，选择资源、调整参数并预览写入。')
                    wrapMode: Text.Wrap
                    color: HusTheme.Primary.colorTextSecondary
                    font.pixelSize: HusTheme.Primary.fontPrimarySizeHeading5
                }
            }

            Flow {
                width: parent.width
                spacing: 32

                HeroCard {
                    width: Math.max((parent.width - parent.spacing) * 0.5, 360)
                    eyebrow: qsTr('数据编辑')
                    title: qsTr('装备与游戏参数')
                    desc: qsTr('浏览装备、战略配备、载具和敌人。在独立工作区编辑，确认修改后统一写入游戏。')
                    primaryText: qsTr('打开装备库')
                    secondaryText: qsTr('浏览数据库')
                    primaryLink: 'workspace:equipment'
                    secondaryLink: 'workspace:records'
                    iconSource: HusIcon.GithubOutlined
                    accentColor: HusTheme.Primary.colorPrimary
                    secondAccentColor: HusTheme.Primary.colorInfo
                }

                HeroCard {
                    width: Math.max((parent.width - parent.spacing) * 0.5, 360)
                    eyebrow: qsTr('配置方案')
                    title: qsTr('预设与个性化')
                    desc: qsTr('保存每件装备的独立预设或整套修改方案；自定义主题色、背景图片与界面动效。')
                    primaryText: qsTr('管理预设')
                    secondaryText: qsTr('外观设置')
                    primaryLink: 'workspace:presets'
                    secondaryLink: 'workspace:settings'
                    iconSource: HusIcon.SkinOutlined
                    accentColor: HusTheme.Primary.colorInfo
                    secondAccentColor: HusTheme.Primary.colorPrimary
                }
            }

            SectionTitle {
                width: parent.width
                title: qsTr('工作空间')
                subtitle: qsTr('按分类选择编辑内容。')
            }

            RowLayout {
                width: parent.width

                Item {
                    Layout.fillWidth: true
                }

                HusSegmented {
                    id: categorySegmented
                    Layout.alignment: Qt.AlignRight
                    colorBg: HusThemeFunctions.alpha(HusTheme.Primary.colorBgBase, 0.5)
                    colorIndicatorBg: HusThemeFunctions.alpha(HusTheme.Primary.colorPrimary, 0.5)
                    options: root.categoryOptions
                    spacing: 5
                    currentIndex: root.selectedCategoryIndex
                    onCurrentIndexChanged: root.selectedCategoryIndex = currentIndex
                }
            }

            GridView {
                id: componentGrid
                width: parent.width - 40
                height: 540
                anchors.horizontalCenter: parent.horizontalCenter
                topMargin: 10
                bottomMargin: 10
                clip: true
                model: root.filteredComponentItems
                reuseItems: true
                cacheBuffer: height
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                ScrollBar.vertical: HusScrollBar { }
                SmoothWheel { }
                leftMargin: sidePadding
                rightMargin: sidePadding
                cellWidth: cellContentWidth
                cellHeight: root.componentCardHeight + root.componentGridSpacing
                delegate: ComponentCard {
                    width: componentGrid.delegateWidth
                    height: root.componentCardHeight
                    itemData: modelData
                    accentColor: root.accentPalette[index % root.accentPalette.length]
                }
                readonly property int sidePadding: 10
                readonly property int availableWidth: Math.max(root.componentCardMinWidth, width - sidePadding * 2)
                property int columnCount: root.resolveComponentGridColumns(availableWidth)
                readonly property int cellContentWidth: Math.floor(availableWidth / columnCount)
                readonly property int delegateWidth: Math.min(root.componentCardWidth, Math.max(root.componentCardMinWidth, cellContentWidth - root.componentGridSpacing))
            }

            Rectangle {
                id: ctaCard
                width: parent.width
                height: ctaColumn.height + 48
                radius: HusTheme.Primary.radiusPrimary
                color: HusThemeFunctions.alpha(HusTheme.Primary.colorPrimary, 0.08)
                scale: ctaHoverHandler.hovered ? 1.02 : 1.0

                Behavior on scale {
                    NumberAnimation {
                        easing.type: Easing.OutBack
                        duration: HusTheme.Primary.durationSlow
                    }
                }

                HoverHandler {
                    id: ctaHoverHandler
                    cursorShape: Qt.PointingHandCursor
                }

                Column {
                    id: ctaColumn
                    width: parent.width - 64
                    anchors.horizontalCenter: parent.horizontalCenter
                    topPadding: 24
                    spacing: 14

                    HusText {
                        width: parent.width
                        text: qsTr('让工作台适合你的习惯')
                        font {
                            pixelSize: HusTheme.Primary.fontPrimarySizeHeading4
                            bold: true
                        }
                        color: HusTheme.Primary.colorTextPrimary
                    }

                    HusText {
                        width: parent.width
                        text: qsTr('调整主题、字体与卡片材质，设置自己的背景图片。')
                        wrapMode: Text.Wrap
                        color: HusTheme.Primary.colorTextSecondary
                    }

                    Row {
                        spacing: 12

                        HusButton {
                            text: qsTr('打开外观设置')
                            type: HusButton.Type_Primary
                            onClicked: root.store.openModule('settings');
                        }
                    }
                }
            }

            RowLayout {
                width: parent.width
                spacing: 16

                HusText {
                    Layout.alignment: Qt.AlignVCenter
                    text: 'SHODAN'
                    color: HusTheme.Primary.colorPrimary
                    font.bold: true
                }

                HusButton {
                    text: qsTr('外观设置')
                    type: HusButton.Type_Link
                    onClicked: root.store.openModule('settings');
                }

                HusButton {
                    text: qsTr('工作空间')
                    type: HusButton.Type_Link
                    onClicked: root.store.openModule('equipment');
                }


                HusButton {
                    text: qsTr('开源许可')
                    type: HusButton.Type_Link
                    onClicked: root.openLink('https://github.com/127MU/SHODAN-Stat-Editor/blob/main/LICENSE');
                }

                Item {
                    Layout.fillWidth: true
                }


            }
        }
    }
}
