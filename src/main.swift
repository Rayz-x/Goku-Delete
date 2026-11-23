// GokuDelete v2 — intercepts Finder deletes, Goku fires a Kamehameha at the
// file icon across a full-desktop click-through overlay, then the file is trashed.
// Silent. Never loses a delete: any failure falls back to Finder's own delete.
import Cocoa
import QuartzCore
import ApplicationServices

// MARK: - Logging
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GokuDelete.log")
func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.data(using: .utf8)!.write(to: logURL) }
}

// MARK: - Constants
let MAGIC: Int64 = 0x60C0DE1
let kDeleteKey: Int64 = 51
let finderBundle = "com.apple.finder"
let trashTitles: Set<String> = ["Move to Trash", "Move to Bin"]
let S: CGFloat = 130.0 / 556.0          // points per source-video pixel (Goku ~130pt tall)
let anchorV = CGPoint(x: 330, y: 350)  // body anchor in video px (y down)
let chargeRectV = CGRect(x: 108, y: 72, width: 464, height: 556)
let fireRectV = CGRect(x: 40, y: 105, width: 510, height: 478)
let orbV = CGPoint(x: 528, y: 337)
let handV = CGPoint(x: 530, y: 308)
let resDir = Bundle.main.resourceURL!

func localRect(_ r: CGRect, flip: Bool) -> CGRect {
    var x0 = (r.minX - anchorV.x) * S, x1 = (r.maxX - anchorV.x) * S
    if flip { (x0, x1) = (-x1, -x0) }
    let y0 = (anchorV.y - r.maxY) * S, y1 = (anchorV.y - r.minY) * S
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
}
func localPoint(_ p: CGPoint, flip: Bool) -> CGPoint {
    CGPoint(x: (p.x - anchorV.x) * S * (flip ? -1 : 1), y: (anchorV.y - p.y) * S)
}
func loadCG(_ name: String) -> CGImage? {
    guard let img = NSImage(contentsOf: resDir.appendingPathComponent(name)) else { return nil }
    var r = CGRect(origin: .zero, size: img.size)
    return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
}
let chargeImg = loadCG("goku_charge.png")
let fireImg = loadCG("goku_fire.png")

// MARK: - Geometry helpers
var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
func axToCocoa(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
func axRectToCocoa(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

// MARK: - Accessibility helpers
func ax(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func axElems(_ e: AXUIElement, _ a: String) -> [AXUIElement] { (ax(e, a) as? [AXUIElement]) ?? [] }
func axRect(_ e: AXUIElement) -> CGRect? {
    guard let pv = ax(e, kAXPositionAttribute), let sv = ax(e, kAXSizeAttribute) else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}
func axURL(_ e: AXUIElement, depth: Int = 0) -> URL? {
    if let u = ax(e, kAXURLAttribute) as? URL { return (u as NSURL).filePathURL ?? u }
    if depth >= 3 { return nil }
    for c in axElems(e, kAXChildrenAttribute) { if let u = axURL(c, depth: depth + 1) { return u } }
    return nil
}
func axFindImage(_ e: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if (ax(e, kAXRoleAttribute) as? String) == "AXImage" { return e }
    if depth >= 3 { return nil }
    for c in axElems(e, kAXChildrenAttribute) { if let i = axFindImage(c, depth: depth + 1) { return i } }
    return nil
}

func finderApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: finderBundle).first
}
func finderFrontmost() -> Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderBundle }

struct Selection {
    var elements: [AXUIElement]
    var urls: [URL]
    var targets: [CGPoint]   // cocoa global
    var fallbackTarget: CGPoint
}
enum SelResult { case text, none, sel(Selection) }

/// Fallback when the focused element doesn't lead to a selection (e.g. right after a menu closes):
/// search Finder's focused window (or the desktop) for the content view holding a selection.
func findSelectionContainer(_ app: AXUIElement) -> (AXUIElement, [AXUIElement])? {
    var roots: [AXUIElement] = []
    if let fw = ax(app, kAXFocusedWindowAttribute) { roots.append(fw as! AXUIElement) }
    for w in axElems(app, kAXWindowsAttribute) where (ax(w, kAXRoleAttribute) as? String) == "AXScrollArea" { roots.append(w) }  // desktop
    for r in roots {
        var queue: [(AXUIElement, Int)] = [(r, 0)]
        while !queue.isEmpty {
            let (e, d) = queue.removeFirst()
            let role = ax(e, kAXRoleAttribute) as? String ?? ""
            if role == "AXToolbar" || (ax(e, kAXDescriptionAttribute) as? String)?.lowercased() == "sidebar" { continue }
            if ["AXList", "AXOutline", "AXGroup", "AXTable"].contains(role) {
                var ss = axElems(e, kAXSelectedChildrenAttribute)
                if ss.isEmpty { ss = axElems(e, kAXSelectedRowsAttribute) }
                if !ss.isEmpty { return (e, ss) }
            }
            if d < 7 { for c in axElems(e, kAXChildrenAttribute) { queue.append((c, d + 1)) } }
        }
    }
    return nil
}

func readSelection() -> SelResult {
    guard let f = finderApp() else { return .none }
    let app = AXUIElementCreateApplication(f.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 0.6)
    let focused = ax(app, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement } ?? app
    let role = ax(focused, kAXRoleAttribute) as? String ?? ""
    if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" { return .text }
    var container: AXUIElement? = focused
    var sel: [AXUIElement] = []
    for _ in 0..<5 {
        guard let c = container else { break }
        sel = axElems(c, kAXSelectedChildrenAttribute)
        if sel.isEmpty { sel = axElems(c, kAXSelectedRowsAttribute) }
        if !sel.isEmpty {
            if (ax(c, kAXDescriptionAttribute) as? String)?.lowercased() == "sidebar" { log("sidebar focused, pass through"); return .none }
            break
        }
        container = ax(c, kAXParentAttribute).map { $0 as! AXUIElement }
    }
    if sel.isEmpty, let (c, ss) = findSelectionContainer(app) { container = c; sel = ss; log("selection via window search") }
    if sel.isEmpty { log("no selection found (focused role \(role))"); return .none }
    // visible area: nearest scroll area / window
    var clip: CGRect? = nil
    var p: AXUIElement? = container
    for _ in 0..<6 {
        guard let e = p else { break }
        let r = ax(e, kAXRoleAttribute) as? String
        if r == "AXScrollArea" || r == "AXWindow" { clip = axRect(e); break }
        p = ax(e, kAXParentAttribute).map { $0 as! AXUIElement }
    }
    if clip == nil, let w = ax(container ?? focused, kAXWindowAttribute) { clip = axRect(w as! AXUIElement) }
    let clipC = clip.map(axRectToCocoa)
    let fallback = clipC.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: NSScreen.main!.frame.midX, y: NSScreen.main!.frame.midY)
    var urls: [URL] = [], targets: [CGPoint] = []
    for e in sel {
        if let u = axURL(e) { urls.append(u) }
        let target = axFindImage(e).flatMap(axRect) ?? axRect(e).map { r in
            r.width > 200 ? CGRect(x: r.minX + 20, y: r.minY, width: 24, height: r.height) : r }
        if let t = target {
            let c = axRectToCocoa(t)
            let pt = CGPoint(x: c.midX, y: c.midY)
            if let cc = clipC, !cc.contains(pt) { continue }
            targets.append(pt)
        }
    }
    if targets.isEmpty { targets = [fallback] }
    return .sel(Selection(elements: sel, urls: urls, targets: targets, fallbackTarget: fallback))
}

// MARK: - Delete actions
func postKeys(_ seq: [(CGKeyCode, Bool, CGEventFlags)]) {
    let src = CGEventSource(stateID: .hidSystemState)
    for (k, down, fl) in seq {
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: down) else { continue }
        ev.flags = fl
        ev.setIntegerValueField(.eventSourceUserData, value: MAGIC)
        ev.post(tap: .cghidEventTap)
        usleep(15000)
    }
}
func postDeleteKeystroke() {
    // Explicit Command down/up around Delete — Finder ignores a bare flagged Delete.
    postKeys([(55, true, .maskCommand), (51, true, .maskCommand), (51, false, .maskCommand), (55, false, [])])
}
func postEscape() { postKeys([(53, true, []), (53, false, [])]) }
let protectedPaths: Set<String> = {
    let h = FileManager.default.homeDirectoryForCurrentUser.path
    var s: Set<String> = ["/", "/Users", "/Applications", "/System", "/Library", "/Volumes", h]
    for d in ["Desktop", "Documents", "Downloads", "Applications", "Library", "Movies", "Music", "Pictures", "Public"] { s.insert(h + "/" + d) }
    return s
}()
func recycle(_ urls: [URL]) {
    let safe = urls.filter { $0.isFileURL && !protectedPaths.contains($0.standardizedFileURL.path) && FileManager.default.fileExists(atPath: $0.path) }
    guard !safe.isEmpty else { log("recycle: nothing safe to recycle"); return }
    NSWorkspace.shared.recycle(safe) { _, err in log("recycled \(safe.map { $0.path }) err=\(String(describing: err))") }
}

// MARK: - Overlay
final class Overlay {
    var panels: [NSPanel] = []
    var roots: [CALayer] = []
    init() {
        for screen in NSScreen.screens {
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.setFrame(screen.frame, display: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.ignoresMouseEvents = true; p.hidesOnDeactivate = false
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let root = CALayer()
            root.frame = v.bounds
            root.masksToBounds = true
            root.sublayerTransform = CATransform3DMakeTranslation(-screen.frame.minX, -screen.frame.minY, 0)
            root.contentsScale = screen.backingScaleFactor
            v.layer = root; v.wantsLayer = true
            p.contentView = v
            p.orderFrontRegardless()
            panels.append(p); roots.append(root)
        }
    }
    func close() { for p in panels { p.orderOut(nil); p.close() } ; panels = []; roots = [] }
}

func circleLayer(_ r: CGFloat, _ color: NSColor, glow: NSColor, scale: CGFloat) -> CALayer {
    let l = CALayer()
    l.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
    l.cornerRadius = r
    l.backgroundColor = color.cgColor
    l.shadowColor = glow.cgColor; l.shadowOpacity = 1; l.shadowRadius = r * 0.9; l.shadowOffset = .zero
    l.contentsScale = scale
    return l
}

let beamBlue = NSColor(calibratedRed: 0.25, green: 0.7, blue: 1.0, alpha: 0.95)
let glowBlue = NSColor(calibratedRed: 0.3, green: 0.75, blue: 1.0, alpha: 1)

var animating = false

/// Runs the full animation. `onHit` is called the moment the last beam hits.
func runAnimation(targets rawTargets: [CGPoint], onHit: @escaping () -> Void, done: @escaping () -> Void) {
    let targets = Array(rawTargets.prefix(8))
    guard let first = targets.first else { onHit(); done(); return }
    animating = true
    // Choose a random spot on a random screen, reasonably far from the target.
    let screens = NSScreen.screens
    var best: (CGPoint, NSScreen)? = nil; var bestD: CGFloat = -1
    for _ in 0..<40 {
        let sc = screens.randomElement()!
        let vf = sc.visibleFrame.insetBy(dx: 80, dy: 80)
        guard vf.width > 0, vf.height > 0 else { continue }
        // bias towards edges: pick an edge band
        let edge = Int.random(in: 0..<4)
        var p = CGPoint(x: CGFloat.random(in: vf.minX...vf.maxX), y: CGFloat.random(in: vf.minY...vf.maxY))
        let band: CGFloat = min(vf.width, vf.height) * 0.25
        switch edge {
        case 0: p.x = vf.minX + CGFloat.random(in: 0...band)
        case 1: p.x = vf.maxX - CGFloat.random(in: 0...band)
        case 2: p.y = vf.minY + CGFloat.random(in: 0...band)
        default: p.y = vf.maxY - CGFloat.random(in: 0...band)
        }
        let d = dist(p, first)
        if d >= 260 && d <= 1800 { best = (p, sc); break }
        if d > bestD { bestD = d; best = (p, sc) }
    }
    let (P, scr) = best ?? (CGPoint(x: screens[0].frame.midX, y: screens[0].frame.midY), screens[0])
    let flip = first.x < P.x
    // Fly in from the nearest edge of that screen
    let f = scr.frame
    let dl = P.x - f.minX, dr = f.maxX - P.x, db = P.y - f.minY, dt = f.maxY - P.y
    let m = min(dl, dr, db, dt)
    var start = P
    if m == dl { start.x = f.minX - 150 } else if m == dr { start.x = f.maxX + 150 } else if m == db { start.y = f.minY - 150 } else { start.y = f.maxY + 150 }

    let overlay = Overlay()
    let hand = localPoint(handV, flip: flip), orb = localPoint(orbV, flip: flip)
    let H = CGPoint(x: P.x + hand.x, y: P.y + hand.y)
    struct Actors { let goku: CALayer; let charge: CALayer; let fire: CALayer; let orbGlow: CALayer; let root: CALayer; let scale: CGFloat }
    var actors: [Actors] = []
    CATransaction.begin(); CATransaction.setDisableActions(true)
    for (i, root) in overlay.roots.enumerated() {
        let scale = overlay.panels[i].screen?.backingScaleFactor ?? 2
        let g = CALayer(); g.bounds = .zero; g.position = start; g.opacity = 0
        let ch = CALayer(); ch.frame = localRect(chargeRectV, flip: false); ch.contents = chargeImg
        let fi = CALayer(); fi.frame = localRect(fireRectV, flip: false); fi.contents = fireImg; fi.opacity = 0
        for l in [ch, fi] { l.contentsGravity = .resizeAspect; l.contentsScale = scale; l.minificationFilter = .trilinear }
        let og = circleLayer(9, NSColor.white, glow: glowBlue, scale: scale)
        og.position = localPoint(orbV, flip: false); og.opacity = 0
        g.addSublayer(ch); g.addSublayer(fi); g.addSublayer(og)
        if flip { g.sublayerTransform = CATransform3DMakeScale(-1, 1, 1) }
        root.addSublayer(g)
        actors.append(Actors(goku: g, charge: ch, fire: fi, orbGlow: og, root: root, scale: scale))
    }
    CATransaction.commit()
    _ = orb

    let main = DispatchQueue.main
    // 1. fly in
    main.asyncAfter(deadline: .now() + 0.03) {
        CATransaction.begin(); CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for a in actors { a.goku.position = P; a.goku.opacity = 1 }
        CATransaction.commit()
    }
    // 2. charge: orb pulse
    main.asyncAfter(deadline: .now() + 0.4) {
        for a in actors {
            a.orbGlow.opacity = 1
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.6; pulse.toValue = 1.8; pulse.duration = 0.12; pulse.autoreverses = true; pulse.repeatCount = 2
            a.orbGlow.add(pulse, forKey: "pulse")
        }
    }
    // 3. fire: beams sequentially to each target
    let fireT = 0.9, per = 0.32, grow = 0.2
    main.asyncAfter(deadline: .now() + fireT) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for a in actors { a.charge.opacity = 0; a.fire.opacity = 1; a.orbGlow.opacity = 0 }
        CATransaction.commit()
    }
    var beamLayers: [[CALayer]] = Array(repeating: [], count: actors.count)
    for (ti, T) in targets.enumerated() {
        let t0 = fireT + Double(ti) * per
        main.asyncAfter(deadline: .now() + t0) {
            let path = CGMutablePath(); path.move(to: H); path.addLine(to: T)
            let len = dist(H, T)
            let thick: CGFloat = 9
            for (ai, a) in actors.enumerated() {
                // fade previous beam
                for old in beamLayers[ai] { CATransaction.begin(); CATransaction.setAnimationDuration(0.12); old.opacity = 0; CATransaction.commit() }
                let glow = CAShapeLayer(); glow.path = path; glow.strokeColor = beamBlue.cgColor; glow.lineWidth = thick * 2.0
                glow.lineCap = .round; glow.fillColor = nil; glow.shadowColor = glowBlue.cgColor; glow.shadowOpacity = 1; glow.shadowRadius = 10; glow.shadowOffset = .zero
                let core = CAShapeLayer(); core.path = path; core.strokeColor = NSColor.white.cgColor; core.lineWidth = thick * 0.75
                core.lineCap = .round; core.fillColor = nil; core.shadowColor = NSColor.white.cgColor; core.shadowOpacity = 1; core.shadowRadius = 4; core.shadowOffset = .zero
                let tip = circleLayer(thick * 1.3, .white, glow: glowBlue, scale: a.scale); tip.position = T
                let base = circleLayer(thick * 1.1, .white, glow: glowBlue, scale: a.scale); base.position = H
                for l in [glow, core] { l.contentsScale = a.scale; l.strokeEnd = 1 }
                a.root.addSublayer(glow); a.root.addSublayer(core); a.root.addSublayer(base); a.root.addSublayer(tip)
                let se = CABasicAnimation(keyPath: "strokeEnd"); se.fromValue = 0; se.toValue = 1; se.duration = grow
                glow.add(se, forKey: "grow"); core.add(se, forKey: "grow")
                let mv = CABasicAnimation(keyPath: "position"); mv.fromValue = NSValue(point: H); mv.toValue = NSValue(point: T); mv.duration = grow
                tip.add(mv, forKey: "mv")
                let fl = CAKeyframeAnimation(keyPath: "lineWidth"); fl.values = [thick * 2.0, thick * 2.5, thick * 1.8, thick * 2.3]; fl.duration = 0.16; fl.repeatCount = 20
                glow.add(fl, forKey: "flicker")
                beamLayers[ai] += [glow, core, base, tip]
                _ = len
            }
        }
        // hit + burst
        main.asyncAfter(deadline: .now() + t0 + grow) {
            for a in actors {
                let b = circleLayer(26, .white, glow: glowBlue, scale: a.scale); b.position = T; b.opacity = 0
                let ring = CAShapeLayer(); ring.path = CGPath(ellipseIn: CGRect(x: -30, y: -30, width: 60, height: 60), transform: nil)
                ring.position = T; ring.strokeColor = glowBlue.cgColor; ring.fillColor = nil; ring.lineWidth = 6; ring.opacity = 0; ring.contentsScale = a.scale
                ring.shadowColor = glowBlue.cgColor; ring.shadowOpacity = 1; ring.shadowRadius = 8; ring.shadowOffset = .zero
                a.root.addSublayer(b); a.root.addSublayer(ring)
                let sc = CABasicAnimation(keyPath: "transform.scale"); sc.fromValue = 0.3; sc.toValue = 2.2
                let op = CABasicAnimation(keyPath: "opacity"); op.fromValue = 1; op.toValue = 0
                let g1 = CAAnimationGroup(); g1.animations = [sc, op]; g1.duration = 0.45
                b.add(g1, forKey: "burst")
                let sc2 = CABasicAnimation(keyPath: "transform.scale"); sc2.fromValue = 0.4; sc2.toValue = 3.0
                let g2 = CAAnimationGroup(); g2.animations = [sc2, op]; g2.duration = 0.5
                ring.add(g2, forKey: "burst")
            }
            if ti == targets.count - 1 { onHit() }
        }
    }
    // 4. beam fades, Goku fades out
    let endT = fireT + Double(targets.count - 1) * per + grow + 0.25
    main.asyncAfter(deadline: .now() + endT) {
        CATransaction.begin(); CATransaction.setAnimationDuration(0.25)
        for ls in beamLayers { for l in ls { l.opacity = 0 } }
        CATransaction.commit()
    }
    main.asyncAfter(deadline: .now() + endT + 0.2) {
        CATransaction.begin(); CATransaction.setAnimationDuration(0.35)
        for a in actors { a.goku.opacity = 0; a.goku.position = CGPoint(x: P.x, y: P.y + 40) }
        CATransaction.commit()
    }
    main.asyncAfter(deadline: .now() + endT + 0.65) {
        overlay.close(); animating = false; done()
    }
}

// MARK: - Delete flow
var pendingFallback: DispatchWorkItem? = nil

func handleDelete(viaMenu: Bool) {
    // Safety net: if anything stalls, do the normal delete after 6 s.
    let fb = DispatchWorkItem { log("watchdog fired: normal delete"); animating = false; postDeleteKeystroke() }
    pendingFallback = fb
    DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: fb)
    func finish(_ action: () -> Void) { guard let p = pendingFallback, !p.isCancelled else { return }; p.cancel(); pendingFallback = nil; action() }

    switch readSelection() {
    case .text:
        finish { postDeleteKeystroke() }   // renaming text etc: behave normally
    case .none:
        finish { postDeleteKeystroke() }
    case .sel(let s):
        log("intercepted delete (menu=\(viaMenu)): \(s.elements.count) item(s) \(s.urls.map { $0.lastPathComponent }) targets=\(s.targets.map { "(\(Int($0.x)),\(Int($0.y)))" })")
        runAnimation(targets: s.targets, onHit: {
            finish { performDelete(s) }
        }, done: {})
    }
}

func sameSelection(_ s: Selection) -> Bool {
    guard case .sel(let now) = readSelection() else { return false }
    if now.elements.count != s.elements.count { return false }
    if !s.urls.isEmpty && Set(now.urls) == Set(s.urls) { return true }
    return zip(now.elements, s.elements).allSatisfy { CFEqual($0, $1) }
}

func performDelete(_ s: Selection) {
    if finderFrontmost() && sameSelection(s) { log("delete via Finder (Cmd+Delete replay)"); postDeleteKeystroke(); return }
    // Finder lost focus or selection changed during the animation.
    if !s.urls.isEmpty { log("selection changed; recycling captured items"); recycle(s.urls); return }
    if let f = finderApp() {
        f.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if sameSelection(s) { postDeleteKeystroke() } else { log("could not re-find selection; delete skipped, file left in place") }
        }
    }
}

// MARK: - Event tap
var eventTap: CFMachPort?

func menuItemIsTrash(at loc: CGPoint) -> Bool {
    guard let f = finderApp() else { return false }
    let sys = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(sys, 0.25)
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(sys, Float(loc.x), Float(loc.y), &el) == .success, let e = el else { return false }
    var pid: pid_t = 0; AXUIElementGetPid(e, &pid)
    guard pid == f.processIdentifier else { return false }
    guard (ax(e, kAXRoleAttribute) as? String) == "AXMenuItem" else { return false }
    let title = (ax(e, kAXTitleAttribute) as? String) ?? ""
    let enabled = (ax(e, kAXEnabledAttribute) as? Bool) ?? true
    return enabled && trashTitles.contains(title)
}

var swallowNextMouseUp = false

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        log("tap re-enabled after \(type.rawValue)")
        return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.eventSourceUserData) == MAGIC { return Unmanaged.passUnretained(event) }
    guard finderFrontmost() else { return Unmanaged.passUnretained(event) }
    switch type {
    case .keyDown:
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let fl = event.flags
        let mods: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        guard code == kDeleteKey, fl.intersection(mods) == .maskCommand else { break }
        if animating { break }   // already busy: let Finder delete normally
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
        DispatchQueue.main.async { handleDelete(viaMenu: false) }
        return nil
    case .keyUp:
        break
    case .leftMouseDown:
        if !animating && menuItemIsTrash(at: event.location) { swallowNextMouseUp = true; return nil }
    case .leftMouseUp:
        if swallowNextMouseUp || (!animating && menuItemIsTrash(at: event.location)) {
            swallowNextMouseUp = false
            DispatchQueue.main.async {
                postEscape()   // close the menu
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { handleDelete(viaMenu: true) }
            }
            return nil
        }
    default: break
    }
    return Unmanaged.passUnretained(event)
}

func installTap() -> Bool {
    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else { return false }
    eventTap = tap
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

// MARK: - Main
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let args = CommandLine.arguments

if args.contains("--test") {
    // Animate at a dummy target (mouse location or given x y) without deleting anything.
    var target = NSEvent.mouseLocation
    if let i = args.firstIndex(of: "--at"), args.count > i + 2, let x = Double(args[i + 1]), let y = Double(args[i + 2]) { target = CGPoint(x: x, y: y) }
    log("test animation at \(Int(target.x)),\(Int(target.y))")
    DispatchQueue.main.async {
        runAnimation(targets: [target], onHit: { log("test hit") }, done: { log("test done"); exit(0) })
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(2) }
    app.run()
} else if args.contains("--check") {
    print(AXIsProcessTrusted() ? "trusted" : "not-trusted"); exit(0)
} else {
    log("agent starting (pid \(getpid()))")
    func tryStart() {
        if AXIsProcessTrusted(), installTap() { log("event tap installed — Goku is watching Finder deletes"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { tryStart() }
    }
    if !AXIsProcessTrusted() {
        log("Accessibility not granted yet — prompting")
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }
    tryStart()
    app.run()
}
