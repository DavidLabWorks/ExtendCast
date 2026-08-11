#pragma once

#include <QMainWindow>
#include <QPushButton>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QResizeEvent>
#include <QScreen>
#include <QApplication>
#include <QSize>
#include <QString>

class QEvent;
class QFrame;
class QLabel;
class QWidget;
class InputHandler;

class VideoWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit VideoWindow(QWidget* videoSurface, InputHandler* inputHandler, QWidget* parent = nullptr);
    ~VideoWindow();

    void showForVideo();
    void resizeToFitVideo(int videoWidth, int videoHeight);
    void bindToDevice(const QString& deviceId, const QString& deviceName);
    QString deviceId() const { return m_deviceId; }
    bool isFullscreen() const;
    void toggleFullscreen();

signals:
    void windowClosed();

protected:
    void keyPressEvent(QKeyEvent* event) override;
    void mouseDoubleClickEvent(QMouseEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;
    void closeEvent(QCloseEvent* event) override;
    bool eventFilter(QObject* watched, QEvent* event) override;
    bool nativeEvent(const QByteArray& eventType, void* message, qintptr* result) override;
    void changeEvent(QEvent* event) override;

private:
    void setupTitleBar(QVBoxLayout* layout);
    void updateWindowControlStates();
    void updateFullscreenButton();
    void applyWindowChrome();
    bool isImmersiveFullscreen() const;
    void enterImmersiveFullscreen();
    void exitImmersiveFullscreen();

    QWidget* m_videoSurface = nullptr;
    InputHandler* m_inputHandler = nullptr;
    QWidget* m_ownerWindow = nullptr;
    QFrame* m_titleBar = nullptr;
    QLabel* m_titleLabel = nullptr;
    QPushButton* m_maximizeButton = nullptr;
    QPushButton* m_fullscreenButton = nullptr;
    QSize m_lastVideoSize;
    QString m_deviceId;
    QRect m_normalGeometry;
    bool m_hasNormalGeometry = false;
    bool m_immersiveFullscreen = false;
};
