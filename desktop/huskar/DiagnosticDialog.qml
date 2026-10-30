import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HuskarUI.Basic

HusModal {
    id:dialog
    required property var store
    property string mode:"chain"
    property var report:({})
    property bool loading:false
    property string query:""
    property string errorText:""
    property string progressText:""
    property int generation:0
    property int resultCount:0
    property real hostWidth:1480
    property real hostHeight:960
    signal openRecord(string hash,string name)
    width:Math.min(1080,hostWidth-70)
    modal:true;cancelText:"关闭";onCancel:close()
    title:mode==="chain"?"射击引用链":"资源依赖诊断"
    function list(value){return value && value.length?value:[]}
    function qa(action){
        if(action==="chain")return visible && !loading && mode==="chain" && list(report.entries).length>0
        if(action==="filtered")return query==="伤害" && resultCount>0 && resultCount<list(report.entries).length
        if(action==="resources"){load("resources");return true}
        if(action==="resourcesCheck")return visible && !loading && mode==="resources" && !!report.owner && !errorText
        if(action==="close"){close();return true}
        if(action==="openRecord"){
            const row=list(report.entries).find(r=>r.record_hash && !r.missing)
            if(!row)return false;close();openRecord(row.record_hash,row.title);return true
        }
        return false
    }
    function load(kind){mode=kind;query="";report={};errorText="";open();refresh()}
    function refresh(){
        loading=true;progressText=mode==="chain"?"正在读取当前引用…":"正在扫描资源与音效目录，首次可能需要较长时间…"
        const ticket=++generation
        store.call(mode==="chain"?"diagnostic_chain":"diagnostic_resources",[],function(data){if(ticket!==generation)return;report=data;loading=false},function(text){if(ticket!==generation)return;errorText=text;loading=false})
    }
    function exportText(){
        let lines=[title+" · "+(report.equipment || ""),report.note || "",""]
        if(mode==="chain")for(const r of list(report.entries))lines.push("  ".repeat(Math.min(r.depth || 0,24))+r.title+" ← "+r.via+(r.missing?" [记录缺失]":"")+(r.repeated?" [重复/循环引用]":"")+(r.summary?" · "+r.summary:""))
        else {
            for(const p of list(report.packages))lines.push("包 "+(p.name || p.id)+" · "+p.id+" · "+p.status)
            lines.push("")
            for(const r of list(report.entries))lines.push(r.type+":"+r.id+" · "+r.status+" · 来源："+list(r.providers).join("、"))
        }
        for(const warning of list(report.warnings))lines.push("提示："+warning)
        return lines.join("\n")+"\n"
    }
    Connections { target:dialog.store;function onOperationProgress(message,done,total){if(dialog.loading)dialog.progressText=message+(total>0?"（"+done+" / "+total+"）":"")} }
    bodyDelegate:ColumnLayout {
        width:dialog.width-48;spacing:12
        RowLayout {
            Layout.fillWidth:true
            HusText { Layout.fillWidth:true;text:dialog.report.equipment || "当前条目";font.bold:true;wrapMode:Text.Wrap }
            HusButton { text:"重新读取";enabled:!dialog.loading;onClicked:dialog.refresh() }
            HusButton { objectName:"exportDiagnostic";text:"导出报告";enabled:!dialog.loading && !dialog.errorText && !!dialog.report.owner;onClicked:{let path=Backend.chooseFile(true,"诊断报告 (*.txt)");if(path && !Backend.writeText(path,dialog.exportText()))dialog.errorText="无法保存报告，请检查所选路径。"} }
        }
        HusText { Layout.fillWidth:true;wrapMode:Text.Wrap;text:dialog.loading?dialog.progressText:dialog.report.note || "只读查看，不写入游戏文件。";color:HusTheme.Primary.colorTextSecondary }
        HusText { visible:!!dialog.errorText;Layout.fillWidth:true;wrapMode:Text.Wrap;text:dialog.errorText;color:HusTheme.Primary.colorError }
        HusText { visible:dialog.mode==="resources" && !dialog.loading && !!dialog.report.owner;Layout.fillWidth:true;text:dialog.list(dialog.report.packages).length+" 个来源包 · "+(dialog.report.missing || 0)+" 项资源缺失 · "+(dialog.report.unresolved_audio || 0)+" 项音效候选未定位";wrapMode:Text.Wrap }
        HusInput { objectName:"diagnosticSearch";Layout.fillWidth:true;placeholderText:"搜索名称、类型、编号或来源包";clearEnabled:true;text:dialog.query;onTextEdited:dialog.query=text;enabled:!dialog.loading }
        ListView {
            id:resultList;objectName:"diagnosticResults";Layout.fillWidth:true;Layout.preferredHeight:Math.max(100,Math.min(400,dialog.hostHeight-500))
            clip:true;spacing:10;ScrollBar.vertical:HusScrollBar{}
            onCountChanged:dialog.resultCount=count
            SmoothWheel{}
            model:dialog.list(dialog.report.entries).filter(x=>JSON.stringify(x).toLowerCase().includes(dialog.query.toLowerCase()))
            delegate:HusGroupBox {
                required property var modelData
                width:ListView.view.width-16
                title:dialog.mode==="chain"?modelData.title:((modelData.type_name || modelData.type)+" · "+modelData.id)
                ColumnLayout {
                    width:parent.width;spacing:6
                    HusText { Layout.fillWidth:true;wrapMode:Text.Wrap;text:dialog.mode==="chain"?(modelData.via+" · "+(modelData.parent_title?"来自 "+modelData.parent_title+" · ":"")+(modelData.missing?"当前版本没有此记录":modelData.repeated?"重复或循环引用，未再次展开":"第 "+(modelData.depth+1)+" 层")+(modelData.summary?"\n"+modelData.summary:"")):(modelData.status+"\n来源包："+(dialog.list(modelData.provider_names || modelData.providers).join("、") || "未定位"));color:modelData.missing?HusTheme.Primary.colorError:HusTheme.Primary.colorTextSecondary }
                    HusButton { visible:dialog.mode==="chain" && !!modelData.record_hash && !modelData.missing;text:"打开数据记录";onClicked:{dialog.close();dialog.openRecord(modelData.record_hash,modelData.title)} }
                }
            }
            HusEmpty { visible:!dialog.loading && resultList.count===0;anchors.centerIn:parent;description:dialog.errorText?"诊断未完成":"没有可显示的引用或匹配结果" }
        }
        HusText { visible:dialog.list(dialog.report.warnings).length>0;Layout.fillWidth:true;wrapMode:Text.Wrap;text:"有 "+dialog.list(dialog.report.warnings).length+" 项诊断提示，详情见对应条目或导出报告。";color:HusTheme.Primary.colorWarning }
    }
}
