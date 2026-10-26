import QtQuick
import HuskarUI.Basic
import "CatalogGroups.js" as CatalogGroups

Timer {
    id:qa
    property var window
    property var store
    property var preferences
    property int step:0
    property bool waiting:false
    property var row
    property real original:0
    property int inputRetries:0
    property bool flagOnly:Backend.setting("qaFlagReset",false)
    property bool flagStarted:false
    property var flagRow
    interval:850;repeat:true
    function run(w,s,p){window=w;store=s;preferences=p;start()}
    function ensure(ok,message){if(!ok)throw new Error(message)}
    function checkRows(expected){
        waiting=true
        store.call("rows",[],function(rows){try{const actual=rows.find(x=>x.id===qa.row.id).value;ensure(actual===expected,"输入没有保存：预期 "+expected+"，实际 "+actual);qa.waiting=false}catch(e){Backend.finishQa(String(e))}})
    }
    onTriggered:{
        if(!Backend.ready || waiting || Object.keys(store.callbacks).length)return
        try{
            if(flagOnly && !flagStarted){flagStarted=true;step=61}
            if(QaRestoreMode){
                const expected=JSON.parse(Backend.readText(QaDirectory+"/appearance.json"))
                const actual=window.qaAppearanceSnapshot()
                Backend.writeText(QaDirectory+"/restored-appearance.json",JSON.stringify(actual))
                ensure(JSON.stringify(actual)===JSON.stringify(expected),"重启后设置不一致")
                ensure(window.qaWindowEffectValid(expected.windowEffect),"重启后窗口效果未恢复")
                waiting=true
                store.call("full_presets",[],function(items){try{ensure(items.some(x=>x.name==="回车重命名测试"),"重启后全局预设丢失");Backend.finishQa("")}catch(e){Backend.finishQa(String(e))}})
                return
            }
            if(step===0){ensure(store.module==="home","默认没有显示首页");ensure(Backend.capture("01-home"),"首页截图失败");store.openModule("equipment")}
            else if(step===1){ensure(store.library.length>0,"装备库为空");Backend.capture("02-library");store.search="ar-11";ensure(store.library.length>0,"搜索无结果")}
            else if(step===2){Backend.capture("03-search");store.select(store.library[0])}
            else if(step===3){ensure(store.rows.length>0,"参数未载入");Backend.capture("04-editor");row=store.rows.find(x=>!x.flag&&!x.choice&&!x.code&&typeof x.value==="number");ensure(!!row,"没有数值字段");original=row.value;ensure(Backend.qaEdit("field_"+row.id,String(original+5),true),"未找到输入控件")}
            else if(step===4){checkRows(original+5)}
            else if(step===5){ensure(Backend.qaEdit("field_"+row.id,String(original+10),false),"无法失焦保存")}
            else if(step===6){checkRows(original+10)}
            else if(step===7){waiting=true;store.call("preset",["save",5],function(){store.call("preset_export",["weapon",5],function(text){try{ensure(text.indexOf("SHODAN-PRESET 1")===0,"预设导出失败");store.call("preset_import",["weapon",5,text],function(){qa.waiting=false})}catch(e){Backend.finishQa(String(e))}})})}
            else if(step===8){if(!Backend.qaEdit("field_"+row.id,"invalid",true)){ensure(++inputRetries<=4,"无法验证无效输入");return}}
            else if(step===9){checkRows(original+10)}
            else if(step===10){store.call("set",[row.id,String(original)]);store.call("preset",["clear",5]);store.openModule("vehicle")}
            else if(step===11){const groups=CatalogGroups.build(store.library,store.catalogs[store.tab] || [],store.tab);ensure(groups.some(x=>x.entries.length>1),"机甲关联条目未分组");ensure(CatalogGroups.build(store.catalogs.Primary,store.catalogs.Primary,"Primary").length===0,"武器不应分组");Backend.capture("05-vehicles");store.openModule("armor")}
            else if(step===12){ensure(store.armor.length>0,"护甲为空");ensure(Backend.qaCheck("passive_"+store.armor[0].id,true),"无法点击被动")}
            else if(step===13){ensure(store.armorProfile.enabled[String(store.armor[0].id)]===true,"被动 ID 映射未保留");ensure(Backend.qaCheck("passive_"+store.armor[0].id),"被动点击后未勾选");Backend.capture("06-armor");store.armorChange(store.armor[0].id,false,null,null);window.armorValues(store.armor[0])}
            else if(step===14){ensure(!store.armorProfile.enabled[String(store.armor[0].id)],"被动取消未保存");Backend.capture("07-armor-popup");window.closeQaDialogs();store.openModule("enemy");store.select(store.library[0])}
            else if(step===14){store.select(store.library[0])}
            else if(step===15){ensure(store.rows.length>0,"敌人参数为空");Backend.capture("08-enemy");store.openModule("settings")}
            else if(step===16){Backend.capture("09-settings");preferences.dark=true}
            else if(step===17){ensure(HusTheme.isDark && String(HusTheme.HusCard.colorBg)===String(HusTheme.Primary.colorBgBase),"深色卡片主题未同步");Backend.capture("10-dark");preferences.compact=true;window.width=1120;window.height=760;store.openModule("equipment")}
            else if(step===18){Backend.capture("11-small-library");store.openModule("presets");store.call("full_preset",["new",0,"Huskar 检查"],()=>store.refreshPresets())}
            else if(step===19){Backend.capture("12-presets");store.openModule("player")}
            else if(step===20){ensure(store.rows.length>0,"潜兵参数为空");Backend.capture("13-player");store.openModule("stratagem")}
            else if(step===21){store.select(store.library[0])}
            else if(step===22){ensure(store.rows.length>0,"战备参数为空");Backend.capture("14-stratagems");store.openModule("records")}
            else if(step===23){store.select(store.library[0])}
            else if(step===24){ensure(store.rows.length>0,"数据记录为空");Backend.capture("15-records");const path=Backend.qaBackground(AssetRoot+"shodan.png");ensure(!!path,"自定义图片未保存");preferences.backgroundImage=path;preferences.backgroundMode="image";preferences.backgroundOpacity=0.25;store.openModule("settings")}
            else if(step===25){Backend.capture("16-image-settings");ensure(window.qaSliderTest(),"无法拖动背景滑块");ensure(window.qaWheelTest(),"无法发送滚轮事件");preferences.accent="#722ed1"}
            else if(step===26){ensure(preferences.backgroundOpacity>=0.7,"滑块拖动没有提交数值");ensure(window.qaWheelMoved(),"滚轮没有滚动页面");Backend.capture("17-theme");Backend.toggleMcp()}
            else if(step===27){ensure(Backend.mcpEnabled,"MCP 未开启");Backend.toggleMcp()}
            else if(step===28){ensure(Backend.themeComponents().length>20,"主题组件清单不完整");store.openModule("settings")}
            else if(step===29){Backend.capture("18-appearance-settings");ensure(window.qaThemeTest(),"主题设置未生效")}
            else if(step===30){Backend.capture("19-theme-customized");preferences.backgroundMode="plain";preferences.themeMode="manual";preferences.dark=false;preferences.windowEffect=1}
            else if(step===31){ensure(window.qaWindowEffectValid(1),"模糊效果底色或回退异常");Backend.capture("20-window-blur");preferences.windowEffect=2}
            else if(step===32){ensure(window.qaWindowEffectValid(2),"亚克力底色或回退异常");Backend.capture("21-window-acrylic");preferences.windowEffect=3}
            else if(step===33){ensure(window.qaWindowEffectValid(3),"云母底色或回退异常");Backend.capture("22-window-mica");preferences.windowEffect=4}
            else if(step===34){ensure(window.qaWindowEffectValid(4),"云母 Alt 底色或回退异常");Backend.capture("23-window-mica-alt");preferences.windowEffect=0}
            else if(step===35){ensure(window.qaWindowEffectValid(0),"关闭窗口效果后底色异常");Backend.capture("24-window-solid");preferences.dark=true;preferences.windowEffect=2}
            else if(step===36){ensure(window.qaWindowEffectValid(2),"深色窗口效果异常");Backend.capture("25-window-dark");preferences.windowEffect=0}
            else if(step===37){preferences.windowEffect=1;store.openModule("equipment");store.setCatalogColumns(4)}
            else if(step===38){Backend.capture("32-library-four-columns");store.select(store.library[0])}
            else if(step===39){window.qaOpenPresets()}
            else if(step===40){Backend.capture("26-equipment-presets");window.qaClosePresets();store.openModule("tweaks")}
            else if(step===41){ensure(Object.keys(store.tweaks).length>0,"游戏参数未加载");Backend.capture("27-game-tweaks")}
            else if(step===42){preferences.backgroundMode="image";preferences.cardMaterial="frost";store.openModule("settings")}
            else if(step===43){Backend.capture("28-card-frost");preferences.cardMaterial="glass"}
            else if(step===44){Backend.capture("29-card-liquid-glass");preferences.setColorMode("light")}
            else if(step===45){ensure(window.qaWindowEffectValid(preferences.windowEffect),"开启材质后浅色效果异常");Backend.capture("30-card-light-glass");preferences.setColorMode("dark")}
            else if(step===46){ensure(window.qaWindowEffectValid(preferences.windowEffect),"切回深色效果异常");Backend.capture("31-card-dark-glass")}
            else if(step===47){preferences.compact=false;preferences.motion=false;store.openModule("home")}
            else if(step===48){Backend.capture("33-home-material");preferences.backgroundMode="flow"}
            else if(step===49){Backend.capture("34-flow-shader");preferences.backgroundMode="image";store.openModule("vehicle");store.search="EXO-45"}
            else if(step===50){const groups=CatalogGroups.build(store.library,store.catalogs[store.tab] || [],store.tab);ensure(groups.some(x=>x.entries.length>1),"搜索丢失关联条目");Backend.capture("35-expanded-vehicle-group");const arm=store.catalogs.Mechas.find(x=>(x.english || "").indexOf("EXO-55")===0 && (x.english || "").indexOf("Left arm")>=0);ensure(!!arm,"突破机甲左臂缺失");store.select(arm)}
            else if(step===51){const hp=store.rows.find(x=>x.label==="机臂生命值");ensure(!!hp && hp.original!==4294967295,"继承标记误作机臂默认生命值");Backend.capture("36-breakthrough-arm");const vehicle=store.catalogs.Mechas.find(x=>(x.english || "").indexOf("M-103")===0);ensure(!!vehicle,"M-103 缺失");store.select(vehicle)}
            else if(step===52){ensure(store.rows.some(x=>x.original===4294967295 && (x.inline_note || "").indexOf("不限")>=0),"无限次数缺少说明");Backend.capture("37-unlimited-uses");ensure(window.qaUpdatePreview(),"更新弹窗无法打开")}
            else if(step===53){Backend.capture("38-update-release-notes");window.qaCloseUpdate();ensure(window.qaSearchContext(),"搜索结果未区分武器与战备");store.openModule("equipment");store.select(store.library[0])}
            else if(step===54){const projectile=store.rows.find(x=>x.choice && !x.choice_kind);ensure(!!projectile,"射弹选项缺失");window.qaProjectilePreview(projectile)}
            else if(step===55){Backend.capture("39-projectile-context");window.qaCloseChoices();window.width=1480;window.height=960;store.setCatalogColumns(4);store.openModule("vehicle")}
            else if(step===56){ensure(store.module==="vehicle" && window.qaCatalogAligned(),"载具四列排列错位");Backend.capture("40-vehicle-four-columns-aligned");window.width=1120;window.height=760}
            else if(step===57){ensure(store.module==="vehicle" && window.qaCatalogAligned(),"窗口缩小后载具排列错位");Backend.capture("41-vehicle-resized-aligned");store.openModule("enemy")}
            else if(step===58){ensure(store.module==="enemy","导航同步意外改变当前页面");store.setTab("SEAF");store.setCatalogColumns(3)}
            else if(step===59){ensure(store.module==="enemy" && store.tab==="SEAF" && window.qaCatalogAligned(),"SEAF 最后一行排列错位");Backend.capture("42-seaf-last-row-aligned");window.width=1480;window.height=960}
            else if(step===60){ensure(store.module==="enemy" && store.tab==="SEAF" && window.qaCatalogAligned(),"窗口放大后排列错位");Backend.capture("43-seaf-resized-aligned");store.setCatalogColumns(4)}
            else if(step===61){store.openModule("equipment");store.select(store.library[0])}
            else if(step===62){flagRow=store.rows.find(x=>x.flag && typeof x.original==="number");ensure(!!flagRow,"没有开关字段");ensure(Backend.qaCheck("toggle_"+flagRow.id,true),"无法点击开关")}
            else if(step===63){waiting=true;store.call("rows",[],function(rows){try{ensure(rows.find(x=>x.id===qa.flagRow.id).value!==qa.flagRow.original,"开关修改未保存");ensure(Backend.qaCheck("toggle_"+qa.flagRow.id)!==(qa.flagRow.original>=0.5),"开关修改后界面状态错误");Backend.capture("44-flag-changed");ensure(Backend.qaCheck("reset_"+qa.flagRow.id,true),"无法点击恢复");qa.waiting=false}catch(e){Backend.finishQa(String(e))}})}
            else if(step===64){waiting=true;store.call("rows",[],function(rows){try{ensure(rows.find(x=>x.id===qa.flagRow.id).value===qa.flagRow.original,"恢复后后台仍是修改值");ensure(Backend.qaCheck("toggle_"+qa.flagRow.id)===(qa.flagRow.original>=0.5),"后台已恢复但开关界面未恢复");Backend.capture("45-flag-reset");ensure(Backend.writeText(QaDirectory+"/appearance.json",JSON.stringify(window.qaAppearanceSnapshot())),"无法保存设置验证快照");qa.waiting=false;if(qa.flagOnly)Backend.finishQa("")}catch(e){Backend.finishQa(String(e))}})}
            else if(step===65){store.openModule("stratagem");store.select(store.library[0])}
            else if(step===66){const resource=store.rows.find(x=>x.choice_kind==="package");ensure(!!resource,"资源包选择入口缺失");window.qaResourcePreview(resource)}
            else if(step===67){ensure(window.qaResourceTranslated(),"资源包选择缺少对照表中文名称");Backend.capture("46-resource-chinese");window.qaCloseChoices();store.openModule("presets")}
            else if(step===68){ensure(Backend.qaCheck("new_global_preset",true),"无法点击新建预设")}
            else if(step===69){ensure(Backend.qaEdit("preset_name_input","全局预设保存测试",false),"预设名称无法输入")}
            else if(step===70){ensure(Backend.qaCheck("save_preset_name",true),"无法点击预设保存")}
            else if(step===71){ensure(store.presets.some(x=>x.name==="全局预设保存测试"),"点击保存后全局预设未落盘");Backend.capture("47-global-preset-saved");window.renamePreset("full",store.presets.find(x=>x.name==="全局预设保存测试").id)}
            else if(step===72){ensure(Backend.qaEdit("preset_name_input","回车重命名测试",true),"预设回车无法提交")}
            else if(step===73){ensure(store.presets.some(x=>x.name==="回车重命名测试"),"回车重命名后预设未更新");Backend.capture("48-global-preset-renamed");window.qaShowExtraWarning()}
            else if(step===74){ensure(window.qaWarningCanContinue(),"警告仍在禁止继续");Backend.capture("49-extra-warning-choice");ensure(Backend.qaCheck("review_cancel",true),"警告取消按钮无法点击")}
            else if(step===75){ensure(window.qaWarningAccepted===0,"取消警告后仍应用操作");window.qaShowExtraWarning()}
            else if(step===76){ensure(Backend.qaCheck("review_continue",true),"警告继续按钮无法点击")}
            else if(step===77){ensure(window.qaWarningAccepted===1,"确认继续未执行操作");Backend.capture("50-extra-warning-confirmed");store.openModule("records")}
            else if(step===78){const arcs=store.library.filter(x=>String(x.id).startsWith("F4"));ensure(arcs.length===16,"电弧记录入口未覆盖全部 16 条");store.select(arcs.find(x=>x.id==="F40000000000000F"))}
            else if(step===79){ensure(store.rows.some(x=>x.flag && String(x.label).includes("电弧排除发射者")),"电弧排除发射者开关未显示");Backend.capture("51-arc-emitter-exclusion");store.openModule("equipment")}
            else if(step===80){store.select(store.library.find(x=>x.id==="D323DE60855898AC"))}
            else if(step===81){ensure(store.rows.filter(x=>String(x.label).startsWith("弹管 ") && x.original===8).length===2,"野炊两根弹管原值不是 8+8");ensure(store.rows.some(x=>String(x.inline_note || "").includes("8 + 8 = 16")),"双弹管总容量未显示");Backend.capture("52-cookout-dual-tubes");const p=store.rows.find(x=>x.projectile_source);store.call("choose",[p.id,220],()=>store.refreshRows())}
            else if(step===82){ensure(store.rows.some(x=>x.projectile_source && x.value===220),"射弹切换未更新");Backend.capture("53-projectile-current-source");ensure(Backend.qaCheck("restore_projectile",true),"恢复原配射弹按钮无法点击")}
            else if(step===83){ensure(store.rows.some(x=>x.projectile_source && x.value===352 && !x.projectile_conflict),"恢复原配射弹未恢复野炊引用");Backend.capture("54-projectile-restored")}
            else if(step===84){const field=store.rows.find(x=>!x.choice && !x.flag && !x.code && typeof x.value==="number" && x.value===x.original);ensure(!!field,"修改筛选测试缺少数值字段");row=field;store.call("set",[field.id,field.value+1],()=>store.refreshRows())}
            else if(step===85){store.screen="catalog"}
            else if(step===86){ensure(Backend.qaCheck("catalog_only_modified",true),"无法开启仅已修改筛选")}
            else if(step===87){ensure(store.catalogOnlyModified && store.library.length>0 && store.library.every(x=>x.changed),"分类列表混入未修改条目");store.search="野炊"}
            else if(step===88){ensure(store.library.some(x=>x.id==="D323DE60855898AC") && store.library.every(x=>x.changed),"名称搜索与修改筛选不兼容");Backend.capture("55-modified-catalog-search");store.catalogOnlyModified=false;window.qaOpenModifiedSearch()}
            else if(step===89){ensure(window.qaModifiedSearchValid(),"全局搜索未按已修改筛选");Backend.capture("56-modified-global-search");window.qaCloseSearch();waiting=true;store.call("reset",[row.id],()=>{Backend.finishQa("")})}
            step++
        }catch(e){Backend.finishQa(String(e))}
    }
}
