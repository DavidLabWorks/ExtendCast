#include "ReceiverSession.h"

#include "AudioDecoder.h"
#include "AudioPlayer.h"
#include "InputHandler.h"
#include "MainWindow.h"
#include "VideoDecoder.h"
#include "VideoRenderer.h"
#include "VideoWindow.h"

#include <QSize>

ReceiverSession::ReceiverSession(
    const QString& deviceId,
    const QString& deviceName,
    const QString& connectionId,
    MainWindow* ownerWindow
)
    : QObject(ownerWindow)
    , m_deviceId(deviceId)
    , m_deviceName(deviceName)
    , m_connectionId(connectionId)
    , m_decoder(new VideoDecoder(this))
    , m_renderer(new VideoRenderer())
    , m_inputHandler(new InputHandler(this))
    , m_audioDecoder(new AudioDecoder(this))
    , m_audioPlayer(new AudioPlayer(this))
    , m_window(new VideoWindow(m_renderer, m_inputHandler, ownerWindow))
{
    m_window->bindToDevice(m_deviceId, m_deviceName);
    m_inputHandler->attach(m_renderer);

    connect(
        m_decoder,
        &VideoDecoder::frameDecoded,
        m_renderer,
        &VideoRenderer::onFrameDecoded
    );
    connect(
        m_decoder,
        &VideoDecoder::dimensionsChanged,
        this,
        [this](int width, int height) {
            m_inputHandler->setContentSize(QSize(width, height));
        }
    );
    connect(
        m_decoder,
        &VideoDecoder::keyframeNeeded,
        this,
        [this]() {
            emit keyframeRequested(m_deviceId);
        }
    );
    connect(
        m_renderer,
        &VideoRenderer::videoSizeChanged,
        this,
        [this](QSize size) {
            if (size.width() <= 0 || size.height() <= 0) {
                return;
            }
            LogManager::instance().log(
                QString("Video size for %1: %2x%3")
                    .arg(m_deviceName)
                    .arg(size.width())
                    .arg(size.height())
            );
            m_window->resizeToFitVideo(size.width(), size.height());
        }
    );
    connect(
        m_audioDecoder,
        &AudioDecoder::pcmDecoded,
        m_audioPlayer,
        &AudioPlayer::onPcmDecoded
    );
    connect(
        m_inputHandler,
        &InputHandler::inputEvent,
        this,
        [this](const InputEvent& event) {
            emit inputEvent(m_deviceId, event);
        }
    );
    connect(
        m_window,
        &VideoWindow::windowClosed,
        this,
        [this]() {
            emit windowClosed(m_deviceId);
        }
    );
}

ReceiverSession::~ReceiverSession() {
    if (m_window) {
        m_window->hide();
        delete m_window;
        m_window = nullptr;
    }
    delete m_renderer;
    m_renderer = nullptr;
}

void ReceiverSession::replaceConnection(
    const QString& connectionId,
    const QString& deviceName
) {
    m_connectionId = connectionId;
    m_deviceName = deviceName;
    m_decoder->reset();
    m_window->bindToDevice(m_deviceId, m_deviceName);
}

void ReceiverSession::show() {
    m_window->showForVideo();
}

void ReceiverSession::resetVideoDecoder() {
    m_decoder->reset();
}

void ReceiverSession::decodeVideo(
    const QByteArray& data
) {
    m_decoder->decode(data);
}

void ReceiverSession::decodeAudio(const QByteArray& data) {
    m_audioDecoder->decode(data);
}
