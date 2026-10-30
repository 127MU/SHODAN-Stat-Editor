#include "war_proxy.h"
#include <QFileDialog>
#include <QSaveFile>
#include <QJsonDocument>
#include <QJsonArray>
#include <QDir>
#include <QRegularExpression>
#include <QCoreApplication>
#include <QDesktopServices>
#include <QUrl>
#include <QProcessEnvironment>
#include <QCryptographicHash>
#include <QDateTime>
#include <algorithm>
#include <cmath>
#include <QSet>
#include <QMap>
#include <QTcpServer>
#include <QHostAddress>
#include <QApplication>
#include <QClipboard>
#include <stdexcept>
#ifdef Q_OS_WIN
#include <windows.h>
#include <wincrypt.h>
#include <tlhelp32.h>
#endif

namespace {
void require(bool condition,QString message){if(!condition)throw std::runtime_error(message.toUtf8().constData());}
QByteArray read(QString path){QFile f(path);require(f.open(QIODevice::ReadOnly),"无法读取："+path);require(f.size()<=8*1024*1024,"配置文件过大："+path);return f.readAll();}
QJsonObject object(QByteArray data){QJsonParseError e;auto d=QJsonDocument::fromJson(data,&e);require(e.error==QJsonParseError::NoError && d.isObject(),"配置必须是有效的 JSON 对象");return d.object();}
void write(QString path,QByteArray data){QSaveFile f(path);require(f.open(QIODevice::WriteOnly),"无法写入："+path);require(f.write(data)==data.size() && f.commit(),"保存失败："+path);}
QByteArray json(QJsonObject o){return QJsonDocument(o).toJson();}
}

QJsonObject WarProxy::plan(int planet,const QString& faction,const QString& effects){
 require(planet>=0 && planet<=10000,"星球索引必须在 0—10000 之间；请使用游戏索引，不是数据表行号");
 require(QStringList{"terminid","automaton","illuminate"}.contains(faction),"请选择敌人阵营");
 QJsonArray ids;
 for(const auto& token:effects.split(QRegularExpression("[,，;；\\s]+"),Qt::SkipEmptyParts)){
  bool ok=false;auto id=token.toInt(&ok);require(ok && id>0,"效果 ID 必须是正整数");
  if(!ids.contains(id))ids.append(id);
 }
 require(!ids.isEmpty() && ids.size()<=32,"请选择 1—32 个效果 ID");
 QString name="shodan_planet_"+QString::number(planet);
 return {{"targets",QJsonArray{QJsonObject{{"planet",planet},{"variant",name}}}},
         {"variants",QJsonObject{{name,ids}}},
         {"meta",QJsonObject{{name,QJsonObject{{"faction",faction},{"mechanic",ids.first()}}}}}};
}

WarProxy::WarProxy(QString profile,QObject* parent):QObject(parent),settings_(profile+"/war-proxy.ini",QSettings::IniFormat),profile_(profile){
 lock_=std::make_unique<QLockFile>(profile+"/war-proxy.lock");lock_->setStaleLockTime(0);
 try{metadata_=object(read(":/shodan/war_catalog.json"));}catch(...){}
 try{if(QFileInfo::exists(profile_+"/war-targets.json"))targets_=validateTargets(object(read(profile_+"/war-targets.json"))["targets"].toArray());}catch(const std::exception& e){status_="方案文件读取失败，已保留原文件："+QString::fromUtf8(e.what());}
 refreshCatalog();
 certificateTrusted_=verifyCertificateTrust();
#ifdef Q_OS_WIN
 job_=CreateJobObjectW(nullptr,nullptr);if(job_){JOBOBJECT_EXTENDED_LIMIT_INFORMATION info{};info.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;if(!SetInformationJobObject(job_,JobObjectExtendedLimitInformation,&info,sizeof(info))){CloseHandle(job_);job_=nullptr;}}
 process_.setCreateProcessArgumentsModifier([](QProcess::CreateProcessArguments* a){a->flags|=CREATE_NO_WINDOW;});
 certificateProcess_.setCreateProcessArgumentsModifier([](QProcess::CreateProcessArguments* a){a->flags|=CREATE_NO_WINDOW;});
#endif
 // Do not retain proxy stdout: third-party logs may contain account identifiers.
 process_.setStandardOutputFile(QProcess::nullDevice());
 process_.setStandardErrorFile(QProcess::nullDevice());
 certificateProcess_.setStandardOutputFile(QProcess::nullDevice());certificateProcess_.setStandardErrorFile(QProcess::nullDevice());
 connect(&certificateProcess_,&QProcess::errorOccurred,this,[this](QProcess::ProcessError){certificateStatus_="无法运行 Windows 证书工具，未确认信任状态。";emit changed();});
 connect(&certificateProcess_,qOverload<int,QProcess::ExitStatus>(&QProcess::finished),this,[this](int code,QProcess::ExitStatus exit){
  certificateTrusted_=verifyCertificateTrust();
  if(code!=0 || exit!=QProcess::NormalExit){certificateStatus_="证书操作失败，请检查当前用户权限；未操作系统级证书库。";emit changed();return;}
  if(removingCertificate_){settings_.remove("installedCa");certificateStatus_="本程序记录的本机 CA 已从当前用户信任库移除。";}
  else{settings_.setValue("installedCa",certificateThumbprint_);certificateStatus_="本机 CA 已安装到当前用户信任库，请重启游戏。指纹："+certificateThumbprint_;}
  settings_.sync();emit changed();
 });
 connect(&process_,&QProcess::started,this,[this]{if(mitmSession_){
#ifdef Q_OS_WIN
  HANDLE child=OpenProcess(PROCESS_SET_QUOTA|PROCESS_TERMINATE,FALSE,DWORD(process_.processId()));bool assigned=child && job_ && AssignProcessToJobObject(job_,child);if(child)CloseHandle(child);if(!assigned){terminalError_="无法建立代理进程退出保护，已停止启动。";process_.kill();return;}
#endif
  active_=!preparing_;status_=preparing_?"正在初始化本机 CA，不捕获游戏流量…":"mitmdump 进程已启动，等待插件加载；尚未确认战况改写。";statusTimer_->start();emit changed();}});
 statusTimer_=new QTimer(this);statusTimer_->setInterval(1000);
 connect(statusTimer_,&QTimer::timeout,this,&WarProxy::pollHealth);
 connect(&process_,&QProcess::errorOccurred,this,[this](QProcess::ProcessError e){if(mitmSession_){statusTimer_->stop();active_=false;if(e==QProcess::FailedToStart){preparing_=false;mitmSession_=false;lock_->unlock();}fail("mitmdump 无法启动，请检查内置文件、Windows 兼容性和捕获权限。");}});
 connect(&process_,qOverload<int,QProcess::ExitStatus>(&QProcess::finished),this,[this](int code,QProcess::ExitStatus exit){
  if(mitmSession_){QFile::remove(profile_+"/war-proxy/steam-proxy.ini");statusTimer_->stop();active_=false;pluginReady_=false;catalogFresh_=false;mitmSession_=false;lock_->unlock();
   if(preparing_){preparing_=false;if(code==0 && exit==QProcess::NormalExit && terminalError_.isEmpty() && !stopping_){if(installAfterPreparation_)installCertificate();else{status_="核心自检通过，已生成隔离 CA，未安装证书信任。";emit changed();}return;}certificateStatus_="CA 初始化失败，请检查代理核心和临时目录权限。";}
   status_=!terminalError_.isEmpty()?terminalError_:stopping_?"mitmdump 已停止。请重启游戏恢复在线战况。":"mitmdump 已退出（代码 "+QString::number(code)+"）。请检查安装、证书信任和进程捕获权限。";emit changed();return;}

 });
}
void WarProxy::pollHealth(){
 if(!mitmSession_ || stopping_)return;
 const auto now=QDateTime::currentMSecsSinceEpoch();
 try{
  const auto s=object(read(profile_+"/war-proxy/health.json"));
  const double updated=s["updated"].toDouble(-1);
  require(s["ready"].isBool() && std::isfinite(updated) && updated>=sessionStart_ && updated<=now/1000.0+5 && now/1000.0-updated<=15,"代理状态已过期或不属于本次会话");
  lastHealthReadMs_=now;pluginReady_=s["ready"].toBool(false);
  const int routerPort=s["router_port"].toInt();
  if(routerPort>0 && routerPort<=65535)proxyAddress_="http://127.0.0.1:"+QString::number(routerPort);
  QString bridgeError;
  if(pluginReady_){try{publishSteamSession();}catch(const std::exception& e){pluginReady_=false;QFile::remove(profile_+"/war-proxy/steam-proxy.ini");bridgeError=" · 游戏启动桥接失败："+QString::fromUtf8(e.what());}}
  else QFile::remove(profile_+"/war-proxy/steam-proxy.ini");
  const auto f=s["failures"].toObject();
  const auto connection=s["connection"].toObject();
  status_=s["message"].toString()+" · 战况 "+QString::number(s["statuses"].toInt())+" · 改写 "+QString::number(s["rewrites"].toInt())+" · 客户端 TLS 失败 "+QString::number(f["client_tls"].toInt())+" · 上游连接失败 "+QString::number(f["connect"].toInt()+f["server_tls"].toInt()+f["http"].toInt());
  if(!connection.isEmpty())status_+=" · API 请求/响应 "+QString::number(connection["requests"].toInt())+"/"+QString::number(connection["responses"].toInt())+(connection["failure_kind"].toString().isEmpty()?QString():" · "+connection["failure_kind"].toString());
  try{
   const auto digest=QString::fromLatin1(QCryptographicHash::hash(read(profile_+"/war-proxy/plan.json"),QCryptographicHash::Sha256).toHex());
   status_+=s["applied_plan_digest"].toString()==digest?" · 本次方案已写入响应（不等同于局内已验证）":" · 本次方案等待战况刷新";
  }catch(...){status_+=" · 方案文件暂不可读，正在重试";}
  status_+=bridgeError;refreshCatalog();emit changed();
 }catch(...){
  if(!lastHealthReadMs_){
   pluginReady_=false;QFile::remove(profile_+"/war-proxy/steam-proxy.ini");
   status_=preparing_?"正在初始化本机 CA，等待代理状态…":"正在等待代理状态文件，初始化完成后自动连接；最长等待 45 秒。";
  }else if(now-lastHealthReadMs_<=15000){
   status_="代理状态暂不可读或正在更新，正在自动重试；尚未确认代理退出。";
  }else{
   pluginReady_=false;catalogFresh_=false;QFile::remove(profile_+"/war-proxy/steam-proxy.ini");
   status_="超过 15 秒未获取有效代理状态，已暂停新的游戏桥接启动。请检查代理是否退出，或停止后重新开启。";
  }
  emit changed();
 }
}
WarProxy::~WarProxy(){if(mitmSession_ && process_.state()!=QProcess::NotRunning){try{write(profile_+"/war-proxy/stop.request","stop");}catch(...){}if(!process_.waitForFinished(2500)){process_.kill();process_.waitForFinished(1000);}}
#ifdef Q_OS_WIN
 if(job_)CloseHandle(job_);
#endif
 if(certificateProcess_.state()!=QProcess::NotRunning)certificateProcess_.waitForFinished(2000);
}
QString WarProxy::check(){
 certificateTrusted_=verifyCertificateTrust();
 try{
   require(QFileInfo(executable()).isFile(),"请先选择官方 Windows 版 mitmdump.exe");
   auto file=QFileInfo(executable());require(file.fileName().compare("mitmdump.exe",Qt::CaseInsensitive)==0 || (file.fileName().compare("python.exe",Qt::CaseInsensitive)==0 && QFileInfo::exists(file.dir().filePath("proxy_main.py"))),"代理核心不完整，请选择 mitmdump.exe 或配套的内置运行时");
   status_="mitmdump 文件检查通过；首次使用需信任本机生成的 CA，游戏进程捕获仍需实测。";emit changed();return status_;
 }catch(const std::exception& e){status_=QString::fromUtf8(e.what());}
 emit changed();return status_;
}
bool WarProxy::start(int planet,QString faction,QString effects){return startMitm(planet,faction,effects);}
void WarProxy::setUseSystemProxy(bool enabled){
 if(active_ || busy()){fail("请先停止变种代理，再切换 API 连接路线");return;}
 settings_.setValue("useSystemProxy",enabled);settings_.sync();
 fail(enabled?"游戏 API 将经当前系统 HTTP 代理转发；请留意与加速器的路由叠加。":"游戏 API 将按系统网络路由直连，不额外叠加系统 HTTP 代理。TUN 和加速器是否接管仍由它们自身决定。");
}
void WarProxy::stop(){
 if(!mitmSession_)return;
 QFile::remove(profile_+"/war-proxy/steam-proxy.ini");
 stopping_=true;status_="正在停止变种代理…";
 try{write(profile_+"/war-proxy/stop.request","stop");}catch(...){process_.terminate();}
 QTimer::singleShot(3000,this,[this]{if(stopping_ && mitmSession_ && process_.state()!=QProcess::NotRunning)process_.kill();});emit changed();
}
QString WarProxy::executable()const{
 auto selected=settings_.value("mitmdump").toString();
 if(QFileInfo(selected).isFile())return selected;
 auto python=QCoreApplication::applicationDirPath()+"/mitmproxy/python.exe";
 if(QFileInfo::exists(python))return python;
 auto bundled=QCoreApplication::applicationDirPath()+"/mitmproxy/mitmdump.exe";
 return bundled;
}
void WarProxy::chooseExecutable(){
 if(busy()||active_)return;
 auto path=QFileDialog::getOpenFileName(nullptr,"选择配套代理核心",executable(),"代理核心 (mitmdump.exe python.exe)");
 if(!path.isEmpty()){settings_.setValue("mitmdump",path);settings_.sync();check();}
}
void WarProxy::openCertificate(){
 auto path=profile_+"/war-proxy/ca/mitmproxy-ca-cert.cer";
 if(!QFileInfo::exists(path)){fail("请先启动一次 mitmdump 生成本机 CA，再打开证书。证书私钥不会随程序分发。");return;}
 QDesktopServices::openUrl(QUrl::fromLocalFile(path));
}
void WarProxy::installCertificate(){
 if(certificateProcess_.state()!=QProcess::NotRunning)return;
 try{
  auto path=profile_+"/war-proxy/ca/mitmproxy-ca-cert.cer";auto pem=read(path);
  require(pem.contains("-----BEGIN CERTIFICATE-----") && pem.contains("-----END CERTIFICATE-----"),"本机 CA 尚未生成，请先启动一次变种代理");
  auto base64=pem.mid(pem.indexOf("-----BEGIN CERTIFICATE-----")+27);base64=base64.left(base64.indexOf("-----END CERTIFICATE-----"));
  auto der=QByteArray::fromBase64(base64);require(!der.isEmpty(),"CA 证书格式无效");
  certificateThumbprint_=QString::fromLatin1(QCryptographicHash::hash(der,QCryptographicHash::Sha1).toHex());removingCertificate_=false;
  auto previous=settings_.value("installedCa").toString();
  require(previous.isEmpty() || previous==certificateThumbprint_,"检测到另一张已记录的本机 CA，请先卸载旧证书，再安装新证书");
  // Record before invoking certutil: closing the editor after the store changes
  // but before the completion callback must not lose the uninstall fingerprint.
  settings_.setValue("installedCa",certificateThumbprint_);settings_.sync();
  // Current user only; no elevation or shared/private CA distribution.
  certificateProcess_.start(qEnvironmentVariable("SystemRoot","C:/Windows")+"/System32/certutil.exe",{"-user","-f","-addstore","Root",path});
  certificateStatus_="正在向当前用户信任库安装本机 CA…";emit changed();
 }catch(const std::exception& e){certificateStatus_=QString::fromUtf8(e.what());emit changed();}
}
void WarProxy::uninstallCertificate(){
 if(certificateProcess_.state()!=QProcess::NotRunning)return;
 auto thumb=settings_.value("installedCa").toString();
 if(!QRegularExpression("^[0-9a-f]{40}$").match(thumb).hasMatch()){certificateStatus_="没有本程序记录的已安装证书，不会删除其他证书。";emit changed();return;}
 removingCertificate_=true;
 certificateProcess_.start(qEnvironmentVariable("SystemRoot","C:/Windows")+"/System32/certutil.exe",{"-user","-delstore","Root",thumb});
 certificateStatus_="正在移除本程序记录的本机 CA…";emit changed();
}
bool WarProxy::startMitm(int planet,QString faction,QString effects){
 try{return launchPlan(plan(planet,faction,effects));}catch(const std::exception& e){fail(QString::fromUtf8(e.what()));return false;}
}
bool WarProxy::launchPlan(QJsonObject p,bool prepareOnly){
 if(process_.state()!=QProcess::NotRunning){fail("请先停止当前代理");return false;}
 try{
  check();require(status_.startsWith("mitmdump 文件检查通过"),status_);
  require(lock_->tryLock(0),"另一个编辑器正在使用本机代理，请先关闭它");
  QString root=profile_+"/war-proxy";
  require(QDir().mkpath(root+"/ca") && QDir().mkpath(root+"/tmp"),"无法创建代理工作目录");
  if(!prepareOnly && QFileInfo::exists(root+"/steam-bridge.exe"))updateSteamBridge();
  write(root+"/addon.py",read(":/shodan/war_status_addon.py"));
  p["health_path"]=root+"/health.json";write(root+"/plan.json",json(p));
  QFile::remove(root+"/health.json");
  QFile::remove(root+"/stop.request");sessionStart_=QDateTime::currentMSecsSinceEpoch()/1000.0;lastHealthReadMs_=0;pluginReady_=false;catalogFresh_=false;preparing_=prepareOnly;terminalError_.clear();const int ticket=++generation_;
  auto env=QProcessEnvironment::systemEnvironment();env.insert("SHODAN_WAR_PLAN",root+"/plan.json");env.insert("SHODAN_PREPARE_CA",prepareOnly?"1":"0");env.insert("TEMP",root+"/tmp");env.insert("TMP",root+"/tmp");process_.setProcessEnvironment(env);
  QString mode="regular@127.0.0.1:0";proxyAddress_.clear();
  if(!prepareOnly && captureMode()=="proxy"){
   QTcpServer reserve;require(reserve.listen(QHostAddress::LocalHost,0),"无法分配本机代理端口");int port=reserve.serverPort();reserve.close();proxyAddress_="http://127.0.0.1:"+QString::number(port);mode="regular@127.0.0.1:"+QString::number(port);
   QSettings internet("HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings",QSettings::NativeFormat);
   auto upstream=internet.value("ProxyServer").toString().trimmed();
   if(upstream.contains(';')||upstream.contains('=')){QString selected;for(const auto& part:upstream.split(';')){auto pair=part.split('=');if(pair.size()==2 && pair[0].trimmed()=="http")selected=pair[1].trimmed();}upstream=selected;}
   if(useSystemProxy() && internet.value("ProxyEnable").toInt()==1 && !upstream.isEmpty()){
    QUrl proxy(upstream.contains("://")?upstream:"http://"+upstream);require(proxy.isValid() && !proxy.host().isEmpty() && proxy.userInfo().isEmpty() && (proxy.scheme()=="http" || proxy.scheme()=="https"),"当前系统 HTTP 代理格式不受支持，未自动改变它");
    mode="upstream:"+proxy.toString(QUrl::RemovePath|QUrl::RemoveQuery|QUrl::RemoveFragment)+"@127.0.0.1:"+QString::number(port);
   }
  }
  if(!prepareOnly){env.insert("SHODAN_WAR_MITM_PORT",QString::number(QUrl(proxyAddress_).port()));process_.setProcessEnvironment(env);}
  process_.setWorkingDirectory(root);mitmSession_=true;stopping_=false;
  QStringList arguments{"--mode",mode,"--allow-hosts","^api\\.live\\.prod\\.thehelldiversgame\\.com(:443)?$","--set","confdir="+root+"/ca","--set","flow_detail=0","--set","connection_strategy=lazy","--set","upstream_cert=false","--set","http2=false","--quiet","-s",root+"/addon.py"};
  if(QFileInfo(executable()).fileName().compare("python.exe",Qt::CaseInsensitive)==0){arguments.prepend(QFileInfo(executable()).dir().absoluteFilePath("proxy_main.py"));arguments.prepend("-I");}
  process_.start(executable(),arguments);
  QTimer::singleShot(45000,this,[this,ticket]{if(ticket==generation_ && mitmSession_ && !pluginReady_){terminalError_="代理插件未在 45 秒内就绪，已停止。请检查核心解包、临时目录和捕获权限。";stop();}});
  status_=proxyAddress_.isEmpty()?"正在初始化进程捕获，尚未就绪。":"正在启动 HTTP 代理兼容模式；不会修改系统代理或 hosts。";emit changed();return true;
 }catch(const std::exception& e){if(process_.state()==QProcess::NotRunning)lock_->unlock();fail(QString::fromUtf8(e.what()));return false;}
}
bool WarProxy::exportPlan(int planet,QString faction,QString effects){
 try{
  auto p=plan(planet,faction,effects);auto dir=QFileDialog::getExistingDirectory(nullptr,"选择方案导出目录");if(dir.isEmpty())return false;
  // One document avoids overwriting a proxy's real config/catalog files.
  auto path=QDir(dir).filePath("shodan-war-plan.json");require(!QFileInfo::exists(path),"导出目录已有 shodan-war-plan.json，请选择其他目录");
  write(path,json(p));fail("方案已导出："+path+"。此文件是配置片段，不是游戏补丁。");return true;
 }catch(const std::exception& e){fail(QString::fromUtf8(e.what()));return false;}
}
QJsonArray WarProxy::validateTargets(QJsonArray input){
 require(input.size()<=64,"最多配置 64 颗星球");QJsonArray output;QSet<int> seen;
 for(const auto& value:input){
  require(value.isObject(),"星球方案必须是对象");auto t=value.toObject();
  auto integer=[](QJsonValue v,int low,int high){auto n=v.toDouble(-1);return v.isDouble() && std::isfinite(n) && n==std::floor(n) && n>=low && n<=high;};
  require(integer(t["planet"],0,10000),"星球索引无效");int id=t["planet"].toInt();require(!seen.contains(id),"同一颗星球只能保留一份方案");seen.insert(id);
  require(t["effects"].isArray(),"方案缺少效果列表");auto effects=t["effects"].toArray();require(effects.size()<=32,"每颗星球最多选择 32 个效果");QJsonArray ids;
  for(const auto& e:effects){require(integer(e,1,2147483647),"效果 ID 无效");if(!ids.contains(e))ids.append(e);}
  auto owner=t.value("owner").isUndefined()?QJsonValue(0):t["owner"],type=t.value("campaign_type").isUndefined()?QJsonValue(0):t["campaign_type"];
  require(integer(owner,0,4) && integer(type,0,4),"阵营或战役类型无效");
  auto race=t.value("campaign_race").isUndefined()?QJsonValue(0):t["campaign_race"];
  require(integer(race,0,4),"作战敌人阵营无效");
  require(!t.contains("initialize_regions") || t["initialize_regions"].isBool(),"分区初始化开关必须为布尔值");
  require(!t.value("initialize_regions").toBool() || (t.value("campaign").toBool() && race.toInt()>=2),"初始化分区需要开启战役并明确选择作战敌人");
  require(!t.contains("open_regions") || t["open_regions"].isBool(),"分区开放开关必须为布尔值");
  require((!t.contains("enabled")||t["enabled"].isBool()) && (!t.contains("campaign")||t["campaign"].isBool()),"方案开关类型无效");
  QJsonObject defense;
  for(auto key:{"defense_source","defense_level","defense_hours","defense_count"}){
   int fallback=QString(key)=="defense_source"?-1:QString(key)=="defense_level"?20:QString(key)=="defense_hours"?48:38;
   auto v=t.contains(key)?t[key]:QJsonValue(fallback);
   int low=QString(key)=="defense_source"?-1:1,high=QString(key)=="defense_source"?10000:QString(key)=="defense_hours"?168:1000;
   require(integer(v,low,high),"防守战役参数无效");defense.insert(key,v);
  }
  if(type.toInt()==4){
   require(t.value("campaign").toBool() && owner.toInt()==1 && race.toInt()>=2,"防守战役需要开启战役、超级地球归属和明确的敌人阵营");
   require(defense["defense_source"].toInt()>=0 && defense["defense_source"].toInt()!=id,"请选择另一颗敌方星球作为进攻来源");
  }
  QJsonObject normalized{{"planet",id},{"enabled",t.value("enabled").toBool(true)},{"effects",ids},{"owner",owner},{"campaign",t.value("campaign").toBool(false)},{"campaign_type",type},{"campaign_race",race},{"open_regions",t.value("open_regions").toBool(false)},{"initialize_regions",t.value("initialize_regions").toBool(false)}};
  for(auto it=defense.begin();it!=defense.end();++it)normalized.insert(it.key(),it.value());
  output.append(normalized);
 }
 return output;
}
void WarProxy::persistTargets(QJsonArray targets){
 auto validated=validateTargets(targets);QString path=profile_+"/war-targets.json";
 if(QFileInfo::exists(path))write(profile_+"/war-targets.backup.json",read(path));
 write(path,json({{"schema",2},{"targets",validated}}));targets_=validated;
 emit targetsChanged();
 if(active_){try{write(profile_+"/war-proxy/plan.json",json({{"schema",2},{"targets",validated},{"health_path",profile_+"/war-proxy/health.json"}}));}catch(const std::exception& e){fail("方案已保存，但运行中的代理配置更新失败："+QString::fromUtf8(e.what()));return;}}
 status_=active_?"方案已保存，等待游戏刷新战况。当前地图、已生成作战和局内任务不会立即热改。":"方案已保存，开启变种后生效。";emit changed();
}
bool WarProxy::saveTarget(QString text){
 try{auto t=object(text.toUtf8());auto next=targets_;int found=-1;for(int i=0;i<next.size();++i)if(next[i].toObject()["planet"]==t["planet"])found=i;if(found>=0)next.replace(found,t);else next.append(t);persistTargets(next);return true;}
 catch(const std::exception& e){fail(QString::fromUtf8(e.what()));return false;}
}
void WarProxy::removeTarget(int planet){try{auto next=targets_;for(int i=next.size()-1;i>=0;--i)if(next[i].toObject()["planet"].toInt()==planet)next.removeAt(i);persistTargets(next);}catch(const std::exception& e){fail(QString::fromUtf8(e.what()));}}
bool WarProxy::startConfigured(bool observeOnly){try{return launchPlan({{"schema",2},{"targets",observeOnly?QJsonArray{}:validateTargets(targets_)}});}catch(const std::exception& e){fail(QString::fromUtf8(e.what()));return false;}}
void WarProxy::prepareCertificate(bool installAfter){
 if(certificateProcess_.state()!=QProcess::NotRunning || preparing_)return;
 installAfterPreparation_=installAfter;
 if(QFileInfo::exists(profile_+"/war-proxy/ca/mitmproxy-ca-cert.cer")){if(installAfter)installCertificate();else fail("隔离 CA 已存在，未安装证书信任。");return;}
 if(active_){certificateStatus_="代理仍在初始化，请稍后再安装证书。";emit changed();return;}
 launchPlan({{"schema",2},{"targets",QJsonArray{}}},true);
}
void WarProxy::importTargets(){
 auto path=QFileDialog::getOpenFileName(nullptr,"导入变种方案",{},"JSON (*.json)");if(path.isEmpty())return;
 try{auto p=object(read(path));require(!p.contains("schema") || p["schema"].toInt(-1)==2,"不支持的方案版本");require(p["targets"].isArray(),"文件缺少星球方案列表");auto targets=p["targets"].toArray();
  for(int i=0;i<targets.size();++i){auto t=targets[i].toObject();if(!t.contains("effects")){t["effects"]=p["variants"].toObject()[t["variant"].toString()].toArray();targets.replace(i,t);}}
  persistTargets(targets);
 }catch(const std::exception& e){fail(QString::fromUtf8(e.what()));}
}
void WarProxy::exportTargets(){
 auto path=QFileDialog::getSaveFileName(nullptr,"导出变种方案","变种方案.json","JSON (*.json)");if(path.isEmpty())return;
 try{write(path,json({{"schema",2},{"targets",validateTargets(targets_)}}));fail("变种方案已导出。");}catch(const std::exception& e){fail(QString::fromUtf8(e.what()));}
}
void WarProxy::restoreBackup(){try{auto p=object(read(profile_+"/war-targets.backup.json"));require(p["targets"].isArray(),"备份文件缺少方案列表");persistTargets(p["targets"].toArray());}catch(const std::exception& e){fail(QString::fromUtf8(e.what()));}}
void WarProxy::refreshCatalog(){
 const auto previousEffects=effects_,previousPlanets=planets_;
 QJsonArray liveEffects,livePlanets;QByteArray c,p;
 try{c=read(profile_+"/war-proxy/catalog.json");auto doc=object(c);liveEffects=doc["effects"].toArray();catalogFresh_=active_ && doc["updated"].toDouble()>=sessionStart_;}catch(...){}
 try{p=read(profile_+"/war-proxy/planets.json");livePlanets=object(p)["planets"].toArray();}catch(...){}
 if(!effects_.isEmpty() && c==catalogStamp_ && p==planetStamp_)return;
 catalogStamp_=c;planetStamp_=p;
 QMap<int,QJsonObject> effects,planets;
 for(const auto& row:metadata_["effects"].toArray()){auto e=row.toObject();e["cached"]=true;effects[e["id"].toInt()]=e;}
 auto strings=metadata_["strings"].toObject();
 auto references=metadata_["effect_reference"].toObject();
 for(const auto& row:liveEffects){auto e=row.toObject();if(!e["id"].isDouble()||e["id"].toInt()<=0)continue;int id=e["id"].toInt();auto previous=effects.value(id);int type=e["effectType"].toInt();
  auto reference=references[QString::number(id)].toObject();
  const bool referenceMatches=reference["effectType"].toInt(-1)==type && reference["nameHash"].toDouble(-1)==e["nameHash"].toDouble(-2);
  const bool sameType=previous["effectType"].toInt(-1)==type && (!reference.contains("nameHash") || referenceMatches);
  auto hash=QString::number(quint32(qint64(e["nameHash"].toDouble())));auto name=strings.value(hash).toString();if(name.isEmpty() && sameType)name=previous["name"].toString();if(name.isEmpty())name="未确认名称的效果";
  e["name"]=name;e["native"]=sameType?previous["native"]:QJsonValue();e["experimental"]=!sameType || previous.value("experimental").toBool(true);e["cached"]=false;e["translation_source"]=strings.value(hash).toString().isEmpty()?(sameType?previous.value("translation_source").toString("中文名待核对"):"中文名待核对"):"游戏文本";
  if(referenceMatches){
   e["name"]=reference["name"];e["translation_source"]=reference["translation_source"];e["reference_note"]=reference["note"];e["aliases"]=reference["aliases"];
  }
  auto descHash=QString::number(quint32(qint64(e["descriptionGamePlayShortHash"].toDouble())));e["description"]=strings.value(descHash).toString();effects[id]=e;
 }
 effects_=QJsonArray{};
 // Once a live catalog exists, don't advertise stale IDs as currently available.
 QSet<int> currentIds;for(const auto& e:liveEffects)currentIds.insert(e.toObject()["id"].toInt());
 for(auto it=effects.begin();it!=effects.end();++it){if(!liveEffects.isEmpty()&&!currentIds.contains(it.key()))continue;auto e=it.value();int type=e["effectType"].toInt();e["category"]=type==71?"变种与敌情":type==40?"星图词条":type==32?"临时战备":type==36?"临时装备":"游戏效果（类型 "+QString::number(type)+"）";effects_.append(e);}
 for(const auto& row:metadata_["planets"].toArray()){auto q=row.toObject();planets[q["id"].toInt()]=q;}
 for(const auto& row:livePlanets){auto q=row.toObject();if(!q["index"].isDouble())continue;int id=q["index"].toInt();auto e=planets.value(id);e["id"]=id;if(e["name"].toString().isEmpty())e["name"]="星球 #"+QString::number(id);e["owner"]=q["owner"];e["players"]=q["players"];planets[id]=e;}
 planets_=QJsonArray{};for(const auto& e:planets)planets_.append(e);
 if(effects_!=previousEffects)emit effectsChanged();
 if(planets_!=previousPlanets)emit planetsChanged();
 if(effects_!=previousEffects || planets_!=previousPlanets)emit modelsChanged();
}
bool WarProxy::verifyCertificateTrust()const{
#ifdef Q_OS_WIN
 try{auto pem=read(profile_+"/war-proxy/ca/mitmproxy-ca-cert.cer");auto start=pem.indexOf("-----BEGIN CERTIFICATE-----");if(start<0)return false;auto encoded=pem.mid(start+27);auto end=encoded.indexOf("-----END CERTIFICATE-----");if(end<0)return false;auto digest=QCryptographicHash::hash(QByteArray::fromBase64(encoded.left(end)),QCryptographicHash::Sha1);
  auto store=CertOpenStore(CERT_STORE_PROV_SYSTEM_W,0,0,CERT_SYSTEM_STORE_CURRENT_USER|CERT_STORE_READONLY_FLAG,L"ROOT");if(!store)return false;CRYPT_HASH_BLOB hash{DWORD(digest.size()),reinterpret_cast<BYTE*>(digest.data())};auto cert=CertFindCertificateInStore(store,X509_ASN_ENCODING|PKCS_7_ASN_ENCODING,0,CERT_FIND_SHA1_HASH,&hash,nullptr);bool found=cert!=nullptr;if(cert)CertFreeCertificateContext(cert);CertCloseStore(store,0);return found;
 }catch(...){return false;}
#else
 return false;
#endif
}
void WarProxy::setCaptureMode(QString mode){
 if(active_ || busy()){fail("请先停止代理，再切换连接方式");return;}
 if(mode!="proxy"){fail("此版本仅支持 HTTP / Steam 桥接，不包含网络捕获驱动。");return;}
 settings_.setValue("captureMode",mode);settings_.sync();proxyAddress_.clear();fail("连接方式已切换，尚未启动。");
}
void WarProxy::launchGame(QString gameDirectory){
 Q_UNUSED(gameDirectory);
 certificateTrusted_=verifyCertificateTrust();
 auto report=[this](QString message){launchStatus_=message;fail(message);};
 if(!active_ || !pluginReady_ || proxyAddress_.isEmpty()){report("请先开启 HTTP 代理兼容模式并等待就绪");return;}
 if(!certificateTrusted()){report("请先安装本机 CA，再通过 Steam 启动游戏");return;}
#ifdef Q_OS_WIN
 HANDLE snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);
 if(snapshot!=INVALID_HANDLE_VALUE){
  PROCESSENTRY32W entry{};entry.dwSize=sizeof(entry);bool running=false;
  if(Process32FirstW(snapshot,&entry)){do{if(QString::fromWCharArray(entry.szExeFile).compare("helldivers2.exe",Qt::CaseInsensitive)==0){running=true;break;}}while(Process32NextW(snapshot,&entry));}
  CloseHandle(snapshot);if(running){report("请先完全退出游戏，再通过 Steam 启动，才能应用本次代理环境");return;}
 }
#endif
 try{
  require(QFileInfo::exists(profile_+"/war-proxy/steam-bridge.exe"),"请先复制 Steam 启动选项，并粘贴到 Steam 游戏属性中");
  publishSteamSession();
  require(QDesktopServices::openUrl(QUrl("steam://rungameid/553850")),"无法打开 Steam 启动链接，请手动从 Steam 库启动游戏");
  report("已向 Steam 发送启动请求。请确认已粘贴桥接启动选项；游戏是否接入以效果目录和战况计数为准。");
 }catch(const std::exception& e){report(QString::fromUtf8(e.what()));}
}

void WarProxy::publishSteamSession(){
 if(!active_ || stopping_ || !pluginReady_ || captureMode()!="proxy" || proxyAddress_.isEmpty() || !certificateTrusted())return;
#ifdef Q_OS_WIN
 HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,DWORD(process_.processId()));
 FILETIME c{},e{},k{},u{};bool ok=process && GetProcessTimes(process,&c,&e,&k,&u);if(process)CloseHandle(process);
 require(ok,"无法读取代理会话标识，未生成 Steam 桥接配置");
 auto started=(quint64(c.dwHighDateTime)<<32)|c.dwLowDateTime;
 QByteArray content=("[proxy]\r\nport="+QString::number(QUrl(proxyAddress_).port())+"\r\npid="+QString::number(process_.processId())+"\r\nstarted="+QString::number(started)+"\r\n").toUtf8();
 auto path=profile_+"/war-proxy/steam-proxy.ini";
 if(!QFileInfo::exists(path) || read(path)!=content)write(path,content);
#endif
}

bool WarProxy::copySteamLaunchOptions(){
 try{
  auto target=profile_+"/war-proxy/steam-bridge.exe";
  updateSteamBridge();
  QApplication::clipboard()->setText("\""+QDir::toNativeSeparators(target)+"\" %command%");
  launchStatus_="Steam 启动选项已复制。请粘贴至：游戏属性 → 通用 → 启动选项。不会自动覆盖已有选项。";fail(launchStatus_);return true;
 }catch(const std::exception& e){launchStatus_=QString::fromUtf8(e.what());fail(launchStatus_);return false;}
}
void WarProxy::updateSteamBridge(){
 const auto target=profile_+"/war-proxy/steam-bridge.exe";
 require(QDir().mkpath(QFileInfo(target).absolutePath()),"无法创建 Steam 桥接目录");
 const auto bytes=read(QCoreApplication::applicationDirPath()+"/shodan-steam-bridge.exe");
 if(!QFileInfo::exists(target) || read(target)!=bytes){
  try{write(target,bytes);}catch(...){throw std::runtime_error("无法更新 Steam 桥接，请先完全退出游戏后重试。");}
 }
}
