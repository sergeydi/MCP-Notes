import SwiftUI

// MARK: - Simulation

@Observable
final class GraphSimulation {
    struct SimNode: Identifiable {
        let id: UUID
        var label: String
        var position: CGPoint
        var velocity: CGPoint = .zero
        var isPinned: Bool = false
    }

    var nodes: [SimNode] = []
    var edges: [(from: Int, to: Int)] = []
    var alpha: Double = 0

    private let repulsion: Double = 8000
    private let springRest: Double = 180
    private let springK: Double = 0.02
    private let centerK: Double = 0.02
    private let damping: Double = 0.78

    func tick(center: CGPoint) {
        guard alpha > 0.005 else { alpha = 0; return }

        let n = nodes.count
        var fx = [Double](repeating: 0, count: n)
        var fy = [Double](repeating: 0, count: n)

        for i in 0..<n {
            for j in (i + 1)..<n {
                let dx = Double(nodes[j].position.x - nodes[i].position.x)
                let dy = Double(nodes[j].position.y - nodes[i].position.y)
                let d2 = max(dx * dx + dy * dy, 1)
                let d = d2.squareRoot()
                let f = repulsion / d2
                fx[i] -= f * dx / d;  fy[i] -= f * dy / d
                fx[j] += f * dx / d;  fy[j] += f * dy / d
            }
        }

        for e in edges {
            guard e.from < n, e.to < n else { continue }
            let dx = Double(nodes[e.to].position.x - nodes[e.from].position.x)
            let dy = Double(nodes[e.to].position.y - nodes[e.from].position.y)
            let d = max((dx * dx + dy * dy).squareRoot(), 0.01)
            let f = springK * (d - springRest)
            fx[e.from] += f * dx / d;  fy[e.from] += f * dy / d
            fx[e.to]   -= f * dx / d;  fy[e.to]   -= f * dy / d
        }

        let cx = Double(center.x), cy = Double(center.y)
        for i in 0..<n {
            fx[i] += centerK * (cx - Double(nodes[i].position.x))
            fy[i] += centerK * (cy - Double(nodes[i].position.y))
        }

        for i in 0..<n {
            guard !nodes[i].isPinned else { continue }
            let vx = (Double(nodes[i].velocity.x) + fx[i] * alpha) * damping
            let vy = (Double(nodes[i].velocity.y) + fy[i] * alpha) * damping
            nodes[i].velocity = CGPoint(x: vx, y: vy)
            nodes[i].position.x += nodes[i].velocity.x
            nodes[i].position.y += nodes[i].velocity.y
        }

        alpha *= 0.992
    }

    func pin(id: UUID, at position: CGPoint) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[i].position = position
        nodes[i].isPinned = true
        alpha = max(alpha, 0.1)
    }

    func recenterNodes(in viewSize: CGSize) {
        guard !nodes.isEmpty, viewSize != .zero else { return }
        let cx = nodes.reduce(0.0) { $0 + Double($1.position.x) } / Double(nodes.count)
        let cy = nodes.reduce(0.0) { $0 + Double($1.position.y) } / Double(nodes.count)
        let dx = CGFloat(Double(viewSize.width) / 2 - cx)
        let dy = CGFloat(Double(viewSize.height) / 2 - cy)
        for i in nodes.indices { nodes[i].position.x += dx; nodes[i].position.y += dy }
    }

    func unpin(id: UUID) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[i].isPinned = false
        nodes[i].velocity = .zero
    }

    func load(notes: [Note], edges rawEdges: [(source: UUID, target: UUID)], in size: CGSize) {
        let n = notes.count
        let cols = max(1, Int((Double(n) * size.width / size.height).squareRoot().rounded()))
        let rows = max(1, Int((Double(n) / Double(cols)).rounded(.up)))
        let cellW = size.width / Double(cols + 1)
        let cellH = size.height / Double(rows + 1)

        nodes = notes.enumerated().map { i, note in
            let col = i % cols
            let row = i / cols
            let jx = Double.random(in: -cellW * 0.3 ... cellW * 0.3)
            let jy = Double.random(in: -cellH * 0.3 ... cellH * 0.3)
            return SimNode(
                id: note.id,
                label: note.filename,
                position: CGPoint(x: cellW * Double(col + 1) + jx, y: cellH * Double(row + 1) + jy)
            )
        }

        let idToIdx = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($0.element.id, $0.offset) })
        edges = rawEdges.compactMap { e -> (from: Int, to: Int)? in
            guard let f = idToIdx[e.source], let t = idToIdx[e.target] else { return nil }
            return (from: f, to: t)
        }

        alpha = 1.0
    }
}

// MARK: - View

struct WikilinkGraphView: View {
    @Environment(NoteStore.self) private var store
    @State private var sim = GraphSimulation()
    @State private var viewSize: CGSize = .zero
    @State private var zoom: CGFloat = 1.0
    @State private var panOffset: CGPoint = .zero
    @State private var scrollMonitor: Any?
    @State private var panDragStartOffset: CGPoint = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            edgeCanvas

            ForEach(sim.nodes) { node in
                nodeView(node)
            }

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .padding(10)
            .help("Reload graph")

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onGeometryChange(for: CGSize.self, of: \.size) { viewSize = $0 }
        .task { await reload() }
        .task {
            var wasSimulating = false
            var ticksSinceCenter = 0
            while !Task.isCancelled {
                if sim.alpha > 0.005 {
                    wasSimulating = true
                    sim.tick(center: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
                    ticksSinceCenter += 1
                    if ticksSinceCenter >= 60 {
                        ticksSinceCenter = 0
                        sim.recenterNodes(in: viewSize)
                    }
                    try? await Task.sleep(nanoseconds: 16_666_666)
                } else {
                    if wasSimulating {
                        wasSimulating = false
                        ticksSinceCenter = 0
                        sim.recenterNodes(in: viewSize)
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        .onChange(of: viewSize) { _, newSize in
            guard sim.alpha == 0 else { return }
            sim.recenterNodes(in: newSize)
        }
        .onAppear { startScrollMonitor() }
        .onDisappear { stopScrollMonitor() }
    }

    // MARK: - Coordinate transforms

    private func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + panOffset.x, y: p.y * zoom + panOffset.y)
    }

    private func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - panOffset.x) / zoom, y: (p.y - panOffset.y) / zoom)
    }

    private func zoomAt(screenPoint: CGPoint, factor: CGFloat) {
        let newZoom = max(0.1, min(8.0, zoom * factor))
        let wx = (screenPoint.x - panOffset.x) / zoom
        let wy = (screenPoint.y - panOffset.y) / zoom
        panOffset = CGPoint(x: screenPoint.x - wx * newZoom, y: screenPoint.y - wy * newZoom)
        panDragStartOffset = panOffset
        zoom = newZoom
    }

    // MARK: - Subviews

    private var edgeCanvas: some View {
        let z = zoom, pan = panOffset
        let nodes = sim.nodes
        let edges = sim.edges
        return Canvas { ctx, _ in
            for e in edges {
                guard e.from < nodes.count, e.to < nodes.count else { continue }
                let w0 = nodes[e.from].position, w1 = nodes[e.to].position
                let p0 = CGPoint(x: w0.x * z + pan.x, y: w0.y * z + pan.y)
                let p1 = CGPoint(x: w1.x * z + pan.x, y: w1.y * z + pan.y)
                var path = Path()
                path.move(to: p0)
                path.addLine(to: p1)
                ctx.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
            }
        }
        .gesture(
            DragGesture()
                .onChanged { val in
                    panOffset = CGPoint(
                        x: panDragStartOffset.x + val.translation.width,
                        y: panDragStartOffset.y + val.translation.height
                    )
                }
                .onEnded { _ in
                    panDragStartOffset = panOffset
                }
        )
    }

    @ViewBuilder
    private func nodeView(_ node: GraphSimulation.SimNode) -> some View {
        @Bindable var store = store
        let isSelected = node.id == store.selectedNoteID
        let dotSize = max(8, 12 * zoom)
        let fontSize = max(7, 9 * zoom)

        VStack(spacing: 2) {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.6))
                .frame(width: dotSize, height: dotSize)
                .overlay(
                    Circle().strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                        .frame(width: dotSize + 4, height: dotSize + 4)
                )
            Text(node.label)
                .font(.system(size: fontSize))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .position(toScreen(node.position))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { val in sim.pin(id: node.id, at: toWorld(val.location)) }
                .onEnded   { _   in sim.unpin(id: node.id) }
        )
        .onTapGesture {
            store.selectedNoteID = node.id
        }
    }

    // MARK: - Data loading

    private func reload() async {
        zoom = 1.0
        panOffset = .zero
        panDragStartOffset = .zero
        // Wait up to 300ms for geometry to be reported before loading
        for _ in 0..<6 where viewSize == .zero {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let notes = store.notes
        let rawEdges = await store.allWikilinkEdges()
        let size = viewSize == .zero ? CGSize(width: 800, height: 600) : viewSize
        sim.load(notes: notes, edges: rawEdges, in: size)
        // Immediately center the initial grid layout
        let targetSize = viewSize == .zero ? size : viewSize
        sim.recenterNodes(in: targetSize)
    }

    // MARK: - Scroll zoom

    private func startScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.window?.identifier?.rawValue == "wikilink-graph" else { return event }
            let factor = pow(1.01, -event.scrollingDeltaY)
            zoomAt(screenPoint: zoomPivot(event: event), factor: factor)
            centerPanIfFitting()
            return nil
        }
    }

    private func centerPanIfFitting() {
        guard !sim.nodes.isEmpty, viewSize != .zero else { return }
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for node in sim.nodes {
            let s = toScreen(node.position)
            minX = min(minX, s.x); maxX = max(maxX, s.x)
            minY = min(minY, s.y); maxY = max(maxY, s.y)
        }
        guard minX >= 0 && maxX <= viewSize.width && minY >= 0 && maxY <= viewSize.height else { return }
        let cx = sim.nodes.reduce(0.0) { $0 + $1.position.x } / CGFloat(sim.nodes.count)
        let cy = sim.nodes.reduce(0.0) { $0 + $1.position.y } / CGFloat(sim.nodes.count)
        let target = CGPoint(x: viewSize.width / 2 - cx * zoom, y: viewSize.height / 2 - cy * zoom)
        panDragStartOffset = target
        panOffset = target
    }

    private func zoomPivot(event: NSEvent) -> CGPoint {
        guard !sim.nodes.isEmpty else {
            return CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        }
        // Check if the entire graph fits on screen
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for node in sim.nodes {
            let s = toScreen(node.position)
            minX = min(minX, s.x); maxX = max(maxX, s.x)
            minY = min(minY, s.y); maxY = max(maxY, s.y)
        }
        let fits = minX >= 0 && maxX <= viewSize.width && minY >= 0 && maxY <= viewSize.height
        if fits {
            // Zoom at centroid so graph stays centered
            let cx = sim.nodes.reduce(0.0) { $0 + $1.position.x } / CGFloat(sim.nodes.count)
            let cy = sim.nodes.reduce(0.0) { $0 + $1.position.y } / CGFloat(sim.nodes.count)
            return toScreen(CGPoint(x: cx, y: cy))
        } else {
            // Zoom at cursor
            let loc = event.locationInWindow
            let winH = event.window?.contentView?.bounds.height ?? viewSize.height
            return CGPoint(x: loc.x, y: winH - loc.y)
        }
    }

    private func stopScrollMonitor() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil
    }
}
