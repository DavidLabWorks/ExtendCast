#ifdef _WIN32

#include "D3D11VideoPresenter.h"
#include "D3D11SharedDevice.h"
#include "MainWindow.h"

#include <QResizeEvent>
#include <QShowEvent>
#include <QStackedWidget>

#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <dxgi1_2.h>

#include <cstring>

namespace {

struct Vertex {
    float x, y, u, v;
};

struct Constants {
    float viewport[4];       // offsetX, offsetY, scaleX, scaleY
    float rangeParameters[4];
    float matrixCoefficients[4];
};

static const char* kVertexShader = R"(
cbuffer Constants : register(b0) {
    float4 uViewport;
    float4 uRangeParameters;
    float4 uMatrixCoefficients;
};
struct VSInput {
    float2 position : POSITION;
    float2 texCoord : TEXCOORD0;
};
struct PSInput {
    float4 position : SV_POSITION;
    float2 texCoord : TEXCOORD0;
};
PSInput main(VSInput input) {
    PSInput output;
    float2 pos = input.position * uViewport.zw + uViewport.xy;
    output.position = float4(pos, 0.0f, 1.0f);
    output.texCoord = input.texCoord;
    return output;
}
)";

static const char* kPixelShader = R"(
cbuffer Constants : register(b0) {
    float4 uViewport;
    float4 uRangeParameters;
    float4 uMatrixCoefficients;
};
Texture2D texY : register(t0);
Texture2D texUV : register(t1);
SamplerState samp : register(s0);
struct PSInput {
    float4 position : SV_POSITION;
    float2 texCoord : TEXCOORD0;
};
float4 main(PSInput input) : SV_TARGET {
    float y = texY.Sample(samp, input.texCoord).r;
    float2 uv = texUV.Sample(samp, input.texCoord).rg;
    float normalizedY = (y - uRangeParameters.x) * uRangeParameters.y;
    float2 normalizedUV = (uv - uRangeParameters.z) * uRangeParameters.w;
    float r = normalizedY + uMatrixCoefficients.x * normalizedUV.y;
    float g = normalizedY
        + uMatrixCoefficients.y * normalizedUV.x
        + uMatrixCoefficients.z * normalizedUV.y;
    float b = normalizedY + uMatrixCoefficients.w * normalizedUV.x;
    return float4(r, g, b, 1.0f);
}
)";

template <typename T>
void releaseCom(T*& ptr) {
    if (ptr) {
        ptr->Release();
        ptr = nullptr;
    }
}

}  // namespace

D3D11VideoPresenter::D3D11VideoPresenter(QWidget* parent)
    : QWidget(parent)
{
    setAttribute(Qt::WA_NativeWindow);
    setAttribute(Qt::WA_PaintOnScreen);
    setAttribute(Qt::WA_OpaquePaintEvent);
    setAttribute(Qt::WA_NoSystemBackground);
    setAutoFillBackground(false);
    qRegisterMetaType<HardwareVideoFrame>("HardwareVideoFrame");
}

D3D11VideoPresenter::~D3D11VideoPresenter() {
    releaseDisplayTexture();
    releasePipeline();
    releaseSwapChain();
}

void D3D11VideoPresenter::onHardwareFrame(const HardwareVideoFrame& frame) {
    if (m_failed.load() || !frame.isValid()) {
        return;
    }
    m_pendingFrame.replace(frame);
    if (!m_updatePending.exchange(true)) {
        QMetaObject::invokeMethod(this, [this]() {
            presentPendingFrame();
        }, Qt::QueuedConnection);
    }
}

void D3D11VideoPresenter::showEvent(QShowEvent* event) {
    QWidget::showEvent(event);
    createWinId();
    ensureSwapChain();
    ensurePipeline();
}

void D3D11VideoPresenter::resizeEvent(QResizeEvent* event) {
    QWidget::resizeEvent(event);
    if (m_swapChain
        && (width() != m_swapWidth || height() != m_swapHeight)
        && width() > 0
        && height() > 0) {
        releaseCom(m_rtv);
        releaseCom(m_backBuffer);
        const HRESULT hr = m_swapChain->ResizeBuffers(
            0,
            static_cast<UINT>(width()),
            static_cast<UINT>(height()),
            DXGI_FORMAT_UNKNOWN,
            0
        );
        if (SUCCEEDED(hr)
            && SUCCEEDED(m_swapChain->GetBuffer(
                   0,
                   __uuidof(ID3D11Texture2D),
                   reinterpret_cast<void**>(&m_backBuffer)
               ))
            && SUCCEEDED(m_device->CreateRenderTargetView(
                   m_backBuffer,
                   nullptr,
                   &m_rtv
               ))) {
            m_swapWidth = width();
            m_swapHeight = height();
        } else {
            releaseSwapChain();
        }
    }
    if (m_updatePending.load() || m_texWidth > 0) {
        presentPendingFrame();
    }
}

void D3D11VideoPresenter::paintEvent(QPaintEvent*) {
    presentPendingFrame();
}

bool D3D11VideoPresenter::nativeEvent(
    const QByteArray& eventType,
    void* message,
    qintptr* result
) {
    Q_UNUSED(eventType);
    Q_UNUSED(message);
    Q_UNUSED(result);
    return false;
}

bool D3D11VideoPresenter::ensureDevice() {
    if (m_device && m_context) {
        return true;
    }
    auto& shared = D3D11SharedDevice::instance();
    if (!shared.ensureCreated()) {
        return false;
    }
    m_device = shared.device();
    m_context = shared.context();
    return m_device && m_context;
}

bool D3D11VideoPresenter::ensureSwapChain() {
    if (!ensureDevice()) {
        return false;
    }
    if (m_swapChain) {
        return true;
    }
    if (m_failed.load()) {
        return false;
    }

    createWinId();
    const WId wid = winId();
    if (!wid || width() <= 0 || height() <= 0) {
        return false;
    }

    IDXGIDevice* dxgiDevice = nullptr;
    HRESULT hr = m_device->QueryInterface(
        __uuidof(IDXGIDevice),
        reinterpret_cast<void**>(&dxgiDevice)
    );
    if (FAILED(hr) || !dxgiDevice) {
        failPresent(QString("QueryInterface IDXGIDevice hr=0x%1")
                        .arg(quint32(hr), 8, 16, QChar('0')));
        return false;
    }

    IDXGIAdapter* adapter = nullptr;
    hr = dxgiDevice->GetAdapter(&adapter);
    dxgiDevice->Release();
    if (FAILED(hr) || !adapter) {
        failPresent("GetAdapter failed");
        return false;
    }

    IDXGIFactory2* factory = nullptr;
    hr = adapter->GetParent(
        __uuidof(IDXGIFactory2),
        reinterpret_cast<void**>(&factory)
    );
    adapter->Release();
    if (FAILED(hr) || !factory) {
        failPresent("GetParent IDXGIFactory2 failed");
        return false;
    }

    // Flip-model swap chains are unreliable on Qt child HWNDs. Use the
    // discard model which is the supported path for embedded windows.
    DXGI_SWAP_CHAIN_DESC1 desc = {};
    desc.Width = static_cast<UINT>(width());
    desc.Height = static_cast<UINT>(height());
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.Scaling = DXGI_SCALING_STRETCH;
    desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;

    hr = factory->CreateSwapChainForHwnd(
        m_device,
        reinterpret_cast<HWND>(wid),
        &desc,
        nullptr,
        nullptr,
        &m_swapChain
    );
    if (FAILED(hr) || !m_swapChain) {
        // Older path for hosts that reject CreateSwapChainForHwnd variants.
        DXGI_SWAP_CHAIN_DESC legacy = {};
        legacy.BufferCount = 1;
        legacy.BufferDesc.Width = desc.Width;
        legacy.BufferDesc.Height = desc.Height;
        legacy.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        legacy.BufferDesc.RefreshRate.Numerator = 60;
        legacy.BufferDesc.RefreshRate.Denominator = 1;
        legacy.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        legacy.OutputWindow = reinterpret_cast<HWND>(wid);
        legacy.SampleDesc.Count = 1;
        legacy.Windowed = TRUE;
        legacy.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

        IDXGIFactory* factory1 = nullptr;
        if (SUCCEEDED(factory->QueryInterface(
                __uuidof(IDXGIFactory),
                reinterpret_cast<void**>(&factory1)
            ))
            && factory1) {
            IDXGISwapChain* legacyChain = nullptr;
            hr = factory1->CreateSwapChain(m_device, &legacy, &legacyChain);
            factory1->Release();
            if (SUCCEEDED(hr) && legacyChain) {
                hr = legacyChain->QueryInterface(
                    __uuidof(IDXGISwapChain1),
                    reinterpret_cast<void**>(&m_swapChain)
                );
                legacyChain->Release();
            }
        }
    }
    factory->MakeWindowAssociation(
        reinterpret_cast<HWND>(wid),
        DXGI_MWA_NO_ALT_ENTER
    );
    factory->Release();
    if (FAILED(hr) || !m_swapChain) {
        failPresent(
            QString("CreateSwapChain failed hr=0x%1")
                .arg(quint32(hr), 8, 16, QChar('0'))
        );
        m_swapChain = nullptr;
        return false;
    }

    hr = m_swapChain->GetBuffer(
        0,
        __uuidof(ID3D11Texture2D),
        reinterpret_cast<void**>(&m_backBuffer)
    );
    if (FAILED(hr) || !m_backBuffer) {
        failPresent("GetBuffer failed");
        releaseSwapChain();
        return false;
    }

    hr = m_device->CreateRenderTargetView(m_backBuffer, nullptr, &m_rtv);
    if (FAILED(hr) || !m_rtv) {
        failPresent("CreateRenderTargetView failed");
        releaseSwapChain();
        return false;
    }
    m_swapWidth = width();
    m_swapHeight = height();
    LogManager::instance().log(
        QString("D3D11: SwapChain ready %1x%2").arg(m_swapWidth).arg(m_swapHeight)
    );
    return true;
}

void D3D11VideoPresenter::failPresent(const QString& reason) {
    if (m_failed.exchange(true)) {
        return;
    }
    LogManager::instance().log(QString("D3D11: Present failed — %1").arg(reason));
    emit presentFailed(reason);
}

void D3D11VideoPresenter::releaseSwapChain() {
    releaseCom(m_rtv);
    releaseCom(m_backBuffer);
    releaseCom(m_swapChain);
    m_swapWidth = 0;
    m_swapHeight = 0;
}

bool D3D11VideoPresenter::ensurePipeline() {
    if (m_pixelShader) {
        return true;
    }
    if (!ensureDevice()) {
        return false;
    }

    ID3DBlob* vsBlob = nullptr;
    ID3DBlob* errorBlob = nullptr;
    HRESULT hr = D3DCompile(
        kVertexShader,
        std::strlen(kVertexShader),
        "vs",
        nullptr,
        nullptr,
        "main",
        "vs_5_0",
        0,
        0,
        &vsBlob,
        &errorBlob
    );
    if (FAILED(hr)) {
        if (errorBlob) {
            LogManager::instance().log(
                QString("D3D11 VS compile failed: %1")
                    .arg(reinterpret_cast<const char*>(errorBlob->GetBufferPointer()))
            );
            errorBlob->Release();
        }
        return false;
    }

    hr = m_device->CreateVertexShader(
        vsBlob->GetBufferPointer(),
        vsBlob->GetBufferSize(),
        nullptr,
        &m_vertexShader
    );
    if (FAILED(hr)) {
        vsBlob->Release();
        return false;
    }

    D3D11_INPUT_ELEMENT_DESC layout[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0},
    };
    hr = m_device->CreateInputLayout(
        layout,
        2,
        vsBlob->GetBufferPointer(),
        vsBlob->GetBufferSize(),
        &m_inputLayout
    );
    vsBlob->Release();
    if (FAILED(hr)) {
        releasePipeline();
        return false;
    }

    ID3DBlob* psBlob = nullptr;
    hr = D3DCompile(
        kPixelShader,
        std::strlen(kPixelShader),
        "ps",
        nullptr,
        nullptr,
        "main",
        "ps_5_0",
        0,
        0,
        &psBlob,
        &errorBlob
    );
    if (FAILED(hr)) {
        if (errorBlob) {
            LogManager::instance().log(
                QString("D3D11 PS compile failed: %1")
                    .arg(reinterpret_cast<const char*>(errorBlob->GetBufferPointer()))
            );
            errorBlob->Release();
        }
        releasePipeline();
        return false;
    }
    hr = m_device->CreatePixelShader(
        psBlob->GetBufferPointer(),
        psBlob->GetBufferSize(),
        nullptr,
        &m_pixelShader
    );
    psBlob->Release();
    if (FAILED(hr)) {
        releasePipeline();
        return false;
    }

    const Vertex vertices[] = {
        {-1.0f, 1.0f, 0.0f, 0.0f},
        {-1.0f, -1.0f, 0.0f, 1.0f},
        {1.0f, 1.0f, 1.0f, 0.0f},
        {1.0f, -1.0f, 1.0f, 1.0f},
    };
    D3D11_BUFFER_DESC vbDesc = {};
    vbDesc.ByteWidth = sizeof(vertices);
    vbDesc.Usage = D3D11_USAGE_IMMUTABLE;
    vbDesc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    D3D11_SUBRESOURCE_DATA vbData = {};
    vbData.pSysMem = vertices;
    hr = m_device->CreateBuffer(&vbDesc, &vbData, &m_vertexBuffer);
    if (FAILED(hr)) {
        releasePipeline();
        return false;
    }

    D3D11_BUFFER_DESC cbDesc = {};
    cbDesc.ByteWidth = sizeof(Constants);
    cbDesc.Usage = D3D11_USAGE_DYNAMIC;
    cbDesc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    cbDesc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    hr = m_device->CreateBuffer(&cbDesc, nullptr, &m_constantBuffer);
    if (FAILED(hr)) {
        releasePipeline();
        return false;
    }

    D3D11_SAMPLER_DESC sampDesc = {};
    sampDesc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sampDesc.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    sampDesc.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    sampDesc.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    hr = m_device->CreateSamplerState(&sampDesc, &m_sampler);
    if (FAILED(hr)) {
        releasePipeline();
        return false;
    }

    D3D11_RASTERIZER_DESC rsDesc = {};
    rsDesc.FillMode = D3D11_FILL_SOLID;
    rsDesc.CullMode = D3D11_CULL_NONE;
    hr = m_device->CreateRasterizerState(&rsDesc, &m_rasterizer);
    if (FAILED(hr)) {
        releasePipeline();
        return false;
    }

    LogManager::instance().log("D3D11: Zero-copy presenter pipeline ready");
    return true;
}

void D3D11VideoPresenter::releasePipeline() {
    releaseCom(m_rasterizer);
    releaseCom(m_sampler);
    releaseCom(m_constantBuffer);
    releaseCom(m_vertexBuffer);
    releaseCom(m_inputLayout);
    releaseCom(m_pixelShader);
    releaseCom(m_vertexShader);
}

bool D3D11VideoPresenter::ensureDisplayTexture(int width, int height) {
    if (m_displayTexture && m_texWidth == width && m_texHeight == height) {
        return true;
    }
    releaseDisplayTexture();
    if (!ensureDevice() || width <= 0 || height <= 0) {
        return false;
    }

    D3D11_TEXTURE2D_DESC desc = {};
    desc.Width = static_cast<UINT>(width);
    desc.Height = static_cast<UINT>(height);
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_NV12;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;

    HRESULT hr = m_device->CreateTexture2D(&desc, nullptr, &m_displayTexture);
    if (FAILED(hr) || !m_displayTexture) {
        LogManager::instance().log(
            QString("D3D11: Create NV12 display texture failed hr=0x%1")
                .arg(quint32(hr), 8, 16, QChar('0'))
        );
        return false;
    }

    D3D11_SHADER_RESOURCE_VIEW_DESC yDesc = {};
    yDesc.Format = DXGI_FORMAT_R8_UNORM;
    yDesc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    yDesc.Texture2D.MipLevels = 1;
    hr = m_device->CreateShaderResourceView(m_displayTexture, &yDesc, &m_srvY);
    if (FAILED(hr)) {
        releaseDisplayTexture();
        return false;
    }

    D3D11_SHADER_RESOURCE_VIEW_DESC uvDesc = {};
    uvDesc.Format = DXGI_FORMAT_R8G8_UNORM;
    uvDesc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    uvDesc.Texture2D.MipLevels = 1;
    hr = m_device->CreateShaderResourceView(m_displayTexture, &uvDesc, &m_srvUV);
    if (FAILED(hr)) {
        releaseDisplayTexture();
        return false;
    }

    m_texWidth = width;
    m_texHeight = height;
    return true;
}

void D3D11VideoPresenter::releaseDisplayTexture() {
    releaseCom(m_srvUV);
    releaseCom(m_srvY);
    releaseCom(m_displayTexture);
    m_texWidth = 0;
    m_texHeight = 0;
}

void D3D11VideoPresenter::presentPendingFrame() {
    m_updatePending.store(false);
    if (m_failed.load()) {
        return;
    }
    if (!ensureSwapChain() || !ensurePipeline()) {
        return;
    }

    auto pending = m_pendingFrame.take();
    if (pending.has_value() && pending->isValid()) {
        if (!ensureDisplayTexture(pending->width, pending->height)) {
            failPresent("display texture create failed");
            return;
        }

        ID3D11Texture2D* source = pending->texture;
        if (!source) {
            return;
        }

        D3D11_BOX box = {};
        box.left = 0;
        box.top = 0;
        box.front = 0;
        box.right = static_cast<UINT>(pending->width);
        box.bottom = static_cast<UINT>(pending->height);
        box.back = 1;
        m_context->CopySubresourceRegion(
            m_displayTexture,
            0,
            0,
            0,
            0,
            source,
            static_cast<UINT>(pending->textureIndex),
            &box
        );

        m_colorParameters = pending->colorParameters;
        const QSize newSize(pending->width, pending->height);
        if (m_videoSize != newSize) {
            m_videoSize = newSize;
            emit videoSizeChanged(newSize);
        }
        emit framePresented(
            pending->streamId,
            pending->sequence,
            pending->presentationTimestampNanoseconds
        );
    }

    if (m_texWidth <= 0 || !m_rtv) {
        return;
    }

    drawLetterboxed();
    const HRESULT presentHr = m_swapChain->Present(0, 0);
    if (FAILED(presentHr)) {
        ++m_copyFailCount;
        if (m_copyFailCount >= 3) {
            failPresent(
                QString("Present hr=0x%1")
                    .arg(quint32(presentHr), 8, 16, QChar('0'))
            );
        }
    } else {
        m_copyFailCount = 0;
    }
}

void D3D11VideoPresenter::drawLetterboxed() {
    const float clearColor[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    m_context->OMSetRenderTargets(1, &m_rtv, nullptr);
    m_context->ClearRenderTargetView(m_rtv, clearColor);

    D3D11_VIEWPORT viewport = {};
    viewport.Width = static_cast<float>(width());
    viewport.Height = static_cast<float>(height());
    viewport.MinDepth = 0.0f;
    viewport.MaxDepth = 1.0f;
    m_context->RSSetViewports(1, &viewport);
    m_context->RSSetState(m_rasterizer);

    float scaleX = 1.0f;
    float scaleY = 1.0f;
    float offsetX = 0.0f;
    float offsetY = 0.0f;
    const float widgetAspect = static_cast<float>(width()) / static_cast<float>(height());
    const float videoAspect =
        static_cast<float>(m_texWidth) / static_cast<float>(m_texHeight);
    if (videoAspect > widgetAspect) {
        scaleY = widgetAspect / videoAspect;
    } else {
        scaleX = videoAspect / widgetAspect;
    }

    D3D11_MAPPED_SUBRESOURCE mapped = {};
    if (SUCCEEDED(m_context->Map(m_constantBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) {
        auto* constants = static_cast<Constants*>(mapped.pData);
        constants->viewport[0] = offsetX;
        constants->viewport[1] = offsetY;
        constants->viewport[2] = scaleX;
        constants->viewport[3] = scaleY;
        constants->rangeParameters[0] = m_colorParameters.yOffset;
        constants->rangeParameters[1] = m_colorParameters.yScale;
        constants->rangeParameters[2] = m_colorParameters.uvOffset;
        constants->rangeParameters[3] = m_colorParameters.uvScale;
        constants->matrixCoefficients[0] = m_colorParameters.redFromV;
        constants->matrixCoefficients[1] = m_colorParameters.greenFromU;
        constants->matrixCoefficients[2] = m_colorParameters.greenFromV;
        constants->matrixCoefficients[3] = m_colorParameters.blueFromU;
        m_context->Unmap(m_constantBuffer, 0);
    }

    UINT stride = sizeof(Vertex);
    UINT offset = 0;
    m_context->IASetInputLayout(m_inputLayout);
    m_context->IASetVertexBuffers(0, 1, &m_vertexBuffer, &stride, &offset);
    m_context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
    m_context->VSSetShader(m_vertexShader, nullptr, 0);
    m_context->VSSetConstantBuffers(0, 1, &m_constantBuffer);
    m_context->PSSetShader(m_pixelShader, nullptr, 0);
    m_context->PSSetConstantBuffers(0, 1, &m_constantBuffer);
    m_context->PSSetShaderResources(0, 1, &m_srvY);
    m_context->PSSetShaderResources(1, 1, &m_srvUV);
    m_context->PSSetSamplers(0, 1, &m_sampler);
    m_context->Draw(4, 0);

    ID3D11ShaderResourceView* nullSrv[2] = {nullptr, nullptr};
    m_context->PSSetShaderResources(0, 2, nullSrv);
}

#endif  // _WIN32
