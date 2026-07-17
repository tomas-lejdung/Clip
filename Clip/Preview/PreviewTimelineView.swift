import SwiftUI

struct PreviewTimelineView: View {
    let duration: TimeInterval
    let trimStart: TimeInterval
    let trimEnd: TimeInterval
    let currentTime: TimeInterval
    let onScrub: (TimeInterval) -> Void
    let onChangeTrimStart: (TimeInterval) -> Void
    let onChangeTrimEnd: (TimeInterval) -> Void

    @State private var startDragOrigin: TimeInterval?
    @State private var endDragOrigin: TimeInterval?

    var body: some View {
        VStack(spacing: 7) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let startX = xPosition(for: trimStart, width: width)
                let endX = xPosition(for: trimEnd, width: width)
                let playheadX = xPosition(for: currentTime, width: width)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                        .gesture(scrubGesture(width: width))

                    Rectangle()
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: max(0, endX - startX), height: 30)
                        .offset(x: startX)
                        .allowsHitTesting(false)

                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.35), radius: 1)
                        .frame(width: 2, height: 24)
                        .position(x: playheadX, y: 15)
                        .allowsHitTesting(false)

                    trimHandle(systemImage: "chevron.right", isLeading: true)
                        .position(x: startX, y: 15)
                        .highPriorityGesture(startHandleGesture(width: width))

                    trimHandle(systemImage: "chevron.left", isLeading: false)
                        .position(x: endX, y: 15)
                        .highPriorityGesture(endHandleGesture(width: width))
                }
            }
            .frame(height: 30)

            HStack {
                Text(PreviewTimecodeFormatter.string(from: trimStart))
                Spacer()
                Text("\(PreviewTimecodeFormatter.string(from: currentTime)) / \(PreviewTimecodeFormatter.string(from: duration))")
                Spacer()
                Text(PreviewTimecodeFormatter.string(from: trimEnd))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video timeline")
        .accessibilityIdentifier("clip.preview.timeline")
    }

    private func xPosition(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return min(max(CGFloat(time / duration) * width, 0), width)
    }

    private func time(forX x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return TimeInterval(min(max(x / width, 0), 1)) * duration
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onScrub(time(forX: value.location.x, width: width))
            }
    }

    private func startHandleGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin = startDragOrigin ?? trimStart
                if startDragOrigin == nil {
                    startDragOrigin = origin
                }
                onChangeTrimStart(origin + TimeInterval(value.translation.width / width) * duration)
            }
            .onEnded { _ in
                startDragOrigin = nil
            }
    }

    private func endHandleGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin = endDragOrigin ?? trimEnd
                if endDragOrigin == nil {
                    endDragOrigin = origin
                }
                onChangeTrimEnd(origin + TimeInterval(value.translation.width / width) * duration)
            }
            .onEnded { _ in
                endDragOrigin = nil
            }
    }

    private func trimHandle(systemImage: String, isLeading: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.accentColor)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)

            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 18, height: 34)
        .contentShape(Rectangle())
        .accessibilityLabel(isLeading ? "Trim start" : "Trim end")
        .accessibilityValue(
            PreviewTimecodeFormatter.string(from: isLeading ? trimStart : trimEnd)
        )
    }
}
