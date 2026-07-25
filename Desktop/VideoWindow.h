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
#include <QPoint>

class VideoRenderer;
class InputHandler;

class VideoWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit VideoWindow(VideoRenderer* renderer, InputHandler* inputHandler, QWidget* parent = nullptr);
    ~VideoWindow();

    void showForVideo();
    void resizeToFitVideo(int videoWidth, int videoHeight);

signals:
    void windowClosed();

protected:
    void keyPressEvent(QKeyEvent* event) override;
    void mouseDoubleClickEvent(QMouseEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;
    void closeEvent(QCloseEvent* event) override;

private:
    void toggleFullscreen();
    void updateFullscreenButton();
    void positionFullscreenButton(bool forceDefault = false);
    void captureFullscreenButtonAnchor();

    VideoRenderer* m_renderer = nullptr;
    InputHandler* m_inputHandler = nullptr;
    QWidget* m_ownerWindow = nullptr;
    QPushButton* m_fullscreenButton = nullptr;
    QSize m_lastVideoSize;
    bool m_fullscreenButtonMoved = false;
    bool m_buttonAnchorRight = true;
    bool m_buttonAnchorBottom = true;
    int m_buttonAnchorX = 16;
    int m_buttonAnchorY = 16;
};
