#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QScreen>
#include <QDir>
#include <QFile>
#include <QFontDatabase>
#include <QRawFont>
#include <QIcon>
#include <QTimer>
#include <cstdio>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "controller.h"
#include "husapp.h"

int main(int argc,char** argv){
 wchar_t executable[32768]{};GetModuleFileNameW(nullptr,executable,32768);
 const QString executableRoot=QFileInfo(QString::fromWCharArray(executable)).absolutePath();
 QCoreApplication::setLibraryPaths({executableRoot});
 if(!qEnvironmentVariableIsSet("SHODAN_HUSKAR_QA")){
  qputenv("QT_QPA_PLATFORM","windows");
  qputenv("QT_QPA_PLATFORM_PLUGIN_PATH",(executableRoot+"/platforms").toUtf8());
 }
 QString profile=qEnvironmentVariable("SHODAN_PROFILE");
 if(profile.isEmpty())profile=qEnvironmentVariable("LOCALAPPDATA")+"/SHODAN/StatEditor";
 QDir().mkpath(profile+"/Logs");
 const auto log=(profile+"/Logs/huskar-startup.log").toStdWString();
 _wfreopen(log.c_str(),L"w",stderr);
 qInstallMessageHandler([](QtMsgType type,const QMessageLogContext&,const QString& text){
  fprintf(stderr,"[%d] %s\n",int(type),qPrintable(text));fflush(stderr);
 });
 // Match the Gallery's transparent surface setup before any QQuickWindow exists.
 // Changing color to transparent after creating an opaque swap chain gives a black backdrop.
 QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
 QQuickWindow::setDefaultAlphaBuffer(true);
 QApplication app(argc,argv);
 // Offscreen verification needs explicit fonts; the Windows plugin uses DirectWrite.
 if(QGuiApplication::platformName()=="offscreen"){
  QFontDatabase::addApplicationFont("C:/Windows/Fonts/msyh.ttc");
  QFontDatabase::addApplicationFont("C:/Windows/Fonts/segoeui.ttf");
 }
 app.setApplicationName("SHODAN 数值编辑器");app.setOrganizationName("SHODAN");app.setApplicationVersion(QString::fromUtf8(shodan::version));
 app.setWindowIcon(QIcon(executableRoot+"/assets/shodan.png"));
 QDir::setCurrent(executableRoot);
 Controller controller;
 QQmlApplicationEngine engine;
 // HusApp is a lazy QML singleton. Initialize it before constructing controls:
 // otherwise pages that never reference HusApp leave its icon font unregistered.
 HusApp::initialize(&engine);
 const QRawFont iconFont=QRawFont::fromFont(QFont("HuskarUI-Icons",20));
 const bool iconsReady=QFontDatabase::families().contains("HuskarUI-Icons")
  && iconFont.supportsCharacter(0xeb9e) && iconFont.supportsCharacter(0xeba0);
 fprintf(stderr,"[huskar] Icon font registered=%d family=%s\n",iconsReady,qPrintable(iconFont.familyName()));fflush(stderr);
 if(!iconsReady)return 3;
 engine.addImportPath(QCoreApplication::applicationDirPath()+"/qml");
 if(!QFile::exists(QCoreApplication::applicationDirPath()+"/qml/HuskarUI/Basic/qmldir"))engine.addImportPath(HUSKAR_IMPORT_PATH);
 engine.rootContext()->setContextProperty("Backend",&controller);
 engine.rootContext()->setContextProperty("AssetRoot",QUrl::fromLocalFile(QCoreApplication::applicationDirPath()+"/assets/"));
 engine.rootContext()->setContextProperty("QaMode",qEnvironmentVariableIsSet("SHODAN_HUSKAR_QA"));
 engine.rootContext()->setContextProperty("QaRestoreMode",qEnvironmentVariableIsSet("SHODAN_HUSKAR_RESTORE_QA"));
 engine.rootContext()->setContextProperty("QaDirectory",qEnvironmentVariable("SHODAN_HUSKAR_QA"));
 QObject::connect(&engine,&QQmlApplicationEngine::objectCreationFailed,&app,[]{QCoreApplication::exit(2);},Qt::QueuedConnection);
 engine.load(QUrl("qrc:/shodan/Main.qml"));
 fprintf(stderr,"[huskar] QML loaded: %lld roots, QA=%d\n",qint64(engine.rootObjects().size()),qEnvironmentVariableIsSet("SHODAN_HUSKAR_QA"));fflush(stderr);
 if(engine.rootObjects().isEmpty())return 2;
 if(auto* window=qobject_cast<QQuickWindow*>(engine.rootObjects().first())){
  auto area=window->screen()->availableGeometry();
  if(qEnvironmentVariableIsSet("SHODAN_HUSKAR_QA") && QGuiApplication::platformName()=="offscreen")window->resize(1480,960);
  else window->resize(qMin(1480,area.width()-60),qMin(960,area.height()-60));
  window->setPosition(area.center()-QPoint(window->width()/2,window->height()/2));
  window->show();window->raise();window->requestActivate();
  fprintf(stderr,"[huskar] Window visible=%d size=%dx%d\n",window->isVisible(),window->width(),window->height());fflush(stderr);
 }
 QObject::connect(&app,&QCoreApplication::aboutToQuit,[]{fprintf(stderr,"[huskar] Application quitting\n");fflush(stderr);});
 return app.exec();
}
