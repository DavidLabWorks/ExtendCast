#include "AudioDecoder.h"
#include <QDebug>
#include <cstring>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>
#include <libavutil/mem.h>
#include <libavutil/error.h>
}

AudioDecoder::AudioDecoder(QObject* parent)
    : QObject(parent)
{
}

AudioDecoder::~AudioDecoder() {
    destroyDecoder();
}

bool AudioDecoder::initDecoder() {
    const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_AAC);
    if (!codec) {
        qWarning() << "AudioDecoder: AAC decoder not found";
        return false;
    }

    m_codecCtx = avcodec_alloc_context3(codec);
    if (!m_codecCtx) return false;

    // Mac AudioEncoder sends raw AAC-LC frames (no ADTS). FFmpeg needs an
    // AudioSpecificConfig (ASC) in extradata before it will accept those
    // packets — otherwise avcodec_send_packet fails with Invalid data and
    // we get silent playback. Match the sender's documented 48 kHz stereo.
    static const uint8_t kAacLc48kStereoAsc[] = {0x11, 0x90};
    const int ascSize = static_cast<int>(sizeof(kAacLc48kStereoAsc));
    uint8_t* extradata = static_cast<uint8_t*>(
        av_malloc(ascSize + AV_INPUT_BUFFER_PADDING_SIZE)
    );
    if (!extradata) {
        avcodec_free_context(&m_codecCtx);
        return false;
    }
    memset(extradata, 0, ascSize + AV_INPUT_BUFFER_PADDING_SIZE);
    memcpy(extradata, kAacLc48kStereoAsc, ascSize);
    m_codecCtx->extradata = extradata;
    m_codecCtx->extradata_size = ascSize;

    if (avcodec_open2(m_codecCtx, codec, nullptr) < 0) {
        qWarning() << "AudioDecoder: Failed to open AAC decoder";
        avcodec_free_context(&m_codecCtx);
        return false;
    }

    m_frame = av_frame_alloc();
    m_packet = av_packet_alloc();
    m_initialized = true;

    qDebug() << "AudioDecoder: AAC decoder initialized (ASC 48kHz stereo LC)";
    return true;
}

void AudioDecoder::destroyDecoder() {
    if (m_frame) { av_frame_free(&m_frame); m_frame = nullptr; }
    if (m_packet) { av_packet_free(&m_packet); m_packet = nullptr; }
    if (m_codecCtx) { avcodec_free_context(&m_codecCtx); m_codecCtx = nullptr; }
    m_initialized = false;
}

void AudioDecoder::decode(const QByteArray& aacData) {
    // Skip tiny silence frames — they can confuse the decoder
    if (aacData.size() < 10) return;

    if (!m_initialized && !initDecoder()) return;

    m_packet->data = const_cast<uint8_t*>(reinterpret_cast<const uint8_t*>(aacData.constData()));
    m_packet->size = aacData.size();

    int ret = avcodec_send_packet(m_codecCtx, m_packet);
    if (ret < 0) {
        static int sendFailures = 0;
        if (sendFailures < 5) {
            char errbuf[128];
            av_strerror(ret, errbuf, sizeof(errbuf));
            qWarning() << "AudioDecoder: avcodec_send_packet failed:" << errbuf
                       << "size=" << aacData.size();
            ++sendFailures;
        }
        return;
    }

    while (ret >= 0) {
        ret = avcodec_receive_frame(m_codecCtx, m_frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        if (ret < 0) {
            qWarning() << "AudioDecoder: Decode error:" << ret;
            break;
        }

        // Convert decoded audio to interleaved float32 PCM
#if LIBAVUTIL_VERSION_MAJOR >= 58
        int channels = m_frame->ch_layout.nb_channels;
#else
        int channels = m_frame->channels;
#endif
        int samples = m_frame->nb_samples;
        int sampleRate = m_frame->sample_rate;

        if (channels <= 0 || channels > AV_NUM_DATA_POINTERS || samples <= 0 || sampleRate <= 0) {
            qWarning() << "AudioDecoder: Invalid decoded format:"
                       << sampleRate << "Hz" << channels << "ch" << samples << "samples";
            continue;
        }

        QByteArray pcm;

        if (m_frame->format == AV_SAMPLE_FMT_FLTP) {
            // Float planar → interleaved float32
            pcm.resize(samples * channels * sizeof(float));
            float* dst = reinterpret_cast<float*>(pcm.data());
            for (int s = 0; s < samples; s++) {
                for (int ch = 0; ch < channels; ch++) {
                    dst[s * channels + ch] = reinterpret_cast<float*>(m_frame->data[ch])[s];
                }
            }
        } else if (m_frame->format == AV_SAMPLE_FMT_FLT) {
            // Float interleaved — copy directly
            int size = samples * channels * sizeof(float);
            pcm = QByteArray(reinterpret_cast<const char*>(m_frame->data[0]), size);
        } else if (m_frame->format == AV_SAMPLE_FMT_S16) {
            // S16 interleaved → float32
            pcm.resize(samples * channels * sizeof(float));
            float* dst = reinterpret_cast<float*>(pcm.data());
            const int16_t* src = reinterpret_cast<const int16_t*>(m_frame->data[0]);
            for (int i = 0; i < samples * channels; i++) {
                dst[i] = static_cast<float>(src[i]) / 32768.0f;
            }
        } else if (m_frame->format == AV_SAMPLE_FMT_S16P) {
            // S16 planar → interleaved float32
            pcm.resize(samples * channels * sizeof(float));
            float* dst = reinterpret_cast<float*>(pcm.data());
            for (int s = 0; s < samples; s++) {
                for (int ch = 0; ch < channels; ch++) {
                    int16_t sample = reinterpret_cast<int16_t*>(m_frame->data[ch])[s];
                    dst[s * channels + ch] = static_cast<float>(sample) / 32768.0f;
                }
            }
        } else {
            qWarning() << "AudioDecoder: Unsupported sample format:" << m_frame->format;
            continue;
        }

        emit pcmDecoded(pcm, sampleRate, channels);
    }
}
