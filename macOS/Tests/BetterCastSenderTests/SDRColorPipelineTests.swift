import CoreGraphics
import CoreVideo
import ScreenCaptureKit
import XCTest
@testable import BetterCastSender

final class SDRColorPipelineTests: XCTestCase {
    func testSDRCaptureUsesVideoRangeRec709() {
        let configuration = SCStreamConfiguration()

        SDRColorPipeline.configureCapture(configuration)

        XCTAssertEqual(
            configuration.pixelFormat,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(
            configuration.colorSpaceName as String,
            CGColorSpace.itur_709 as String
        )
        XCTAssertEqual(
            configuration.colorMatrix as String,
            CGDisplayStream.yCbCrMatrix_ITU_R_709_2 as String
        )
    }
}
