import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Effects
import HuskarUI.Basic

HusWindow {
    id:window
    width:1480;height:960;minimumWidth:980;minimumHeight:680
    title:"SHODAN 数值编辑器 · "+Backend.version
    Workspace { id:workspace;cardMaterial:appearance.cardMaterial;cardBackdrop:backgroundLayer;cardMotion:appearance.motion;hoverEffects:appearance.hoverEffects;frostOpacity:appearance.frostOpacity;glassOpacity:appearance.glassOpacity;materialBlur:appearance.materialBlur;glassRefraction:appearance.glassRefraction;glassHighlight:appearance.glassHighlight }
    QtObject {
        id:appearance
        property bool restored:false
        property bool dark:Backend.setting("dark",false)
        property bool compact:Backend.setting("compact",false)
        property string cardMaterial:Backend.setting("cardMaterial","solid")
        property string backgroundMode:Backend.setting("backgroundMode","plain")
        property string backgroundImage:Backend.setting("backgroundImage","")
        property real backgroundOpacity:Backend.setting("backgroundOpacity",0.22)
        property string imageFit:Backend.setting("imageFit","cover")
        property string accent:Backend.setting("accent","#1677ff")
        property string themeMode:Backend.setting("themeMode","light")
        property bool motion:Backend.setting("motion",true)
        property int fontSize:Backend.setting("fontSize",16)
        property int radius:Backend.setting("radius",8)
        property int duration:Backend.setting("duration",160)
        property int pageEffect:Backend.setting("pageEffect",1)
        property int easingType:Backend.setting("easingType",Easing.OutCubic)
        property int windowEffect:Backend.setting("windowEffect",0)
        property bool onTop:Backend.setting("onTop",false)
        property real windowOpacity:Backend.setting("windowOpacity",1)
        property bool autoAccent:Backend.setting("autoAccent",false)
        property bool hoverEffects:Backend.setting("hoverEffects",true)
        property real frostOpacity:Backend.setting("frostOpacity",0.48)
        property real glassOpacity:Backend.setting("glassOpacity",0.18)
        property real materialBlur:Backend.setting("materialBlur",3)
        property real glassRefraction:Backend.setting("glassRefraction",0.095)
        property real glassHighlight:Backend.setting("glassHighlight",2.1)
        property var customAppearance:Backend.setting("customAppearance",null)
        property var previousAppearance:null
        readonly property var appearanceKeys:["dark","themeMode","accent","cardMaterial","fontSize","radius","motion","duration","pageEffect","easingType","autoAccent","hoverEffects","frostOpacity","glassOpacity","materialBlur","glassRefraction","glassHighlight"]
        function snapshot(){const out={};for(const key of appearanceKeys)out[key]=appearance[key];return out}
        function restore(values){
            if(!values)return
            restored=false
            for(const key of appearanceKeys)if(values[key]!==undefined)appearance[key]=values[key]
            restored=true
            for(const key of appearanceKeys)Backend.saveSetting(key,appearance[key])
            apply();updateAutoAccent()
        }
        function resetAppearance(){
            previousAppearance=snapshot()
            restore({dark:false,themeMode:"light",accent:"#1677ff",cardMaterial:"solid",fontSize:16,radius:8,motion:true,duration:160,pageEffect:1,easingType:Easing.OutCubic,autoAccent:false,hoverEffects:true,frostOpacity:0.48,glassOpacity:0.18,materialBlur:3,glassRefraction:0.095,glassHighlight:2.1})
        }
        function saveCustom(){customAppearance=snapshot();Backend.saveSetting("customAppearance",customAppearance)}
        function useCustom(){if(customAppearance){previousAppearance=snapshot();restore(customAppearance)}}
        function undo(){if(previousAppearance){const old=previousAppearance;previousAppearance=snapshot();restore(old)}}
        function previewPageEffect(){window.enterPage()}
        function updateAutoAccent(){if(restored && autoAccent && backgroundImage){const color=Backend.backgroundAccent(backgroundImage,HusTheme.isDark);if(color)accent=color}}
        function apply(){
            HusTheme.animationEnabled=false
            HusTheme.darkMode=themeMode==="system"?HusTheme.System:dark?HusTheme.Dark:HusTheme.Light
            const doc=JSON.parse(Backend.readText(":/HuskarUI/resources/theme/Index.json"))
            const vars=doc.__init__.__vars__
            vars.colorPrimaryBase="$genColor("+accent+")"
            vars.fontSizeBase="$genFontSize("+fontSize+")"
            vars.fontLineHeightBase="$genFontLineHeight("+fontSize+")"
            vars.fontFamilyBase="$genFontFamily('Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI', sans-serif)"
            vars.radiusBase="$genRadius("+radius+")"
            doc.__style__.durationFast=String(duration);doc.__style__.durationMid=String(duration*2);doc.__style__.durationSlow=String(duration*3)
            doc.__style__.fontPrimarySize="@fontSizeBase-2"
            doc.__style__.fontPrimaryHeight="$multiply(@fontSizeBase-2, @fontLineHeightBase-2)"
            const path=Backend.storeTheme(JSON.stringify(doc));if(path)HusTheme.installIndexTheme(path)
            Qt.callLater(function(){HusTheme.animationEnabled=appearance.motion;window.applyWindowEffect();appearance.updateAutoAccent()})
        }
        function save(key,v,refreshTheme){
            if(!restored)return
            Backend.saveSetting(key,v)
            if(refreshTheme)apply()
        }
        function setColorMode(mode){
            themeMode=mode
            if(mode!=="system")dark=mode==="dark"
        }
        onDarkChanged:{if(restored && themeMode!=="system")themeMode=dark?"dark":"light";save("dark",dark,true)}
        onCardMaterialChanged:save("cardMaterial",cardMaterial)
        onCompactChanged:save("compact",compact)
        onBackgroundModeChanged:save("backgroundMode",backgroundMode)
        onBackgroundImageChanged:{save("backgroundImage",backgroundImage);updateAutoAccent()}
        onBackgroundOpacityChanged:save("backgroundOpacity",backgroundOpacity)
        onImageFitChanged:save("imageFit",imageFit)
        onAccentChanged:save("accent",accent,true)
        onThemeModeChanged:{if(restored && (themeMode==="dark" || themeMode==="light"))dark=themeMode==="dark";save("themeMode",themeMode,true)}
        onMotionChanged:{save("motion",motion);HusTheme.animationEnabled=motion;if(restored && !motion)window.resetPageEntrance()}
        onFontSizeChanged:save("fontSize",fontSize,true)
        onRadiusChanged:save("radius",radius,true)
        onDurationChanged:save("duration",duration,true)
        onPageEffectChanged:save("pageEffect",pageEffect)
        onEasingTypeChanged:save("easingType",easingType)
        onWindowEffectChanged:{if(restored){save("windowEffect",windowEffect);Qt.callLater(window.applyWindowEffect)}}
        onOnTopChanged:if(restored){save("onTop",onTop);HusApi.setWindowStaysOnTopHint(window,onTop)}
        onWindowOpacityChanged:save("windowOpacity",windowOpacity)
        onAutoAccentChanged:{save("autoAccent",autoAccent);updateAutoAccent()}
        onHoverEffectsChanged:save("hoverEffects",hoverEffects)
        onFrostOpacityChanged:save("frostOpacity",frostOpacity)
        onGlassOpacityChanged:save("glassOpacity",glassOpacity)
        onMaterialBlurChanged:save("materialBlur",materialBlur)
        onGlassRefractionChanged:save("glassRefraction",glassRefraction)
        onGlassHighlightChanged:save("glassHighlight",glassHighlight)
        Component.onCompleted:{
            if(themeMode==="manual")themeMode=dark?"dark":"light"
            if(themeMode!=="system")dark=themeMode==="dark"
            restored=true
            apply()
            Qt.callLater(updateAutoAccent)
            Qt.callLater(function(){window.applyWindowEffect();HusApi.setWindowStaysOnTopHint(window,appearance.onTop)})
        }
    }
    property string progressText:""
    function resetPageEntrance(){pageEntrance.stop();pageLoader.opacity=1;pageShift.x=0;pageShift.y=0;pageLoader.entranceScale=1}
    function enterPage(){resetPageEntrance();if(appearance.motion && appearance.pageEffect!==0)pageEntrance.restart()}
    property var progressPercent:"auto"
    property string updateUrl:""
    property string updateVersion:""
    property string updateNotes:""
    property string updateDownloadUrl:""
    property bool effectUnavailable:false
    function applyWindowEffect(){
        if(!window.initialized || !appearance.restored)return
        window.setWindowMode(HusTheme.isDark)
        window.setSpecialEffect(HusWindow.None)
        effectUnavailable=appearance.windowEffect!==0 && !window.setSpecialEffect(appearance.windowEffect)
        if(effectUnavailable)window.setSpecialEffect(HusWindow.None)
    }
    onInitializedChanged:if(initialized)Qt.callLater(window.applyWindowEffect)
    opacity:appearance.windowOpacity
    property var searchOptions:{
        const categories={Primary:"主武器参数",Secondary:"副武器参数",Support:"支援武器参数",Throwables:"投掷物参数",Boosters:"强化增益",Stratagems:"战备参数",Mechas:"载具与机甲参数",Attachments:"武器配件",Records:"数据记录",Helldiver:"潜兵数值",ArmorWeight:"护甲类型参数",Terminids:"终结族参数",Automatons:"机器人参数",Illuminate:"光能族参数",SEAF:"超级地球部队参数",Spawning:"敌人生成参数"}
        const out=[];for(let tab of Object.keys(workspace.catalogs))for(let item of workspace.catalogs[tab]){
            if(searchDialog.onlyModified && !item.changed)continue
            const category=categories[tab] || tab
            out.push({label:(item.changed?"【已修改】 ":"")+"【"+category+"】 "+item.name,value:tab+":"+item.id,tab:tab,id:item.id,search:(item.search || item.name)+" "+category})
        }return out
    }
    function selectSearch(option){
        const module=({Primary:"equipment",Secondary:"equipment",Support:"equipment",Throwables:"equipment",Boosters:"equipment",Stratagems:"stratagem",Mechas:"vehicle",Attachments:"attachment",Records:"records",Helldiver:"player",ArmorWeight:"armor",Terminids:"enemy",Automatons:"enemy",Illuminate:"enemy",SEAF:"enemy",Spawning:"enemy"})[option.tab]
        workspace.openModule(module);workspace.setTab(option.tab);workspace.select((workspace.catalogs[option.tab] || []).find(x=>x.id===option.id));searchDialog.close()
    }
    property bool syncingNavigation:false
    property int navigationTicket:0
    function syncNavigation(){
        if(!Backend.ready || !navigationLoader.item){syncingNavigation=false;return}
        const ticket=++navigationTicket
        syncingNavigation=true
        navigationLoader.item.gotoMenu(workspace.module)
        // Menu delegates can complete during the next layout pass after resize.
        Qt.callLater(function(){if(ticket===window.navigationTicket)window.syncingNavigation=false})
    }
    property string locationTitle:workspace.module==="warproxy"?"变种":workspace.module==="home"?"首页":workspace.module==="settings"?"设置":workspace.module==="tweaks"?"游戏参数":workspace.module==="presets"?"全局预设":workspace.module==="mods"?"Mod 管理":workspace.destinations.find(x=>x.key===workspace.module)?.name || "工作台"
    function closeQaDialogs(){if(QaMode)armorDialog.close()}
    function qaOpenPresets(){if(QaMode)equipmentPresets.open()}
    function qaUpdatePreview(){
        if(!QaMode)return false
        workspace.updateFound("v99.0.0","https://github.com/127MU/SHODAN-Stat-Editor/releases/tag/v99.0.0","更新日志\n\n修复启动空白与被动勾选。\n新增同类条目分组。", "https://github.com/127MU/SHODAN-Stat-Editor/releases/download/v99.0.0/SHODAN_99.0.0.exe")
        return true
    }
    function qaCloseUpdate(){if(QaMode)updateDialog.close()}
    function qaSearchContext(){
        if(!QaMode)return false
        const matches=searchOptions.filter(x=>x.label.indexOf("类星体")>=0)
        return matches.some(x=>x.tab==="Support" && x.label.indexOf("支援武器参数")>=0) && matches.some(x=>x.tab==="Stratagems" && x.label.indexOf("战备参数")>=0)
    }
    function qaProjectilePreview(row){if(QaMode){choices(row);choiceDialog.query="120"}}
    function qaResourcePreview(row){if(QaMode){choices(row);choiceDialog.query="05656B4B5B893AB8"}}
    function qaResourceTranslated(){return choiceDialog.items.some(x=>x.raw==="05656B4B5B893AB8" && x.name.indexOf("固定重机枪")>=0)}
    function qaCloseChoices(){if(QaMode)choiceDialog.close()}
    function qaOpenModifiedSearch(){if(QaMode){searchDialog.onlyModified=true;searchDialog.open()}}
    function qaModifiedSearchValid(){return QaMode && window.searchOptions.length>0 && window.searchOptions.every(x=>x.label.startsWith("【已修改】"))}
    function qaCloseSearch(){if(QaMode)searchDialog.close()}
    function qaCatalogAligned(){
        if(!QaMode)return false
        function find(item){
            if(item.objectName==="groupedCatalog" && item.visible)return item.qaAligned()
            for(let child of item.children || []){const found=find(child);if(found!==null)return found}
            return null
        }
        return find(window.contentItem)===true
    }
    function qaClosePresets(){if(QaMode)equipmentPresets.close()}
    function qaSliderTest(){
        if(!QaMode || workspace.module!=="settings")return false
        pageLoader.item.section=1
        pageLoader.item.contentY=0
        return Backend.qaDrag("setting_backgroundOpacity")
    }
    function qaWheelTest(){
        if(!QaMode || workspace.module!=="settings")return false
        pageLoader.item.section=0
        pageLoader.item.contentY=0
        return Backend.qaWheel("settingsScroll")
    }
    function qaWheelMoved(){return QaMode && pageLoader.item.contentY>40}
    function qaSettingsSection(index){if(QaMode && workspace.module==="settings"){pageLoader.item.section=index;pageLoader.item.contentY=0;return true}return false}
    function qaGlassBound(){
        let found=false
        function visit(item){if(item.objectName==="__HusLiquidGlass__" && Math.abs(item.refraction-appearance.glassRefraction)<0.0001)found=true;for(const child of item.children || [])visit(child)}
        visit(window.contentItem);return found
    }
    function qaEntranceReset(){return pageLoader.opacity===1 && pageShift.x===0 && pageShift.y===0 && pageLoader.entranceScale===1}
    function qaGroupPopup(action){
        function find(item){if(item.objectName==="groupedCatalog" && item.visible)return item;for(const child of item.children || []){const hit=find(child);if(hit)return hit}return null}
        const list=find(window.contentItem)
        if(!QaMode || !list)return false
        if(action==="open")return list.qaOpen()
        if(action==="close"){list.qaClose();return true}
        return list.qaPopupStable()
    }
    function qaAppearanceSnapshot(){
        return {catalogColumns:workspace.catalogColumns,cardMaterial:appearance.cardMaterial,themeMode:appearance.themeMode,dark:appearance.dark,compact:appearance.compact,
            autoAccent:appearance.autoAccent,hoverEffects:appearance.hoverEffects,frostOpacity:appearance.frostOpacity,glassOpacity:appearance.glassOpacity,materialBlur:appearance.materialBlur,glassRefraction:appearance.glassRefraction,glassHighlight:appearance.glassHighlight,
            accent:appearance.accent,fontSize:appearance.fontSize,radius:appearance.radius,duration:appearance.duration,
            motion:appearance.motion,pageEffect:appearance.pageEffect,windowEffect:appearance.windowEffect,
            onTop:appearance.onTop,windowOpacity:appearance.windowOpacity,backgroundMode:appearance.backgroundMode,
            backgroundImage:appearance.backgroundImage,backgroundOpacity:appearance.backgroundOpacity,imageFit:appearance.imageFit}
    }
    function qaThemeTest(){
        if(!QaMode || !pageLoader.item)return false
        appearance.fontSize=18
        appearance.radius=10
        return parseInt(HusTheme.Primary.fontPrimarySize)===18 && parseInt(HusTheme.Primary.radiusPrimary)===10
    }
    function qaWindowEffectValid(requested){
        if(!QaMode)return false
        const supported=window.specialEffect===requested
        const fallback=effectUnavailable && window.specialEffect===HusWindow.None
        const surface=windowSurface.color
        return (supported || fallback) && surface.a>=0.75 && (HusTheme.isDark?surface.r<0.2:surface.r>0.7)
    }
    function focusOut(){content.forceActiveFocus()}
    property int qaWarningAccepted:0
    function qaShowExtraWarning(){if(QaMode){review.title="重复附赠警告测试";review.data={entries:[],warnings:["两个战备附赠同一战备，同时携带可能导致任务加载崩溃。是否仍然继续？"]};review.loading=false;review.action=()=>window.qaWarningAccepted++;review.open()}}
    function qaWarningCanContinue(){return QaMode && review.visible && review.confirmText==="仍然继续"}
    function message(title,text){info.title=title;info.description=String(text);info.open()}
    function preview(title,method,args,apply){
        focusOut();review.title=title;review.data={};review.loading=true;review.action=apply;review.open()
        workspace.call(method,args,x=>{review.data=x;review.loading=false},e=>{review.data={problems:[e]};review.loading=false})
    }
    function operate(action){
        workspace.busy=true;progress.title=action==="install"?"写入游戏":"恢复游戏原版";progressText="准备处理…";progressPercent="auto";progress.open()
        workspace.call(action,[],x=>{workspace.busy=false;progress.close();workspace.status=x;message("操作结果",x);workspace.refreshRows()},e=>{workspace.busy=false;progress.close();message("操作未完成",e)})
    }
    function choices(row){
        if(row.code){codeEditor.row=row;codeEditor.arrows=[];codeEditor.open();return}
        choiceDialog.row=row;choiceDialog.items=[];choiceDialog.query="";choiceDialog.open();workspace.call("choices",[row.id],x=>choiceDialog.items=x)
    }
    function selectChoice(row,item){
        if(row.choice_kind!=="resomode" && row.choice_kind!=="smmode"){
            workspace.call("choose",[row.id,item.id],x=>{workspace.status=x;choiceDialog.close();workspace.refreshRows()});return
        }
        choiceDialog.close()
        if(Number(item.id)===0)return
        residency.row=row;residency.mode=item.id
        residency.title=row.choice_kind==="smmode"?"确认修改状态机补丁（实验性功能）":"确认修改资源驻留补丁"
        residency.description="此操作会立即"+((row.choice_kind==="smmode"?Number(item.id)===2:Number(item.id)===3)?"移除":"写入")+"当前条目的资源驻留补丁（"+(item.name || item.label)+"）。请先关闭游戏，完成后重启游戏生效。"
        residency.open()
    }
    function shared(row){message("共享影响 · "+row.label,(row.shared || []).map(x=>typeof x==="string"?x:(x.name || x.equipment || JSON.stringify(x))).join("\n"))}
    function armorValues(passive){armorDialog.passive=passive;armorDialog.values=[];armorDialog.open();workspace.call("armor_rows",[passive.id],x=>armorDialog.values=x)}
    function importPreset(kind,id){
        let p=Backend.chooseFile(false,"SHODAN 预设 (*.txt);;所有文件 (*)");if(!p)return
        let text=Backend.readText(p);if(!text){message("无法导入","文件为空或无法读取");return}
        preview("导入预设前对比","preset_inspect",[kind,text],()=>workspace.call("preset_import",[kind,id,text],x=>{workspace.status=x.message;workspace.refreshPreset();workspace.refreshPresets()}))
    }
    function exportPreset(kind,id){workspace.call("preset_export",[kind,id],text=>{let p=Backend.chooseFile(true,"SHODAN 预设 (*.txt)");if(p && !Backend.writeText(p,text))message("导出失败","无法保存文件")})}
    function renamePreset(kind,id){nameDialog.callback=name=>workspace.call("preset_rename",[kind,id,name],()=>{workspace.refreshPreset();workspace.refreshPresets()});nameDialog.open()}
    function importMods(paths){if(paths.length)workspace.call("mods_import",[paths],x=>{workspace.mods=x.mods;workspace.status="已导入 "+x.count+" 个 Mod";if(x.errors)message("部分文件未导入",x.errors)})}
    Connections {
        target:workspace
        function onError(text){message("操作未完成",text)}
        function onUpdateFound(version,url,notes,downloadUrl){updateVersion=version;updateUrl=url;updateNotes=notes || "该发行版未提供更新日志。";updateDownloadUrl=downloadUrl || "";updateDialog.open()}
        function onOperationProgress(text,done,total){progressText=text;progressPercent=total>0?Math.round(done*100/total):"auto"}
        function onModuleChanged(){window.syncingNavigation=true;focusOut();Qt.callLater(window.syncNavigation)}
        function onLoaded(){Qt.callLater(window.syncNavigation)}
    }
    captionBar.height:42
    captionBar.winTitle:"SHODAN 数值编辑器"
    captionBar.winIcon:AssetRoot+"shodan.png"
    captionBar.winIconDelegate:Image { source:AssetRoot+"shodan.png";fillMode:Image.PreserveAspectFit;layer.enabled:HusTheme.isDark;layer.effect:MultiEffect { brightness:0.45 } }
    captionBar.showReturnButton:workspace.module!=="home"
    captionBar.returnCallback:function(){focusOut();if(workspace.screen==="editor")workspace.screen="catalog";else workspace.openModule("home")}
    captionBar.showThemeButton:true
    captionBar.showTopButton:true
    captionBar.topButtonChecked:appearance.onTop
    captionBar.topCallback:checked=>appearance.onTop=checked
    captionBar.themeCallback:function(){appearance.setColorMode(HusTheme.isDark?"light":"dark")}
    captionBar.winExtraButtonsDelegate:Row {
        height:window.captionBar.height;spacing:8
        Connections { target:window.captionBar;function onWindowAgentChanged(){window.captionBar.addInteractionItem(installButton);window.captionBar.addInteractionItem(restoreButton)} }
        HusButton { id:installButton;anchors.verticalCenter:parent.verticalCenter;text:"写入游戏";type:HusButton.Type_Primary;enabled:Backend.ready && !workspace.busy;onClicked:window.preview("写入游戏前预览","install_preview",[],()=>window.operate("install")) }
        HusButton { id:restoreButton;anchors.verticalCenter:parent.verticalCenter;text:"恢复原版";enabled:Backend.ready && !workspace.busy;onClicked:{review.title="恢复游戏原版";review.data={};review.loading=false;review.action=()=>operate("restore");review.open()} }
    }
    onClosing:event=>{focusOut();if(workspace.busy)event.accepted=false}
    Item {
        id:backgroundLayer
        anchors.fill:parent
    Rectangle {
        id:windowSurface
        objectName:"windowSurface"
        anchors.fill:parent
        color:HusThemeFunctions.alpha(HusTheme.Primary.colorBgBase,window.specialEffect===HusWindow.None?1:(HusTheme.isDark?0.82:0.78))
    }
    Loader { anchors.fill:parent;active:appearance.backgroundMode==="flow" && !QaMode;source:Qt.resolvedUrl("GalleryFlow.qml");opacity:appearance.backgroundOpacity }
    Image { anchors.fill:parent;visible:appearance.backgroundMode==="image";source:appearance.backgroundImage;fillMode:appearance.imageFit==="contain"?Image.PreserveAspectFit:appearance.imageFit==="stretch"?Image.Stretch:Image.PreserveAspectCrop;opacity:appearance.backgroundOpacity;asynchronous:true;cache:false }
    }
    Item {
        id:content
        anchors.fill:parent;anchors.topMargin:window.captionBar.height
        Item {
            id:rail
            width:appearance.compact?78:300
            anchors.left:parent.left;anchors.top:parent.top;anchors.bottom:parent.bottom
            Behavior on width { enabled:appearance.motion;NumberAnimation { duration:appearance.duration;easing.type:Easing.OutCubic } }
            ColumnLayout {
                anchors.fill:parent;anchors.margins:10;spacing:12
                RowLayout {
                    Layout.fillWidth:true;Layout.preferredHeight:72
                    HusIconText { iconSize:42;iconSource:AssetRoot+"shodan.png";layer.enabled:HusTheme.isDark;layer.effect:MultiEffect { brightness:0.45 } }
                    ColumnLayout { visible:!appearance.compact;HusText { text:"SHODAN";font.pixelSize:20;font.bold:true } HusText { text:Backend.version;color:HusTheme.Primary.colorTextSecondary;font.pixelSize:13 } }
                }
                HusAutoComplete {
                    Layout.fillWidth:true;visible:!appearance.compact
                    placeholderText:"搜索全部数据";iconSource:HusIcon.SearchOutlined
                    options:window.searchOptions;showToolTip:true;defaultPopupMaxHeight:340
                    filterOption:(input,option)=>!!input && option.search.toLowerCase().indexOf(input.toLowerCase().replace(/[-\s]/g,""))>=0
                    onSelect:option=>window.selectSearch(option)
                }
                HusIconButton { Layout.alignment:Qt.AlignHCenter;visible:appearance.compact;iconSource:HusIcon.SearchOutlined;onClicked:searchDialog.open() }
                Loader {
                    id:navigationLoader
                    active:Backend.ready
                    Layout.fillWidth:true;Layout.fillHeight:true;Layout.minimumWidth:0
                    sourceComponent:Component {
                    HusMenu {
                    id:menu
                    Component.onCompleted:contentItem.model=initModel
                    anchors.fill:parent
                    defaultMenuWidth:rail.width-20
                    compactMode:appearance.compact?HusMenu.Mode_Compact:HusMenu.Mode_Relaxed
                    compactWidth:58;showToolTip:true;enabled:Backend.ready && !workspace.busy
                    defaultSelectedKeys:workspace.module==="settings"?[]:[workspace.module]
                    initModel:[
                        {key:"home",label:"首页",iconSource:HusIcon.HomeOutlined},
                        {key:"editing",label:"数据编辑",iconSource:HusIcon.EditOutlined,menuChildren:[
                            {key:"equipment",label:"装备库",iconSource:HusIcon.AimOutlined},{key:"stratagem",label:"战略配备",iconSource:HusIcon.RocketOutlined},
                            {key:"vehicle",label:"载具与机甲",iconSource:HusIcon.CarOutlined},{key:"armor",label:"护甲组合",iconSource:HusIcon.SafetyOutlined},
                            {key:"player",label:"潜兵数值",iconSource:HusIcon.UserOutlined},{key:"enemy",label:"敌人",iconSource:HusIcon.BugOutlined},{key:"attachment",label:"配件",iconSource:HusIcon.ToolOutlined}]},
                        {key:"tweaks",label:"游戏参数",iconSource:HusIcon.SettingOutlined},
                        {key:"warproxy",label:"变种",iconSource:HusIcon.GlobalOutlined},
                        {key:"database",label:"数据与方案",iconSource:HusIcon.DatabaseOutlined,menuChildren:[{key:"records",label:"数据库",iconSource:HusIcon.DatabaseOutlined},{key:"presets",label:"全局预设",iconSource:HusIcon.FolderOpenOutlined}]}
                    ].concat(workspace.modsUnlocked?[{key:"mods",label:"Mod 管理",iconSource:HusIcon.AppstoreOutlined}]:[])
                    onClickMenu:(deep,key)=>{if(!window.syncingNavigation && key!=="editing" && key!=="database" && workspace.module!==key){focusOut();workspace.openModule(key)}}
                }
                    }
                }
                Item {
                    Layout.fillWidth:true
                    Layout.preferredHeight:appearance.compact?106:58
                    HusDivider { anchors.left:parent.left;anchors.right:parent.right;anchors.top:parent.top }
                    GridLayout {
                        anchors.fill:parent;anchors.topMargin:10
                        columns:appearance.compact?1:2;columnSpacing:4;rowSpacing:4
                        HusIconButton {
                            objectName:"settingsButton"
                            Layout.fillWidth:true;Layout.preferredHeight:44
                            type:HusButton.Type_Text
                            iconSource:HusIcon.SettingOutlined;iconSize:20
                            text:appearance.compact?"":"设置"
                            onClicked:{focusOut();workspace.openModule("settings")}
                            HusToolTip { visible:parent.hovered && appearance.compact;text:"设置" }
                        }
                        HusIconButton {
                            objectName:"sidebarToggle"
                            Layout.alignment:Qt.AlignHCenter|Qt.AlignVCenter
                            Layout.preferredWidth:40;Layout.minimumWidth:40;Layout.maximumWidth:40
                            Layout.preferredHeight:40;Layout.minimumHeight:40;Layout.maximumHeight:40
                            type:HusButton.Type_Text
                            leftPadding:8;rightPadding:8;topPadding:8;bottomPadding:8
                            iconSize:20
                            iconSource:appearance.compact?HusIcon.MenuUnfoldOutlined:HusIcon.MenuFoldOutlined
                            onClicked:appearance.compact=!appearance.compact
                            HusToolTip { visible:parent.hovered;text:appearance.compact?"展开导航栏":"收起导航栏" }
                        }
                    }
                }
            }
        }
        HusDivider { x:rail.width;y:0;height:parent.height;orientation:Qt.Vertical }
        Item {
            id:workArea
            clip:true
            anchors.left:rail.right;anchors.leftMargin:28;anchors.right:parent.right;anchors.rightMargin:28;anchors.top:parent.top;anchors.topMargin:20;anchors.bottom:footer.top;anchors.bottomMargin:16
            ColumnLayout {
                anchors.fill:parent;spacing:18
                HusBreadcrumb { Layout.fillWidth:true;initModel:[{title:"工作台",key:"home"},{title:locationTitle,key:workspace.module}].concat(workspace.screen==="editor"?[{title:workspace.current.name || "编辑",key:"editor"}]:[]) }
                Loader {
                    id:pageLoader;Layout.fillWidth:true;Layout.fillHeight:true;active:Backend.ready;clip:true
                    property real entranceScale:1
                    transform:[Translate { id:pageShift },Scale { origin.x:pageLoader.width/2;origin.y:pageLoader.height/2;xScale:pageLoader.entranceScale;yScale:pageLoader.entranceScale }]
                    sourceComponent:workspace.module==="warproxy"?warProxyPage:workspace.module==="home"?homePage:workspace.module==="settings"?settingsPage:workspace.module==="tweaks"?tweaksPage:workspace.module==="presets"?globalPresetsPage:workspace.module==="mods"?modsPage:workspace.screen==="editor"?editorPage:workspace.module==="armor"?armorPage:catalogPage
                    onLoaded:window.enterPage()
                    ParallelAnimation {
                        id:pageEntrance
                        NumberAnimation { target:pageLoader;property:"opacity";from:0;to:1;duration:appearance.duration*2;easing.type:Easing.OutCubic }
                        NumberAnimation { target:pageShift;property:"x";from:appearance.pageEffect===2?32:appearance.pageEffect===3?-32:0;to:0;duration:appearance.duration*2;easing.type:appearance.easingType }
                        NumberAnimation { target:pageShift;property:"y";from:appearance.pageEffect===4 || appearance.pageEffect===7?24:0;to:0;duration:appearance.duration*2;easing.type:appearance.pageEffect===7?Easing.OutBack:appearance.easingType }
                        NumberAnimation { target:pageLoader;property:"entranceScale";from:appearance.pageEffect===5?0.96:appearance.pageEffect===6?1.04:1;to:1;duration:appearance.duration*2;easing.type:appearance.easingType }
                    }
                }
                HusSpin { visible:!Backend.ready && !workspace.fatalError;Layout.alignment:Qt.AlignCenter;tip:"正在载入游戏数据…" }
                HusText { visible:!!workspace.fatalError;Layout.fillWidth:true;text:workspace.fatalError;wrapMode:Text.Wrap;color:HusTheme.Primary.colorError }
            }
        }
        HusFrame {
            id:footer
            anchors.left:rail.right;anchors.leftMargin:28;anchors.right:parent.right;anchors.rightMargin:28;anchors.bottom:parent.bottom;anchors.bottomMargin:10;height:46
            padding:10
            colorBg:HusThemeFunctions.onBackground(HusTheme.Primary.colorFillSecondary,HusTheme.Primary.colorBgBase)
            borderBg.color:HusTheme.Primary.colorBorder
            contentItem:RowLayout {
                HusIconText { iconSource:workspace.busy?HusIcon.LoadingOutlined:HusIcon.CheckCircleOutlined;iconSize:16;colorIcon:HusTheme.Primary.colorPrimary }
                HusText { text:workspace.status;elide:Text.ElideRight;color:HusTheme.Primary.colorTextPrimary;Layout.fillWidth:true;font.pixelSize:13 }
            }
        }
    }
    Component { id:homePage;HomePage { store:workspace } }
    Component { id:catalogPage;CatalogPage { store:workspace;onHiddenRequested:hidden.open() } }
    Component { id:editorPage;EditorPage { store:workspace;onChoose:row=>window.choices(row);onShared:row=>window.shared(row);onPresetsRequested:equipmentPresets.open() } }
    Component { id:armorPage;ArmorPage { store:workspace;onEditValues:p=>window.armorValues(p) } }
    Component { id:tweaksPage;GameTweaksPage { store:workspace } }
    Component { id:warProxyPage;WarProxyPage { store:workspace } }
    function qaWarProxy(action){return QaMode && workspace.module==="warproxy" && pageLoader.item?pageLoader.item.qa(action):false}
    Component { id:settingsPage;SettingsPage { store:workspace;preferences:appearance;effectUnavailable:window.effectUnavailable;onMessage:(title,text)=>window.message(title,text) } }
    HusModal {
        id:searchDialog;title:"搜索全部数据";width:620;modal:true;cancelText:"关闭";onCancel:close()
        property bool onlyModified:false
        onOpened:{for(const key of Object.keys(workspace.catalogs))workspace.refreshCatalog(key)}
        bodyDelegate:ColumnLayout {
            width:560;spacing:12
            HusCheckBox { objectName:"global_only_modified";text:"仅已修改";checked:searchDialog.onlyModified;onClicked:searchDialog.onlyModified=checked }
            HusAutoComplete { Layout.fillWidth:true;placeholderText:"名称 / 型号 / ID";iconSource:HusIcon.SearchOutlined;options:window.searchOptions;defaultPopupMaxHeight:360;showToolTip:true;filterOption:(input,option)=>(!!input || searchDialog.onlyModified) && option.search.toLowerCase().indexOf(input.toLowerCase().replace(/[-\s]/g,""))>=0;onSelect:option=>window.selectSearch(option) }
        }
    }
    Component {
        id:globalPresetsPage
        ColumnLayout {
            spacing:20
            RowLayout {
                Layout.fillWidth:true;HusText { text:"全局预设";font.pixelSize:30;font.bold:true;Layout.fillWidth:true }
                HusButton { text:"导入";onClicked:window.importPreset("full",0) }
                HusButton { objectName:"new_global_preset";text:"新建预设";type:HusButton.Type_Primary;onClicked:{nameDialog.callback=name=>workspace.call("full_preset",["new",0,name],()=>workspace.refreshPresets());nameDialog.open()} }
            }
            ListView {
                Layout.fillWidth:true;Layout.fillHeight:true;clip:true;spacing:16;model:workspace.presets;ScrollBar.vertical:HusScrollBar{}
                SmoothWheel { }
                delegate:MaterialCard {
                    store:workspace
                    required property var modelData;width:ListView.view.width-16;title:modelData.name;bodyDescription:modelData.count+" 项参数"
                    actionDelegate:Row {
                        padding:16;spacing:10
                        HusButton { text:"读取";type:HusButton.Type_Primary;onClicked:window.preview("读取预设前对比","preset_compare",["full",modelData.id],()=>workspace.call("full_preset",["load",modelData.id],x=>workspace.status=x)) }
                        HusButton { text:"覆盖保存";onClicked:workspace.call("full_preset",["save",modelData.id],()=>workspace.refreshPresets()) }
                        HusButton { text:"重命名";onClicked:renamePreset("full",modelData.id) }
                        HusButton { text:"导出";onClicked:exportPreset("full",modelData.id) }
                        HusButton { text:"删除";onClicked:workspace.call("full_preset",["delete",modelData.id],()=>workspace.refreshPresets()) }
                    }
                }
            }
        }
    }
    Component {
        id:modsPage
        ColumnLayout {
            RowLayout {
                Layout.fillWidth:true;HusText { text:"Mod 管理";font.pixelSize:30;font.bold:true;Layout.fillWidth:true }
                HusButton { text:"导入 ZIP";onClicked:window.importMods(Backend.chooseMods()) }
                HusButton { text:"合并 Mod 并导出";onClicked:{let p=Backend.chooseFile(true,"ZIP 压缩包 (*.zip)");if(p)workspace.call("mods_export",[p],x=>window.message("导出结果",x))} }
            }
            HusText { text:"开启的 Mod 与参数一起写入；关闭后重新写入即可移除。" }
            DropArea {
                Layout.fillWidth:true;Layout.fillHeight:true
                onDropped:event=>window.importMods(event.urls.map(x=>String(x).replace(/^file:\/\//,"")))
                ListView {
                    anchors.fill:parent;model:workspace.mods;spacing:16;clip:true;ScrollBar.vertical:HusScrollBar{}
                    SmoothWheel { }
                    delegate:MaterialCard {
                    store:workspace
                        id:modCard;required property var modelData;width:ListView.view.width-16;title:modelData.name
                        extraDelegate:HusSwitch { checked:modCard.modelData.enabled;onClicked:workspace.call("mods_update",[modCard.modelData.index,{enabled:checked}],x=>workspace.mods=x) }
                        bodyDelegate:ColumnLayout {
                            width:parent.width
                            HusText { Layout.fillWidth:true;Layout.margins:16;text:modCard.modelData.description;wrapMode:Text.Wrap }
                            Repeater {
                                model:modCard.modelData.options
                                RowLayout {
                                    required property int index;required property var modelData;Layout.fillWidth:true;Layout.margins:16
                                    HusText { text:modelData.name;Layout.fillWidth:true }
                                    HusSelect { model:modelData.choices;textRole:"label";valueRole:"value";defaultPopupMaxHeight:300;clearEnabled:false;currentIndex:modelData.choices.findIndex(c=>c.value===modelData.selected);onActivated:{let choices=modCard.modelData.options.map(x=>x.selected);choices[index]=currentValue;workspace.call("mods_update",[modCard.modelData.index,{choices:choices}],x=>workspace.mods=x)} }
                                }
                            }
                        }
                        actionDelegate:HusButton { text:"从管理列表移除";type:HusButton.Type_Text;onClicked:workspace.call("mods_remove",[modCard.modelData.index],x=>workspace.mods=x) }
                    }
                }
            }
        }
    }
    HusModal {
        id:residency;width:Math.min(680,window.width-100);title:"确认修改资源驻留补丁";modal:true;maskClosable:false
        property var row:({});property int mode:0
        confirmText:"确认";cancelText:"取消";onCancel:close()
        onConfirm:{
            close();workspace.busy=true;progress.title=row.choice_kind==="smmode"?"处理状态机补丁":"处理资源驻留补丁";progressText="正在处理，请稍候…";progressPercent="auto";progress.open()
            workspace.call("choose",[row.id,mode],x=>{workspace.busy=false;progress.close();workspace.status=x;window.message("操作结果",x);workspace.refreshRows()},e=>{workspace.busy=false;progress.close();window.message("操作未完成",e)})
        }
    }
    HusModal { id:info;width:Math.min(760,window.width-100);modal:true;cancelText:"关闭";onCancel:close() }
    HusModal {
        id:review;width:Math.min(1000,window.width-100);modal:true;maskClosable:false
        property var data:({});property bool loading:false;property var action:null
        confirmText:!loading && !(data.problems || []).length?((data.warnings || []).length?"仍然继续":"确认"):"";cancelText:"取消"
        confirmButtonDelegate:HusButton { objectName:"review_continue";text:review.confirmText;type:HusButton.Type_Primary;onClicked:review.confirm() }
        cancelButtonDelegate:HusButton { objectName:"review_cancel";text:review.cancelText;onClicked:review.cancel() }
        onConfirm:{close();if(action)action()}
        onCancel:close()
        bodyDelegate:ColumnLayout {
            width:review.width-48;spacing:14
            HusSpin { visible:review.loading;tip:"正在检查修改内容…" }
            HusText { Layout.fillWidth:true;text:(review.data.problems || []).join("\n");visible:!!text;wrapMode:Text.Wrap;color:HusTheme.Primary.colorError }
            Flickable {
                visible:(review.data.warnings || []).length>0
                Layout.fillWidth:true;Layout.preferredHeight:visible?Math.min(160,warningText.implicitHeight):0
                contentHeight:warningText.implicitHeight;clip:true;boundsBehavior:Flickable.StopAtBounds
                ScrollBar.vertical:HusScrollBar{}
                SmoothWheel{}
                HusText { id:warningText;width:parent.width-16;text:(review.data.warnings || []).join("\n");wrapMode:Text.Wrap;color:HusTheme.Primary.colorWarning }
            }
            HusText { text:"共 "+(review.data.entries || []).length+" 项变化 · 原值 → 待写入值" }
            ListView {
                Layout.fillWidth:true;Layout.preferredHeight:Math.min(420,(review.data.entries || []).length*66);model:review.data.entries || [];clip:true;spacing:8;ScrollBar.vertical:HusScrollBar{}
                SmoothWheel { }
                delegate:HusText { required property var modelData;width:ListView.view.width-16;height:58;text:modelData.equipment+" · "+modelData.parameter+"\n"+modelData.before+" → "+modelData.after;wrapMode:Text.Wrap }
            }
        }
    }
    HusModal {
        id:progress;width:600;modal:true;maskClosable:false;closable:false
        bodyDelegate:ColumnLayout { width:550;spacing:20;HusSpin { Layout.alignment:Qt.AlignHCenter;percent:window.progressPercent } HusText { Layout.fillWidth:true;text:window.progressText;wrapMode:Text.Wrap } }
    }
    HusModal {
        id:choiceDialog;width:Math.min(820,window.width-100);title:"选择条目";modal:true;cancelText:"关闭";onCancel:close()
        property var row:({});property var items:[];property string query:""
        bodyDelegate:ColumnLayout {
            width:choiceDialog.width-48;spacing:14
            HusInput { Layout.fillWidth:true;placeholderText:"名称 / ID";text:choiceDialog.query;clearEnabled:true;onTextEdited:choiceDialog.query=text }
            ListView {
                Layout.fillWidth:true;Layout.preferredHeight:420;clip:true;spacing:6;ScrollBar.vertical:HusScrollBar{}
                SmoothWheel { }
                model:choiceDialog.items.filter(x=>(String(x.name || x.label)+" "+(x.description || "")+" "+(x.raw || "")+" "+x.id).toLowerCase().indexOf(choiceDialog.query.toLowerCase())>=0)
                delegate:HusButton {
                    id:choiceButton
                    required property var modelData
                    enabled:!modelData.disabled
                    width:ListView.view.width-16
                    text:"#"+modelData.id+" · "+(modelData.name || modelData.label || "条目")
                    contentItem:ColumnLayout {
                        spacing:4
                        HusText {Layout.fillWidth:true;text:choiceButton.text;color:choiceButton.colorText;wrapMode:Text.Wrap}
                        HusText {Layout.fillWidth:true;visible:!!choiceButton.modelData.description;text:choiceButton.modelData.description || "";color:HusTheme.Primary.colorTextSecondary;wrapMode:Text.Wrap}
                    }
                    onClicked:window.selectChoice(choiceDialog.row,modelData)
                }
            }
        }
    }
    HusModal {
        id:armorDialog;width:Math.min(1000,window.width-100);modal:true;cancelText:"关闭";onCancel:close()
        property var passive:({});property var values:[]
        title:(passive.zh || passive.name || "护甲被动")+" · 数值"
        bodyDelegate:Flickable {
            width:armorDialog.width-48;implicitHeight:Math.max(100,Math.min(500,grid.implicitHeight));contentHeight:grid.implicitHeight;clip:true;ScrollBar.vertical:HusScrollBar{}
            SmoothWheel { }
            GridLayout {
                id:grid;width:parent.width-16;columns:width>620?2:1;rowSpacing:24;columnSpacing:28
                Repeater { model:armorDialog.values;FieldEditor { required property var modelData;Layout.fillWidth:true;Layout.margins:12;row:modelData;store:workspace;armor:true;passiveId:armorDialog.passive.id } }
            }
            HusEmpty { visible:armorDialog.values.length===0;anchors.centerIn:parent;description:"此被动没有可编辑数值" }
        }
    }
    HusDrawer {
        id:equipmentPresets;title:"当前装备预设";drawerSize:430
        contentDelegate:Flickable {
            clip:true;contentHeight:presetBody.implicitHeight+32
            boundsBehavior:Flickable.StopAtBounds
            ScrollBar.vertical:HusScrollBar{}
            SmoothWheel { }
            ColumnLayout {
                id:presetBody
                width:parent.width-32;x:16;y:16;spacing:14
                HusText { Layout.fillWidth:true;text:workspace.current.name || "";font.bold:true;wrapMode:Text.Wrap }
                HusSegmented { options:[{label:"1",value:1},{label:"2",value:2},{label:"3",value:3},{label:"4",value:4},{label:"5",value:5}];currentIndex:workspace.slot-1;onCurrentValueChanged:if(Backend.ready && currentValue && workspace.slot!==currentValue){workspace.slot=currentValue;workspace.refreshPreset()} }
                HusText { Layout.fillWidth:true;text:workspace.presetInfo.name || "空预设";wrapMode:Text.Wrap }
                GridLayout {
                    Layout.fillWidth:true;columns:2;rowSpacing:10;columnSpacing:10
                    HusButton { Layout.fillWidth:true;text:"保存";type:HusButton.Type_Primary;onClicked:workspace.call("preset",["save",workspace.slot],()=>workspace.refreshPreset()) }
                    HusButton { Layout.fillWidth:true;text:"读取";onClicked:window.preview("读取装备预设前对比","preset_compare",["weapon",workspace.slot],()=>workspace.call("preset",["load",workspace.slot],x=>{workspace.status=x;workspace.refreshRows()})) }
                    HusButton { Layout.fillWidth:true;text:"重命名";onClicked:renamePreset("weapon",workspace.slot) }
                    HusButton { Layout.fillWidth:true;text:"清除";onClicked:workspace.call("preset",["clear",workspace.slot],()=>workspace.refreshPreset()) }
                    HusButton { Layout.fillWidth:true;text:"导入";onClicked:importPreset("weapon",workspace.slot) }
                    HusButton { Layout.fillWidth:true;text:"导出";onClicked:exportPreset("weapon",workspace.slot) }
                }
            }
        }
    }
    HusModal {
        id:nameDialog;title:"预设名称";width:460;modal:true;confirmText:"保存";cancelText:"取消";property var callback:null
        property string inputValue:""
        function submit(){const value=inputValue.trim();if(callback && value){callback(value);close()}}
        confirmButtonDelegate:HusButton { objectName:"save_preset_name";text:nameDialog.confirmText;type:HusButton.Type_Primary;onClicked:nameDialog.confirm() }
        bodyDelegate:HusInput {
            id:presetNameInput;width:400;objectName:"preset_name_input";placeholderText:"输入预设名称";text:nameDialog.inputValue
            onTextChanged:nameDialog.inputValue=text
            onAccepted:nameDialog.submit()
            Connections { target:nameDialog;function onOpened(){nameDialog.inputValue="";presetNameInput.forceActiveFocus()} }
        }
        onConfirm:submit()
        onCancel:close()
    }
    HusModal {
        id:codeEditor;title:"战备指令";width:620;modal:true;confirmText:"保存";cancelText:"取消";property var row:({});property var arrows:[]
        bodyDelegate:ColumnLayout {
            width:560;spacing:20
            HusText { text:codeEditor.arrows.map(x=>["","↑","→","↓","←"][x]).join("  ");font.pixelSize:30 }
            RowLayout {
                Repeater { model:["↑","→","↓","←"];HusButton { required property int index;required property string modelData;text:modelData;onClicked:if(codeEditor.arrows.length<9)codeEditor.arrows=codeEditor.arrows.concat([index+1]) } }
                HusButton { text:"撤销";onClicked:codeEditor.arrows=codeEditor.arrows.slice(0,-1) }
                HusButton { text:"清空";onClicked:codeEditor.arrows=[] }
            }
        }
        onConfirm:workspace.call("code_set",[row.id,arrows],x=>{workspace.status=x;codeEditor.close();workspace.refreshRows()})
        onCancel:close()
    }
    HusModal {
        id:hidden;title:"开启隐藏功能？";description:"开启后显示 Mod 管理，可导入、合并和安装 ZIP Mod。";width:560;modal:true;confirmText:"开启";cancelText:"取消"
        onConfirm:{workspace.call("mods_unlock",[],()=>{workspace.modsUnlocked=true;workspace.openModule("mods")});close()}
        onCancel:close()
    }
    HusModal {
        id:updateDialog;title:"发现新版本 "+window.updateVersion;width:Math.min(760,window.width-80);modal:true;cancelText:"稍后再说"
        bodyDelegate:ColumnLayout {
            width:updateDialog.width-48;spacing:16
            HusText {text:"当前版本："+Backend.version;color:HusTheme.Primary.colorTextSecondary}
            Flickable {
                Layout.fillWidth:true;Layout.preferredHeight:Math.min(380,window.height*0.45)
                clip:true;contentHeight:releaseNotes.implicitHeight;boundsBehavior:Flickable.StopAtBounds
                ScrollBar.vertical:HusScrollBar{}
                SmoothWheel{}
                HusText {id:releaseNotes;objectName:"updateReleaseNotes";width:parent.width-16;text:window.updateNotes;wrapMode:Text.Wrap;textFormat:Text.PlainText}
            }
            RowLayout {
                Layout.fillWidth:true
                HusButton {text:"查看发行版";onClicked:Backend.openUrl(window.updateUrl)}
                Item {Layout.fillWidth:true}
                HusButton {objectName:"updateDirectDownload";text:"直接下载";type:HusButton.Type_Primary;enabled:window.updateDownloadUrl.length>0;onClicked:Backend.openUrl(window.updateDownloadUrl)}
            }
        }
        onCancel:close()
    }
    Loader { active:QaMode;source:Qt.resolvedUrl("QaRunner.qml");onLoaded:item.run(window,workspace,appearance) }
}
