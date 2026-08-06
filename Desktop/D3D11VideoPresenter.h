#pragma once

// Do NOT wrap in #ifdef _WIN32 — AutoMoc cannot resolve preprocessor guards
// and will skip Q_OBJECT, causing linker errors. CMake only adds this header
// on Windows targets.

#include "HardwareVideoFrame.h"
#include "LatestValueMailbox.h"

#include <QWidget>
#include <QSize>
#include <QString>

#include <atomic>
#include <cstdint>

struct ID3D11Device;
struct ID3D11DeviceContext;
struct ID3D11Texture2D;
struct ID3D11RenderTargetView;
struct ID3D11ShaderResourceView;
struct ID3D11VertexShader;
struct ID3D11PixelShader;
struct ID3D11InputLayout;
struct ID3D11Buffer;
struct ID3D11SamplerState;
struct ID3D11BlendState;
struct ID3D11RasterizerState;
struct IDXGISwapChain1;

/// Presents NV12 D3D11 decode textures without a CPU round-trip.
class D3D11VideoPresenter : public QWidget {
    Q_OBJECT

public:
    explicit D3D11VideoPresenter(QWidget* parent = nullptr);
    ~D3D11VideoPresenter() override;

    QSize videoSize() const { return m_videoSize; }
    bool isReady() const { return m_swapChain != nullptr; }

signals:
    void videoSizeChanged(QSize size);
    void framePresented(
        quint64 streamId,
        quint64 sequence,
        quint64 presentationTimestampNanoseconds
    );
    /// Emitted when the D3D present path cannot show frames; caller should
    /// fall back to CPU/OpenGL presentation.
    void presentFailed(const QString& reason);

public slots:
    void onHardwareFrame(const HardwareVideoFrame& frame);

protected:
    void showEvent(QShowEvent* event) override;
    void hideEvent(QHideEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;
    void moveEvent(QMoveEvent* event) override;
    bool event(QEvent* event) override;
    bool eventFilter(QObject* watched, QEvent* event) override;
    QPaintEngine* paintEngine() const override { return nullptr; }

private:
    bool ensureDevice();
    bool ensurePresentHwnd();
    bool syncPresentHwndGeometry();
    void releasePresentHwnd();
    void installWindowTracker();
    void removeWindowTracker();
    void* topLevelHwnd() const;
    bool ensureSwapChain();
    bool ensurePipeline();
    bool ensureDisplayTexture(int width, int height);
    void releaseSwapChain();
    void releaseDisplayTexture();
    void releasePipeline();
    void presentPendingFrame();
    void drawLetterboxed();
    void failPresent(const QString& reason);

    ID3D11Device* m_device = nullptr;
    ID3D11DeviceContext* m_context = nullptr;

    void* m_presentHwnd = nullptr;
    QWidget* m_trackedWindow = nullptr;

    IDXGISwapChain1* m_swapChain = nullptr;
    ID3D11Texture2D* m_backBuffer = nullptr;
    ID3D11RenderTargetView* m_rtv = nullptr;
    int m_swapWidth = 0;
    int m_swapHeight = 0;

    ID3D11Texture2D* m_displayTexture = nullptr;
    ID3D11ShaderResourceView* m_srvY = nullptr;
    ID3D11ShaderResourceView* m_srvUV = nullptr;
    int m_texWidth = 0;
    int m_texHeight = 0;

    ID3D11VertexShader* m_vertexShader = nullptr;
    ID3D11PixelShader* m_pixelShader = nullptr;
    ID3D11InputLayout* m_inputLayout = nullptr;
    ID3D11Buffer* m_vertexBuffer = nullptr;
    ID3D11Buffer* m_constantBuffer = nullptr;
    ID3D11SamplerState* m_sampler = nullptr;
    ID3D11RasterizerState* m_rasterizer = nullptr;

    QSize m_videoSize;
    video_color::Parameters m_colorParameters = video_color::parametersFor(
        video_color::Range::unspecified,
        video_color::Matrix::bt709
    );

    LatestValueMailbox<HardwareVideoFrame> m_pendingFrame;
    std::atomic_bool m_updatePending{false};
    std::atomic_bool m_failed{false};
    int m_copyFailCount = 0;
    bool m_loggedFirstPresent = false;
    QString m_swapEffectLabel;
};
