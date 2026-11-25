// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import BaerchenIOS

@Suite struct MobileAttachmentImagePresentationTests {
    @Test func pdfAndTextNeverNeedImageInspectionSheet() {
        #expect(!MobileAttachmentImagePresentation.inspect(Data("%PDF-1.7\n".utf8)).isRaster)
        #expect(!MobileAttachmentImagePresentation.inspect(Data("ordinary text".utf8)).isRaster)
    }
    @Test func imageClassificationUsesBytesAndWarnsOnUndecodableSketchMetadata() {
        let signature = Data([137,80,78,71,13,10,26,10])
        let ordinary = signature + Data([0,0,0,0]) + Data("IEND".utf8) + Data(repeating: 0, count: 4)
        #expect(MobileAttachmentImagePresentation.inspect(ordinary).isRaster)
        #expect(!MobileAttachmentImagePresentation.inspect(ordinary).hasSketchMetadata)
        let corruptDrawing = signature + Data([0,0,0,1]) + Data("thND".utf8) + Data([0]) + Data(repeating: 0, count: 4)
        #expect(MobileAttachmentImagePresentation.inspect(corruptDrawing).hasSketchMetadata)
        let truncatedDrawing = signature + Data([255,255,255,255]) + Data("thND".utf8)
        #expect(MobileAttachmentImagePresentation.inspect(truncatedDrawing).hasSketchMetadata)
        let markerInsidePixels = signature + Data([0,0,0,4]) + Data("IDAT".utf8) + Data("thND".utf8) + Data(repeating: 0, count: 4)
        #expect(!MobileAttachmentImagePresentation.inspect(markerInsidePixels).hasSketchMetadata)
    }
}
