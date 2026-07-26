#include <QApplication>
#include <QSurfaceFormat>
#include <QIcon>
#include <QProcess>
#include <QStandardPaths>
#include <QFile>
#include <QLockFile>
#include <QLocalServer>
#include <QLocalSocket>
#include <QDebug>
#include <thread>
#include "MainWindow.h"
#include "Version.h"

#ifdef _WIN32
// Add Windows Firewall exceptions for mDNS and streaming
static void ensureFirewallRule() {
    // Check if our firewall rules already exist
    QProcess check;
    check.start("netsh", {"advfirewall", "firewall", "show", "rule", "name=ExtendCast mDNS In"});
    check.waitForFinished(3000);
    QString output = QString::fromUtf8(check.readAllStandardOutput());
    if (output.contains("ExtendCast mDNS In")) {
        qDebug() << "Firewall: Rules already exist";
        return;
    }

    qDebug() << "Firewall: Adding rules (requires admin)...";

    // Inbound UDP 5353 — receive mDNS queries from Mac/other devices
    QProcess addIn;
    addIn.start("netsh", {"advfirewall", "firewall", "add", "rule",
                          "name=ExtendCast mDNS In",
                          "dir=in", "action=allow", "protocol=UDP",
                          "localport=5353",
                          "profile=private,public",
                          "description=Allow inbound mDNS for ExtendCast auto-discovery"});
    addIn.waitForFinished(3000);

    // Outbound UDP 5353 — send mDNS announcements to multicast
    QProcess addOut;
    addOut.start("netsh", {"advfirewall", "firewall", "add", "rule",
                           "name=ExtendCast mDNS Out",
                           "dir=out", "action=allow", "protocol=UDP",
                           "remoteport=5353",
                           "profile=private,public",
                           "description=Allow outbound mDNS for ExtendCast auto-discovery"});
    addOut.waitForFinished(3000);

    // Inbound TCP 51820 — accept streaming connections
    QProcess addTcp;
    addTcp.start("netsh", {"advfirewall", "firewall", "add", "rule",
                            "name=ExtendCast Receiver",
                            "dir=in", "action=allow", "protocol=TCP",
                            "localport=51820",
                            "profile=private,public",
                            "description=Allow ExtendCast screen streaming"});
    addTcp.waitForFinished(3000);

    // Log firewall status — this runs before LogManager UI is set up,
    // so we store the result and MainWindow will log it later
    if (addIn.exitCode() == 0) {
        qputenv("EXTENDCAST_FW_STATUS", "ok");
        qDebug() << "Firewall: Rules added successfully";
    } else {
        qputenv("EXTENDCAST_FW_STATUS", "failed");
        qDebug() << "Firewall: Could not add rules (needs admin)";
    }
}
#endif

static const char* kSingleInstanceServerName = "ExtendCastReceiver";

static void notifyExistingInstance() {
    QLocalSocket socket;
    socket.connectToServer(kSingleInstanceServerName, QIODevice::WriteOnly);
    if (socket.waitForConnected(300)) {
        socket.write("show");
        socket.flush();
        socket.waitForBytesWritten(300);
    }
}

int main(int argc, char* argv[]) {
    // Use Compatibility Profile for GL_LUMINANCE/GL_LUMINANCE_ALPHA support
    // Core Profile removes these, breaking NV12 texture uploads on Windows
    QSurfaceFormat format;
    format.setVersion(2, 1);
    format.setProfile(QSurfaceFormat::CompatibilityProfile);
    format.setSwapInterval(1); // VSync
    QSurfaceFormat::setDefaultFormat(format);

    QApplication app(argc, argv);

    QLockFile singleInstanceLock(QStandardPaths::writableLocation(QStandardPaths::TempLocation) + "/ExtendCast.lock");
    singleInstanceLock.setStaleLockTime(0);
    if (!singleInstanceLock.tryLock(100)) {
        notifyExistingInstance();
        qDebug() << "ExtendCast is already running";
        return 0;
    }

    app.setApplicationName("ExtendCast");
    app.setOrganizationName("ExtendCast");
    app.setApplicationVersion(EXTENDCAST_VERSION);
    app.setWindowIcon(QIcon(":/appicon.png"));

    MainWindow window;

    QLocalServer::removeServer(kSingleInstanceServerName);
    QLocalServer singleInstanceServer;
    if (singleInstanceServer.listen(kSingleInstanceServerName)) {
        QObject::connect(&singleInstanceServer, &QLocalServer::newConnection,
                         &window, [&singleInstanceServer, &window]() {
            while (auto* socket = singleInstanceServer.nextPendingConnection()) {
                socket->deleteLater();
            }
            window.show();
            if (window.isMinimized()) {
                window.showNormal();
            }
            window.raise();
            window.activateWindow();
        });
    } else {
        qDebug() << "Single-instance server failed:" << singleInstanceServer.errorString();
    }

    window.show();

#ifdef _WIN32
    std::thread([]() {
        ensureFirewallRule();
    }).detach();
#endif

    return app.exec();
}
