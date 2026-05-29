import MCPNotesCore
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
    private var edgeNodes: [SKShapeNode] = []
    private var edgeParticles: [[SKShapeNode]] = []
    private let cam = SKCameraNode()

    var selectedID: UUID? { didSet { guard oldValue != selectedID else { return }; syncSelection(oldID: oldValue) } }
    var onTap: ((UUID?) -> Void)?

    private var dragNodeIndex: Int?
    private var cameraAnchor: CGPoint = .zero
    private var labelsVisible: Bool = true
    private var isolatedIndices: Set<Int> = []
    private var isolatedDotsVisible: Bool = true

    // MARK: Lifecycle

    override func didMove(to view: SKView) {
        anchorPoint = .zero

        if camera == nil {
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
        stopIdleFlicker()
        simNodes.forEach { $0.sprite?.removeFromParent() }
        simNodes = []
        edges = []
        simAlpha = 0
        edgeNodes.forEach { $0.removeFromParent() }
        edgeNodes = []
        edgeParticles.forEach { $0.forEach { $0.removeFromParent() } }
        edgeParticles = []
        isolatedIndices = []
        isolatedDotsVisible = true
    }

    func load(notes: [Note], rawEdges: [(source: UUID, target: UUID)]) {
        isPaused = false
        view?.isPaused = false
        simNodes.forEach { $0.sprite?.removeFromParent() }
        simNodes = []
        edges = []
        simAlpha = 0
        edgeNodes.forEach { $0.removeFromParent() }
        edgeNodes = []
        edgeParticles.forEach { $0.forEach { $0.removeFromParent() } }
        edgeParticles = []

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
            (sprite.childNode(withName: "dot") as? SKShapeNode).map {
                $0.alpha = 0; $0.run(.fadeIn(withDuration: 2.0))
            }
            (sprite.childNode(withName: "lbl") as? SKLabelNode).map {
                $0.alpha = 0; $0.run(.fadeIn(withDuration: 3.0), withKey: "labelFade")
            }
            addChild(sprite)
            idToIdx[note.id] = i
            return SimNode(id: note.id, sprite: sprite)
        }

        edges = rawEdges.compactMap { e in
            guard let f = idToIdx[e.source], let t = idToIdx[e.target] else { return nil }
            return (from: f, to: t)
        }

        edgeNodes = edges.map { _ in
            let shape = SKShapeNode()
            shape.strokeColor = .white
            shape.lineWidth = 1
            shape.zPosition = -1
            shape.alpha = 0
            shape.run(.fadeAlpha(to: 0.4, duration: 2.0))
            addChild(shape)
            return shape
        }
        edgeParticles = Array(repeating: [], count: edges.count)
        let connected = Set(edges.flatMap { [$0.from, $0.to] })
        isolatedIndices = Set(simNodes.indices).subtracting(connected)
        isolatedDotsVisible = true
        simAlpha = 1.0
        labelsVisible = true
        cam.position = CGPoint(x: sz.width / 2, y: sz.height / 2)
        cam.setScale(3.0)
        syncSelection()
        syncLabelScale()
    }

    private func truncated(_ text: String, limit: Int = 30) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(limit)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }

    private func makeSprite(_ note: Note) -> SKNode {
        let root = SKNode()
        root.name = note.id.uuidString

        let glow = SKShapeNode(circleOfRadius: 18)
        glow.name = "glow"
        glow.fillColor = .white
        glow.strokeColor = .clear
        glow.lineWidth = 0
        glow.alpha = 0
        glow.zPosition = -1
        root.addChild(glow)

        for i in 0..<3 {
            let ring = SKShapeNode(circleOfRadius: 8)
            ring.name = "ring\(i)"
            ring.fillColor = .clear
            ring.strokeColor = .white
            ring.lineWidth = 1.5
            ring.alpha = 0
            ring.zPosition = -0.5
            root.addChild(ring)
        }

        let dot = SKShapeNode(circleOfRadius: 6)
        dot.name = "dot"
        dot.fillColor = NSColor(white: 0.5, alpha: 1.0)
        dot.strokeColor = .clear
        root.addChild(dot)

        let lbl = SKLabelNode(text: truncated(note.filename))
        lbl.name = "lbl"
        lbl.fontName = NSFont.systemFont(ofSize: 0, weight: .medium).fontName
        lbl.fontSize = 13
        lbl.fontColor = NSColor.white.withAlphaComponent(0.3)
        lbl.position = CGPoint(x: 0, y: -20)
        lbl.horizontalAlignmentMode = .center
        lbl.verticalAlignmentMode = .top
        root.addChild(lbl)

        return root
    }

    private func startIdleFlicker() {
        let seq = SKAction.sequence([
            .wait(forDuration: 4.0),
            .run { [weak self] in self?.flickerRandomNode() }
        ])
        run(.repeatForever(seq), withKey: "idleFlicker")
    }

    private func stopIdleFlicker() {
        removeAction(forKey: "idleFlicker")
    }

    private func flickerRandomNode() {
        guard selectedID == nil, !simNodes.isEmpty,
              let node = simNodes.randomElement(),
              let sprite = node.sprite else { return }

        if let lbl = sprite.childNode(withName: "lbl") as? SKLabelNode {
            lbl.removeAction(forKey: "labelFade")
            lbl.fontColor = .white
            lbl.run(.sequence([
                .fadeIn(withDuration: 0.15),
                .wait(forDuration: 2.0),
                .run { [weak self, weak lbl] in
                    guard let self, let lbl else { return }
                    lbl.fontColor = NSColor.white.withAlphaComponent(0.3)
                    lbl.run(.fadeAlpha(to: self.labelsVisible ? 1.0 : 0.0, duration: 0.3), withKey: "labelFade")
                }
            ]), withKey: "labelFlicker")
        }

        if let glow = sprite.childNode(withName: "glow") {
            glow.setScale(1.0)
            glow.alpha = 0
            glow.run(SKAction.sequence([
                SKAction.group([
                    .scale(to: 2.2, duration: 0.5),
                    .sequence([.fadeAlpha(to: 0.22, duration: 0.15), .fadeOut(withDuration: 0.35)])
                ]),
                SKAction.group([.scale(to: 1.0, duration: 0), .fadeOut(withDuration: 0)])
            ]), withKey: "idleGlow")
        }

        if let ring = sprite.childNode(withName: "ring0") {
            ring.setScale(1.0)
            ring.alpha = 0
            ring.run(SKAction.sequence([
                SKAction.group([
                    .scale(to: 4.0, duration: 1.2),
                    .sequence([.fadeAlpha(to: 0.45, duration: 0.1), .fadeOut(withDuration: 1.1)])
                ]),
                SKAction.group([.scale(to: 1.0, duration: 0), .fadeOut(withDuration: 0)])
            ]), withKey: "idleRing")
        }
    }

    private func startRipple(on sprite: SKNode) {
        if let glow = sprite.childNode(withName: "glow") {
            glow.removeAllActions()
            glow.setScale(1.0)
            glow.alpha = 0.12
            let breathe = SKAction.sequence([
                SKAction.group([.scale(to: 1.5, duration: 2.8), .fadeAlpha(to: 0.20, duration: 2.8)]),
                SKAction.group([.scale(to: 1.0, duration: 2.8), .fadeAlpha(to: 0.12, duration: 2.8)])
            ])
            glow.run(.repeatForever(breathe), withKey: "glow")
        }

        for i in 0..<3 {
            guard let ring = sprite.childNode(withName: "ring\(i)") else { continue }
            ring.removeAllActions()
            ring.setScale(1.0)
            ring.alpha = 0
            let fire = SKAction.sequence([
                SKAction.group([
                    .scale(to: 5.0, duration: 2.2),
                    .sequence([.fadeAlpha(to: 0.7, duration: 0.1), .fadeOut(withDuration: 2.1)])
                ]),
                SKAction.group([.scale(to: 1.0, duration: 0), .fadeOut(withDuration: 0)]),
                .wait(forDuration: 1.0)
            ])
            ring.run(.sequence([.wait(forDuration: Double(i) * 1.0), .repeatForever(fire)]), withKey: "ring")
        }
    }

    private func stopRipple(on sprite: SKNode) {
        sprite.childNode(withName: "glow").map {
            $0.removeAllActions(); $0.run(.fadeOut(withDuration: 0.3))
        }
        for i in 0..<3 {
            guard let ring = sprite.childNode(withName: "ring\(i)") else { continue }
            ring.removeAllActions()
            ring.run(.fadeOut(withDuration: 0.2))
        }
    }

    private func syncSelection(oldID: UUID? = nil) {
        for node in simNodes {
            guard let s = node.sprite else { continue }
            let sel = node.id == selectedID
            if let dot = s.childNode(withName: "dot") as? SKShapeNode {
                dot.fillColor = sel ? .white : NSColor(white: 0.5, alpha: 1.0)
                dot.strokeColor = sel ? .white : .clear
                dot.lineWidth = sel ? 2 : 0
            }
            if let lbl = s.childNode(withName: "lbl") as? SKLabelNode {
                lbl.fontColor = sel ? .white : NSColor.white.withAlphaComponent(0.3)
            }
            if sel && node.id != oldID {
                startRipple(on: s)
            } else if !sel && node.id == oldID {
                stopRipple(on: s)
            }
        }

        if selectedID == nil {
            if action(forKey: "idleFlicker") == nil { startIdleFlicker() }
        } else {
            stopIdleFlicker()
        }

        syncEdgeAnimation()
        syncLabelVisibility()

        guard !isolatedDotsVisible else { return }
        if let old = oldID, old != selectedID,
           let idx = simNodes.firstIndex(where: { $0.id == old }),
           isolatedIndices.contains(idx) {
            simNodes[idx].sprite?.run(.fadeOut(withDuration: 0.3), withKey: "isolatedFade")
        }
        if let newID = selectedID,
           let idx = simNodes.firstIndex(where: { $0.id == newID }),
           isolatedIndices.contains(idx) {
            simNodes[idx].sprite?.run(.fadeIn(withDuration: 0.3), withKey: "isolatedFade")
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
        let r = CGFloat(6)
        for (idx, e) in edges.enumerated() {
            guard idx < edgeNodes.count else { continue }
            let edgeNode = edgeNodes[idx]
            guard e.from < n, e.to < n,
                  let p0 = simNodes[e.from].sprite?.position,
                  let p1 = simNodes[e.to].sprite?.position else {
                edgeNode.path = nil; continue
            }
            let dx = p1.x - p0.x, dy = p1.y - p0.y
            let d = hypot(dx, dy)
            guard d > r * 2 else { edgeNode.path = nil; continue }
            let nx = dx / d, ny = dy / d
            let path = CGMutablePath()
            path.move(to: CGPoint(x: p0.x + nx * r, y: p0.y + ny * r))
            path.addLine(to: CGPoint(x: p1.x - nx * r, y: p1.y - ny * r))
            edgeNode.path = path
        }
    }

    private func startEdgePulse(on edge: SKShapeNode) {
        edge.removeAction(forKey: "edgePulse")
        edge.lineWidth = 1.5
        let pulse = SKAction.repeatForever(SKAction.sequence([
            .fadeAlpha(to: 0.9, duration: 1.4),
            .fadeAlpha(to: 0.45, duration: 1.4)
        ]))
        edge.run(pulse, withKey: "edgePulse")
    }

    private func stopEdgePulse(on edge: SKShapeNode) {
        edge.removeAction(forKey: "edgePulse")
        edge.lineWidth = 1.0
        edge.run(.fadeAlpha(to: 0.4, duration: 0.3), withKey: "edgePulse")
    }

    private func startEdgeParticles(edgeIndex: Int, from fromIdx: Int, to toIdx: Int) {
        guard edgeIndex < edgeParticles.count else { return }
        stopEdgeParticles(edgeIndex: edgeIndex)

        let count = 3
        let duration: Double = 3.5
        let spacing = duration / Double(count)

        edgeParticles[edgeIndex] = (0..<count).map { i in
            let dot = SKShapeNode(circleOfRadius: 2)
            dot.fillColor = .white
            dot.strokeColor = .clear
            dot.alpha = 0
            dot.zPosition = 1
            addChild(dot)

            let move = SKAction.customAction(withDuration: duration) { [weak self] node, elapsed in
                guard let self,
                      let p0 = self.simNodes[fromIdx].sprite?.position,
                      let p1 = self.simNodes[toIdx].sprite?.position else { return }
                let t = CGFloat(elapsed) / CGFloat(duration)
                node.position = CGPoint(x: p0.x + (p1.x - p0.x) * t,
                                        y: p0.y + (p1.y - p0.y) * t)
                if t < 0.15 {
                    node.alpha = t / 0.15
                } else if t > 0.85 {
                    node.alpha = (1.0 - t) / 0.15
                } else {
                    node.alpha = 1.0
                }
            }
            let arrive = SKAction.run { [weak self] in
                guard let self, let sprite = self.simNodes[toIdx].sprite else { return }
                self.pulseArrive(on: sprite)
            }
            dot.run(.sequence([.wait(forDuration: Double(i) * spacing), .repeatForever(.sequence([move, arrive]))]))
            return dot
        }
    }

    private func pulseArrive(on sprite: SKNode) {
        guard let dot = sprite.childNode(withName: "dot") as? SKShapeNode else { return }
        dot.removeAction(forKey: "arrive")
        dot.run(.sequence([
            .scale(to: 1.3, duration: 0.2),
            .scale(to: 1.0, duration: 0.5)
        ]), withKey: "arrive")
    }

    private func stopEdgeParticles(edgeIndex: Int) {
        guard edgeIndex < edgeParticles.count else { return }
        edgeParticles[edgeIndex].forEach { $0.removeFromParent() }
        edgeParticles[edgeIndex] = []
    }

    private func syncEdgeAnimation() {
        let selIdx = selectedID.flatMap { id in simNodes.firstIndex(where: { $0.id == id }) }
        for (idx, e) in edges.enumerated() {
            guard idx < edgeNodes.count else { continue }
            let connected = selIdx.map { e.from == $0 || e.to == $0 } ?? false
            if connected, let si = selIdx {
                startEdgePulse(on: edgeNodes[idx])
                let (from, to) = (e.from == si) ? (e.from, e.to) : (e.to, e.from)
                startEdgeParticles(edgeIndex: idx, from: from, to: to)
            } else {
                stopEdgePulse(on: edgeNodes[idx])
                stopEdgeParticles(edgeIndex: idx)
            }
        }
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
        let id = nearestIndex(to: loc, screenRadius: 40).map { simNodes[$0].id }
        onTap?(id)
    }

    func handleScroll(event: NSEvent, in view: SKView) {
        let factor = pow(1.005, -event.scrollingDeltaY)
        let newScale = max(0.125, min(8.0, cam.xScale * factor))
        let pivot = convertPoint(fromView: view.convert(event.locationInWindow, from: nil))
        let ratio = newScale / cam.xScale
        cam.position = CGPoint(
            x: pivot.x + (cam.position.x - pivot.x) * ratio,
            y: pivot.y + (cam.position.y - pivot.y) * ratio
        )
        cam.setScale(newScale)
        syncLabelScale()
    }

    private func syncLabelScale() {
        let s = cam.xScale
        let shouldShow = s < 1.25
        for node in simNodes {
            guard let lbl = node.sprite?.childNode(withName: "lbl") as? SKLabelNode else { continue }
            lbl.xScale = s
            lbl.yScale = s
        }
        if shouldShow != labelsVisible {
            labelsVisible = shouldShow
            if selectedID == nil {
                let action: SKAction = shouldShow ? .fadeIn(withDuration: 0.3) : .fadeOut(withDuration: 0.3)
                for node in simNodes {
                    node.sprite?.childNode(withName: "lbl")?.run(action, withKey: "labelFade")
                }
            }
        }

        let shouldShowIsolated = s < 2.0
        if shouldShowIsolated != isolatedDotsVisible {
            isolatedDotsVisible = shouldShowIsolated
            let action: SKAction = shouldShowIsolated ? .fadeIn(withDuration: 0.3) : .fadeOut(withDuration: 0.3)
            for i in isolatedIndices where i < simNodes.count {
                if !shouldShowIsolated && simNodes[i].id == selectedID { continue }
                simNodes[i].sprite?.run(action, withKey: "isolatedFade")
            }
        }
    }

    private func neighborIndices(of idx: Int) -> Set<Int> {
        var result = Set<Int>()
        for e in edges {
            if e.from == idx { result.insert(e.to) }
            else if e.to == idx { result.insert(e.from) }
        }
        return result
    }

    private func syncLabelVisibility() {
        if let selIdx = simNodes.firstIndex(where: { $0.id == selectedID }) {
            let visible = neighborIndices(of: selIdx).union([selIdx])
            for (i, node) in simNodes.enumerated() {
                let show = visible.contains(i)
                node.sprite?.childNode(withName: "lbl")?.run(
                    show ? .fadeIn(withDuration: 0.3) : .fadeOut(withDuration: 0.3),
                    withKey: "labelFade"
                )
            }
        } else {
            let action: SKAction = labelsVisible ? .fadeIn(withDuration: 0.3) : .fadeOut(withDuration: 0.3)
            for node in simNodes {
                node.sprite?.childNode(withName: "lbl")?.run(action, withKey: "labelFade")
            }
        }
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
