#pragma once

#include "VideoColorConversion.h"
#include "DecodedVideoFrame.h"
#include "LatestValueMailbox.h"

#include <QOpenGLWidget>
#include <QOpenGLFunctions>
#include <QOpenGLShaderProgram>
#include <QOpenGLTexture>
#include <QSize>

#include <atomic>

class VideoRenderer : public QOpenGLWidget, protected QOpenGLFunctions {
    Q_OBJECT

public:
    explicit VideoRenderer(QWidget* parent = nullptr);
    ~VideoRenderer();

    QSize videoSize() const { return m_videoSize; }

signals:
    void videoSizeChanged(QSize size);
    void framePresented(
        quint64 streamId,
        quint64 sequence,
        quint64 presentationTimestampNanoseconds
    );

public slots:
    void onFrameDecoded(const DecodedVideoFrame& frame);

protected:
    void initializeGL() override;
    void paintGL() override;
    void resizeGL(int w, int h) override;

private:
    void createTextures(int width, int height);
    void deleteTextures();

    QOpenGLShaderProgram* m_program = nullptr;

    // YUV textures (NV12: Y plane + UV interleaved plane)
    GLuint m_textureY = 0;
    GLuint m_textureUV = 0;

    // Vertex buffer
    GLuint m_vbo = 0;

    // Frame dimensions
    QSize m_videoSize;
    int m_texWidth = 0;
    int m_texHeight = 0;

    LatestValueMailbox<DecodedVideoFrame> m_pendingFrame;
    std::atomic_bool m_updatePending{false};
    video_color::Parameters m_colorParameters = video_color::parametersFor(
        video_color::Range::unspecified,
        video_color::Matrix::bt709
    );
};
