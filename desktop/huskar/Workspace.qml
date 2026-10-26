import QtQuick

// Application state and data access; deliberately contains no visual controls.
QtObject {
    id: store
    property int catalogColumns:Number(Backend.setting("catalogColumns",3))
    function setCatalogColumns(count){catalogColumns=count===4?4:3;Backend.saveSetting("catalogColumns",catalogColumns)}
    property string cardMaterial:"solid"
    property var cardBackdrop:null
    property bool cardMotion:true
    property var catalogs: ({})
    property var armor: []
    property var groups: []
    property var current: ({})
    property var rows: []
    property var callbacks: ({})
    property var lastItems: ({})
    property var slotByItem: ({})
    property var recent: Backend.setting("recent", [])
    property string tab: "Primary"
    property string module: "home"
    property string screen: "catalog"
    property string search: ""
    property bool catalogOnlyModified:false
    property string game: ""
    property string status: "正在读取游戏数据…"
    property string fatalError: ""
    property int epoch: 0
    property int slot: 1
    property var presetInfo: ({})
    property int armorTarget: 999
    property var armorProfile: ({enabled:{},own:true,conflicts:"stack"})
    property var presets: []
    property var tweaks: ({})
    property var mods: []
    property bool modsUnlocked: false
    property bool busy: false
    property var destinations: [
        {key:"equipment",name:"装备",tab:"Primary",description:"武器、投掷物与强化增益",icon:0},
        {key:"stratagem",name:"战略配备",tab:"Stratagems",description:"投送、炮塔与战备参数",icon:0},
        {key:"vehicle",name:"载具与机甲",tab:"Mechas",description:"本体、挂载与车辆数据",icon:0},
        {key:"armor",name:"护甲",tab:"ArmorWeight",description:"多被动组合与被动数值",icon:0},
        {key:"player",name:"潜兵",tab:"Helldiver",description:"生命值与潜兵基础参数",icon:0},
        {key:"enemy",name:"敌人",tab:"Terminids",description:"单位、阵营与生成规则",icon:0},
        {key:"records",name:"数据库",tab:"Records",description:"射弹、伤害与底层记录",icon:0},
        {key:"attachment",name:"配件",tab:"Attachments",description:"武器配件与属性修正",icon:0}
    ]
    property var types: module==="equipment" ? [
        {label:"主武器",value:"Primary"},{label:"副武器",value:"Secondary"},{label:"支援武器",value:"Support"},{label:"投掷物",value:"Throwables"},{label:"强化增益",value:"Boosters"}
    ] : module==="enemy" ? [
        {label:"终结族",value:"Terminids"},{label:"机器人",value:"Automatons"},{label:"光能族",value:"Illuminate"},{label:"超级地球武装部队",value:"SEAF"},{label:"敌人生成",value:"Spawning"}
    ] : []
    property var library: {
        let q=search.trim().toLowerCase()
        const compact=q.replace(/[^a-z0-9\u3400-\u9fff]/g,"")
        return (catalogs[tab] || []).filter(x=>(!catalogOnlyModified || x.changed) && (!q || (x.search || x.name || "").toLowerCase().indexOf(q)>=0 || (x.search || x.name || "").toLowerCase().replace(/[^a-z0-9\u3400-\u9fff]/g,"").indexOf(compact)>=0))
    }
    signal error(string text)
    signal loaded()
    signal selectionReady()
    signal rowUpdated(var row)
    signal updateFound(string version,string url,string notes,string downloadUrl)
    signal operationProgress(string message,int done,int total)

    function call(method,args,done,failed){
        if(!Backend.ready){if(failed)failed("数据尚未载入");return -1}
        let id=Backend.request(method,args || [])
        callbacks[id]={done:done,failed:failed}
        return id
    }
    function openModule(key){
        module=key;search="";screen="catalog"
        if(key==="home")return
        if(key==="presets"){refreshPresets();return}
        if(key==="mods"){refreshMods();return}
        if(key==="settings")return
        if(key==="tweaks"){call("tweaks",[],x=>tweaks=x);return}
        if(key==="armor"){refreshArmor();return}
        const d=destinations.find(x=>x.key===key)
        if(!d)return
        call("editor_mode",[key==="enemy"])
        setTab(d.tab)
        if(key==="player" && library.length)select(library[0])
    }
    function refreshCatalog(key){
        if(!Backend.ready || !catalogs[key])return
        call("items",[key,""],function(items){
            const previous={};for(const item of catalogs[key] || [])previous[item.id]=item
            const next=Object.assign({},catalogs)
            next[key]=items.map(x=>Object.assign({},previous[x.id] || {},x))
            catalogs=next
        })
    }
    onScreenChanged:if(screen==="catalog" && module!=="home")refreshCatalog(tab)
    function setTab(key){tab=key;search="";screen="catalog";rows=[];refreshCatalog(key)}
    function select(item){
        if(!item || !item.id)return
        if(current.id)slotByItem[current.id]=slot
        current=item;slot=slotByItem[item.id] || 1;lastItems[tab]=item.id
        rows=[];screen="editor";epoch++
        const ticket=epoch
        call("select",[item.id],function(){
            call("rows",[],function(data){if(ticket===epoch){rows=data;selectionReady()}})
            refreshPreset()
        })
    }
    function applyRows(updated){
        rows=updated
        // Update the current owner immediately; refresh all shared owners when
        // returning to the catalog or opening the global search.
        if(current.id && catalogs[tab]){
            const next=Object.assign({},catalogs)
            next[tab]=catalogs[tab].map(x=>x.id===current.id?Object.assign({},x,{changed:updated.some(r=>r.changed)}):x)
            catalogs=next
        }
        // FieldEditor updates its local row after edits. Replacing the model
        // alone does not update that local copy when section delegates survive.
        for(const item of updated)rowUpdated(item)
    }
    function refreshRows(){if(!current.id)return;const ticket=epoch;call("rows",[],x=>{if(ticket===epoch)applyRows(x)})}
    function save(row,text,done,failed){
        const ticket=epoch;const owner=current.id
        call("set",[row.id,text],function(result){
            status=String(result);recent=recent.filter(x=>x!==owner);recent.unshift(owner);recent=recent.slice(0,40);Backend.saveSetting("recent",recent)
            if(ticket!==epoch)return
            if(done)done()
            store.call("rows",[],function(updated){
                if(ticket===epoch)store.applyRows(updated)
            })
        },failed)
    }
    function refreshPreset(){call("preset_info",[slot],x=>presetInfo=x)}
    function refreshPresets(){call("full_presets",[],x=>presets=x)}
    function refreshArmor(){call("armor_profile",[armorTarget],x=>armorProfile=x)}
    function armorChange(id,on,own,policy){call("armor_update",[armorTarget,id,on,own,policy],function(){refreshArmor();status="护甲组合已保存，写入游戏后生效"})}
    function refreshMods(){call("mods_list",[],x=>mods=x)}
    property Connections connection: Connections {
        target:Backend
        function onCompleted(id,data,error){
            let cb=store.callbacks[id];delete store.callbacks[id]
            if(error){if(cb && cb.failed)cb.failed(error);else store.error(error)}
            else if(cb && cb.done)cb.done(data)
        }
        function onInitialized(data){store.catalogs=data.catalogs;store.armor=data.armor;store.groups=data.armorGroups;store.game=data.game;store.status="数据已就绪";store.loaded()}
        function onStartupError(text){store.fatalError=text;store.error(text);if(QaMode)Backend.finishQa(text)}
        function onUpdateAvailable(version,url,notes,downloadUrl){store.updateFound(version,url,notes,downloadUrl)}
        function onProgress(text,done,total){store.operationProgress(text,done,total)}
        function onExternalChange(){store.refreshRows();if(store.module==="armor")store.refreshArmor();if(store.module==="mods")store.refreshMods()}
    }
}
