import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HuskarUI.Basic

Flickable {
    id:page
    objectName:"settingsScroll"
    required property var store
    required property var preferences
    property bool effectUnavailable:false
    property bool uiReady:false
    Component.onCompleted:uiReady=true
    signal message(string title,string text)
    contentHeight:body.height;clip:true
    ScrollBar.vertical:HusScrollBar{}
    SmoothWheel { }
    ColumnLayout {
        id:body;width:page.width-18;spacing:22
        HusText { text:"设置";font.pixelSize:30;font.bold:true }
        HusText { text:"调整工作台外观、交互和本机接口。";color:HusTheme.Primary.colorTextSecondary }
        MaterialCard {
            store:page.store
            Layout.fillWidth:true;title:"主题与外观"
            bodyDelegate:ColumnLayout {
                width:parent.width;spacing:20
                RowLayout {
                    Layout.fillWidth:true;Layout.margins:18
                    HusText { text:"颜色模式";Layout.fillWidth:true }
                    HusSelect { model:[{label:"跟随系统",value:"system"},{label:"浅色",value:"light"},{label:"深色",value:"dark"}];textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:preferences.themeMode==="system"?0:preferences.dark?2:1;onActivated:preferences.setColorMode(currentValue) }
                }
                RowLayout {
                    Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18
                    HusText { text:"主题色";Layout.fillWidth:true }
                    HusColorPicker {
                        defaultValue:preferences.accent;showText:true;alphaEnabled:false
                        title:"选择主题色"
                        presets:[{label:"HuskarUI 预设色",expanded:true,colors:["#1677ff","#722ed1","#eb2f96","#f5222d","#fa8c16","#faad14","#52c41a","#13c2c2"]}]
                        onChange:color=>{if(page.uiReady)preferences.accent=toHexString(color)}
                    }
                    HusButton { text:"恢复默认";type:HusButton.Type_Text;onClicked:{HusTheme.installIndexTheme(":/HuskarUI/resources/theme/Index.json");preferences.accent="#1677ff";preferences.fontSize=16;preferences.radius=6;preferences.apply()} }
                }
                RowLayout {
                    Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18
                    HusText { text:"卡片材质";Layout.fillWidth:true }
                    HusSelect { model:[{label:"普通",value:"solid"},{label:"磨砂",value:"frost"},{label:"液态玻璃",value:"glass"}];textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:preferences.cardMaterial==="glass"?2:preferences.cardMaterial==="frost"?1:0;onActivated:preferences.cardMaterial=currentValue }
                }
                RowLayout { Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18;HusText { text:"导航栏";Layout.fillWidth:true } HusSegmented { options:[{label:"展开",value:false},{label:"紧凑",value:true}];currentIndex:preferences.compact?1:0;onCurrentValueChanged:if(page.uiReady && currentValue!==undefined)preferences.compact=!!currentValue } }
                RowLayout { Layout.fillWidth:true;Layout.margins:18;HusText { text:"字体大小  "+preferences.fontSize;Layout.preferredWidth:190 } HusSlider { Layout.fillWidth:true;Layout.preferredHeight:32;Layout.minimumHeight:32;objectName:"setting_fontSize";min:12;max:24;stepSize:1;value:preferences.fontSize;onFirstReleased:preferences.fontSize=Math.round(currentValue) } }
                RowLayout { Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18;Layout.bottomMargin:18;HusText { text:"圆角大小";Layout.preferredWidth:190 } HusSlider { Layout.fillWidth:true;Layout.preferredHeight:32;Layout.minimumHeight:32;objectName:"setting_radius";min:0;max:20;stepSize:1;value:preferences.radius;onFirstReleased:preferences.radius=Math.round(currentValue) } }
            }
        }
        MaterialCard {
            store:page.store
            Layout.fillWidth:true;title:"背景图片"
            bodyDelegate:ColumnLayout {
                width:parent.width;spacing:20
                RowLayout {
                    Layout.fillWidth:true;Layout.margins:18
                    HusText { text:"背景来源";Layout.fillWidth:true }
                    HusSelect { model:[{label:"默认主题背景",value:"plain"},{label:"Gallery 动态背景",value:"flow"},{label:"自定义图片",value:"image"}];textRole:"label";valueRole:"value";currentIndex:preferences.backgroundMode==="flow"?1:preferences.backgroundMode==="image"?2:0;clearEnabled:false;onActivated:preferences.backgroundMode=currentValue }
                }
                RowLayout {
                    Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18
                    HusButton { text:preferences.backgroundImage?"替换图片":"选择图片";onClicked:{let path=Backend.chooseBackground();if(path){preferences.backgroundImage=path;preferences.backgroundMode="image"}} }
                    HusButton { text:"清除图片";enabled:!!preferences.backgroundImage;onClicked:{preferences.backgroundImage="";preferences.backgroundMode="plain"} }
                    HusSelect { model:[{label:"裁剪填满",value:"cover"},{label:"完整显示",value:"contain"},{label:"拉伸",value:"stretch"}];textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:preferences.imageFit==="contain"?1:preferences.imageFit==="stretch"?2:0;onActivated:preferences.imageFit=currentValue }
                }
                RowLayout { Layout.fillWidth:true;Layout.margins:18;HusText { text:"背景透明度";Layout.preferredWidth:190 } HusSlider { Layout.fillWidth:true;Layout.preferredHeight:32;Layout.minimumHeight:32;objectName:"setting_backgroundOpacity";min:0;max:1;stepSize:0.05;value:preferences.backgroundOpacity;onFirstReleased:preferences.backgroundOpacity=currentValue } }
            }
        }
        MaterialCard {
            store:page.store
            Layout.fillWidth:true;title:"动画"
            bodyDelegate:ColumnLayout {
                width:parent.width;spacing:20
                RowLayout { Layout.fillWidth:true;Layout.margins:18;HusText { text:"界面过渡动画";Layout.fillWidth:true } HusSwitch { checked:preferences.motion;onClicked:preferences.motion=checked } }
                RowLayout { Layout.fillWidth:true;Layout.margins:18;HusText { text:"动画速度";Layout.preferredWidth:190 } HusSlider { Layout.fillWidth:true;Layout.preferredHeight:32;Layout.minimumHeight:32;objectName:"setting_duration";min:80;max:300;stepSize:10;value:preferences.duration;onFirstReleased:preferences.duration=Math.round(currentValue) } }
                RowLayout {
                    Layout.fillWidth:true;Layout.margins:18
                    HusText { text:"页面切换特效";Layout.fillWidth:true }
                    HusSelect { model:[{label:"无",value:0},{label:"淡入",value:1}];textRole:"label";valueRole:"value";currentIndex:preferences.pageEffect===0?0:1;clearEnabled:false;defaultPopupMaxHeight:320;onActivated:preferences.pageEffect=currentValue }
                }
            }
        }
        MaterialCard {
            store:page.store
            Layout.fillWidth:true;title:"窗口"
            bodyDelegate:ColumnLayout {
                width:parent.width;spacing:18
                RowLayout { Layout.fillWidth:true;Layout.margins:18;HusText { text:"窗口置顶";Layout.fillWidth:true } HusSwitch { checked:preferences.onTop;onClicked:preferences.onTop=checked } }
                RowLayout { Layout.fillWidth:true;Layout.margins:18;HusText { text:"窗口效果";Layout.fillWidth:true } HusSelect { model:[{label:"无",value:0},{label:"DWM 模糊",value:1},{label:"亚克力",value:2},{label:"云母",value:3},{label:"云母 Alt",value:4}];textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:preferences.windowEffect;defaultPopupMaxHeight:280;onActivated:preferences.windowEffect=currentValue } }
                HusText { visible:page.effectUnavailable;Layout.leftMargin:18;Layout.rightMargin:18;Layout.fillWidth:true;text:"当前系统不支持所选效果，已使用普通主题背景。";wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
                RowLayout { Layout.fillWidth:true;Layout.margins:18;HusText { text:"窗口透明度";Layout.preferredWidth:190 } HusSlider { Layout.fillWidth:true;Layout.preferredHeight:32;Layout.minimumHeight:32;objectName:"setting_windowOpacity";min:0.8;max:1;stepSize:0.02;value:preferences.windowOpacity;onFirstReleased:preferences.windowOpacity=currentValue } }
            }
        }
        MaterialCard {
            store:page.store
            Layout.fillWidth:true;title:"MCP 与调试"
            bodyDelegate:ColumnLayout {
                width:parent.width;spacing:14
                RowLayout { Layout.fillWidth:true;Layout.margins:18;HusText { text:"仅当前会话开启，仅监听本机。";Layout.fillWidth:true } HusSwitch { checked:Backend.mcpEnabled;onClicked:Backend.toggleMcp() } }
                RowLayout {
                    Layout.margins:18
                    HusButton { text:"复制连接配置";enabled:Backend.mcpEnabled;onClicked:Backend.copyMcp() }
                    HusButton { text:"查看接口";onClicked:store.call("debug_interfaces",[],d=>page.message("接口清单",d.map(x=>x.name+" · "+x.type).join("\n"))) }
                }
            }
        }
        MaterialCard {
            store:page.store
            Layout.fillWidth:true;title:"版本与项目"
            bodyDelegate:ColumnLayout {
                width:parent.width;spacing:14
                HusText { Layout.margins:18;text:Backend.version+" · "+Backend.updateStatus;wrapMode:Text.Wrap }
                RowLayout { Layout.margins:18;HusButton { text:Backend.checking?"正在检查…":"检查更新";enabled:!Backend.checking;onClicked:Backend.checkUpdate() } HusButton { text:"GitHub 项目";onClicked:Backend.openUrl("https://github.com/127MU/SHODAN-Stat-Editor") } }
                HusText { Layout.margins:18;Layout.fillWidth:true;text:"游戏路径："+store.game;wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
            }
        }
    }
}
