#include "ReceiverSession.h"

#include "AudioDecoder.h"
#include "AudioPlayer.h"
#include "InputHandler.h"
#include "MainWindow.h"
#include "VideoDecoder.h"
#include "VideoRenderer.h"
#include "VideoWindow.h"

#ifdef _WIN32
#include "D3D11SharedDevice.h"
#include "D3D11VideoPresenter.h"
#include "HardwareVideoFrame.h"
#endif

#include <QSize>
#include <QStackedWidget>

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
{
    m_presentStack = new QStackedWidget();
    m_presentStack->addWidget(m_renderer);
    m_videoSurface = m_presentStack;

#ifdef _WIN32
    qRegisterMetaType<HardwareVideoFrame>("HardwareVideoFrame");
    const bool disableZeroCopy =
        qEnvironmentVariableIsSet("EXTENDCAST_DISABLE_ZERO_COPY");
    if (!disableZeroCopy && D3D11SharedDevice::instance().ensureCreated()) {
        m_d3dPresenter = new D3D11VideoPresenter();
        m_presentStack->addWidget(m_d3dPresenter);
        m_presentStack->setCurrentWidget(m_d3dPresenter);
        m_decoder->setZeroCopyPresent(true);
        m_usingZeroCopyPresent = true;
        LogManager::instance().log(
            "Receiver: Using D3D11 zero-copy presenter on popup overlay HWND "
            "(set EXTENDCAST_DISABLE_ZERO_COPY=1 to force OpenGL)"
        );
    } else if (D3D11SharedDevice::instance().ensureCreated()) {
        LogManager::instance().log(
            "Receiver: D3D11 decode available — presenting via OpenGL "
            "(zero-copy disabled by env)"
        );
        m_decoder->setZeroCopyPresent(false);
    } else {
        m_decoder->setZeroCopyPresent(false);
    }
#else
    m_decoder->setZeroCopyPresent(false);
#endif

    m_window = new VideoWindow(m_videoSurface, m_inputHandler, ownerWindow);

    m_decoder->moveToThread(&m_decoderThread);
    m_decoderThread.setObjectName("ExtendCast video decoder");
    m_decoderThread.start(QThread::HighPriority);
    m_playbackAcknowledgementTimer.start();
    m_keyframeRequestCooldown.invalidate();

    m_window->bindToDevice(m_deviceId, m_deviceName);

    auto onPresented = [this](
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
    };

    auto onVideoSizeChanged = [this](QSize size) {
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
    };

#ifdef _WIN32
    if (m_usingZeroCopyPresent && m_d3dPresenter) {
        connectZeroCopyPresentPath();
        connect(
            m_d3dPresenter,
            &D3D11VideoPresenter::framePresented,
            this,
            onPresented
        );
        connect(
            m_d3dPresenter,
            &D3D11VideoPresenter::videoSizeChanged,
            this,
            onVideoSizeChanged
        );
        connect(
            m_d3dPresenter,
            &D3D11VideoPresenter::presentFailed,
            this,
            [this](const QString& reason) {
                fallbackPresentToOpenGL(reason);
            }
        );
        m_inputHandler->attach(m_d3dPresenter);
    } else {
        connectOpenGLPresentPath();
        m_inputHandler->attach(m_renderer);
    }
#else
    connectOpenGLPresentPath();
    m_inputHandler->attach(m_renderer);
#endif

    connect(
        m_renderer,
        &VideoRenderer::framePresented,
        this,
        onPresented
    );
    connect(
        m_renderer,
        &VideoRenderer::videoSizeChanged,
        this,
        onVideoSizeChanged
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

void ReceiverSession::connectOpenGLPresentPath() {
    connect(
        m_decoder,
        &VideoDecoder::frameDecoded,
        m_renderer,
        &VideoRenderer::onFrameDecoded,
        Qt::DirectConnection
    );
}

#ifdef _WIN32
void ReceiverSession::connectZeroCopyPresentPath() {
    connect(
        m_decoder,
        &VideoDecoder::hardwareFrameDecoded,
        m_d3dPresenter,
        &D3D11VideoPresenter::onHardwareFrame,
        Qt::QueuedConnection
    );
}

void ReceiverSession::fallbackPresentToOpenGL(const QString& reason) {
    if (!m_usingZeroCopyPresent) {
        return;
    }
    m_usingZeroCopyPresent = false;
    LogManager::instance().log(
        QString("Receiver: Falling back to OpenGL present — %1").arg(reason)
    );

    if (m_d3dPresenter) {
        disconnect(
            m_decoder,
            &VideoDecoder::hardwareFrameDecoded,
            m_d3dPresenter,
            &D3D11VideoPresenter::onHardwareFrame
        );
        disconnect(
            m_d3dPresenter,
            &D3D11VideoPresenter::presentFailed,
            this,
            nullptr
        );
    }

    m_decoder->setZeroCopyPresent(false);
    connectOpenGLPresentPath();
    if (m_presentStack && m_renderer) {
        m_presentStack->setCurrentWidget(m_renderer);
    }
    if (m_d3dPresenter) {
        m_d3dPresenter->hide();
    }
    if (m_renderer) {
        m_inputHandler->attach(m_renderer);
    }

    // Force a fresh IDR so the OpenGL path gets a clean access unit soon.
    requestKeyframeThrottled("zero-copy present fallback");
}
#endif

ReceiverSession::~ReceiverSession() {
    m_videoDecodeQueue.clearForStreamReset();

    if (m_decoder) {
        disconnect(m_decoder, nullptr, m_renderer, nullptr);
#ifdef _WIN32
        if (m_d3dPresenter) {
            disconnect(m_decoder, nullptr, m_d3dPresenter, nullptr);
        }
#endif
        disconnect(m_decoder, nullptr, this, nullptr);
    }
    if (m_renderer) {
        disconnect(m_renderer, nullptr, this, nullptr);
    }
#ifdef _WIN32
    if (m_d3dPresenter) {
        disconnect(m_d3dPresenter, nullptr, this, nullptr);
    }
#endif

    if (m_decoder && m_decoderThread.isRunning()) {
        // Drain decoder GPU/GL-touching state on its thread before teardown.
        QMetaObject::invokeMethod(
            m_decoder,
            [decoder = m_decoder]() { decoder->reset(); },
            Qt::BlockingQueuedConnection
        );
        m_decoderThread.quit();
        m_decoderThread.wait(5000);
        m_decoder->moveToThread(QThread::currentThread());
        delete m_decoder;
        m_decoder = nullptr;
    } else if (m_decoder) {
        delete m_decoder;
        m_decoder = nullptr;
    }

    if (m_window) {
        m_window->hide();
        delete m_window;
        m_window = nullptr;
    }
    // Stack owns the renderer / optional D3D presenter widgets.
    delete m_presentStack;
    m_presentStack = nullptr;
    m_videoSurface = nullptr;
#ifdef _WIN32
    m_d3dPresenter = nullptr;
#endif
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
