#pragma once
#include <QObject>
#include <QProcess>
#include <QSettings>
#include <QJsonObject>
#include <QFileInfo>
#include <QTimer>
#include <QJsonArray>
#include <QLockFile>
#include <memory>

// Uses the upstream mitmproxy core. No game writes or automatic startup.
class WarProxy : public QObject {
 Q_OBJECT
 Q_PROPERTY(QString status READ status NOTIFY changed)
 Q_PROPERTY(bool busy READ busy NOTIFY changed)
 Q_PROPERTY(bool active READ active NOTIFY changed)
 Q_PROPERTY(QString executable READ executable NOTIFY changed)
 Q_PROPERTY(QString certificateStatus READ certificateStatus NOTIFY changed)
 Q_PROPERTY(QVariantList targets READ targets NOTIFY targetsChanged)
 Q_PROPERTY(QVariantList effects READ effects NOTIFY modelsChanged)
 Q_PROPERTY(QVariantList planets READ planets NOTIFY modelsChanged)
 Q_PROPERTY(bool pluginReady READ pluginReady NOTIFY changed)
 Q_PROPERTY(bool catalogFresh READ catalogFresh NOTIFY changed)
 Q_PROPERTY(bool certificateTrusted READ certificateTrusted NOTIFY changed)
 Q_PROPERTY(QString captureMode READ captureMode NOTIFY changed)
 Q_PROPERTY(QString proxyAddress READ proxyAddress NOTIFY changed)
 Q_PROPERTY(QString launchStatus READ launchStatus NOTIFY changed)
public:
 explicit WarProxy(QString profile,QObject* parent=nullptr);
 ~WarProxy() override;
 QString status()const{return status_;}
 bool busy()const{return preparing_ || certificateProcess_.state()!=QProcess::NotRunning || process_.state()==QProcess::Starting;}
 bool active()const{return active_;}
 QString executable()const;
 QString certificateStatus()const{return certificateStatus_;}
 QVariantList targets()const{return targets_.toVariantList();}
 QVariantList effects()const{return effects_.toVariantList();}
 QVariantList planets()const{return planets_.toVariantList();}
 bool pluginReady()const{return pluginReady_;}
 bool catalogFresh()const{return catalogFresh_;}
 bool certificateTrusted()const;
 QString captureMode()const{return "proxy";}
 QString proxyAddress()const{return proxyAddress_;}
 QString launchStatus()const{return launchStatus_;}
 Q_INVOKABLE void chooseExecutable();
 Q_INVOKABLE void openCertificate();
 Q_INVOKABLE void installCertificate();
 Q_INVOKABLE void uninstallCertificate();
 Q_INVOKABLE void prepareCertificate(bool installAfter=true);
 Q_INVOKABLE bool saveTarget(QString json);
 Q_INVOKABLE void removeTarget(int planet);
 Q_INVOKABLE bool startConfigured(bool observeOnly=false);
 Q_INVOKABLE void importTargets();
 Q_INVOKABLE void exportTargets();
 Q_INVOKABLE void restoreBackup();
 Q_INVOKABLE void refreshCatalog();
 Q_INVOKABLE void setCaptureMode(QString mode);
 Q_INVOKABLE void launchGame(QString gameDirectory);
 Q_INVOKABLE bool copySteamLaunchOptions();
 Q_INVOKABLE QString check();
 Q_INVOKABLE bool start(int planet,QString faction,QString effects);
 Q_INVOKABLE void stop();
 Q_INVOKABLE bool exportPlan(int planet,QString faction,QString effects);
 static QJsonObject plan(int planet,const QString& faction,const QString& effects);
 static QJsonArray validateTargets(QJsonArray targets);
signals:
 void changed();
 void modelsChanged();
 void targetsChanged();
private:
 friend struct WarProxyTestAccess;
 QSettings settings_;
 QProcess process_;
 QProcess certificateProcess_;
 QString certificateThumbprint_;
 QString certificateStatus_="仅在点击安装后信任本机 CA；不会静默修改系统级证书库。";
 bool removingCertificate_=false;
 QString status_="变种代理未开启";
 bool active_=false,stopping_=false;
 bool mitmSession_=false;
 bool preparing_=false,pluginReady_=false,catalogFresh_=false;
 bool installAfterPreparation_=false;
 QJsonArray targets_,effects_,planets_;
 QJsonObject metadata_;
 QByteArray catalogStamp_,planetStamp_;
 double sessionStart_=0;
 qint64 lastHealthReadMs_=0;
 std::unique_ptr<QLockFile> lock_;
 void* job_=nullptr;
 int generation_=0;
 QString terminalError_;
 QString proxyAddress_;
 QString launchStatus_;
 QTimer* statusTimer_=nullptr;
 QString profile_;
 bool startMitm(int planet,QString faction,QString effects);
 bool launchPlan(QJsonObject plan,bool prepareOnly=false);
 void publishSteamSession();
 void updateSteamBridge();
 void pollHealth();
 void persistTargets(QJsonArray targets);
 void fail(QString message){status_=message;emit changed();}
};
