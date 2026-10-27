#pragma once
#include <QObject>
#include <QThread>
#include <QVariant>
#include <QTimer>
#include <QSettings>
#include <memory>
#include "bridge.h"
#include "version.h"
#include "mcp_server.h"

class Controller : public QObject {
 Q_OBJECT
 Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
 Q_PROPERTY(QString version READ version CONSTANT)
 Q_PROPERTY(QString profile READ profile CONSTANT)
 Q_PROPERTY(QString updateStatus READ updateStatus NOTIFY updateChanged)
 Q_PROPERTY(bool checking READ checking NOTIFY updateChanged)
 Q_PROPERTY(bool mcpEnabled READ mcpEnabled NOTIFY mcpChanged)
public:
 explicit Controller(QObject* parent=nullptr);
 ~Controller();
 bool ready()const{return ready_;}
 QString version()const{return QString::fromUtf8(shodan::version);}
 QString profile()const{return profile_;}
 QString updateStatus()const{return updateStatus_;}
 bool checking()const{return checking_;}
 bool mcpEnabled()const{return mcp_.enabled();}
 Q_INVOKABLE int request(QString method,QVariantList args={});
 Q_INVOKABLE QVariant setting(QString name,QVariant fallback={});
 Q_INVOKABLE void saveSetting(QString name,QVariant value);
 Q_INVOKABLE void checkUpdate();
 Q_INVOKABLE void toggleMcp();
 Q_INVOKABLE void copyMcp();
 Q_INVOKABLE QString readText(QString path);
 Q_INVOKABLE bool writeText(QString path,QString text);
 Q_INVOKABLE QString chooseFile(bool save,QString filter);
 Q_INVOKABLE QStringList chooseMods();
 Q_INVOKABLE QString chooseBackground();
 Q_INVOKABLE QString backgroundAccent(QString source,bool dark);
 Q_INVOKABLE QString qaBackground(QString path);
 Q_INVOKABLE QString storeTheme(QString json);
 Q_INVOKABLE QStringList themeComponents()const;
 Q_INVOKABLE void openUrl(QString url);
 Q_INVOKABLE bool capture(QString name);
 Q_INVOKABLE void finishQa(QString error);
 Q_INVOKABLE bool qaEdit(QString objectName,QString text,bool enter);
 Q_INVOKABLE bool qaDrag(QString objectName);
 Q_INVOKABLE bool qaCheck(QString objectName,bool click=false);
 Q_INVOKABLE bool qaWheel(QString objectName);
signals:
 void readyChanged();
 void initialized(QVariantMap data);
 void completed(int requestId,QVariant value,QString error);
 void progress(QString message,int done,int total);
 void startupError(QString error);
 void updateChanged();
 void updateAvailable(QString version,QString url,QString notes,QString downloadUrl);
 void mcpChanged();
 void externalChange();
private:
 bool ready_=false,checking_=false;
 int serial_=0;
 QString profile_,updateStatus_="每次启动自动检查一次正式发行版";
 QThread thread_;
 QObject* worker_=nullptr;
 std::unique_ptr<Backend> backend_;
 std::unique_ptr<QSettings> settings_;
 shodan::McpServer mcp_;
 QTimer mcpTimer_;
 QVariant dispatch(const QString& method,const QVariantList& args);
 Value invoke(const std::string& method,const std::vector<Value>& args);
 void pollMcp();
 void start();
 QString saveBackground(QString path);
 struct State;
 std::unique_ptr<State> state_;
};
