// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// Keep the native TextEditor, including selection, undo and spelling. AppKit's
/// inner text scroll view otherwise consumes wheel events even at its edges.
struct MailComposerScrollHandoff: NSViewRepresentable {
    func makeNSView(context: Context) -> ComposerScrollProbe { ComposerScrollProbe() }
    func updateNSView(_ view: ComposerScrollProbe, context: Context) {}
    static func dismantleNSView(_ view: ComposerScrollProbe, coordinator: ()) { view.stopMonitoring() }
}

@MainActor final class ComposerScrollProbe: NSView {
    private var monitor: Any?
    var isMonitoring: Bool { monitor != nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  self.bounds.intersection(self.visibleRect).contains(self.convert(event.locationInWindow, from: nil)),
                  let root = window.contentView else { return event }
            // Only the TextEditor underneath this probe may hand off scrolling.
            // Do not intercept other fields, popovers or another product/window.
            var hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
            while let view = hit {
                if let text = view as? NSTextView, let scroll = text.enclosingScrollView {
                    return self.forwardVerticalScroll(event, from: scroll) ? nil : event
                }
                hit = view.superview
            }
            return event
        }
    }
    @discardableResult func forwardVerticalScroll(_ event: NSEvent, from inner: NSScrollView) -> Bool {
        guard let text = inner.documentView as? NSTextView,
              Self.shouldForward(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                 viewport: inner.contentView.bounds, document: inner.contentView.documentRect,
                                 flipped: text.isFlipped) else { return false }
        var ancestor = inner.superview
        while let view = ancestor {
            if let outer = view as? NSScrollView { outer.scrollWheel(with: event); return true }
            ancestor = view.superview
        }
        return false
    }
    static func shouldForward(deltaX: CGFloat, deltaY: CGFloat, viewport: NSRect, document: NSRect, flipped: Bool) -> Bool {
        guard deltaY != 0, abs(deltaY) >= abs(deltaX) else { return false }
        if document.height <= viewport.height + 1 { return true }
        let towardStart = flipped ? deltaY > 0 : deltaY < 0
        return towardStart ? viewport.minY <= document.minY + 1 : viewport.maxY >= document.maxY - 1
    }
    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
