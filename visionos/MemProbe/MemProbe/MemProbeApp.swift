import SwiftUI

@main
struct MemProbeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MemProbe").font(.largeTitle)
            ForEach(lines, id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
        }
        .padding(40)
        .task { lines = Self.probe() }
    }

    static func probe() -> [String] {
        let r = run_probe()
        func kr(_ v: Int32) -> String { "\(v) (\(String(cString: probe_kr_string(v))))" }
        let out = [
            "FIXED 4GB @0x1000000000: kr=\(kr(r.fixed_kr)) touch=\(r.fixed_touch_ok != 0)",
            "ANYWHERE 4GB: kr=\(kr(r.anywhere_kr)) addr=0x\(String(r.anywhere_addr, radix: 16)) touch=\(r.anywhere_touch_ok != 0)",
            "vm_allocate FIXED 4GB @0x1000000000: kr=\(kr(r.vm_fixed_kr))",
            "mmap 4GB hint 0x1000000000: addr=0x\(String(r.mmap_addr, radix: 16)) errno=\(r.mmap_errno)",
            "largest ANYWHERE: \(r.largest_anywhere_mb) MB",
        ] + {
            let a = [r.cand_addr.0, r.cand_addr.1, r.cand_addr.2, r.cand_addr.3, r.cand_addr.4]
            let k = [r.cand_kr.0, r.cand_kr.1, r.cand_kr.2, r.cand_kr.3, r.cand_kr.4]
            let t = [r.cand_touch_ok.0, r.cand_touch_ok.1, r.cand_touch_ok.2, r.cand_touch_ok.3, r.cand_touch_ok.4]
            return (0..<5).map { "FIXED 4GB @0x\(String(a[$0], radix: 16)): kr=\(kr(k[$0])) touch=\(t[$0] != 0)" }
        }()
        out.forEach { print("MEMPROBE \($0)") }
        return out
    }
}
