#include "MainWindow.h"
#include "VideoDecoder.h"
#include "VideoRenderer.h"
#include "VideoWindow.h"
#include "NetworkListener.h"
#include "InputHandler.h"
#include "InputEvent.h"
#include "ServiceDiscovery.h"
#include "AudioDecoder.h"
#include "AudioPlayer.h"
#include "AdbHelper.h"
#include "ServiceDiscovery.h"
#ifdef ENABLE_SENDER
#include "sender/SenderController.h"
#include "sender/VirtualDisplayVDD.h"
#endif

#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QGridLayout>
#include <QGroupBox>
#include <QFrame>
#include <QScrollArea>
#include <QScreen>
#include <QApplication>
#include <QClipboard>
#include <QDesktopServices>
#include <QMessageBox>
#include <QStandardPaths>
#include <QSettings>
#include <QPainter>
#include <QSvgRenderer>
#include <QFile>
#include <QHash>
#include <QDir>
#include <QDebug>
#include <QNetworkInterface>
#include <QUrl>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QStyledItemDelegate>
#include <QStyleOptionViewItem>
#include <algorithm>
#include <thread>

// ─── Dark theme stylesheet ─────────────────────────────────────────────────────

static const char* kDarkStylesheet = R"(
    QMainWindow { background-color: #1a1a1a; }
    QSplitter { background-color: #1a1a1a; }
    QSplitter::handle { background: transparent; width: 0px; }

    QListWidget {
        background-color: #202020;
        border: none;
        outline: none;
        font-size: 14px;
        padding: 18px 0 0 0;
    }
    QListWidget::item {
        border: none;
    }
    QListWidget::item:selected {
        background: transparent;
    }
    QListWidget::item:hover:!selected {
        background: transparent;
    }

    QStackedWidget { background-color: #1a1a1a; }
    QScrollArea { background-color: #1a1a1a; border: none; }
    QScrollArea > QWidget > QWidget { background-color: #1a1a1a; }

    QScrollBar:vertical {
        background: transparent;
        width: 10px;
        margin: 4px 2px 4px 2px;
    }
    QScrollBar::handle:vertical {
        background: rgba(255, 255, 255, 0.22);
        border-radius: 4px;
        min-height: 36px;
    }
    QScrollBar::handle:vertical:hover {
        background: rgba(255, 255, 255, 0.34);
    }
    QScrollBar::handle:vertical:pressed {
        background: rgba(255, 255, 255, 0.46);
    }
    QScrollBar::add-line:vertical,
    QScrollBar::sub-line:vertical {
        height: 0px;
        border: none;
        background: transparent;
    }
    QScrollBar::add-page:vertical,
    QScrollBar::sub-page:vertical {
        background: transparent;
    }

    QScrollBar:horizontal {
        background: transparent;
        height: 10px;
        margin: 2px 4px 2px 4px;
    }
    QScrollBar::handle:horizontal {
        background: rgba(255, 255, 255, 0.22);
        border-radius: 4px;
        min-width: 36px;
    }
    QScrollBar::handle:horizontal:hover {
        background: rgba(255, 255, 255, 0.34);
    }
    QScrollBar::handle:horizontal:pressed {
        background: rgba(255, 255, 255, 0.46);
    }
    QScrollBar::add-line:horizontal,
    QScrollBar::sub-line:horizontal {
        width: 0px;
        border: none;
        background: transparent;
    }
    QScrollBar::add-page:horizontal,
    QScrollBar::sub-page:horizontal {
        background: transparent;
    }

    QLabel { color: #e0e0e0; }

    QLineEdit {
        background-color: #2a2a2a;
        color: white;
        border: 1px solid #444;
        border-radius: 6px;
        padding: 7px 10px;
        font-size: 13px;
        selection-background-color: #0078D4;
    }
    QLineEdit:focus { border-color: #0078D4; }

    QPushButton {
        background-color: #333;
        color: white;
        border: 1px solid #555;
        border-radius: 6px;
        padding: 8px 16px;
        font-size: 13px;
    }
    QPushButton:hover { background-color: #444; border-color: #666; }
    QPushButton:pressed { background-color: #555; }
    QPushButton:disabled { background-color: #2a2a2a; color: #666; border-color: #333; }

    QGroupBox {
        color: #888;
        border: 1px solid #333;
        border-radius: 10px;
        margin-top: 16px;
        padding: 20px 16px 12px 16px;
        font-size: 12px;
        font-weight: bold;
    }
    QGroupBox::title {
        subcontrol-origin: margin;
        left: 16px;
        padding: 0 6px;
        color: #888;
    }

    QTextEdit {
        background-color: #111;
        color: #888;
        border: none;
        font-family: "Cascadia Code", "Consolas", "SF Mono", monospace;
        font-size: 11px;
    }

    QSpinBox {
        background-color: #2a2a2a;
        color: white;
        border: 1px solid #444;
        border-radius: 6px;
        padding: 5px 8px;
        font-size: 13px;
    }
    QSpinBox:focus { border-color: #0078D4; }
    QSpinBox::up-button, QSpinBox::down-button {
        background-color: #333;
        border: none;
        width: 20px;
    }

    QComboBox {
        background-color: #2a2a2a;
        color: white;
        border: 1px solid #444;
        border-radius: 6px;
        padding: 5px 8px;
        font-size: 13px;
    }
    QComboBox:focus { border-color: #0078D4; }
    QComboBox::drop-down { border: none; }
    QComboBox QAbstractItemView {
        background-color: #2a2a2a;
        color: white;
        selection-background-color: #0078D4;
    }

    QCheckBox { color: #e0e0e0; font-size: 13px; spacing: 8px; }
    QCheckBox::indicator {
        width: 16px; height: 16px;
        border: 1px solid #555; border-radius: 4px;
        background-color: #2a2a2a;
    }
    QCheckBox::indicator:checked { background-color: #0078D4; border-color: #0078D4; }
)";

// ─── Sidebar section header helper ──────────────────────────────────────────────

static QListWidgetItem* addSidebarSection(QListWidget* list, const QString& title) {
    auto* item = new QListWidgetItem(title);
    item->setFlags(Qt::ItemIsEnabled); // not selectable
    item->setData(Qt::UserRole, -1);
    QFont f = item->font();
    f.setPointSize(9);
    f.setBold(true);
    item->setFont(f);
    item->setForeground(QColor("#777"));
    // Add extra spacing above sections (except the first)
    if (list->count() > 0) {
        item->setSizeHint(QSize(0, 32));
    }
    list->addItem(item);
    return item;
}

static QIcon makeSidebarIcon(const QString& name) {
    static const QHash<QString, QString> kIconPaths = {
        {"sender", ":/icons/sidebar-sender.svg"},
        {"devices", ":/icons/sidebar-devices.svg"},
        {"recent", ":/icons/sidebar-recent.svg"},
        {"connect", ":/icons/sidebar-connect.svg"},
        {"receiver", ":/icons/sidebar-receiver.svg"},
        {"settings", ":/icons/sidebar-settings.svg"},
        {"logs", ":/icons/sidebar-logs.svg"},
        {"power", ":/icons/sidebar-power.svg"},
    };

    auto drawIcon = [&](const QColor& color) {
        const QSize logicalSize(24, 24);
        const qreal dpr = qApp ? qApp->devicePixelRatio() : 1.0;
        QPixmap pixmap(logicalSize * dpr);
        pixmap.setDevicePixelRatio(dpr);
        pixmap.fill(Qt::transparent);

        QFile file(kIconPaths.value(name));
        if (!file.open(QIODevice::ReadOnly)) {
            return pixmap;
        }

        QString svg = QString::fromUtf8(file.readAll());
        svg.replace("currentColor", color.name(QColor::HexRgb));

        QPainter painter(&pixmap);
        painter.setRenderHint(QPainter::Antialiasing);
        QSvgRenderer renderer(svg.toUtf8());
        renderer.render(&painter, QRectF(2, 2, 20, 20));

        return pixmap;
    };

    QIcon icon;
    icon.addPixmap(drawIcon(QColor("#aeb3bd")), QIcon::Normal);
    icon.addPixmap(drawIcon(QColor("#f5f7fb")), QIcon::Selected);
    icon.addPixmap(drawIcon(QColor("#f5f7fb")), QIcon::Active);
    return icon;
}

static QListWidgetItem* addSidebarItem(QListWidget* list, const QIcon& icon,
                                        const QString& title, int pageIndex) {
    auto* item = new QListWidgetItem(icon, title);
    item->setData(Qt::UserRole, pageIndex);
    item->setSizeHint(QSize(0, 44));
    list->addItem(item);
    return item;
}

class SidebarItemDelegate final : public QStyledItemDelegate {
public:
    explicit SidebarItemDelegate(QObject* parent = nullptr)
        : QStyledItemDelegate(parent) {}

    void paint(QPainter* painter, const QStyleOptionViewItem& option,
               const QModelIndex& index) const override {
        painter->save();
        painter->setRenderHint(QPainter::Antialiasing);

        const bool isSection = index.data(Qt::UserRole).toInt() < 0;
        const bool selected = option.state & QStyle::State_Selected;
        QRectF rowRect = option.rect.adjusted(0, 3, 0, -3);

        if (isSection) {
            QFont sectionFont = option.font;
            sectionFont.setPixelSize(15);
            sectionFont.setWeight(QFont::Medium);
            painter->setFont(sectionFont);
            painter->setPen(QColor("#7a8388"));
            painter->drawText(rowRect.adjusted(30, 8, 0, 0),
                              Qt::AlignLeft | Qt::AlignVCenter,
                              index.data(Qt::DisplayRole).toString().toUpper());
            painter->restore();
            return;
        }

        QRectF bgRect(rowRect);
        bgRect = bgRect.adjusted(1, 1, -1, -1);

        if (selected) {
            painter->setPen(Qt::NoPen);
            painter->setBrush(QColor(10, 132, 255, 42));
            painter->drawRoundedRect(bgRect, 7, 7);
        }

        QRectF contentRect = bgRect.adjusted(32, 0, -16, 0);
        const int iconSize = 22;
        QRect iconRect(qRound(contentRect.left()),
                       qRound(contentRect.center().y() - iconSize / 2.0),
                       iconSize, iconSize);

        const QIcon icon = qvariant_cast<QIcon>(index.data(Qt::DecorationRole));
        const QPixmap pixmap = icon.pixmap(QSize(iconSize, iconSize),
                                           selected ? QIcon::Selected : QIcon::Normal);
        if (!pixmap.isNull()) {
            painter->drawPixmap(iconRect, pixmap);
        }

        QFont textFont = option.font;
        textFont.setPixelSize(17);
        textFont.setWeight(QFont::Medium);
        painter->setFont(textFont);
        painter->setPen(selected ? QColor("#2f7dff") : QColor("#e8edf1"));

        QRectF textRect = contentRect.adjusted(iconSize + 10, 0, 0, 0);
        QFontMetrics metrics(textFont);
        const QString title = metrics.elidedText(index.data(Qt::DisplayRole).toString(),
                                                 Qt::ElideRight,
                                                 qRound(textRect.width()));
        painter->drawText(textRect, Qt::AlignLeft | Qt::AlignVCenter, title);

        if (selected) {
            painter->setPen(QPen(QColor(94, 177, 255, 80), 1));
            painter->setBrush(Qt::NoBrush);
            painter->drawRoundedRect(bgRect.adjusted(0.5, 0.5, -0.5, -0.5), 7, 7);
        }

        painter->restore();
    }

    QSize sizeHint(const QStyleOptionViewItem& option,
                   const QModelIndex& index) const override {
        Q_UNUSED(option);
        return QSize(0, index.data(Qt::UserRole).toInt() < 0 ? 38 : 44);
    }
};

// ─── Card widget helper ─────────────────────────────────────────────────────────

static QGroupBox* makeCard(const QString& title) {
    auto* card = new QGroupBox(title);
    return card;
}

static QFrame* makePanel() {
    auto* panel = new QFrame();
    panel->setObjectName("receiverPanel");
    panel->setStyleSheet(
        "QFrame#receiverPanel { background-color: #1f1f1f; border: 1px solid #303030; border-radius: 12px; }");
    return panel;
}

static QFrame* makeMethodPanel() {
    auto* panel = new QFrame();
    panel->setObjectName("methodPanel");
    panel->setStyleSheet(
        "QFrame#methodPanel { background-color: #202020; border: 1px solid #313131; border-radius: 10px; }");
    return panel;
}

struct LocalAddressInfo {
    QString ip;
    QString interfaceName;
    QString connectionLabel;
    QString usageHint;
    int priority = 100;
};

static bool containsAny(const QString& text, const QStringList& needles) {
    for (const auto& needle : needles) {
        if (text.contains(needle, Qt::CaseInsensitive)) return true;
    }
    return false;
}

static QString classifyAddress(const QNetworkInterface& iface,
                               const QHostAddress& address,
                               QString* usageHint,
                               int* priority) {
    const QString name = iface.humanReadableName().isEmpty()
        ? iface.name()
        : iface.humanReadableName();
    const QString lowerName = name.toLower();
    const QString ip = address.toString();

    if (ip.startsWith("198.18.") ||
        ip.startsWith("198.19.") ||
        containsAny(lowerName, {"mihomo", "meta tunnel", "clash", "proxy"})) {
        *usageHint = "Proxy tunnel; usually not reachable from local senders";
        *priority = 80;
        return "Proxy";
    }
    if (containsAny(lowerName, {"tailscale", "zerotier", "wireguard", "vpn"})) {
        *usageHint = "VPN address; use from devices on the same VPN";
        *priority = 50;
        return "VPN";
    }
    if (containsAny(lowerName, {"hyper-v", "vethernet", "virtualbox", "vmware", "wsl"})) {
        *usageHint = "Virtual adapter; mainly for VMs or local containers";
        *priority = 70;
        return "Virtual";
    }
    if (containsAny(lowerName, {"usb4", "thunderbolt"})) {
        *usageHint = "Connect directly over Thunderbolt.";
        *priority = 20;
        return "Thunderbolt Bridge";
    }
    if (containsAny(lowerName, {"bluetooth"})) {
        *usageHint = "Bluetooth PAN; only use when paired over Bluetooth networking";
        *priority = 75;
        return "Bluetooth";
    }
    if (ip.startsWith("169.254.")) {
        *usageHint = "Link-local address; only works on direct or ad-hoc links";
        *priority = 60;
        return "Link-local";
    }
    if (containsAny(lowerName, {"wi-fi", "wifi", "wlan", "wireless"})) {
        *usageHint = "Connect through the Wi-Fi network.";
        *priority = 10;
        return "Wi-Fi";
    }
    if (containsAny(lowerName, {"ethernet", "以太网"})) {
        *usageHint = "Connect through a wired Ethernet network.";
        *priority = 15;
        return "Ethernet";
    }
    *usageHint = "Use when the sender is on this same network";
    *priority = 30;
    return "Network";
}

static QVector<LocalAddressInfo> localAddressInfos() {
    QVector<LocalAddressInfo> infos;
    for (const auto& iface : QNetworkInterface::allInterfaces()) {
        if (!iface.flags().testFlag(QNetworkInterface::IsUp) ||
            !iface.flags().testFlag(QNetworkInterface::IsRunning) ||
            iface.flags().testFlag(QNetworkInterface::IsLoopBack)) {
            continue;
        }

        const QString ifaceName = iface.humanReadableName().isEmpty()
            ? iface.name()
            : iface.humanReadableName();
        for (const auto& entry : iface.addressEntries()) {
            const QHostAddress ip = entry.ip();
            if (ip.protocol() != QAbstractSocket::IPv4Protocol) continue;

            LocalAddressInfo info;
            info.ip = ip.toString();
            info.interfaceName = ifaceName;
            info.connectionLabel = classifyAddress(iface, ip, &info.usageHint, &info.priority);
            if (info.ip.startsWith("169.254.") && info.priority < 60) {
                info.usageHint += "; current address is link-local";
            }
            infos.append(info);
        }
    }

    std::sort(infos.begin(), infos.end(), [](const LocalAddressInfo& a, const LocalAddressInfo& b) {
        if (a.priority != b.priority) return a.priority < b.priority;
        return a.ip < b.ip;
    });
    return infos;
}

static QVector<LocalAddressInfo> receiverAddressInfos() {
    QVector<LocalAddressInfo> result;
    for (auto info : localAddressInfos()) {
        const QString lowerInterface = info.interfaceName.toLower();
        const bool isLinkLocal = info.ip.startsWith("169.254.");
        const bool isExcluded =
            info.connectionLabel == "Virtual" ||
            info.connectionLabel == "Proxy" ||
            info.connectionLabel == "Bluetooth" ||
            info.connectionLabel == "VPN" ||
            containsAny(lowerInterface, {"tailscale", "zerotier", "wireguard", "vpn", "mihomo", "hyper-v", "vethernet"});

        if (isExcluded) continue;

        if (info.connectionLabel == "Wi-Fi" ||
            info.connectionLabel == "Ethernet" ||
            info.connectionLabel == "Thunderbolt Bridge") {
            result.append(info);
            continue;
        }

        // Windows may expose USB4/Thunderbolt peer networking as a generic Ethernet alias
        // with a link-local address, especially on localized systems.
        if (isLinkLocal && containsAny(lowerInterface, {"ethernet", "以太网"})) {
            info.connectionLabel = "Thunderbolt Bridge";
            info.usageHint = "Connect directly over Thunderbolt.";
            info.priority = 20;
            result.append(info);
        }
    }

    std::sort(result.begin(), result.end(), [](const LocalAddressInfo& a, const LocalAddressInfo& b) {
        if (a.priority != b.priority) return a.priority < b.priority;
        return a.ip < b.ip;
    });
    return result;
}

static QString formatAddressLines(const QVector<LocalAddressInfo>& infos) {
    if (infos.isEmpty()) return "No network detected";

    QStringList lines;
    for (int i = 0; i < infos.size(); ++i) {
        const auto& info = infos.at(i);
        const QString badge = (i == 0 && info.priority <= 30)
            ? QStringLiteral("Recommended - ")
            : QString();
        lines.append(QString("%1%2<br><b>%3:51820</b><br>%4<br><span style=\"color:#777;\">%5</span>")
                         .arg(badge,
                              info.connectionLabel.toHtmlEscaped(),
                              info.ip.toHtmlEscaped(),
                              info.interfaceName.toHtmlEscaped(),
                              info.usageHint.toHtmlEscaped()));
    }
    return lines.join("<br><br>");
}

static QLabel* makeAddressLabel(const QString& text, const QString& style) {
    auto* label = new QLabel(text);
    label->setStyleSheet(style);
    label->setWordWrap(true);
    return label;
}

static QFrame* makeDivider() {
    auto* line = new QFrame();
    line->setFrameShape(QFrame::HLine);
    line->setFrameShadow(QFrame::Plain);
    line->setStyleSheet("background-color: #2c2c2c; max-height: 1px;");
    return line;
}

static void clearLayout(QLayout* layout) {
    if (!layout) return;
    while (auto* item = layout->takeAt(0)) {
        if (auto* childLayout = item->layout()) clearLayout(childLayout);
        if (auto* widget = item->widget()) delete widget;
        delete item;
    }
}

static QString formatPrimaryAddress(const QVector<LocalAddressInfo>& infos) {
    if (infos.isEmpty()) return "Listening on port 51820";

    const auto& primary = infos.first();
    return QString("Listening at %1:%2").arg(primary.ip, QStringLiteral("51820"));
}

static QString formatPrimaryHint(const QVector<LocalAddressInfo>& infos) {
    if (infos.isEmpty()) return "No active network address was found.";

    const auto& primary = infos.first();
    return QString("Best manual address: %1 · %2")
                         .arg(primary.ip, primary.connectionLabel);
}

static bool receiverAutoStartEnabledPreference() {
    QSettings settings;
    if (settings.contains("receiverAutoStartEnabled")) {
        return settings.value("receiverAutoStartEnabled", false).toBool();
    }
    if (settings.contains("receiverListeningEnabled")) {
        const bool migrated = settings.value("receiverListeningEnabled", false).toBool();
        settings.setValue("receiverAutoStartEnabled", migrated);
        settings.sync();
        return migrated;
    }
    return false;
}

// ─── Constructor ────────────────────────────────────────────────────────────────

MainWindow::MainWindow(QWidget* parent)
    : QMainWindow(parent)
{
    setWindowTitle("ExtendCast");
    setMinimumSize(800, 500);

    // Crash detection: clear stale marker from previous sessions. Avoid showing a
    // startup dialog here because it has caused Qt Widgets crashes on some systems.
    QString crashMarker = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) + "/running.lock";
    if (QFile::exists(crashMarker)) {
        QFile::remove(crashMarker);
    }
    // Write crash marker (removed on clean exit)
    QDir().mkpath(QFileInfo(crashMarker).absolutePath());
    QFile marker(crashMarker);
    marker.open(QIODevice::WriteOnly);
    marker.close();

    // Create core components
    m_decoder = new VideoDecoder(this);
    m_renderer = new VideoRenderer();
    m_network = new NetworkListener(this);
    m_inputHandler = new InputHandler(this);
    m_discovery = new ServiceDiscovery(this);
    m_audioDecoder = new AudioDecoder(this);
    m_audioPlayer = new AudioPlayer(this);
    m_adbHelper = new AdbHelper(this);
    m_reconnectTimer = new QTimer(this);
    m_reconnectTimer->setInterval(3000);
    connect(m_reconnectTimer, &QTimer::timeout, this, &MainWindow::attemptAdbReconnect);

#ifdef ENABLE_SENDER
    m_sender = new SenderController(this);
    connect(m_sender, &SenderController::statusChanged, this, [this](const QString& status) {
        if (m_senderStatusLabel) m_senderStatusLabel->setText(status);
        LogManager::instance().log("Sender: " + status);
    });
    connect(m_sender, &SenderController::error, this, [this](const QString& msg) {
        m_lastSenderError = msg;
        if (m_senderStatusLabel) m_senderStatusLabel->setText("Error: " + msg);
        if (m_vddStatusLabel && (msg.contains("VDD", Qt::CaseInsensitive) ||
                                 msg.contains("driver", Qt::CaseInsensitive) ||
                                 msg.contains("virtual display", Qt::CaseInsensitive))) {
            m_vddStatusLabel->setText("Error: " + msg);
            m_vddStatusLabel->setStyleSheet("font-size: 12px; color: #d32f2f;");
        }
        LogManager::instance().log("Sender error: " + msg);
    });
    connect(m_sender, &SenderController::connected, this, [this]() {
        if (m_senderStatusLabel) m_senderStatusLabel->setText("Sending screen...");
        LogManager::instance().log("Sender: Connected and streaming");
    });
    connect(m_sender, &SenderController::stopped, this, [this]() {
        if (m_sendBtn) m_sendBtn->setEnabled(true);
        if (m_stopSendBtn) m_stopSendBtn->setEnabled(false);
        if (m_sendHostEdit) m_sendHostEdit->setEnabled(true);
    });

    // mDNS browsing for receiver discovery
    connect(m_discovery, &ServiceDiscovery::serviceFound,
            this, &MainWindow::onReceiverDiscovered);
#endif

    // Wire up core components
    m_network->setup(m_decoder, m_renderer, m_audioDecoder);

    connect(m_audioDecoder, &AudioDecoder::pcmDecoded,
            m_audioPlayer, &AudioPlayer::onPcmDecoded);

    connect(m_decoder, &VideoDecoder::frameDecoded,
            m_renderer, &VideoRenderer::onFrameDecoded);
    connect(m_decoder, &VideoDecoder::dimensionsChanged,
            m_renderer, [this](int w, int h) {
                m_inputHandler->setContentSize(QSize(w, h));
            });
    connect(m_decoder, &VideoDecoder::keyframeNeeded,
            this, [this]() {
                // Request IDR from sender on decode errors (throttled to every 2s)
                static QDateTime lastRequest;
                if (lastRequest.msecsTo(QDateTime::currentDateTime()) > 2000) {
                    LogManager::instance().log("Decoder: Requesting keyframe from sender (decode error recovery)");
                    m_network->sendInputEvent(InputEvent(InputEventType::Command, 0, 0, kIDRRequestKeyCode));
                    lastRequest = QDateTime::currentDateTime();
                }
            });

    m_inputHandler->attach(m_renderer);
    connect(m_inputHandler, &InputHandler::inputEvent,
            m_network, &NetworkListener::sendInputEvent);

    connect(m_adbHelper, &AdbHelper::statusChanged,
            this, &MainWindow::onStatusChanged);

    connect(m_network, &NetworkListener::connectionEstablished,
            this, &MainWindow::onConnectionEstablished);
    connect(m_network, &NetworkListener::connectionLost,
            this, &MainWindow::onConnectionLost);
    connect(m_network, &NetworkListener::statusChanged,
            this, &MainWindow::onStatusChanged);

    connect(m_renderer, &VideoRenderer::videoSizeChanged,
            this, &MainWindow::onVideoSizeChanged);

    // LogManager
    connect(&LogManager::instance(), &LogManager::logAdded,
            this, &MainWindow::onLogAdded);

    setupUi();

    // Match macOS: only start the receiver automatically when the persisted
    // receiverAutoStartEnabled preference is enabled.
    onReceiverListeningToggled(receiverAutoStartEnabledPreference());
#ifdef ENABLE_SENDER
    m_discovery->startBrowsing();
#endif
    LogManager::instance().log(QString("ExtendCast started — receiver listening %1")
                                   .arg(m_receiverListening ? "enabled" : "disabled"));
#ifdef _WIN32
    QByteArray fwStatus = qgetenv("EXTENDCAST_FW_STATUS");
    if (fwStatus == "ok") {
        LogManager::instance().log("Firewall: Rules added (mDNS + TCP)");
    } else if (fwStatus == "failed") {
        LogManager::instance().log("Firewall: Rules NOT added — run as Administrator once for auto-discovery");
    } else {
        LogManager::instance().log("Firewall: Rules already exist");
    }
#endif

    // Default window size (landscape 16:9, 70% screen)
    QScreen* screen = QApplication::primaryScreen();
    if (screen) {
        QRect available = screen->availableGeometry();
        int w = static_cast<int>(available.width() * 0.7);
        int h = w * 9 / 16;
        int x = available.x() + (available.width() - w) / 2;
        int y = available.y() + (available.height() - h) / 2;
        setGeometry(x, y, w, h);
    }
}

MainWindow::~MainWindow() {
    m_discovery->stopAdvertising();
    delete m_videoWindow;
    m_videoWindow = nullptr;
    delete m_renderer;
    m_renderer = nullptr;
    // Clean exit — remove crash marker
    QString crashMarker = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) + "/running.lock";
    QFile::remove(crashMarker);
}

// ─── UI Setup ───────────────────────────────────────────────────────────────────

void MainWindow::setupUi() {
    setStyleSheet(kDarkStylesheet);

    m_splitter = new QSplitter(Qt::Horizontal, this);
    m_splitter->setHandleWidth(0);
    setCentralWidget(m_splitter);

    auto* sidebarFrame = new QFrame();
    sidebarFrame->setObjectName("sidebarFrame");
    sidebarFrame->setFixedWidth(252);
    sidebarFrame->setStyleSheet(
        "QFrame#sidebarFrame { background-color: #202020; border: none; }");

    auto* sidebarLayout = new QHBoxLayout(sidebarFrame);
    sidebarLayout->setContentsMargins(0, 0, 0, 0);
    sidebarLayout->setSpacing(0);

    // Sidebar
    m_sidebarList = new QListWidget();
    m_sidebarList->setFixedWidth(248);
    m_sidebarList->setIconSize(QSize(24, 24));
    m_sidebarList->setSpacing(1);
    m_sidebarList->setFocusPolicy(Qt::NoFocus);
    m_sidebarList->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    m_sidebarList->setItemDelegate(new SidebarItemDelegate(m_sidebarList));
    sidebarLayout->addWidget(m_sidebarList);

    auto* sidebarShadowStrip = new QFrame();
    sidebarShadowStrip->setFixedWidth(4);
    sidebarShadowStrip->setStyleSheet(
        "QFrame { background: qlineargradient(x1: 0, y1: 0, x2: 1, y2: 0, "
        "stop: 0 rgba(0, 0, 0, 16), stop: 1 rgba(0, 0, 0, 0)); border: none; }");
    sidebarLayout->addWidget(sidebarShadowStrip);

    // Detail stack
    m_stack = new QStackedWidget();

    // Build pages — order matters for page indices
    setupReceivePage();
    setupSettingsPage();
    setupLogsPage();

    // Build sidebar
    setupSidebar();

    // Assemble splitter
    m_splitter->addWidget(sidebarFrame);
    m_splitter->addWidget(m_stack);
    m_splitter->setStretchFactor(0, 0);
    m_splitter->setStretchFactor(1, 1);
    m_splitter->setCollapsible(0, false);
    m_splitter->setCollapsible(1, false);

    // Connect sidebar selection
    connect(m_sidebarList, &QListWidget::currentRowChanged,
            this, &MainWindow::onSidebarSelectionChanged);

    // Select Receiver by default
    selectSidebarItem(m_pageReceive);
}

void MainWindow::setupSidebar() {
    addSidebarItem(m_sidebarList, makeSidebarIcon("receiver"), "Receiver", m_pageReceive);
    addSidebarItem(m_sidebarList, makeSidebarIcon("settings"), "Settings", m_pageSettings);
    addSidebarItem(m_sidebarList, makeSidebarIcon("logs"), "Logs", m_pageLogs);
}

// ─── Overview Page ──────────────────────────────────────────────────────────────

void MainWindow::setupOverviewPage() {
    auto* page = new QWidget();
    auto* scroll = new QScrollArea();
    scroll->setWidget(page);
    scroll->setWidgetResizable(true);

    auto* layout = new QVBoxLayout(page);
    layout->setAlignment(Qt::AlignCenter);
    layout->setContentsMargins(40, 40, 40, 40);
    layout->setSpacing(12);

    // App icon
    auto* iconLabel = new QLabel();
    QPixmap appIcon(":/appicon.png");
    if (!appIcon.isNull()) {
        iconLabel->setPixmap(appIcon.scaled(80, 80, Qt::KeepAspectRatio, Qt::SmoothTransformation));
    }
    iconLabel->setAlignment(Qt::AlignCenter);
    layout->addWidget(iconLabel);

    // Title
    auto* title = new QLabel("ExtendCast");
    title->setStyleSheet("font-size: 28px; font-weight: bold; color: white;");
    title->setAlignment(Qt::AlignCenter);
    layout->addWidget(title);

    auto* subtitle = new QLabel("Turn any device into a wireless extended display");
    subtitle->setStyleSheet("font-size: 14px; color: #888;");
    subtitle->setAlignment(Qt::AlignCenter);
    layout->addWidget(subtitle);

    layout->addSpacing(24);

    // Getting started steps
    auto* stepsCard = makeCard("Getting Started");
    auto* stepsLayout = new QVBoxLayout(stepsCard);
    stepsLayout->setSpacing(16);

    auto addStep = [&](int num, const QString& title, const QString& desc) {
        auto* row = new QHBoxLayout();
        row->setSpacing(12);

        auto* numLabel = new QLabel(QString::number(num));
        numLabel->setFixedSize(28, 28);
        numLabel->setAlignment(Qt::AlignCenter);
        numLabel->setStyleSheet(
            "background-color: #0078D4; color: white; font-weight: bold; "
            "font-size: 13px; border-radius: 14px;");
        row->addWidget(numLabel);

        auto* textLayout = new QVBoxLayout();
        textLayout->setSpacing(2);
        auto* titleLabel = new QLabel(title);
        titleLabel->setStyleSheet("font-size: 14px; font-weight: bold; color: #e0e0e0;");
        textLayout->addWidget(titleLabel);
        auto* descLabel = new QLabel(desc);
        descLabel->setStyleSheet("font-size: 12px; color: #888;");
        descLabel->setWordWrap(true);
        textLayout->addWidget(descLabel);
        row->addLayout(textLayout, 1);

        stepsLayout->addLayout(row);
    };

    addStep(1, "Download the Receiver",
            "Install an ExtendCast-compatible receiver on your iPad, Android, Windows, Linux, or Mac.");
    addStep(2, "Connect to the Same Network",
            "Make sure both devices are on the same Wi-Fi network.");
    addStep(3, "Open the Receiver App",
            "Your device will appear automatically, or use Manual IP to connect.");

    layout->addWidget(stepsCard);

    layout->addSpacing(12);

    // Status
    m_overviewStatusLabel = new QLabel("Searching for devices on your network...");
    m_overviewStatusLabel->setStyleSheet("font-size: 12px; color: #888;");
    m_overviewStatusLabel->setAlignment(Qt::AlignCenter);
    layout->addWidget(m_overviewStatusLabel);

    // Local IP
    m_overviewIpLabel = new QLabel();
    m_overviewIpLabel->setStyleSheet("font-size: 12px; color: #666;");
    m_overviewIpLabel->setAlignment(Qt::AlignCenter);
    layout->addWidget(m_overviewIpLabel);

    layout->addStretch();

    m_pageOverview = m_stack->addWidget(scroll);
    updateLocalIpDisplay();
}

// ─── Send Screen Page (ENABLE_SENDER) ───────────────────────────────────────────

#ifdef ENABLE_SENDER
void MainWindow::setupSendPage() {
    auto* page = new QWidget();
    auto* scroll = new QScrollArea();
    scroll->setWidget(page);
    scroll->setWidgetResizable(true);

    auto* layout = new QVBoxLayout(page);
    layout->setContentsMargins(48, 34, 48, 34);
    layout->setSpacing(20);

    auto* pageTitle = new QLabel("Send Screen");
    pageTitle->setStyleSheet("font-size: 22px; font-weight: bold; color: white;");
    layout->addWidget(pageTitle);

    auto* pageDesc = new QLabel("Stream your screen to an ExtendCast receiver on another device.");
    pageDesc->setStyleSheet("font-size: 13px; color: #888;");
    pageDesc->setWordWrap(true);
    layout->addWidget(pageDesc);

    layout->addSpacing(8);

    // ─── Virtual Display card ──────────────────────────────────────────
    auto* vddCard = makeCard("Virtual Display (Extend Screen)");
    auto* vddLayout = new QVBoxLayout(vddCard);
    vddLayout->setSpacing(10);

    // VDD status
    m_vddStatusLabel = new QLabel();
    bool vddInstalled = m_sender && m_sender->vdd() && m_sender->vdd()->isVddInstalled();
    if (vddInstalled) {
        m_vddStatusLabel->setText("Virtual Display Driver detected");
        m_vddStatusLabel->setStyleSheet("font-size: 13px; color: #4caf50;");
    } else {
        m_vddStatusLabel->setText(
            "Virtual Display Driver not found — install from "
            "github.com/itsmikethetech/Virtual-Display-Driver");
        m_vddStatusLabel->setStyleSheet("font-size: 12px; color: #ff9800;");
    }
    m_vddStatusLabel->setWordWrap(true);
    vddLayout->addWidget(m_vddStatusLabel);

    // Re-check button (shown when VDD not detected)
    m_recheckVddBtn = new QPushButton("Re-check VDD Installation");
    m_recheckVddBtn->setVisible(!vddInstalled);
    m_recheckVddBtn->setStyleSheet(
        "QPushButton { background-color: #333; color: #4da6ff; padding: 6px 14px; "
        "border-radius: 5px; font-size: 12px; border: 1px solid #4da6ff; }"
        "QPushButton:hover { background-color: #1a3a5c; }");
    connect(m_recheckVddBtn, &QPushButton::clicked, this, [this]() {
        if (!m_sender || !m_sender->vdd()) return;
        m_sender->vdd()->refreshInstallStatus();
        bool found = m_sender->vdd()->isVddInstalled();
        if (found) {
            m_vddStatusLabel->setText("Virtual Display Driver detected");
            m_vddStatusLabel->setStyleSheet("font-size: 13px; color: #4caf50;");
            m_recheckVddBtn->setVisible(false);
            m_vddResolutionCombo->setEnabled(true);
            m_createVddBtn->setEnabled(true);
        } else {
            m_vddStatusLabel->setText(
                "Still not detected — make sure VDD is installed and try restarting the app");
            m_vddStatusLabel->setStyleSheet("font-size: 12px; color: #ff9800;");
        }
    });
    vddLayout->addWidget(m_recheckVddBtn);

    // Resolution picker
    auto* resRow = new QHBoxLayout();
    auto* resLabel = new QLabel("Resolution:");
    resLabel->setStyleSheet("font-size: 13px; color: #ccc;");
    resRow->addWidget(resLabel);

    m_vddResolutionCombo = new QComboBox();
    m_vddResolutionCombo->addItem("1920 x 1080 @ 60Hz", QVariant::fromValue(QSize(1920, 1080)));
    m_vddResolutionCombo->addItem("2560 x 1440 @ 60Hz", QVariant::fromValue(QSize(2560, 1440)));
    m_vddResolutionCombo->addItem("3840 x 2160 @ 60Hz", QVariant::fromValue(QSize(3840, 2160)));
    m_vddResolutionCombo->addItem("1920 x 1200 @ 60Hz", QVariant::fromValue(QSize(1920, 1200)));
    m_vddResolutionCombo->addItem("2560 x 1600 @ 60Hz", QVariant::fromValue(QSize(2560, 1600)));
    m_vddResolutionCombo->addItem("1280 x 720 @ 60Hz",  QVariant::fromValue(QSize(1280, 720)));
    m_vddResolutionCombo->addItem("1024 x 768 @ 60Hz",  QVariant::fromValue(QSize(1024, 768)));
    m_vddResolutionCombo->setFixedWidth(240);
    m_vddResolutionCombo->setEnabled(vddInstalled);
    resRow->addWidget(m_vddResolutionCombo);
    resRow->addStretch();
    vddLayout->addLayout(resRow);

    // Create / Remove buttons
    auto* vddBtnRow = new QHBoxLayout();
    vddBtnRow->setSpacing(10);

    m_createVddBtn = new QPushButton("Create Virtual Display");
    m_createVddBtn->setEnabled(vddInstalled);
    m_createVddBtn->setStyleSheet(
        "QPushButton { background-color: #4caf50; color: white; font-weight: bold; "
        "padding: 8px 18px; border-radius: 6px; border: none; }"
        "QPushButton:hover { background-color: #66bb6a; }"
        "QPushButton:disabled { background-color: #2a2a2a; color: #666; }");
    connect(m_createVddBtn, &QPushButton::clicked, this, &MainWindow::onCreateVirtualDisplay);
    vddBtnRow->addWidget(m_createVddBtn);

    m_removeVddBtn = new QPushButton("Remove");
    m_removeVddBtn->setEnabled(false);
    m_removeVddBtn->setStyleSheet(
        "QPushButton { background-color: #333; color: #ccc; padding: 8px 18px; "
        "border-radius: 6px; font-size: 13px; border: 1px solid #555; }"
        "QPushButton:hover { background-color: #444; }"
        "QPushButton:disabled { background-color: #2a2a2a; color: #666; }");
    connect(m_removeVddBtn, &QPushButton::clicked, this, &MainWindow::onRemoveVirtualDisplay);
    vddBtnRow->addWidget(m_removeVddBtn);

    vddBtnRow->addStretch();
    vddLayout->addLayout(vddBtnRow);

    layout->addWidget(vddCard);

    // ─── Monitor Selection card ────────────────────────────────────────
    auto* monCard = makeCard("Monitor to Stream");
    auto* monLayout = new QVBoxLayout(monCard);
    monLayout->setSpacing(10);

    auto* monDesc = new QLabel("Select which display to capture and stream:");
    monDesc->setStyleSheet("font-size: 12px; color: #888;");
    monLayout->addWidget(monDesc);

    auto* monRow = new QHBoxLayout();
    m_monitorCombo = new QComboBox();
    m_monitorCombo->setMinimumWidth(300);
    connect(m_monitorCombo, QOverload<int>::of(&QComboBox::currentIndexChanged),
            this, &MainWindow::onMonitorSelected);
    monRow->addWidget(m_monitorCombo);

    auto* refreshBtn = new QPushButton("Refresh");
    refreshBtn->setStyleSheet(
        "QPushButton { background-color: #333; color: #ccc; padding: 6px 14px; "
        "border-radius: 6px; font-size: 12px; border: 1px solid #555; }"
        "QPushButton:hover { background-color: #444; }");
    connect(refreshBtn, &QPushButton::clicked, this, &MainWindow::onRefreshMonitors);
    monRow->addWidget(refreshBtn);

    monRow->addStretch();
    monLayout->addLayout(monRow);

    layout->addWidget(monCard);

    // Populate monitor list
    onRefreshMonitors();

    // Enable Remove button if virtual displays already exist from previous sessions
    if (m_removeVddBtn && m_monitorCombo) {
        for (int i = 0; i < m_monitorCombo->count(); i++) {
            QVariantMap data = m_monitorCombo->itemData(i).toMap();
            if (data.value("virtual", false).toBool()) {
                m_removeVddBtn->setEnabled(true);
                break;
            }
        }
    }

    // ─── Connection card ───────────────────────────────────────────────
    auto* connCard = makeCard("Target Receiver");
    auto* connLayout = new QVBoxLayout(connCard);
    connLayout->setSpacing(12);

    // Discovered receivers dropdown
    auto* discLabel = new QLabel("Discovered Receivers:");
    discLabel->setStyleSheet("font-size: 13px; color: #ccc;");
    connLayout->addWidget(discLabel);

    m_receiverCombo = new QComboBox();
    m_receiverCombo->addItem("Searching for receivers...");
    m_receiverCombo->setEnabled(false);
    connect(m_receiverCombo, QOverload<int>::of(&QComboBox::currentIndexChanged),
            this, &MainWindow::onReceiverSelected);
    connLayout->addWidget(m_receiverCombo);

    connLayout->addSpacing(4);

    auto* orLabel = new QLabel(QString::fromUtf8("\xe2\x80\x94 or enter IP manually \xe2\x80\x94"));
    orLabel->setStyleSheet("font-size: 11px; color: #666;");
    orLabel->setAlignment(Qt::AlignCenter);
    connLayout->addWidget(orLabel);

    auto* hostRow = new QHBoxLayout();
    auto* hostLabel = new QLabel("Receiver IP:");
    hostLabel->setStyleSheet("font-size: 13px; color: #ccc;");
    hostRow->addWidget(hostLabel);
    m_sendHostEdit = new QLineEdit();
    m_sendHostEdit->setPlaceholderText("e.g. 192.168.1.50");
    m_sendHostEdit->setFixedWidth(200);
    hostRow->addWidget(m_sendHostEdit);
    hostRow->addStretch();
    connLayout->addLayout(hostRow);

    layout->addWidget(connCard);

    // ─── Quality card ──────────────────────────────────────────────────
    auto* qualCard = makeCard("Stream Quality");
    auto* qualLayout = new QVBoxLayout(qualCard);
    qualLayout->setSpacing(10);

    auto* fpsRow = new QHBoxLayout();
    auto* fpsLabel = new QLabel("Frame Rate:");
    fpsLabel->setStyleSheet("font-size: 13px; color: #ccc;");
    fpsRow->addWidget(fpsLabel);
    m_fpsSpinBox = new QSpinBox();
    m_fpsSpinBox->setRange(15, 120);
    m_fpsSpinBox->setValue(60);
    m_fpsSpinBox->setSuffix(" FPS");
    m_fpsSpinBox->setFixedWidth(100);
    fpsRow->addWidget(m_fpsSpinBox);
    fpsRow->addStretch();
    qualLayout->addLayout(fpsRow);

    auto* brRow = new QHBoxLayout();
    auto* brLabel = new QLabel("Bitrate:");
    brLabel->setStyleSheet("font-size: 13px; color: #ccc;");
    brRow->addWidget(brLabel);
    m_bitrateSpinBox = new QSpinBox();
    m_bitrateSpinBox->setRange(2, 100);
    m_bitrateSpinBox->setValue(20);
    m_bitrateSpinBox->setSuffix(" Mbps");
    m_bitrateSpinBox->setFixedWidth(100);
    brRow->addWidget(m_bitrateSpinBox);
    brRow->addStretch();
    qualLayout->addLayout(brRow);

    layout->addWidget(qualCard);

    // ─── Action buttons ────────────────────────────────────────────────
    auto* btnRow = new QHBoxLayout();
    btnRow->setSpacing(12);

    m_sendBtn = new QPushButton("Send Screen");
    m_sendBtn->setStyleSheet(
        "QPushButton { background-color: #0078D4; color: white; font-weight: bold; "
        "font-size: 14px; padding: 10px 24px; border-radius: 8px; border: none; }"
        "QPushButton:hover { background-color: #1a8ae8; }"
        "QPushButton:disabled { background-color: #2a2a2a; color: #666; }");
    connect(m_sendBtn, &QPushButton::clicked, this, &MainWindow::onSendScreenClicked);
    btnRow->addWidget(m_sendBtn);

    m_stopSendBtn = new QPushButton("Stop");
    m_stopSendBtn->setEnabled(false);
    m_stopSendBtn->setStyleSheet(
        "QPushButton { background-color: #d32f2f; color: white; font-weight: bold; "
        "font-size: 14px; padding: 10px 24px; border-radius: 8px; border: none; }"
        "QPushButton:hover { background-color: #e53935; }"
        "QPushButton:disabled { background-color: #2a2a2a; color: #666; }");
    connect(m_stopSendBtn, &QPushButton::clicked, this, &MainWindow::onStopSendingClicked);
    btnRow->addWidget(m_stopSendBtn);

    btnRow->addStretch();
    layout->addLayout(btnRow);

    // Status
    m_senderStatusLabel = new QLabel("Select a monitor and receiver to start streaming");
    m_senderStatusLabel->setStyleSheet("font-size: 12px; color: #888;");
    m_senderStatusLabel->setWordWrap(true);
    layout->addWidget(m_senderStatusLabel);

    layout->addStretch();

    m_pageSend = m_stack->addWidget(scroll);
}
#endif

// ─── Receive Page ───────────────────────────────────────────────────────────────

void MainWindow::setupReceivePage() {
    auto* page = new QWidget();
    auto* scroll = new QScrollArea();
    scroll->setWidget(page);
    scroll->setWidgetResizable(true);

    auto* layout = new QVBoxLayout(page);
    layout->setContentsMargins(48, 34, 48, 34);
    layout->setSpacing(18);
    layout->setAlignment(Qt::AlignTop | Qt::AlignHCenter);

    auto* pageTitle = new QLabel("Receiver");
    pageTitle->setMaximumWidth(680);
    pageTitle->setStyleSheet("font-size: 26px; font-weight: bold; color: white;");
    layout->addWidget(pageTitle);

    auto* statusTitle = new QLabel("Status");
    statusTitle->setMaximumWidth(680);
    statusTitle->setStyleSheet("font-size: 14px; font-weight: 700; color: #a7a7a7; padding-top: 14px;");
    layout->addWidget(statusTitle);

    auto* statusCard = makePanel();
    statusCard->setMaximumWidth(680);
    auto* statusLayout = new QVBoxLayout(statusCard);
    statusLayout->setContentsMargins(24, 22, 24, 22);

    auto* statusRow = new QHBoxLayout();
    statusRow->setSpacing(12);

    m_recvStatusDot = new QLabel();
    m_recvStatusDot->setFixedSize(10, 10);
    m_recvStatusDot->setStyleSheet("background-color: #34c759; border-radius: 5px;");
    statusRow->addWidget(m_recvStatusDot);

    auto* statusTextLayout = new QVBoxLayout();
    statusTextLayout->setSpacing(3);

    m_recvStatusLabel = new QLabel("Listening on port 51820");
    m_recvStatusLabel->setStyleSheet("font-size: 13px; font-weight: bold; color: #d8d8d8;");
    statusTextLayout->addWidget(m_recvStatusLabel);

    m_recvStatusDetailLabel = new QLabel();
    m_recvStatusDetailLabel->setWordWrap(true);
    m_recvStatusDetailLabel->setStyleSheet("font-size: 12px; color: #9a9a9a;");
    m_recvStatusDetailLabel->hide();
    statusTextLayout->addWidget(m_recvStatusDetailLabel);

    statusRow->addLayout(statusTextLayout, 1);
    statusRow->addStretch();

    m_receiverListenToggle = new QPushButton("On");
    m_receiverListenToggle->setCheckable(true);
    m_receiverListenToggle->setChecked(true);
    m_receiverListenToggle->setCursor(Qt::PointingHandCursor);
    m_receiverListenToggle->setFixedSize(74, 32);
    m_receiverListenToggle->setStyleSheet(
        "QPushButton { background-color: #2b2b2b; border: 1px solid #3a3a3a; border-radius: 16px; "
        "color: #bdbdbd; font-size: 12px; font-weight: 700; padding: 0 12px; text-align: center; }"
        "QPushButton:checked { background-color: #248a46; border-color: #2fbf62; color: white; }"
        "QPushButton:hover { border-color: #555555; }");
    connect(m_receiverListenToggle, &QPushButton::toggled,
            this, &MainWindow::onReceiverListeningToggled);
    statusRow->addWidget(m_receiverListenToggle);
    statusLayout->addLayout(statusRow);

    layout->addWidget(statusCard);

    m_receiverConnectionsTitle = new QLabel("Available Connections");
    m_receiverConnectionsTitle->setMaximumWidth(680);
    m_receiverConnectionsTitle->setStyleSheet("font-size: 14px; font-weight: 700; color: #a7a7a7; padding-top: 8px;");
    layout->addWidget(m_receiverConnectionsTitle);

    m_receiverConnectionsCard = makePanel();
    m_receiverConnectionsCard->setMaximumWidth(680);
    auto* listenLayout = new QVBoxLayout(m_receiverConnectionsCard);
    listenLayout->setContentsMargins(24, 24, 24, 24);
    listenLayout->setSpacing(0);

    m_recvIpLabel = new QLabel();
    m_recvIpLabel->setTextFormat(Qt::PlainText);
    m_recvIpLabel->setWordWrap(true);
    m_recvIpLabel->setStyleSheet(
        "font-size: 13px; color: #8f8f8f; padding: 18px 0;");
    listenLayout->addWidget(m_recvIpLabel);

    m_recvAddressListLayout = new QVBoxLayout();
    m_recvAddressListLayout->setContentsMargins(0, 0, 0, 0);
    m_recvAddressListLayout->setSpacing(10);
    listenLayout->addLayout(m_recvAddressListLayout);

    layout->addWidget(m_receiverConnectionsCard);

    auto* settingsTitle = new QLabel("Settings");
    settingsTitle->setMaximumWidth(680);
    settingsTitle->setStyleSheet("font-size: 14px; font-weight: 700; color: #a7a7a7; padding-top: 8px;");
    layout->addWidget(settingsTitle);

    auto* autoStartCard = makePanel();
    autoStartCard->setMaximumWidth(680);
    auto* autoStartRow = new QHBoxLayout(autoStartCard);
    autoStartRow->setContentsMargins(24, 18, 24, 18);
    autoStartRow->setSpacing(14);

    auto* autoStartText = new QVBoxLayout();
    autoStartText->setSpacing(4);
    auto* autoStartTitle = new QLabel("Start Listening at Launch");
    autoStartTitle->setStyleSheet("font-size: 13px; font-weight: 700; color: #f2f2f2;");
    autoStartText->addWidget(autoStartTitle);
    auto* autoStartDesc = new QLabel("Automatically start receiver listening when ExtendCast opens.");
    autoStartDesc->setWordWrap(true);
    autoStartDesc->setStyleSheet("font-size: 12px; color: #9a9a9a;");
    autoStartText->addWidget(autoStartDesc);
    autoStartRow->addLayout(autoStartText, 1);

    m_receiverAutoStartToggle = new QPushButton(receiverAutoStartEnabledPreference() ? "On" : "Off");
    m_receiverAutoStartToggle->setCheckable(true);
    m_receiverAutoStartToggle->setChecked(receiverAutoStartEnabledPreference());
    m_receiverAutoStartToggle->setCursor(Qt::PointingHandCursor);
    m_receiverAutoStartToggle->setFixedSize(74, 32);
    m_receiverAutoStartToggle->setStyleSheet(
        "QPushButton { background-color: #2b2b2b; border: 1px solid #3a3a3a; border-radius: 16px; "
        "color: #bdbdbd; font-size: 12px; font-weight: 700; padding: 0 12px; text-align: center; }"
        "QPushButton:checked { background-color: #248a46; border-color: #2fbf62; color: white; }"
        "QPushButton:hover { border-color: #555555; }");
    connect(m_receiverAutoStartToggle, &QPushButton::toggled,
            this, &MainWindow::onReceiverAutoStartToggled);
    autoStartRow->addWidget(m_receiverAutoStartToggle, 0, Qt::AlignVCenter);
    layout->addWidget(autoStartCard);

    layout->addStretch();

    m_pageReceive = m_stack->addWidget(scroll);
    updateLocalIpDisplay();
}

// ─── Settings Page ──────────────────────────────────────────────────────────────

void MainWindow::setupSettingsPage() {
    auto* page = new QWidget();
    auto* scroll = new QScrollArea();
    scroll->setWidget(page);
    scroll->setWidgetResizable(true);

    auto* layout = new QVBoxLayout(page);
    layout->setContentsMargins(40, 30, 40, 30);
    layout->setSpacing(16);

    auto* pageTitle = new QLabel("Settings");
    pageTitle->setStyleSheet("font-size: 22px; font-weight: bold; color: white;");
    layout->addWidget(pageTitle);

    // About card
    auto* aboutCard = makeCard("About");
    auto* aboutLayout = new QVBoxLayout(aboutCard);
    aboutLayout->setSpacing(8);

    m_versionLabel = new QLabel(QString("ExtendCast v%1")
        .arg(QApplication::applicationVersion()));
    m_versionLabel->setStyleSheet("font-size: 14px; font-weight: bold; color: #e0e0e0;");
    aboutLayout->addWidget(m_versionLabel);

    auto* descLabel = new QLabel(
        "Turn any device into a wireless extended display. "
        "Works with iPad, Android, Windows, Linux, and Mac receivers.");
    descLabel->setStyleSheet("font-size: 12px; color: #888;");
    descLabel->setWordWrap(true);
    aboutLayout->addWidget(descLabel);

    layout->addWidget(aboutCard);

    // Connection card
    auto* connCard = makeCard("Connection");
    auto* connLayout = new QVBoxLayout(connCard);
    connLayout->setSpacing(10);

    auto* portInfo = new QLabel("Listening on port 51820 (TCP)");
    portInfo->setStyleSheet("font-size: 13px; color: #ccc;");
    connLayout->addWidget(portInfo);

    auto* ipInfo = new QLabel(formatAddressLines(localAddressInfos()));
    ipInfo->setStyleSheet("font-size: 12px; color: #888;");
    ipInfo->setTextFormat(Qt::RichText);
    ipInfo->setWordWrap(true);
    connLayout->addWidget(ipInfo);

    layout->addWidget(connCard);

    // Changelog card
    auto* changeCard = makeCard("What's New");
    auto* changeLayout = new QVBoxLayout(changeCard);
    changeLayout->setSpacing(10);

    struct ChangeEntry {
        QString version, date;
        QStringList items;
    };
    QVector<ChangeEntry> changelog = {
        {"v8", "2026-03-30", {
            "Unified sender + receiver in a single app",
            "Apple Music-style sidebar with tinted selection",
            "Windows sender with sidebar UI",
            "In-app update checker via GitHub Releases",
        }},
        {"v7", "2026-03-23", {
            "Android ADB wireless auto-reconnect",
            "Orientation fix for rotated displays",
        }},
        {"v6", "2026-03-19", {
            "Windows sender Phase 1",
            "DMG signing improvements",
        }},
    };

    for (const auto& entry : changelog) {
        auto* verLabel = new QLabel(QString("%1  —  %2").arg(entry.version, entry.date));
        verLabel->setStyleSheet("font-size: 13px; font-weight: bold; color: #ccc;");
        changeLayout->addWidget(verLabel);

        for (const auto& item : entry.items) {
            auto* bulletLabel = new QLabel(QString("  \xE2\x80\xA2  %1").arg(item));
            bulletLabel->setStyleSheet("font-size: 11px; color: #888;");
            changeLayout->addWidget(bulletLabel);
        }

        changeLayout->addSpacing(4);
    }

    layout->addWidget(changeCard);

    layout->addStretch();

    m_pageSettings = m_stack->addWidget(scroll);
}

// ─── Logs Page ──────────────────────────────────────────────────────────────────

void MainWindow::setupLogsPage() {
    auto* page = new QWidget();
    auto* layout = new QVBoxLayout(page);
    layout->setContentsMargins(20, 16, 20, 16);
    layout->setSpacing(10);

    // Title row with buttons
    auto* titleRow = new QHBoxLayout();

    auto* pageTitle = new QLabel("Logs");
    pageTitle->setStyleSheet("font-size: 22px; font-weight: bold; color: white;");
    titleRow->addWidget(pageTitle);

    titleRow->addStretch();

    auto* reportBtn = new QPushButton("Report Issue");
    reportBtn->setStyleSheet(
        "QPushButton { background-color: #333; color: #ccc; padding: 6px 14px; "
        "border-radius: 6px; font-size: 12px; border: 1px solid #555; }"
        "QPushButton:hover { background-color: #444; }");
    connect(reportBtn, &QPushButton::clicked, this, &MainWindow::onReportIssue);
    titleRow->addWidget(reportBtn);

    auto* copyBtn = new QPushButton("Copy");
    copyBtn->setStyleSheet(
        "QPushButton { background-color: #333; color: #ccc; padding: 6px 14px; "
        "border-radius: 6px; font-size: 12px; border: 1px solid #555; }"
        "QPushButton:hover { background-color: #444; }");
    connect(copyBtn, &QPushButton::clicked, this, &MainWindow::onCopyLogs);
    titleRow->addWidget(copyBtn);

    auto* clearBtn = new QPushButton("Clear");
    clearBtn->setStyleSheet(
        "QPushButton { background-color: #333; color: #ccc; padding: 6px 14px; "
        "border-radius: 6px; font-size: 12px; border: 1px solid #555; }"
        "QPushButton:hover { background-color: #444; }");
    connect(clearBtn, &QPushButton::clicked, this, &MainWindow::onClearLogs);
    titleRow->addWidget(clearBtn);

    layout->addLayout(titleRow);

    // Log viewer
    m_logViewer = new QTextEdit();
    m_logViewer->setReadOnly(true);
    m_logViewer->setPlaceholderText("No log entries yet...");
    layout->addWidget(m_logViewer);

    m_pageLogs = m_stack->addWidget(page);
}

// ─── Sidebar Selection ──────────────────────────────────────────────────────────

void MainWindow::onSidebarSelectionChanged(int row) {
    auto* item = m_sidebarList->item(row);
    if (!item) return;

    int page = item->data(Qt::UserRole).toInt();
    if (page < 0) {
        // Section header — skip to next selectable item
        if (row + 1 < m_sidebarList->count()) {
            m_sidebarList->setCurrentRow(row + 1);
        }
        return;
    }

    m_stack->setCurrentIndex(page);
}

void MainWindow::selectSidebarItem(int pageIndex) {
    for (int i = 0; i < m_sidebarList->count(); i++) {
        auto* item = m_sidebarList->item(i);
        if (item && item->data(Qt::UserRole).toInt() == pageIndex) {
            m_sidebarList->setCurrentRow(i);
            return;
        }
    }
}

// ─── Connection Handlers ────────────────────────────────────────────────────────

void MainWindow::onConnectClicked() {
    bool ok = false;
    uint16_t port = m_portEdit->text().toUShort(&ok);
    if (!ok) port = 51820;

    m_network->connectTo(m_hostEdit->text(), port);
    m_connectBtn->setEnabled(false);
    m_recvStatusLabel->setText("Connecting...");
    m_recvStatusLabel->setStyleSheet("font-size: 15px; font-weight: bold; color: #4da6ff;");
    LogManager::instance().log("Connecting to " + m_hostEdit->text() + ":" + QString::number(port));
}

void MainWindow::onAdbConnectClicked() {
    m_adbBtn->setEnabled(false);
    m_adbBtn->setText("Setting up ADB...");
    m_recvStatusLabel->setText("Looking for Android device...");
    m_recvStatusLabel->setStyleSheet("font-size: 15px; font-weight: bold; color: #4da6ff;");
    LogManager::instance().log("Starting ADB setup...");

    std::thread([this]() {
        bool success = m_adbHelper->setupForward(51820);
        uint16_t localPort = m_adbHelper->lastLocalPort();
        QMetaObject::invokeMethod(this, [this, success, localPort]() {
            m_adbBtn->setEnabled(true);
            m_adbBtn->setText("Connect to Android (ADB)");

            if (success) {
                m_recvStatusLabel->setText("ADB tunnel ready — connecting...");
                LogManager::instance().log(QString("ADB tunnel established, connecting to localhost:%1...").arg(localPort));
                m_network->connectTo("localhost", localPort);
            }
        });
    }).detach();
}

void MainWindow::onConnectionEstablished() {
    if (m_connectBtn) {
        m_connectBtn->setEnabled(true);
    }
    m_reconnectTimer->stop();
    LogManager::instance().log("Connection established — streaming video");

    // Open the video in a separate window
    if (!m_videoWindow) {
        m_videoWindow = new VideoWindow(m_renderer, m_inputHandler, this);
        connect(m_videoWindow, &VideoWindow::windowClosed, this, [this]() {
            LogManager::instance().log("Video window closed by user");
        });
    }
    if (m_videoWindow) {
        m_videoWindow->showForVideo();
    }

    QTimer::singleShot(200, this, [this]() {
        if (!m_network->clients().isEmpty()) {
            LogManager::instance().log("Receiver: Requesting keyframe for new connection");
            m_network->sendInputEvent(InputEvent(InputEventType::Command, 0, 0, kIDRRequestKeyCode));
        }
    });

    m_recvStatusLabel->setText("Connected — video window opened");
    m_recvStatusLabel->setStyleSheet("font-size: 15px; font-weight: bold; color: #4caf50;");

    // Reset reconnect counter only after video actually starts flowing
    // (delayed so brief connect-then-disconnect during reconnect doesn't reset it)
    QTimer::singleShot(3000, this, [this]() {
        // Only reset if we're still connected (not in a reconnect cycle)
        if (!m_network->clients().isEmpty()) {
            m_reconnectAttempts = 0;
        }
    });

    if (m_adbHelper->wasAdbConnection() && !m_wirelessAdbEnabled) {
        // Delay wireless ADB by 5 seconds — adb tcpip 5555 temporarily kills
        // the USB connection (and our forward tunnel). Give the stream time to
        // start before we switch to wireless mode.
        QTimer::singleShot(5000, this, [this]() {
            if (m_wirelessAdbEnabled) return; // already done
            m_wirelessAdbEnabled = true;
            LogManager::instance().log("Enabling wireless ADB (USB can be disconnected after)...");
            std::thread([this]() {
                m_adbHelper->enableWirelessAdb();
            }).detach();
        });
    }
}

void MainWindow::onConnectionLost() {
    if (m_connectBtn) {
        m_connectBtn->setEnabled(true);
    }

    if (m_adbHelper->wasAdbConnection()) {
        // Don't reset m_reconnectAttempts here — if the reconnect itself
        // succeeds briefly then disconnects, we'd loop forever.
        // The counter only resets after a sustained connection (3s in onConnectionEstablished).
        m_recvStatusLabel->setText("Connection lost — reconnecting in 2s...");
        m_recvStatusLabel->setStyleSheet("font-size: 15px; font-weight: bold; color: orange;");
        LogManager::instance().log("Connection lost — will reconnect via ADB in 2s...");
        // Delay before first reconnect to avoid rapid cycling
        QTimer::singleShot(2000, this, [this]() {
            attemptAdbReconnect();
            m_reconnectTimer->start();
        });
    } else {
        // Close video window when non-ADB connection is lost
        if (m_videoWindow && m_videoWindow->isVisible()) {
            m_videoWindow->close();
        }
        m_recvStatusLabel->setText("Connection lost — still listening on port 51820");
        m_recvStatusLabel->setStyleSheet("font-size: 15px; font-weight: bold; color: orange;");
        LogManager::instance().log("Connection lost");
    }
}

void MainWindow::onStatusChanged(const QString& status) {
    if (m_recvStatusLabel) {
        if (status.contains("Waiting for connection", Qt::CaseInsensitive)) {
            m_recvStatusLabel->setText(QString("Listening on port %1").arg(m_receiverPort));
            m_recvStatusLabel->setStyleSheet("font-size: 13px; font-weight: bold; color: #d8d8d8;");
            if (m_recvStatusDetailLabel) {
                m_recvStatusDetailLabel->clear();
                m_recvStatusDetailLabel->hide();
            }
        } else {
            m_recvStatusLabel->setText(status);
            if (m_recvStatusDetailLabel && status.startsWith("TCP listen failed", Qt::CaseInsensitive)) {
                m_recvStatusDetailLabel->setText(status);
                m_recvStatusDetailLabel->show();
            }
        }
    }
    LogManager::instance().log(status);
}

void MainWindow::onReceiverListeningToggled(bool checked) {
    if (m_receiverListenToggle) {
        m_receiverListenToggle->blockSignals(true);
        m_receiverListenToggle->setChecked(checked);
        m_receiverListenToggle->setText(checked ? "On" : "Off");
        m_receiverListenToggle->blockSignals(false);
    }

    if (checked) {
        m_network->start();
        m_receiverPort = m_network->actualTcpPort();
        m_discovery->startAdvertising(m_receiverPort);
        m_receiverListening = true;
        if (m_recvStatusLabel) {
            m_recvStatusLabel->setText(QString("Listening on port %1").arg(m_receiverPort));
            m_recvStatusLabel->setStyleSheet("font-size: 13px; font-weight: bold; color: #d8d8d8;");
        }
        if (m_recvStatusDetailLabel) {
            m_recvStatusDetailLabel->clear();
            m_recvStatusDetailLabel->hide();
        }
        if (m_recvStatusDot) {
            m_recvStatusDot->setStyleSheet("background-color: #34c759; border-radius: 5px;");
        }
        LogManager::instance().log(QString("Receiver listening enabled on port %1").arg(m_receiverPort));
    } else {
        m_discovery->stopAdvertising();
        m_network->stop();
        m_receiverListening = false;
        if (m_recvStatusLabel) {
            m_recvStatusLabel->setText("Receiver is not listening");
            m_recvStatusLabel->setStyleSheet("font-size: 13px; font-weight: bold; color: #9a9a9a;");
        }
        if (m_recvStatusDetailLabel) {
            m_recvStatusDetailLabel->setText("Turn listening on to accept incoming connections.");
            m_recvStatusDetailLabel->show();
        }
        if (m_recvStatusDot) {
            m_recvStatusDot->setStyleSheet("background-color: #6b6b6b; border-radius: 5px;");
        }
        LogManager::instance().log("Receiver listening disabled");
    }

    updateLocalIpDisplay();
}

void MainWindow::onReceiverAutoStartToggled(bool checked) {
    if (m_receiverAutoStartToggle) {
        m_receiverAutoStartToggle->setText(checked ? "On" : "Off");
    }
    QSettings settings;
    settings.setValue("receiverAutoStartEnabled", checked);
    settings.sync();
    LogManager::instance().log(QString("Receiver start-on-launch %1").arg(checked ? "enabled" : "disabled"));
}

void MainWindow::onVideoSizeChanged(QSize size) {
    if (size.width() > 0 && size.height() > 0 && m_videoWindow) {
        LogManager::instance().log(QString("Video size: %1x%2").arg(size.width()).arg(size.height()));
        m_videoWindow->resizeToFitVideo(size.width(), size.height());
    }
}

void MainWindow::attemptAdbReconnect() {
    m_reconnectAttempts++;

    if (m_reconnectAttempts > 15) {
        m_reconnectTimer->stop();
        m_recvStatusLabel->setText("Auto-reconnect failed. Click 'Connect to Android (ADB)' to retry.");
        m_recvStatusLabel->setStyleSheet("font-size: 15px; font-weight: bold; color: #d32f2f;");
        LogManager::instance().log("ADB auto-reconnect failed after 15 attempts");
        return;
    }

    m_recvStatusLabel->setText(QString("Reconnecting via ADB... (attempt %1)").arg(m_reconnectAttempts));
    LogManager::instance().log(QString("ADB reconnect attempt %1").arg(m_reconnectAttempts));

    std::thread([this]() {
        bool success = m_adbHelper->setupForward(51820);
        uint16_t localPort = m_adbHelper->lastLocalPort();
        QMetaObject::invokeMethod(this, [this, success, localPort]() {
            if (success) {
                m_reconnectTimer->stop();
                m_recvStatusLabel->setText("ADB tunnel restored — connecting...");
                LogManager::instance().log("ADB tunnel restored, reconnecting...");
                m_network->connectTo("localhost", localPort);
            }
        });
    }).detach();
}

// ─── Sender Slots ───────────────────────────────────────────────────────────────

#ifdef ENABLE_SENDER
void MainWindow::onSendScreenClicked() {
    QString host = m_sendHostEdit->text().trimmed();
    if (host.isEmpty()) {
        m_senderStatusLabel->setText("Enter a receiver IP address first");
        m_senderStatusLabel->setStyleSheet("font-size: 12px; color: #d32f2f;");
        return;
    }

    // Apply selected monitor to sender controller
    if (m_monitorCombo && m_monitorCombo->currentIndex() >= 0) {
        QVariantMap monData = m_monitorCombo->currentData().toMap();
        int adapterIdx = monData.value("adapter", 0).toInt();
        int outputIdx = monData.value("output", 0).toInt();
        QString displayName = monData.value("displayName").toString();
        m_sender->setMonitorIndex(adapterIdx, outputIdx);
        m_sender->setDisplayName(displayName);
        LogManager::instance().log(QString("Capturing monitor: %1 (adapter %2, output %3)")
                                       .arg(m_monitorCombo->currentText())
                                       .arg(adapterIdx).arg(outputIdx));
    }

    m_sendBtn->setEnabled(false);
    m_stopSendBtn->setEnabled(true);
    m_sendHostEdit->setEnabled(false);
    m_fpsSpinBox->setEnabled(false);
    m_bitrateSpinBox->setEnabled(false);
    m_senderStatusLabel->setText("Starting sender...");
    m_senderStatusLabel->setStyleSheet("font-size: 12px; color: #4da6ff;");

    int fps = m_fpsSpinBox->value();
    int bitrate = m_bitrateSpinBox->value();
    LogManager::instance().log(QString("Starting sender to %1 at %2 FPS, %3 Mbps")
                                   .arg(host).arg(fps).arg(bitrate));
    m_sender->startSending(host, m_selectedReceiverPort, fps, bitrate);
}

void MainWindow::onCreateVirtualDisplay() {
    if (!m_sender || !m_sender->vdd()) return;

    QSize res = m_vddResolutionCombo->currentData().toSize();
    int w = res.width(), h = res.height();
    if (w <= 0 || h <= 0) { w = 1920; h = 1080; }

    m_createVddBtn->setEnabled(false);
    m_vddStatusLabel->setText("Creating virtual display...");
    m_vddStatusLabel->setStyleSheet("font-size: 12px; color: #4da6ff;");
    m_lastSenderError.clear();
    LogManager::instance().log(QString("Creating virtual display %1x%2...").arg(w).arg(h));

    // Run in background thread to avoid blocking UI
    std::thread([this, w, h]() {
        bool ok = m_sender->vdd()->createVirtualDisplay(w, h, 60);
        QMetaObject::invokeMethod(this, [this, ok, w, h]() {
            m_createVddBtn->setEnabled(true);
            if (ok) {
                m_removeVddBtn->setEnabled(true);
                m_vddStatusLabel->setText(QString("Virtual display active: %1x%2").arg(w).arg(h));
                m_vddStatusLabel->setStyleSheet("font-size: 13px; color: #4caf50;");
                LogManager::instance().log("Virtual display created successfully");
                // Refresh monitor list to include the new display
                onRefreshMonitors();
                // Auto-select the virtual display
                for (int i = 0; i < m_monitorCombo->count(); i++) {
                    QVariantMap data = m_monitorCombo->itemData(i).toMap();
                    if (data.value("virtual", false).toBool()) {
                        m_monitorCombo->setCurrentIndex(i);
                        break;
                    }
                }
            } else {
                const QString errorText = m_lastSenderError.isEmpty()
                    ? QString("Failed to create virtual display — check logs")
                    : QString("Failed: %1").arg(m_lastSenderError);
                m_vddStatusLabel->setText(errorText);
                m_vddStatusLabel->setStyleSheet("font-size: 12px; color: #d32f2f;");
            }
        });
    }).detach();
}

void MainWindow::onRemoveVirtualDisplay() {
    if (!m_sender || !m_sender->vdd()) return;

    m_removeVddBtn->setEnabled(false);
    LogManager::instance().log("Removing virtual display...");

    std::thread([this]() {
        bool ok = m_sender->vdd()->removeAllVirtualDisplays();
        QMetaObject::invokeMethod(this, [this, ok]() {
            if (ok) {
                m_vddStatusLabel->setText("Virtual display removed");
                m_vddStatusLabel->setStyleSheet("font-size: 12px; color: #888;");
                LogManager::instance().log("Virtual display removed");
            } else {
                m_removeVddBtn->setEnabled(true);
                LogManager::instance().log("Failed to remove virtual display");
            }
            onRefreshMonitors();
        });
    }).detach();
}

void MainWindow::onRefreshMonitors() {
    if (!m_monitorCombo || !m_sender || !m_sender->vdd()) return;

    m_monitorCombo->clear();

    auto monitors = m_sender->vdd()->enumerateMonitors();
    if (monitors.isEmpty()) {
        m_monitorCombo->addItem("No monitors detected (adapter 0, output 0)");
        QVariantMap defaultData;
        defaultData["adapter"] = 0;
        defaultData["output"] = 0;
        defaultData["virtual"] = false;
        m_monitorCombo->setItemData(0, defaultData);
        return;
    }

    for (const auto& mon : monitors) {
        QString label = QString("%1  %2x%3  (%4)")
                            .arg(mon.name)
                            .arg(mon.width).arg(mon.height)
                            .arg(mon.adapterName);
        if (mon.isVirtual) {
            label += "  [Virtual]";
        }

        QVariantMap data;
        data["adapter"] = mon.adapterIndex;
        data["output"] = mon.outputIndex;
        data["virtual"] = mon.isVirtual;
        data["displayName"] = mon.name;
        m_monitorCombo->addItem(label, data);
    }

    LogManager::instance().log(QString("Found %1 monitor(s)").arg(monitors.size()));
}

void MainWindow::onMonitorSelected(int index) {
    if (!m_monitorCombo || index < 0) return;
    QVariantMap data = m_monitorCombo->itemData(index).toMap();
    LogManager::instance().log(QString("Selected monitor: %1 (adapter %2, output %3)")
                                   .arg(m_monitorCombo->currentText())
                                   .arg(data.value("adapter", 0).toInt())
                                   .arg(data.value("output", 0).toInt()));
}

void MainWindow::onStopSendingClicked() {
    m_sender->stopSending();
    m_senderStatusLabel->setText("Sender stopped");
    m_senderStatusLabel->setStyleSheet("font-size: 12px; color: #888;");
    m_fpsSpinBox->setEnabled(true);
    m_bitrateSpinBox->setEnabled(true);
    LogManager::instance().log("Sender stopped");
}

void MainWindow::onReceiverDiscovered(const DiscoveredService& service) {
    if (!m_receiverCombo) return;

    // Remove the "Searching..." placeholder on first discovery
    if (m_receiverCombo->count() == 1 && !m_receiverCombo->isEnabled()) {
        m_receiverCombo->clear();
        m_receiverCombo->setEnabled(true);
        m_receiverCombo->addItem("Select a receiver...");
    }

    // All BetterCast receivers listen on port 51820. mDNS may report a different port
    // (e.g., from the P2P/AWDL listener) which is unreachable from Windows/Linux.
    // Always use the standard port for reliability.
    uint16_t port = 51820;

    // Check if already in the list
    QString entry = QString("%1  (%2:%3)").arg(service.name, service.host).arg(port);
    for (int i = 0; i < m_receiverCombo->count(); i++) {
        QVariantMap existing = m_receiverCombo->itemData(i).toMap();
        if (existing.value("host").toString() == service.host) {
            m_receiverCombo->setItemText(i, entry);
            QVariantMap updated;
            updated["host"] = service.host;
            updated["port"] = port;
            m_receiverCombo->setItemData(i, updated);
            return;
        }
    }

    QVariantMap data;
    data["host"] = service.host;
    data["port"] = port;
    m_receiverCombo->addItem(entry, data);
    if (service.port != port) {
        LogManager::instance().log(QString("Discovered receiver: %1 at %2 (mDNS reported port %3, using standard port %4)")
                                       .arg(service.name, service.host).arg(service.port).arg(port));
    } else {
        LogManager::instance().log(QString("Discovered receiver: %1 at %2:%3")
                                       .arg(service.name, service.host).arg(port));
    }
}

void MainWindow::onReceiverSelected(int index) {
    if (!m_receiverCombo || !m_sendHostEdit) return;
    QVariantMap data = m_receiverCombo->itemData(index).toMap();
    QString host = data.value("host").toString();
    if (!host.isEmpty()) {
        m_sendHostEdit->setText(host);
        m_selectedReceiverPort = static_cast<uint16_t>(data.value("port", 51820).toUInt());
    }
}
#endif

// ─── Log Slots ──────────────────────────────────────────────────────────────────

void MainWindow::onLogAdded(const QString& entry) {
    if (m_logViewer) {
        m_logViewer->append(entry);
    }
}

void MainWindow::onCopyLogs() {
    QApplication::clipboard()->setText(
        LogManager::instance().entries().join("\n"));
    LogManager::instance().log("Logs copied to clipboard");
}

void MainWindow::onClearLogs() {
    LogManager::instance().clear();
    if (m_logViewer) m_logViewer->clear();
}

void MainWindow::onReportIssue() {
    QString sysInfo = QString("Platform: %1, ExtendCast %2")
        .arg(
#ifdef _WIN32
            "Windows"
#elif __linux__
            "Linux"
#else
            "Unknown"
#endif
        )
        .arg(QApplication::applicationVersion());

    QStringList recentLogs = LogManager::instance().entries();
    if (recentLogs.size() > 30) {
        recentLogs = recentLogs.mid(recentLogs.size() - 30);
    }

    QString body = QString(
        "**Describe the issue:**\n\n\n"
        "**Steps to reproduce:**\n1. \n\n"
        "**Expected behavior:**\n\n\n"
        "**System info:** %1\n\n"
        "<details><summary>Recent Logs</summary>\n\n```\n%2\n```\n\n</details>"
    ).arg(sysInfo, recentLogs.join("\n"));

    QString url = QString("https://github.com/Ruobin521/ExtendCast/issues/new?title=%1&body=%2")
        .arg(QString("Bug: ").toUtf8().toPercentEncoding(),
             body.toUtf8().toPercentEncoding());

    QDesktopServices::openUrl(QUrl(url));
    LogManager::instance().log("Opened GitHub issue form");
}

// Key/mouse events for video are handled by VideoWindow

// ─── Local IP Display ───────────────────────────────────────────────────────────

void MainWindow::updateLocalIpDisplay() {
    const auto infos = receiverAddressInfos();
    QString overviewText = "No network detected";

    if (!infos.isEmpty()) {
        const auto& primary = infos.first();
        overviewText = QString("Best manual address: %1:51820 (%2)")
                           .arg(primary.ip, primary.connectionLabel);
    }

    if (m_overviewIpLabel) m_overviewIpLabel->setText(overviewText);

    if (m_recvStatusLabel) {
        if (m_receiverListening) {
            m_recvStatusLabel->setText(infos.isEmpty() ? "Waiting for network" : QString("Listening on port %1").arg(m_receiverPort));
            m_recvStatusLabel->setToolTip(formatPrimaryHint(infos));
            if (m_recvStatusDetailLabel) {
                m_recvStatusDetailLabel->clear();
                m_recvStatusDetailLabel->hide();
            }
        } else {
            m_recvStatusLabel->setText("Receiver is not listening");
            m_recvStatusLabel->setToolTip("Turn on listening to receive connections.");
            if (m_recvStatusDetailLabel) {
                m_recvStatusDetailLabel->setText("Turn listening on to accept incoming connections.");
                m_recvStatusDetailLabel->show();
            }
        }
    }

    if (!m_receiverListening) {
        if (m_receiverConnectionsTitle) m_receiverConnectionsTitle->hide();
        if (m_receiverConnectionsCard) m_receiverConnectionsCard->hide();
        m_receiverAddressSignature.clear();
        return;
    }

    if (m_receiverConnectionsTitle) m_receiverConnectionsTitle->show();
    if (m_receiverConnectionsCard) m_receiverConnectionsCard->show();

    if (m_recvIpLabel) {
        if (infos.isEmpty()) {
            if (m_recvAddressListLayout) {
                clearLayout(m_recvAddressListLayout);
            }
            m_receiverAddressSignature.clear();
            m_recvIpLabel->show();
            m_recvIpLabel->setText("No active Wi-Fi, Ethernet, or Thunderbolt connection detected.");
            return;
        }

        m_recvIpLabel->clear();
        m_recvIpLabel->hide();
    }

    if (m_recvAddressListLayout) {
        QStringList signatureParts;
        for (const auto& info : infos) {
            signatureParts.append(QString("%1|%2|%3|%4")
                                      .arg(info.connectionLabel, info.ip, QString::number(m_receiverPort), info.usageHint));
        }
        const QString signature = signatureParts.join("\n");
        if (signature == m_receiverAddressSignature) {
            return;
        }

        clearLayout(m_recvAddressListLayout);
        m_receiverAddressSignature = signature;

        for (const auto& info : infos) {
            auto* panel = makeMethodPanel();
            panel->setToolTip(QString("Windows adapter: %1").arg(info.interfaceName));
            auto* row = new QHBoxLayout(panel);
            row->setContentsMargins(18, 16, 18, 16);
            row->setSpacing(16);

            auto* textCol = new QVBoxLayout();
            textCol->setSpacing(6);

            auto* titleRow = new QHBoxLayout();
            titleRow->setSpacing(8);

            auto* modeLabel = new QLabel(info.connectionLabel);
            modeLabel->setStyleSheet("font-size: 13px; font-weight: 700; color: #f2f2f2;");
            titleRow->addWidget(modeLabel);

            titleRow->addStretch();
            textCol->addLayout(titleRow);

            auto* addressLabel = new QLabel(QString("%1:%2").arg(info.ip).arg(m_receiverPort));
            addressLabel->setTextInteractionFlags(Qt::TextSelectableByMouse);
            addressLabel->setWordWrap(true);
            addressLabel->setStyleSheet(
                "font-family: Consolas, 'SF Mono', monospace; font-size: 20px; "
                "font-weight: 700; color: #ffffff; letter-spacing: 0;");
            textCol->addWidget(addressLabel);

            auto* hintLabel = new QLabel(info.usageHint);
            hintLabel->setWordWrap(true);
            hintLabel->setStyleSheet("font-size: 12px; color: #a6a6a6;");
            textCol->addWidget(hintLabel);

            row->addLayout(textCol, 1);

            auto* copyBtn = new QPushButton("Copy");
            copyBtn->setCursor(Qt::PointingHandCursor);
            copyBtn->setFixedWidth(68);
            copyBtn->setStyleSheet(
                "QPushButton { background-color: #2b2b2b; border: 1px solid #3a3a3a; "
                "border-radius: 8px; color: #d8d8d8; font-size: 12px; font-weight: 600; padding: 6px 10px; }"
                "QPushButton:hover { background-color: #333333; border-color: #4d4d4d; }");
            const QString address = QString("%1:%2").arg(info.ip).arg(m_receiverPort);
            connect(copyBtn, &QPushButton::clicked, this, [address]() {
                QApplication::clipboard()->setText(address);
                LogManager::instance().log(QString("Copied receiver address: %1").arg(address));
            });
            row->addWidget(copyBtn, 0, Qt::AlignTop);

            m_recvAddressListLayout->addWidget(panel);
        }
    }
}
