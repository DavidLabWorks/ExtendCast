#pragma once

#include <QObject>
#include <QByteArray>
#include <QSize>
#include <QString>

#include <atomic>

#include "DecodedVideoFrame.h"
#include "HardwareVideoFrame.h"

// Forward declarations for FFmpeg types
struct AVBufferRef;
struct AVCodecContext;
struct AVFrame;
struct AVPacket;

class VideoDecoder : public QObject {
    Q_OBJECT

public:
    explicit VideoDecoder(QObject* parent = nullptr);
    ~VideoDecoder();

    void decode(const QByteArray& data);
    /// Drop decoded refs and wait for an IDR. Keeps codec context alive.
    void flushForKeyframeResume();
    /// Tear down codec state. Only for new streams or unrecoverable errors.
    void reset();

    bool usingHardwareDecode() const { return m_usingHardware; }
    /// When true on Windows, emit GPU frames instead of CPU NV12 copies.
    void setZeroCopyPresent(bool enabled) { m_zeroCopyPresent.store(enabled); }
    /// Permanently use software decode for this session after D3D device loss.
    void disableHardwareDecode();

signals:
    void frameDecoded(const DecodedVideoFrame& frame);
    void hardwareFrameDecoded(const HardwareVideoFrame& frame);
    void zeroCopyPresentUnavailable(const QString& reason, bool deviceLost);
    void softwareDecodeFallbackReady();
    void dimensionsChanged(int width, int height);
    void keyframeNeeded();  // Emitted on decode errors — receiver should request IDR from sender

private:
    bool initDecoder(const uint8_t* sps, int spsLen, const uint8_t* pps, int ppsLen);
    bool openCodecContext(
        const uint8_t* sps,
        int spsLen,
        const uint8_t* pps,
        int ppsLen,
        bool preferHardware
    );
    bool ensureHardwareDevice();
    void destroyDecoder();
    void decodeNalus(
        const uint8_t* data,
        int size,
        const DecodedVideoFrame& metadata
    );
    QByteArray avccToAnnexB(const uint8_t* data, int size, int* naluCount = nullptr) const;
    bool reportHardwareDeviceLoss(bool probeDevice);

    AVBufferRef* m_hwDeviceCtx = nullptr;
    AVCodecContext* m_codecCtx = nullptr;
    AVFrame* m_frame = nullptr;
    AVFrame* m_transferFrame = nullptr;
    AVPacket* m_packet = nullptr;
    bool m_usingHardware = false;
    std::atomic_bool m_zeroCopyPresent{false};
    bool m_hardwareDecodeDisabled = false;
    bool m_hardwareDeviceLossReported = false;

    // Cached SPS/PPS (from current packet scan)
    QByteArray m_sps;
    QByteArray m_pps;
    // Active SPS/PPS (what the decoder was initialized with)
    QByteArray m_activeSps;
    QByteArray m_activePps;

    // Track dimensions for change detection (orientation switch)
    int m_currentWidth = 0;
    int m_currentHeight = 0;
    int m_decodeCallCount = 0;
    int m_sendCount = 0;
    int m_outputCount = 0;
};
