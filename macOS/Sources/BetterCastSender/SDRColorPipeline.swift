import CoreGraphics
import CoreVideo
import ScreenCaptureKit

enum SDRColorPipeline {
    static let colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_709_2
    static let transferFunction = kCVImageBufferTransferFunction_ITU_R_709_2
    static let yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2

    static func configureCapture(_ configuration: SCStreamConfiguration) {
        configuration.pixelFormat =
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // ScreenCaptureKit performs the source-display to Rec.709 conversion.
        // This avoids merely relabelling Display P3 pixels at encode time.
        configuration.colorSpaceName = CGColorSpace.itur_709
        configuration.colorMatrix =
            CGDisplayStream.yCbCrMatrix_ITU_R_709_2
    }
}
