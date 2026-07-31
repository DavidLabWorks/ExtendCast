#pragma once

#include <QMainWindow>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QStackedWidget>
#include <QSplitter>
#include <QListWidget>
#include <QTextEdit>
#include <QComboBox>
#include <QCheckBox>
#include <QSpinBox>
#include <QTimer>
#include <QSize>
#include <QMouseEvent>
#include <QSystemTrayIcon>
#include <QMenu>
#include <QAction>
#include <QStringList>
#include <QTime>
#include <QHash>
#include <QSet>

// Simple log manager (mirrors macOS LogManager)
class LogManager : public QObject {
    Q_OBJECT
public:
    static LogManager& instance() {
        static LogManager lm;
        return lm;
    }

    void log(const QString& msg) {
        QString entry = QString("[%1] %2")
            .arg(QTime::currentTime().toString("HH:mm:ss"), msg);
        m_entries.append(entry);
        if (m_entries.size() > 1000) m_entries.removeFirst();
        qDebug().noquote() << msg;
        emit logAdded(entry);
    }

    void clear() { m_entries.clear(); }
    const QStringList& entries() const { return m_entries; }

signals:
    void logAdded(const QString& entry);

private:
    LogManager() = default;
    QStringList m_entries;
};

struct DiscoveredRemoteReceiver;
class NetworkListener;
class InboundSessionConnector;
class ServiceDiscovery;
#ifdef ENABLE_ANDROID_ADB
class AdbHelper;
#endif
class ReceiverSession;
class QByteArray;
class QVBoxLayout;
class QFrame;
class QEvent;
class QNetworkAccessManager;
class QNetworkReply;
#ifdef ENABLE_SENDER
class SenderController;
class VirtualDisplayVDD;
#endif

class MainWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit MainWindow(QWidget* parent = nullptr);
    ~MainWindow();

protected:
    bool nativeEvent(const QByteArray& eventType, void* message, qintptr* result) override;
    bool eventFilter(QObject* watched, QEvent* event) override;
    void changeEvent(QEvent* event) override;
    void closeEvent(QCloseEvent* event) override;

private slots:
    void onSidebarSelectionChanged(int row);
#ifdef ENABLE_ANDROID_ADB
    void onAdbConnectClicked();
#endif
    void onConnectionEstablished(
        const QString& deviceId,
        const QString& deviceName,
        const QString& connectionId,
        const QString& peerAddress,
        quint16 peerPort,
        const QString& connectionMode
    );
    void onConnectionLost(const QString& deviceId);
    void onVideoDataReceived(
        const QString& deviceId,
        const QByteArray& data
    );
    void onAudioDataReceived(
        const QString& deviceId,
        const QByteArray& data
    );
    void onStatusChanged(const QString& status);
    void onReceiverListeningToggled(bool checked);
    void onReceiverAutoStartToggled(bool checked);
#ifdef ENABLE_ANDROID_ADB
    void attemptAdbReconnect();
#endif
    void onLogAdded(const QString& entry);
    void onCopyLogs();
    void onClearLogs();
    void onReportIssue();
    void onLaunchAtLoginToggled(bool checked);
    void onCheckUpdatesClicked();
    void onDownloadUpdateClicked();
    void onTrayActivated(QSystemTrayIcon::ActivationReason reason);
    void onShowFromTray();
    void onQuitFromTray();
    void onCopyReceiverAddressFromTray();
    void onOpenAppDataFolder();
    void onShowAbout();
#ifdef ENABLE_SENDER
    void onSendScreenClicked();
    void onStopSendingClicked();
    void onReceiverDiscovered(const DiscoveredRemoteReceiver& receiver);
    void onReceiverSelected(int index);
    void onCreateVirtualDisplay();
    void onRemoveVirtualDisplay();
    void onRefreshMonitors();
    void onMonitorSelected(int index);
#endif

private:
    void setupUi();
    void setupTitleBar(QVBoxLayout* rootLayout);
    void updateWindowControlStates();
    void setupSidebar();
    void setupOverviewPage();
    void setupReceivePage();
    void setupSettingsPage();
    void setupLogsPage();
    void refreshConnectedSendersCard();
#ifdef ENABLE_SENDER
    void setupSendPage();
    void admitVerifiedReceiver(const DiscoveredRemoteReceiver& receiver);
#endif
    void setupTrayIcon();
    void updateTrayActions();
    void updateLocalIpDisplay();
    void selectSidebarItem(int pageIndex);
    void updateLaunchAtLoginToggleStyle();
    void handleUpdateReply(QNetworkReply* reply);

    // Core components
    NetworkListener* m_network = nullptr;
    InboundSessionConnector* m_inboundCompatibilityConnector = nullptr;
    ServiceDiscovery* m_receiverServiceAdvertiser = nullptr;
#ifdef ENABLE_ANDROID_ADB
    AdbHelper* m_adbHelper = nullptr;
#endif
    QTimer* m_reconnectTimer = nullptr;
    int m_reconnectAttempts = 0;
#ifdef ENABLE_ANDROID_ADB
    bool m_wirelessAdbEnabled = false;
#endif
#ifdef ENABLE_SENDER
    SenderController* m_sender = nullptr;
    ServiceDiscovery* m_outboundReceiverBrowser = nullptr;
#endif

    // Layout
    QFrame* m_titleBar = nullptr;
    QPushButton* m_maximizeButton = nullptr;
    QSplitter* m_splitter = nullptr;
    QListWidget* m_sidebarList = nullptr;
    QStackedWidget* m_stack = nullptr;
    QSystemTrayIcon* m_trayIcon = nullptr;
    QMenu* m_trayMenu = nullptr;
    QAction* m_trayShowAction = nullptr;
    QAction* m_trayListeningAction = nullptr;
    QAction* m_trayCopyAddressAction = nullptr;
    bool m_quitRequested = false;

    // Page indices (set during setupUi based on ENABLE_SENDER)
    int m_pageOverview = -1;
    int m_pageSend = -1;     // only if ENABLE_SENDER
    int m_pageReceive = -1;
    int m_pageSettings = -1;
    int m_pageLogs = -1;

    // Overview page
    QLabel* m_overviewStatusLabel = nullptr;
    QLabel* m_overviewIpLabel = nullptr;

    // Receive page
    QLabel* m_recvStatusDot = nullptr;
    QLabel* m_recvStatusLabel = nullptr;
    QLabel* m_recvStatusDetailLabel = nullptr;
    QLabel* m_recvIpLabel = nullptr;
    QLabel* m_recvPrimaryTypeLabel = nullptr;
    QLabel* m_recvPrimaryAddressLabel = nullptr;
    QLabel* m_recvPrimaryHintLabel = nullptr;
    QVBoxLayout* m_recvAddressListLayout = nullptr;
    QVBoxLayout* m_connectedSenderListLayout = nullptr;
    QLabel* m_connectedSendersEmptyLabel = nullptr;
    QLabel* m_receiverConnectionsTitle = nullptr;
    QFrame* m_receiverConnectionsCard = nullptr;
    QPushButton* m_receiverListenToggle = nullptr;
    QPushButton* m_receiverAutoStartToggle = nullptr;
    bool m_receiverListening = false;
    uint16_t m_receiverPort = 51820;
    QString m_receiverAddressSignature;
    struct ConnectedSenderInfo {
        QString deviceName;
        QString connectionMode;
        QString peerAddress;
        quint16 peerPort = 0;
    };
    QHash<QString, ConnectedSenderInfo> m_connectedSenders;
#ifdef ENABLE_ANDROID_ADB
    QPushButton* m_adbBtn = nullptr;
    QLabel* m_adbHelpLabel = nullptr;
#endif

    // Settings page
    QLabel* m_versionLabel = nullptr;
    QPushButton* m_launchAtLoginToggle = nullptr;
    QPushButton* m_checkUpdatesButton = nullptr;
    QPushButton* m_downloadUpdateButton = nullptr;
    QLabel* m_updateStatusLabel = nullptr;
    QNetworkAccessManager* m_updateManager = nullptr;
    QString m_updateDownloadUrl;

    // Logs page
    QTextEdit* m_logViewer = nullptr;

    // One isolated decode/render/window pipeline per sender device ID.
    QHash<QString, ReceiverSession*> m_receiverSessions;

#ifdef ENABLE_SENDER
    // Send page
    QComboBox* m_receiverCombo = nullptr;
    QLineEdit* m_sendHostEdit = nullptr;
    uint16_t m_selectedReceiverPort = 51820;
    QSpinBox* m_fpsSpinBox = nullptr;
    QSpinBox* m_bitrateSpinBox = nullptr;
    QPushButton* m_sendBtn = nullptr;
    QPushButton* m_stopSendBtn = nullptr;
    QLabel* m_senderStatusLabel = nullptr;
    QSet<QString> m_pendingReceiverProbes;

    // Virtual Display (VDD) controls
    QComboBox* m_monitorCombo = nullptr;
    QComboBox* m_vddResolutionCombo = nullptr;
    QPushButton* m_createVddBtn = nullptr;
    QPushButton* m_removeVddBtn = nullptr;
    QPushButton* m_recheckVddBtn = nullptr;
    QLabel* m_vddStatusLabel = nullptr;
    QString m_lastSenderError;
#endif
};
