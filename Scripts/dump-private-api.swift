// dump-private-api.swift — reproduces the provenance of Sources/CHiDPIPrivate.
//
// Dumps Apple's private CGVirtualDisplay* class interfaces directly from the
// CoreGraphics framework via the Objective-C runtime, so the header in this
// repo can be regenerated from Apple's own binary (not from any third party).
//
// Usage:  swift Scripts/dump-private-api.swift
import Foundation
import CoreGraphics
import ObjectiveC.runtime

let classNames = ["CGVirtualDisplayDescriptor","CGVirtualDisplay","CGVirtualDisplayMode","CGVirtualDisplaySettings"]
for name in classNames {
    guard let cls = NSClassFromString(name) else { print("=== \(name): NOT FOUND ==="); continue }
    print("=== \(name) : \(class_getSuperclass(cls).map{ NSStringFromClass($0) } ?? "?") ===")
    var pc: UInt32 = 0
    if let props = class_copyPropertyList(cls, &pc) {
        for i in 0..<Int(pc) {
            let n = String(cString: property_getName(props[i]))
            let a = property_getAttributes(props[i]).map{ String(cString: $0) } ?? ""
            print("@property \(n)  [\(a)]")
        }
        free(props)
    }
    var mc: UInt32 = 0
    if let ms = class_copyMethodList(cls, &mc) {
        for i in 0..<Int(mc) {
            let sel = NSStringFromSelector(method_getName(ms[i]))
            let enc = method_getTypeEncoding(ms[i]).map{ String(cString: $0) } ?? ""
            print("- \(sel)  {\(enc)}")
        }
        free(ms)
    }
}
