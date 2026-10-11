import Foundation

@main
struct ColorTests {
    static func main() {
        let fixtures: [(String, UInt32)] = [("V", 0xA1A7B4), ("D", 0x73D9FF), ("I", 0x75E5A0), ("W", 0xFFD166), ("E", 0xFF758F), ("A", 0xE5A0FF)]
        for (level, expected) in fixtures {
            precondition(LogcatPalette.rgb(column: "level", level: level, tag: "", dark: true) == expected)
            precondition(LogcatPalette.rgb(column: "message", level: level, tag: "", dark: true) == expected, "The whole message must carry severity, not only the level letter")
            let light = LogcatPalette.rgb(column: "message", level: level, tag: "", dark: false)
            precondition(contrast(light, 0xFFFFFF) >= 4.5, "Light-theme text must remain readable: \(level)")
            precondition(contrast(expected, 0x21262D) >= 4.5, "Dark-theme text must remain readable: \(level)")
            precondition(contrast(light, 0xF0F0F0) >= 4.5, "Selected light rows must keep contrast: \(level)")
            precondition(contrast(expected, 0x2F343B) >= 4.5, "Selected dark rows must keep contrast: \(level)")
        }
        for (tag, expected) in [("tcmd", UInt32(0x87D7AF)), ("adbd", 0x5FD7D7), ("AndroidRuntime", 0xD7875F), ("đọc log", 0xD7AF87)] {
            precondition(LogcatPalette.rgb(column: "tag", level: "D", tag: tag, dark: true) == expected, "Keep termlog's UTF-8 FNV color identity")
            precondition(LogcatPalette.rgb(column: "tag", level: "E", tag: tag, dark: true) == expected, "Tag identity must not change with level")
            precondition(contrast(LogcatPalette.rgb(column: "tag", level: "D", tag: tag, dark: false), 0xFFFFFF) >= 4.5)
        }
        precondition(LogcatPalette.rgb(column: "time", level: "E", tag: "x", dark: true) == 0x8E96A5)
        precondition(LogcatPalette.rgb(column: "pid", level: "E", tag: "x", dark: true) == 0x8E96A5)
        precondition(LogcatPalette.rgb(column: "package", level: "E", tag: "x", dark: true) == 0xC0C7D4)
        precondition(LogcatPalette.rgb(column: "message", level: "?", tag: "x", dark: true) == 0xC0C7D4)
        print("PASS: full-message severity colors, stable UTF-8 tag colors, quiet metadata, light/dark text contrast")
    }

    private static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ rgb: UInt32) -> Double {
            func channel(_ shift: UInt32) -> Double {
                let value = Double((rgb >> shift) & 255) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
