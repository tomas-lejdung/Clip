import AppKit
import CoreGraphics
import MetalKit
import Testing
@preconcurrency import WebRTC

@Suite("Native WebRTC renderer color contract", .serialized)
struct NativeRendererColorContractTests {
    @Test("Metal output gamut and transfer follow decoded color metadata")
    @MainActor
    func outputColorContractSelection() async throws {
        let cases = [
            RendererColorCase(
                name: "Display P3 with sRGB transfer",
                colorSpace: .init(primaries: 12, transfer: 13, matrix: 6, range: 1),
                expectedOutputName: CGColorSpace.displayP3,
                expectedTransferConversionKind: 0
            ),
            RendererColorCase(
                name: "Display P3 with Rec.709 transfer",
                colorSpace: .init(primaries: 12, transfer: 1, matrix: 6, range: 1),
                expectedOutputName: CGColorSpace.displayP3,
                expectedTransferConversionKind: 1
            ),
            RendererColorCase(
                name: "sRGB",
                colorSpace: .init(primaries: 1, transfer: 13, matrix: 6, range: 1),
                expectedOutputName: CGColorSpace.sRGB,
                expectedTransferConversionKind: 0
            ),
            RendererColorCase(
                name: "Rec.709",
                colorSpace: .init(primaries: 1, transfer: 1, matrix: 1, range: 1),
                expectedOutputName: CGColorSpace.itur_709,
                expectedTransferConversionKind: 0
            ),
        ]
        let transferConversionSelector = NSSelectorFromString(
            "outputTransferConversionKind"
        )

        for colorCase in cases {
            let renderer = RTCMTLNSVideoView(frame: CGRect(
                x: 0,
                y: 0,
                width: 16,
                height: 16
            ))
            let metalView = try #require(findMetalView(in: renderer))
            let frame = makeRendererFixtureFrame(colorSpace: colorCase.colorSpace)

            renderer.renderFrame(frame)
            for _ in 0 ..< 100
                where metalView.colorspace?.name != colorCase.expectedOutputName
            {
                await Task.yield()
            }

            #expect(
                metalView.colorspace?.name == colorCase.expectedOutputName,
                Comment(rawValue:
                    "\(colorCase.name) selected "
                        + "\(String(describing: metalView.colorspace?.name)); "
                    + "expected \(colorCase.expectedOutputName)"
                )
            )
            let exposesTransferConversion = renderer.responds(
                to: transferConversionSelector
            )
            #expect(exposesTransferConversion, Comment(rawValue:
                "\(colorCase.name) renderer does not expose its transfer "
                    + "conversion state"
            ))
            if exposesTransferConversion {
                let conversion = renderer.value(
                    forKey: "outputTransferConversionKind"
                ) as? NSNumber
                #expect(
                    conversion?.intValue
                        == colorCase.expectedTransferConversionKind,
                    Comment(rawValue:
                        "\(colorCase.name) transfer conversion was "
                            + "\(String(describing: conversion)); expected "
                            + "\(colorCase.expectedTransferConversionKind)"
                    )
                )
            }
            renderer.renderFrame(nil)
        }
    }
}

private struct RendererColorCase {
    let name: String
    let colorSpace: RTCVideoColorSpace
    let expectedOutputName: CFString
    let expectedTransferConversionKind: Int
}

@MainActor
private func findMetalView(in view: NSView) -> MTKView? {
    if let metalView = view as? MTKView {
        return metalView
    }
    for subview in view.subviews {
        if let metalView = findMetalView(in: subview) {
            return metalView
        }
    }
    return nil
}

private func makeRendererFixtureFrame(
    colorSpace: RTCVideoColorSpace
) -> RTCVideoFrame {
    let buffer = RTCMutableI420Buffer(width: 16, height: 16)
    memset(
        buffer.mutableDataY,
        16,
        Int(buffer.strideY) * Int(buffer.height)
    )
    memset(
        buffer.mutableDataU,
        128,
        Int(buffer.strideU) * Int(buffer.chromaHeight)
    )
    memset(
        buffer.mutableDataV,
        128,
        Int(buffer.strideV) * Int(buffer.chromaHeight)
    )
    let frame = RTCVideoFrame(
        buffer: buffer,
        rotation: ._0,
        timeStampNs: 0
    )
    frame.hasColorSpace = true
    frame.colorSpace = colorSpace
    return frame
}
