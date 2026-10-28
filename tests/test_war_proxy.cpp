#include "war_proxy.h"
#include <QCoreApplication>
#include <QTemporaryDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonArray>
#include <QCryptographicHash>
#include <iostream>
#include <stdexcept>
#include <QSettings>
#include <QEventLoop>
#include <QTimer>
#include <QDateTime>
struct WarProxyTestAccess {
 static void log(WarProxy& p,QString path){p.process_.setProcessChannelMode(QProcess::MergedChannels);p.process_.setStandardOutputFile(path);}
 static void beginHealth(WarProxy& p){p.mitmSession_=true;p.sessionStart_=QDateTime::currentMSecsSinceEpoch()/1000.0-1;}
 static void poll(WarProxy& p){p.pollHealth();}
 static void expireHealth(WarProxy& p){p.lastHealthReadMs_=QDateTime::currentMSecsSinceEpoch()-16000;}
 static void endHealth(WarProxy& p){p.mitmSession_=false;}
 static void updateBridge(WarProxy& p){p.updateSteamBridge();}
};
static void check(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
static void save(QString path,QByteArray b){QFile f(path);check(f.open(QIODevice::WriteOnly),"fixture write");check(f.write(b)==b.size(),"fixture bytes");}
static QByteArray read(QString path){QFile f(path);check(f.open(QIODevice::ReadOnly),"fixture read");return f.readAll();}
static QString hash(QByteArray b){return QString::fromLatin1(QCryptographicHash::hash(b,QCryptographicHash::Sha256).toHex());}
int main(int argc,char** argv){
 QCoreApplication app(argc,argv);
 try{
  auto p=WarProxy::plan(182,"illuminate","1373，1386 1373");
  check(p["variants"].toObject()["shodan_planet_182"].toArray().size()==2,"deduplicate effects");
  check(p["targets"].toArray()[0].toObject()["planet"]==182,"exact planet index");
  for(auto invalid:{"0","-1","1373x","", "2147483648"}){bool rejected=false;try{WarProxy::plan(182,"illuminate",invalid);}catch(...){rejected=true;}check(rejected,"invalid effect accepted");}
  bool rejected=false;try{WarProxy::plan(-1,"illuminate","1373");}catch(...){rejected=true;}check(rejected,"invalid planet");
  auto list=WarProxy::validateTargets(QJsonArray{QJsonObject{{"planet",182},{"effects",QJsonArray{1373,1373}},{"enabled",false},{"owner",4},{"campaign",true},{"campaign_type",3}}});
  check(list[0].toObject()["effects"].toArray().size()==1,"target dedup");
  auto separateRace=WarProxy::validateTargets(QJsonArray{QJsonObject{{"planet",260},{"effects",QJsonArray{}},{"owner",1},{"campaign",true},{"campaign_race",3}}});
  check(separateRace[0].toObject()["owner"]==1 && separateRace[0].toObject()["campaign_race"]==3,"ownership must be independent from operation enemy");
  rejected=false;try{WarProxy::validateTargets(QJsonArray{list[0],list[0]});}catch(...){rejected=true;}check(rejected,"duplicate target");
  QTemporaryDir profile;check(profile.isValid(),"temporary profile");
  {QSettings old(profile.filePath("war-proxy.ini"),QSettings::IniFormat);old.setValue("captureMode","local");old.sync();}
  {WarProxy driverless(profile.path());check(driverless.captureMode()=="proxy","old capture setting must migrate to HTTP");driverless.setCaptureMode("local");check(driverless.captureMode()=="proxy" && driverless.status().contains("不包含网络捕获驱动"),"local capture should not remain available");}
  if(argc==3 && QString::fromLocal8Bit(argv[1])=="--native-core"){
   QSettings settings(profile.filePath("war-proxy.ini"),QSettings::IniFormat);settings.setValue("mitmdump",QString::fromLocal8Bit(argv[2]));settings.sync();
   WarProxy proxy(profile.path());if(!qEnvironmentVariable("SHODAN_PROXY_TEST_LOG").isEmpty())WarProxyTestAccess::log(proxy,qEnvironmentVariable("SHODAN_PROXY_TEST_LOG"));QEventLoop loop;
   QObject::connect(&proxy,&WarProxy::changed,&loop,[&]{if(proxy.status().contains("核心自检通过") || proxy.status().contains("已退出") || proxy.status().contains("无法启动"))loop.quit();});
   QTimer::singleShot(65000,&loop,&QEventLoop::quit);proxy.prepareCertificate(false);loop.exec();
   check(proxy.status().contains("核心自检通过"),proxy.status().toUtf8().constData());
   check(!proxy.certificateTrusted(),"native smoke must not install trust");
   check(QFileInfo::exists(profile.filePath("war-proxy/ca/mitmproxy-ca-cert.cer")),"CA not generated");
  }
  {WarProxy proxy(profile.path());check(proxy.saveTarget("{\"planet\":93,\"effects\":[1386]}"),"save plan");check(proxy.saveTarget("{\"planet\":182,\"effects\":[1373],\"enabled\":false}"),"save second plan");}
  {WarProxy restored(profile.path());check(restored.targets().size()==2,"restart persistence");check(!restored.active(),"must not autostart");restored.removeTarget(182);check(restored.targets().size()==1,"remove target");restored.restoreBackup();check(restored.targets().size()==2,"restore backup");}
  QDir().mkpath(profile.filePath("war-proxy"));
  {WarProxy upgrade(profile.path());const auto target=profile.filePath("war-proxy/steam-bridge.exe");save(target,"old bridge");WarProxyTestAccess::updateBridge(upgrade);check(read(target)==read(QCoreApplication::applicationDirPath()+"/shodan-steam-bridge.exe"),"persistent bridge was not upgraded");}
  {
   WarProxy health(profile.path());WarProxyTestAccess::beginHealth(health);
   WarProxyTestAccess::poll(health);check(!health.pluginReady() && health.status().contains("等待代理状态"),"missing initial health should wait, not report file read error");
   auto status=[&](double updated){save(profile.filePath("war-proxy/health.json"),QJsonDocument(QJsonObject{{"ready",true},{"router_port",32123},{"updated",updated},{"message","healthy"}}).toJson());};
   status(QDateTime::currentMSecsSinceEpoch()/1000.0-60);WarProxyTestAccess::poll(health);check(!health.pluginReady(),"old session health accepted");
   status(QDateTime::currentMSecsSinceEpoch()/1000.0);WarProxyTestAccess::poll(health);check(health.pluginReady(),"fresh health did not recover");
   check(health.proxyAddress()=="http://127.0.0.1:32123","bridge must use API-only dispatcher instead of mitmproxy upstream listener");
   QFile::remove(profile.filePath("war-proxy/health.json"));WarProxyTestAccess::poll(health);check(health.pluginReady() && health.status().contains("自动重试"),"transient missing health should retry");
   save(profile.filePath("war-proxy/steam-proxy.ini"),"stale bridge");WarProxyTestAccess::expireHealth(health);WarProxyTestAccess::poll(health);
   check(!health.pluginReady() && !QFileInfo::exists(profile.filePath("war-proxy/steam-proxy.ini")),"prolonged health failure left stale bridge enabled");
   status(QDateTime::currentMSecsSinceEpoch()/1000.0);WarProxyTestAccess::poll(health);check(health.pluginReady(),"health did not recover after timeout");
   save(profile.filePath("war-proxy/health.json"),"{partial");WarProxyTestAccess::expireHealth(health);WarProxyTestAccess::poll(health);check(!health.pluginReady(),"malformed health treated as ready");
   WarProxyTestAccess::endHealth(health);
  }
  save(profile.filePath("war-proxy/catalog.json"),R"({"effects":[{"id":1211,"effectType":71,"nameHash":0}],"updated":0})");
  // Wrong name hash must not acquire a possibly unrelated reference title.
  {WarProxy display(profile.path());auto rows=display.effects();check(rows.size()==1,"live catalog filter");check(rows[0].toMap()["translation_source"].toString()!="用户提供的资源 ID 对照表","reference identity guard");}
  auto metadata=QJsonDocument::fromJson(read(":/shodan/war_catalog.json")).object();auto reference=metadata["effect_reference"].toObject()["1211"].toObject();
  save(profile.filePath("war-proxy/catalog.json"),QJsonDocument(QJsonObject{{"effects",QJsonArray{QJsonObject{{"id",1211},{"effectType",71},{"nameHash",reference["nameHash"]}}}},{"updated",0}}).toJson());
  {WarProxy display(profile.path());auto row=display.effects()[0].toMap();check(row["name"].toString()==reference["name"].toString(),"reference Chinese title priority");}
  std::cout<<"PASS: plan validation and effect deduplication\n";return 0;
 }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
