#include "VideoWindow.h"
#include "VideoRenderer.h"
#include "InputHandler.h"
#include "MainWindow.h"  // for LogManager

#include <QDebug>
#include <QEvent>
#include <QFrame>
#include <QIcon>
#include <QLabel>
#include <QWindow>
#include <functional>

#ifdef _WIN32
#include <windows.h>
#include <windowsx.h>
#endif

VideoWindow::VideoWindow(VideoRenderer* renderer, InputHandler* inputHandler, QWidget* parent)
    : QMainWindow(nullptr)
    , m_renderer(renderer)
    , m_inputHandler(inputHandler)
    , m_ownerWindow(parent)
{
    setWindowTitle("ExtendCast — Receiving");
    setAttribute(Qt::WA_DeleteOnClose, false);
    setWindowFlags(Qt::Window | Qt::FramelessWindowHint);
    setStyleSheet(R"(
        QMainWindow { background-color: black; }
        QWidget#videoRoot { background-color: black; border: 1px solid #303030; }
        QFrame#videoTitleBar { background-color: #151515; border: none; }
        QLabel#videoTitleText { color: #a8a8a8; font-size: 13px; font-weight: 500; }
        QPushButton#videoWindowButton { background: transparent; border: none; color: #c8c8c8; font-family: "Segoe MDL2 Assets"; font-size: 10px; padding: 0; margin: 0; }
        QPushButton#videoWindowButton:hover { background-color: rgba(255, 255, 255, 0.12); color: #ffffff; }
        QPushButton#videoWindowButton:pressed { background-color: rgba(255, 255, 255, 0.08); color: #ffffff; }
        QPushButton#videoCloseWindowButton { background: transparent; border: none; color: #c8c8c8; font-family: "Segoe MDL2 Assets"; font-size: 10px; padding: 0; margin: 0; }
        QPushButton#videoCloseWindowButton:hover { background-color: #c42b1c; color: #ffffff; }
        QPushButton#videoCloseWindowButton:pressed { background-color: #a82419; color: #ffffff; }
    )");
    setMinimumSize(320, 214);

    auto* central = new QWidget();
    central->setObjectName("videoRoot");
    auto* layout = new QVBoxLayout(central);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    setupTitleBar(layout);
    layout->addWidget(m_renderer, 1);

    setCentralWidget(central);

}

void VideoWindow::setupTitleBar(QVBoxLayout* layout) {
    m_titleBar = new QFrame(this);
    m_titleBar->setObjectName("videoTitleBar");
    m_titleBar->setFixedHeight(32);
    m_titleBar->installEventFilter(this);

    auto* titleLayout = new QHBoxLayout(m_titleBar);
    titleLayout->setContentsMargins(12, 0, 0, 0);
    titleLayout->setSpacing(8);

    auto* iconLabel = new QLabel(m_titleBar);
    QPixmap appIcon(":/appicon.png");
    if (!appIcon.isNull()) {
        iconLabel->setPixmap(appIcon.scaled(18, 18, Qt::KeepAspectRatio, Qt::SmoothTransformation));
    }
    iconLabel->setFixedSize(20, 20);
    iconLabel->setAlignment(Qt::AlignCenter);
    iconLabel->installEventFilter(this);
    titleLayout->addWidget(iconLabel);

    m_titleLabel = new QLabel("Receiving", m_titleBar);
    m_titleLabel->setObjectName("videoTitleText");
    m_titleLabel->installEventFilter(this);
    titleLayout->addWidget(m_titleLabel);
    titleLayout->addStretch();

    m_fullscreenButton = new QPushButton(QString::fromWCharArray(L"\uE740"), m_titleBar);
    m_fullscreenButton->setObjectName("videoWindowButton");
    m_fullscreenButton->setFixedSize(46, 32);
    m_fullscreenButton->setToolTip("Enter fullscreen");
    connect(m_fullscreenButton, &QPushButton::clicked, this, &VideoWindow::toggleFullscreen);
    titleLayout->addWidget(m_fullscreenButton);

    auto* minimizeButton = new QPushButton(QString::fromWCharArray(L"\uE921"), m_titleBar);
    minimizeButton->setObjectName("videoWindowButton");
    minimizeButton->setFixedSize(46, 32);
    connect(minimizeButton, &QPushButton::clicked, this, &VideoWindow::showMinimized);
    titleLayout->addWidget(minimizeButton);

    m_maximizeButton = new QPushButton(QString::fromWCharArray(L"\uE922"), m_titleBar);
    m_maximizeButton->setObjectName("videoWindowButton");
    m_maximizeButton->setFixedSize(46, 32);
    connect(m_maximizeButton, &QPushButton::clicked, this, [this]() {
        isMaximized() ? showNormal() : showMaximized();
    });
    titleLayout->addWidget(m_maximizeButton);

    auto* closeButton = new QPushButton(QString::fromWCharArray(L"\uE8BB"), m_titleBar);
    closeButton->setObjectName("videoCloseWindowButton");
    closeButton->setFixedSize(46, 32);
    connect(closeButton, &QPushButton::clicked, this, &VideoWindow::close);
    titleLayout->addWidget(closeButton);

    layout->addWidget(m_titleBar);
}

void VideoWindow::updateWindowControlStates() {
    if (m_maximizeButton) {
        m_maximizeButton->setText(QString::fromWCharArray(isMaximized() ? L"\uE923" : L"\uE922"));
    }
}

VideoWindow::~VideoWindow() {
    // Don't delete the renderer — it's owned by MainWindow
    if (m_renderer) {
        m_renderer->setParent(nullptr);
    }
}

void VideoWindow::showForVideo() {
    if (isVisible()) {
        if (m_renderer) {
            m_renderer->show();
        }
        raise();
        activateWindow();
        return;
    }

    if (m_titleBar) {
        m_titleBar->show();
    }
    if (m_fullscreenButton) {
        m_fullscreenButton->show();
    }
    updateWindowControlStates();
    updateFullscreenButton();

    // Position to the right of the main window if possible
    QWidget* mainWin = m_ownerWindow;
    QScreen* screen = QApplication::primaryScreen();
    QRect available = screen ? screen->availableGeometry()
                             : QRect(0, 0, 1920, 1080);

    int winW = 960;
    int winH = 540;

    if (mainWin) {
        QRect mainFrame = mainWin->geometry();
        int rightX = mainFrame.right() + 12;
        if (rightX + winW <= available.right()) {
            move(rightX, mainFrame.center().y() - winH / 2);
        } else {
            int leftX = mainFrame.left() - winW - 12;
            move(qMax(leftX, available.left()), mainFrame.center().y() - winH / 2);
        }
    } else {
        move(available.center().x() - winW / 2, available.center().y() - winH / 2);
    }

    resize(winW, winH);
    if (m_renderer) {
        m_renderer->show();
    }
    show();
    LogManager::instance().log("Video window opened");
}

void VideoWindow::bindToDevice(
    const QString& deviceId,
    const QString& deviceName
) {
    m_deviceId = deviceId;
    setObjectName("receiving-" + deviceId);
    setProperty("receiverDeviceId", deviceId);
    setWindowTitle(QString("ExtendCast — %1").arg(deviceName));
    if (m_titleLabel) {
        m_titleLabel->setText(
            QString("%1 · %2")
                .arg(deviceName, deviceId.left(8))
        );
    }
}

void VideoWindow::resizeToFitVideo(int videoWidth, int videoHeight) {
    if (videoWidth <= 0 || videoHeight <= 0) return;

    QSize newSize(videoWidth, videoHeight);
    if (newSize == m_lastVideoSize) return;
    m_lastVideoSize = newSize;
    if (isFullScreen() || isMaximized()) {
        return;
    }

    QScreen* screen = QApplication::primaryScreen();
    if (!screen) return;
    QRect available = screen->availableGeometry();

    double aspect = static_cast<double>(videoWidth) / videoHeight;
    bool landscape = videoWidth > videoHeight;

    int winW, winH;
    if (landscape) {
        winW = qMin(static_cast<int>(available.width() * 0.6), videoWidth);
        winH = static_cast<int>(winW / aspect);
        if (winH > available.height() * 0.8) {
            winH = static_cast<int>(available.height() * 0.8);
            winW = static_cast<int>(winH * aspect);
        }
    } else {
        winH = qMin(static_cast<int>(available.height() * 0.75), videoHeight);
        winW = static_cast<int>(winH * aspect);
        if (winW > available.width() * 0.5) {
            winW = static_cast<int>(available.width() * 0.5);
            winH = static_cast<int>(winW / aspect);
        }
    }

    winW = qMax(winW, 320);
    winH = qMax(winH, 180);

    // Keep centered on current center
    QRect cur = geometry();
    int x = cur.center().x() - winW / 2;
    int y = cur.center().y() - winH / 2;
    x = qMax(available.left(), qMin(x, available.right() - winW));
    y = qMax(available.top(), qMin(y, available.bottom() - winH));

    qDebug() << "VideoWindow: Resizing to" << winW << "x" << winH
             << "for video" << videoWidth << "x" << videoHeight;

    setGeometry(x, y, winW, winH);
}

bool VideoWindow::eventFilter(QObject* watched, QEvent* event) {
    if ((watched == m_titleBar || (m_titleBar && watched->parent() == m_titleBar)) && event) {
        if (event->type() == QEvent::MouseButtonDblClick) {
            auto* mouseEvent = static_cast<QMouseEvent*>(event);
            if (mouseEvent->button() == Qt::LeftButton) {
                isMaximized() ? showNormal() : showMaximized();
                return true;
            }
        }

        if (event->type() == QEvent::MouseButtonPress) {
            auto* mouseEvent = static_cast<QMouseEvent*>(event);
            if (mouseEvent->button() == Qt::LeftButton && windowHandle()) {
                windowHandle()->startSystemMove();
                return true;
            }
        }
    }

    return QMainWindow::eventFilter(watched, event);
}

void VideoWindow::changeEvent(QEvent* event) {
    QMainWindow::changeEvent(event);
    if (event->type() == QEvent::WindowStateChange) {
        updateWindowControlStates();
        updateFullscreenButton();
    }
}

bool VideoWindow::nativeEvent(const QByteArray& eventType, void* message, qintptr* result) {
#ifdef _WIN32
    Q_UNUSED(eventType);
    MSG* msg = static_cast<MSG*>(message);
    if (msg && msg->message == WM_NCHITTEST) {
        const LONG x = GET_X_LPARAM(msg->lParam);
        const LONG y = GET_Y_LPARAM(msg->lParam);
        const QPoint localPos = mapFromGlobal(QPoint(x, y));
        const int resizeMargin = isMaximized() || isFullScreen() ? 0 : 6;
        const int w = width();
        const int h = height();

        const bool left = localPos.x() >= 0 && localPos.x() < resizeMargin;
        const bool right = localPos.x() <= w && localPos.x() >= w - resizeMargin;
        const bool top = localPos.y() >= 0 && localPos.y() < resizeMargin;
        const bool bottom = localPos.y() <= h && localPos.y() >= h - resizeMargin;

        if (top && left) { *result = HTTOPLEFT; return true; }
        if (top && right) { *result = HTTOPRIGHT; return true; }
        if (bottom && left) { *result = HTBOTTOMLEFT; return true; }
        if (bottom && right) { *result = HTBOTTOMRIGHT; return true; }
        if (left) { *result = HTLEFT; return true; }
        if (right) { *result = HTRIGHT; return true; }
        if (top) { *result = HTTOP; return true; }
        if (bottom) { *result = HTBOTTOM; return true; }

        const int titleHeight = m_titleBar && m_titleBar->isVisible() ? m_titleBar->height() : 0;
        const bool overWindowButtons = localPos.x() >= w - 184 && localPos.y() >= 0 && localPos.y() < titleHeight;
        if (!overWindowButtons && localPos.y() >= 0 && localPos.y() < titleHeight) {
            *result = HTCAPTION;
            return true;
        }
    }
#else
    Q_UNUSED(eventType);
    Q_UNUSED(message);
    Q_UNUSED(result);
#endif
    return QMainWindow::nativeEvent(eventType, message, result);
}

void VideoWindow::keyPressEvent(QKeyEvent* event) {
    if (event->key() == Qt::Key_F11) {
        toggleFullscreen();
        return;
    }
    if (event->key() == Qt::Key_Escape) {
        if (isFullScreen()) {
            toggleFullscreen();
            return;
        }
    }
    QMainWindow::keyPressEvent(event);
}

void VideoWindow::mouseDoubleClickEvent(QMouseEvent* event) {
    toggleFullscreen();
    event->accept();
}

void VideoWindow::resizeEvent(QResizeEvent* event) {
    QMainWindow::resizeEvent(event);
}

void VideoWindow::closeEvent(QCloseEvent* event) {
    if (isFullScreen()) {
        showNormal();
    }
    if (m_titleBar) {
        m_titleBar->show();
    }
    if (m_fullscreenButton) {
        m_fullscreenButton->show();
    }
    emit windowClosed();
    QMainWindow::closeEvent(event);
}

void VideoWindow::toggleFullscreen() {
    if (isFullScreen()) {
        if (m_titleBar) m_titleBar->show();
        showNormal();
        if (m_fullscreenButton) m_fullscreenButton->show();
        updateWindowControlStates();
        updateFullscreenButton();
        LogManager::instance().log("Exited fullscreen");
    } else {
        if (m_titleBar) m_titleBar->hide();
        showFullScreen();
        updateWindowControlStates();
        LogManager::instance().log("Entered fullscreen (F11 or Escape to exit)");
    }
}

void VideoWindow::updateFullscreenButton() {
    if (!m_fullscreenButton) {
        return;
    }
    m_fullscreenButton->show();
    m_fullscreenButton->setText(QString::fromWCharArray(L"\uE740"));
}
