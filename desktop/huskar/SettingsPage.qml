import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HuskarUI.Basic

Flickable {
    id:page
    objectName:"settingsScroll"
    required property var store
    required property var preferences
    property bool advancedAppearance:Backend.setting("advancedAppearance",false)
    onAdvancedAppearanceChanged:if(uiReady)Backend.saveSetting("advancedAppearance",advancedAppearance)
    property int section:0
    onSectionChanged:contentY=0
    property bool effectUnavailable:false
    property bool uiReady:false
    Component.onCompleted:uiReady=true
    signal message(string title,string text)
    contentHeight:body.height;clip:true
    ScrollBar.vertical:HusScrollBar{}
    SmoothWheel { }
    ColumnLayout {
        id:body;x:10;width:page.width-30;spacing:18
        HusText { text:"设置";font.pixelSize:30;font.bold:true }
        RowLayout {
            Layout.fillWidth:true
            HusText { text:"你的工作台，你的风格。修改即时预览并自动保存。";Layout.fillWidth:true;color:HusTheme.Primary.colorTextSecondary;wrapMode:Text.Wrap }
            HusButton { text:"撤销主题切换";enabled:!!preferences.previousAppearance;onClicked:preferences.undo() }
        }
        HusSegmented {
            Layout.fillWidth:true
            options:[{label:"主题与材质",value:0},{label:"背景",value:1},{label:"交互动效",value:2},{label:"窗口",value:3},{label:"接口与项目",value:4}]
            currentIndex:page.section
            onCurrentValueChanged:if(page.uiReady && currentValue!==undefined)page.section=Number(currentValue)
        }
        RowLayout {
            visible:page.section===0;Layout.fillWidth:true
            HusText { Layout.fillWidth:true;text:page.advancedAppearance?"高级细调：保留全部自定义参数":"常用设置：颜色、字号、背景和动效";color:HusTheme.Primary.colorTextSecondary }
            HusSwitch { checked:page.advancedAppearance;checkedText:"高级";uncheckedText:"常用";onClicked:page.advancedAppearance=checked }
        }
        GridLayout {
            id:themeGrid;visible:page.section===0;Layout.fillWidth:true
            columns:width>=900?2:1;uniformCellWidths:true;columnSpacing:22;rowSpacing:18
        MaterialCard {
            Layout.fillWidth:true;Layout.fillHeight:true;Layout.alignment:Qt.AlignTop;Layout.row:themeGrid.columns===2?0:1;Layout.column:0;objectName:"personalTheme";store:page.store;title:"个人主题"
            bodyDelegate:ColumnLayout {
                width:parent.width;spacing:16
                HusText { Layout.fillWidth:true;Layout.margins:18;text:"自由调整下面的颜色、材质和交互参数，组合成自己的外观。所有调整即时生效；保存个人主题后，可随时重新加载。";wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
                Flow {
                    Layout.fillWidth:true;Layout.margins:18;spacing:12
                    HusButton { text:"保存当前外观";onClicked:{preferences.saveCustom();page.message("主题已保存","颜色、材质与交互动效已保存为你的个人主题。")} }
                    HusButton { text:"加载我的外观";enabled:!!preferences.customAppearance;onClicked:preferences.useCustom() }
                    HusButton { text:"恢复默认外观";onClicked:preferences.resetAppearance() }
                }
            }
        }
        MaterialCard {
            objectName:"appearancePreview";Layout.fillWidth:true;Layout.fillHeight:true;Layout.alignment:Qt.AlignTop;Layout.row:0;Layout.column:themeGrid.columns===2?1:0;store:page.store;title:"实时预览"
            bodyDelegate:ColumnLayout {
                width:parent.width;spacing:12
                HusText { Layout.margins:18;text:"AR-23 解放者";font.bold:true;font.pixelSize:22 }
                HusText { Layout.leftMargin:18;Layout.rightMargin:18;Layout.fillWidth:true;text:"在这张卡片上查看当前材质、文字对比和悬浮反馈。";wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
                Flow { Layout.fillWidth:true;Layout.margins:18;spacing:12;HusButton { text:"主要操作";type:HusButton.Type_Primary } HusButton { text:"次要操作" } HusSwitch { checked:true;checkedText:"开";uncheckedText:"关" } }
            }
        }
        }
        MaterialCard {
            store:page.store
            visible:page.section===0;Layout.fillWidth:true;title:"主题与外观"
            bodyDelegate:ColumnLayout {
                width:parent.width;spacing:20
                RowLayout {
                    Layout.fillWidth:true;Layout.margins:18
                    ColumnLayout { Layout.fillWidth:true;Layout.minimumWidth:0;spacing:4;HusText { text:"颜色模式";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"浅色、深色或跟随系统；影响整个工作台的背景和文字。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } }
                    HusSelect { model:[{label:"跟随系统",value:"system"},{label:"浅色",value:"light"},{label:"深色",value:"dark"}];textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:preferences.themeMode==="system"?0:preferences.dark?2:1;onActivated:preferences.setColorMode(currentValue) }
                }
                RowLayout {
                    Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18
                    ColumnLayout { Layout.fillWidth:true;Layout.minimumWidth:0;spacing:4;HusText { text:"主题色";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"用于主按钮、选中项和控件高亮；自动配色开启时由背景图片决定。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } }
                    HusColorPicker {
                        defaultValue:preferences.accent;showText:true;alphaEnabled:false;enabled:!preferences.autoAccent
                        title:"选择主题色"
                        presets:[{label:"HuskarUI 预设色",expanded:true,colors:["#1677ff","#722ed1","#eb2f96","#f5222d","#fa8c16","#faad14","#52c41a","#13c2c2"]}]
                        onChange:color=>{if(page.uiReady)preferences.accent=toHexString(color)}
                    }
                    HusButton { text:"重置主题色";type:HusButton.Type_Text;onClicked:{preferences.autoAccent=false;preferences.accent="#1677ff"} }
                }
                RowLayout {
                    Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18
                    ColumnLayout { Layout.fillWidth:true;Layout.minimumWidth:0;spacing:4;HusText { text:"卡片材质";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"普通为实色；磨砂模糊背后的图片；液态玻璃增加折射与边缘高光。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } }
                    HusSelect { model:[{label:"普通",value:"solid"},{label:"磨砂",value:"frost"},{label:"液态玻璃",value:"glass"}];textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:preferences.cardMaterial==="glass"?2:preferences.cardMaterial==="frost"?1:0;onActivated:preferences.cardMaterial=currentValue }
                }
                RowLayout {
                    Layout.fillWidth:true;Layout.margins:18
                    HusText { text:"材质设置随所选材质展开，滑动即可预览。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
                }
                RowLayout {
                    visible:preferences.cardMaterial==="frost";Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18
                    ColumnLayout { Layout.preferredWidth:210;Layout.minimumWidth:140;Layout.maximumWidth:230;spacing:4;HusText { text:"磨砂底色不透明度";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"越高越不透，文字更清楚；越低越能看到背景图片。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } }
                    HusSlider { objectName:"setting_frostOpacity";Layout.fillWidth:true;Layout.minimumWidth:100;Layout.preferredHeight:32;min:0.1;max:1;stepSize:0.02;value:preferences.frostOpacity;onFirstMoved:preferences.frostOpacity=currentValue }
                    HusText { text:Number(preferences.frostOpacity).toFixed(2);Layout.preferredWidth:48 }
                }
                RowLayout {
                    visible:page.advancedAppearance && preferences.cardMaterial==="frost";Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18
                    ColumnLayout { Layout.preferredWidth:210;Layout.minimumWidth:140;Layout.maximumWidth:230;spacing:4;HusText { text:"磨砂模糊强度";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"越高背景越柔和；设为 0 时不模糊。只影响磨砂卡片。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } }
                    HusSlider { objectName:"setting_materialBlur";Layout.fillWidth:true;Layout.minimumWidth:100;Layout.preferredHeight:32;min:0;max:8;stepSize:0.1;value:preferences.materialBlur;onFirstMoved:preferences.materialBlur=currentValue }
                    HusText { text:Number(preferences.materialBlur).toFixed(2);Layout.preferredWidth:48 }
                }
                RowLayout {
                    visible:preferences.cardMaterial==="glass";Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18
                    ColumnLayout { Layout.preferredWidth:210;Layout.minimumWidth:140;Layout.maximumWidth:230;spacing:4;HusText { text:"玻璃底色不透明度";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"调整玻璃表面的底色浓度；不改变窗口本身的透明度。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } }
                    HusSlider { objectName:"setting_glassOpacity";Layout.fillWidth:true;Layout.minimumWidth:100;Layout.preferredHeight:32;min:0.05;max:0.85;stepSize:0.02;value:preferences.glassOpacity;onFirstMoved:preferences.glassOpacity=currentValue }
                    HusText { text:Number(preferences.glassOpacity).toFixed(2);Layout.preferredWidth:48 }
                }
                HusCollapse {
                    visible:page.advancedAppearance && preferences.cardMaterial==="glass";Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18
                    initModel:[{key:"glass",title:"玻璃高级参数"}]
                    contentDelegate:ColumnLayout { width:parent.width;spacing:18
                RowLayout {
                    visible:preferences.cardMaterial==="glass";Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18
                    ColumnLayout { Layout.preferredWidth:210;Layout.minimumWidth:140;Layout.maximumWidth:230;spacing:4;HusText { text:"玻璃折射强度";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"控制卡片内背景的弯曲程度，过高可能影响背景清晰度。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } }
                    HusSlider { objectName:"setting_glassRefraction";Layout.fillWidth:true;Layout.minimumWidth:100;Layout.preferredHeight:32;min:0.01;max:0.18;stepSize:0.005;value:preferences.glassRefraction;onFirstMoved:preferences.glassRefraction=currentValue }
                    HusText { text:Number(preferences.glassRefraction).toFixed(2);Layout.preferredWidth:48 }
                }
                RowLayout {
                    visible:preferences.cardMaterial==="glass";Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18
                    ColumnLayout { Layout.preferredWidth:210;Layout.minimumWidth:140;Layout.maximumWidth:230;spacing:4;HusText { text:"玻璃高光强度";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"控制玻璃边缘亮度；设为 0 可以隐藏高光。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } }
                    HusSlider { objectName:"setting_glassHighlight";Layout.fillWidth:true;Layout.minimumWidth:100;Layout.preferredHeight:32;min:0;max:3;stepSize:0.1;value:preferences.glassHighlight;onFirstMoved:preferences.glassHighlight=currentValue }
                    HusText { text:Number(preferences.glassHighlight).toFixed(2);Layout.preferredWidth:48 }
                }
                    }
                }
                RowLayout { Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18;ColumnLayout { Layout.fillWidth:true;Layout.minimumWidth:0;spacing:4;HusText { text:"导航栏";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"展开时显示图标与文字，紧凑时减少侧边栏占用。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } } HusSegmented { options:[{label:"展开",value:false},{label:"紧凑",value:true}];currentIndex:preferences.compact?1:0;onCurrentValueChanged:if(page.uiReady && currentValue!==undefined)preferences.compact=!!currentValue } }
                RowLayout { Layout.fillWidth:true;Layout.margins:18;ColumnLayout { Layout.preferredWidth:210;Layout.minimumWidth:140;Layout.maximumWidth:230;spacing:4;HusText { text:"字体大小  "+preferences.fontSize;Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"调整全局文字尺寸，标题和控件会一起适配。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } } HusSlider { Layout.fillWidth:true;Layout.minimumWidth:100;Layout.preferredHeight:32;Layout.minimumHeight:32;objectName:"setting_fontSize";min:12;max:24;stepSize:1;value:preferences.fontSize;onFirstReleased:preferences.fontSize=Math.round(currentValue) } }
                RowLayout { Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18;Layout.bottomMargin:18;ColumnLayout { Layout.preferredWidth:210;Layout.minimumWidth:140;Layout.maximumWidth:230;spacing:4;HusText { text:"圆角大小";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"控制按钮、输入框和卡片的圆角；0 表示直角。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } } HusSlider { Layout.fillWidth:true;Layout.minimumWidth:100;Layout.preferredHeight:32;Layout.minimumHeight:32;objectName:"setting_radius";min:0;max:20;stepSize:1;value:preferences.radius;onFirstReleased:preferences.radius=Math.round(currentValue) } }
            }
        }
        MaterialCard {
            store:page.store
            visible:page.section===1;Layout.fillWidth:true;title:"背景与自动配色"
            bodyDelegate:ColumnLayout {
                width:parent.width;spacing:20
                RowLayout {
                    Layout.fillWidth:true;Layout.margins:18
                    ColumnLayout { Layout.fillWidth:true;Layout.minimumWidth:0;spacing:4;HusText { text:"背景来源";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"选择纯主题底色、动态流光，或你自己的图片。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } }
                    HusSelect { model:[{label:"默认主题背景",value:"plain"},{label:"流光动态背景",value:"flow"},{label:"自定义图片",value:"image"}];textRole:"label";valueRole:"value";currentIndex:preferences.backgroundMode==="flow"?1:preferences.backgroundMode==="image"?2:0;clearEnabled:false;onActivated:preferences.backgroundMode=currentValue }
                }
                RowLayout {
                    Layout.fillWidth:true;Layout.leftMargin:18;Layout.rightMargin:18
                    HusButton { text:preferences.backgroundImage?"替换图片":"选择图片";onClicked:{let path=Backend.chooseBackground();if(path){preferences.backgroundImage=path;preferences.backgroundMode="image"}} }
                    HusButton { text:"清除图片";enabled:!!preferences.backgroundImage;onClicked:{preferences.backgroundImage="";preferences.backgroundMode="plain"} }
                    HusSelect { model:[{label:"裁剪填满",value:"cover"},{label:"完整显示",value:"contain"},{label:"拉伸",value:"stretch"}];textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:preferences.imageFit==="contain"?1:preferences.imageFit==="stretch"?2:0;onActivated:preferences.imageFit=currentValue }
                }
                RowLayout {
                    Layout.fillWidth:true;Layout.margins:18
                    ColumnLayout { Layout.fillWidth:true;Layout.minimumWidth:0;spacing:4;HusText { text:"从背景提取主题色";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"从图片中提取主色并用于控件，不会修改原图片。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } }
                    HusSwitch { checked:preferences.autoAccent;onClicked:preferences.autoAccent=checked }
                    HusButton { text:"重新取色";enabled:!!preferences.backgroundImage;onClicked:preferences.updateAutoAccent() }
                }
                HusText { Layout.leftMargin:18;Layout.rightMargin:18;Layout.fillWidth:true;text:"选择图片后自动提取主色；纯黑白图片使用默认蓝色。关闭自动配色后可手动选择主题色。";wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
                RowLayout { Layout.fillWidth:true;Layout.margins:18;ColumnLayout { Layout.preferredWidth:210;Layout.minimumWidth:140;Layout.maximumWidth:230;spacing:4;HusText { text:"背景透明度";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"越高图片越明显；设为 0 隐藏图片，保留主题底色。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } } HusSlider { Layout.fillWidth:true;Layout.minimumWidth:100;Layout.preferredHeight:32;Layout.minimumHeight:32;objectName:"setting_backgroundOpacity";min:0;max:1;stepSize:0.05;value:preferences.backgroundOpacity;onFirstMoved:preferences.backgroundOpacity=currentValue } }
            }
        }
        MaterialCard {
            store:page.store
            visible:page.section===2;Layout.fillWidth:true;title:"交互动效"
            bodyDelegate:ColumnLayout {
                width:parent.width;spacing:20
                RowLayout { Layout.fillWidth:true;Layout.margins:18;ColumnLayout { Layout.fillWidth:true;Layout.minimumWidth:0;spacing:4;HusText { text:"界面过渡动画";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"总开关；关闭后停止控件过渡、卡片高亮渐变和玻璃动态效果。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } } HusSwitch { checked:preferences.motion;onClicked:preferences.motion=checked } }
                RowLayout { Layout.fillWidth:true;Layout.margins:18;ColumnLayout { Layout.fillWidth:true;Layout.minimumWidth:0;spacing:4;HusText { text:"卡片高亮与玻璃跟随";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"鼠标移入时边框高亮，玻璃随鼠标方向变化；卡片位置保持不动。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } } HusSwitch { enabled:preferences.motion;checked:preferences.hoverEffects;onClicked:preferences.hoverEffects=checked } }
                RowLayout {
                    Layout.fillWidth:true;Layout.margins:18
                    ColumnLayout { Layout.fillWidth:true;HusText { text:"材质性能" } HusText { Layout.fillWidth:true;wrapMode:Text.Wrap;text:"省电降低模糊并停止玻璃流动；均衡在滚动时暂停流动；高品质持续保留完整效果。";font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } }
                    HusSelect { objectName:"setting_materialQuality";model:[{label:"省电",value:"economy"},{label:"均衡",value:"balanced"},{label:"高品质",value:"quality"}];textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:preferences.materialQuality==="economy"?0:preferences.materialQuality==="quality"?2:1;onActivated:preferences.materialQuality=currentValue }
                }
                HusText { Layout.margins:18;Layout.fillWidth:true;text:"按钮按压与颜色过渡沿用 HuskarUI 原生动效。关闭界面动画后，玻璃流动与悬浮跟随同步停止。";wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
                RowLayout { Layout.fillWidth:true;Layout.margins:18;ColumnLayout { Layout.preferredWidth:210;Layout.minimumWidth:140;Layout.maximumWidth:230;spacing:4;HusText { text:"动画时长（毫秒）";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"控件的基础时长；页面过渡使用两倍时长。数值越小越快。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } } HusSlider { Layout.fillWidth:true;Layout.minimumWidth:100;Layout.preferredHeight:32;Layout.minimumHeight:32;objectName:"setting_duration";min:80;max:600;stepSize:10;value:preferences.duration;onFirstReleased:preferences.duration=Math.round(currentValue) } }
                RowLayout {
                    Layout.fillWidth:true;Layout.margins:18
                    ColumnLayout { Layout.fillWidth:true;Layout.minimumWidth:0;spacing:4;HusText { text:"页面切换特效";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"选择页面的进入方式；滑移与缩放不会改变布局，不影响数据读取。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } }
                    HusSelect { model:[{label:"无",value:0},{label:"淡入",value:1},{label:"从右滑入",value:2},{label:"从左滑入",value:3},{label:"上移淡入",value:4},{label:"轻缩放进入",value:5},{label:"缩小归位",value:6},{label:"弹性上移",value:7}];textRole:"label";valueRole:"value";currentIndex:preferences.pageEffect;clearEnabled:false;defaultPopupMaxHeight:320;onActivated:preferences.pageEffect=currentValue }
                }
                RowLayout {
                    Layout.fillWidth:true;Layout.margins:18
                    ColumnLayout { Layout.fillWidth:true;Layout.minimumWidth:0;HusText { text:"运动曲线" } HusText { Layout.fillWidth:true;text:"柔和逐渐减速；利落收尾更快；匀缓首尾放慢；弹性带轻微回弹。";wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } }
                    HusSelect { model:[{label:"柔和",value:Easing.OutCubic},{label:"利落",value:Easing.OutQuint},{label:"匀缓",value:Easing.InOutCubic},{label:"弹性",value:Easing.OutBack}];textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:preferences.easingType===Easing.OutQuint?1:preferences.easingType===Easing.InOutCubic?2:preferences.easingType===Easing.OutBack?3:0;onActivated:preferences.easingType=currentValue }
                    HusButton { text:"预览过渡";enabled:preferences.motion;onClicked:preferences.previewPageEffect() }
                }
            }
        }
        MaterialCard {
            store:page.store
            visible:page.section===3;Layout.fillWidth:true;title:"窗口"
            bodyDelegate:ColumnLayout {
                width:parent.width;spacing:18
                RowLayout { Layout.fillWidth:true;Layout.margins:18;ColumnLayout { Layout.fillWidth:true;Layout.minimumWidth:0;spacing:4;HusText { text:"窗口置顶";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"开启后保持窗口在其他程序上方。默认关闭。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } } HusSwitch { checked:preferences.onTop;onClicked:preferences.onTop=checked } }
                RowLayout { Layout.fillWidth:true;Layout.margins:18;ColumnLayout { Layout.fillWidth:true;Layout.minimumWidth:0;spacing:4;HusText { text:"窗口效果";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"使用 Windows 提供的背景效果；不支持时自动回退普通背景。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } } HusSelect { model:[{label:"无",value:0},{label:"DWM 模糊",value:1},{label:"亚克力",value:2},{label:"云母",value:3},{label:"云母 Alt",value:4}];textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:preferences.windowEffect;defaultPopupMaxHeight:280;onActivated:preferences.windowEffect=currentValue } }
                HusText { visible:page.effectUnavailable;Layout.leftMargin:18;Layout.rightMargin:18;Layout.fillWidth:true;text:"当前系统不支持所选效果，已使用普通主题背景。";wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
                RowLayout { Layout.fillWidth:true;Layout.margins:18;ColumnLayout { Layout.preferredWidth:210;Layout.minimumWidth:140;Layout.maximumWidth:230;spacing:4;HusText { text:"窗口透明度";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap } HusText { text:"调整整个应用窗口，包括文字和按钮；建议保持 1。";Layout.fillWidth:true;Layout.minimumWidth:0;wrapMode:Text.Wrap;font.pixelSize:12;color:HusTheme.Primary.colorTextSecondary } } HusSlider { Layout.fillWidth:true;Layout.minimumWidth:100;Layout.preferredHeight:32;Layout.minimumHeight:32;objectName:"setting_windowOpacity";min:0.8;max:1;stepSize:0.02;value:preferences.windowOpacity;onFirstReleased:preferences.windowOpacity=currentValue } }
            }
        }
        MaterialCard {
            store:page.store
            visible:page.section===4;Layout.fillWidth:true;title:"MCP 与调试"
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
            visible:page.section===4;Layout.fillWidth:true;title:"版本与项目"
            bodyDelegate:ColumnLayout {
                width:parent.width;spacing:14
                HusText { Layout.margins:18;text:Backend.version+" · "+Backend.updateStatus;wrapMode:Text.Wrap }
                RowLayout { Layout.margins:18;HusButton { text:Backend.checking?"正在检查…":"检查更新";enabled:!Backend.checking;onClicked:Backend.checkUpdate() } HusButton { text:"GitHub 项目";onClicked:Backend.openUrl("https://github.com/127MU/SHODAN-Stat-Editor") } }
                HusText { Layout.margins:18;Layout.fillWidth:true;text:"游戏路径："+store.game;wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
            }
        }
    }
}
