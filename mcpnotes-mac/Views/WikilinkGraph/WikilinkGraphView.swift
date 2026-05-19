import SwiftUI
import SpriteKit

private struct GraphSKViewRepresentable: NSViewRepresentable {
    @Environment(NoteStore.self) private var store
    let reloadID: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GraphSKView {
        let c = context.coordinator
        c.store = store
        let skv = GraphSKView()
        skv.ignoresSiblingOrder = true

        let scene = GraphSKScene()
        scene.scaleMode = .resizeFill
        scene.backgroundColor = .black
        scene.onTap = { [weak c] id in c?.store?.selectedNoteID = id }
        c.scene = scene
        skv.presentScene(scene)

        skv.addGestureRecognizer(NSPanGestureRecognizer(target: scene, action: #selector(GraphSKScene.handlePan(_:))))
        skv.addGestureRecognizer(NSClickGestureRecognizer(target: scene, action: #selector(GraphSKScene.handleClick(_:))))

        c.scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak skv, weak scene] event in
            guard let v = skv, v.window != nil, v.window == event.window else { return event }
            scene?.handleScroll(event: event, in: v)
            return nil
        }

        skv.onWindowBecomeVisible = { [weak c] in c?.reloadGraph() }

        return skv
    }

    func updateNSView(_ nsView: GraphSKView, context: Context) {
        let c = context.coordinator
        c.store = store

        let ids = store.notes.map(\.id)
        if c.loadedIDs != ids || c.reloadID != reloadID {
            c.loadedIDs = ids
            c.reloadID = reloadID
            c.reloadGraph()
        }

        c.scene?.selectedID = store.selectedNoteID
    }

    static func dismantleNSView(_ nsView: GraphSKView, coordinator: Coordinator) {
        if let m = coordinator.scrollMonitor { NSEvent.removeMonitor(m) }
        coordinator.scrollMonitor = nil
    }

    final class Coordinator {
        var scene: GraphSKScene?
        var store: NoteStore?
        var loadedIDs: [UUID] = []
        var reloadID: Int = -1
        var scrollMonitor: Any?

        func reloadGraph() {
            guard let scene, let store else { return }
            scene.clearImmediate()
            Task {
                let notes = store.notes
                let rawEdges = await store.allWikilinkEdges()
                scene.load(notes: notes, rawEdges: rawEdges)
            }
        }
    }
}

struct WikilinkGraphView: View {
    @Environment(NoteStore.self) private var store
    @State private var reloadID = 0

    var body: some View {
        GraphSKViewRepresentable(reloadID: reloadID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .onAppear { reloadID += 1 }
    }
}
