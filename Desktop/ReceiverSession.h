#pragma once

#include <QObject>
#include <QByteArray>
#include <QString>

#include "InputEvent.h"

class AudioDecoder;
class AudioPlayer;
class InputHandler;
class MainWindow;
class VideoDecoder;
class VideoRenderer;
class VideoWindow;

class ReceiverSession : public QObject {
    Q_OBJECT

public:
    ReceiverSession(
        const QString& deviceId,
        const QString& deviceName,
        const QString& connectionId,
        MainWindow* ownerWindow
    );
    ~ReceiverSession() override;

    QString deviceId() const { return m_deviceId; }
    QString deviceName() const { return m_deviceName; }
    QString connectionId() const { return m_connectionId; }

    void replaceConnection(
        const QString& connectionId,
        const QString& deviceName
    );
    void show();
    void resetVideoDecoder();
    void decodeVideo(const QByteArray& data);
    void decodeAudio(const QByteArray& data);

signals:
    void inputEvent(
        const QString& deviceId,
        const InputEvent& event
    );
    void keyframeRequested(const QString& deviceId);
    void windowClosed(const QString& deviceId);

private:
    QString m_deviceId;
    QString m_deviceName;
    QString m_connectionId;
    VideoDecoder* m_decoder = nullptr;
    VideoRenderer* m_renderer = nullptr;
    InputHandler* m_inputHandler = nullptr;
    AudioDecoder* m_audioDecoder = nullptr;
    AudioPlayer* m_audioPlayer = nullptr;
    VideoWindow* m_window = nullptr;
};
