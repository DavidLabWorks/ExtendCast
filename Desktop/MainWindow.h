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
#include <QStringList>
#include <QTime>
#include <QHash>

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

struct DiscoveredService;
class NetworkListener;
class ServiceDiscovery;
class AdbHelper;
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

private slots:
    void onSidebarSelectionChanged(int row);
    void onConnectClicked();
    void onAdbConnectClicked();
    void onConnectionEstablished(
        const QString& deviceId,
        const QString& deviceName,
        const QString& connectionId,
        const QString& peerAddress
    );
    void onConnectionLost(const QString& deviceId);
    void onVideoDataReceived(
        const QString& deviceId,
        const QByteArray& data,
        bool hasPtsPrefix
    );
    void onAudioDataReceived(
        const QString& deviceId,
        const QByteArray& data
    );
    void onStatusChanged(const QString& status);
    void onReceiverListeningToggled(bool checked);
    void onReceiverAutoStartToggled(bool checked);
    void attemptAdbReconnect();
    void onLogAdded(const QString& entry);
    void onCopyLogs();
    void onClearLogs();
    void onReportIssue();
    void onLaunchAtLoginToggled(bool checked);
    void onCheckUpdatesClicked();
    void onDownloadUpdateClicked();
#ifdef ENABLE_SENDER
    void onSendScreenClicked();
    void onStopSendingClicked();
    void onReceiverDiscovered(const DiscoveredService& service);
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
#ifdef ENABLE_SENDER
    void setupSendPage();
#endif
    void updateLocalIpDisplay();
    void selectSidebarItem(int pageIndex);
    void updateLaunchAtLoginToggleStyle();
    void handleUpdateReply(QNetworkReply* reply);

    // Core components
    NetworkListener* m_network = nullptr;
    ServiceDiscovery* m_discovery = nullptr;
    AdbHelper* m_adbHelper = nullptr;
    QTimer* m_reconnectTimer = nullptr;
    int m_reconnectAttempts = 0;
    bool m_wirelessAdbEnabled = false;
#ifdef ENABLE_SENDER
    SenderController* m_sender = nullptr;
#endif

    // Layout
    QFrame* m_titleBar = nullptr;
    QPushButton* m_maximizeButton = nullptr;
    QSplitter* m_splitter = nullptr;
    QListWidget* m_sidebarList = nullptr;
    QStackedWidget* m_stack = nullptr;

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
    QLabel* m_receiverConnectionsTitle = nullptr;
    QFrame* m_receiverConnectionsCard = nullptr;
    QPushButton* m_receiverListenToggle = nullptr;
    QPushButton* m_receiverAutoStartToggle = nullptr;
    bool m_receiverListening = false;
    uint16_t m_receiverPort = 51820;
    QString m_receiverAddressSignature;
    QLineEdit* m_hostEdit = nullptr;
    QLineEdit* m_portEdit = nullptr;
    QPushButton* m_connectBtn = nullptr;
    QPushButton* m_adbBtn = nullptr;
    QLabel* m_adbHelpLabel = nullptr;

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
