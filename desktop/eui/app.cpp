#include "eui_neo.h"
#include "bridge.h"
#include "pagination.h"
#include "eui/app.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commdlg.h>
#include <shellapi.h>
#include <shlobj.h>
#include "search.h"
#include "motion.h"
#include "version.h"
#include "mod_zip.h"
#include "patch_mods.h"
#include "mcp_server.h"
#include <iomanip>
#include "core/input/input_state.h"
#include <glad/glad.h>
#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>
#define GLFW_EXPOSE_NATIVE_WIN32
#include <GLFW/glfw3native.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <future>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <unordered_map>

namespace app {
DslAppConfig& mutableConfig();
namespace {
struct ManagedMod {std::filesystem::path path;std::string name,description;bool enabled=true;std::vector<shodan::ModOption> options;std::vector<int> choices;};
struct ModImportResult {std::vector<ManagedMod> mods;std::vector<std::string> errors;};
struct McpResult {Value value;bool updateMods=false;std::vector<ManagedMod> mods;};
struct Model {
 int fontPixels=18,pendingFontPixels=0,sidebarMode=0;bool sidebarModeOpen=false;eui::Signal<float> settingsScroll{0};
 eui::Signal<float> navScroll{0};float navWidth=0,navVelocity=0,frameDelta=0.016f;bool qaResizeAnimationObserved=false;
 shodan::McpServer mcp;std::set<std::string> mcpMethods;
 std::shared_ptr<shodan::McpRequest> mcpRequest;std::future<McpResult> mcpWork;
 bool modsUnlocked=false,hiddenFeaturePrompt=false;
 std::future<ModImportResult> modImport;std::vector<std::filesystem::path> modQueue;bool importingMods=false;size_t qaModsBefore=0;
 bool modInfoOpen=false;std::string modInfoTitle,modInfoText;
 eui::Signal<float> modInfoScroll{0};
 std::vector<ManagedMod> mods;std::vector<shodan::ModFile> preparedPatches;
 int modOptionsIndex=-1;eui::Signal<float> modOptionsScroll{0};
 eui::Signal<float> modScroll{0};
 std::unique_ptr<Backend> backend;
 std::future<std::unique_ptr<Backend>> loading;
 std::future<std::string> operation;
 std::future<Value> reviewWork;Value reviewData;
 bool reviewOpen=false,reviewLoading=false,reviewFilesOpen=false,recentOnly=false;
 std::string reviewAction,importText,presetLabel,renameText,activeScroll;int reviewSlot=0,renameId=-1;
 std::vector<std::string> recent;
 eui::Signal<float> reviewScroll{0},reviewFileScroll{0};float reviewVisual=0;
 std::mutex progressMutex;
 std::string progressMessage;int progressDone=0,progressTotal=0;bool operationResult=false;
 bool groupOpen=false,armorTargetOpen=false;
 bool started=false,dark=false,onlyChanged=false,busy=false,presetsExpanded=false,weaponPresetOpen=false;
 std::map<std::string,int> presetSlots;
 int fullPreset=0,rowsRevision=0;
 std::string presetName;
 int page=0,sub=0,enemySub=0,preset=1,group=0,armorTarget=999,armorDetail=-1,choiceRow=0,codeRow=0;
 std::vector<int> codeArrows;Value tweaks;bool enemyMode=false;
 std::string message="正在读取游戏数据…",error,selected,selectedName,query,choiceQuery,confirm;
 std::vector<Value> items,rows,armor,choices,armorGroups,fullPresetView;
 std::set<std::string> openBrowserGroups;int browserRevision=0;
 Value armorProfileView;
 std::string gamePath;
 std::map<int,std::vector<Value>> armorValues;
 std::map<std::string,std::vector<Value>> catalog;
 float pageProgress=1,presetProgress=0,presetVelocity=0;
 float listMaximum=0,detailVisual=0,armorVisual=0,armorValueVisual=0,listVisual=0,choiceVisual=0,fullVisual=0;int armorDialogId=-1;bool qaSmoothObserved=false,qaListSmoothObserved=false;
 int qaOriginalWidth=0,qaOriginalHeight=0,qaRow=0,qaFull=0,qaImportedFull=0;double qaBefore=0;
 eui::Signal<float> armorValueScroll{0},listScroll{0},choiceScroll{0},fullScroll{0};
 std::string scrollContext;
 std::function<void(float)> qaListChanged;
 std::chrono::steady_clock::time_point animationClock=std::chrono::steady_clock::now();
 std::map<std::string,std::string> edits;
 std::vector<double> frameSamples;
 eui::Signal<float> detailScroll{0},armorScroll{0};
};
Model m;
void tickMcp();
void toggleMcp();
void installWindowResize();
struct SharedView {bool open=false;std::string title;std::vector<Value> entries;eui::Signal<float> scroll{0};};
SharedView sharedView;
struct SharedHint {std::string title;std::vector<Value> entries;};
std::map<std::string,SharedHint> sharedHints;
struct HelpHint {std::string title;std::vector<std::string> lines;};
std::map<std::string,HelpHint> helpHints;
std::string hoveredHelp;
std::string fadingHelp;
float helpOpacity=0;
float helpPointerX=0,helpPointerY=0,qaHelpX=0,qaHelpY=0;
float qaPointerScaleX=1,qaPointerScaleY=1;
std::string qaHelpTarget;
std::set<std::string> qaAnimatedArrows;
std::string qaSharedId,qaBrowserGroup,qaBrowserLabel;bool qaSharedHint=false;
float labelWidth(const std::string& s){float width=0;for(unsigned char c:s){if(c<128)width+=6.5f;else if((c&0xC0)!=0x80)width+=13;}return width;}
std::string sharedSummary(const std::vector<Value>& entries,float width){
 std::string out="同时影响：";size_t shown=0;
 for(const auto& item:entries){
  const std::string next=(shown?"、":"")+item["name"].str();
  if(shown&&labelWidth(out+next)+50>width)break;
  out+=next;++shown;if(shown>=3)break;
 }
 if(shown<entries.size())out+=" +"+std::to_string(entries.size()-shown);
 return out;
}

void showShared(const std::string& title,const std::vector<Value>& entries){sharedView.open=true;sharedView.title=title;sharedView.entries=entries;sharedView.scroll.set(0);}
const std::vector<std::string> categories={"Primary","Stratagems","Mechas","Attachments","Armors","Records"};
const std::vector<std::string> names={"装备编辑","战略配备","载具与机甲","武器配件","护甲被动","数据记录","设置"};
const std::vector<std::string> equipKeys={"Primary","Secondary","Support","Throwables"};
const std::vector<std::string> equipNames={"主武器","副武器","支援武器","投掷物"};
const std::vector<std::string> enemyKeys={"Terminids","Automatons","Illuminate","SEAF","Spawning"};
const std::vector<std::string> enemyNames={"终结族","机器人","光能族","超级地球武装部队","敌人生成"};
std::filesystem::path profile(){if(const char* override=std::getenv("SHODAN_PROFILE"))return std::filesystem::path(override);const char* p=std::getenv("LOCALAPPDATA");return std::filesystem::path(p?p:".")/"SHODAN"/"StatEditor";}
void applyFontSize(int pixels){
 m.fontPixels=std::clamp(pixels,12,24);m.pendingFontPixels=0;
 mutableConfig().uiScale(std::min(1.0f,110.4f/float(GetDpiForSystem()))*float(m.fontPixels)/16.0f);
 std::filesystem::create_directories(profile());std::ofstream(profile()/"font-size.txt")<<m.fontPixels;
 ++m.rowsRevision;app::requestUpdate();
}
void saveTheme(){std::error_code ec;std::filesystem::create_directories(profile(),ec);std::ofstream(profile()/"theme.txt")<<(m.dark?"dark":"light");}
components::theme::ThemeColorTokens theme(){
 auto t=m.dark?components::theme::dark():components::theme::light();
 t.primary=m.dark?eui::Color{0.08f,0.78f,0.54f,1}:eui::Color{0.04f,0.48f,0.35f,1};
 t.background=m.dark?eui::Color{0,0,0,1}:eui::Color{0.95f,0.97f,0.95f,1};
 t.surface=m.dark?eui::Color{0,0,0,1}:eui::Color{1,1,1,1};
 t.surfaceHover=m.dark?eui::Color{0.035f,0.07f,0.055f,1}:eui::Color{0.91f,0.95f,0.92f,1};
 t.surfaceActive=t.surfaceHover;
 t.border=m.dark?eui::Color{0.13f,0.21f,0.18f,1}:eui::Color{0.80f,0.86f,0.82f,1};
 t.text=m.dark?eui::Color{0.88f,0.94f,0.91f,1}:eui::Color{0.12f,0.20f,0.17f,1};
 return t;
}
eui::Transition motion(){return eui::Transition::make(0.18f,eui::Ease::OutCubic);}
float animatedArrow(const std::string& id,float target){
 struct Arrow{float angle,velocity=0,target;std::chrono::steady_clock::time_point last;};
 static std::map<std::string,Arrow> arrows;const auto now=std::chrono::steady_clock::now();
 auto result=arrows.try_emplace(id,Arrow{target,0,target,now});auto& arrow=result.first->second;
 float dt=std::chrono::duration<float>(now-arrow.last).count();arrow.last=now;
 if(target!=arrow.target&&dt>0.05f)dt=0;arrow.target=target;
 if(shodan::damped(arrow.angle,arrow.velocity,target,dt,26))app::requestUpdate();
 if(std::getenv("SHODAN_EUI_QA")&&target>1&&arrow.angle>0.01f&&arrow.angle<target-0.01f)qaAnimatedArrows.insert(id);
 return arrow.angle;
}
void dropdownArrow(eui::Ui& ui,const std::string& id){
 if(auto* arrow=ui.find(id+".chevron")){
  const bool open=arrow->text==core::dsl::utf8(0xF077);
  arrow->text=core::dsl::utf8(0xF078);arrow->transform.rotate=animatedArrow(id,open?3.14159265f:0);
  arrow->transition.properties=core::AnimProperty::TextColor;
 }
}
float entrance(const std::string& channel,const std::string& key,float duration=0.20f){
 struct Entry{std::string key;std::chrono::steady_clock::time_point start;};
 static std::map<std::string,Entry> entries;
 auto now=std::chrono::steady_clock::now();auto& e=entries[channel];
 if(e.key!=key){e.key=key;e.start=now;}
 float t=std::clamp(std::chrono::duration<float>(now-e.start).count()/duration,0.0f,1.0f);
 if(t<1)app::requestUpdate();
 return 1-std::pow(1-t,3);
}
float stagger(float progress,int index){return std::clamp(progress*1.12f-std::min(index,5)*0.018f,0.0f,1.0f);}
void clampScroll(eui::Signal<float>& target,float& visual,float maximum){
 maximum=std::max(0.0f,maximum);
 const float value=std::clamp(target.get(),0.0f,maximum);
 if(value!=target.get())target.set(value);
 visual=std::clamp(visual,0.0f,maximum);
}


std::string number(double v){char b[48];std::snprintf(b,sizeof b,"%.9g",v);return b;}
void text(eui::Ui& ui,const std::string& id,const std::string& s,float x,float y,float w,float h=28,float size=16,bool muted=false){
 auto c=theme().text;if(muted)c.a=0.58f;
 ui.text(id).position(x,y).size(w,h).text(s).fontSize(size).lineHeight(size+6).wrap(true).color(c).build();
}
void panel(eui::Ui& ui,const std::string& id,float x,float y,float w,float h){
 components::panel(ui,id,theme()).position(x,y).size(w,h).radius(12).border(1,theme().border).shadow({}).build();
}
void button(eui::Ui& ui,const std::string& id,const std::string& s,float x,float y,float w,std::function<void()> cb,bool primary=false,float h=40,bool allowWhileBusy=false){
 std::string label=s;unsigned int arrow=0;bool folding=false;float angle=0;
 if(s=="‹"){label.clear();arrow=0xF053;}else if(s=="›"){label.clear();arrow=0xF054;}
 else if(s.size()>=3&&s.compare(s.size()-3,3,"▾")==0){label=s.substr(0,s.size()-3);arrow=0xF054;folding=true;angle=1.57079633f;}
 else if(s.size()>=3&&s.compare(s.size()-3,3,"▸")==0){label=s.substr(0,s.size()-3);arrow=0xF054;folding=true;}
 else if(s.rfind("‹ ",0)==0){label=s.substr(4);arrow=0xF053;}
 auto control=components::button(ui,id);if(arrow)control.icon(arrow).iconSize(22);
 control.position(x,y).size(w,h).theme(theme(),primary).radius(10).fontSize(15)
 .text(label).disabled(m.busy&&!allowWhileBusy).pressScale(0.985f).shadow(0,0,0,{0,0,0,0}).transition(eui::Transition::make(0.14f,eui::Ease::OutCubic)).onClick(std::move(cb)).build();
 if(folding)if(auto* icon=ui.find(id+".icon")){
  icon->transform.rotate=animatedArrow(id,angle);icon->transition.properties=core::AnimProperty::TextColor;
 }
}
components::theme::ThemeColorTokens dropdownTheme(){auto t=theme();t.metrics.typography.hint=22;return t;}
components::InputStyle inputStyle(){auto s=components::InputStyle(theme());s.shadow={};return s;}
components::DropdownStyle dropdownStyle(){auto s=components::DropdownStyle(theme());s.shadow={};return s;}
void scrollDropdown(eui::Ui& ui,const std::string& id,float width,float height,float maximum,const std::vector<std::string>& labels,int selected,bool open,std::function<void(bool)> onOpen,std::function<void(int)> onChange){
 struct State{eui::Signal<float> offset{0};bool wasOpen=false;};auto& state=ui.state<State>(id+".scroll-state");
 const float view=std::max(44.0f,std::min(maximum,float(labels.size()*44+12)));
 if(open&&!state.wasOpen)state.offset.set(std::clamp(float(selected*44)-view/2,0.0f,std::max(0.0f,float(labels.size()*44+12)-view)));state.wasOpen=open;
 button(ui,id+".field",selected>=0&&selected<int(labels.size())?labels[selected]:"请选择",0,0,width,[onOpen,open]{onOpen(!open);app::requestUpdate();},false,height);
 ui.text(id+".chevron").position(width-36,(height-22)/2).size(24,24).icon(0xF078).fontSize(22).color(theme().primary).rotate(animatedArrow(id,open?3.14159265f:0)).build();
 if(!open)return;
 panel(ui,id+".popup",0,height+6,width,view);
 components::scrollView(ui,id+".scroll").theme(theme()).position(4,height+10).size(width-8,view-8).bind(state.offset)
 .onChange([&state](float v){state.offset.set(v);app::requestUpdate();}).step(44).scrollbarWidth(7).scrollbarGap(4)
 .contentKey(id+":"+std::to_string(labels.size())+":"+std::to_string(selected)).content([=](eui::Ui& content,float cw,float vh){
  content.stack(id+".canvas").size(cw,float(labels.size()*44)).content([&]{for(size_t i=0;i<labels.size();++i)
   button(content,id+".option."+std::to_string(i),labels[i],0,float(i*44),cw,[onOpen,onChange,i]{onChange(int(i));onOpen(false);app::requestUpdate();},int(i)==selected,40);
  }).build();
 }).build();
 if(auto* scroll=ui.find(id+".scroll"))scroll->composeOnScrollOffsetChange=true;
}
components::DialogStyle dialogStyle(){auto s=components::DialogStyle(theme());s.shadow={};return s;}
void safe(const std::function<void()>& fn){try{fn();}catch(const std::exception& e){m.message=e.what();m.error=e.what();}}
void refreshRows(){++m.rowsRevision;m.rows=m.backend->call("rows").array;m.edits.clear();m.error.clear();}
void updatePresetInfo(){if(m.backend&&!m.selected.empty())m.presetLabel=m.backend->call("preset_info",{m.preset})["name"].str();}
void markRecent(){
 if(m.selected.empty())return;
 m.recent.erase(std::remove(m.recent.begin(),m.recent.end(),m.selected),m.recent.end());m.recent.insert(m.recent.begin(),m.selected);
 if(m.recent.size()>40)m.recent.resize(40);
 std::ofstream file(profile()/"recent.txt");for(const auto& id:m.recent)file<<id<<'\n';
}
void select(const Value& item){
 if(!m.selected.empty())m.presetSlots[m.selected]=m.preset;
 m.backend->call("select",{item["id"]});m.selected=item["id"].str();m.selectedName=item["name"].str();m.preset=m.presetSlots.count(m.selected)?m.presetSlots[m.selected]:1;
 m.groupOpen=false;m.group=0;m.onlyChanged=false;m.detailScroll.set(0);refreshRows();updatePresetInfo();
}
void reloadList(bool chooseFirst=false){
 const auto tab=m.page==11?enemyKeys[m.enemySub]:m.page==12?std::string("Boosters"):m.page==10?std::string("Helldiver"):m.page==0?equipKeys[m.sub]:categories[std::min(m.page,5)];
 if(!m.catalog.count(tab))m.catalog[tab]=m.backend->call("items",{tab,""}).array;
 m.items.clear();
 for(const auto& item:m.catalog[tab]){
  if(m.recentOnly&&std::find(m.recent.begin(),m.recent.end(),item["id"].str())==m.recent.end())continue;
  if(shodan::searchMatches(item["search"].str(),m.query))m.items.push_back(item);
 }
 if(m.recentOnly)std::stable_sort(m.items.begin(),m.items.end(),[](const Value& a,const Value& b){
  return std::find(m.recent.begin(),m.recent.end(),a["id"].str())<std::find(m.recent.begin(),m.recent.end(),b["id"].str());
 });
 m.listScroll.set(0);m.listVisual=0;
 if(chooseFirst && !m.items.empty())select(m.items.front());
}
void navigate(int page){safe([&]{
 if(page==8&&!m.modsUnlocked)return;
 if(page!=9){m.enemyMode=page==11;m.backend->call("editor_mode",{m.enemyMode});}
 m.animationClock=std::chrono::steady_clock::now();
 m.groupOpen=false;m.armorTargetOpen=false;m.page=page;m.pageProgress=0;m.armorDetail=-1;m.query.clear();m.recentOnly=false;m.error.clear();m.group=0;m.detailScroll.set(0);m.armorScroll.set(0);
 if(page<4||page==5||page==10||page==11||page==12)reloadList(true);
 if(page==6)m.tweaks=m.backend->call("tweaks");
});}
void searchEquipment(const std::string& query){safe([&]{
 if(m.page==0&&query=="mu7"){
  m.query.clear();reloadList();
  if(!m.modsUnlocked)m.hiddenFeaturePrompt=true;
  else m.message="Mod 管理入口已开启";
  app::requestUpdate();return;
 }
 m.query=query;reloadList();
});}
void commit(int n,const std::string& value){safe([&]{m.message=m.backend->call("set",{n,value}).str();refreshRows();markRecent();});}
void flushEdits(){
 auto edits=m.edits;
 for(const auto& e:edits){
  if(m.page==4&&m.armorDetail>=0){
   auto v=m.backend->call("armor_set",{m.armorDetail,e.first,e.second});
   if(v.kind==Value::Nil)throw std::runtime_error("护甲数值无效，未执行写入");
  }else m.backend->call("set",{std::stoi(e.first),e.second});
 }
 m.edits.clear();
}
void syncManagedMods();
void saveMods();
ModImportResult importMods(const std::vector<std::filesystem::path>&,const std::filesystem::path&,size_t);
void openReview(const std::string& action,int slot=0,const std::string& imported=""){safe([&]{
 flushEdits();if(m.page!=4)refreshRows();
 m.reviewAction=action;m.reviewSlot=slot;m.importText=imported;m.reviewOpen=true;m.reviewLoading=true;m.reviewFilesOpen=false;
 m.reviewData=Value();m.reviewScroll.set(0);m.reviewFileScroll.set(0);m.reviewVisual=0;m.busy=true;m.error.clear();
 m.reviewWork=std::async(std::launch::async,[action,slot,imported]{
  if(action=="install"){
   syncManagedMods();auto preview=m.backend->call("install_preview");
   for(const auto& file:m.preparedPatches)if(file.name.find(".stream")==std::string::npos&&file.name.find(".gpu_resources")==std::string::npos){
    preview.fields["files"].array.push_back(Value("data/"+file.name));Value row;row.kind=Value::Table;row.fields["equipment"]=file.label;row.fields["parameter"]="资源补丁（保留原内容）";row.fields["before"]="未启用";row.fields["after"]="已选择，写入后生效";preview.fields["entries"].array.push_back(row);
   }
   if(m.modsUnlocked&&m.preparedPatches.empty()&&std::filesystem::exists(profile()/"patch-install.txt")){preview.fields["files"].array.push_back(Value("清理本管理器已关闭的资源补丁"));}
   return preview;
  }
  if(action=="load-weapon"||action=="load-full")return m.backend->call("preset_compare",{action=="load-weapon"?"weapon":"full",slot});
  return m.backend->call("preset_inspect",{action=="import-weapon"?"weapon":"full",imported});
 });
});}
std::filesystem::path presetFile(bool save){
 wchar_t path[32768]=L"SHODAN_预设.shodanpreset";
 OPENFILENAMEW of{};of.lStructSize=sizeof(of);of.hwndOwner=glfwGetWin32Window(glfwGetCurrentContext());
 of.lpstrFilter=L"SHODAN 预设 (*.shodanpreset)\0*.shodanpreset\0所有文件\0*.*\0";
 of.lpstrFile=path;of.nMaxFile=32768;of.lpstrDefExt=L"shodanpreset";
 of.lpstrTitle=save?L"导出预设":L"导入预设";
 of.Flags=OFN_EXPLORER|OFN_NOCHANGEDIR|OFN_PATHMUSTEXIST|(save?OFN_OVERWRITEPROMPT:OFN_FILEMUSTEXIST);
 BOOL ok=save?GetSaveFileNameW(&of):GetOpenFileNameW(&of);
 if(!ok){if(CommDlgExtendedError())throw std::runtime_error("无法打开预设文件选择窗口");return {};}
 return std::filesystem::path(path);
}
void exportPreset(const std::string& kind,int slot){safe([&]{
 const auto data=m.backend->call("preset_export",{kind,slot}).str();auto path=presetFile(true);if(path.empty())return;
 std::ofstream file(path,std::ios::binary|std::ios::trunc);file.write(data.data(),std::streamsize(data.size()));file.flush();
 if(!file)throw std::runtime_error("预设导出失败，请选择可写入的位置");m.message="预设已导出";
});}
void importPreset(const std::string& kind,int slot=0){safe([&]{
 auto path=presetFile(false);if(path.empty())return;
 if(std::filesystem::file_size(path)>8*1024*1024)throw std::runtime_error("预设文件过大");
 std::ifstream file(path,std::ios::binary);if(!file)throw std::runtime_error("无法读取预设文件");
 std::string data((std::istreambuf_iterator<char>(file)),{});openReview("import-"+kind,slot,data);
});}
void closeArmorValues(){
 if(m.armorDetail>=0){
  safe([]{flushEdits();m.armorValues[m.armorDetail]=m.backend->call("armor_rows",{m.armorDetail}).array;});
  if(!m.edits.empty())return;
 }
 m.armorDetail=-1;
}
std::string performWrite(const std::string& action){
 if(m.backend->call("game_running").yes())throw std::runtime_error("请先关闭游戏，再写入或恢复");
 m.backend->call("mod_management",{m.modsUnlocked});
 if(action=="install")syncManagedMods();
 std::unique_ptr<shodan::PatchTransaction> patches;
 if(m.modsUnlocked)patches=std::make_unique<shodan::PatchTransaction>(std::filesystem::u8path(m.gamePath).parent_path(),profile(),action=="install"?m.preparedPatches:std::vector<shodan::ModFile>{});
 auto result=m.backend->call(action.c_str()).str();
 if(m.backend->call("write_succeeded").yes()){
  if(patches){patches->commit();result+=action=="install"?"\n资源补丁已同步；关闭的 Mod 补丁已移除。":"\n本管理器安装的资源补丁已移除。";}
 }else throw std::runtime_error(result);
 return result;
}
void runOperation(const std::string& action){safe([&]{
 flushEdits();m.operationResult=false;m.busy=true;
 {std::lock_guard<std::mutex> lock(m.progressMutex);m.progressMessage="正在检查修改…";m.progressDone=0;m.progressTotal=0;}
 m.backend->onProgress=[](const std::string& message,int done,int total){{std::lock_guard<std::mutex> lock(m.progressMutex);m.progressMessage=message;m.progressDone=done;m.progressTotal=total;}app::requestUpdate();};
 m.message=action=="install"?"正在准备并写入游戏…":"正在恢复原始文件…";
 m.operation=std::async(std::launch::async,[action]{
  return performWrite(action);
 });
});}

void saveMods(){
 ++m.rowsRevision;
 std::filesystem::create_directories(profile());
 std::ofstream out(profile()/"mods-v2.txt.tmp",std::ios::binary|std::ios::trunc);
 if(!out)throw std::runtime_error("无法保存 Mod 开关");
 for(const auto& mod:m.mods){out<<mod.enabled<<' '<<std::quoted(mod.path.u8string())<<' '<<std::quoted(mod.name)<<' '<<std::quoted(mod.description)<<' '<<mod.choices.size();for(int choice:mod.choices)out<<' '<<choice;out<<'\n';}
 out.close();if(!out)throw std::runtime_error("Mod 开关保存失败");
 if(!MoveFileExW((profile()/"mods-v2.txt.tmp").c_str(),(profile()/"mods-v2.txt").c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))throw std::runtime_error("Mod 开关提交失败");
}
Value modInputs(){
 Value entries;entries.kind=Value::Table;size_t total=0;std::vector<shodan::ModFile> patchInputs;
 for(const auto& mod:m.mods)if(mod.enabled){
  auto zip=shodan::readModZip(mod.path);
  for(auto& file:shodan::selectedModFiles(zip,mod.choices)){
   total+=file.data.size();if(total>512*1024*1024)throw std::runtime_error("开启的 Mod 数据超过 512 MB");
   if(shodan::isPatchFile(file.name)){file.label=mod.name+" / "+file.path;patchInputs.push_back(std::move(file));continue;}
   Value entry;entry.kind=Value::Table;entry.fields["name"]=file.name;entry.fields["label"]=mod.name+" / "+file.name;entry.fields["data"]=std::move(file.data);entries.array.push_back(std::move(entry));
  }
 }
 m.preparedPatches=shodan::combinePatchFiles(patchInputs);return entries;
}
void syncManagedMods(){
 m.backend->call("mod_management",{m.modsUnlocked});
 if(!m.modsUnlocked){m.preparedPatches.clear();return;}
 m.backend->call("managed_mods",{modInputs()});shodan::checkPatchDeployment(std::filesystem::u8path(m.gamePath).parent_path(),profile(),m.preparedPatches);
}
void addMods(const std::vector<std::filesystem::path>& paths){safe([&]{
 if(!m.modsUnlocked){m.message="当前未开启 Mod 管理";app::requestUpdate();return;}
 if(m.modQueue.size()+paths.size()>128)throw std::runtime_error("待导入文件过多，请等待当前队列完成");
 m.modQueue.insert(m.modQueue.end(),paths.begin(),paths.end());
 m.message="ZIP 已加入导入队列";app::requestUpdate();
});}
ModImportResult importMods(const std::vector<std::filesystem::path>& paths,const std::filesystem::path& folder,size_t available){
 ModImportResult result;
 for(const auto& source:paths){try{
  if(result.mods.size()>=available)throw std::runtime_error("最多管理 32 个 Mod");
  std::string ext=source.extension().u8string();std::transform(ext.begin(),ext.end(),ext.begin(),[](unsigned char c){return char(std::tolower(c));});
  if(ext!=".zip")throw std::runtime_error("请拖入 ZIP 格式的数值 Mod");
  auto archive=shodan::readModZip(source);std::filesystem::create_directories(folder);
  auto name=source.stem().u8string();auto dest=folder/source.filename();int suffix=1;
  while(std::filesystem::exists(dest))dest=folder/(source.stem().u8string()+"_"+std::to_string(suffix++)+".zip");
  std::filesystem::copy_file(source,dest);
  result.mods.push_back({dest,archive.title.empty()?name:archive.title,archive.description.empty()?"未提供说明":archive.description,true,archive.options,std::vector<int>(archive.options.size(),1)});
 }catch(const std::exception& error){result.errors.push_back(source.filename().u8string()+"："+error.what());}}
 return result;
}
void receiveModDrop(GLFWwindow*,int count,const char** paths){
 // GLFW releases the shell's HDROP only after this callback returns. Never
 // decompress, copy files, navigate or touch Lua while it owns that handle.
 safe([&]{std::vector<std::filesystem::path> files;for(int i=0;i<count;++i)files.push_back(std::filesystem::u8path(paths[i]));addMods(files);});
 app::requestUpdate();
}
std::filesystem::path modFile(bool save){
 wchar_t path[32768]=L"SHODAN_合并Mod.zip";if(!save)path[0]=0;
 OPENFILENAMEW of{};of.lStructSize=sizeof(of);of.hwndOwner=glfwGetWin32Window(glfwGetCurrentContext());
 of.lpstrFilter=L"Mod ZIP (*.zip)\0*.zip\0";of.lpstrFile=path;of.nMaxFile=32768;of.lpstrDefExt=L"zip";
 of.Flags=OFN_EXPLORER|OFN_NOCHANGEDIR|OFN_PATHMUSTEXIST|(save?OFN_OVERWRITEPROMPT:OFN_FILEMUSTEXIST);
 if(!(save?GetSaveFileNameW(&of):GetOpenFileNameW(&of))){if(CommDlgExtendedError())throw std::runtime_error("无法打开 ZIP 选择窗口");return {};}
 return path;
}
std::string exportModsTo(const std::filesystem::path& path){
  auto inputs=modInputs();std::map<std::string,Value> groups;
  for(auto& item:inputs.array){auto& group=groups[item["name"].str()];group.kind=Value::Table;group.array.push_back(std::move(item));}
  std::vector<shodan::ModFile> files;
  for(auto& pair:groups){auto result=m.backend->call("merge_named",{pair.first,pair.second});files.push_back({pair.first,"",result["data"].str()});}
  files.insert(files.end(),m.preparedPatches.begin(),m.preparedPatches.end());shodan::writeModZip(path,files);return std::string("开启的 Mod 已合并导出（不包含编辑器数值；写入游戏会同时应用编辑器修改）");
}
void exportMods(){safe([]{
 auto path=modFile(true);if(path.empty())return;m.busy=true;m.operationResult=false;m.message="正在校验并合并开启的 Mod…";
 m.operation=std::async(std::launch::async,[path]{return exportModsTo(path);});
});}
void modPage(eui::Ui& ui,float w,float h){
 text(ui,"mods.intro","拖入 ZIP 添加 Mod。开启的 Mod 与当前编辑器修改一起写入；关闭后重新写入可移除效果。",0,0,w,44,15,true);
 button(ui,"mods.add","添加 ZIP",0,54,140,[]{safe([]{auto path=modFile(false);if(!path.empty())addMods({path});});},true);
 button(ui,"mods.export","合并 Mod 并导出",152,54,180,exportMods);
 text(ui,"mods.scope","支持 .dl_bin 数值与 .patch_* 资源补丁；选项包按所选子项导出、安装，冲突会停止处理。",0,104,w,44,14,true);
 const float area=std::max(40.0f,h-164),content=std::max(area,float(m.mods.size()*176));
 components::scrollView(ui,"mods.list").position(0,158).size(w,area).theme(theme()).bind(m.modScroll).onChange([](float v){m.modScroll.set(v);app::requestUpdate();}).contentKey("mods-"+std::to_string(m.rowsRevision)).content([&](eui::Ui& ui,float cw,float vh){
  ui.stack("mods.canvas").size(cw,content).content([&]{
  if(m.mods.empty())text(ui,"mods.empty","将 Mod ZIP 拖到窗口中，或点击「添加 ZIP」",20,32,w-60,80,20,true);
  for(size_t i=0;i<m.mods.size();++i){const auto mod=m.mods[i];const std::string id="mod."+std::to_string(i);const float y=float(i*176);
   panel(ui,id,0,y,w-20,164);
   ui.text(id+".name").position(18,y+12).size(w-290,30).text(mod.name).fontSize(19).wrap(false).clip().color(theme().text).build();
   ui.text(id+".description").position(18,y+48).size(w-210,100).text(mod.description).fontSize(14).lineHeight(22).wrap(true).clip().color(theme().text).build();
   button(ui,id+".enabled",mod.enabled?"已开启":"已关闭",w-174,y+16,130,[i]{safe([i]{auto old=m.mods[i].enabled;m.mods[i].enabled=!old;try{saveMods();}catch(...){m.mods[i].enabled=old;throw;}m.message="开关已保存，重新写入游戏后生效";});},mod.enabled);
   button(ui,id+".info",mod.options.empty()?"查看说明":"说明与选项",w-174,y+66,130,[mod,i]{if(mod.options.empty()){m.modInfoOpen=true;m.modInfoTitle=mod.name;m.modInfoText=mod.description;m.modInfoScroll.set(0);}else{m.modOptionsIndex=int(i);m.modOptionsScroll.set(0);}});
   button(ui,id+".remove","移除",w-174,y+116,130,[i]{safe([i]{auto previous=m.mods;m.mods.erase(m.mods.begin()+i);try{saveMods();}catch(...){m.mods=std::move(previous);throw;}m.message="已移除；重新写入游戏以移除已安装效果";});});
  }
  }).build();
 }).build();
}
void modInfoDialog(eui::Ui& ui,const eui::Screen& screen){
 const float w=std::min(760.0f,screen.width-80),h=std::min(600.0f,screen.height-120);
 components::dialog(ui,"mods.info").theme(theme()).style(dialogStyle()).screen(screen.width,screen.height).size(w,h).open(m.modInfoOpen).zIndex(110).transition(motion()).onOpenChange([](bool open){m.modInfoOpen=open;}).content([&]{
  text(ui,"mods.info.title",m.modInfoTitle,24,22,w-170,60,22);
  button(ui,"mods.info.close","关闭",w-124,22,100,[]{m.modInfoOpen=false;});
  components::scrollView(ui,"mods.info.scroll").theme(theme()).position(24,98).size(w-48,h-122).bind(m.modInfoScroll).onChange([](float v){m.modInfoScroll.set(v);}).contentKey(m.modInfoTitle+m.modInfoText).content([&](eui::Ui& content,float cw,float vh){
   float rows=1,line=0;for(unsigned char c:m.modInfoText){if(c=='\n'){rows+=1+std::floor(line/cw);line=0;}else if(c<128)line+=7.5f;else if((c&0xC0)!=0x80)line+=15;}rows+=std::floor(line/cw);
   text(content,"mods.info.body",m.modInfoText,0,0,cw,std::max(vh,rows*24+48),15);
  }).build();
 }).build();
}
std::string modOptionName(const std::string& name){
 static const std::map<std::string,std::string> names={{"Core","核心（必选）"},{"Weapon rings","武器环形信息"},{"Backpack ring","背包环形信息"},{"Numbers","弹药数字"},{"Rounds and reserve","弹匣与后备弹药"},{"Rounds only","仅弹匣子弹"},{"Weapon icon","武器图标"},{"Everything","显示全部"},{"Hide scope zoom","隐藏瞄具倍率"},{"Fire mode only","仅开火模式"},{"Weapon icon position","武器图标位置"},{"By the crosshair","准星旁"},{"By the game HUD","游戏 HUD 旁"},{"Show when idle","闲置时显示"},{"Faint","淡化"},{"Full brightness","完整亮度"},{"Squad","队伍信息"},{"Colored Night Vision","全彩夜视"}};
 auto found=names.find(name);return found==names.end()?name:found->second;
}
void chooseModOption(size_t index,size_t option,int value){safe([&]{
 auto previous=m.mods[index].choices;m.mods[index].choices.resize(m.mods[index].options.size(),1);m.mods[index].choices[option]=value;
 try{saveMods();}catch(...){m.mods[index].choices=std::move(previous);throw;}m.message="Mod 选项已保存；重新写入游戏后生效";
});}
void modOptionsDialog(eui::Ui& ui,const eui::Screen& screen){
 const int index=m.modOptionsIndex;const bool open=index>=0&&index<int(m.mods.size());
 const float w=std::min(860.0f,screen.width-80),h=std::min(780.0f,screen.height-100);
 components::dialog(ui,"mods.options").theme(theme()).style(dialogStyle()).screen(screen.width,screen.height).size(w,h).open(open).zIndex(112).transition(motion()).onOpenChange([](bool open){if(!open)m.modOptionsIndex=-1;}).content([&]{
  if(!open)return;const auto mod=m.mods[index];
  ui.text("mods.options.title").position(24,20).size(w-170,36).text(mod.name).fontSize(20).wrap(false).clip().color(theme().text).build();
  button(ui,"mods.options.close","关闭",w-124,20,100,[]{m.modOptionsIndex=-1;});
  ui.text("mods.options.description").position(24,72).size(w-48,76).text(mod.description).fontSize(14).lineHeight(22).wrap(true).clip().color(theme().text).build();
  text(ui,"mods.options.hint","按整包管理；每组选一个子项。修改选项不会改写包内已经合并的脚本。",24,154,w-48,36,14,true);
  components::scrollView(ui,"mods.options.scroll").theme(theme()).position(24,200).size(w-48,h-224).bind(m.modOptionsScroll).onChange([](float v){m.modOptionsScroll.set(v);app::requestUpdate();}).contentKey(mod.path.u8string()+":"+std::to_string(m.rowsRevision)).content([&](eui::Ui& content,float cw,float vh){
   float height=0;for(const auto& option:mod.options)height+=option.children.empty()?106:106+option.children.size()*44;
   content.stack("mods.options.canvas").size(cw,std::max(vh,height)).content([&]{
    float y=0;
    for(size_t i=0;i<mod.options.size();++i){const auto option=mod.options[i];const auto id="mods.option."+std::to_string(i);const int selected=i<mod.choices.size()?mod.choices[i]:1;const float pitch=option.children.empty()?106:106+option.children.size()*44;
     panel(content,id,0,y,cw,pitch-12);text(content,id+".name",modOptionName(option.name),16,y+12,cw-180,30,17);
     button(content,id+".toggle",option.required?"必选":selected?"已开启":"已关闭",cw-140,y+10,120,[index,i,selected,option]{if(!option.required)chooseModOption(index,i,selected?0:1);},selected!=0);
     if(option.children.empty())text(content,id+".detail",option.required?"此项随整包安装":"关闭此项后，相应补丁不会进入导出或安装结果",16,y+54,cw-32,30,13,true);
     else for(size_t j=0;j<option.children.size();++j){const auto label=modOptionName(option.children[j].name);button(content,id+".child."+std::to_string(j),label,16,y+54+j*44,cw-32,[index,i,j]{chooseModOption(index,i,int(j)+1);},selected==int(j)+1,38);}
     y+=pitch;
    }
   }).build();
  }).build();
 }).build();
}
Value mcpCatalog(){
 using shodan::object;Value catalog;catalog.kind=Value::Table;m.mcpMethods.clear();
 const std::map<std::string,std::string> signatures={
 {"items","[tab, query] 查询装备；tab: Primary/Secondary/Support/Throwables/Stratagems/Mechas/Attachments/Records"},
 {"select","[hash] 选择装备；hash 使用 items 返回的 id"},{"rows","[] 当前装备的参数、原值、范围和共享影响"},
 {"set","[row_id, value] 修改当前装备参数；value 可为数字或数值字符串，先调用 rows 获取 id"},
 {"reset","[row_id?] 恢复原值；省略 row_id 恢复当前装备"},{"choices","[row_id] 查询弹丸或状态效果候选项"},
 {"shared","[row_id] 查询共享此参数的装备"},{"preset","[action, slot] 当前装备预设；action: save/load/clear，slot: 1..5"},
 {"choose","[row_id, choice_id] 沿用原项目选择逻辑替换弹丸、爆炸或效果；先调用 choices"},
 {"full_presets","[] 列出全局预设"},{"full_preset","[action, id, name?] 全局预设 save/load/delete"},
 {"preset_info","[slot] 当前装备预设详情"},{"preset_rename","[kind, id, name] 重命名预设；kind: weapon/full"},
 {"preset_export","[kind, id] 导出预设文本；kind: weapon/full"},{"preset_import","[kind, id, text] 导入预设文本"},
 {"preset_inspect","[kind, text] 预览待导入预设"},{"preset_compare","[kind, id] 比较预设与当前修改"},
 {"armor_rows","[passive_id] 查询护甲被动可修改参数及原值"},{"armor_set","[passive_id, key, value] 修改护甲被动数值"},
 {"armor_profile","[target_id] 查询多被动组合；999 为所有护甲"},
 {"armor_update","[target_id, passive_id?, enabled?, keep_original?, policy?] 设置多被动；policy: stack/strongest"},
 {"pending_preview","[] 列出未写入修改"},{"install_preview","[] 检查写入内容、护甲组合和冲突"},
 {"install","[] 安装当前数值与开启的 Mod，执行原项目写入流程；必须先关闭游戏"},
 {"restore","[] 恢复游戏原版并移除本程序部署的资源补丁；必须先关闭游戏"},
 {"managed_mods","[inputs] 设置 .dl_bin 合并输入；每项 {name,label,data}，二进制 data 使用 {$base64:...}"},
 {"mod_management","[enabled] 内部 Mod 协调开关；写入和预览会以界面的隐藏功能开关为准"},
 {"merge_named","[name, inputs] 按可信原版合并指定 .dl_bin；inputs 每项 {label,data}"},
 {"merge_mods","[base, inputs, policy] 底层 .dl_bin 合并与冲突报告；二进制用 {$base64:...}"},
 {"game_running","[] 查询游戏是否运行"},{"write_succeeded","[] 查询上次写入结果"},{"status","[] 后端状态"},
 {"flush","[] 保存未落盘的编辑器设置"},{"tick","[] 推进一次后端任务"}};
 auto add=[&](const std::string& name,const std::string& description,const Value& schema,bool readOnly){
  catalog.array.push_back(object({{"name",name},{"description",description},{"inputSchema",schema},
   {"annotations",object({{"readOnlyHint",readOnly},{"destructiveHint",!readOnly},{"openWorldHint",false}})}}));};
 auto positional=shodan::jsonParse(R"({"type":"object","properties":{"args":{"type":"array","items":{},"maxItems":8,"description":"按工具描述顺序传入的位置参数；无参数时传 []"}},"additionalProperties":false})");
 const std::set<std::string> reads={"items","rows","choices","shared","preset_info","full_presets","preset_compare","preset_export","preset_inspect","pending_preview","armor_rows","armor_profile","install_preview","game_running","write_succeeded","status"};
 for(const auto& entry:m.backend->interfaces().array)if(entry["type"].str()=="function"){
  auto name=entry["name"].str();m.mcpMethods.insert(name);auto it=signatures.find(name);
  add("shodan_"+name,it==signatures.end()?"现有后端接口 "+name:it->second,positional,reads.count(name)!=0);
 }
 auto empty=shodan::jsonParse(R"({"type":"object","properties":{},"additionalProperties":false})");
 add("shodan_debug_interfaces","列出所有后端接口与属性类型，核对 MCP 覆盖情况",empty,true);
 add("shodan_debug_runtime","调试：Lua 内存、栈、游戏路径、当前页面、选中装备和后端状态",empty,true);
 add("shodan_debug_logs","调试：最近 100 条 MCP 调用记录；不记录参数和连接令牌",empty,true);
 add("shodan_debug_log_files","调试：列出编辑器 Logs 目录中的日志文件",empty,true);
 add("shodan_debug_read_log","调试：读取指定日志末尾，最多 64 KiB；仅限 Logs 目录的文件名",
  shodan::jsonParse(R"({"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false})"),true);
 add("shodan_debug_self_test","调试：检查当前参数的数值、原值和范围，返回异常行；不写入游戏",empty,true);
 add("shodan_debug_property","调试：只读查询公开后端属性，例如 armor_list、armor_groups、game",
  shodan::jsonParse(R"({"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false})"),true);
 add("shodan_mods_list","列出 Mod 名称、描述、开关、选项与缓存路径。需在界面开启隐藏功能",empty,true);
 add("shodan_mods_import","导入本地 ZIP 路径列表，复用界面的格式检查和缓存流程",
  shodan::jsonParse(R"({"type":"object","properties":{"paths":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":32}},"required":["paths"],"additionalProperties":false})"),false);
 add("shodan_mods_update","设置 Mod 开关、名称、描述或选项；index 从 0 开始；关闭后重新写入游戏移除效果",
  shodan::jsonParse(R"({"type":"object","properties":{"index":{"type":"integer","minimum":0},"enabled":{"type":"boolean"},"name":{"type":"string"},"description":{"type":"string"},"choices":{"type":"array","items":{"type":"integer","minimum":0}}},"required":["index"],"additionalProperties":false})"),false);
 add("shodan_mods_remove","从管理列表移除指定 Mod；index 从 0 开始",
  shodan::jsonParse(R"({"type":"object","properties":{"index":{"type":"integer","minimum":0}},"required":["index"],"additionalProperties":false})"),false);
 add("shodan_mods_export","合并开启的 Mod 并导出 ZIP；指定绝对输出路径；已有文件会被覆盖",
  shodan::jsonParse(R"({"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false})"),false);
 return catalog;
}
void toggleMcp(){safe([]{
 if(m.mcp.enabled()){m.mcp.stop();m.message="MCP 已关闭，本地连接已断开";return;}
 m.mcp.start(mcpCatalog(),[]{app::requestUpdate();});m.message="MCP 已开启，连接配置可在设置中复制";
 // Enabling is deliberately session-only: restarting never opens a control endpoint.
});}
McpResult executeMcp(const shodan::McpRequest& request,std::vector<ManagedMod> mods){
 using shodan::object;const auto& a=request.arguments;const auto& name=request.name;McpResult out;
 if(name=="shodan_debug_interfaces")out.value=m.backend->interfaces();
 else if(name=="shodan_debug_runtime"){out.value=m.backend->diagnostics();out.value.fields["game_path"]=m.gamePath;out.value.fields["version"]=shodan::version;out.value.fields["page"]=m.page;out.value.fields["selected"]=m.selected;out.value.fields["mods_enabled"]=m.modsUnlocked;}
 else if(name=="shodan_debug_logs")out.value=m.mcp.logs();
 else if(name=="shodan_debug_log_files"){
  out.value.kind=Value::Table;auto folder=profile()/"Logs";if(std::filesystem::exists(folder))for(const auto& file:std::filesystem::directory_iterator(folder))if(file.is_regular_file()&&!file.is_symlink())out.value.array.push_back(object({{"name",file.path().filename().u8string()},{"bytes",double(file.file_size())}}));
 }else if(name=="shodan_debug_read_log"){
  const auto filename=std::filesystem::u8path(a["name"].str());if(filename.empty()||filename!=filename.filename()||filename==L"."||filename==L"..")throw std::runtime_error("日志名称无效");
  auto path=profile()/"Logs"/filename;if(std::filesystem::is_symlink(path)||!std::filesystem::is_regular_file(path))throw std::runtime_error("日志不存在");
  auto length=std::filesystem::file_size(path);std::ifstream file(path,std::ios::binary);if(!file)throw std::runtime_error("无法读取日志");file.seekg(length>65536?length-65536:0);out.value=std::string((std::istreambuf_iterator<char>(file)),{});
 }
 else if(name=="shodan_debug_property"){
  const auto key=a["name"].str();bool allowed=false;for(const auto& i:m.backend->interfaces().array)if(i["name"].str()==key&&i["type"].str()!="function")allowed=true;
  if(!allowed)throw std::runtime_error("只允许查询公开后端属性");out.value=m.backend->property(key.c_str());
 }else if(name=="shodan_debug_self_test"){
  auto rows=m.backend->call("rows");Value issues;issues.kind=Value::Table;issues.arrayValue=true;
  for(const auto& row:rows.array)if(row["value"].kind==Value::Number){const double v=row["value"].number;
   if(!std::isfinite(v)||(row["min"].kind==Value::Number&&v<row["min"].number)||(row["max"].kind==Value::Number&&v>row["max"].number))issues.array.push_back(row);}
  out.value=object({{"rows_checked",int(rows.array.size())},{"issues",issues},{"backend",m.backend->diagnostics()},{"game_writes",0}});
 }else if(name.rfind("shodan_mods_",0)==0){
  if(!m.modsUnlocked)throw std::runtime_error("请先在装备搜索栏输入 mu7，并确认开启隐藏功能");
  if(name=="shodan_mods_list"){
   out.value.kind=Value::Table;out.value.arrayValue=true;for(size_t i=0;i<mods.size();++i){const auto& mod=mods[i];Value choices;choices.kind=Value::Table;choices.arrayValue=true;for(int c:mod.choices)choices.array.emplace_back(c);
    Value options;options.kind=Value::Table;for(const auto& option:mod.options){Value children;children.kind=Value::Table;for(const auto& child:option.children)children.array.emplace_back(child.name);options.array.push_back(object({{"name",option.name},{"description",option.description},{"required",option.required},{"children",children}}));}
    out.value.array.push_back(object({{"index",int(i)},{"name",mod.name},{"description",mod.description},{"enabled",mod.enabled},{"path",mod.path.u8string()},{"choices",choices},{"options",options}}));}
  }else if(name=="shodan_mods_import"){
   std::vector<std::filesystem::path> paths;for(const auto& path:a["paths"].array){if(path.kind!=Value::String)throw std::runtime_error("paths 必须为路径列表");auto p=std::filesystem::u8path(path.str());if(!p.is_absolute())throw std::runtime_error("请使用绝对 ZIP 路径");paths.push_back(p);}if(paths.empty()||paths.size()>32)throw std::runtime_error("一次导入 1 至 32 个 ZIP");
   auto imported=importMods(paths,profile()/"Mods",32-mods.size());Value errors;errors.kind=Value::Table;for(auto& e:imported.errors)errors.array.emplace_back(e);
   out.value=object({{"imported",int(imported.mods.size())},{"errors",errors}});mods.insert(mods.end(),imported.mods.begin(),imported.mods.end());out.updateMods=true;
  }else if(name=="shodan_mods_export"){
   auto path=std::filesystem::u8path(a["path"].str());if(!path.is_absolute()||path.extension()!=L".zip")throw std::runtime_error("请提供绝对 ZIP 输出路径");out.value=exportModsTo(path);
  }else{
   if(a["index"].kind!=Value::Number||a["index"].number!=std::floor(a["index"].number)||a["index"].number<0||a["index"].number>=mods.size())throw std::runtime_error("Mod index 无效");size_t i=size_t(a["index"].number);
   if(name=="shodan_mods_remove")mods.erase(mods.begin()+i);
   else if(name=="shodan_mods_update"){
    auto& mod=mods[i];if(a.fields.count("enabled")){if(a["enabled"].kind!=Value::Boolean)throw std::runtime_error("enabled 必须为布尔值");mod.enabled=a["enabled"].yes();}
    for(const char* key:{"name","description"})if(a.fields.count(key)){if(a[key].kind!=Value::String)throw std::runtime_error("名称和说明必须是文本");(std::string(key)=="name"?mod.name:mod.description)=a[key].str();}
    if(a.fields.count("choices")){if(a["choices"].array.size()!=mod.options.size())throw std::runtime_error("choices 数量必须与选项组一致");mod.choices.clear();for(const auto& c:a["choices"].array){if(c.kind!=Value::Number||c.number!=std::floor(c.number)||c.number<0||c.number>64)throw std::runtime_error("选项编号无效");mod.choices.push_back(c.integer());}shodan::selectedModFiles(shodan::readModZip(mod.path),mod.choices);}
   }else throw std::runtime_error("未知 Mod 接口");out.updateMods=true;out.value=true;
  }out.mods=std::move(mods);
 }else{
  const auto method=name.rfind("shodan_",0)==0?name.substr(7):"";
  if(!m.mcpMethods.count(method))throw std::runtime_error("未知 MCP 工具");
  if((method=="managed_mods"||method=="merge_named"||method=="merge_mods"||method=="mod_management")&&!m.modsUnlocked)throw std::runtime_error("请先在界面开启隐藏功能");
  if(a.fields.count("args")&&a["args"].kind!=Value::Table)throw std::runtime_error("args 必须是数组");
  if(a["args"].array.size()>8)throw std::runtime_error("参数过多");
  if(method=="install"||method=="restore")out.value=performWrite(method);
  else if(method=="install_preview"){syncManagedMods();out.value=m.backend->call(method.c_str(),a["args"].array);}
  else out.value=m.backend->call(method.c_str(),a["args"].array);
 }return out;
}
void tickMcp(){
 using namespace std::chrono_literals;
 if(m.mcpWork.valid()&&m.mcpWork.wait_for(0ms)==std::future_status::ready){
  auto request=m.mcpRequest;m.mcpRequest.reset();m.busy=false;m.operationResult=false;
  try{auto result=m.mcpWork.get();if(result.updateMods){auto previous=m.mods;m.mods=std::move(result.mods);try{saveMods();}catch(...){m.mods=std::move(previous);throw;}}
   m.message="MCP 已完成："+request->name;refreshRows();for(const auto& armor:m.armor)m.armorValues[armor["id"].integer()]=m.backend->call("armor_rows",{armor["id"]}).array;
   // Selection is shared with the backend. Update the visible equipment title as well.
   if(request->name=="shodan_select"){
    auto id=request->arguments["args"].array.at(0).str();m.selected=id;
    for(const auto& tab:m.catalog)for(const auto& item:tab.second)if(item["id"].str()==id)m.selectedName=item["name"].str();
    updatePresetInfo();m.detailScroll.set(0);m.group=0;
   }
   request->response.set_value(std::move(result.value));
  }catch(...){request->response.set_exception(std::current_exception());m.message="MCP 调用失败，详情已返回客户端";}app::requestUpdate();
 }
 if(!m.mcp.enabled()||!m.backend||m.busy||m.reviewOpen||m.hiddenFeaturePrompt||!m.confirm.empty())return;
 auto request=m.mcp.take();if(!request)return;
 try{flushEdits();m.operationResult=false;m.busy=true;m.mcpRequest=request;
  {std::lock_guard<std::mutex> lock(m.progressMutex);m.progressMessage="MCP："+request->name;m.progressDone=0;m.progressTotal=0;}
  m.mcpWork=std::async(std::launch::async,[request,mods=m.mods]{return executeMcp(*request,mods);});
 }catch(...){m.busy=false;request->response.set_exception(std::current_exception());}app::requestUpdate();
}
WNDPROC originalWindowProcedure=nullptr;
struct LiveResize {int edge=0;POINT origin{};RECT initial{};unsigned frames=0;} liveResize;
bool resizeEdge(int hit){return hit==HTLEFT||hit==HTRIGHT||hit==HTTOP||hit==HTBOTTOM||hit==HTTOPLEFT||hit==HTTOPRIGHT||hit==HTBOTTOMLEFT||hit==HTBOTTOMRIGHT;}
LRESULT CALLBACK resizableWindowProcedure(HWND window,UINT message,WPARAM w,LPARAM l){
 if(message==WM_NCCALCSIZE&&w)return 0;
 // Keep GLFW's event/render loop running during an edge drag. Windows'
 // default non-client sizing loop otherwise pauses application composition.
 if(message==WM_NCLBUTTONDOWN&&resizeEdge(int(w))&&!IsZoomed(window)){
  liveResize.edge=int(w);liveResize.origin={LONG(short(LOWORD(l))),LONG(short(HIWORD(l)))};GetWindowRect(window,&liveResize.initial);
  liveResize.frames=0;SetCapture(window);app::requestUpdate();return 0;
 }
 if(message==WM_MOUSEMOVE&&liveResize.edge){
  POINT point={LONG(short(LOWORD(l))),LONG(short(HIWORD(l)))};ClientToScreen(window,&point);
  RECT rect=liveResize.initial;const int dx=point.x-liveResize.origin.x,dy=point.y-liveResize.origin.y,edge=liveResize.edge;
  const bool left=edge==HTLEFT||edge==HTTOPLEFT||edge==HTBOTTOMLEFT,right=edge==HTRIGHT||edge==HTTOPRIGHT||edge==HTBOTTOMRIGHT;
  const bool top=edge==HTTOP||edge==HTTOPLEFT||edge==HTTOPRIGHT,bottom=edge==HTBOTTOM||edge==HTBOTTOMLEFT||edge==HTBOTTOMRIGHT;
  if(left)rect.left=std::min(rect.right-1000,rect.left+dx);if(right)rect.right=std::max(rect.left+1000,rect.right+dx);
  if(top)rect.top=std::min(rect.bottom-680,rect.top+dy);if(bottom)rect.bottom=std::max(rect.top+680,rect.bottom+dy);
  SetWindowPos(window,nullptr,rect.left,rect.top,rect.right-rect.left,rect.bottom-rect.top,SWP_NOZORDER|SWP_NOACTIVATE);
  app::requestUpdate();return 0;
 }
 if((message==WM_LBUTTONUP||message==WM_CANCELMODE)&&liveResize.edge){liveResize.edge=0;ReleaseCapture();app::requestUpdate();return 0;}
 if(message==WM_CAPTURECHANGED&&liveResize.edge){liveResize.edge=0;app::requestUpdate();}
 if(message==WM_NCHITTEST&&!IsZoomed(window)){
  RECT bounds{};GetWindowRect(window,&bounds);const int x=int(short(LOWORD(l))),y=int(short(HIWORD(l)));
  const int edge=std::max(6,MulDiv(7,GetDpiForWindow(window),96));
  const bool left=x>=bounds.left&&x<bounds.left+edge,right=x<bounds.right&&x>=bounds.right-edge;
  const bool top=y>=bounds.top&&y<bounds.top+edge,bottom=y<bounds.bottom&&y>=bounds.bottom-edge;
  if(top&&left)return HTTOPLEFT;if(top&&right)return HTTOPRIGHT;if(bottom&&left)return HTBOTTOMLEFT;if(bottom&&right)return HTBOTTOMRIGHT;
  if(left)return HTLEFT;if(right)return HTRIGHT;if(top)return HTTOP;if(bottom)return HTBOTTOM;
 }
 return CallWindowProcW(originalWindowProcedure,window,message,w,l);
}
void installWindowResize(){
 HWND window=glfwGetWin32Window(glfwGetCurrentContext());
 originalWindowProcedure=reinterpret_cast<WNDPROC>(SetWindowLongPtrW(window,GWLP_WNDPROC,reinterpret_cast<LONG_PTR>(resizableWindowProcedure)));
 SetWindowLongPtrW(window,GWL_STYLE,GetWindowLongPtrW(window,GWL_STYLE)|WS_THICKFRAME|WS_MAXIMIZEBOX);
 SetWindowPos(window,nullptr,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOZORDER|SWP_FRAMECHANGED);
}
void centerStartupWindow(){
 auto* window=glfwGetCurrentContext();if(!window)return;
 HWND hwnd=glfwGetWin32Window(window);POINT pointer{};GetCursorPos(&pointer);
 MONITORINFO monitor{};monitor.cbSize=sizeof(monitor);
 if(!GetMonitorInfoW(MonitorFromPoint(pointer,MONITOR_DEFAULTTOPRIMARY),&monitor))return;
 RECT bounds{};GetWindowRect(hwnd,&bounds);const RECT work=monitor.rcWork;
 const int width=bounds.right-bounds.left,height=bounds.bottom-bounds.top;
 SetWindowPos(hwnd,nullptr,work.left+((work.right-work.left)-width)/2,
  work.top+((work.bottom-work.top)-height)/2,0,0,SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE);
}
void start(){
 {
  const bool modern=std::filesystem::exists(profile()/"mods-v2.txt");std::ifstream in(profile()/(modern?"mods-v2.txt":"mods.txt"),std::ios::binary);ManagedMod mod;std::string path;
  while(in>>mod.enabled>>std::quoted(path)>>std::quoted(mod.name)>>std::quoted(mod.description)){
   mod.path=std::filesystem::u8path(path);mod.choices.clear();mod.options.clear();
   if(modern){size_t count=0;if(!(in>>count)||count>64)break;for(size_t i=0;i<count;++i){int value=0;if(!(in>>value))break;mod.choices.push_back(value);}if(!in)break;}
   try{auto zip=shodan::readModZip(mod.path);mod.options=zip.options;if(!zip.title.empty())mod.name=zip.title;if(!zip.description.empty())mod.description=zip.description;mod.choices.resize(zip.options.size(),1);}catch(const std::exception& error){mod.description+="\n读取失败："+std::string(error.what());}
   m.mods.push_back(mod);if(m.mods.size()>=32)break;
  }
 }
 std::ifstream recent(profile()/"recent.txt");std::string id;while(recent>>id){if(id.size()==16&&m.recent.size()<40&&std::all_of(id.begin(),id.end(),[](unsigned char c){return std::isxdigit(c);}))m.recent.push_back(id);}
 std::ifstream f(profile()/"theme.txt");std::string s;f>>s;m.dark=s=="dark";
 {int pixels=18;std::ifstream font(profile()/"font-size.txt");font>>pixels;m.fontPixels=std::clamp(pixels,12,24);mutableConfig().uiScale(std::min(1.0f,110.4f/float(GetDpiForSystem()))*float(m.fontPixels)/16.0f);}
 {int mode=0;std::ifstream sidebar(profile()/"sidebar-mode.txt");sidebar>>mode;m.sidebarMode=std::clamp(mode,0,2);}
 m.loading=std::async(std::launch::async,[]{return std::make_unique<Backend>();});m.started=true;
}
void tick(){
 auto now=std::chrono::steady_clock::now();
 const float dt=std::min(0.05f,std::chrono::duration<float>(now-m.animationClock).count());m.animationClock=now;
 m.frameDelta=dt;
 if(m.pageProgress<1){m.pageProgress=std::min(1.0f,m.pageProgress+dt/0.20f);app::requestUpdate();}
 const float target=m.weaponPresetOpen?1.0f:0.0f;
 static float lastPresetTarget=0;
 const float presetDt=target!=lastPresetTarget?0:dt;lastPresetTarget=target;
 if(shodan::damped(m.presetProgress,m.presetVelocity,target,presetDt))app::requestUpdate();
 if(!hoveredHelp.empty())fadingHelp=hoveredHelp;
 const float helpTarget=hoveredHelp.empty()?0.0f:1.0f;
 static float lastHelpTarget=0;
 const float helpDt=helpTarget!=lastHelpTarget?0:dt;lastHelpTarget=helpTarget;
 helpOpacity+=(helpTarget-helpOpacity)*(1-std::exp(-helpDt*26));
 if(std::abs(helpTarget-helpOpacity)<0.01f){helpOpacity=helpTarget;if(helpTarget==0)fadingHelp.clear();}else app::requestUpdate();
 // Native scroll state remains the target. Only the content transform eases;
 // pointer hit testing follows that transform and dragging stays immediate.
 const std::string context=std::to_string(m.page)+":"+m.selected+":"+std::to_string(m.group)+":"+std::to_string(m.onlyChanged);
 const bool changed=context!=m.scrollContext;m.scrollContext=context;
 const bool pointerDown=glfwGetMouseButton(glfwGetCurrentContext(),GLFW_MOUSE_BUTTON_LEFT)==GLFW_PRESS;
 if(!pointerDown&&m.pendingFontPixels)safe([]{applyFontSize(m.pendingFontPixels);});
 if(!pointerDown)m.activeScroll.clear();const bool dragging=pointerDown&&!m.activeScroll.empty();
 auto smooth=[&](float& visual,float target,bool reset=false){
  if(reset||dragging)visual=target;
  else if(!pointerDown)visual+=(target-visual)*(1-std::exp(-dt*22.0f));
  if(std::abs(target-visual)<0.15f)visual=target;else app::requestUpdate();
 };
 smooth(m.detailVisual,m.detailScroll.get(),changed);smooth(m.armorVisual,m.armorScroll.get(),changed);smooth(m.armorValueVisual,m.armorValueScroll.get(),changed);
 smooth(m.listVisual,m.listScroll.get());smooth(m.choiceVisual,m.choiceScroll.get());smooth(m.fullVisual,m.fullScroll.get());smooth(m.reviewVisual,m.reviewScroll.get());
 if(std::getenv("SHODAN_EUI_QA")&&m.detailScroll.get()==104&&m.detailVisual>0.2f&&m.detailVisual<103.8f)m.qaSmoothObserved=true;
 if(std::getenv("SHODAN_EUI_QA")&&m.listScroll.get()==132&&m.listVisual>0.2f&&m.listVisual<131.8f)m.qaListSmoothObserved=true;
 using namespace std::chrono_literals;
 if(m.loading.valid()&&m.loading.wait_for(0ms)==std::future_status::ready){safe([&]{
  m.backend=m.loading.get();m.armor=m.backend->initialArmor;
  m.armorValues=m.backend->initialArmorValues;m.catalog=m.backend->initialCatalog;
  m.armorGroups=m.backend->property("armor_groups").array;m.gamePath=m.backend->property("game").str();
  reloadList(true);
  m.message="数据已载入 · 修改后点击「写入游戏」生效";
 });}
 if(m.reviewWork.valid()&&m.reviewWork.wait_for(0ms)==std::future_status::ready){
  try{m.reviewData=m.reviewWork.get();}catch(const std::exception& e){m.reviewData=Value();m.reviewData.kind=Value::Table;Value problems;problems.kind=Value::Table;problems.array.push_back(Value(e.what()));m.reviewData.fields["problems"]=problems;}
  m.reviewLoading=false;m.busy=false;app::requestUpdate();
 }
 if(m.modImport.valid()&&m.modImport.wait_for(0ms)==std::future_status::ready){
  m.busy=false;m.importingMods=false;
  safe([&]{
   auto result=m.modImport.get();const auto previous=m.mods;
   m.mods.insert(m.mods.end(),std::make_move_iterator(result.mods.begin()),std::make_move_iterator(result.mods.end()));
   try{saveMods();}catch(...){m.mods=previous;throw;}
   if(!result.mods.empty()){navigate(8);m.modScroll.set(0);}
   m.message="已导入 "+std::to_string(result.mods.size())+" 个 Mod；点击写入游戏后生效";
   if(!result.errors.empty()){m.error=result.errors.front();m.message+="；未导入 "+std::to_string(result.errors.size())+" 个："+result.errors.front();}
  });app::requestUpdate();
 }
 if(m.backend&&!m.busy&&!m.reviewOpen&&!m.operationResult&&!m.modInfoOpen&&m.modOptionsIndex<0&&!m.modQueue.empty()){
  auto paths=std::move(m.modQueue);m.modQueue.clear();const auto folder=profile()/"Mods";const auto available=32-m.mods.size();
  m.busy=true;m.importingMods=true;m.operationResult=false;m.message="正在导入 ZIP…";
  {std::lock_guard<std::mutex> lock(m.progressMutex);m.progressMessage="正在读取、校验并保存 Mod ZIP…";m.progressDone=0;m.progressTotal=0;}
  m.modImport=std::async(std::launch::async,[paths=std::move(paths),folder,available]{return importMods(paths,folder,available);});
 }
 if(m.operation.valid()&&m.operation.wait_for(0ms)==std::future_status::ready){
  m.busy=false;safe([&]{m.message=m.operation.get();if(m.page!=4)refreshRows();});m.operationResult=true;
 }
 tickMcp();
}
float fieldPitch(const Value& row){return 104.0f+(row["shared"].array.empty()?0.0f:30.0f)+(row["inline_note"].str().empty()?0.0f:28.0f);}
void field(eui::Ui& ui,const Value& r,float y,float w,bool armor=false){
 const int n=r["id"].integer();const std::string id=armor?r["key"].str():std::to_string(n);
 const std::string raw=armor?number(r["value"].number):r["text"].str();
 const std::string original=armor?number(r["default"].number):r["default_text"].str();
 const bool choice=r["choice"].yes(),flag=r["flag"].yes();
 const auto& shared=r["shared"].array;
 panel(ui,"field."+id,0,y,w,fieldPitch(r)-12);
 const auto label=r["label"].str();float titleWidth=0;
 for(unsigned char c:label){if(c<128)titleWidth+=8.5f;else if((c&0xC0)!=0x80)titleWidth+=17;}
 const bool hasHelp=!r["help"].array.empty();
 const float originalX=std::min(w-140.0f,18+titleWidth+(hasHelp?42:16));
 ui.text("label."+id).position(18,y+11).size(originalX-(hasHelp?54:30),24).text(label).fontSize(15).wrap(false).clip().color(theme().text).build();
 if(hasHelp){
 const std::string helpId=(armor?"armor.":"parameter.")+id;
 HelpHint hint;hint.title=label;
 for(const auto& line:r["help"].array)if(!line.str().empty())hint.lines.push_back(line.str());
 helpHints[helpId]=hint;
 ui.text("help.icon."+helpId).position(originalX-32,y+10).size(24,26).text("?").fontSize(19).color(theme().primary).build();
 ui.rect("help.hit."+helpId).position(originalX-36,y+7).size(32,30).color({0,0,0,0})
  .states({0,0,0,0},components::theme::withOpacity(theme().primary,0.12f),{0,0,0,0}).radius(12)
  .cursor(eui::CursorShape::Hand)
  .onHover([helpId](bool over){if(over)hoveredHelp=helpId;else if(hoveredHelp==helpId)hoveredHelp.clear();app::requestUpdate();})
  .onMove([](const eui::PointerEvent& event,const eui::Rect&){helpPointerX=float(event.x);helpPointerY=float(event.y);app::requestUpdate();}).build();
 if(std::getenv("SHODAN_EUI_QA")&&helpId==qaHelpTarget){
  if(auto* mark=ui.find("help.hit."+helpId))mark->onFrame=[mark](float){
   qaHelpX=mark->frame.x+mark->frame.width/2;qaHelpY=mark->frame.y+mark->frame.height/2;
  };
 }
 }
 text(ui,"original."+id,"原值 "+original,originalX,y+13,w-originalX-18,24,12,true);
 auto reset=[id,n,armor]{safe([&]{
  if(armor){for(const auto& row:m.backend->call("armor_rows",{m.armorDetail}).array)if(row["key"].str()==id)m.backend->call("armor_set",{m.armorDetail,id,row["default"]});m.edits.erase(id);m.armorValues[m.armorDetail]=m.backend->call("armor_rows",{m.armorDetail}).array;}
  else {m.backend->call("reset",{n});refreshRows();markRecent();}
  m.message="已恢复此项原始值";
 });};
 const float inputX=18.0f;
 const float inputW=w-184.0f;
 auto apply=[id,n,armor,raw]{safe([&]{
  const std::string value=m.edits.count(id)?m.edits[id]:raw;
  if(armor){auto v=m.backend->call("armor_set",{m.armorDetail,id,value});if(v.kind==Value::Nil)throw std::runtime_error("请输入有效的护甲数值");m.edits.erase(id);m.armorValues[m.armorDetail]=m.backend->call("armor_rows",{m.armorDetail}).array;m.message="护甲数值已保存";}
  else commit(n,value);
 });};
 if(r["code"].yes()){
  button(ui,"code."+id,raw+" · 录入",inputX,y+40,w-112,[n]{m.codeRow=n;m.codeArrows.clear();m.error.clear();});
 }else if(choice){
  button(ui,"choice."+id,r["choice_kind"].str()=="crosshair"?(r["value"].integer()==1?"关闭准星":r["value"].integer()==2?"始终显示准星":"原有准星样式 · "+raw):r["choice_name"].str().empty()?"选择名称 · ID "+raw:r["choice_name"].str()+" · #"+raw,inputX,y+40,w-112,[n]{safe([&]{m.choices=m.backend->call("choices",{n}).array;m.choiceRow=n;m.choiceQuery.clear();m.choiceScroll.set(0);m.choiceVisual=0;});});
 }else if(flag){
  button(ui,"flag."+id,r["value"].number>=0.5?"已启用":"已关闭",inputX,y+40,w-112,[n,r]{commit(n,r["value"].number>=0.5?"0":"1");},r["value"].number>=0.5);
 }else{
  components::input(ui,"input."+id).position(inputX,y+40).size(inputW,40).theme(theme()).style(inputStyle()).fontSize(17)
  .value(m.edits.count(id)?m.edits[id]:raw).onChange([id](const std::string& v){m.edits[id]=v;})
  .onEnter(apply).build();
  button(ui,"apply."+id,"应用",w-156,y+40,64,apply,true);
 }
 button(ui,"reset."+id,"恢复",w-80,y+40,64,reset);
 if(!r["inline_note"].str().empty())text(ui,"note."+id,r["inline_note"].str(),18,y+(shared.empty()?85:115),w-36,24,13,true);
 if(!shared.empty()){
  sharedHints[id]={r["label"].str(),shared};
  ui.text("shared.names."+id).position(18,y+86).size(w-36,26).text(sharedSummary(shared,w-36)).fontSize(13).lineHeight(20).color(theme().primary).build();
  ui.rect("shared.hit."+id).position(18,y+84).size(w-36,30).color({0,0,0,0})
   .states({0,0,0,0},components::theme::withOpacity(theme().primary,0.08f),{0,0,0,0})
   .cursor(eui::CursorShape::Hand).onMove([](const eui::PointerEvent&,const eui::Rect&){app::requestUpdate();}).onClick([r]{showShared(r["label"].str(),r["shared"].array);}).build();
 }

}
void groupedBrowser(eui::Ui& ui,float left,float height){
 struct Group {std::string id,name;std::vector<Value> items;float y=0,progress=0,height=0,angle=0;};
 struct Motion {float value=0,velocity=0;};
 static std::map<std::string,Motion> states;
 static std::string previousSearch;
 std::vector<Group> groups;std::map<std::string,size_t> index;
 const std::string searchContext=std::to_string(m.page)+":"+std::to_string(m.enemySub)+":"+m.query;
 const bool newSearch=searchContext!=previousSearch&&!m.query.empty();previousSearch=searchContext;
 for(const auto& item:m.items){
  const auto& memberships=item["groups"].array;
  if(memberships.empty()){
   const auto key=item["id"].str();index[key]=groups.size();Group group;group.id=key;group.name=item["name"].str();group.items.push_back(item);groups.push_back(std::move(group));
  }else for(const auto& membership:memberships){
   const auto key=membership["id"].str();auto found=index.find(key);
   if(found==index.end()){index[key]=groups.size();Group group;group.id=key;group.name=membership["name"].str();groups.push_back(std::move(group));}
   groups[index[key]].items.push_back(item);
  }
 }
 float total=0;std::string key=searchContext+":"+std::to_string(m.browserRevision)+":"+std::to_string(m.recentOnly)+":"+std::to_string(m.dark);
 for(auto& group:groups){
  if(newSearch)m.openBrowserGroups.insert(group.id);
  const bool open=m.openBrowserGroups.count(group.id)>0;auto& state=states[group.id];
  if(shodan::damped(state.value,state.velocity,open?1.0f:0.0f,m.frameDelta,24))app::requestUpdate();
  group.progress=std::clamp(state.value,0.0f,1.0f);group.angle=animatedArrow("browser."+group.id,open?1.57079633f:0);
  group.y=total;group.height=46+group.progress*(group.items.size()*44+8);total+=group.height+8;
  key+=":"+group.id+":"+std::to_string(group.progress)+":"+std::to_string(group.angle);
 }
 m.listMaximum=std::max(0.0f,total-(height-158));clampScroll(m.listScroll,m.listVisual,m.listMaximum);
 components::scrollView(ui,"equipment.list.scroll").theme(theme()).position(12,114).size(left-24,height-158)
 .bind(m.listScroll).onChange([](float offset){m.listScroll.set(offset);app::requestUpdate();}).step(60).scrollbarWidth(8).scrollbarGap(8).contentKey(key)
 .content([=](eui::Ui& content,float cw,float viewport){
  content.stack("equipment.list.canvas").size(cw,std::max(46.0f,total)).translateY(m.listScroll.get()-m.listVisual).content([&]{
   for(const auto& group:groups){
    if(group.y+group.height<std::min(m.listVisual,m.listScroll.get())-60||group.y>std::max(m.listVisual,m.listScroll.get())+viewport+60)continue;
    const auto id="browser.group."+group.id;bool active=false;for(const auto& item:group.items)if(item["id"].str()==m.selected)active=true;
    panel(content,id+".panel",0,group.y,cw,group.height);
    button(content,id+".toggle","",4,group.y+4,cw-8,[group]{if(m.openBrowserGroups.count(group.id))m.openBrowserGroups.erase(group.id);else m.openBrowserGroups.insert(group.id);++m.browserRevision;app::requestUpdate();},active,38);
    content.text(id+".label").position(12,group.y+11).size(std::max(20.0f,cw-44),26).text(group.name).fontSize(15).lineHeight(22).wrap(false).clip().color(theme().text).build();
    content.text(id+".arrow").position(cw-26,group.y+15).size(12,16).icon(0xF054).fontSize(11).lineHeight(14).rotate(group.angle).color(theme().primary).build();
    if(group.progress>0.001f)content.stack(id+".children").position(8,group.y+46).size(cw-16,std::max(0.0f,group.height-50)).clip().opacity(group.progress).disabled(group.progress<0.85f).content([&]{
     for(size_t i=0;i<group.items.size();++i){const Value item=group.items[i];
      std::string label=item["name"].str();if(label==group.name)label=m.page==2?"本体数据":"本体 / 变体数据";
      button(content,id+".item."+item["id"].str(),(item["changed"].yes()?"• ":"")+label,0,float(i*44),cw-16,[item]{safe([&]{select(item);});},item["id"].str()==m.selected,38);
     }
    }).build();
   }
   if(groups.empty())text(content,"list.empty","没有匹配的数据",8,12,cw-16,40,16,true);
  }).build();
 }).build();
}
void parameterPage(eui::Ui& ui,float w,float h){
 const bool player=m.page==10;
 const float left=w<850?220.0f:250.0f,gap=28,detailX=player?0:left+gap,detailW=w-detailX;
 if(!player){
 ui.stack("equipment.browser").size(left,h).content([&]{
 panel(ui,"list.panel",0,0,left,h);
 text(ui,"list.title",m.page==11?"选择敌人":m.page==12?"强化增益":"选择装备",20,18,left-126,28,18);
 button(ui,"list.recent",m.recentOnly?"显示全部":"最近编辑",left-110,14,94,[]{m.recentOnly=!m.recentOnly;reloadList();},m.recentOnly,32);
 components::input(ui,"equipment.search").position(16,62).size(left-32,42).theme(theme()).style(inputStyle()).placeholder("名称 / 型号 / 拼音首字母")
 .value(m.query).onChange(searchEquipment).build();
 if(m.page==2||m.page==11){groupedBrowser(ui,left,h);}else{
 m.listMaximum=std::max(0.0f,float(m.items.size()*44)-(h-158));
 clampScroll(m.listScroll,m.listVisual,m.listMaximum);
 const std::string listKey=std::to_string(m.page)+":"+std::to_string(m.sub)+":"+m.query+":"+std::to_string(m.recentOnly)+":"+std::to_string(m.items.size());
 // Search results update immediately; typing must not restart a list fade.
 const float listEnter=entrance("equipment.list",std::to_string(m.page)+":"+std::to_string(m.sub),0.16f);
 components::scrollView(ui,"equipment.list.scroll").theme(theme()).position(12,114).size(left-24,h-158)
 .bind(m.listScroll).onChange([](float offset){m.listScroll.set(offset);app::requestUpdate();}).step(60).scrollbarWidth(8).scrollbarGap(8).contentKey(listKey)
 .content([&](eui::Ui& content,float cw,float viewportHeight){
  content.stack("equipment.list.canvas").size(cw,std::max(44.0f,float(m.items.size()*44)))
  .opacity(0.65f+listEnter*0.35f).translateY(m.listScroll.get()-m.listVisual+(1-listEnter)*5).content([&]{
   const auto range=shodan::visibleRange(int(m.items.size()),1,44,viewportHeight,m.listVisual,m.listScroll.get());const int first=range.first,end=range.end;
   for(int i=first;i<end;++i){
    const Value item=m.items[i];const bool active=item["id"].str()==m.selected;
    button(content,"item."+item["id"].str(),(item["changed"].yes()?"• ":"")+item["name"].str(),0,float(i*44),cw,[item]{safe([&]{select(item);});},active,38);
   }
   if(m.items.empty())text(content,"list.empty","没有匹配的数据",8,12,cw-16,40,16,true);
  }).build();
 }).build();
 }
 text(ui,"list.count",std::to_string(m.items.size())+" 项",20,h-34,left-40,26,13,true);
 }).build();
 }
 const float detailEnter=entrance("details",std::to_string(m.page)+":"+m.selected);
 ui.stack("details").position(detailX,0).size(detailW,h).opacity(0.7f+detailEnter*0.3f).translateY((1-detailEnter)*6).content([&]{
  if(m.selected.empty()){text(ui,"no.selection","请先选择一项装备",24,30,detailW-48);return;}
  text(ui,"details.title",m.selectedName,0,4,detailW-128,40,25);
  button(ui,"reset.item","重置本项",detailW-118,0,118,[]{m.confirm="reset";});
  text(ui,"details.subtitle","直接输入数值，按 Enter 或点应用保存；恢复始终使用游戏原始值。",0,45,detailW,28,13,true);
  std::vector<std::string> groups={"全部参数"};for(const auto& r:m.rows){auto s=r["section"].str();if(!s.empty()&&std::find(groups.begin(),groups.end(),s)==groups.end())groups.push_back(s);}
  ui.stack("group.wrap").position(0,82).size(detailW-320,44).zIndex(30).content([&]{
   scrollDropdown(ui,"group",detailW-320,42,std::max(88.0f,h-164),groups,m.group,m.groupOpen,[](bool open){m.groupOpen=open;},[](int i){m.group=i;m.detailScroll.set(0);});
  }).build();
  button(ui,"changed.filter",m.onlyChanged?"显示全部":"仅看已修改",detailW-304,82,132,[]{m.onlyChanged=!m.onlyChanged;m.detailScroll.set(0);},m.onlyChanged);

  button(ui,"presets.toggle",m.page==11?(m.weaponPresetOpen?"单位预设 ▾":"单位预设 ▸"):(m.weaponPresetOpen?"装备预设 ▾":"装备预设 ▸"),detailW-156,82,156,[]{m.weaponPresetOpen=!m.weaponPresetOpen;m.detailScroll.set(0);},m.weaponPresetOpen);
  const float presetEase=m.presetProgress;
  const float fieldsTop=140.0f+158.0f*presetEase;
  if(m.presetProgress>0){
   ui.stack("presets.branch").position(0,136).size(detailW,148*presetEase).opacity(presetEase).translateY((1-presetEase)*-8).clip().disabled(m.presetProgress<0.95f).content([&]{
   panel(ui,"presets.inline",0,0,detailW,148);
   text(ui,"presets.context","仅作用于当前选中的装备",14,9,detailW-28,24,13,true);
   for(int i=1;i<=5;++i)button(ui,"slot."+std::to_string(i),std::to_string(i),14+(i-1)*44,42,36,[i]{m.preset=i;m.presetSlots[m.selected]=i;safe([]{updatePresetInfo();});},m.preset==i,36);
   components::input(ui,"preset.name").position(242,40).size(detailW-256,36).theme(theme()).style(inputStyle()).placeholder("预设名称")
    .value(m.presetLabel).onChange([](const std::string& s){m.presetLabel=s;}).build();
   const float pw=(detailW-78)/6;
   button(ui,"preset.save","保存",14,94,pw,[]{safe([&]{flushEdits();m.message=m.backend->call("preset",{"save",m.preset}).str();m.backend->call("preset_rename",{"weapon",m.preset,m.presetLabel});updatePresetInfo();});},true,36);
   button(ui,"preset.load","读取",24+pw,94,pw,[]{openReview("load-weapon",m.preset);},false,36);
   button(ui,"preset.rename","命名",34+pw*2,94,pw,[]{safe([]{m.message=m.backend->call("preset_rename",{"weapon",m.preset,m.presetLabel}).str();});},false,36);
   button(ui,"preset.import","导入",44+pw*3,94,pw,[]{importPreset("weapon",m.preset);},false,36);
   button(ui,"preset.export","导出",54+pw*4,94,pw,[]{exportPreset("weapon",m.preset);},false,36);
   button(ui,"preset.clear","清空",64+pw*5,94,pw,[]{m.confirm="clear-preset";},false,36);
   }).build();
  }
  components::scrollView(ui,"parameters.scroll").theme(theme()).position(0,fieldsTop).size(detailW,h-fieldsTop)
  .bind(m.detailScroll).onChange([](float offset){m.detailScroll.set(offset);app::requestUpdate();}).contentKey(m.selected+":"+std::to_string(m.group)+":"+std::to_string(m.onlyChanged)+":"+std::to_string(m.rowsRevision)).step(60).scrollbarWidth(8).scrollbarGap(12).content([&](eui::Ui& content,float cw,float viewportHeight){
   std::vector<Value> visible;for(const auto& r:m.rows){if(m.onlyChanged&&!r["changed"].yes())continue;if(m.group>0&&r["section"].str()!=groups[m.group])continue;visible.push_back(r);}
   const int columns=cw>=620?2:1;const float cardWidth=(cw-(columns-1)*14)/columns;
   const int rowCount=int((visible.size()+columns-1)/columns);
   std::vector<float> tops(rowCount+1,0);std::vector<float> pitches(rowCount,104);
   for(int row=0;row<rowCount;++row){for(int c=0;c<columns;++c){int i=row*columns+c;if(i<int(visible.size()))pitches[row]=std::max(pitches[row],fieldPitch(visible[i]));}
    tops[row+1]=tops[row]+pitches[row];}
   const float height=std::max(80.0f,tops.back());
   clampScroll(m.detailScroll,m.detailVisual,height-(h-fieldsTop));
   const float cardsEnter=entrance("fields",m.selected+":"+std::to_string(m.group)+":"+std::to_string(m.onlyChanged),0.20f);
   content.stack("fields.canvas").size(cw,height).translateY(m.detailScroll.get()-m.detailVisual).content([&]{
    int revealIndex=0;
    const float low=std::min(m.detailVisual,m.detailScroll.get()),high=std::max(m.detailVisual,m.detailScroll.get())+viewportHeight;
    for(int row=0;row<rowCount;++row){
     if(tops[row+1]<low-134||tops[row]>high+134)continue;
     for(int c=0;c<columns;++c){int i=row*columns+c;if(i>=int(visible.size()))break;
      const float x=float(c)*(cardWidth+14),y=tops[row],reveal=stagger(cardsEnter,revealIndex++);
      content.stack("field.wrap."+std::to_string(i)).position(x,y).size(cardWidth,pitches[row]-12).opacity(0.6f+reveal*0.4f).translateY((1-reveal)*7).content([&]{field(content,visible[i],0,cardWidth);}).build();
     }
    }
    if(visible.empty())text(content,"no.fields","当前筛选条件下没有参数",20,20,cw-40,30,17,true);
   }).build();
  }).build();
 }).build();
}
void armorPage(eui::Ui& ui,float w,float h){
 panel(ui,"armor.profile.panel",0,0,w,102);
 text(ui,"armor.profile.title","应用范围与叠加方式",20,12,w-40,26,15,true);
 const auto& groups=m.armorGroups;std::vector<std::string> labels;int selected=0;
 for(size_t i=0;i<groups.size();++i){int id=groups[i].integer();std::string s=id==999?"所有护甲":"被动 #"+std::to_string(id);for(const auto& a:m.armor)if(a["id"].integer()==id)s=a["zh"].str();labels.push_back(s);if(id==m.armorTarget)selected=int(i);}
 if(!m.busy)m.armorProfileView=m.backend->call("armor_profile",{m.armorTarget});
 const Value profile=m.armorProfileView;
 ui.stack("armor.target.wrap").position(20,48).size(236,38).zIndex(30).content([&]{scrollDropdown(ui,"armor.target",236,38,std::min(396.0f,h-112),labels,selected,m.armorTargetOpen,[](bool open){m.armorTargetOpen=open;},[groups](int i){m.armorTarget=groups.at(i).integer();});}).build();
 ui.stack("armor.own.wrap").position(280,46).size(210,40).content([&]{components::checkbox(ui,"armor.own").theme(theme()).size(210,40).fontSize(16).text("保留原生被动").checked(profile["own"].kind==Value::Nil||profile["own"].yes()).onChange([](bool b){safe([&]{m.backend->call("armor_update",{m.armorTarget,Value(),Value(),b});});}).build();}).build();
 button(ui,"armor.policy",profile["conflicts"].str()=="strongest"?"同类效果：保留最强":"同类效果：叠加",w-242,48,222,[profile]{safe([&]{m.backend->call("armor_update",{m.armorTarget,Value(),Value(),Value(),profile["conflicts"].str()=="strongest"?"stack":"strongest"});});});
 text(ui,"armor.instructions","勾选需要叠加的被动；点击「修改数值」打开编辑弹窗。",0,116,w,28,14,true);
 const int cols=w>=1000?4:w>=780?3:w>=520?2:1;
 components::scrollView(ui,"armor.cards").theme(theme()).position(0,154).size(w,h-154).bind(m.armorScroll).onChange([](float offset){m.armorScroll.set(offset);app::requestUpdate();}).contentKey("armor-grid-"+std::to_string(cols)+":"+std::to_string(m.armor.size())).step(60).content([&](eui::Ui& content,float cw,float viewportHeight){
  const float width=(cw-(cols-1)*14)/cols;
  clampScroll(m.armorScroll,m.armorVisual,float(((m.armor.size()+cols-1)/cols)*94)-(h-154));
  content.stack("armor.canvas").size(cw,float(((m.armor.size()+cols-1)/cols)*94)).translateY(m.armorScroll.get()-m.armorVisual).content([&]{
   const auto range=shodan::visibleRange(int(m.armor.size()),cols,94,viewportHeight,m.armorVisual,m.armorScroll.get());const int first=range.first,end=range.end;
   for(int i=first;i<end;++i){const auto a=m.armor[i];int id=a["id"].integer();float x=float(i%cols)*(width+14),y=float(i/cols)*94;
    panel(content,"passive.panel."+std::to_string(id),x,y,width,82);
    content.stack("passive.check.wrap."+std::to_string(id)).position(x+12,y+8).size(width-24,30).content([&]{components::checkbox(content,"passive.check."+std::to_string(id)).theme(theme()).size(width-24,30).fontSize(cols==4?14:15).text(a["zh"].str()).checked(profile["enabled"][std::to_string(id)].yes()).onChange([id](bool b){safe([&]{m.backend->call("armor_update",{m.armorTarget,id,b});});}).build();}).build();
    bool editable=!m.armorValues[id].empty();
    text(content,"passive.id."+std::to_string(id),"被动 ID "+std::to_string(id),x+14,y+40,width-128,24,12,true);
    if(editable)button(content,"passive.edit."+std::to_string(id),"修改数值",x+width-114,y+43,100,[id]{m.armorDetail=id;m.armorDialogId=id;m.armorValueScroll.set(0);m.armorValueVisual=0;m.edits.clear();},false,32);
   }
  }).build();
 }).build();
}
void armorValueDialog(eui::Ui& ui,const eui::Screen& screen){
 if(m.armorDetail>=0)m.armorDialogId=m.armorDetail;
 const int id=m.armorDialogId;
 const auto& values=m.armorValues[id];
 const float w=std::min(values.size()<=1?680.0f:920.0f,screen.width-64);
 const int columns=w-48>=620&&values.size()>1?2:1;
 const float h=std::min(screen.height-80,std::min(700.0f,std::max(252.0f,142.0f+float((values.size()+columns-1)/columns)*104)));
 auto close=[]{closeArmorValues();};
 components::dialog(ui,"armor.values.dialog").theme(theme()).style(dialogStyle()).screen(screen.width,screen.height)
 .size(w,h).open(m.armorDetail>=0).zIndex(70).transition(eui::Transition::make(0.26f,eui::Ease::OutCubic))
 .onOpenChange([close](bool open){if(!open)close();}).content([&]{
  if(id<0)return;
  std::string title="被动数值";for(const auto& a:m.armor)if(a["id"].integer()==id)title=a["zh"].str()+" · 数值修改";
  text(ui,"armor.modal.title",title,24,20,w-176,36,23);
  button(ui,"armor.modal.close","完成",w-126,18,102,close);
  text(ui,"armor.modal.note","修改后按 Enter 或点击应用；关闭弹窗时保存尚未提交的输入。",24,70,w-48,30,14,true);
  const auto& rows=m.armorValues[id];
  components::scrollView(ui,"armor.values.scroll").theme(theme()).position(24,118).size(w-48,h-142)
  .bind(m.armorValueScroll).onChange([](float offset){m.armorValueScroll.set(offset);app::requestUpdate();}).contentKey("armor-values-"+std::to_string(id)).step(60).content([&](eui::Ui& content,float cw,float){
   const int cols=cw>=620&&rows.size()>1?2:1;const float width=(cw-(cols-1)*14)/cols;
   content.stack("armor.values.canvas").size(cw,std::max(100.0f,float(((rows.size()+cols-1)/cols)*104)))
   .translateY(m.armorValueScroll.get()-m.armorValueVisual).content([&]{
    for(size_t i=0;i<rows.size();++i){
     content.stack("armor.value.wrap."+std::to_string(i)).position(float(i%cols)*(width+14),float(i/cols)*104).size(width,92)
     .content([&]{field(content,rows[i],0,width,true);}).build();
    }
   }).build();
  }).build();
 }).build();
}
void fullPresets(eui::Ui& ui,float w,float h){
 if(!m.busy)m.fullPresetView=m.backend->call("full_presets").array;
 const auto& entries=m.fullPresetView;
 panel(ui,"full.header",0,0,w,170);
 text(ui,"full.title",m.enemyMode?"敌人难度预设":"全局预设",24,20,w-210,36,22);
 button(ui,"full.import","导入预设",w-164,18,140,[]{importPreset("full");});
 text(ui,"full.help",m.enemyMode?"仅保存敌人与生成规则的修改；读取难度预设不会改动装备数值。":"保存所有装备和数据记录的数值修改；护甲叠加组合单独保存在护甲页。",24,64,w-48,46,15,true);
 components::input(ui,"full.name").position(24,116).size(w-230,40).theme(theme()).style(inputStyle()).placeholder("输入预设名称").value(m.presetName).onChange([](const std::string& v){m.presetName=v;}).build();
 button(ui,"full.new","保存为新预设",w-188,116,164,[]{safe([&]{flushEdits();m.message=m.backend->call("full_preset",{"new",0,m.presetName}).str();m.presetName.clear();});},true);
 clampScroll(m.fullScroll,m.fullVisual,float(entries.size()*96)-std::max(0.0f,h-236));
 const float fullEnter=entrance("full.list",std::to_string(entries.size()),0.22f);
 components::scrollView(ui,"full.list.scroll").theme(theme()).position(0,194).size(w,std::max(0.0f,h-236))
 .bind(m.fullScroll).onChange([](float offset){m.fullScroll.set(offset);app::requestUpdate();}).step(60).scrollbarWidth(8).scrollbarGap(12).contentKey("full-"+std::to_string(entries.size()))
 .content([&](eui::Ui& content,float cw,float viewportHeight){
  content.stack("full.list.canvas").size(cw,std::max(44.0f,float(entries.size()*96)))
  .opacity(fullEnter).translateY(m.fullScroll.get()-m.fullVisual+(1-fullEnter)*10).content([&]{
   const auto range=shodan::visibleRange(int(entries.size()),1,96,viewportHeight,m.fullVisual,m.fullScroll.get());const int first=range.first,end=range.end;
   for(int i=first;i<end;++i){auto p=entries[i];int id=p["id"].integer();float y=i*96;
    panel(content,"full.entry."+std::to_string(id),0,y,cw,82);
    text(content,"full.name."+std::to_string(id),p["name"].str(),20,y+12,cw-440,32,18);
    text(content,"full.count."+std::to_string(id),std::to_string(p["count"].integer())+" 项修改",20,y+46,cw-440,26,13,true);
    button(content,"full.load."+std::to_string(id),"读取",cw-402,y+20,72,[id]{openReview("load-full",id);});
    button(content,"full.overwrite."+std::to_string(id),"覆盖",cw-322,y+20,72,[id]{m.fullPreset=id;m.confirm="save-full";});
    button(content,"full.rename."+std::to_string(id),"命名",cw-242,y+20,72,[id,p]{m.renameId=id;m.renameText=p["name"].str();m.error.clear();});
    button(content,"full.export."+std::to_string(id),"导出",cw-162,y+20,72,[id]{exportPreset("full",id);});
    button(content,"full.delete."+std::to_string(id),"删除",cw-82,y+20,72,[id]{m.fullPreset=id;m.confirm="delete-full";});
   }
   if(entries.empty())text(content,"full.empty","尚未保存全局预设",20,10,cw-40,30,15,true);
  }).build();
 }).build();
 text(ui,"full.total",std::to_string(entries.size())+" 组预设",0,h-32,w,26,14,true);
}
void settingsContent(eui::Ui& ui,float w,float h){
 const bool narrow=w<650;const float extra=narrow?76:0,fontX=narrow?24:216,fontY=narrow?156:76;
 panel(ui,"settings.appearance",0,0,w,144+extra);
 text(ui,"settings.appearance.title","外观",24,22,w-48,32,22);
 button(ui,"settings.theme",m.dark?"切换到浅色":"切换到纯黑",24,76,170,[]{m.dark=!m.dark;saveTheme();});
 const int preview=m.pendingFontPixels?m.pendingFontPixels:m.fontPixels;
 text(ui,"settings.font.label","字体大小 "+std::to_string(preview)+" · 拖动预览，松开保存",fontX,narrow?120:32,w-fontX-24,32,15,true);
 const float sliderWidth=std::max(80.0f,w-fontX-256);
 ui.stack("settings.font.wrap").position(fontX,fontY).size(sliderWidth,44).content([&]{
  components::slider(ui,"settings.font.slider").theme(theme()).size(sliderWidth,40).value(float(preview-12)/12.0f)
   .onChange([](float value){m.pendingFontPixels=std::clamp(int(std::round(value*12))+12,12,24);app::requestUpdate();}).build();
 }).build();
 text(ui,"settings.font.preview","文字",w-232,fontY+5,88,36,float(preview));
 button(ui,"settings.font.reset","默认 18",w-132,fontY,108,[]{safe([]{applyFontSize(18);});});
 panel(ui,"settings.sidebar",0,156+extra,w,108);
 text(ui,"settings.sidebar.title","侧边栏显示",24,164+extra,w-48,28,18);
 const char* modes[]={"自动","展开","收起"};
 for(int i=0;i<3;++i)button(ui,"settings.sidebar."+std::to_string(i),modes[i],24+i*94,202+extra,84,[i]{safe([i]{m.sidebarMode=i;m.navScroll.set(0);std::filesystem::create_directories(profile());std::ofstream file(profile()/"sidebar-mode.txt");file<<i;if(!file)throw std::runtime_error("侧边栏设置保存失败");});},m.sidebarMode==i,36);
 panel(ui,"settings.game",0,288+extra,w,190);
 text(ui,"settings.game.title","游戏目录",24,310+extra,w-48,32,22);
 text(ui,"settings.game.path",m.gamePath,24,358+extra,w-48,60,16);
 text(ui,"settings.game.note","启动时沿用原项目自动查找游戏路径的流程。",24,428+extra,w-48,28,14,true);
 panel(ui,"settings.mcp",0,502+extra,w,174);
 text(ui,"settings.mcp.title","MCP 与调试接口",24,518+extra,w-250,32,22);
 button(ui,"settings.mcp.toggle",m.mcp.enabled()?"关闭 MCP":"开启 MCP",w-194,518+extra,170,toggleMcp,m.mcp.enabled());
 text(ui,"settings.mcp.endpoint",m.mcp.enabled()?m.mcp.endpoint():"默认关闭 · 仅当前会话开启 · 仅监听本机",24,566+extra,w-240,32,14,true);
 button(ui,"settings.mcp.copy","复制连接配置",w-194,568+extra,170,[]{if(m.mcp.enabled()){
  auto config=shodan::object({{"mcpServers",shodan::object({{"shodan",shodan::object({{"type","http"},{"url",m.mcp.endpoint()},{"headers",shodan::object({{"Authorization","Bearer "+m.mcp.token()}})}})}})}});
  glfwSetClipboardString(glfwGetCurrentContext(),shodan::jsonEncode(config).c_str());m.message="MCP 连接配置已复制，包含本次会话令牌";
 }});
 text(ui,"settings.mcp.note","开放现有编辑、预设、Mod 和写入接口；调试支持接口清单、状态、调用记录与参数自检。",24,618+extra,w-48,44,14,true);
 panel(ui,"settings.tweaks",0,700+extra,w,234);
 text(ui,"settings.tweaks.title","游戏设置 · 写入后生效",24,716+extra,w-48,32,20);
 const char* keys[]={"reticle","bounce","foliage"};const char* labels[]={"狙击步枪第三人称准星","战略球更易附着表面","射弹穿过树冠与灌木"};
 for(int i=0;i<3;++i){const std::string key=keys[i];const bool enabled=m.tweaks[key].yes();
  button(ui,"settings.tweak."+key,std::string(labels[i])+" · "+(enabled?"已启用":"已关闭"),24,760+extra+i*50,w-48,[key,enabled]{safe([&]{m.tweaks=m.backend->call("tweaks",{key,!enabled});m.message="设置已保存，写入游戏后生效";refreshRows();});},enabled,40);
 }
}
void settingsPage(eui::Ui& ui,float w,float h){
 components::scrollView(ui,"settings.scroll").theme(theme()).size(w,h).bind(m.settingsScroll).onChange([](float v){m.settingsScroll.set(v);app::requestUpdate();}).contentKey("settings-"+std::to_string(m.fontPixels)+":"+std::to_string(m.mcp.enabled())+":"+std::to_string(m.pendingFontPixels)+":"+std::to_string(m.dark)+":"+std::to_string(m.sidebarMode)+":"+std::to_string(m.tweaks["bounce"].yes())+":"+std::to_string(m.tweaks["reticle"].yes())+":"+std::to_string(m.tweaks["foliage"].yes())).content([&](eui::Ui& content,float cw,float vh){
  content.stack("settings.canvas").size(cw,cw<650?1010:934).content([&]{settingsContent(content,cw,1010);}).build();
 }).build();
}
void codeDialog(eui::Ui& ui,const eui::Screen& screen){
 auto submit=[] {safe([]{Value arrows;arrows.kind=Value::Table;arrows.arrayValue=true;for(int a:m.codeArrows)arrows.array.emplace_back(a);m.message=m.backend->call("code_set",{m.codeRow,arrows}).str();m.codeRow=0;refreshRows();});};
 const int keys[]={GLFW_KEY_UP,GLFW_KEY_RIGHT,GLFW_KEY_DOWN,GLFW_KEY_LEFT,GLFW_KEY_W,GLFW_KEY_D,GLFW_KEY_S,GLFW_KEY_A,GLFW_KEY_BACKSPACE,GLFW_KEY_ENTER,GLFW_KEY_ESCAPE};
 static bool held[11]={};
 for(int i=0;i<11;++i){const bool down=glfwGetKey(glfwGetCurrentContext(),keys[i])==GLFW_PRESS;const bool fresh=down&&!held[i];held[i]=down;
  if(!fresh||m.codeRow==0)continue;
  if(i<8){if(m.codeArrows.size()<9)m.codeArrows.push_back(i%4+1);}
  else if(i==8){if(!m.codeArrows.empty())m.codeArrows.pop_back();}
  else if(i==9)submit();else m.codeRow=0;
 }
 if(m.codeRow)app::requestUpdate();
 components::dialog(ui,"code.dialog").theme(theme()).style(dialogStyle()).screen(screen.width,screen.height).size(560,330).open(m.codeRow!=0).zIndex(170).transition(motion()).onOpenChange([](bool open){if(!open)m.codeRow=0;}).content([&]{
  text(ui,"code.title","录入战备指令",24,18,390,36,24);
  text(ui,"code.note","方向键或 WASD 录入 1～9 个方向；Enter 保存，退格撤回，Esc 取消。",24,62,512,52,15,true);
  const char* arrows[]={"↑","→","↓","←"};std::string line;for(int a:m.codeArrows){if(!line.empty())line+="  ";line+=arrows[a-1];}
  text(ui,"code.sequence",line.empty()?"请录入指令":line,24,122,512,42,24);
  for(int a=1;a<=4;++a)button(ui,"code.arrow."+std::to_string(a),arrows[a-1],24+(a-1)*80,178,68,[a]{if(m.codeArrows.size()<9)m.codeArrows.push_back(a);},false,42);
  button(ui,"code.undo","撤回",376,178,76,[]{if(!m.codeArrows.empty())m.codeArrows.pop_back();},false,42);
  text(ui,"code.error",m.error,24,228,512,32,14,true);
  button(ui,"code.cancel","取消",336,272,92,[]{m.codeRow=0;},false,40);button(ui,"code.save","保存",440,272,92,submit,true,40);
 }).build();
}
void choiceDialog(eui::Ui& ui,const eui::Screen& screen){

 std::vector<Value> filtered;for(const auto& c:m.choices)if(m.choiceQuery.empty()||(c["name"].str()+" "+std::to_string(c["id"].integer())).find(m.choiceQuery)!=std::string::npos)filtered.push_back(c);
 const float height=std::min(760.0f,screen.height-60);
 clampScroll(m.choiceScroll,m.choiceVisual,float(filtered.size()*52)-(height-202));
 components::dialog(ui,"choice.dialog").theme(theme()).style(dialogStyle()).screen(screen.width,screen.height).size(760,height).open(m.choiceRow!=0).transition(motion()).onOpenChange([](bool open){if(!open)m.choiceRow=0;}).content([&]{
  text(ui,"choice.title","按名称选择",26,22,580,38,25);
  button(ui,"choice.close","关闭",640,22,92,[]{m.choiceRow=0;});
  components::input(ui,"choice.search").position(26,80).size(708,44).theme(theme()).style(inputStyle()).placeholder("搜索子弹、效果名称或 ID")
  .value(m.choiceQuery).onChange([](const std::string& q){m.choiceQuery=q;m.choiceScroll.set(0);m.choiceVisual=0;}).build();
  const float choiceEnter=entrance("choice.list",std::to_string(m.choiceRow),0.16f);
  components::scrollView(ui,"choice.list.scroll").theme(theme()).position(26,146).size(708,height-202)
  .bind(m.choiceScroll).onChange([](float offset){m.choiceScroll.set(offset);app::requestUpdate();}).step(60).scrollbarWidth(8).scrollbarGap(12)
  .contentKey(std::to_string(m.choiceRow)+":"+m.choiceQuery+":"+std::to_string(filtered.size()))
  .content([&](eui::Ui& content,float cw,float viewportHeight){
   content.stack("choice.list.canvas").size(cw,std::max(52.0f,float(filtered.size()*52)))
   .opacity(choiceEnter).translateY(m.choiceScroll.get()-m.choiceVisual+(1-choiceEnter)*8).content([&]{
    const auto range=shodan::visibleRange(int(filtered.size()),1,52,viewportHeight,m.choiceVisual,m.choiceScroll.get());const int first=range.first,end=range.end;
    for(int i=first;i<end;++i){auto c=filtered[i];
     button(content,"choice.item."+std::to_string(c["id"].integer()),c["name"].str()+"  ·  ID "+std::to_string(c["id"].integer()),0,i*52,cw,[c]{safe([&]{m.message=m.backend->call("choose",{m.choiceRow,c["id"]}).str();refreshRows();markRecent();m.choiceRow=0;});},false,44);
    }
    if(filtered.empty())text(content,"choice.empty","没有匹配的数据",16,12,cw-32,30,15,true);
   }).build();
  }).build();
  text(ui,"choice.total",std::to_string(filtered.size())+" 项",26,height-40,708,26,14,true);
 }).build();
}
void acceptReview(){
 try{
  if(m.reviewAction=="install"){m.reviewOpen=false;runOperation("install");return;}
  if(m.reviewAction=="load-weapon"){
   m.message=m.backend->call("preset",{"load",m.reviewSlot}).str();refreshRows();markRecent();updatePresetInfo();
  }else if(m.reviewAction=="load-full"){
   m.message=m.backend->call("full_preset",{"load",m.reviewSlot}).str();refreshRows();
  }else{
   const std::string kind=m.reviewAction=="import-weapon"?"weapon":"full";
   auto result=m.backend->call("preset_import",{kind,m.reviewSlot,m.importText});m.message=result["message"].str();
   if(kind=="weapon")updatePresetInfo();
  }
  m.reviewOpen=false;
 }catch(const std::exception& e){m.reviewData.fields["problems"].kind=Value::Table;m.reviewData.fields["problems"].array.push_back(Value(e.what()));}
}
void parameterHelpHints(eui::Ui& ui,const eui::Screen& screen){
 if(sharedView.open||m.reviewOpen||m.choiceRow||m.busy||m.operationResult||!m.confirm.empty()||m.renameId>=0)return;
 const float px=helpPointerX,py=helpPointerY;
 for(const auto& pair:helpHints){
  const bool armorHint=pair.first.rfind("armor.",0)==0;
  if(armorHint!=(m.armorDetail>=0))continue;
  const std::string source="help.hit."+pair.first;if(!ui.find(source))continue;
  if(fadingHelp!=pair.first||helpOpacity<=0)continue;
  const float width=std::min(460.0f,screen.width-32),bodyWidth=width-32;
  std::vector<std::string> lines;
  for(const auto& paragraph:pair.second.lines){
   std::string line;float used=0;
   for(size_t i=0;i<paragraph.size();){
    const unsigned char c=paragraph[i];size_t count=c<128?1:(c&0xE0)==0xC0?2:(c&0xF0)==0xE0?3:4;
    count=std::min(count,paragraph.size()-i);const float advance=c<128?7.5f:14.5f;
    if(c=='\n'||used+advance>bodyWidth){lines.push_back(line);line.clear();used=0;}
    if(c!='\n'){line+=paragraph.substr(i,count);used+=advance;}i+=count;
   }
   if(!line.empty())lines.push_back(line);
  }
  const int maximum=std::max(1,int((screen.height-110)/24));
  if(int(lines.size())>maximum){lines.resize(maximum);lines.back()="…";}
  const float height=60+float(lines.size()*24);
  const float x=std::clamp(px+14,16.0f,std::max(16.0f,screen.width-width-16));
  const float y=std::clamp(py+height+20<screen.height?py+18:py-height-10,16.0f,std::max(16.0f,screen.height-height-16));
  auto popup=ui.stack("help.popup."+pair.first);
  popup.position(x,y).size(width,height).zIndex(650).disabled(true);
  popup.opacity(helpOpacity).translateY((1-helpOpacity)*4);
  popup.content([&]{
   panel(ui,"help.bg."+pair.first,0,0,width,height);
   ui.text("help.title."+pair.first).position(16,12).size(bodyWidth,28).text(pair.second.title).fontSize(17).wrap(false).clip().color(theme().primary).build();
   for(size_t i=0;i<lines.size();++i)
    ui.text("help.line."+pair.first+"."+std::to_string(i)).position(16,48+float(i*24)).size(bodyWidth,24).text(lines[i]).fontSize(14).lineHeight(22).wrap(false).clip().color(theme().text).build();
  }).build();
 }
}
void sharedNameHints(eui::Ui& ui,const eui::Screen& screen){
 if(sharedView.open||m.reviewOpen||m.choiceRow||m.armorDetail>=0||m.busy||!m.confirm.empty())return;
 POINT mouse{};GetCursorPos(&mouse);auto* window=glfwGetCurrentContext();auto hwnd=glfwGetWin32Window(window);ScreenToClient(hwnd,&mouse);
 RECT client{};GetClientRect(hwnd,&client);
 const float px=mouse.x*screen.width/std::max(1L,client.right),py=mouse.y*screen.height/std::max(1L,client.bottom);
 for(const auto& hint:sharedHints){
  const std::string source="shared.hit."+hint.first;if(!ui.find(source))continue;
  const auto& entries=hint.second.entries;
  const int columns=std::min(3,std::max(1,int((entries.size()+11)/12)));
  const float width=std::min(screen.width-32,float(columns*260+28));
  const int rows=std::min(int((entries.size()+columns-1)/columns),std::max(1,int((screen.height-140)/24)));
  const float height=58+rows*24;
  const float x=std::clamp(px+14,16.0f,std::max(16.0f,screen.width-width-16));
  const float y=std::clamp(py+height+20<screen.height?py+18:py-height-10,16.0f,std::max(16.0f,screen.height-height-16));
  auto popup=ui.stack("shared.hint."+hint.first);
  popup.position(x,y).size(width,height).zIndex(600).disabled(true);
  if(qaSharedHint&&qaSharedId==hint.first)popup.opacity(1);else popup.hoverOpacityFrom(source);
  popup.content([&]{
   panel(ui,"shared.hint.bg."+hint.first,0,0,width,height);
   text(ui,"shared.hint.title."+hint.first,"同时影响 "+std::to_string(entries.size())+" 项：",14,10,width-28,30,15);
   const int shown=std::min(int(entries.size()),columns*rows);
   for(int i=0;i<shown;++i){int col=i/rows,row=i%rows;
    ui.text("shared.hint.name."+hint.first+"."+std::to_string(i)).position(14+col*(width-28)/columns,44+row*24)
     .size((width-28)/columns-12,24).text(entries[i]["name"].str()).fontSize(14).lineHeight(20).wrap(false).clip().color(theme().text).build();
   }
   if(shown<int(entries.size()))text(ui,"shared.hint.more."+hint.first,"点击名称提示查看完整列表",14,height-24,width-28,22,12,true);
  }).build();
 }
}
void sharedDialog(eui::Ui& ui,const eui::Screen& screen){
 const float w=std::min(760.0f,screen.width-64);
 const float h=std::min(screen.height-80,std::min(650.0f,190.0f+float(sharedView.entries.size()*58)));
 components::dialog(ui,"shared.dialog").theme(theme()).style(dialogStyle()).screen(screen.width,screen.height).size(w,h)
 .open(sharedView.open).zIndex(250).transition(motion()).onOpenChange([](bool open){if(!open)sharedView.open=false;}).content([&]{
  text(ui,"shared.title","共享参数 · "+sharedView.title,24,18,w-170,38,23);
  button(ui,"shared.close","关闭",w-126,18,102,[]{sharedView.open=false;});
  text(ui,"shared.note","以下条目引用同一底层参数，修改会一并影响。仅列出当前已解析并验证的关联。",24,70,w-48,48,14,true);
  text(ui,"shared.count","另有 "+std::to_string(sharedView.entries.size())+" 项共用此参数",24,118,w-48,28,15);
  components::scrollView(ui,"shared.scroll").theme(theme()).position(24,156).size(w-48,std::max(30.0f,h-180))
   .bind(sharedView.scroll).onChange([](float offset){sharedView.scroll.set(offset);app::requestUpdate();}).step(58).scrollbarWidth(8).scrollbarGap(12)
   .contentKey(sharedView.title+":"+std::to_string(sharedView.entries.size())).content([&](eui::Ui& content,float cw,float viewport){
    content.stack("shared.canvas").size(cw,float(sharedView.entries.size()*58)).content([&]{
     const auto range=shodan::visibleRange(int(sharedView.entries.size()),1,58,viewport,sharedView.scroll.get(),sharedView.scroll.get());
     for(int i=range.first;i<range.end;++i){const auto& item=sharedView.entries[i];const float y=float(i*58);
      panel(content,"shared.item."+std::to_string(i),0,y,cw,50);
      text(content,"shared.name."+std::to_string(i),item["name"].str(),14,y+10,cw-110,30,16);
      text(content,"shared.kind."+std::to_string(i),item["category"].str(),cw-90,y+12,76,26,13,true);
     }
    }).build();
   }).build();
 }).build();
}
void reviewDialog(eui::Ui& ui,const eui::Screen& screen){
 const float w=std::min(980.0f,screen.width-64);
 const bool install=m.reviewAction=="install",importing=m.reviewAction.rfind("import-",0)==0;
 const auto& entries=m.reviewData["entries"].array;const auto& files=m.reviewData["files"].array;
 const auto& problems=m.reviewData["problems"].array;
 const bool sharedRows=std::any_of(entries.begin(),entries.end(),[](const Value& r){return !r["shared"].array.empty();});
 const float rowPitch=sharedRows?116.0f:88.0f;
 const float fileExtra=install&&m.reviewFilesOpen?std::min(160.0f,float(files.size()*22+8)):0;
 const float desired=!problems.empty()?520.0f:m.reviewLoading?300.0f:(install?166.0f:144.0f)+104+std::max(70.0f,float(entries.size())*rowPitch)+fileExtra;
 const float h=std::min(screen.height-64,std::min(760.0f,std::max(300.0f,desired)));
 components::dialog(ui,"review.dialog").theme(theme()).style(dialogStyle()).screen(screen.width,screen.height).size(w,h)
 .open(m.reviewOpen).zIndex(150).transition(motion()).onOpenChange([](bool open){if(!open&&!m.reviewLoading)m.reviewOpen=false;})
 .content([&]{
  text(ui,"review.title",install?"写入前预览":importing?"导入预设":"读取预设前对比",24,20,w-180,36,24);
  button(ui,"review.cancel","取消",w-126,18,102,[]{m.reviewOpen=false;});
  if(m.reviewLoading){text(ui,"review.loading","正在整理修改与文件清单…",24,106,w-48,40,18);return;}
  const std::string subtitle=install?"原始值 → 待写入值。确认后沿用原有流程写入游戏，请先关闭游戏。":importing?
   "导入只保存预设。下面列出今后读取它时，与当前数值相比的变化。":"当前值 → 预设值。未包含在预设中的参数会恢复为游戏原始值。";
  text(ui,"review.note",subtitle,24,70,w-48,44,14,true);
  if(!problems.empty()){
   std::string reason;for(const auto& problem:problems)reason+=problem.str()+"\n\n";
   components::scrollView(ui,"review.errors").theme(theme()).position(24,126).size(w-48,h-202).contentKey(reason).content([&](eui::Ui& content,float cw,float vh){
    const float lines=std::ceil(labelWidth(reason)/cw)+8;text(content,"review.error.body",reason,0,0,cw,std::max(vh,lines*22),15);
   }).build();
   text(ui,"review.blocked","未写入游戏。请调整冲突 Mod 或选项后重新预览。",24,h-56,w-48,36,14,true);return;
  }
  float top=144;
  if(install){
   button(ui,"review.files","涉及 "+std::to_string(files.size())+" 个游戏文件 "+(m.reviewFilesOpen?"▾":"▸"),24,118,260,[]{m.reviewFilesOpen=!m.reviewFilesOpen;},false,32);
   top=166;
   if(m.reviewFilesOpen){std::string names;for(const auto& file:files)names+=file.str()+"\n";
    const float fileHeight=std::min(160.0f,float(files.size()*22+8));
    components::scrollView(ui,"review.files.scroll").theme(theme()).position(30,160).size(w-60,fileHeight)
     .bind(m.reviewFileScroll).onChange([](float offset){m.reviewFileScroll.set(offset);app::requestUpdate();}).step(44)
     .contentKey(std::to_string(files.size())).content([&](eui::Ui& content,float cw,float){text(content,"review.filenames",names,0,0,cw,float(files.size()*22+8),13,true);}).build();
    top=166+fileHeight;
   }
  }else text(ui,"review.preset.name",m.reviewData["name"].str(),24,116,w-48,26,17);
  const float viewHeight=std::max(80.0f,h-top-104);
  clampScroll(m.reviewScroll,m.reviewVisual,float(entries.size())*rowPitch-viewHeight);
  components::scrollView(ui,"review.scroll").theme(theme()).position(24,top).size(w-48,viewHeight)
  .bind(m.reviewScroll).onChange([](float offset){m.reviewScroll.set(offset);app::requestUpdate();}).step(60).scrollbarWidth(8).scrollbarGap(12)
  .contentKey(m.reviewAction+":"+std::to_string(entries.size())+":"+std::to_string(top))
  .content([&](eui::Ui& content,float cw,float viewportHeight){
   content.stack("review.canvas").size(cw,std::max(70.0f,float(entries.size())*rowPitch)).translateY(m.reviewScroll.get()-m.reviewVisual).content([&]{
    auto range=shodan::visibleRange(int(entries.size()),1,rowPitch,viewportHeight,m.reviewVisual,m.reviewScroll.get());
    for(int i=range.first;i<range.end;++i){const auto& row=entries[i];float y=float(i)*rowPitch;
     panel(content,"review.row."+std::to_string(i),0,y,cw,rowPitch-12);
     text(content,"review.label."+std::to_string(i),row["equipment"].str()+" · "+row["parameter"].str(),14,y+8,cw-(row["shared"].array.empty()?28:154),26,15);
     text(content,"review.value."+std::to_string(i),row["before"].str()+"  →  "+row["after"].str(),14,y+39,cw-28,30,16);
     if(!row["shared"].array.empty()){
      button(content,"review.shared."+std::to_string(i),"共享 "+std::to_string(row["shared"].array.size())+" 项",cw-132,y+6,118,[row]{showShared(row["parameter"].str(),row["shared"].array);},false,28);
      std::string summary="同时影响：";int shown=0;for(const auto& user:row["shared"].array){if(shown==2)break;if(shown++)summary+="、";summary+=user["name"].str();}
      if(row["shared"].array.size()>2)summary+=" 等";
      text(content,"review.shared.names."+std::to_string(i),summary,14,y+71,cw-28,24,13,true);
     }

    }
    if(entries.empty())text(content,"review.empty",problems.empty()?"数值没有差异":"无法生成预览，请查看下方原因",16,16,cw-32,36,16,true);
   }).build();
  }).build();
  text(ui,"review.summary",problems.empty()?std::to_string(entries.size())+" 项数值或组合变化":problems.front().str(),24,h-90,w-48,34,14,!problems.empty());
  const bool allowed=problems.empty()&&(!install||!files.empty());
  components::button(ui,"review.accept").position(w-212,h-50).size(188,38).theme(theme(),true).radius(10).fontSize(16)
   .text(install?"确认写入游戏":importing?"确认导入预设":"确认读取预设").disabled(!allowed).onClick(acceptReview).build();
  text(ui,"review.foot",importing?"不会写入游戏文件":install?"仅在确认后执行写入":"读取后仍需点击写入游戏才生效",24,h-45,w-260,28,13,true);
 }).build();
 components::dialog(ui,"preset.rename.dialog").theme(theme()).style(dialogStyle()).screen(screen.width,screen.height).size(560,244)
 .open(m.renameId>=0).zIndex(150).transition(motion()).onOpenChange([](bool open){if(!open)m.renameId=-1;}).content([&]{
  text(ui,"rename.title","预设名称",24,20,500,36,23);
  components::input(ui,"rename.input").position(24,72).size(512,42).theme(theme()).style(inputStyle()).value(m.renameText)
   .onChange([](const std::string& value){m.renameText=value;}).build();
  text(ui,"rename.error",m.error,24,124,512,36,14,true);
  button(ui,"rename.cancel","取消",310,180,100,[]{m.renameId=-1;});
  button(ui,"rename.save","保存",430,180,106,[]{safe([]{m.message=m.backend->call("preset_rename",{"full",m.renameId,m.renameText}).str();m.renameId=-1;});},true);
 }).build();
}
void operationDialog(eui::Ui& ui,const eui::Screen& screen){

 std::string message;int done=0,total=0;
 {std::lock_guard<std::mutex> lock(m.progressMutex);message=m.busy?m.progressMessage:m.message;done=m.progressDone;total=m.progressTotal;}
 const float width=std::min(720.0f,screen.width-48);const float resultHeight=m.busy?300.0f:std::min(500.0f,screen.height-120);
 components::dialog(ui,"operation.progress").theme(theme()).style(dialogStyle()).screen(screen.width,screen.height)
 .size(width,resultHeight).open((m.busy&&!m.reviewLoading)||m.operationResult).zIndex(100).transition(motion())
 .onOpenChange([](bool open){if(!open&&!m.busy)m.operationResult=false;})
 .content([&]{
  text(ui,"operation.title",m.importingMods?"正在导入 Mod":m.busy?"正在处理游戏文件":"操作结果",24,22,width-48,36,23);
  if(m.busy)text(ui,"operation.message",message,24,78,width-48,100,16);
  else components::scrollView(ui,"operation.result.scroll").theme(theme()).position(24,78).size(width-48,resultHeight-156).contentKey(message).content([&](eui::Ui& content,float cw,float vh){
   const float lines=std::ceil(labelWidth(message)/cw)+8;text(content,"operation.message",message,0,0,cw,std::max(vh,lines*22),16);
  }).build();
  if(m.busy){
   ui.rect("operation.track").position(24,190).size(width-48,7).color(theme().border).radius(3).build();
   if(total>0){
    const float progress=std::clamp(float(done)/float(total),0.0f,1.0f);
    ui.rect("operation.fill").position(24,190).size((width-48)*progress,7).color(theme().primary).radius(3).transition(0.24f,eui::Ease::OutCubic).animate(eui::AnimProperty::Frame).build();
    text(ui,"operation.count","准备文件 "+std::to_string(done)+" / "+std::to_string(total),24,214,width-48,28,14,true);
   }else{
    const float travel=(width-48)*0.7f;
    const double now=glfwGetTime();float x=24+travel*float((std::sin(now*4.0)+1)*0.5);
    ui.rect("operation.indeterminate").position(x,190).size((width-48)*0.3f,7).color(theme().primary).radius(3).build();
    text(ui,"operation.wait","请稍候，完成后会在这里显示结果",24,214,width-48,28,14,true);
   }
  }else button(ui,"operation.done","关闭",width-132,resultHeight-62,108,[]{m.operationResult=false;});
 }).build();
}
// Opt-in framebuffer QA for this application only. No game writes or desktop
// input injection. Screenshots come from our own OpenGL swapchain.
void capture(const std::filesystem::path& file){
 auto* window=glfwGetCurrentContext();if(!window)return;
 int w=0,h=0;glfwGetFramebufferSize(window,&w,&h);if(w<=0||h<=0)return;
 std::vector<unsigned char> pixels(size_t(w)*h*4);
 glReadBuffer(GL_FRONT);glPixelStorei(GL_PACK_ALIGNMENT,4);glReadPixels(0,0,w,h,GL_BGRA,GL_UNSIGNED_BYTE,pixels.data());
 std::ofstream f(file,std::ios::binary);auto put=[&](unsigned v,int bytes){for(int i=0;i<bytes;++i)f.put(char(v>>(8*i)));};
 f.put('B');f.put('M');put(54+unsigned(pixels.size()),4);put(0,4);put(54,4);put(40,4);put(w,4);put(h,4);
 put(1,2);put(32,2);put(0,4);put(unsigned(pixels.size()),4);put(0,4);put(0,4);put(0,4);put(0,4);
 f.write(reinterpret_cast<const char*>(pixels.data()),pixels.size());
}
struct UiFrameSample {
 std::chrono::steady_clock::time_point start=std::chrono::steady_clock::now();
 bool enabled=std::getenv("SHODAN_EUI_QA")&&m.backend&&!m.busy;
 ~UiFrameSample(){if(enabled)m.frameSamples.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count());}
};
void qaDropZip(const std::filesystem::path& path,int count=1){
 const auto name=path.wstring();const size_t length=(name.size()+1)*count+1;
 HGLOBAL memory=GlobalAlloc(GHND,sizeof(DROPFILES)+length*sizeof(wchar_t));if(!memory)throw std::runtime_error("QA drop allocation failed");
 auto* header=static_cast<DROPFILES*>(GlobalLock(memory));header->pFiles=sizeof(DROPFILES);header->fWide=TRUE;
 auto* names=reinterpret_cast<wchar_t*>(reinterpret_cast<char*>(header)+sizeof(DROPFILES));
 for(int i=0;i<count;++i)std::copy(name.c_str(),name.c_str()+name.size()+1,names+i*(name.size()+1));
 GlobalUnlock(memory);SendMessageW(glfwGetWin32Window(glfwGetCurrentContext()),WM_DROPFILES,reinterpret_cast<WPARAM>(memory),0);
}
void qaTick(eui::Ui& ui){
 const char* target=std::getenv("SHODAN_EUI_QA");if(!target)return;
 app::requestUpdate();
 if(std::getenv("SHODAN_MCP_QA")){
  static int step=0;static auto due=std::chrono::steady_clock::now()+std::chrono::seconds(2);
  if(!m.backend||m.busy||std::chrono::steady_clock::now()<due)return;due=std::chrono::steady_clock::now()+std::chrono::milliseconds(350);
  try{
   const auto folder=std::filesystem::u8path(target);std::filesystem::create_directories(folder);
   if(step==0){if(m.mcp.enabled())throw std::runtime_error("MCP must default to disabled");
    // A locked manager must not even try to read a persisted enabled ZIP or
    // inspect/deploy an old resource ledger during ordinary numeric editing.
    m.mods.push_back({profile()/"missing-should-not-be-read.zip","QA locked","",true,{},{}});
    {std::ofstream file(profile()/"patch-install.txt");file<<"QA intentionally invalid ledger";}
    syncManagedMods();if(!m.preparedPatches.empty())throw std::runtime_error("Locked manager prepared patches");
    m.mods.pop_back();navigate(10);
   }
   else if(step==1){
    if(ui.find("equipment.browser")||m.items.size()!=1||m.rows.size()<20||m.items[0]["english"].str()!="Helldiver")throw std::runtime_error("Original helldiver category or full-width parameters missing");
    bool health=false;for(const auto& r:m.rows)if(r["label"].str()=="生命值"&&r["original"].number>0)health=true;
    if(!health)throw std::runtime_error("Original helldiver health missing");capture(folder/"helldiver.bmp");navigate(4);m.armorTargetOpen=true;
   }else if(step==2){auto* scroll=ui.find("armor.target.scroll");if(!scroll||!scroll->onScrollOffsetChanged)throw std::runtime_error("Armor dropdown does not scroll");scroll->onScrollOffsetChanged(100000);}
   else if(step==3){
    auto* scroll=ui.find("armor.target.scroll");if(!scroll||scroll->frame.height>400)throw std::runtime_error("Armor dropdown viewport not bounded");
    auto* option=ui.find("armor.target.option."+std::to_string(m.armorGroups.size()-1)+".bg");if(!option||!option->onClick)throw std::runtime_error("Last armor option missing");capture(folder/"armor-dropdown-bottom.bmp");option->onClick();
   }else if(step==4){if(m.armorTarget!=m.armorGroups.back().integer()||m.armorTargetOpen)throw std::runtime_error("Last armor dropdown option not selectable");m.armorTarget=999;navigate(6);}
   else if(step==5){
    if(!ui.find("brand.icon")||ui.find("brand"))throw std::runtime_error("Sidebar brand icon missing");
    for(int mode:{2,1,0}){auto* choice=ui.find("settings.sidebar."+std::to_string(mode)+".bg");if(!choice||!choice->onClick)throw std::runtime_error("Sidebar display setting missing");choice->onClick();if(m.sidebarMode!=mode)throw std::runtime_error("Sidebar display setting did not apply");}
    auto* slider=ui.find("settings.font.slider");if(!slider||!slider->onSliderValueChanged)throw std::runtime_error("Font slider has no change action");slider->onSliderValueChanged(10.0f/12.0f);}
   else if(step==6){if(m.fontPixels!=22)throw std::runtime_error("Custom font size did not apply");capture(folder/"font-size-22.bmp");applyFontSize(24);glfwSetWindowSize(glfwGetCurrentContext(),1000,680);}
   else if(step==7){
    auto* scroll=ui.find("navigation.scroll");auto* themeButton=ui.find("nav.theme");
    if(!scroll||!themeButton||!scroll->onScrollOffsetChanged||scroll->frame.y+scroll->frame.height>themeButton->frame.y)throw std::runtime_error("Large fonts overlap the bottom sidebar control");
    scroll->onScrollOffsetChanged(100000);
   }else if(step==8){
    if(m.navScroll.get()<=0||!m.qaResizeAnimationObserved)throw std::runtime_error("Small-window navigation or resize animation missing");capture(folder/"font-size-24-small-window.bmp");
    auto* arrow=ui.find("nav.branch.arrow");auto* branch=ui.find("nav.presets.bg");auto* folderIcon=ui.find("nav.branch.icon");
    if(!arrow||!branch||!folderIcon||arrow->frame.x<branch->frame.x||arrow->frame.x+arrow->frame.width>branch->frame.x+branch->frame.width||folderIcon->frame.x+folderIcon->frame.width>arrow->frame.x)throw std::runtime_error("Compact sidebar arrow escaped button or overlapped folder icon");
    applyFontSize(18);m.navScroll.set(0);glfwSetWindowSize(glfwGetCurrentContext(),1480,960);
   }else if(step==9){navigate(11);
    HWND window=glfwGetWin32Window(glfwGetCurrentContext());RECT rect{};GetWindowRect(window,&rect);
    SendMessageW(window,WM_NCLBUTTONDOWN,HTRIGHT,MAKELPARAM(rect.right-2,(rect.top+rect.bottom)/2));
    POINT point={rect.right-50,(rect.top+rect.bottom)/2};ScreenToClient(window,&point);SendMessageW(window,WM_MOUSEMOVE,MK_LBUTTON,MAKELPARAM(point.x,point.y));
   }else if(step==10){
    if(!liveResize.edge||liveResize.frames==0)throw std::runtime_error("Window content did not redraw during native edge drag");
    HWND window=glfwGetWin32Window(glfwGetCurrentContext());const RECT before=liveResize.initial;RECT current{};GetWindowRect(window,&current);
    if(current.right-current.left==before.right-before.left)throw std::runtime_error("Native edge drag did not resize window");
    SendMessageW(window,WM_LBUTTONUP,0,0);SetWindowPos(window,nullptr,before.left,before.top,before.right-before.left,before.bottom-before.top,SWP_NOZORDER|SWP_NOACTIVATE);
    if(!ui.find("nav.enemies")||!ui.find("enemy.kind.4")||m.items.size()<50)throw std::runtime_error("Enemy editor entry or faction categories missing");
    capture(folder/"v4-enemies.bmp");navigate(12);
   }else if(step==11){
    if(!ui.find("nav.boosters")||m.items.size()!=7)throw std::runtime_error("Booster category missing");capture(folder/"v4-boosters.bmp");navigate(1);
   }else if(step==12){
    bool found=false;for(const auto& r:m.rows)if(r["code"].yes()){m.codeRow=r["id"].integer();m.codeArrows.clear();found=true;break;}
    if(!found)throw std::runtime_error("Stratagem call-in row missing");
   }else if(step==13){
    auto* arrow=ui.find("code.arrow.4.bg");if(!arrow||!arrow->onClick)throw std::runtime_error("Call-in recording arrow not clickable");for(int i=0;i<9;++i)arrow->onClick();
   }else if(step==14){capture(folder/"v4-code-recorder.bmp");auto* save=ui.find("code.save.bg");if(!save||!save->onClick)throw std::runtime_error("Call-in save missing");save->onClick();if(m.codeRow)throw std::runtime_error("Call-in did not save");
   }else if(step==15){
    for(const auto& r:m.rows)if(r["code"].yes()){if(r["text"].str()!="← ← ← ← ← ← ← ← ←")throw std::runtime_error("Call-in arrows not retained");m.backend->call("reset",{r["id"]});break;}
    navigate(6);m.dark=false;
   }else if(step==16){capture(folder/"v4-logo-light.bmp");m.dark=true;
   }else if(step==17){capture(folder/"v4-logo-dark.bmp");m.dark=false;
   }else if(step==18){navigate(11);
   }else if(step==19){
    std::map<std::string,int> counts;for(const auto& item:m.items)for(const auto& group:item["groups"].array)++counts[group["id"].str()];
    bool found=false;for(const auto& item:m.items){for(const auto& group:item["groups"].array){auto id=group["id"].str();auto* toggle=ui.find("browser.group."+id+".toggle.bg");if(counts[id]>1&&toggle&&toggle->onClick){qaBrowserGroup=id;qaBrowserLabel=group["name"].str();toggle->onClick();found=true;break;}}if(found)break;}
    if(!found)throw std::runtime_error("Enemy subgroup toggle missing");
   }else if(step==20){
    auto* children=ui.find("browser.group."+qaBrowserGroup+".children");if(!children||children->height.value<50||!qaAnimatedArrows.count("browser."+qaBrowserGroup))throw std::runtime_error("Enemy subgroup did not animate open: "+qaBrowserGroup+" children="+(children?std::to_string(children->height.value):"missing")+" open="+std::to_string(m.openBrowserGroups.count(qaBrowserGroup))+" arrow="+std::to_string(qaAnimatedArrows.count("browser."+qaBrowserGroup)));
    capture(folder/"v4-enemy-group-expanded.bmp");searchEquipment(qaBrowserLabel);if(m.items.size()<2)throw std::runtime_error("Collapsed enemy subgroup search lost variants or weapons");navigate(2);
   }else if(step==21){
    bool found=false;for(const auto& item:m.items){for(const auto& group:item["groups"].array){auto id=group["id"].str();auto* toggle=ui.find("browser.group."+id+".toggle.bg");if(toggle&&toggle->onClick){qaBrowserGroup=id;qaBrowserLabel=group["name"].str();toggle->onClick();found=true;break;}}if(found)break;}
    if(!found)throw std::runtime_error("Vehicle subgroup toggle missing");
   }else if(step==22){
    auto* children=ui.find("browser.group."+qaBrowserGroup+".children");if(!children||children->height.value<50||!qaAnimatedArrows.count("browser."+qaBrowserGroup))throw std::runtime_error("Vehicle subgroup did not animate open");
    capture(folder/"v4-vehicle-group-expanded.bmp");searchEquipment(qaBrowserLabel);if(m.items.size()<2)throw std::runtime_error("Vehicle search lost mounted weapons");navigate(6);
   }else if(step==23){
    HWND window=glfwGetWin32Window(glfwGetCurrentContext());RECT rect{};GetWindowRect(window,&rect);
    auto hit=SendMessageW(window,WM_NCHITTEST,0,MAKELPARAM(rect.right-2,(rect.top+rect.bottom)/2));if(hit!=HTRIGHT)throw std::runtime_error("Frameless window cannot resize");
    auto* toggle=ui.find("settings.mcp.toggle.bg");if(!toggle||!toggle->onClick)throw std::runtime_error("MCP settings toggle missing");toggle->onClick();
    if(!m.mcp.enabled())throw std::runtime_error("MCP failed to start");
    std::ofstream(folder/"mcp-ready.json")<<shodan::jsonEncode(shodan::object({{"url",m.mcp.endpoint()},{"token",m.mcp.token()},{"player","4D1C334D294DFA97"}}));
   }else if(step==24){if(!std::filesystem::exists(folder/"mcp-done.txt"))return;
    capture(folder/"mcp-settings.bmp");toggleMcp();if(m.mcp.enabled())throw std::runtime_error("MCP did not close");
    std::ofstream(folder/"report.txt")<<"Helldiver full-width category and original health, armor dropdown scrolling and final option, font slider at 22/24, small-window navigation, resize intermediate frames, native resize hit test, MCP enable/disable, enemy and booster categories, nine-arrow call-in modal, dark and light logo verified. No game writes.\n";
    glfwSetWindowShouldClose(glfwGetCurrentContext(),GLFW_TRUE);
   }++step;
  }catch(const std::exception& e){capture(std::filesystem::u8path(target)/"failure.bmp");std::ofstream(std::filesystem::u8path(target)/"failure.txt")<<"MCP UI stage "<<step<<": "<<e.what();glfwSetWindowShouldClose(glfwGetCurrentContext(),GLFW_TRUE);}
  return;
 }
 static int stage=0;static bool smoothStarted=false;
 if(stage==8&&!smoothStarted){m.detailScroll.set(104);m.listScroll.set(132);smoothStarted=true;}
 static auto next=std::chrono::steady_clock::now()+std::chrono::seconds(2);
 if(!m.backend||m.importingMods||!m.modQueue.empty()||m.reviewLoading||(m.busy&&stage<10)||std::chrono::steady_clock::now()<next)return;
 next=std::chrono::steady_clock::now()+std::chrono::milliseconds(700);
 std::filesystem::create_directories(target);
 try{
  static const char* shots[]={"equipment","stratagems","vehicles","armor","armor-values","records","dark-choice","settings","equipment-presets","full-presets","install-progress","install-result"};
  if(stage<12)capture(std::filesystem::path(target)/(std::string(shots[stage])+".bmp"));
  if(stage==0)navigate(1);
  else if(stage==1)navigate(2);
  else if(stage==2)navigate(4);
  else if(stage==3){for(const auto& a:m.armor)if(!m.backend->call("armor_rows",{a["id"]}).array.empty()){m.armorDetail=a["id"].integer();break;}}
  else if(stage==4){
   const int id=m.armorDetail;const auto original=m.armorValues[id].front();const auto key=original["key"].str();
   m.edits[key]="invalid-value";closeArmorValues();
   if(m.armorDetail!=id||m.edits.empty())throw std::runtime_error("armor modal discarded invalid draft");
   const double nextValue=original["value"].number+1;
   m.edits[key]=number(nextValue);closeArmorValues();
   if(m.armorDetail!=-1||!m.edits.empty())throw std::runtime_error("armor modal failed to save and close");
   bool saved=false;for(const auto& row:m.armorValues[id])if(row["key"].str()==key&&row["value"].number==nextValue)saved=true;
   m.backend->call("armor_set",{id,key,original["value"]});m.armorValues[id]=m.backend->call("armor_rows",{id}).array;
   if(!saved||m.page!=4)throw std::runtime_error("armor modal failed to retain its page or saved value");
   navigate(5);
  }
  else if(stage==5){navigate(0);m.dark=true;for(const auto& r:m.rows)if(r["choice"].yes()){m.choices=m.backend->call("choices",{r["id"]}).array;m.choiceRow=r["id"].integer();break;}}
  else if(stage==6){m.choiceRow=0;navigate(6);}
  else if(stage==7){m.presetsExpanded=true;navigate(0);m.weaponPresetOpen=true;}
  else if(stage==8){
   if(!m.qaSmoothObserved||!m.qaListSmoothObserved)throw std::runtime_error("smooth scroll did not produce intermediate offsets");
   if(m.listScroll.get()!=132)throw std::runtime_error("equipment list scroll target changed");
   if(m.items.size()>4){select(m.items[4]);if(m.listScroll.get()!=132)throw std::runtime_error("equipment selection reset list scroll");}
   navigate(9);
  }
  else if(stage==9){
   navigate(0);m.detailScroll.set(104);m.armorScroll.set(94);
   m.busy=true;m.progressMessage="正在准备 generated_damage_settings.dl_bin…";m.progressDone=1;m.progressTotal=3;
  }
  else if(stage==10){m.busy=false;m.operationResult=true;m.message="进度显示测试完成，未写入游戏文件。";}
  else if(stage==11){m.operationResult=false;navigate(0);if(!m.qaListChanged)throw std::runtime_error("list scroll callback missing");m.qaListChanged(100000);}
  else if(stage>=12&&stage<=16){
   static const char* bottomShots[]={"primary-bottom","stratagem-bottom","vehicle-bottom","attachment-bottom","records-bottom"};
   capture(std::filesystem::path(target)/(std::string(bottomShots[stage-12])+".bmp"));
   if(m.items.empty()||std::abs(m.listScroll.get()-m.listMaximum)>0.5f)throw std::runtime_error("list bottom was not reached");
   const int nextPage[]={1,2,3,5};
   if(stage<16){navigate(nextPage[stage-12]);m.qaListChanged(100000);}
   else {navigate(0);m.detailScroll.set(104);}
  }
  else if(stage==17){
   glfwGetWindowSize(glfwGetCurrentContext(),&m.qaOriginalWidth,&m.qaOriginalHeight);
   glfwSetWindowSize(glfwGetCurrentContext(),1180,760);m.qaListChanged(100000);
  }
  else if(stage==18){
   capture(std::filesystem::path(target)/"resized-list-bottom.bmp");
   if(m.listScroll.get()<0||m.listScroll.get()>m.listMaximum+1)throw std::runtime_error("resized list exceeded its bounds");
   glfwSetWindowSize(glfwGetCurrentContext(),m.qaOriginalWidth,m.qaOriginalHeight);centerStartupWindow();navigate(0);
   for(const auto& row:m.rows)if(!row["choice"].yes()&&!row["flag"].yes()&&row["value"].kind==Value::Number){m.qaRow=row["id"].integer();m.qaBefore=row["value"].number;break;}
   if(!m.qaRow)throw std::runtime_error("no numeric QA row");
   m.backend->call("set",{m.qaRow,m.qaBefore+1});refreshRows();markRecent();
   openReview("install");
  }
  else if(stage==19){
   capture(std::filesystem::path(target)/"install-preview.bmp");
   if(m.reviewData["entries"].array.empty()||m.reviewData["files"].array.empty()||!m.reviewData["problems"].array.empty())throw std::runtime_error("write preview incomplete");
   m.reviewOpen=false;m.backend->call("preset",{"save",5});m.backend->call("preset_rename",{"weapon",5,"中文装备预设"});
   m.backend->call("set",{m.qaRow,m.qaBefore});refreshRows();openReview("load-weapon",5);
  }
  else if(stage==20){
   capture(std::filesystem::path(target)/"preset-comparison.bmp");
   if(m.reviewData["entries"].array.empty()||!m.reviewData["problems"].array.empty())throw std::runtime_error("preset comparison incomplete");
   m.reviewOpen=false;auto data=m.backend->call("preset_export",{"weapon",5}).str();openReview("import-weapon",4,data);
  }
  else if(stage==21){
   capture(std::filesystem::path(target)/"preset-import-preview.bmp");
   if(!m.reviewData["problems"].array.empty())throw std::runtime_error("portable preset inspection failed");
   acceptReview();if(m.reviewOpen||m.backend->call("preset_info",{4})["name"].str()!="中文装备预设")throw std::runtime_error("portable preset import failed");
   m.backend->call("full_preset",{"new",0,"全局功能测试"});
   for(const auto& p:m.backend->call("full_presets").array)if(p["name"].str()=="全局功能测试")m.qaFull=p["id"].integer();
   if(!m.qaFull)throw std::runtime_error("global preset creation failed");
   m.renameId=m.qaFull;m.renameText="中文全局预设";
  }
  else if(stage==22){
   capture(std::filesystem::path(target)/"preset-rename.bmp");
   m.backend->call("preset_rename",{"full",m.renameId,m.renameText});m.renameId=-1;
   auto data=m.backend->call("preset_export",{"full",m.qaFull}).str();
   auto result=m.backend->call("preset_import",{"full",0,data});m.qaImportedFull=result["id"].integer();
   if(!m.qaImportedFull)throw std::runtime_error("global preset import failed");
  }
  else if(stage==23){
   m.query="ar11";reloadList();if(m.items.empty())throw std::runtime_error("compact model search failed");
   const auto item=m.items.front();auto letters=shodan::initials(item["name"].str());
   m.query=letters;reloadList();if(m.items.empty())throw std::runtime_error("Chinese initials search failed");
   m.query=item["english"].str();reloadList();if(m.items.empty())throw std::runtime_error("English search failed");
   m.query.clear();m.recentOnly=true;reloadList();if(m.items.empty())throw std::runtime_error("recently edited search failed");
   m.recentOnly=false;reloadList();m.qaListChanged(0);m.qaListChanged(100000);m.qaListChanged(0);m.qaListChanged(100000);
  }
  else if(stage==24){
   capture(std::filesystem::path(target)/"rapid-scroll-bottom.bmp");
   if(std::abs(m.listScroll.get()-m.listMaximum)>1)throw std::runtime_error("rapid scroll lost its bounds");
   m.backend->call("set",{m.qaRow,m.qaBefore});m.backend->call("preset",{"clear",4});m.backend->call("preset",{"clear",5});
   m.backend->call("full_preset",{"delete",m.qaFull});m.backend->call("full_preset",{"delete",m.qaImportedFull});
   m.detailScroll.set(104);centerStartupWindow();
  }
  else if(stage==25){
   bool found=false;
   for(const auto& tab:std::vector<std::string>{"Support","Primary","Stratagems","Records"}){
    if(found)break;
    for(const auto& item:m.catalog[tab]){
     select(item);
     for(const auto& row:m.rows)if(!row["shared"].array.empty()){
      auto list=m.backend->call("shared",{row["id"]}).array;
      if(list.size()!=row["shared"].array.size())throw std::runtime_error("shared field list mismatch");
      for(const auto& entry:list)if(entry["id"].str()==m.selected||entry["name"].str().empty())throw std::runtime_error("invalid shared user");
      m.page=tab=="Records"?5:tab=="Stratagems"?1:0;m.sub=tab=="Support"?2:0;
      showShared(row["label"].str(),list);qaSharedId=std::to_string(row["id"].integer());
      float offset=0;const int wanted=(row["id"].integer()-1)/2;
      for(int pair=0;pair<wanted;++pair){float pitch=104;for(int c=0;c<2;++c){int at=pair*2+c;if(at<int(m.rows.size()))pitch=std::max(pitch,fieldPitch(m.rows[at]));}offset+=pitch;}
      m.detailScroll.set(offset);m.detailVisual=offset;found=true;break;
     }
     if(found)break;
    }
   }
   if(!found)throw std::runtime_error("no shared parameters were discovered in parsed data");
  }
  else if(stage==26){capture(std::filesystem::path(target)/"shared-parameter.bmp");sharedView.open=false;qaSharedHint=true;}
  else if(stage==27){
   capture(std::filesystem::path(target)/"shared-inline-names.bmp");qaSharedHint=false;m.sub=0;navigate(0);
   bool found=false;
   for(const auto& item:m.catalog["Primary"]){
    select(item);
    for(const auto& row:m.rows)if(!row["help"].array.empty()){
     qaHelpTarget="parameter."+std::to_string(row["id"].integer());
     float offset=0;const int wanted=(row["id"].integer()-1)/2;
     for(int pair=0;pair<wanted;++pair){float pitch=104;for(int c=0;c<2;++c){int at=pair*2+c;if(at<int(m.rows.size()))pitch=std::max(pitch,fieldPitch(m.rows[at]));}offset+=pitch;}
     m.detailScroll.set(offset);m.detailVisual=offset;found=true;break;
    }
    if(found)break;
   }
   if(!found)throw std::runtime_error("original parameter help not found");
  }
  else if(stage==28){
   if(helpHints.empty())throw std::runtime_error("parameter help anchors missing");
   if(qaHelpX<=0||qaHelpY<=0)throw std::runtime_error("question mark layout missing");
   core::queuePointerMotion(glfwGetCurrentContext(),qaHelpX*qaPointerScaleX,qaHelpY*qaPointerScaleY,{},{});
  }
  else if(stage==29){
   if(hoveredHelp!=qaHelpTarget)throw std::runtime_error("pointer did not enter question mark: "+hoveredHelp+" at "+number(qaHelpX)+","+number(qaHelpY));
   capture(std::filesystem::path(target)/"parameter-help.bmp");
   core::queuePointerMotion(glfwGetCurrentContext(),10,10,{},{});
  }
  else if(stage==30){
   if(!hoveredHelp.empty())throw std::runtime_error("help did not dismiss after pointer left");
   capture(std::filesystem::path(target)/"parameter-help-dismissed.bmp");navigate(0);m.detailScroll.set(104);
  }
  else if(stage==31){
   if(m.modsUnlocked||ui.find("nav.mods"))throw std::runtime_error("hidden Mod entry visible at startup");
   navigate(8);if(m.page==8)throw std::runtime_error("locked Mod page was reachable");
   if(const char* zip=std::getenv("SHODAN_MOD_QA_ZIP")){qaDropZip(std::filesystem::u8path(zip));if(!m.modQueue.empty())throw std::runtime_error("drop bypassed hidden feature gate");}
   auto* input=ui.find("equipment.search.hit");if(!input||!input->onTextInput)throw std::runtime_error("equipment search input missing");
   core::TextInputEvent event;event.text="mu7";input->onTextInput(event);
   if(!m.hiddenFeaturePrompt||m.modsUnlocked||!m.query.empty())throw std::runtime_error("mu7 search did not request confirmation");
  }
  else if(stage==32){
   if(ui.find("nav.mods")||m.modsUnlocked)throw std::runtime_error("Mod entry appeared before confirmation");
   capture(std::filesystem::path(target)/"hidden-feature-confirm.bmp");
   auto* cancel=ui.find("hidden.features.secondary.bg");if(!cancel||!cancel->onClick)throw std::runtime_error("hidden feature cancel action missing");cancel->onClick();
  }
  else if(stage==33){
   if(m.hiddenFeaturePrompt||m.modsUnlocked||ui.find("nav.mods"))throw std::runtime_error("cancel unlocked hidden features");
   navigate(1);searchEquipment("mu7");if(m.hiddenFeaturePrompt||m.modsUnlocked)throw std::runtime_error("other page search unlocked hidden features");
   navigate(0);searchEquipment("mu7");
  }
  else if(stage==34){
   auto* enable=ui.find("hidden.features.primary.bg");if(!enable||!enable->onClick)throw std::runtime_error("hidden feature enable action missing");enable->onClick();
   if(!m.modsUnlocked||m.hiddenFeaturePrompt)throw std::runtime_error("confirmation failed to enable hidden features");
  }
  else if(stage==35){
   if(!ui.find("nav.mods"))throw std::runtime_error("unlocked Mod sidebar entry missing");
   if(const char* zip=std::getenv("SHODAN_MOD_QA_ZIP")){m.qaModsBefore=m.mods.size();qaDropZip(std::filesystem::u8path(zip));}
  }
  else if(stage==36){
   if(const char* zip=std::getenv("SHODAN_MOD_QA_ZIP")){if(m.mods.size()!=m.qaModsBefore+1)throw std::runtime_error("first native ZIP drop missing");qaDropZip(std::filesystem::u8path(zip));}
  }
  else if(stage==37){
   if(const char* zip=std::getenv("SHODAN_MOD_QA_ZIP")){if(m.mods.size()!=m.qaModsBefore+2)throw std::runtime_error("second native ZIP drop missing");qaDropZip(std::filesystem::u8path(zip),2);}
  }
  else if(stage==38){
   if(std::getenv("SHODAN_MOD_QA_ZIP")){
    if(m.mods.size()!=m.qaModsBefore+4||m.page!=8||m.mods.back().description=="未提供说明")throw std::runtime_error("batched native ZIP drops or metadata missing");
    capture(std::filesystem::path(target)/"mod-manager.bmp");m.modInfoOpen=true;m.modInfoTitle=m.mods.back().name;m.modInfoText=m.mods.back().description;
   }
  }
  else if(stage==39){
   if(m.modInfoOpen)capture(std::filesystem::path(target)/"mod-description.bmp");
   m.modInfoOpen=false;navigate(0);m.detailScroll.set(104);
  }
  else if(stage==40){
   if(const char* directory=std::getenv("SHODAN_PATCH_QA_DIR")){
    m.qaModsBefore=m.mods.size();const auto root=std::filesystem::u8path(directory);
    qaDropZip(root/"HD2FP-fix.zip");qaDropZip(root/"HD2 HUD+ 0.1.6 Full Repair 0.5.3 + 头顶照明 Native Beacon 1.2.3 合并版.zip");qaDropZip(root/"HD2-Colored-Night-Vision.zip");
   }
  }
  else if(stage==41){
   if(std::getenv("SHODAN_PATCH_QA_DIR")){
    if(m.mods.size()!=m.qaModsBefore+3||m.mods[m.qaModsBefore+1].options.size()!=8||m.mods.back().name!="HD2 Colored Night Vision")throw std::runtime_error("actual patch ZIPs or options not imported");
    for(size_t i=0;i<m.mods.size();++i)m.mods[i].enabled=i==m.qaModsBefore+1;
    m.modOptionsIndex=int(m.qaModsBefore+1);m.modOptionsScroll.set(0);navigate(8);
   }
  }
  else if(stage==42){
   if(std::getenv("SHODAN_PATCH_QA_DIR")){
    capture(std::filesystem::path(target)/"hud-patch-options.bmp");auto numeric=modInputs();if(!numeric.array.empty()||m.preparedPatches.size()!=30)throw std::runtime_error("merged HUD default files not selected");
    chooseModOption(m.qaModsBefore+1,0,2);chooseModOption(m.qaModsBefore+1,3,0);numeric=modInputs();if(m.preparedPatches.size()!=27)throw std::runtime_error("HUD alternatives mixed together");
    chooseModOption(m.qaModsBefore+1,0,1);chooseModOption(m.qaModsBefore+1,3,1);m.modOptionsIndex=-1;
    m.mods[m.qaModsBefore].enabled=true;bool conflict=false;try{modInputs();}catch(const std::exception& error){conflict=std::string(error.what()).find("f476df93691895fa")!=std::string::npos;}if(!conflict)throw std::runtime_error("boot resource conflict silently accepted");
    openReview("install");
   }
  }
  else if(stage==43){
   if(std::getenv("SHODAN_PATCH_QA_DIR")){
    if(m.reviewData["problems"].array.empty())throw std::runtime_error("conflicting boot mods reached install confirmation");capture(std::filesystem::path(target)/"patch-conflict-preview.bmp");m.reviewOpen=false;
    for(size_t i=0;i<m.mods.size();++i)m.mods[i].enabled=i==m.qaModsBefore+2;
    auto numeric=modInputs();if(!numeric.array.empty()||m.preparedPatches.size()!=3)throw std::runtime_error("night vision resources not selected");saveMods();
   }
   navigate(0);m.detailScroll.set(104);
  }
  else if(stage==44){
   navigate(1);m.weaponPresetOpen=false;bool found=false;
   for(const auto& item:m.items)if(item["id"].str()=="EF85D6CF58E31D70"){
    select(item);for(const auto& row:m.rows)if(row["label"].str()=="炮塔持续时间（秒）"){
     m.qaRow=row["id"].integer();m.qaBefore=row["original"].number;
     if(m.qaBefore!=150||row["inline_note"].str()!="0 秒＝无限时间")throw std::runtime_error("sentry duration baseline or unlimited note missing");
     std::vector<std::string> groups={"全部参数"};for(const auto& r:m.rows){auto section=r["section"].str();if(!section.empty()&&std::find(groups.begin(),groups.end(),section)==groups.end())groups.push_back(section);}
     m.group=int(std::find(groups.begin(),groups.end(),row["section"].str())-groups.begin());m.detailScroll.set(100000);found=true;break;
    }break;
   }
   if(!found)throw std::runtime_error("Gatling sentry duration row not exposed");
  }
  else if(stage==45){
   const auto id=std::to_string(m.qaRow);auto* note=ui.find("note."+id);auto* card=ui.find("field."+id);
   if(!note||!card||note->text!="0 秒＝无限时间"||note->frame.y+note->frame.height>card->frame.y+card->frame.height+1)throw std::runtime_error("unlimited timer note is missing or outside its card");
   capture(std::filesystem::path(target)/"sentry-duration.bmp");m.edits[id]="0";
   auto* apply=ui.find("apply."+id+".bg");if(!apply||!apply->onClick)throw std::runtime_error("duration apply button missing");apply->onClick();
  }
  else if(stage==46){
   if(m.rows[m.qaRow-1]["value"].number!=0)throw std::runtime_error("UI duration input failed to save zero");capture(std::filesystem::path(target)/"sentry-duration-zero.bmp");
   auto* reset=ui.find("reset."+std::to_string(m.qaRow)+".bg");if(!reset||!reset->onClick)throw std::runtime_error("duration restore button missing");reset->onClick();
  }
  else if(stage==47){
   if(m.rows[m.qaRow-1]["value"].number!=m.qaBefore)throw std::runtime_error("UI duration restore lost original timer");navigate(0);m.detailScroll.set(104);
  }
  else if(stage==48){
   if(!m.qaResizeAnimationObserved)throw std::runtime_error("Window content did not animate during resizing");
   if(!qaAnimatedArrows.count("nav.presets")||!qaAnimatedArrows.count("presets.toggle"))throw std::runtime_error("expand arrows skipped intermediate rotation frames");
   if(m.page!=0||m.detailScroll.get()!=104)throw std::runtime_error("operation changed the current page or scroll position");
   auto samples=m.frameSamples;std::sort(samples.begin(),samples.end());
   std::ofstream report(std::filesystem::path(target)/"report.txt");
   report<<"Release "<<shodan::version<<": Sentry lifetime UI (150 seconds, zero, restore and visible unlimited-time note); hidden entry, mu7 search confirmation/cancel, equipment-only trigger and locked-drop gate; actual FP/HUD/NightVision ZIPs, mutually exclusive HUD choices and boot-conflict preview; repeated native ZIP drops (1, 1, 2 files), import metadata and description dialog passed; navigation and equipment preset arrows passed intermediate rotation checks; pointer enter/leave help passed.\n";
   report<<"Rendered editor pages, five list bottoms, resized/rapid scroll, install preview, preset comparison/import/rename and shared parameter impacts; no game writes.\n";
   HRGN region=CreateRectRgn(0,0,0,0);
   HWND hwnd=glfwGetWin32Window(glfwGetCurrentContext());RECT bounds{};GetWindowRect(hwnd,&bounds);
   const int regionType=GetWindowRgn(hwnd,region);
   const bool rounded=regionType!=ERROR&&!PtInRegion(region,0,0)&&PtInRegion(region,(bounds.right-bounds.left)/2,(bounds.bottom-bounds.top)/2);
   DeleteObject(region);
   if(!rounded)throw std::runtime_error("native rounded window region missing");
   MONITORINFO monitor{};monitor.cbSize=sizeof(monitor);
   if(!GetMonitorInfoW(MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST),&monitor))throw std::runtime_error("monitor work area missing");
   const RECT work=monitor.rcWork;
   if(std::abs((bounds.left+bounds.right)-(work.left+work.right))>2||std::abs((bounds.top+bounds.bottom)-(work.top+work.bottom))>2)
    throw std::runtime_error("startup window was not centered in monitor work area");
   report<<"Startup window center verified against monitor work area.\n";

   report<<"Native rounded window region verified; caption icons=26, targets=44x44.\n";
   report<<"Search (model, English, initials, recent), preset roundtrip and preview verified; parameter and equipment list smooth scroll intermediate positions verified; armor modal validates, saves, closes and retains its page.\n";

   if(!samples.empty())report<<"UI composition median="<<samples[samples.size()/2]<<" ms, p95="<<samples[std::min(samples.size()-1,size_t(samples.size()*0.95))]<<" ms; frames="<<samples.size()<<"\n";
   glfwSetWindowShouldClose(glfwGetCurrentContext(),GLFW_TRUE);
  }
  ++stage;
 }catch(const std::exception& e){
  std::ofstream(std::filesystem::path(target)/"failure.txt")<<"stage "<<stage<<": "<<e.what();
  capture(std::filesystem::path(target)/"failure.bmp");
  glfwSetWindowShouldClose(glfwGetCurrentContext(),GLFW_TRUE);
 }
}

}
DslAppConfig& mutableConfig(){
 static DslAppConfig c=DslAppConfig{}.title(std::string("SHODAN 数值编辑器 ")+shodan::version)
 .pageId("shodan.desktop").appId("shodan.desktop").decorated(false).windowSize(1480,960).minWindowSize(1000,680)
 .textFont("C:/Windows/Fonts/msyh.ttc").iconFont("assets/Font Awesome 7 Free-Solid-900.otf")
 .iconPath("assets/icon.png").clearColor({0,0,0,1}).fps(120)
 .uiScale(std::min(1.0f,110.4f/float(GetDpiForSystem())))
 .onStart([]{installWindowResize();centerStartupWindow();glfwSetDropCallback(glfwGetCurrentContext(),receiveModDrop);})
 .onShutdown([]{m.mcp.stop();if(m.mcpWork.valid())m.mcpWork.wait();if(m.modImport.valid())m.modImport.wait();if(m.operation.valid())m.operation.wait();if(m.reviewWork.valid())m.reviewWork.wait();if(m.loading.valid())m.loading.wait();m.backend.reset();});
 return c;
}
const DslAppConfig& dslAppConfig(){return mutableConfig();}
void composeEditor(eui::Ui& ui,const eui::Screen& screen){
 if(std::getenv("SHODAN_EUI_QA")){
  int width=0,height=0;glfwGetWindowSize(glfwGetCurrentContext(),&width,&height);
  qaPointerScaleX=width/std::max(1.0f,screen.width);qaPointerScaleY=height/std::max(1.0f,screen.height);
 }
 // Scroll views retain their composition while idle. Keep their help metadata
 // until the actual selection changes, rather than erasing it every frame.
 static std::string hintContext;
 const std::string context=std::to_string(m.page)+":"+m.selected+":"+std::to_string(m.rowsRevision)+":"+std::to_string(m.armorDetail);
 if(context!=hintContext){helpHints.clear();sharedHints.clear();hoveredHelp.clear();fadingHelp.clear();helpOpacity=0;hintContext=context;}
 if(!m.started)start();tick();
 if(m.loading.valid()||m.busy)app::requestUpdate();
 ui.rect("background").size(screen.width,screen.height).color(theme().background).transition(motion()).build();
 const bool compact=m.sidebarMode==2||(m.sidebarMode==0&&screen.width<1240);
 if(m.navWidth==0)m.navWidth=compact?76:208;
 if(shodan::damped(m.navWidth,m.navVelocity,compact?76.0f:208.0f,m.frameDelta,26))app::requestUpdate();
 const float nav=m.navWidth,pad=24,bodyX=nav+pad,bodyW=screen.width-bodyX-pad;
 auto navTheme=theme();navTheme.metrics.typography.label=8;navTheme.metrics.control.navigation=38;
 std::vector<components::NavbarItem> menu;const unsigned icons[]={0xF05B,0xF135,0xF5DE,0xF0AD,0xF3ED,0xF1C0,0xF013};
 for(int i=0;i<6;++i)menu.push_back({std::to_string(i),names[i],icons[i],i});
 menu.insert(menu.begin()+5,{"helldiver","潜兵数值",0xF183,10});
 menu.insert(menu.begin()+3,{"boosters","强化增益",0xF0E7,12});
 menu.push_back({"enemies","敌人编辑",0xF188,11});
 if(m.modsUnlocked)menu.push_back({"mods","Mod 管理",0xF126,8});
 menu.push_back({"presets","预设",m.presetsExpanded?0xF07Cu:0xF07Bu,7});
 if(m.presetsExpanded){menu.push_back({"full-presets","  全局预设",0xF5FD,9});}
 menu.push_back({"6","设置",0xF013,6});
 ui.stack("navigation").size(nav,screen.height).content([&]{
  ui.rect("navigation.background").size(nav,screen.height).color(theme().surface).build();
  const std::string ink=m.dark?"#d9fff0":"#20332b",accent=m.dark?"#52e5b1":"#087c5b";
  const std::string logo="<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 72 72'><path fill='"+ink+"' d='M8 17L29 5 49 17V28L29 17 18 23 40 35V43L18 55 29 61 49 50V61L29 72 8 60V49L29 37 8 25Z'/><path fill='"+accent+"' d='M29 25L40 31V43L29 49 18 43V31Z'/><path fill='none' stroke='"+accent+"' stroke-width='4' stroke-linecap='round' stroke-linejoin='round' d='M40 32L51 21H60M40 37H60M40 42L51 53H60'/><g fill='none' stroke='"+accent+"' stroke-width='4'><circle cx='64' cy='21' r='4'/><circle cx='64' cy='37' r='4'/><circle cx='64' cy='53' r='4'/></g></svg>";
  ui.svg("brand.icon").position((nav-48)/2,12).size(48,48).source(logo).tint({1,1,1,1}).contain().build();
  text(ui,"brand.version",shodan::version,compact?16:26,62,nav-32,18,11,true);
  const float navTop=compact?80.0f:92.0f;
  const float arrowAngle=animatedArrow("nav.presets",m.presetsExpanded?1.57079633f:0);
  const float navHeight=std::max(44.0f,screen.height-navTop-80);
  m.navScroll.set(std::clamp(m.navScroll.get(),0.0f,std::max(0.0f,float(menu.size()*48)-navHeight)));
  components::scrollView(ui,"navigation.scroll").position(0,navTop).size(nav,navHeight).theme(theme()).bind(m.navScroll).onChange([](float v){m.navScroll.set(v);app::requestUpdate();}).step(48).scrollbarWidth(4).scrollbarGap(0)
   .contentKey(std::to_string(m.page)+":"+std::to_string(menu.size())+":"+std::to_string(m.dark)+":"+std::to_string(compact)+":"+std::to_string(arrowAngle)).content([&](eui::Ui& content,float cw,float vh){
   content.stack("navigation.canvas").size(cw,float(menu.size()*48)).content([&]{
   for(size_t i=0;i<menu.size();++i){auto item=menu[i];
   components::button(content,"nav."+item.id).position(12,i*48).size(cw-24,40).theme(theme(),m.page==item.value)
    .text(compact?"":item.label).icon(compact&&item.value==7?0:item.icon).iconSize(16).fontSize(15).radius(10)
    .shadow(0,0,0,{0,0,0,0}).transition(motion()).onClick([item]{if(!m.backend||m.busy)return;if(item.value==7){m.presetsExpanded=!m.presetsExpanded;return;}navigate(item.value);}).build();
   if(auto* root=content.find("nav."+item.id)){root->transition=motion();root->transition.properties=core::AnimProperty::Frame;}
   if(item.value==7){
    if(compact)content.text("nav.branch.icon").position(21,i*48+11).size(18,18).icon(item.icon).fontSize(16).lineHeight(18).color(theme().text).build();
    content.text("nav.branch.arrow").position(cw-(compact?32:42),i*48+(compact?13:10)).size(compact?12:22,compact?14:22).icon(0xF054).rotate(arrowAngle).fontSize(compact?10:20).lineHeight(compact?14:22).color(theme().primary).build();
   }
   }
   }).build();
  }).build();
  button(ui,"nav.theme",compact?"◐":m.dark?"浅色模式":"纯黑模式",12,screen.height-64,nav-24,[]{m.dark=!m.dark;saveTheme();});
 }).build();
 const std::string pageName=m.page==11?"敌人编辑":m.page==12?"强化增益":m.page==10?"潜兵数值":m.page==8?"Mod 管理":m.page==9?(m.enemyMode?"敌人难度预设":"全局预设"):names[std::min(m.page,6)];
 const bool smallHeader=bodyW<650;
 text(ui,"page.heading",pageName,bodyX,22,std::max(100.0f,bodyW-(smallHeader?120:448)),38,26);
 if(!smallHeader)text(ui,"page.subtitle",m.page==4?"被动组合与数值分层管理":m.page>=6?"按工作流程分类管理，保持编辑区清晰":"选择装备，再编辑分组参数",bodyX,66,bodyW-320,28,14,true);
 button(ui,"install","写入游戏",smallHeader?bodyX:screen.width-408,smallHeader?72:22,142,[]{if(m.backend&&!m.busy)openReview("install");},true,44);
 button(ui,"restore","恢复原版",smallHeader?bodyX+156:screen.width-252,smallHeader?72:22,118,[]{if(m.backend&&!m.busy)m.confirm="restore";},false,44);
 if(!m.backend){
  panel(ui,"loading.panel",bodyX,150,bodyW,240);
  text(ui,"loading.title",m.error.empty()?"正在载入编辑器":"无法载入数据",bodyX+30,180,bodyW-60,44,25);
  text(ui,"loading.message",m.message,bodyX+30,244,bodyW-60,120,17,true);
  if(!m.error.empty())button(ui,"loading.retry","重新读取",bodyX+30,330,140,[]{m.error.clear();m.message="正在重新读取…";m.loading=std::async(std::launch::async,[]{return std::make_unique<Backend>();});});
 }else{
  float top=smallHeader?140:106;
  if(m.page==0){for(int i=0;i<4;++i)button(ui,"equipment.kind."+std::to_string(i),equipNames[i],bodyX+i*112,smallHeader?140:104,102,[i]{m.sub=i;safe([]{reloadList(true);});},m.sub==i);top=smallHeader?194:158;}
  if(m.page==11){const float width=std::min(150.0f,(bodyW-32)/5);for(int i=0;i<5;++i)button(ui,"enemy.kind."+std::to_string(i),enemyNames[i],bodyX+i*(width+8),smallHeader?140:104,width,[i]{m.enemySub=i;safe([]{reloadList(true);});},m.enemySub==i);top=smallHeader?194:158;}
  ui.stack("page.body").position(bodyX,top).size(bodyW,screen.height-top-68).disabled(m.busy||m.operationResult||!m.confirm.empty()||m.armorDetail>=0||m.choiceRow!=0||m.codeRow!=0||m.reviewOpen||m.renameId>=0||sharedView.open||m.modInfoOpen||m.modOptionsIndex>=0||m.hiddenFeaturePrompt).opacity(0.75f+0.25f*(1-(1-m.pageProgress)*(1-m.pageProgress))).translateY((1-m.pageProgress)*8).content([&]{
   if(m.page==4)armorPage(ui,bodyW,screen.height-top-68);
   else if(m.page==8)modPage(ui,bodyW,screen.height-top-68);
   else if(m.page==6)settingsPage(ui,bodyW,screen.height-top-68);
   else if(m.page==9)fullPresets(ui,bodyW,screen.height-top-68);
   else parameterPage(ui,bodyW,screen.height-top-68);
  }).build();
 }
 ui.rect("status.line").position(bodyX,screen.height-50).size(bodyW,1).color(theme().border).build();
 text(ui,"status.message",m.message,bodyX,screen.height-36,bodyW,38,14,true);
 armorValueDialog(ui,screen);
 choiceDialog(ui,screen);
 codeDialog(ui,screen);
 {
  static std::string retainedAction;
  if(!m.confirm.empty())retainedAction=m.confirm;
  auto action=retainedAction;
  const bool presetAction=action.find("full")!=std::string::npos||action=="clear-preset";
  components::dialog(ui,"confirm").theme(theme()).style(dialogStyle()).screen(screen.width,screen.height).size(560,256).open(!m.confirm.empty())
  .title(presetAction?"确认预设操作":action=="install"?"写入游戏":action=="restore"?"恢复游戏原始文件":"重置当前装备")
  .message(presetAction?"读取会替换当前数值，覆盖和删除会更改已保存的预设。确认后继续。":action=="install"?"将已保存的数值与护甲被动配置写入游戏。请先关闭游戏。":action=="restore"?"恢复已备份的游戏原始文件。编辑器中的配置将继续保留。":"将当前装备的所有参数恢复为游戏原始值。")
  .primaryText("确认").secondaryText("取消").transition(motion()).onOpenChange([](bool b){if(!b)m.confirm.clear();})
  .onPrimary([action]{m.confirm.clear();if(action=="reset")safe([]{m.backend->call("reset");refreshRows();});else if(action=="clear-preset")safe([]{m.message=m.backend->call("preset",{"clear",m.preset}).str();});
   else if(action.find("full")!=std::string::npos)safe([&]{std::string op=action.substr(0,action.find('-'));m.message=m.backend->call("full_preset",{op,m.fullPreset}).str();refreshRows();});
   else runOperation(action);})
  .onSecondary([]{m.confirm.clear();}).build();
 }
 components::dialog(ui,"hidden.features").theme(theme()).style(dialogStyle()).screen(screen.width,screen.height).size(560,252).open(m.hiddenFeaturePrompt).zIndex(160)
 .title("是否开启隐藏功能？").message("开启后，侧边栏将显示「Mod 管理」入口。仅在本次运行期间开启，重新启动后默认隐藏。")
 .primaryText("开启").secondaryText("取消").transition(motion()).onOpenChange([](bool open){if(!open)m.hiddenFeaturePrompt=false;})
 .onPrimary([]{m.modsUnlocked=true;m.hiddenFeaturePrompt=false;m.message="隐藏功能已开启，可从侧边栏进入 Mod 管理";})
 .onSecondary([]{m.hiddenFeaturePrompt=false;}).build();
 sharedNameHints(ui,screen);
 parameterHelpHints(ui,screen);
 sharedDialog(ui,screen);
 reviewDialog(ui,screen);
 operationDialog(ui,screen);
 modInfoDialog(ui,screen);
 modOptionsDialog(ui,screen);
 // Tooltips are root overlays, outside the sidebar scroll clip and above the
 // page, dropdowns and dialogs. Off-screen rows must never produce a tooltip.
 if(compact){const float navTop=80;
  for(size_t i=0;i<menu.size();++i){const auto& item=menu[i];const float y=navTop+i*48-m.navScroll.get();
   if(y+40<navTop||y>screen.height-80)continue;
   components::tooltip(ui,"nav.tip."+item.id).source("nav."+item.id+".bg").value(item.label).anchor(nav+62,y+36).bounds(screen.width,screen.height).theme(theme()).zIndex(500).build();
  }
 }
 // Virtualized content must be rebuilt in the same input frame, as well as
 // while its visual offset eases. A Signal alone does not schedule composition.
 for(const char* id:{"equipment.list.scroll","parameters.scroll","armor.cards","armor.values.scroll","choice.list.scroll","full.list.scroll","review.scroll","review.files.scroll","shared.scroll"}){
  if(auto* scroll=ui.find(id))scroll->composeOnScrollOffsetChange=true;
  if(auto* thumb=ui.find(std::string(id)+".scroll.thumb")){
   thumb->onPress=[key=std::string(id)](const eui::PointerEvent&,const eui::Rect&){m.activeScroll=key;};
   thumb->onRelease=[](const eui::PointerEvent&,const eui::Rect&){m.activeScroll.clear();};
  }
 }
 if(std::getenv("SHODAN_EUI_QA")){
  if(const auto* list=ui.find("equipment.list.scroll"))m.qaListChanged=list->onScrollOffsetChanged;
 }
 qaTick(ui);
}
// Clip the native window itself, including its outside corners. Rebuild the
// region only after a size/DPI change; Windows owns it after SetWindowRgn.
void updateWindowCorners(GLFWwindow* window){
 static HWND previous=nullptr;static int oldWidth=0,oldHeight=0;static UINT oldDpi=0;static bool oldMaximized=false;
 HWND hwnd=glfwGetWin32Window(window);RECT bounds{};GetWindowRect(hwnd,&bounds);
 const int width=bounds.right-bounds.left,height=bounds.bottom-bounds.top;
 const UINT dpi=GetDpiForWindow(hwnd);const bool maximized=IsZoomed(hwnd)!=FALSE;
 if(hwnd==previous&&width==oldWidth&&height==oldHeight&&dpi==oldDpi&&maximized==oldMaximized)return;
 if(maximized){if(!SetWindowRgn(hwnd,nullptr,TRUE))return;}
 else{
  const int diameter=MulDiv(28,dpi,96);
  HRGN region=CreateRoundRectRgn(0,0,width+1,height+1,diameter,diameter);
  if(!region)return;
  if(!SetWindowRgn(hwnd,region,TRUE)){DeleteObject(region);return;}
 }
 previous=hwnd;oldWidth=width;oldHeight=height;oldDpi=dpi;oldMaximized=maximized;
}
void windowControl(eui::Ui& ui,const char* id,unsigned int icon,float x,std::function<void()> action){
 components::button(ui,id).position(x,22).size(44,44).theme(theme()).radius(10)
 .text("").icon(icon).iconSize(26).pressScale(0.94f)
 .shadow(0,0,0,{0,0,0,0}).transition(motion()).onClick(std::move(action)).build();
}
void compose(eui::Ui& ui,const eui::Screen& screen){
 UiFrameSample frameSample;
 static float width=0,height=0,vx=0,vy=0;
 static auto last=std::chrono::steady_clock::now();auto now=std::chrono::steady_clock::now();float dt=std::chrono::duration<float>(now-last).count();last=now;
 if(width==0){width=screen.width;height=screen.height;}
 if(liveResize.edge){width=screen.width;height=screen.height;vx=vy=0;++liveResize.frames;}
 const bool movingX=shodan::damped(width,vx,screen.width,dt,32),movingY=shodan::damped(height,vy,screen.height,dt,32);
 if(std::getenv("SHODAN_EUI_QA")&&(std::abs(width-screen.width)>2||std::abs(height-screen.height)>2)&&(movingX||movingY))m.qaResizeAnimationObserved=true;
 if(movingX||movingY)app::requestUpdate();
 auto layout=screen;layout.width=width;layout.height=height;
 composeEditor(ui,layout);
 auto* window=glfwGetCurrentContext();
 updateWindowCorners(window);
 const float nav=m.navWidth;
 // The drag area sits behind the heading, with no separate bar or reserved row.
 ui.rect("window.drag").position(nav+16,0).size(std::max(0.0f,screen.width-nav-440),76)
 .color({0,0,0,0}).onPress([window](const eui::PointerEvent& e,const eui::Rect&){
  if(e.button==eui::PointerButton::Left){ReleaseCapture();SendMessageW(glfwGetWin32Window(window),WM_NCLBUTTONDOWN,HTCAPTION,0);}
 }).build();
 windowControl(ui,"window.minimize",0xF068,screen.width-116,[window]{glfwIconifyWindow(window);});
 windowControl(ui,"window.close",0xF00D,screen.width-64,[window]{glfwSetWindowShouldClose(window,GLFW_TRUE);});
}

}
