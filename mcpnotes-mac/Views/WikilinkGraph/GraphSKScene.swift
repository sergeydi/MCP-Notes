import SpriteKit

final class GraphSKScene: SKScene {

    private let repulsion: Double = 8000
    private let springRest: Double = 180
    private let springK: Double = 0.02
    private let centerK: Double = 0.02
    private let damping: Double = 0.78

    private struct SimNode {
        let id: UUID
        var velocity: CGPoint = .zero
        var isPinned: Bool = false
        var sprite: SKNode?
    }

    private var simNodes: [SimNode] = []
    private var edges: [(from: Int, to: Int)] = []
    private var simAlpha: Double = 0
    private var edgeShape: SKShapeNode?
    private let cam = SKCameraNode()

    var selectedID: UUID? { didSet { syncSelection() } }
    var onTap: ((UUID) -> Void)?

    private var dragNodeIndex: Int?
    private var cameraAnchor: CGPoint = .zero

    // MARK: Lifecycle

    override func didMove(to view: SKView) {
        anchorPoint = .zero

        if edgeShape == nil {
            let shape = SKShapeNode()
            shape.strokeColor = NSColor.labelColor.withAlphaComponent(0.3)
            shape.lineWidth = 1
            shape.zPosition = -1
            addChild(shape)
            edgeShape = shape
            addChild(cam)
            camera = cam
        }

        cam.position = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        cam.position = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    // MARK: Data

    func clearImmediate() {
        simNodes.forEach { $0.sprite?.removeFromParent() }
        simNodes = []
        edges = []
        simAlpha = 0
        edgeShape?.path = nil
    }

    func load(notes: [Note], rawEdges: [(source: UUID, target: UUID)]) {
        isPaused = false
        view?.isPaused = false
        simNodes.forEach { $0.sprite?.removeFromParent() }
        simNodes = []
        edges = []
        simAlpha = 0

        let n = notes.count
        guard n > 0 else { return }

        let sz = size == .zero ? CGSize(width: 800, height: 600) : size
        let cols = max(1, Int((Double(n) * sz.width / sz.height).squareRoot().rounded()))
        let rows = max(1, Int((Double(n) / Double(cols)).rounded(.up)))
        let cellW = sz.width / Double(cols + 1)
        let cellH = sz.height / Double(rows + 1)

        var idToIdx: [UUID: Int] = [:]
        simNodes = notes.enumerated().map { i, note in
            let x = cellW * Double(i % cols + 1) + Double.random(in: -cellW * 0.3 ... cellW * 0.3)
            let y = cellH * Double(i / cols + 1) + Double.random(in: -cellH * 0.3 ... cellH * 0.3)
            let sprite = makeSprite(note)
            sprite.position = CGPoint(x: x, y: y)
            addChild(sprite)
            idToIdx[note.id] = i
            return SimNode(id: note.id, sprite: sprite)
        }

        edges = rawEdges.compactMap { e in
            guard let f = idToIdx[e.source], let t = idToIdx[e.target] else { return nil }
            return (from: f, to: t)
        }

        simAlpha = 1.0
        cam.position = CGPoint(x: sz.width / 2, y: sz.height / 2)
        cam.setScale(1.0)
        syncSelection()
    }

    private func makeSprite(_ note: Note) -> SKNode {
        let root = SKNode()
        root.name = note.id.uuidString

        let dot = SKShapeNode(circleOfRadius: 6)
        dot.name = "dot"
        dot.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.6)
        dot.strokeColor = .clear
        root.addChild(dot)

        let lbl = SKLabelNode(text: note.filename)
        lbl.name = "lbl"
        lbl.fontSize = 9
        lbl.fontColor = .secondaryLabelColor
        lbl.position = CGPoint(x: 0, y: -20)
        lbl.horizontalAlignmentMode = .center
        lbl.verticalAlignmentMode = .top
        root.addChild(lbl)

        return root
    }

    private func syncSelection() {
        for node in simNodes {
            guard let s = node.sprite else { continue }
            let sel = node.id == selectedID
            if let dot = s.childNode(withName: "dot") as? SKShapeNode {
                dot.fillColor = sel ? .controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.6)
                dot.strokeColor = sel ? .controlAccentColor : .clear
                dot.lineWidth = sel ? 2 : 0
            }
            if let lbl = s.childNode(withName: "lbl") as? SKLabelNode {
                lbl.fontColor = sel ? .labelColor : .secondaryLabelColor
            }
        }
    }

    // MARK: Simulation

    override func update(_ currentTime: TimeInterval) {
        guard simAlpha > 0.005 else { simAlpha = 0; return }

        let n = simNodes.count
        var fx = [Double](repeating: 0, count: n)
        var fy = [Double](repeating: 0, count: n)

        for i in 0..<n {
            guard let pi = simNodes[i].sprite?.position else { continue }
            for j in (i + 1)..<n {
                guard let pj = simNodes[j].sprite?.position else { continue }
                let dx = Double(pj.x - pi.x), dy = Double(pj.y - pi.y)
                let d2 = max(dx * dx + dy * dy, 1), d = d2.squareRoot()
                let f = repulsion / d2
                fx[i] -= f * dx / d; fy[i] -= f * dy / d
                fx[j] += f * dx / d; fy[j] += f * dy / d
            }
        }

        for e in edges {
            guard e.from < n, e.to < n,
                  let pf = simNodes[e.from].sprite?.position,
                  let pt = simNodes[e.to].sprite?.position else { continue }
            let dx = Double(pt.x - pf.x), dy = Double(pt.y - pf.y)
            let d = max((dx * dx + dy * dy).squareRoot(), 0.01)
            let f = springK * (d - springRest)
            fx[e.from] += f * dx / d; fy[e.from] += f * dy / d
            fx[e.to]   -= f * dx / d; fy[e.to]   -= f * dy / d
        }

        let cx = Double(size.width / 2), cy = Double(size.height / 2)
        for i in 0..<n {
            guard let p = simNodes[i].sprite?.position else { continue }
            fx[i] += centerK * (cx - Double(p.x))
            fy[i] += centerK * (cy - Double(p.y))
        }

        for i in 0..<n {
            guard !simNodes[i].isPinned else { continue }
            let vx = (Double(simNodes[i].velocity.x) + fx[i] * simAlpha) * damping
            let vy = (Double(simNodes[i].velocity.y) + fy[i] * simAlpha) * damping
            simNodes[i].velocity = CGPoint(x: vx, y: vy)
            simNodes[i].sprite?.position.x += simNodes[i].velocity.x
            simNodes[i].sprite?.position.y += simNodes[i].velocity.y
        }

        simAlpha *= 0.992
        rebuildEdges()
    }

    private func rebuildEdges() {
        let n = simNodes.count
        let path = CGMutablePath()
        for e in edges {
            guard e.from < n, e.to < n,
                  let p0 = simNodes[e.from].sprite?.position,
                  let p1 = simNodes[e.to].sprite?.position else { continue }
            path.move(to: p0)
            path.addLine(to: p1)
        }
        edgeShape?.path = path
    }

    // MARK: Input

    @objc func handlePan(_ g: NSPanGestureRecognizer) {
        guard let v = g.view as? SKView else { return }
        let loc = convertPoint(fromView: g.location(in: v))
        switch g.state {
        case .began:
            if let i = nearestIndex(to: loc, screenRadius: 20) {
                dragNodeIndex = i
                pinNode(i, to: loc)
            } else {
                dragNodeIndex = nil
                cameraAnchor = cam.position
            }
        case .changed:
            if let i = dragNodeIndex {
                pinNode(i, to: loc)
            } else {
                let t = g.translation(in: v)
                let s = cam.xScale
                cam.position = CGPoint(x: cameraAnchor.x - t.x * s,
                                       y: cameraAnchor.y - t.y * s)
            }
        case .ended, .cancelled:
            if let i = dragNodeIndex { unpinNode(i); dragNodeIndex = nil }
        default: break
        }
    }

    @objc func handleClick(_ g: NSClickGestureRecognizer) {
        guard let v = g.view as? SKView, g.state == .ended else { return }
        let loc = convertPoint(fromView: g.location(in: v))
        if let i = nearestIndex(to: loc, screenRadius: 20) { onTap?(simNodes[i].id) }
    }

    func handleScroll(event: NSEvent, in view: SKView) {
        let factor = pow(1.01, -event.scrollingDeltaY)
        let newScale = max(0.125, min(8.0, cam.xScale * factor))
        let pivot = convertPoint(fromView: view.convert(event.locationInWindow, from: nil))
        let ratio = newScale / cam.xScale
        cam.position = CGPoint(
            x: pivot.x + (cam.position.x - pivot.x) * ratio,
            y: pivot.y + (cam.position.y - pivot.y) * ratio
        )
        cam.setScale(newScale)
    }

    // MARK: Helpers

    private func nearestIndex(to point: CGPoint, screenRadius: CGFloat) -> Int? {
        let worldRadius = screenRadius * cam.xScale
        var best: (Int, CGFloat)?
        for (i, n) in simNodes.enumerated() {
            guard let p = n.sprite?.position else { continue }
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < worldRadius, d < (best?.1 ?? .greatestFiniteMagnitude) { best = (i, d) }
        }
        return best?.0
    }

    private func pinNode(_ i: Int, to point: CGPoint) {
        simNodes[i].sprite?.position = point
        simNodes[i].isPinned = true
        simAlpha = max(simAlpha, 0.1)
    }

    private func unpinNode(_ i: Int) {
        simNodes[i].isPinned = false
        simNodes[i].velocity = .zero
    }
}
