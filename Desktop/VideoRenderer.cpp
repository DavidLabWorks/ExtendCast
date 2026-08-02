#include "VideoRenderer.h"
#include <QDebug>
#include <QVector4D>

// Vertex data: position (x,y) + texcoord (u,v)
static const float kVertexData[] = {
    // pos      // tex
    -1.0f,  1.0f,  0.0f, 0.0f,  // top-left
    -1.0f, -1.0f,  0.0f, 1.0f,  // bottom-left
     1.0f,  1.0f,  1.0f, 0.0f,  // top-right
     1.0f, -1.0f,  1.0f, 1.0f,  // bottom-right
};

// NV12 YUV->RGB shader (Compatibility Profile / GLSL 1.20)
static const char* kVertexShaderSource = R"(
    attribute vec4 aPosition;
    attribute vec2 aTexCoord;
    varying vec2 vTexCoord;
    uniform vec4 uViewport; // x_offset, y_offset, width, height (normalized)
    void main() {
        vec2 pos = aPosition.xy * vec2(uViewport.z, uViewport.w) + vec2(uViewport.x, uViewport.y);
        gl_Position = vec4(pos, 0.0, 1.0);
        vTexCoord = aTexCoord;
    }
)";

static const char* kFragmentShaderSource = R"(
    varying highp vec2 vTexCoord;
    uniform sampler2D uTextureY;
    uniform sampler2D uTextureUV;
    // x = Y offset, y = Y scale, z = UV offset, w = UV scale.
    uniform highp vec4 uRangeParameters;
    // x = R from V, y = G from U, z = G from V, w = B from U.
    uniform highp vec4 uMatrixCoefficients;
    void main() {
        highp float y = texture2D(uTextureY, vTexCoord).r;
        // GL_LUMINANCE_ALPHA: luminance->rgb, alpha->a
        // NV12 interleaved: first byte=U(Cb), second byte=V(Cr)
        // So .r = U (luminance), .a = V (alpha)
        highp vec2 uv = texture2D(uTextureUV, vTexCoord).ra;

        highp float normalizedY =
            (y - uRangeParameters.x) * uRangeParameters.y;
        highp vec2 normalizedUV =
            (uv - vec2(uRangeParameters.z)) * uRangeParameters.w;

        highp float r = normalizedY
            + uMatrixCoefficients.x * normalizedUV.y;
        highp float g = normalizedY
            + uMatrixCoefficients.y * normalizedUV.x
            + uMatrixCoefficients.z * normalizedUV.y;
        highp float b = normalizedY
            + uMatrixCoefficients.w * normalizedUV.x;

        gl_FragColor = vec4(r, g, b, 1.0);
    }
)";

VideoRenderer::VideoRenderer(QWidget* parent)
    : QOpenGLWidget(parent)
{
}

VideoRenderer::~VideoRenderer() {
    if (context()) {
        makeCurrent();
        deleteTextures();
        if (m_vbo) {
            glDeleteBuffers(1, &m_vbo);
        }
        doneCurrent();
    }
    delete m_program;
}

void VideoRenderer::initializeGL() {
    initializeOpenGLFunctions();

    qDebug() << "OpenGL version:" << reinterpret_cast<const char*>(glGetString(GL_VERSION));
    qDebug() << "OpenGL renderer:" << reinterpret_cast<const char*>(glGetString(GL_RENDERER));

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);

    // Compile shaders
    m_program = new QOpenGLShaderProgram(this);
    if (!m_program->addShaderFromSourceCode(QOpenGLShader::Vertex, kVertexShaderSource)) {
        qWarning() << "Vertex shader compile failed:" << m_program->log();
    }
    if (!m_program->addShaderFromSourceCode(QOpenGLShader::Fragment, kFragmentShaderSource)) {
        qWarning() << "Fragment shader compile failed:" << m_program->log();
    }
    m_program->bindAttributeLocation("aPosition", 0);
    m_program->bindAttributeLocation("aTexCoord", 1);
    if (!m_program->link()) {
        qWarning() << "Shader link failed:" << m_program->log();
    }

    // Create VBO
    glGenBuffers(1, &m_vbo);
    glBindBuffer(GL_ARRAY_BUFFER, m_vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(kVertexData), kVertexData, GL_STATIC_DRAW);
}

void VideoRenderer::resizeGL(int w, int h) {
    glViewport(0, 0, w, h);
}

void VideoRenderer::paintGL() {
    glClear(GL_COLOR_BUFFER_BIT);

    m_updatePending.store(false);
    auto pendingFrame = m_pendingFrame.take();
    if (pendingFrame.has_value()) {
        const auto& frame = *pendingFrame;
        if (m_texWidth != frame.width || m_texHeight != frame.height) {
            createTextures(frame.width, frame.height);
        }

        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glBindTexture(GL_TEXTURE_2D, m_textureY);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, frame.width, frame.height,
                        GL_LUMINANCE, GL_UNSIGNED_BYTE, frame.yPlane.constData());

        glBindTexture(GL_TEXTURE_2D, m_textureUV);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, frame.width / 2, frame.height / 2,
                        GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, frame.uvPlane.constData());
        m_colorParameters = frame.colorParameters;
        const QSize newSize(frame.width, frame.height);
        if (m_videoSize != newSize) {
            m_videoSize = newSize;
            emit videoSizeChanged(newSize);
        }
        emit framePresented(
            frame.streamId,
            frame.sequence,
            frame.presentationTimestampNanoseconds
        );
    }

    if (m_texWidth == 0) return;

    // Calculate aspect-ratio-correct viewport (letterboxing)
    float widgetAspect = static_cast<float>(width()) / static_cast<float>(height());
    float videoAspect = static_cast<float>(m_texWidth) / static_cast<float>(m_texHeight);

    float scaleX = 1.0f, scaleY = 1.0f;
    float offsetX = 0.0f, offsetY = 0.0f;

    if (videoAspect > widgetAspect) {
        scaleY = widgetAspect / videoAspect;
    } else {
        scaleX = videoAspect / widgetAspect;
    }

    const auto colorParameters = m_colorParameters;

    m_program->bind();

    m_program->setUniformValue("uViewport", offsetX, offsetY, scaleX, scaleY);
    m_program->setUniformValue(
        "uRangeParameters",
        QVector4D(
            colorParameters.yOffset,
            colorParameters.yScale,
            colorParameters.uvOffset,
            colorParameters.uvScale
        )
    );
    m_program->setUniformValue(
        "uMatrixCoefficients",
        QVector4D(
            colorParameters.redFromV,
            colorParameters.greenFromU,
            colorParameters.greenFromV,
            colorParameters.blueFromU
        )
    );

    // Bind textures
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, m_textureY);
    m_program->setUniformValue("uTextureY", 0);

    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, m_textureUV);
    m_program->setUniformValue("uTextureUV", 1);

    // Draw
    glBindBuffer(GL_ARRAY_BUFFER, m_vbo);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), nullptr);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                          reinterpret_cast<const void*>(2 * sizeof(float)));

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);

    m_program->release();
}

void VideoRenderer::onFrameDecoded(const DecodedVideoFrame& frame) {
    if (frame.width <= 0 || frame.height <= 0) return;

    m_pendingFrame.replace(frame);
    if (!m_updatePending.exchange(true)) {
        QMetaObject::invokeMethod(this, QOverload<>::of(&QWidget::update), Qt::QueuedConnection);
    }
}

void VideoRenderer::createTextures(int width, int height) {
    deleteTextures();

    // Y texture (luminance, full resolution)
    glGenTextures(1, &m_textureY);
    glBindTexture(GL_TEXTURE_2D, m_textureY);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, width, height, 0,
                 GL_LUMINANCE, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    // UV texture (luminance-alpha, half resolution)
    glGenTextures(1, &m_textureUV);
    glBindTexture(GL_TEXTURE_2D, m_textureUV);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE_ALPHA, width / 2, height / 2, 0,
                 GL_LUMINANCE_ALPHA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    m_texWidth = width;
    m_texHeight = height;

    qDebug() << "Created textures:" << width << "x" << height;
}

void VideoRenderer::deleteTextures() {
    if (m_textureY) {
        glDeleteTextures(1, &m_textureY);
        m_textureY = 0;
    }
    if (m_textureUV) {
        glDeleteTextures(1, &m_textureUV);
        m_textureUV = 0;
    }
    m_texWidth = 0;
    m_texHeight = 0;
}
