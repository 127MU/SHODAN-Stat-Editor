import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HuskarUI.Basic

Flickable {
    id:page;required property var store
    objectName:"warProxyPage";clip:true;contentHeight:body.implicitHeight+24;boundsBehavior:Flickable.StopAtBounds
    ScrollBar.vertical:HusScrollBar{}
    SmoothWheel{}
    property int section:0
    property int planet:Number(Backend.setting("warPlanet",182))
    property string effects:String(Backend.setting("warEffects",""))
    property int owner:0
    property bool targetEnabled:true
    property bool campaign:false
    property int campaignType:0
    property int campaignRace:0
    property string planetQuery:""
    property string effectQuery:""
    property string category:"all"
    property bool selectedOnly:false
    property bool advanced:false
    readonly property var effectRows:WarProxyBackend.effects
    readonly property var planetRows:WarProxyBackend.planets
    property bool dirty:false
    property bool observeRequest:false
    property string localError:""
    property bool uiReady:false
    property var qaEditorItem:null
    property var editorInstance:null
    function filteredPlanets(){const q=planetQuery.trim().toLowerCase();return planetRows.filter(x=>!q || (x.name+" "+(x.native || "")+" "+x.id).toLowerCase().includes(q))}
    property var selectedEffects:parseEffects() || []
    function parseEffects(){
        const tokens=effects.trim()?effects.split(/[,，;；\s]+/).filter(x=>x.length):[]
        if(tokens.some(x=>!/^\d+$/.test(x) || Number(x)<1 || Number(x)>2147483647))return null
        return [...new Set(tokens.map(Number))]
    }
    function planetName(id){const p=planetRows.find(x=>Number(x.id)===Number(id));return p?p.name:"星球 #"+id}
    function effectName(id){const e=effectRows.find(x=>Number(x.id)===Number(id));return e?e.name:"效果 #"+id}
    function loadTarget(t){planet=Number(t.planet);effects=(t.effects || []).join(", ");owner=Number(t.owner || 0);campaign=!!t.campaign;campaignType=Number(t.campaign_type || 0);campaignRace=Number(t.campaign_race || 0);targetEnabled=t.enabled!==false;dirty=false;localError=""}
    function choosePlanet(id){const t=WarProxyBackend.targets.find(x=>Number(x.planet)===Number(id));if(t)loadTarget(t);else{planet=Number(id);effects="";owner=0;campaign=false;campaignType=0;campaignRace=0;targetEnabled=true;dirty=true}}
    function toggleEffect(id){let ids=parseEffects() || [];ids=ids.includes(id)?ids.filter(x=>x!==id):ids.concat([id]);effects=ids.join(", ");dirty=true}
    function saveCurrent(){
        const ids=parseEffects();if(ids===null){localError="效果 ID 必须是正整数，多个用逗号隔开。";return false}
        const ok=WarProxyBackend.saveTarget(JSON.stringify({planet:planet,effects:ids,enabled:targetEnabled,owner:owner,campaign:campaign,campaign_type:campaignType,campaign_race:campaignRace}))
        if(ok){dirty=false;localError="";Backend.saveSetting("warPlanet",planet);Backend.saveSetting("warEffects",effects)}return ok
    }
    function requestEnable(observe){if(!observe && dirty && !saveCurrent())return;observeRequest=observe;enableDialog.open()}
    function qa(action){if(!QaMode)return false;if(action==="advanced"){advanced=true;return true}if(action==="planetSearchOpen"){section=0;planetQuery="";planetDialog.open();return true}if(action==="planetSearchCheck"){const unchanged=planet===93;const english=planetQuery==="lesath" && filteredPlanets().some(p=>Number(p.id)===194);planetQuery="尾宿八";const chinese=filteredPlanets().some(p=>Number(p.id)===194);planetQuery="194";const numeric=filteredPlanets().some(p=>Number(p.id)===194);planetDialog.close();planetQuery="";return unchanged && english && chinese && numeric}if(action==="catalog"){section=0;effectQuery="1373";effectDialog.open();return WarProxyBackend.effects.length>=70 && WarProxyBackend.planets.length>=273}if(action==="selected")return selectedEffects.includes(1373);if(action==="save")return saveCurrent();if(action==="editorCached")return editorInstance===qaEditorItem;if(action==="editor"){section=0;return true}if(action==="connection"){qaEditorItem=editorInstance;effectDialog.close();section=2;return true}return false}
    Component.onCompleted:{if(WarProxyBackend.targets.length)loadTarget(WarProxyBackend.targets[0]);uiReady=true}
    Connections { target:WarProxyBackend;function onTargetsChanged(){if(!page.dirty){const t=WarProxyBackend.targets.find(x=>Number(x.planet)===page.planet);if(t)page.loadTarget(t)}} }
    onSectionChanged:contentY=0
    ColumnLayout {
        id:body;x:6;width:page.width-24;spacing:16
        RowLayout {
            Layout.fillWidth:true
            ColumnLayout { Layout.fillWidth:true;HusText { text:"变种工作区";font.pixelSize:28;font.bold:true } HusText { Layout.fillWidth:true;wrapMode:Text.Wrap;text:"选择星球 → 配置效果 → 保存方案 → 开启代理并从 Steam 启动 · 实验性";color:HusTheme.Primary.colorTextSecondary } }
            HusText { text:WarProxyBackend.active?(WarProxyBackend.pluginReady?"代理已就绪":"代理初始化中"):"已关闭" }
            HusSwitch { objectName:"warProxySwitch";checked:WarProxyBackend.active;enabled:!WarProxyBackend.busy;onClicked:{checked=Qt.binding(function(){return WarProxyBackend.active});if(WarProxyBackend.active)WarProxyBackend.stop();else page.requestEnable(false)} }
        }
        HusText { Layout.fillWidth:true;text:page.section===2?WarProxyBackend.status:page.dirty?"当前方案有未保存的修改。保存后才会应用到后续战况。":WarProxyBackend.active?"代理正在运行；修改方案后保存即可应用到下一次战况刷新。":"代理已关闭。首次使用请先到连接设置完成证书和 Steam 启动选项配置。";wrapMode:Text.Wrap }
        HusSegmented { options:[{label:"编辑方案",value:0},{label:"已保存方案",value:1},{label:"连接设置",value:2}];currentIndex:page.section;onCurrentValueChanged:if(page.uiReady && currentValue!==undefined)page.section=Number(currentValue) }
        HusText { visible:page.section===2;Layout.fillWidth:true;wrapMode:Text.Wrap;text:WarProxyBackend.captureMode==="proxy"?"Steam 兼容模式：首次复制桥接启动选项，粘贴到 Steam 游戏属性中。此后从 Steam 正常启动即可；代理端口变化无需重新粘贴。未开启代理时按原始命令启动游戏。":"实验性进程捕获：等待捕获服务真正就绪后再启动游戏。初始化失败会超时停止。";color:HusTheme.Primary.colorTextSecondary }
        Flow { visible:page.section===2;Layout.fillWidth:true;spacing:10
            HusButton { text:"复制 Steam 启动选项";onClicked:{if(WarProxyBackend.copySteamLaunchOptions())steamDialog.open()} }
            HusButton { text:"通过 Steam 启动游戏";enabled:WarProxyBackend.active && WarProxyBackend.pluginReady && WarProxyBackend.certificateTrusted;onClicked:steamDialog.open() }
        }
        HusText { visible:WarProxyBackend.captureMode==="proxy" && !!WarProxyBackend.launchStatus;Layout.fillWidth:true;wrapMode:Text.Wrap;text:WarProxyBackend.launchStatus;color:HusTheme.Primary.colorTextSecondary }
        MaterialCard {
            visible:page.section===1;store:page.store;Layout.fillWidth:true;title:"已保存的星球方案"
            bodyDelegate:Loader {
                width:parent.width;property bool loadedOnce:false;asynchronous:true;active:parent.visible || loadedOnce;onLoaded:loadedOnce=true
                sourceComponent:ColumnLayout {
                width:parent.width;spacing:10
                Flow { Layout.fillWidth:true;Layout.margins:16;spacing:10
                    HusButton { text:"新建星球方案";onClicked:{const p=planetRows.find(p=>!WarProxyBackend.targets.some(t=>Number(t.planet)===Number(p.id)));if(p){page.choosePlanet(p.id);page.section=0}} }
                    HusButton { text:"导入";onClicked:WarProxyBackend.importTargets() }
                    HusButton { text:"导出全部";onClicked:WarProxyBackend.exportTargets() }
                    HusButton { text:"撤销上次保存";onClicked:WarProxyBackend.restoreBackup() }
                    HusButton { text:"仅转发并采集目录";enabled:!WarProxyBackend.active && !WarProxyBackend.busy;onClicked:page.requestEnable(true) }
                }
                HusText { visible:!WarProxyBackend.targets.length;Layout.fillWidth:true;Layout.margins:16;text:"暂无方案。可以先采集在线目录，再按名称选择星球和效果。";wrapMode:Text.Wrap }
                Repeater { model:WarProxyBackend.targets
                    RowLayout { required property var modelData;Layout.fillWidth:true;Layout.leftMargin:16;Layout.rightMargin:16;Layout.bottomMargin:8
                        HusSwitch { checked:modelData.enabled;enabled:!WarProxyBackend.busy;onClicked:{const t=Object.assign({},modelData);t.enabled=checked;WarProxyBackend.saveTarget(JSON.stringify(t))} }
                        HusText { Layout.fillWidth:true;text:page.planetName(modelData.planet)+" · #"+modelData.planet+" · "+modelData.effects.length+" 个效果"+(modelData.owner?" · 阵营覆盖":"")+(modelData.campaign?" · 战役覆盖":"");wrapMode:Text.Wrap }
                        HusButton { text:"编辑";onClicked:{page.loadTarget(modelData);page.section=0} }
                        HusButton { text:"删除";onClicked:WarProxyBackend.removeTarget(modelData.planet) }
                    }
                }
                HusText { Layout.fillWidth:true;Layout.margins:16;text:"关闭方案后不会写入后续战况。已在游戏里缓存的效果需要重新登录清除。保存时会保留上一份配置备份。";wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
            }
            }
        }
        MaterialCard {
            visible:page.section===0;store:page.store;Layout.fillWidth:true;title:"当前星球 · "+page.planetName(page.planet)
            bodyDelegate:Loader {
                id:editorFormLoader
                width:parent.width;property bool loadedOnce:false;asynchronous:true;active:parent.visible || loadedOnce;onLoaded:{loadedOnce=true;page.editorInstance=item}
                sourceComponent:ColumnLayout {
                width:parent.width;spacing:12
                HusButton { Layout.fillWidth:true;Layout.margins:16;text:page.planetName(page.planet)+" · #"+page.planet+"　选择 / 搜索星球";onClicked:planetDialog.open() }
                RowLayout { Layout.fillWidth:true;Layout.leftMargin:16;Layout.rightMargin:16
                    HusText { text:"游戏索引" }
                    HusInput { objectName:"warPlanet";Layout.fillWidth:true;text:String(page.planet);onEditingFinished:{const n=Number(text);if(Number.isInteger(n)&&n>=0&&n<=10000){if(page.planet!==n){page.planet=n;page.dirty=true}}else text=String(page.planet)} }
                    HusCheckBox { text:"启用此星球方案";checked:page.targetEnabled;onClicked:{page.targetEnabled=checked;page.dirty=true} }
                }
                HusText { Layout.fillWidth:true;Layout.leftMargin:16;Layout.rightMargin:16;text:"已选择 "+page.selectedEffects.length+" 个效果："+page.selectedEffects.map(page.effectName).join("、");wrapMode:Text.Wrap }
                Flow { Layout.fillWidth:true;Layout.margins:16;spacing:10
                    HusButton { text:"选择 / 搜索效果";onClicked:effectDialog.open() }
                    HusButton { text:"清空效果";onClicked:{page.effects="";page.dirty=true} }
                }
                HusText { visible:page.advanced;Layout.leftMargin:16;text:"效果 ID（高级输入，可留空）" }
                HusInput { visible:page.advanced;objectName:"warEffects";Layout.fillWidth:true;Layout.leftMargin:16;Layout.rightMargin:16;text:page.effects;onTextEdited:{page.effects=text;page.dirty=true} }
                HusCheckBox { Layout.leftMargin:16;text:"高级设置：效果 ID、阵营与战役";checked:page.advanced;onClicked:page.advanced=checked }
                HusText { visible:page.advanced;Layout.leftMargin:16;text:"星球归属与默认阵营（实验性）" }
                HusSelect { visible:page.advanced;Layout.fillWidth:true;Layout.leftMargin:16;Layout.rightMargin:16;textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:page.owner
                    model:[{label:"保持原始归属与敌人阵营",value:0},{label:"超级地球归属（不强制改变作战敌人）",value:1},{label:"终结族",value:2},{label:"机器人",value:3},{label:"光能族",value:4}]
                    onActivated:{page.owner=Number(currentValue);page.dirty=true}
                }
                RowLayout { visible:page.advanced;Layout.fillWidth:true;Layout.leftMargin:16;Layout.rightMargin:16
                    HusCheckBox { text:"开放该星球并覆盖战役类型（实验性）";checked:page.campaign;onClicked:{page.campaign=checked;page.dirty=true} }
                    HusSelect { Layout.fillWidth:true;enabled:page.campaign;textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:page.campaignType
                        model:[{label:"常规解放",value:0},{label:"侦察战役",value:1},{label:"高优先级战役",value:2},{label:"超级地球保卫战形态",value:3}]
                        onActivated:{page.campaignType=Number(currentValue);page.dirty=true}
                    }
                }
                RowLayout { visible:page.advanced && page.campaign;Layout.fillWidth:true;Layout.leftMargin:16;Layout.rightMargin:16
                    HusText { text:"作战敌人" }
                    HusSelect { objectName:"warCampaignRace";Layout.fillWidth:true;textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:page.campaignRace
                        model:[{label:"自动：保留原阵营或已确认的原生敌情",value:0},{label:"超级地球（实验性）",value:1},{label:"终结族",value:2},{label:"机器人",value:3},{label:"光能族",value:4}]
                        onActivated:{page.campaignRace=Number(currentValue);page.dirty=true}
                    }
                }
                HusText { visible:page.advanced;Layout.fillWidth:true;Layout.margins:16;text:"星球开放可能让客户端向线上服务器创建作战；奖励与归属统计尚未确认。此处没有防守事件注入，战役类型也不能替代防守事件。";wrapMode:Text.Wrap;color:HusTheme.Primary.colorWarning }
                HusText { Layout.fillWidth:true;Layout.leftMargin:16;Layout.rightMargin:16;text:"已核实的星图标记 / 玩法词条配对会一起应用到同一星球；图标、文案效果不等同于新任务。保存后需等游戏下一次战况刷新，已生成的作战不会立即重建。";wrapMode:Text.Wrap }
                HusText { Layout.fillWidth:true;Layout.leftMargin:16;Layout.rightMargin:16;text:page.localError;visible:!!text;wrapMode:Text.Wrap;color:HusTheme.Primary.colorError }
                Flow { Layout.fillWidth:true;Layout.margins:16;spacing:10
                    HusButton { type:HusButton.Type_Primary;text:WarProxyBackend.active?"保存并应用":"保存方案";onClicked:page.saveCurrent() }
                    HusButton { text:"保存并开启代理";enabled:!WarProxyBackend.active && !WarProxyBackend.busy;onClicked:{if(page.saveCurrent())page.requestEnable(false)} }
                    HusButton { text:"启动游戏（Steam）";enabled:WarProxyBackend.active && WarProxyBackend.pluginReady && WarProxyBackend.certificateTrusted;onClicked:steamDialog.open() }
                }
            }
            }
        }
        HusModal {
            id:effectDialog;width:Math.min(900,page.width-30);modal:true;title:"添加效果 · 已选择 "+page.selectedEffects.length+" 项";confirmText:"完成选择";cancelText:"关闭";onConfirm:close();onCancel:close()
            bodyDelegate:Loader {
                width:parent.width;active:effectDialog.visible
                sourceComponent:ColumnLayout {
                width:parent.width;spacing:12
                HusText { Layout.fillWidth:true;Layout.margins:16;text:WarProxyBackend.catalogFresh?"来自本次游戏连接的完整目录。未测试组合仍标为实验性。":"当前显示研究快照或上次缓存。启动采集并重新登录游戏后，会用本次完整目录替换；缓存不会用于放行未知效果。";wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
                RowLayout { Layout.fillWidth:true;Layout.leftMargin:16;Layout.rightMargin:16
                    HusCheckBox { Layout.alignment:Qt.AlignVCenter;text:"仅显示已选";checked:page.selectedOnly;onClicked:page.selectedOnly=checked }
                    HusInput { Layout.fillWidth:true;placeholderText:"搜索效果名称 / 原名 / ID";text:page.effectQuery;clearEnabled:true;onClickClear:page.effectQuery="";onTextEdited:page.effectQuery=text }
                    HusSelect { textRole:"label";valueRole:"value";clearEnabled:false;currentIndex:0;model:[{label:"全部",value:"all"},{label:"变种与敌情",value:"71"},{label:"星图词条",value:"40"},{label:"临时战备",value:"32"},{label:"临时装备",value:"36"}];onActivated:page.category=String(currentValue) }
                }
                ListView {
                    Layout.fillWidth:true;Layout.preferredHeight:Math.min(340,Math.max(110,count*90));Layout.leftMargin:16;Layout.rightMargin:16;clip:true;spacing:8;boundsBehavior:Flickable.StopAtBounds
                    model:effectRows.filter(e=>(!page.selectedOnly || page.selectedEffects.includes(Number(e.id))) && (page.category==="all" || String(e.effectType)===page.category) && (!page.effectQuery.trim() || (e.name+" "+(e.native || "")+" "+(e.aliases || []).join(" ")+" "+e.id).toLowerCase().includes(page.effectQuery.trim().toLowerCase())))
                    ScrollBar.vertical:HusScrollBar{}
                    SmoothWheel{}
                    delegate:ColumnLayout {
                        required property var modelData;width:ListView.view.width-16;spacing:3
                        HusCheckBox { objectName:"warEffect_"+modelData.id;Layout.fillWidth:true;text:modelData.name+" · #"+modelData.id;checked:page.selectedEffects.includes(Number(modelData.id));onClicked:page.toggleEffect(Number(modelData.id)) }
                        HusText { Layout.fillWidth:true;text:modelData.category+" · "+(modelData.experimental?"实验性，未实测":"上游有实测记录，本机仍需验证")+(modelData.cached?" · 研究快照":"")+" · "+(modelData.translation_source || "中文名待核对");font.pixelSize:13;wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
                        HusText { visible:!!modelData.description;Layout.fillWidth:true;text:modelData.description || "";font.pixelSize:13;wrapMode:Text.Wrap }
                        HusText { visible:!!modelData.reference_note && modelData.reference_note!==modelData.name;Layout.fillWidth:true;text:"对照表备注："+(modelData.reference_note || "");font.pixelSize:13;wrapMode:Text.Wrap }
                        HusDivider { Layout.fillWidth:true }
                    }
                }

            }
            }
        }
        MaterialCard {
            visible:page.section===2;store:page.store;Layout.fillWidth:true;title:"内置代理与证书"
            bodyDelegate:Loader {
                width:parent.width;property bool loadedOnce:false;asynchronous:true;active:parent.visible || loadedOnce;onLoaded:loadedOnce=true
                sourceComponent:ColumnLayout {
                width:parent.width;spacing:12
                HusText { Layout.fillWidth:true;Layout.margins:16;text:"代理与变种开关联动，默认关闭。仅游戏 API 域名的 443 端口进入变种代理，其他 HTTPS 目标通过本机分流器直连，不解密、不经变种上游。Steam 桥接只给游戏进程设置代理环境，保留 Steam 原始启动命令；既有 HTTP 代理上游仅用于游戏 API，不改系统代理或 hosts。关闭变种后退出并重启游戏即可恢复普通连接，也可删除 Steam 中的桥接启动选项。";wrapMode:Text.Wrap }
                HusText { Layout.fillWidth:true;Layout.leftMargin:16;Layout.rightMargin:16;wrapMode:Text.Wrap;text:"连接方式：HTTP 代理 + Steam 启动桥接。本版本不包含网络捕获驱动。" }
                HusText { Layout.fillWidth:true;Layout.leftMargin:16;Layout.rightMargin:16;text:WarProxyBackend.executable;wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
                HusText { Layout.fillWidth:true;Layout.leftMargin:16;Layout.rightMargin:16;text:WarProxyBackend.certificateTrusted?"本机 CA：已在当前用户证书库中信任":"本机 CA：尚未在当前用户证书库中信任";wrapMode:Text.Wrap }
                Flow { Layout.fillWidth:true;Layout.margins:16;spacing:10
                    HusButton { text:"初始化并安装本机证书";enabled:!WarProxyBackend.busy;onClicked:WarProxyBackend.prepareCertificate() }
                    HusButton { text:"查看证书";onClicked:WarProxyBackend.openCertificate() }
                    HusButton { text:"卸载本程序证书";enabled:!WarProxyBackend.busy;onClicked:WarProxyBackend.uninstallCertificate() }
                    HusButton { text:"刷新效果目录";onClicked:WarProxyBackend.refreshCatalog() }
                    HusButton { text:"检测代理文件";onClicked:WarProxyBackend.check() }
                    HusButton { text:"选择备用核心";enabled:!WarProxyBackend.active && !WarProxyBackend.busy;onClicked:WarProxyBackend.chooseExecutable() }
                }
                HusText { Layout.fillWidth:true;Layout.margins:16;text:WarProxyBackend.certificateStatus;wrapMode:Text.Wrap;color:HusTheme.Primary.colorTextSecondary }
                HusText { Layout.fillWidth:true;Layout.margins:16;text:"安装仅作用于当前用户 Root 存储，不弹 Windows 安装向导。每台电脑生成独立 CA；不会分发私钥。若游戏拒绝证书或捕获不兼容，本功能无法工作。";wrapMode:Text.Wrap }
                Flow { Layout.fillWidth:true;Layout.margins:16;spacing:10
                    HusButton { text:"研究文档";onClicked:Backend.openUrl("https://github.com/deepseekv41flash/hd2-network-proxy") }
                    HusButton { text:"mitmproxy 证书说明";onClicked:Backend.openUrl("https://docs.mitmproxy.org/stable/concepts/certificates/") }
                }
            }
            }
        }
    }
    HusModal {
        id:enableDialog;width:Math.min(700,page.width-30);title:page.observeRequest?"采集在线目录":"开启变种方案";modal:true;maskClosable:false;confirmText:"开启";cancelText:"取消";onCancel:close()
        onConfirm:{close();WarProxyBackend.startConfigured(page.observeRequest)}
        bodyDelegate:HusText { width:enableDialog.width-48;wrapMode:Text.Wrap;text:(page.observeRequest?"本次仅转发并采集效果目录，不应用保存的星球修改。":"将应用所有已启用的星球方案，未知效果会被拦截；阵营和战役覆盖是实验性功能。")+"\n\n请先安装本机 CA。"+(WarProxyBackend.captureMode==="proxy"?"兼容模式需要先将桥接启动选项粘贴到 Steam 游戏属性，然后由 Steam 启动游戏。":"等待捕获服务就绪后再启动游戏。")+"多人会话也可能受玩法变化影响。关闭代理后请退出游戏，再从 Steam 正常启动。不会保存账号、认证信息或完整流量。" }
    }
    HusModal {
        id:planetDialog;width:Math.min(720,page.width-30);title:"选择星球";modal:true;confirmText:"完成";cancelText:"关闭";onConfirm:close();onCancel:close()
        bodyDelegate:ColumnLayout {
            width:planetDialog.width-48;spacing:10
            HusInput { objectName:"warPlanetSearch";Layout.fillWidth:true;placeholderText:"搜索中文名 / 英文名 / 星球编号";text:page.planetQuery;clearEnabled:true;onClickClear:page.planetQuery="";onTextEdited:page.planetQuery=text }
            HusText { text:page.filteredPlanets().length+" 颗星球" }
            ListView { Layout.fillWidth:true;Layout.preferredHeight:320;clip:true;spacing:6;model:page.filteredPlanets();boundsBehavior:Flickable.StopAtBounds
                ScrollBar.vertical:HusScrollBar{}
                SmoothWheel{}
                delegate:HusButton { required property var modelData;width:ListView.view.width-16;text:modelData.name+" · "+(modelData.native || "")+" · #"+modelData.id;onClicked:{page.choosePlanet(modelData.id);planetDialog.close()} }
            }
            HusText { visible:!page.filteredPlanets().length;text:"没有匹配的星球，请更换名称或编号。" }
        }
    }
    HusModal {
        id:steamDialog;width:Math.min(680,page.width-30);title:"Steam 启动设置";modal:true;confirmText:"已设置，通过 Steam 启动";cancelText:"关闭";onCancel:close()
        onConfirm:{close();WarProxyBackend.launchGame("")}
        bodyDelegate:HusText { width:steamDialog.width-48;wrapMode:Text.Wrap;text:"首次使用：点击“复制 Steam 启动选项”，然后在 Steam 库右键《绝地潜兵 2》→ 属性 → 通用 → 启动选项，粘贴复制的一行。\n\n如果已有其他启动选项，请先保留备份；原有游戏参数可放在 %command% 后。请完全退出游戏，等待代理和证书就绪后再启动。\n\n这里只向 Steam 发送启动请求，不直接运行游戏 EXE。之后可直接从 Steam 启动；代理关闭时桥接不添加代理环境。" }
    }
}
