#include "ReceiverSession.h"

#include "AudioDecoder.h"
#include "AudioPlayer.h"
#include "InputHandler.h"
#include "MainWindow.h"
#include "VideoDecoder.h"
#include "VideoRenderer.h"
#include "VideoWindow.h"

#include <QSize>

namespace {
constexpr int kKeyframeRequestCooldownMs = 2000;
}

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
    , m_decoder(new VideoDecoder())
    , m_renderer(new VideoRenderer())
    , m_inputHandler(new InputHandler(this))
    , m_audioDecoder(new AudioDecoder(this))
    , m_audioPlayer(new AudioPlayer(this))
    , m_window(new VideoWindow(m_renderer, m_inputHandler, ownerWindow))
{
    m_decoder->moveToThread(&m_decoderThread);
    connect(
        &m_decoderThread,
        &QThread::finished,
        m_decoder,
        &QObject::deleteLater
    );
    m_decoderThread.setObjectName("ExtendCast video decoder");
    m_decoderThread.start(QThread::HighPriority);
    m_playbackAcknowledgementTimer.start();
    m_keyframeRequestCooldown.invalidate();

    m_window->bindToDevice(m_deviceId, m_deviceName);
    m_inputHandler->attach(m_renderer);

    connect(
        m_decoder,
        &VideoDecoder::frameDecoded,
        m_renderer,
        &VideoRenderer::onFrameDecoded,
        Qt::DirectConnection
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
            if (m_videoDecodeQueue.waitForKeyframeAfterDecodeError()) {
                requestKeyframeThrottled("decode error");
            }
        },
        Qt::DirectConnection
    );
    connect(
        m_renderer,
        &VideoRenderer::framePresented,
        this,
        [this](
            quint64 streamId,
            quint64 sequence,
            quint64 presentationTimestampNanoseconds
        ) {
            if (m_playbackAcknowledgementTimer.elapsed() < 250) {
                return;
            }
            m_playbackAcknowledgementTimer.restart();
            InputEvent acknowledgement(
                InputEventType::Command,
                0,
                0,
                kPlaybackAcknowledgementKeyCode
            );
            acknowledgement.streamId = QString::number(streamId);
            acknowledgement.sequence = QString::number(sequence);
            acknowledgement.presentationTimestampNanoseconds =
                QString::number(presentationTimestampNanoseconds);
            emit inputEvent(m_deviceId, acknowledgement);
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
    m_decoderThread.quit();
    m_decoderThread.wait();
    m_decoder = nullptr;
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
    resetVideoDecoder();
    m_window->bindToDevice(m_deviceId, m_deviceName);
}

void ReceiverSession::show() {
    m_window->showForVideo();
}

void ReceiverSession::resetVideoDecoder() {
    m_videoDecodeQueue.clearForStreamReset();
    if (!m_decoder) {
        return;
    }
    QMetaObject::invokeMethod(
        m_decoder,
        [decoder = m_decoder]() { decoder->reset(); },
        Qt::QueuedConnection
    );
}

void ReceiverSession::noteCatchUpToBufferedKeyframe() {
    m_videoDecodeQueue.armFlushBeforeNextFrame();
}

void ReceiverSession::noteCatchUpWaitingForKeyframe() {
    m_videoDecodeQueue.waitForRemoteKeyframe();
}

void ReceiverSession::requestKeyframeThrottled(const char* reason) {
    if (m_keyframeRequestCooldown.isValid()
        && m_keyframeRequestCooldown.elapsed() < kKeyframeRequestCooldownMs) {
        return;
    }
    m_keyframeRequestCooldown.start();
    LogManager::instance().log(
        QString("Decoder: Requesting keyframe (%1)").arg(reason)
    );
    emit keyframeRequested(m_deviceId);
}

void ReceiverSession::decodeVideo(
    const QByteArray& data
) {
    if (!m_decoder) return;

    video_packet::Header header;
    if (!video_packet::parseHeader(
            reinterpret_cast<const std::uint8_t*>(data.constData()),
            static_cast<std::size_t>(data.size()),
            header
        )) {
        return;
    }

    const auto result = m_videoDecodeQueue.enqueue(data, header);
    if (result.discardedFrames > 0) {
        LogManager::instance().log(
            QString("Decoder: Discarded %1 queued frame(s) to catch up")
                .arg(static_cast<qulonglong>(result.discardedFrames))
        );
    }
    if (result.requestKeyframe) {
        requestKeyframeThrottled("decode queue latency budget");
    }
    if (!result.scheduleDrain) {
        return;
    }

    QMetaObject::invokeMethod(
        m_decoder,
        [
            decoder = m_decoder,
            queue = &m_videoDecodeQueue
        ]() {
            while (const auto item = queue->takeNext()) {
                switch (item->resumeAction) {
                case VideoDecodeResumeAction::Flush:
                    decoder->flushForKeyframeResume();
                    break;
                case VideoDecodeResumeAction::HardReset:
                    decoder->reset();
                    break;
                case VideoDecodeResumeAction::Continue:
                    break;
                }
                decoder->decode(item->packet);
            }
        },
        Qt::QueuedConnection
    );
}

void ReceiverSession::decodeAudio(const QByteArray& data) {
    m_audioDecoder->decode(data);
}
