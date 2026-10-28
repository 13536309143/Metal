import AppKit
import MetalKit

final class ViewerView: MTKView {

    weak var renderer: Renderer?

    private enum DragMode {
        case none, orbit, pan
    }

    private var dragMode: DragMode = .none
    private var lastPoint = NSPoint.zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastPoint = convert(event.locationInWindow, from: nil)
        dragMode = event.modifierFlags.contains(.shift) ? .pan : .orbit
    }

    override func mouseDragged(with event: NSEvent) {
        handleDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = .none
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastPoint = convert(event.locationInWindow, from: nil)
        dragMode = .pan
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleDrag(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        dragMode = .none
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastPoint = convert(event.locationInWindow, from: nil)
        dragMode = .pan
    }

    override func otherMouseDragged(with event: NSEvent) {
        handleDrag(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        dragMode = .none
    }

    override func scrollWheel(with event: NSEvent) {
        let raw = event.scrollingDeltaY
        let steps = event.hasPreciseScrollingDeltas ? raw / 10 : raw * 5
        renderer?.zoom(delta: Float(steps))
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r":
            renderer?.resetView()
            return
        case "l":
            renderer?.cycleLODLock()
            return
        case "m":
            renderer?.cycleRenderMode()
            return
        case "1":
            renderer?.setRenderMode(.shaded)
            return
        case "2":
            renderer?.setRenderMode(.wireframe)
            return
        case "3":
            renderer?.setRenderMode(.boundingBox)
            return
        case "4":
            renderer?.setRenderMode(.lodColor)
            return
        default:
            super.keyDown(with: event)
        }
    }

    private func handleDrag(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - lastPoint.x
        let dy = point.y - lastPoint.y
        lastPoint = point

        switch dragMode {
        case .orbit: renderer?.orbit(dx: dx, dy: dy)
        case .pan: renderer?.pan(dx: dx, dy: dy)
        case .none: break
        }
    }
}
