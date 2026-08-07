//
//  A11yDump.swift
//  JeevesUITests
//
//  Turns the app's live accessibility hierarchy into JSON a judge can read.
//
//  NOT `XCUIApplication.debugDescription`. That is a debugging aid: its format
//  carries no compatibility promise, and it elides long label and value strings —
//  which are exactly the strings the judge needs in order to decide whether a
//  control was ever built.
//
//  `snapshot()` returns the same tree the query engine matches against, with
//  every field addressable. The one field it does not give you is the one that
//  matters most here, so we compute it: `onScreen`. A control that exists but is
//  scrolled out of view and a control that does not exist at all look identical
//  in a flat dump, and treating the first as missing would make the whole
//  exercise lie.
//

import XCTest

struct A11yNode: Codable {
    let type: String
    let identifier: String
    let label: String
    let title: String
    let value: String
    let placeholder: String
    let isEnabled: Bool
    let isSelected: Bool
    let frame: [Double]      // x, y, w, h
    let onScreen: Bool
    let children: [A11yNode]
}

enum A11yDump {

    /// Recursively serialize a snapshot. `screen` is the device's own bounds,
    /// used to decide `onScreen`.
    static func node(from snapshot: XCUIElementSnapshot, screen: CGRect) -> A11yNode {
        let f = snapshot.frame
        return A11yNode(
            type: name(for: snapshot.elementType),
            identifier: snapshot.identifier,
            label: snapshot.label,
            title: snapshot.title,
            value: String(describing: snapshot.value ?? ""),
            placeholder: snapshot.placeholderValue ?? "",
            isEnabled: snapshot.isEnabled,
            isSelected: snapshot.isSelected,
            frame: [f.origin.x, f.origin.y, f.size.width, f.size.height].map(Double.init),
            // A zero-size frame is a real thing in SwiftUI (spacers, empty
            // containers) and is not "on screen" in any useful sense.
            onScreen: !f.isEmpty && f.intersects(screen),
            children: snapshot.children.map { node(from: $0, screen: screen) }
        )
    }

    static func json(for app: XCUIApplication) -> Data? {
        guard let snap = try? app.snapshot() else { return nil }
        let tree = node(from: snap, screen: XCUIScreen.main.screenshot().image.size.asRect)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(tree)
    }

    /// Flat count, so the walkthrough can assert the tree was not silently
    /// depth-capped by comparing against `app.descendants(matching: .any).count`.
    static func count(_ node: A11yNode) -> Int {
        1 + node.children.reduce(0) { $0 + count($1) }
    }

    private static func name(for type: XCUIElement.ElementType) -> String {
        switch type {
        case .application:    return "application"
        case .window:         return "window"
        case .button:         return "button"
        case .staticText:     return "staticText"
        case .image:          return "image"
        case .textField:      return "textField"
        case .secureTextField:return "secureTextField"
        case .textView:       return "textView"
        case .switch:         return "switch"
        case .toggle:         return "toggle"
        case .slider:         return "slider"
        case .stepper:        return "stepper"
        case .datePicker:     return "datePicker"
        case .picker:         return "picker"
        case .pickerWheel:    return "pickerWheel"
        case .scrollView:     return "scrollView"
        case .table:          return "table"
        case .cell:           return "cell"
        case .collectionView: return "collectionView"
        case .navigationBar:  return "navigationBar"
        case .tabBar:         return "tabBar"
        case .toolbar:        return "toolbar"
        case .sheet:          return "sheet"
        case .alert:          return "alert"
        case .link:           return "link"
        case .other:          return "other"
        case .any:            return "any"
        default:              return "type\(type.rawValue)"
        }
    }
}

private extension CGSize {
    var asRect: CGRect { CGRect(origin: .zero, size: self) }
}
