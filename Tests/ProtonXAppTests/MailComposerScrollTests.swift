// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing
import SwiftUI
@testable import ProtonXApp

@Suite @MainActor struct MailComposerScrollTests {
    @Test func hostingProbeSharesTheEditorBounds() async throws {
        let host = NSHostingView(rootView: ScrollView { VStack { TextEditor(text: .constant("Synthetic")).background(MailComposerScrollHandoff().allowsHitTesting(false)).frame(width: 500, height: 230); Text("Synthetic quote").frame(height: 1200) } })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 230), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        for _ in 0..<10 { await Task.yield() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(host)
        let probe = try #require(views.compactMap { $0 as? ComposerScrollProbe }.first)
        let text = try #require(views.compactMap { $0 as? NSTextView }.first)
        #expect(probe.isMonitoring)
        #expect(probe.bounds.width >= 490 && probe.bounds.height >= 220)
        let point = host.convert(text.convert(NSPoint(x: 20, y: 20), to: nil), from: nil)
        let hit = host.hitTest(point)
        #expect(hit is NSTextView)
        let probePoint = probe.convert(text.convert(NSPoint(x: 20, y: 20), to: nil), from: nil)
        #expect(probe.bounds.intersection(probe.visibleRect).contains(probePoint))
        let inner = try #require(text.enclosingScrollView)
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -80, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: wheel))
        // Exercise SwiftUI's real TextEditor/ScrollView hierarchy, in addition
        // to the recording fixture below. An offscreen event tests dispatch,
        // while the native preview verifies visible movement.
        #expect(probe.forwardVerticalScroll(event, from: inner))
    }
    @Test func shortBodiesAndLongBodyEdgesHandOffButInteriorAndHorizontalGesturesDoNot() {
        let viewport = NSRect(x: 0, y: 0, width: 500, height: 230)
        let short = NSRect(x: 0, y: 0, width: 500, height: 80)
        let long = NSRect(x: 0, y: 0, width: 500, height: 1000)
        func forwards(_ dy: CGFloat, _ visible: NSRect, _ doc: NSRect, dx: CGFloat = 0, flipped: Bool = true) -> Bool {
            ComposerScrollProbe.shouldForward(deltaX: dx, deltaY: dy, viewport: visible, document: doc, flipped: flipped)
        }
        #expect(forwards(-40, viewport, short))
        #expect(forwards(40, viewport, short))
        #expect(!forwards(0, viewport, short))
        #expect(!forwards(-5, viewport, short, dx: 40))
        #expect(forwards(40, viewport, long))
        #expect(!forwards(-40, viewport, long))
        let middle = NSRect(x: 0, y: 300, width: 500, height: 230)
        #expect(!forwards(40, middle, long))
        #expect(!forwards(-40, middle, long))
        let bottom = NSRect(x: 0, y: 770, width: 500, height: 230)
        #expect(forwards(-40, bottom, long))
        #expect(!forwards(40, bottom, long))
        #expect(forwards(-40, viewport, long, flipped: false))
        #expect(forwards(40, bottom, long, flipped: false))
    }
    @Test func nativeHandoffTargetsOnlyTheEnclosingComposerAndMonitoringStopsOnDetach() throws {
        final class RecordingScroll: NSScrollView {
            var forwarded = 0
            override func scrollWheel(with event: NSEvent) { forwarded += 1 }
        }
        let outer = RecordingScroll(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1200))
        outer.documentView = document
        let inner = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 230))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        inner.documentView = text; document.addSubview(inner)
        let probe = ComposerScrollProbe(frame: inner.frame); document.addSubview(probe)
        let window = NSWindow(contentRect: outer.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = outer
        defer { window.contentView = nil; probe.stopMonitoring() }
        outer.layoutSubtreeIfNeeded()
        #expect(probe.isMonitoring)
        #expect(probe.hitTest(.zero) == nil)
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -80, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: wheel))
        #expect(probe.forwardVerticalScroll(event, from: inner))
        #expect(outer.forwarded == 1)
        // No outer scroll view means no swallowed gesture.
        inner.removeFromSuperview()
        #expect(!probe.forwardVerticalScroll(event, from: inner))
        #expect(outer.forwarded == 1)
        probe.removeFromSuperview()
        #expect(!probe.isMonitoring)
    }
}
