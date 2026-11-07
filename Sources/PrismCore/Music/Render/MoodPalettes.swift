import Foundation

// Palette tables for the 16 moods (docs/research/music_reactive.md §3.3). Hex stops are sRGB;
// they are baked into OKLab lookup tables once, on first use.

extension MusicMood {
    /// The mood's palettes, in display order (index 0 is the default). `.auto` shows Prism Bloom's.
    public var palettes: [MoodPalette] {
        MoodPaletteTable.shared.palettes(for: self)
    }
}

/// Synthwave palette layout: 3 sun stops, 2 grid stops, 1 night base.
enum SynthwaveStops {
    static let sun = 0..<3
    static let grid = 3..<5
    static let night = 5
}

/// Starfield palette layout: sky base then 3 star colours.
enum StarfieldStops {
    static let sky = 0
    static let stars = 1..<4
}

final class MoodPaletteTable: @unchecked Sendable {
    static let shared = MoodPaletteTable()
    private let table: [MusicMood: [MoodPalette]]

    func palettes(for mood: MusicMood) -> [MoodPalette] {
        let m = mood == .auto ? .prismBloom : mood
        return table[m] ?? [MoodPalette("White", [0xFFFFFF])]
    }

    private init() {
        var t: [MusicMood: [MoodPalette]] = [:]
        t[.aurora] = [
            MoodPalette("Borealis", [0x062A3A, 0x00B386, 0x3DFF9A, 0x5CE1E6, 0x8A5CFF, 0xE05CFF]),
            MoodPalette("Australis", [0x0A1A4F, 0x2E6BFF, 0x00E0C7, 0xA6FF4D, 0xFF5FA2]),
            MoodPalette("Polar Night", [0x0B1340, 0x3A2CFF, 0x7A3CFF, 0x00D1FF, 0xB8FFF2]),
            MoodPalette("Emerald Veil", [0x003B2F, 0x00A86B, 0x50FFB1, 0xC6FFE8]),
        ]
        t[.neonPulse] = [
            MoodPalette("Tokyo", [0xFF2A6D, 0x05D9E8, 0x7700FF, 0xD1F7FF]),
            MoodPalette("Miami", [0xFF3CAC, 0x00F5D4, 0x784BA0, 0x2B86C5]),
            MoodPalette("Acid", [0xFF00E6, 0x39FF14, 0x00F0FF, 0xFFF200]),
            MoodPalette("Electric Rose", [0xFF006E, 0x3A86FF, 0x8338EC, 0xFB5607]),
        ]
        t[.oceanDrift] = [
            MoodPalette("Lagoon", [0x003F5C, 0x0077B6, 0x00B4D8, 0x48CAE4, 0xCAF0F8]),
            MoodPalette("Deep Sea", [0x03045E, 0x023E8A, 0x0096C7, 0x00F5D4]),
            MoodPalette("Tropical", [0x006D77, 0x00B4A6, 0x83C5BE, 0xEDF6F9, 0xFFDDD2]),
            MoodPalette("Bioluminescence", [0x001233, 0x0353A4, 0x00E5FF, 0x7CFFCB]),
        ]
        t[.sunset] = [
            MoodPalette("Golden Hour", [0x2D1B69, 0x8E2DE2, 0xFF4E50, 0xFC913A, 0xF9D423]),
            MoodPalette("Malibu", [0x355C7D, 0x6C5B7B, 0xC06C84, 0xF67280, 0xF8B195]),
            MoodPalette("Desert Bloom", [0x3D1E6D, 0xB33F62, 0xF9564F, 0xF3C677, 0xFFE8C2]),
            MoodPalette("Tequila", [0x4A0E4E, 0xC2185B, 0xFF5722, 0xFF9800, 0xFFC107]),
        ]
        t[.synthwave] = [
            MoodPalette("Outrun", [0xFF2E97, 0xFF6C11, 0xFFD319, 0x2DE2E6, 0x8B2CFF, 0x241734]),
            MoodPalette("Vaporwave", [0xFF71CE, 0xFFB3E6, 0xFFFB96, 0x01CDFE, 0xB967FF, 0x05FFA1]),
            MoodPalette("Nightdrive", [0xFC28A8, 0xFF8B3D, 0xFFF338, 0x03EDF9, 0x8B2CFF, 0x1A0B3D]),
            MoodPalette("Laser Grid", [0xFF2975, 0xFF8A3D, 0xFFD300, 0xF222FF, 0x00E5FF, 0x120458]),
        ]
        t[.lavaLamp] = [
            MoodPalette("Classic", [0x5A0000, 0xFF2D00, 0xFF7B00, 0xFFB800, 0xFFE45C]),
            MoodPalette("Purple Haze", [0x240046, 0x7209B7, 0xF72585, 0xFF8FAB]),
            MoodPalette("Toxic", [0x0B3D2E, 0x08A045, 0x6BBF59, 0xDDF247]),
            MoodPalette("Blue Lava", [0x03045E, 0x0077B6, 0x00B4D8, 0x90E0EF]),
            MoodPalette("Peach Melt", [0x6D2E46, 0xA26769, 0xD5B9B2, 0xECE2D0]),
        ]
        // Pitch-class tables in chromatic order (C … B); hues follow the circle of fifths.
        t[.spectrum] = [
            MoodPalette("Fifths Soft", [0xFF8372, 0x9B80FF, 0xFEE68A, 0xFF85DF, 0x96FFF8, 0xFF8296,
                                        0x5184FF, 0xFFB97E, 0xDC83FF, 0xA0FF8A, 0xFF82BA, 0x86D8FF]),
            MoodPalette("Fifths Vivid", [0xFB110E, 0x730EFA, 0xFED619, 0xFD13CC, 0x1FFEF4, 0xFC1161,
                                         0x0D10FC, 0xFD9012, 0xC612FD, 0x56FE19, 0xFC1297, 0x16C1FD]),
            MoodPalette("Fifths Pastel", [0xFFBEB3, 0xC6BDFF, 0xFFF2C3, 0xFFC0EF, 0xCBFFFB, 0xFFBEC6,
                                          0x9FC0FF, 0xFFDABB, 0xEDBFFF, 0xCFFFC3, 0xFFBEDA, 0xC1EBFF]),
            MoodPalette("Fifths Even", [0xFA6A59, 0x9F88FF, 0xBB9C00, 0xE56BC1, 0x00B6AF, 0xF86680,
                                        0x6E9AFF, 0xE68100, 0xC877EA, 0x59B842, 0xF167A4, 0x00ADE4]),
        ]
        t[.cinematic] = [
            MoodPalette("Teal & Orange", [0x0F4C5C, 0x1B998B, 0xF6AE2D, 0xF26419]),
            MoodPalette("Neo Noir", [0x0B0C2A, 0x1F3B73, 0x2DE2E6, 0xFF3864]),
            MoodPalette("Dune", [0x3B1F0E, 0x8C4A1E, 0xD98E32, 0xF2C879, 0xFFF1D6]),
            MoodPalette("Arrival", [0x1C2833, 0x2E4053, 0x85929E, 0xD5D8DC]),
            MoodPalette("Moonlight", [0x0A1931, 0x185ADB, 0x7FB3FF, 0xE8F0FF]),
        ]
        t[.club] = [
            MoodPalette("Peak Time", [0xFF0055, 0x7000FF, 0x00C2FF, 0xFF7A00, 0xE8F4FF]),
            MoodPalette("Ultraviolet", [0x6A00FF, 0xB100E8, 0xFF00C8, 0x00E1FF]),
            MoodPalette("Ibiza", [0xFF5F6D, 0xFFC371, 0x00D2FF, 0xFF2BD6]),
            MoodPalette("Ice", [0x00F0FF, 0x0080FF, 0x8F00FF, 0xE0FBFF]),
            MoodPalette("Techno", [0x1A1AFF, 0xB000FF, 0xFF2D55, 0xF2F2FF]),
        ]
        t[.chill] = [
            MoodPalette("Lo-fi Café", [0xFFB4A2, 0xE5989B, 0xB5838D, 0x6D6875, 0xFFE8D6]),
            MoodPalette("Lavender Dusk", [0xCDB4DB, 0xFFC8DD, 0xFFAFCC, 0xBDE0FE, 0xA2D2FF]),
            MoodPalette("Matcha Latte", [0xCCD5AE, 0xE9EDC9, 0xFEFAE0, 0xFAEDCD, 0xD4A373]),
            MoodPalette("Vinyl Sunset", [0xF4A261, 0xE76F51, 0x2A9D8F, 0xE9C46A]),
            MoodPalette("Rainy Window", [0x8EA8C3, 0xCBD5E1, 0xA3B18A, 0xF2E9E4]),
        ]
        t[.starfield] = [
            MoodPalette("Night Sky", [0x0B1026, 0xFFFFFF, 0xCFE3FF, 0xFFE9C4]),
            MoodPalette("Nebula Dust", [0x1A0B2E, 0xE0AAFF, 0xFFFFFF, 0x9D4EDD]),
            MoodPalette("Arctic", [0x001B2E, 0xE0FBFC, 0x98C1D9, 0xFFFFFF]),
            MoodPalette("Golden Dust", [0x1B1200, 0xFFD166, 0xFFF3B0, 0xFFFFFF]),
        ]
        t[.heartbeat] = [
            MoodPalette("Rose", [0x5C1A33, 0xD63A6A, 0xFF5C8A, 0xFFC2D1]),
            MoodPalette("Amethyst", [0x3C1A5B, 0x8E44AD, 0xD980FA, 0xF8C8FF]),
            MoodPalette("Coral", [0x4A1C1C, 0xE07A5F, 0xF2A07B, 0xFFE5D9]),
            MoodPalette("Ice Heart", [0x0B2545, 0x13315C, 0x8DA9C4, 0xEEF4ED]),
        ]
        t[.gradientSweep] = [
            MoodPalette("Soft Rainbow", [0xFF6B6B, 0xFFD93D, 0x6BCB77, 0x4D96FF, 0x9B5DE5]),
            MoodPalette("Candy", [0xF15BB5, 0xFEE440, 0x00BBF9, 0x00F5D4, 0x9B5DE5]),
            MoodPalette("Citrus", [0xFF9F1C, 0xFFBF69, 0xCBF3F0, 0x2EC4B6]),
            MoodPalette("Berry", [0x7209B7, 0xB5179E, 0xF72585, 0x4CC9F0]),
            MoodPalette("Mono Blue", [0x03045E, 0x0077B6, 0x00B4D8, 0x90E0EF, 0xCAF0F8]),
        ]
        t[.prismBloom] = [
            MoodPalette("Prism", [0xF771A0, 0xFD7562, 0xEF8600, 0xC89F00, 0x98B305, 0x3FC168,
                                  0x00BFA8, 0x00B9CF, 0x0EAFFF, 0x829EFF, 0xB688FE, 0xDE79D7]),
            MoodPalette("Opal", [0xFFBBCF, 0xFFBFB4, 0xFDC495, 0xE8CF8C, 0xC9DA97, 0xA7E2B2,
                                 0x8CE5D3, 0x86E2F2, 0xA3D8FF, 0xBFD0FF, 0xD9C6FF, 0xF3BCED]),
            MoodPalette("Crystal", [0x7DF9FF, 0x5AA9FF, 0x8B7CFF, 0xD47CFF, 0xFF8AD8]),
            MoodPalette("Ember Prism", [0xFF4D8D, 0xFF5E5B, 0xFF8C42, 0xFFC145, 0xFFE66D]),
            MoodPalette("Diamond", [0xFFFFFF, 0xE8F7FF, 0xFFF1E6, 0xF3E8FF, 0xE8FFF3]),
        ]
        t[.ember] = [
            MoodPalette("Candle", [0x7A2E0E, 0xFF8A00, 0xFFB347, 0xFFD8A8]),
            MoodPalette("Fireplace", [0x5A1E02, 0xC2410C, 0xF97316, 0xFDBA74]),
            MoodPalette("Whiskey Bar", [0x3E1F0D, 0x9C4A1A, 0xE8A15A, 0xFFE0B2]),
            MoodPalette("Rose Gold", [0x6B2D3A, 0xB76E79, 0xE8B4B8, 0xFFE5D0]),
        ]
        t[.nebula] = [
            MoodPalette("Orion", [0x1B0A3C, 0x5B21B6, 0xDB2777, 0xF472B6, 0x93C5FD]),
            MoodPalette("Carina", [0x0F172A, 0x1E40AF, 0x0EA5E9, 0xF59E0B, 0xFDE68A]),
            MoodPalette("Crab", [0x1A0B0B, 0x7F1D1D, 0xEA580C, 0x22D3EE]),
            MoodPalette("Helix", [0x022C22, 0x0D9488, 0x5EEAD4, 0xF0ABFC]),
        ]
        table = t
    }
}
