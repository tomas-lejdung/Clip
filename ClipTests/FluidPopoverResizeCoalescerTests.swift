import XCTest
@testable import Clip

@MainActor
final class FluidPopoverResizeCoalescerTests: XCTestCase {
    func testLatestReportWinsWithinOneSchedulingTurn() async {
        let coalescer = FluidPopoverResizeCoalescer()
        let sizingToken = UUID()
        let applied = expectation(description: "Latest resize applied")
        var received: [FluidPopoverResizeCoalescer.Request] = []
        let apply: @MainActor (FluidPopoverResizeCoalescer.Request) -> Void = { request in
            received.append(request)
            applied.fulfill()
        }

        coalescer.submit(
            request(height: 180, width: 330, token: sizingToken),
            apply: apply
        )
        coalescer.submit(
            request(height: 420, width: 380, token: sizingToken),
            apply: apply
        )
        let expected = request(height: 610, width: 380, token: sizingToken)
        coalescer.submit(expected, apply: apply)

        await fulfillment(of: [applied], timeout: 1)
        XCTAssertEqual(received, [expected])
    }

    func testCancelDropsSubmissionFromReplacedSizingToken() async {
        let coalescer = FluidPopoverResizeCoalescer()
        let applied = expectation(description: "Canceled resize is not applied")
        applied.isInverted = true

        coalescer.submit(
            request(height: 620, width: 380, token: UUID())
        ) { _ in
            applied.fulfill()
        }
        coalescer.cancel()

        await fulfillment(of: [applied], timeout: 0.1)
    }

    func testCanRescheduleAfterCancellation() async {
        let coalescer = FluidPopoverResizeCoalescer()
        let replacedToken = UUID()
        let activeToken = UUID()
        let staleApplied = expectation(description: "Replaced resize is not applied")
        staleApplied.isInverted = true
        let activeApplied = expectation(description: "Replacement resize is applied")
        var received: [FluidPopoverResizeCoalescer.Request] = []

        coalescer.submit(
            request(height: 180, width: 330, token: replacedToken)
        ) { _ in
            staleApplied.fulfill()
        }
        coalescer.cancel()

        let expected = request(height: 540, width: 380, token: activeToken)
        coalescer.submit(expected) { request in
            received.append(request)
            activeApplied.fulfill()
        }

        await fulfillment(of: [activeApplied, staleApplied], timeout: 0.1)
        XCTAssertEqual(received, [expected])
    }

    private func request(
        height: CGFloat,
        width: CGFloat,
        token: UUID
    ) -> FluidPopoverResizeCoalescer.Request {
        FluidPopoverResizeCoalescer.Request(
            idealHeight: height,
            width: width,
            sizingToken: token
        )
    }
}
