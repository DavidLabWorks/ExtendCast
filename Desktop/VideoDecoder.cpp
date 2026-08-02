#include "VideoDecoder.h"
#include "MainWindow.h"  // for LogManager
#include "VideoPacket.h"
#include <QDebug>
#include <QtEndian>
#include <cstring>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
}

VideoDecoder::VideoDecoder(QObject* parent)
    : QObject(parent)
{
}

VideoDecoder::~VideoDecoder() {
    destroyDecoder();
}

void VideoDecoder::decode(const QByteArray& data) {
    m_decodeCallCount++;

    constexpr int videoHeaderSize =
        static_cast<int>(video_packet::headerSize);

    if (data.size() <= videoHeaderSize) {
        if (m_decodeCallCount <= 5) {
            LogManager::instance().log(QString("Decoder: frame %1 too small (%2 bytes), skipping")
                .arg(m_decodeCallCount).arg(data.size()));
        }
        return;
    }

    const uint8_t* raw = reinterpret_cast<const uint8_t*>(data.constData());

    video_packet::Header header;
    if (!video_packet::parseHeader(
            raw,
            static_cast<std::size_t>(data.size()),
            header
        )) {
        return;
    }

    DecodedVideoFrame metadata;
    metadata.streamId = header.streamId;
    metadata.sequence = header.sequence;
    metadata.presentationTimestampNanoseconds =
        header.presentationTimestampNanoseconds;

    const uint8_t* videoData = raw + videoHeaderSize;
    int videoLen = data.size() - videoHeaderSize;

    // Scan for SPS/PPS in AVCC-framed NALUs: [4-byte big-endian length][NALU data]
    int offset = 0;
    int naluCount = 0;
    while (offset + 4 <= videoLen) {
        uint32_t naluLen = qFromBigEndian<uint32_t>(videoData + offset);
        if (naluLen == 0 || offset + 4 + static_cast<int>(naluLen) > videoLen) {
            if (m_decodeCallCount <= 5) {
                LogManager::instance().log(QString("Decoder: frame %1 NALU scan stopped at offset %2, naluLen=%3, videoLen=%4")
                    .arg(m_decodeCallCount).arg(offset).arg(naluLen).arg(videoLen));
            }
            break;
        }

        uint8_t naluType = videoData[offset + 4] & 0x1F;
        naluCount++;

        if (m_decodeCallCount <= 3) {
            LogManager::instance().log(QString("Decoder: frame %1 NALU #%2: type=%3, len=%4")
                .arg(m_decodeCallCount).arg(naluCount).arg(naluType).arg(naluLen));
        }

        if (naluType == 7) { // SPS
            m_sps = QByteArray(reinterpret_cast<const char*>(videoData + offset + 4),
                               static_cast<int>(naluLen));
            LogManager::instance().log(QString("Decoder: Got SPS (%1 bytes)").arg(naluLen));
        } else if (naluType == 8) { // PPS
            m_pps = QByteArray(reinterpret_cast<const char*>(videoData + offset + 4),
                               static_cast<int>(naluLen));
            LogManager::instance().log(QString("Decoder: Got PPS (%1 bytes)").arg(naluLen));
        }

        offset += 4 + static_cast<int>(naluLen);
    }

    // Initialize or reinitialize decoder if we have SPS/PPS
    if (!m_sps.isEmpty() && !m_pps.isEmpty()) {
        bool needsInit = !m_codecCtx;
        // Also reinit if SPS/PPS changed (new stream or resolution change)
        if (m_codecCtx && (m_sps != m_activeSps || m_pps != m_activePps)) {
            LogManager::instance().log("Decoder: SPS/PPS changed — reinitializing for new stream");
            destroyDecoder();
            needsInit = true;
        }
        if (needsInit) {
            LogManager::instance().log(QString("Decoder: Initializing with SPS(%1) + PPS(%2)")
                .arg(m_sps.size()).arg(m_pps.size()));
            if (initDecoder(reinterpret_cast<const uint8_t*>(m_sps.constData()), m_sps.size(),
                            reinterpret_cast<const uint8_t*>(m_pps.constData()), m_pps.size())) {
                m_activeSps = m_sps;
                m_activePps = m_pps;
            }
        }
    }

    if (m_codecCtx) {
        decodeNalus(videoData, videoLen, metadata);
    } else if (m_decodeCallCount <= 10) {
        LogManager::instance().log(QString("Decoder: frame %1 — no codec context yet (waiting for SPS/PPS)")
            .arg(m_decodeCallCount));
    }
}

bool VideoDecoder::initDecoder(const uint8_t* sps, int spsLen, const uint8_t* pps, int ppsLen) {
    // Build extradata in AVCC format for FFmpeg
    // Format: [1 byte version][1 byte profile][1 byte compat][1 byte level]
    //         [1 byte NALU length size - 1][1 byte num SPS | 0xE0]
    //         [2 byte SPS length][SPS data]
    //         [1 byte num PPS][2 byte PPS length][PPS data]

    if (spsLen < 4) return false;

    int extradataSize = 6 + 2 + spsLen + 1 + 2 + ppsLen;
    uint8_t* extradata = static_cast<uint8_t*>(av_malloc(extradataSize + AV_INPUT_BUFFER_PADDING_SIZE));
    if (!extradata) return false;
    memset(extradata, 0, extradataSize + AV_INPUT_BUFFER_PADDING_SIZE);

    int idx = 0;
    extradata[idx++] = 1;           // version
    extradata[idx++] = sps[1];     // profile
    extradata[idx++] = sps[2];     // compatibility
    extradata[idx++] = sps[3];     // level
    extradata[idx++] = 0xFF;       // 4 bytes NALU length size (0xFF = 3 + 1)
    extradata[idx++] = 0xE1;       // 1 SPS (0xE0 | 1)
    extradata[idx++] = static_cast<uint8_t>((spsLen >> 8) & 0xFF);
    extradata[idx++] = static_cast<uint8_t>(spsLen & 0xFF);
    memcpy(extradata + idx, sps, spsLen);
    idx += spsLen;
    extradata[idx++] = 1;          // 1 PPS
    extradata[idx++] = static_cast<uint8_t>((ppsLen >> 8) & 0xFF);
    extradata[idx++] = static_cast<uint8_t>(ppsLen & 0xFF);
    memcpy(extradata + idx, pps, ppsLen);

    const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_H264);
    if (!codec) {
        qWarning() << "H.264 decoder not found";
        av_free(extradata);
        return false;
    }

    // If we already have a context, check for dimension change
    if (m_codecCtx) {
        // We'll destroy and recreate — dimension change detected via SPS
        destroyDecoder();
    }

    m_codecCtx = avcodec_alloc_context3(codec);
    if (!m_codecCtx) {
        av_free(extradata);
        return false;
    }

    m_codecCtx->extradata = extradata;
    m_codecCtx->extradata_size = extradataSize;

    // Low latency settings with error resilience
    m_codecCtx->flags |= AV_CODEC_FLAG_LOW_DELAY;
    m_codecCtx->flags2 |= AV_CODEC_FLAG2_FAST;
    m_codecCtx->thread_count = 2;
    m_codecCtx->thread_type = FF_THREAD_SLICE;
    m_codecCtx->skip_loop_filter = AVDISCARD_NONREF;

    // Error concealment — show best-effort frames instead of artifacts
    m_codecCtx->err_recognition = 0;  // Don't reject frames with errors
    m_codecCtx->error_concealment = FF_EC_GUESS_MVS | FF_EC_DEBLOCK;

    if (avcodec_open2(m_codecCtx, codec, nullptr) < 0) {
        qWarning() << "Failed to open H.264 decoder";
        avcodec_free_context(&m_codecCtx);
        return false;
    }

    m_frame = av_frame_alloc();
    m_packet = av_packet_alloc();

    qDebug() << "H.264 decoder initialized";
    return true;
}

void VideoDecoder::reset() {
    LogManager::instance().log("Decoder: reset — clearing state for new stream");
    destroyDecoder();
    m_sps.clear();
    m_pps.clear();
    m_activeSps.clear();
    m_activePps.clear();
}

void VideoDecoder::destroyDecoder() {
    if (m_frame) {
        av_frame_free(&m_frame);
        m_frame = nullptr;
    }
    if (m_packet) {
        av_packet_free(&m_packet);
        m_packet = nullptr;
    }
    if (m_codecCtx) {
        avcodec_free_context(&m_codecCtx);
        m_codecCtx = nullptr;
    }
    m_currentWidth = 0;
    m_currentHeight = 0;
}

QByteArray VideoDecoder::avccToAnnexB(const uint8_t* data, int size, int* naluCount) const {
    QByteArray converted;
    int offset = 0;
    int count = 0;

    while (offset + 4 <= size) {
        const uint32_t naluLen = qFromBigEndian<uint32_t>(data + offset);
        offset += 4;

        if (naluLen == 0 || naluLen > static_cast<uint32_t>(size - offset)) {
            converted.clear();
            break;
        }

        static constexpr char kStartCode[] = {0x00, 0x00, 0x00, 0x01};
        converted.append(kStartCode, sizeof(kStartCode));
        converted.append(reinterpret_cast<const char*>(data + offset), static_cast<int>(naluLen));
        offset += static_cast<int>(naluLen);
        count++;
    }

    if (offset != size) {
        converted.clear();
    }

    if (naluCount) {
        *naluCount = converted.isEmpty() ? 0 : count;
    }
    return converted;
}

void VideoDecoder::decodeNalus(
    const uint8_t* data,
    int size,
    const DecodedVideoFrame& metadata
) {
    int naluCount = 0;
    QByteArray packetData = avccToAnnexB(data, size, &naluCount);
    if (packetData.isEmpty()) {
        LogManager::instance().log(QString("Decoder: invalid AVCC packet (%1 bytes), requesting keyframe").arg(size));
        avcodec_flush_buffers(m_codecCtx);
        emit keyframeNeeded();
        return;
    }

    if (m_sendCount < 3) {
        LogManager::instance().log(QString("Decoder: converted AVCC to Annex-B (%1 NALUs, %2 -> %3 bytes)")
            .arg(naluCount).arg(size).arg(packetData.size()));
    }

    m_sendCount++;
    av_packet_unref(m_packet);
    int packetRet = av_new_packet(m_packet, packetData.size());
    if (packetRet < 0) {
        LogManager::instance().log(QString("Decoder: av_new_packet failed: %1").arg(packetRet));
        return;
    }
    memcpy(m_packet->data, packetData.constData(), packetData.size());

    int ret = avcodec_send_packet(m_codecCtx, m_packet);
    av_packet_unref(m_packet);
    if (ret < 0) {
        if (m_sendCount <= 10 || m_sendCount % 100 == 0) {
            LogManager::instance().log(QString("Decoder: send_packet #%1 failed: %2")
                .arg(m_sendCount).arg(ret));
        }
        if (ret == AVERROR_INVALIDDATA) {
            avcodec_flush_buffers(m_codecCtx);
            emit keyframeNeeded();
        }
        return;
    }

    while (ret >= 0) {
        ret = avcodec_receive_frame(m_codecCtx, m_frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            break;
        }
        if (ret < 0) {
            if (m_outputCount <= 5) {
                LogManager::instance().log(QString("Decoder: receive_frame error: %1").arg(ret));
            }
            break;
        }

        m_outputCount++;
        if (m_outputCount <= 3 || m_outputCount % 300 == 0) {
            LogManager::instance().log(QString("Decoder: decoded frame #%1 — %2x%3 format=%4")
                .arg(m_outputCount).arg(m_frame->width).arg(m_frame->height).arg(m_frame->format));
        }

        // Check for dimension change (orientation switch)
        if (m_frame->width != m_currentWidth || m_frame->height != m_currentHeight) {
            m_currentWidth = m_frame->width;
            m_currentHeight = m_frame->height;
            LogManager::instance().log(QString("Decoder: dimensions changed to %1x%2")
                .arg(m_currentWidth).arg(m_currentHeight));
            emit dimensionsChanged(m_currentWidth, m_currentHeight);
        }

        DecodedVideoFrame decoded = metadata;
        decoded.width = m_frame->width;
        decoded.height = m_frame->height;
        decoded.colorParameters = video_color::parametersFor(
            m_frame->color_range == AVCOL_RANGE_JPEG
                || m_frame->format == AV_PIX_FMT_YUVJ420P
                ? video_color::Range::full
                : video_color::Range::unspecified,
            m_frame->colorspace == AVCOL_SPC_SMPTE170M
                || m_frame->colorspace == AVCOL_SPC_BT470BG
                ? video_color::Matrix::bt601
                : video_color::Matrix::bt709
        );
        decoded.yPlane.resize(decoded.width * decoded.height);
        decoded.uvPlane.resize(decoded.width * decoded.height / 2);

        for (int row = 0; row < decoded.height; ++row) {
            memcpy(
                decoded.yPlane.data() + row * decoded.width,
                m_frame->data[0] + row * m_frame->linesize[0],
                decoded.width
            );
        }
        const int chromaHeight = decoded.height / 2;
        if (m_frame->format == AV_PIX_FMT_NV12) {
            for (int row = 0; row < chromaHeight; ++row) {
                memcpy(
                    decoded.uvPlane.data() + row * decoded.width,
                    m_frame->data[1] + row * m_frame->linesize[1],
                    decoded.width
                );
            }
        } else if (m_frame->format == AV_PIX_FMT_YUV420P
                   || m_frame->format == AV_PIX_FMT_YUVJ420P) {
            const int chromaWidth = decoded.width / 2;
            for (int row = 0; row < chromaHeight; ++row) {
                const uint8_t* u =
                    m_frame->data[1] + row * m_frame->linesize[1];
                const uint8_t* v =
                    m_frame->data[2] + row * m_frame->linesize[2];
                char* destination =
                    decoded.uvPlane.data() + row * decoded.width;
                for (int column = 0; column < chromaWidth; ++column) {
                    destination[column * 2] = static_cast<char>(u[column]);
                    destination[column * 2 + 1] = static_cast<char>(v[column]);
                }
            }
        } else {
            LogManager::instance().log(
                QString("Decoder: unsupported output format %1")
                    .arg(m_frame->format)
            );
            continue;
        }

        emit frameDecoded(decoded);
    }
}
