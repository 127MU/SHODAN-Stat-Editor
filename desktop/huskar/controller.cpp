#include "controller.h"
#include "mcp_catalog.h"
#include "release_update.h"
#include "mod_zip.h"
#include "patch_mods.h"
#include <QtConcurrent>
#include <QFutureWatcher>
#include <QCoreApplication>
#include <QClipboard>
#include <QApplication>
#include <QDesktopServices>
#include <QUrl>
#include <QDir>
#include <QFileDialog>
#include <QFile>
#include <QSaveFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QQuickWindow>
#include <QImage>
#include <QImageReader>
#include <QFileInfo>
#include <QCryptographicHash>
#include <QQuickItem>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QEventLoop>
#include <QInputMethodEvent>
#include <QFocusEvent>
#include <QJSValue>
#include <QMetaProperty>
#include "hustheme.h"
#include <fstream>
#include <iomanip>
#include <regex>
#include <set>
#include <cmath>

namespace {
QString qs(const std::string& s){return QString::fromUtf8(s.data(),int(s.size()));}
std::string utf(const QString& s){auto b=s.toUtf8();return {b.data(),size_t(b.size())};}
std::filesystem::path fp(const QString& s){return std::filesystem::path(s.toStdWString());}
QVariant plain(QVariant q){
 if(q.metaType()==QMetaType::fromType<QJSValue>())q=q.value<QJSValue>().toVariant();
 if(q.typeId()==QMetaType::QVariantList){QVariantList out;for(const auto& x:q.toList())out<<plain(x);return out;}
 if(q.typeId()==QMetaType::QVariantMap){auto out=q.toMap();for(auto i=out.begin();i!=out.end();++i)i.value()=plain(i.value());return out;}
 return q;
}
QVariant variant(const Value& v){
 switch(v.kind){
 case Value::String:return qs(v.text);
 case Value::Number:return v.number;
 case Value::Boolean:return v.boolean;
 case Value::Table:
  if(v.arrayValue||!v.array.empty()){QVariantList l;for(const auto& a:v.array)l<<variant(a);return l;}
  else{QVariantMap m;for(const auto& a:v.fields)m[qs(a.first)]=variant(a.second);return m;}
 default:return {};}
}
Value value(const QVariant& q){
 if(!q.isValid()||q.isNull())return {};
 switch(q.typeId()){
 case QMetaType::Bool:return Value(q.toBool());
 case QMetaType::QVariantList:{Value v;v.kind=Value::Table;v.arrayValue=true;for(const auto& a:q.toList())v.array.push_back(value(a));return v;}
 case QMetaType::QVariantMap:{Value v;v.kind=Value::Table;const auto m=q.toMap();for(auto i=m.begin();i!=m.end();++i)v.fields[utf(i.key())]=value(i.value());return v;}
 case QMetaType::QString:return Value(utf(q.toString()));
 default:return Value(q.toDouble());}
}
}
struct Controller::State {
 struct Mod{QString path,name,description;bool enabled=true;std::vector<int> choices;};
 std::vector<Mod> mods;
 bool modsUnlocked=false;
 std::vector<shodan::ModFile> patches;
 Value catalog;
 std::set<std::string> methods;
};

Controller::Controller(QObject* parent):QObject(parent),state_(new State){
 profile_=qEnvironmentVariable("SHODAN_PROFILE");
 if(profile_.isEmpty())profile_=qEnvironmentVariable("LOCALAPPDATA")+"/SHODAN/StatEditor";
 QDir().mkpath(profile_);
 settings_=std::make_unique<QSettings>(profile_+"/huskar-ui.ini",QSettings::IniFormat);
 worker_=new QObject;worker_->moveToThread(&thread_);
 connect(&thread_,&QThread::finished,worker_,&QObject::deleteLater);
 thread_.start();
 QTimer::singleShot(0,this,[this]{start();if(!qEnvironmentVariableIsSet("SHODAN_HUSKAR_QA"))checkUpdate();});
 connect(&mcpTimer_,&QTimer::timeout,this,&Controller::pollMcp);mcpTimer_.start(40);
}
Controller::~Controller(){
 mcp_.stop();
 QMetaObject::invokeMethod(worker_,[this]{backend_.reset();},Qt::BlockingQueuedConnection);
 thread_.quit();thread_.wait();
}
void Controller::start(){
 QMetaObject::invokeMethod(worker_,[this]{
  try{
   backend_=std::make_unique<Backend>();
   backend_->onProgress=[this](const std::string& s,int d,int n){emit progress(qs(s),d,n);};
   QVariantMap catalogs;
   for(const auto& cat:backend_->initialCatalog){QVariantList items;for(const auto& item:cat.second)items<<variant(item);catalogs[qs(cat.first)]=items;}
   QVariantMap data{{"catalogs",catalogs},{"armor",variant(backend_->property("armor_list"))},{"armorGroups",variant(backend_->property("armor_groups"))},{"game",variant(backend_->property("game"))}};
   std::ifstream mods(fp(profile_)/"mods-v2.txt",std::ios::binary);std::string path,name,description;State::Mod mod;
   while(mods>>mod.enabled>>std::quoted(path)>>std::quoted(name)>>std::quoted(description)){
    size_t count=0;if(!(mods>>count)||count>64)break;mod.choices.clear();
    for(size_t i=0;i<count;++i){int c=0;mods>>c;mod.choices.push_back(c);}if(!mods)break;
    if(std::regex_match(std::filesystem::u8path(path).filename().u8string(),std::regex("^farm_pods(_[0-9]+)?\\.zip$")))continue;
    mod.path=qs(path);mod.name=qs(name);mod.description=qs(description);state_->mods.push_back(mod);if(state_->mods.size()>=32)break;
   }
   QMetaObject::invokeMethod(this,[this,data]{ready_=true;emit readyChanged();emit initialized(data);});
  }catch(const std::exception& e){emit startupError(qs(e.what()));}
 },Qt::QueuedConnection);
}
QVariant Controller::setting(QString n,QVariant fallback){
 fallback=plain(fallback);
 auto value=settings_->value(n,fallback);
 // INI reloads may return strings (notably "false"). Preserve the requested
 // value type so QML never treats a nonempty boolean string as true.
 if(fallback.isValid() && value.metaType()!=fallback.metaType() && !value.convert(fallback.metaType()))return fallback;
 return value;
}
void Controller::saveSetting(QString n,QVariant v){settings_->setValue(n,plain(v));settings_->sync();}
int Controller::request(QString method,QVariantList args){
 args=plain(args).toList();
 int id=++serial_;
 if(qEnvironmentVariableIsSet("SHODAN_HUSKAR_QA")){fprintf(stderr,"[QA] request %d %s\n",id,qPrintable(method));fflush(stderr);}
 QMetaObject::invokeMethod(worker_,[this,id,method,args]{
  try{if(!backend_)throw std::runtime_error("数据尚未载入");auto result=dispatch(method,args);emit completed(id,result,{});}
  catch(const std::exception& e){emit completed(id,{},qs(e.what()));}
 },Qt::QueuedConnection);return id;
}
QVariant Controller::dispatch(const QString& method,const QVariantList& args){
 std::vector<Value> a;for(const auto& item:args)a.push_back(value(item));return variant(invoke(utf(method),a));
}
Value Controller::invoke(const std::string& method,const std::vector<Value>& args){
 using shodan::object;
 auto modList=[&]{Value out;out.kind=Value::Table;out.arrayValue=true;
  for(size_t i=0;i<state_->mods.size();++i){const auto& m=state_->mods[i];Value options;options.kind=Value::Table;options.arrayValue=true;
   try{auto zip=shodan::readModZip(fp(m.path));for(size_t j=0;j<zip.options.size();++j){const auto& o=zip.options[j];Value choices;choices.kind=Value::Table;choices.arrayValue=true;
    if(!o.required)choices.array.push_back(object({{"label","关闭"},{"value",0}}));
    if(o.children.empty())choices.array.push_back(object({{"label","开启"},{"value",1}}));
    else for(size_t c=0;c<o.children.size();++c)choices.array.push_back(object({{"label",o.children[c].name},{"value",int(c+1)}}));
    options.array.push_back(object({{"name",o.name},{"description",o.description},{"choices",choices},{"selected",j<m.choices.size()?m.choices[j]:1}}));
   }}catch(...){}
   out.array.push_back(object({{"index",int(i)},{"path",utf(m.path)},{"name",utf(m.name)},{"description",utf(m.description)},{"enabled",m.enabled},{"options",options}}));
  }return out;};
 auto saveMods=[&]{std::ostringstream out;for(const auto& m:state_->mods){out<<m.enabled<<' '<<std::quoted(utf(m.path))<<' '<<std::quoted(utf(m.name))<<' '<<std::quoted(utf(m.description))<<' '<<m.choices.size();for(int c:m.choices)out<<' '<<c;out<<'\n';}
  QSaveFile f(profile_+"/mods-v2.txt");auto data=out.str();if(!f.open(QIODevice::WriteOnly)||f.write(data.data(),data.size())!=qint64(data.size())||!f.commit())throw std::runtime_error("无法保存 Mod 列表");};
 auto inputs=[&]{Value out;out.kind=Value::Table;out.arrayValue=true;std::vector<shodan::ModFile> patches;size_t total=0;
  for(const auto& mod:state_->mods)if(mod.enabled){auto zip=shodan::readModZip(fp(mod.path));for(auto file:shodan::selectedModFiles(zip,mod.choices)){
   total+=file.data.size();if(total>512*1024*1024)throw std::runtime_error("Mod 数据超过 512 MB");
   if(shodan::isPatchFile(file.name)){file.label=utf(mod.name)+" / "+file.path;patches.push_back(std::move(file));}
   else out.array.push_back(object({{"name",file.name},{"label",utf(mod.name)+" / "+file.name},{"data",std::move(file.data)}}));
  }}state_->patches=shodan::combinePatchFiles(patches);return out;};
 auto sync=[&]{backend_->call("mod_management",{state_->modsUnlocked});if(!state_->modsUnlocked){state_->patches.clear();return;}
  backend_->call("managed_mods",{inputs()});shodan::checkPatchDeployment(std::filesystem::u8path(backend_->property("game").str()).parent_path(),fp(profile_),state_->patches);};
 if(method=="mods_unlock"){state_->modsUnlocked=true;return true;}
 if(method.rfind("mods_",0)==0){
  if(!state_->modsUnlocked)throw std::runtime_error("请先在界面开启隐藏功能");
  if(method=="mods_list")return modList();
  if(method=="mods_import"){
   std::string errors;int imported=0;for(const auto& path:args.at(0).array){try{
    if(state_->mods.size()>=32)throw std::runtime_error("最多管理 32 个 Mod");auto p=fp(qs(path.str()));
    if(QString::fromStdWString(p.extension().wstring()).toLower()!=".zip")throw std::runtime_error("请选择 ZIP 文件");
    auto zip=shodan::readModZip(p);auto dir=fp(profile_)/"Mods";std::filesystem::create_directories(dir);auto dest=dir/p.filename();int suffix=1;
    while(std::filesystem::exists(dest))dest=dir/(p.stem().wstring()+L"_"+std::to_wstring(suffix++)+L".zip");std::filesystem::copy_file(p,dest);
    state_->mods.push_back({QString::fromStdWString(dest.wstring()),qs(zip.title.empty()?p.stem().u8string():zip.title),qs(zip.description.empty()?"未提供说明":zip.description),true,std::vector<int>(zip.options.size(),1)});++imported;
   }catch(const std::exception& e){errors+=path.str()+"："+e.what()+"\n";}}saveMods();return object({{"count",imported},{"errors",errors},{"mods",modList()}});
  }
  if(method=="mods_update"||method=="mods_remove"){
   if(args.at(0).kind!=Value::Number||args[0].number!=std::floor(args[0].number))throw std::runtime_error("Mod 编号无效");
   int i=args.at(0).integer();if(i<0||i>=int(state_->mods.size()))throw std::runtime_error("Mod 不存在");auto previous=state_->mods;
   if(method=="mods_remove")state_->mods.erase(state_->mods.begin()+i);
   else{auto m=state_->mods[i];const auto& o=args.at(1);
    if(o.fields.count("enabled")&&o["enabled"].kind!=Value::Boolean)throw std::runtime_error("enabled 必须为布尔值");
    for(const auto* key:{"name","description"})if(o.fields.count(key)&&o[key].kind!=Value::String)throw std::runtime_error("名称和描述必须是文本");
    if(o.fields.count("enabled"))m.enabled=o["enabled"].yes();if(o.fields.count("name"))m.name=qs(o["name"].str());if(o.fields.count("description"))m.description=qs(o["description"].str());
    if(o.fields.count("choices")){auto zip=shodan::readModZip(fp(m.path));if(o["choices"].array.size()!=zip.options.size())throw std::runtime_error("选项数量不匹配");m.choices.clear();for(const auto& c:o["choices"].array){if(c.kind!=Value::Number||c.number!=std::floor(c.number)||c.number<0||c.number>64)throw std::runtime_error("选项编号无效");m.choices.push_back(c.integer());}shodan::selectedModFiles(zip,m.choices);}state_->mods[i]=std::move(m);}
   try{saveMods();}catch(...){state_->mods=previous;throw;}return modList();
  }
  if(method=="mods_export"){
   auto data=inputs();std::map<std::string,Value> groups;for(const auto& item:data.array){auto& g=groups[item["name"].str()];g.kind=Value::Table;g.array.push_back(item);}
   std::vector<shodan::ModFile> files=state_->patches;for(const auto& g:groups){auto r=backend_->call("merge_named",{g.first,g.second});files.push_back({g.first,"",r["data"].str()});}
   shodan::writeModZip(fp(qs(args.at(0).str())),files);return "开启的 Mod 已合并并导出";
  }
 }
 if(method=="debug_interfaces")return backend_->interfaces();
 if(method=="debug_runtime")return backend_->diagnostics();
 if(method=="debug_property"){
  const auto key=args.at(0).str();bool allowed=false;for(const auto& entry:backend_->interfaces().array)if(entry["name"].str()==key&&entry["type"].str()!="function")allowed=true;
  if(!allowed)throw std::runtime_error("只允许查询公开后端属性");return backend_->property(key.c_str());
 }
 if(method=="debug_logs")return mcp_.logs();
 if(method=="debug_log_files"){Value out;out.kind=Value::Table;out.arrayValue=true;QDir d(profile_+"/Logs");for(const auto& f:d.entryInfoList(QDir::Files|QDir::NoSymLinks))out.array.push_back(object({{"name",utf(f.fileName())},{"bytes",double(f.size())}}));return out;}
 if(method=="debug_read_log"){auto n=qs(args.at(0).str());if(n.contains('/')||n.contains('\\')||n.contains(':')||n==".."||QFileInfo(profile_+"/Logs/"+n).isSymLink())throw std::runtime_error("日志文件名无效");QFile f(profile_+"/Logs/"+n);if(!f.open(QIODevice::ReadOnly))throw std::runtime_error("无法读取日志");if(f.size()>65536)f.seek(f.size()-65536);return utf(QString::fromUtf8(f.readAll()));}
 if(method=="debug_self_test"){auto rows=backend_->call("rows");Value issues;issues.kind=Value::Table;issues.arrayValue=true;for(const auto& row:rows.array)if(row["value"].kind==Value::Number&&!std::isfinite(row["value"].number))issues.array.push_back(row);return object({{"rows_checked",int(rows.array.size())},{"issues",issues},{"backend",backend_->diagnostics()},{"game_writes",0}});}
 if(method=="install_preview"){sync();return backend_->call("install_preview");}
 if(method=="install"||method=="restore"){
  if(qEnvironmentVariableIsSet("SHODAN_HUSKAR_QA"))throw std::runtime_error("界面测试禁止写入游戏");
  if(backend_->call("game_running").yes())throw std::runtime_error("请先关闭游戏，再写入或恢复");
  sync();std::unique_ptr<shodan::PatchTransaction> patches;
  if(state_->modsUnlocked)patches=std::make_unique<shodan::PatchTransaction>(std::filesystem::u8path(backend_->property("game").str()).parent_path(),fp(profile_),method=="install"?state_->patches:std::vector<shodan::ModFile>{});
  auto result=backend_->call(method.c_str());if(patches&&backend_->call("write_succeeded").yes())patches->commit();return result;
 }
 // Always use the UI's session switch, never enable/disable deployment behind it.
 if(method=="mod_management"){backend_->call("mod_management",{state_->modsUnlocked});return state_->modsUnlocked;}
 return backend_->call(method.c_str(),args);
}
void Controller::checkUpdate(){
 if(checking_)return;checking_=true;updateStatus_="正在检查正式发行版…";emit updateChanged();
 auto* watcher=new QFutureWatcher<shodan::ReleaseUpdate>(this);
 connect(watcher,&QFutureWatcherBase::finished,this,[this,watcher]{auto r=watcher->result();watcher->deleteLater();checking_=false;
  updateStatus_=r.error.empty()?(r.newer?"有新版本 "+qs(r.version):"当前已是最新版本"):qs(r.error);emit updateChanged();if(r.newer)emit updateAvailable(qs(r.version),qs(r.url));});
 watcher->setFuture(QtConcurrent::run([]{try{return shodan::checkReleaseUpdate(shodan::version);}catch(const std::exception& e){shodan::ReleaseUpdate r;r.error=e.what();return r;}}));
}
void Controller::toggleMcp(){
 if(mcp_.enabled()){mcp_.stop();emit mcpChanged();return;}if(!ready_)return;
 QMetaObject::invokeMethod(worker_,[this]{
  Value catalog=huskarMcpCatalog(*backend_,state_->methods);
  state_->catalog=catalog;QMetaObject::invokeMethod(this,[this,catalog]{try{mcp_.start(catalog,[]{});emit mcpChanged();}catch(const std::exception& e){emit startupError(qs(e.what()));}});
 },Qt::QueuedConnection);
}
void Controller::pollMcp(){
 if(!ready_||!mcp_.enabled())return;auto r=mcp_.take();if(!r)return;
 QMetaObject::invokeMethod(worker_,[this,r]{try{auto name=r->name;if(name.rfind("shodan_",0)!=0)throw std::runtime_error("未知接口");name.erase(0,7);
  std::vector<Value> args=r->arguments["args"].array;const auto& a=r->arguments;
  const bool extra=name.rfind("debug_",0)==0||name.rfind("mods_",0)==0;
  if(!extra&&!state_->methods.count(name))throw std::runtime_error("未知接口");
  if(name=="debug_property"||name=="debug_read_log")args={a["name"]};
  else if(name=="mods_import")args={a["paths"]};
  else if(name=="mods_update")args={a["index"],a};
  else if(name=="mods_remove")args={a["index"]};
  else if(name=="mods_export")args={a["path"]};
  if((name=="managed_mods"||name=="merge_named"||name=="merge_mods"||name=="mod_management")&&!state_->modsUnlocked)throw std::runtime_error("请先在界面开启隐藏功能");
  auto out=invoke(name,args);r->response.set_value(out);emit externalChange();
 }catch(...){r->response.set_exception(std::current_exception());}},Qt::QueuedConnection);
}
void Controller::copyMcp(){if(!mcp_.enabled())return;QJsonObject config{{"mcpServers",QJsonObject{{"shodan",QJsonObject{{"type","http"},{"url",qs(mcp_.endpoint())},{"headers",QJsonObject{{"Authorization","Bearer "+qs(mcp_.token())}}}}}}}};QApplication::clipboard()->setText(QString::fromUtf8(QJsonDocument(config).toJson()));}
QString Controller::readText(QString path){QFile f(QUrl(path).isLocalFile()?QUrl(path).toLocalFile():path);if(!f.open(QIODevice::ReadOnly)||f.size()>8*1024*1024)return {};return QString::fromUtf8(f.readAll());}
bool Controller::writeText(QString path,QString text){QSaveFile f(QUrl(path).isLocalFile()?QUrl(path).toLocalFile():path);auto data=text.toUtf8();return f.open(QIODevice::WriteOnly)&&f.write(data)==data.size()&&f.commit();}
QString Controller::chooseFile(bool save,QString filter){return save?QFileDialog::getSaveFileName(nullptr,"导出",{},filter):QFileDialog::getOpenFileName(nullptr,"导入",{},filter);}
QStringList Controller::chooseMods(){return QFileDialog::getOpenFileNames(nullptr,"导入 Mod ZIP",{},"ZIP 压缩包 (*.zip)");}
QString Controller::chooseBackground(){
 auto path=QFileDialog::getOpenFileName(nullptr,"选择背景图片",{},"图片 (*.png *.jpg *.jpeg *.bmp *.gif *.svg)");if(path.isEmpty())return {};
 return saveBackground(path);
}
QString Controller::qaBackground(QString path){if(!qEnvironmentVariableIsSet("SHODAN_HUSKAR_QA"))return {};return saveBackground(path);}
QString Controller::saveBackground(QString path){
 if(QUrl(path).isLocalFile())path=QUrl(path).toLocalFile();
 QImageReader reader(path);auto size=reader.size();QFile input(path);
 if(!reader.canRead()||!size.isValid()||size.width()>16000||size.height()>16000||!input.open(QIODevice::ReadOnly)||input.size()>32*1024*1024){emit completed(-1,{},"无法读取这张背景图片，请选择有效的 PNG、JPG、BMP、GIF 或 SVG 图片");return {};}
 auto data=input.readAll();auto directory=profile_+"/Backgrounds";QDir().mkpath(directory);auto dest=directory+"/"+QString::fromLatin1(QCryptographicHash::hash(data,QCryptographicHash::Sha256).toHex().left(16))+"."+QFileInfo(path).suffix().toLower();QSaveFile output(dest);
 if(!output.open(QIODevice::WriteOnly)||output.write(data)!=data.size()||!output.commit()){emit completed(-1,{},"背景图片保存失败");return {};}
 return QUrl::fromLocalFile(dest).toString();
}
QString Controller::storeTheme(QString json){
 auto bytes=json.toUtf8();QJsonParseError error;auto doc=QJsonDocument::fromJson(bytes,&error);
 if(bytes.size()>4*1024*1024||error.error!=QJsonParseError::NoError||!doc.isObject())return {};
 auto dir=profile_+"/Themes";QDir().mkpath(dir);
 auto path=dir+"/"+QString::fromLatin1(QCryptographicHash::hash(bytes,QCryptographicHash::Sha256).toHex().left(16))+".json";
 QSaveFile f(path);if(!f.open(QIODevice::WriteOnly)||f.write(bytes)!=bytes.size()||!f.commit())return {};return path;
}
QStringList Controller::themeComponents()const{
 QStringList result;const auto& meta=HusTheme::staticMetaObject;
 for(int i=0;i<meta.propertyCount();++i){const auto p=meta.property(i);auto name=QString::fromLatin1(p.name());if(p.metaType().id()==QMetaType::QVariantMap&&(name=="Primary"||name.startsWith("Hus")))result<<name;}
 return result;
}
void Controller::openUrl(QString u){QUrl url(u);if(url.scheme()=="https"||url.scheme()=="http")QDesktopServices::openUrl(url);}
bool Controller::capture(QString name){
 auto dir=qEnvironmentVariable("SHODAN_HUSKAR_QA");if(dir.isEmpty()||name.contains('/')||name.contains('\\'))return false;
 QDir().mkpath(dir);for(auto* window:QGuiApplication::allWindows())if(auto* quick=qobject_cast<QQuickWindow*>(window)){bool ok=quick->grabWindow().save(dir+"/"+name+".png");fprintf(stderr,"[QA] capture %s %d\n",qPrintable(name),ok);fflush(stderr);return ok;}return false;
}
void Controller::finishQa(QString error){
 fprintf(stderr,"[QA] finished: %s\n",qPrintable(error));fflush(stderr);
 auto dir=qEnvironmentVariable("SHODAN_HUSKAR_QA");if(dir.isEmpty())return;
 QSaveFile f(dir+"/report.json");if(f.open(QIODevice::WriteOnly)){f.write(QJsonDocument(QJsonObject{{"framework","HuskarUI"},{"error",error},{"game_writes",0}}).toJson());f.commit();}
 QCoreApplication::exit(error.isEmpty()?0:3);
}
bool Controller::qaEdit(QString name,QString text,bool enter){
 if(!qEnvironmentVariableIsSet("SHODAN_HUSKAR_QA"))return false;
 std::function<QQuickItem*(QQuickItem*)> find=[&](QQuickItem* root)->QQuickItem*{if(root->objectName()==name)return root;for(auto* child:root->childItems())if(auto* item=find(child))return item;return nullptr;};
 for(auto* w:QGuiApplication::allWindows())if(auto* window=qobject_cast<QQuickWindow*>(w))if(auto* item=find(window->contentItem())){
  QFocusEvent focus(QEvent::FocusIn,Qt::OtherFocusReason);QCoreApplication::sendEvent(window,&focus);
  item->forceActiveFocus();QMetaObject::invokeMethod(item,"selectAll");QInputMethodEvent event;event.setCommitString(text);QCoreApplication::sendEvent(item,&event);
  if(enter){QKeyEvent down(QEvent::KeyPress,Qt::Key_Return,Qt::NoModifier),up(QEvent::KeyRelease,Qt::Key_Return,Qt::NoModifier);QCoreApplication::sendEvent(window,&down);QCoreApplication::sendEvent(window,&up);}
  else {item->setFocus(false,Qt::OtherFocusReason);window->contentItem()->forceActiveFocus();}
  return true;
 }return false;
}
bool Controller::qaDrag(QString name){
 if(!qEnvironmentVariableIsSet("SHODAN_HUSKAR_QA"))return false;
 std::function<QQuickItem*(QQuickItem*)> find=[&](QQuickItem* root)->QQuickItem*{if(root->objectName()==name)return root;for(auto* child:root->childItems())if(auto* item=find(child))return item;return nullptr;};
 for(auto* w:QGuiApplication::allWindows())if(auto* window=qobject_cast<QQuickWindow*>(w))if(auto* item=find(window->contentItem())){
  for(auto* ancestor=item->parentItem();ancestor;ancestor=ancestor->parentItem())if(ancestor->property("contentY").isValid()){
   const auto delta=item->mapToItem(ancestor,QPointF(0,item->height()/2)).y()-ancestor->height()/2;
   const auto maximum=qMax(0.0,ancestor->property("contentHeight").toDouble()-ancestor->height());
   ancestor->setProperty("contentY",qBound(0.0,ancestor->property("contentY").toDouble()+delta,maximum));
  }
  item->forceActiveFocus();window->requestActivate();QCoreApplication::processEvents();
  const auto point=item->mapToScene(QPointF(item->width()/2,item->height()/2));
  fprintf(stderr,"[QA] slider geometry %.0fx%.0f at %.0f,%.0f window %dx%d\n",item->width(),item->height(),point.x(),point.y(),window->width(),window->height());fflush(stderr);
  ulong timestamp=1000;
  auto send=[&](QEvent::Type type,qreal ratio,Qt::MouseButton button,Qt::MouseButtons buttons){
   auto local=item->mapToScene(QPointF(item->width()*ratio,item->height()/2));
   QMouseEvent event(type,local,local,window->mapToGlobal(local.toPoint()),button,buttons,Qt::NoModifier);
   event.setTimestamp(timestamp);timestamp+=25;
   QCoreApplication::sendEvent(window,&event);
   QEventLoop frame;QTimer::singleShot(25,&frame,&QEventLoop::quit);frame.exec();
  };
  send(QEvent::MouseButtonPress,0.2,Qt::LeftButton,Qt::LeftButton);
  for(auto ratio:{0.35,0.5,0.65,0.8})send(QEvent::MouseMove,ratio,Qt::NoButton,Qt::LeftButton);
  send(QEvent::MouseButtonRelease,0.8,Qt::LeftButton,Qt::NoButton);
  fprintf(stderr,"[QA] slider %s current=%s\n",qPrintable(name),qPrintable(item->property("currentValue").toString()));fflush(stderr);
  return true;
 }return false;
}
bool Controller::qaWheel(QString name){
 if(!qEnvironmentVariableIsSet("SHODAN_HUSKAR_QA"))return false;
 std::function<QQuickItem*(QQuickItem*)> find=[&](QQuickItem* root)->QQuickItem*{if(root->objectName()==name)return root;for(auto* child:root->childItems())if(auto* item=find(child))return item;return nullptr;};
 for(auto* w:QGuiApplication::allWindows())if(auto* window=qobject_cast<QQuickWindow*>(w))if(auto* item=find(window->contentItem())){
  auto local=item->mapToScene(QPointF(item->width()/2,item->height()/2));
  QWheelEvent event(local,window->mapToGlobal(local.toPoint()),QPoint(),QPoint(0,-120),Qt::NoButton,Qt::NoModifier,Qt::NoScrollPhase,false);
  QCoreApplication::sendEvent(window,&event);return true;
 }return false;
}
