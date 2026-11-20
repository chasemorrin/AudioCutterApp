import SwiftUI

/// Draws the visible part of the waveform, discarded sections, cut points and
/// the playhead, and turns touches into callbacks:
///  - tap: move the playhead
///  - drag: pan when zoomed in, scrub when fully zoomed out
///  - pinch: zoom
struct WaveformView: View {
    let peaks: [Float]
    let overviewSecondsPerBucket: Double
    let loudest: Float
    let detail: DetailPeaks?
    let duration: Double
    let viewStart: Double
    let viewDuration: Double
    let currentTime: Double
    let markerTimes: [Double]
    let dimmedRanges: [TimeRange]

    let onSeek: (Double) -> Void
    let onScrub: (Double, Bool) -> Void       // (time, isFinal)
    let onPan: (Double, Bool) -> Void         // (fraction of width, isFinal)
    let onPinch: (Double, Bool) -> Void       // (scale, isFinal)

    @State private var touchActive = false
    @State private var dragMoved = false
    @State private var pinchHappened = false

    private let waveColor = Color(red: 0.33, green: 0.79, blue: 0.64)
    private let playheadColor = Color(red: 0.11, green: 0.42, blue: 0.25)   // dark green
    private let markerColor = Color(red: 0.89, green: 0.63, blue: 0.24)     // amber
    private let dimColor = Color(red: 0.08, green: 0.07, blue: 0.06)

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                drawWaveform(context: context, size: size)
                drawDimmed(context: context, size: size)
                drawMarkers(context: context, size: size)
                drawPlayhead(context: context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !touchActive {
                            touchActive = true
                            pinchHappened = false
                            dragMoved = false
                        }
                        if pinchHappened { return }
                        let moved = abs(value.translation.width) > 8 || abs(value.translation.height) > 8
                        if !dragMoved && !moved { return }
                        dragMoved = true
                        handleDrag(value, width: geo.size.width, isFinal: false)
                    }
                    .onEnded { value in
                        defer {
                            touchActive = false
                            dragMoved = false
                        }
                        if pinchHappened {
                            onPan(0, true)      // make sure any pan in progress is closed out
                            return
                        }
                        if dragMoved {
                            handleDrag(value, width: geo.size.width, isFinal: true)
                        } else {
                            onSeek(time(forX: value.location.x, width: geo.size.width))
                        }
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        pinchHappened = true
                        onPinch(Double(scale), false)
                    }
                    .onEnded { scale in
                        onPinch(Double(scale), true)
                    }
            )
        }
        .background(Color(red: 0.055, green: 0.047, blue: 0.039))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 0.17, green: 0.15, blue: 0.12), lineWidth: 1)
        )
    }

    // MARK: - Touch handling

    private func handleDrag(_ value: DragGesture.Value, width: CGFloat, isFinal: Bool) {
        if viewDuration < duration - 0.001 {
            onPan(Double(value.translation.width / max(width, 1)), isFinal)
        } else {
            onScrub(time(forX: value.location.x, width: width), isFinal)
        }
    }

    private func time(forX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        let fraction = min(max(x / width, 0), 1)
        return viewStart + Double(fraction) * viewDuration
    }

    // MARK: - Drawing

    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        guard !peaks.isEmpty, size.width > 1, viewDuration > 0 else { return }

        let columns = Int(size.width)
        let midY = size.height / 2
        var path = Path()

        for x in 0..<columns {
            let t0 = viewStart + Double(x) / Double(columns) * viewDuration
            let t1 = viewStart + Double(x + 1) / Double(columns) * viewDuration
            let peak = peak(from: t0, to: t1)
            let half = CGFloat(peak / loudest) * midY * 0.92
            let xPos = CGFloat(x) + 0.5
            path.move(to: CGPoint(x: xPos, y: midY - half))
            path.addLine(to: CGPoint(x: xPos, y: midY + half))
        }
        context.stroke(path, with: .color(waveColor), lineWidth: 1)
    }

    private func peak(from t0: Double, to t1: Double) -> Float {
        if let d = detail, t0 >= d.start, t1 <= d.end {
            return maxPeak(in: d.peaks, secondsPerBucket: d.secondsPerBucket, origin: d.start, from: t0, to: t1)
        }
        return maxPeak(in: peaks, secondsPerBucket: overviewSecondsPerBucket, origin: 0, from: t0, to: t1)
    }

    private func maxPeak(in array: [Float], secondsPerBucket: Double, origin: Double, from t0: Double, to t1: Double) -> Float {
        guard !array.isEmpty, secondsPerBucket > 0 else { return 0 }
        let first = max(0, min(array.count - 1, Int(((t0 - origin) / secondsPerBucket).rounded(.down))))
        let lastRaw = Int(((t1 - origin) / secondsPerBucket).rounded(.up)) - 1
        let last = max(first, min(array.count - 1, lastRaw))
        var result: Float = 0
        for i in first...last where array[i] > result {
            result = array[i]
        }
        return result
    }

    /// Discarded sections are darkened so they read as "not included".
    private func drawDimmed(context: GraphicsContext, size: CGSize) {
        guard viewDuration > 0 else { return }
        for range in dimmedRanges {
            let start = max(range.start, viewStart)
            let end = min(range.end, viewStart + viewDuration)
            if end <= start { continue }
            let x0 = CGFloat((start - viewStart) / viewDuration) * size.width
            let x1 = CGFloat((end - viewStart) / viewDuration) * size.width
            let rect = CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)
            context.fill(Path(rect), with: .color(dimColor.opacity(0.7)))
        }
    }

    private func drawMarkers(context: GraphicsContext, size: CGSize) {
        guard viewDuration > 0 else { return }
        for (index, time) in markerTimes.enumerated() {
            if time < viewStart || time > viewStart + viewDuration { continue }
            let x = CGFloat((time - viewStart) / viewDuration) * size.width

            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(markerColor), lineWidth: 1.5)

            let flagWidth: CGFloat = index + 1 >= 10 ? 24 : 17
            let flag = CGRect(x: x, y: 0, width: flagWidth, height: 16)
            context.fill(Path(roundedRect: flag, cornerRadius: 3), with: .color(markerColor))
            context.draw(
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white),
                at: CGPoint(x: flag.midX, y: flag.midY),
                anchor: .center
            )
        }
    }

    private func drawPlayhead(context: GraphicsContext, size: CGSize) {
        guard viewDuration > 0 else { return }
        if currentTime < viewStart || currentTime > viewStart + viewDuration { return }
        let x = CGFloat((currentTime - viewStart) / viewDuration) * size.width
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(playheadColor), lineWidth: 3)
    }
}
