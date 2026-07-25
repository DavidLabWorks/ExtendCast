#include "VideoWindow.h"
#include "VideoRenderer.h"
#include "InputHandler.h"
#include "MainWindow.h"  // for LogManager

#include <QDebug>
#include <QIcon>
#include <functional>

namespace {

class FloatingFullscreenButton : public QPushButton {
public:
    explicit FloatingFullscreenButton(QWidget* parent = nullptr)
        : QPushButton(parent)
    {
        setFixedSize(38, 38);
        setCursor(Qt::PointingHandCursor);
        setFocusPolicy(Qt::NoFocus);
    }

    bool wasMovedByUser() const { return m_wasMovedByUser; }
    void setMoveFinishedCallback(std::function<void()> callback) {
        m_moveFinishedCallback = std::move(callback);
    }

protected:
    void mousePressEvent(QMouseEvent* event) override {
        if (event->button() == Qt::LeftButton) {
            m_pressPos = event->globalPosition().toPoint();
            m_startPos = pos();
            m_dragging = false;
        }
        QPushButton::mousePressEvent(event);
    }

    void mouseMoveEvent(QMouseEvent* event) override {
        QWidget* bounds = parentWidget();
        if (!(event->buttons() & Qt::LeftButton) || !bounds) {
            QPushButton::mouseMoveEvent(event);
            return;
        }

        const QPoint delta = event->globalPosition().toPoint() - m_pressPos;
        if (!m_dragging && delta.manhattanLength() < QApplication::startDragDistance()) {
            QPushButton::mouseMoveEvent(event);
            return;
        }

        m_dragging = true;
        m_wasMovedByUser = true;
        setCursor(Qt::SizeAllCursor);

        const int margin = 12;
        QPoint next = m_startPos + delta;
        next.setX(qBound(margin, next.x(), bounds->width() - width() - margin));
        next.setY(qBound(margin, next.y(), bounds->height() - height() - margin));
        move(next);
        raise();
        event->accept();
    }

    void mouseReleaseEvent(QMouseEvent* event) override {
        setCursor(Qt::PointingHandCursor);
        if (m_dragging) {
            m_dragging = false;
            setDown(false);
            if (m_moveFinishedCallback) {
                m_moveFinishedCallback();
            }
            event->accept();
            return;
        }
        QPushButton::mouseReleaseEvent(event);
    }

private:
    QPoint m_pressPos;
    QPoint m_startPos;
    bool m_dragging = false;
    bool m_wasMovedByUser = false;
    std::function<void()> m_moveFinishedCallback;
};

} // namespace

VideoWindow::VideoWindow(VideoRenderer* renderer, InputHandler* inputHandler, QWidget* parent)
    : QMainWindow(nullptr)
    , m_renderer(renderer)
    , m_inputHandler(inputHandler)
    , m_ownerWindow(parent)
{
    setWindowTitle("ExtendCast — Receiving");
    setAttribute(Qt::WA_DeleteOnClose, false);
    setWindowFlag(Qt::Window, true);
    setStyleSheet("background-color: black;");
    setMinimumSize(320, 180);

    auto* central = new QWidget();
    central->setStyleSheet("background-color: black;");
    auto* layout = new QVBoxLayout(central);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    layout->addWidget(m_renderer, 1);

    setCentralWidget(central);

    m_fullscreenButton = new FloatingFullscreenButton(central);
    static_cast<FloatingFullscreenButton*>(m_fullscreenButton)->setMoveFinishedCallback([this]() {
        m_fullscreenButtonMoved = true;
        captureFullscreenButtonAnchor();
    });
    connect(m_fullscreenButton, &QPushButton::clicked, this, &VideoWindow::toggleFullscreen);
    updateFullscreenButton();
    positionFullscreenButton(true);
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
    positionFullscreenButton(true);
    LogManager::instance().log("Video window opened");
}

void VideoWindow::resizeToFitVideo(int videoWidth, int videoHeight) {
    if (videoWidth <= 0 || videoHeight <= 0) return;

    QSize newSize(videoWidth, videoHeight);
    if (newSize == m_lastVideoSize) return;
    m_lastVideoSize = newSize;

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
    positionFullscreenButton(false);
}

void VideoWindow::closeEvent(QCloseEvent* event) {
    if (isFullScreen()) {
        showNormal();
    }
    emit windowClosed();
    QMainWindow::closeEvent(event);
}

void VideoWindow::toggleFullscreen() {
    captureFullscreenButtonAnchor();

    if (isFullScreen()) {
        showNormal();
        updateFullscreenButton();
        positionFullscreenButton(false);
        LogManager::instance().log("Exited fullscreen");
    } else {
        showFullScreen();
        updateFullscreenButton();
        positionFullscreenButton(false);
        LogManager::instance().log("Entered fullscreen (F11 or Escape to exit)");
    }
}

void VideoWindow::updateFullscreenButton() {
    if (!m_fullscreenButton) return;

    const bool full = isFullScreen();
    m_fullscreenButton->setIcon(QIcon());
    m_fullscreenButton->setText(full
        ? QString::fromUtf8("\xE2\x86\x98 \xE2\x86\x99\n\xE2\x86\x97 \xE2\x86\x96")
        : QString::fromUtf8("\xE2\x86\x96 \xE2\x86\x97\n\xE2\x86\x99 \xE2\x86\x98"));
    m_fullscreenButton->setToolTip(full ? "Exit fullscreen" : "Enter fullscreen");
    m_fullscreenButton->setAccessibleName(full ? "Exit fullscreen" : "Enter fullscreen");
    m_fullscreenButton->setStyleSheet(R"(
        QPushButton {
            background-color: rgba(16, 16, 16, 0.72);
            border: 1px solid rgba(255, 255, 255, 0.24);
            border-radius: 8px;
            color: white;
            font-size: 13px;
            font-weight: 600;
            line-height: 12px;
            padding: 0;
        }
        QPushButton:hover {
            background-color: rgba(34, 34, 34, 0.78);
            border-color: rgba(255, 255, 255, 0.36);
        }
        QPushButton:pressed {
            background-color: rgba(16, 16, 16, 0.72);
            border-color: rgba(255, 255, 255, 0.24);
        }
    )");
    m_fullscreenButton->raise();
    m_fullscreenButton->show();
}

void VideoWindow::captureFullscreenButtonAnchor() {
    if (!m_fullscreenButton || !centralWidget()) return;

    const int parentW = centralWidget()->width();
    const int parentH = centralWidget()->height();
    const int left = m_fullscreenButton->x();
    const int top = m_fullscreenButton->y();
    const int right = parentW - left - m_fullscreenButton->width();
    const int bottom = parentH - top - m_fullscreenButton->height();

    m_buttonAnchorRight = right < left;
    m_buttonAnchorBottom = bottom < top;
    m_buttonAnchorX = qMax(0, m_buttonAnchorRight ? right : left);
    m_buttonAnchorY = qMax(0, m_buttonAnchorBottom ? bottom : top);
}

void VideoWindow::positionFullscreenButton(bool forceDefault) {
    if (!m_fullscreenButton || !centralWidget()) return;

    auto* floatingButton = dynamic_cast<FloatingFullscreenButton*>(m_fullscreenButton);
    if (floatingButton && floatingButton->wasMovedByUser()) {
        m_fullscreenButtonMoved = true;
    }

    const int margin = isFullScreen() ? 24 : 16;
    const QSize buttonSize = m_fullscreenButton->size();
    QPoint next = m_fullscreenButton->pos();

    if (forceDefault || !m_fullscreenButtonMoved) {
        m_buttonAnchorRight = true;
        m_buttonAnchorBottom = true;
        m_buttonAnchorX = margin;
        m_buttonAnchorY = margin;
        next = QPoint(centralWidget()->width() - buttonSize.width() - margin,
                      centralWidget()->height() - buttonSize.height() - margin);
    } else {
        next.setX(m_buttonAnchorRight
            ? centralWidget()->width() - buttonSize.width() - m_buttonAnchorX
            : m_buttonAnchorX);
        next.setY(m_buttonAnchorBottom
            ? centralWidget()->height() - buttonSize.height() - m_buttonAnchorY
            : m_buttonAnchorY);
    }

    next.setX(qBound(margin, next.x(), centralWidget()->width() - buttonSize.width() - margin));
    next.setY(qBound(margin, next.y(), centralWidget()->height() - buttonSize.height() - margin));
    m_fullscreenButton->move(next);
    m_fullscreenButton->raise();
}
