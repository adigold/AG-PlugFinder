import Foundation

/// Search by sound (BL-98): words people use for how something sounds ("warm", "wide",
/// "punchy") lead to the plugins that do that, through their names, categories, kinds and
/// descriptions.
@MainActor
enum SoundSearch {
    /// A sound word, and the words that mean it in a plugin's name or description.
    private static let vocabulary: [String: [String]] = [
        "warm": ["warm", "analog", "analogue", "tube", "valve", "tape", "saturat", "console", "vintage", "transformer"],
        "tape": ["tape", "reel", "cassette", "flutter", "saturat", "echo"],
        "analog": ["analog", "analogue", "console", "vintage", "tube", "tape", "transformer", "saturat"],
        "vintage": ["vintage", "classic", "analog", "tube", "tape", "console", "emulat"],
        "tube": ["tube", "valve", "saturat", "warm"],
        "wide": ["wide", "width", "widen", "stereo", "imager", "spread", "mid/side", "doubler", "haas"],
        "width": ["width", "wide", "stereo", "imager", "spread"],
        "stereo": ["stereo", "imager", "width", "wide", "spread", "panner"],
        "shimmer": ["shimmer", "octave", "pitch", "reverb", "ambient"],
        "big": ["hall", "reverb", "large", "space", "huge", "big"],
        "space": ["reverb", "space", "room", "hall", "plate", "ambience", "ambient", "spatial"],
        "ambient": ["ambient", "ambience", "reverb", "shimmer", "pad", "texture", "granular"],
        "room": ["room", "reverb", "ambience", "space"],
        "punchy": ["punch", "transient", "compress", "attack", "clip", "enveloper", "drum"],
        "punch": ["punch", "transient", "compress", "attack", "clip", "enveloper"],
        "drums": ["drum", "kick", "snare", "percussion", "transient", "beat", "gate"],
        "drum": ["drum", "kick", "snare", "percussion", "transient", "beat", "gate"],
        "kick": ["kick", "drum", "sub", "transient", "low"],
        "snare": ["snare", "drum", "transient", "gate"],
        "air": ["air", "bright", "exciter", "presence", "high shelf", "shelf", "eq", "harmonic"],
        "bright": ["bright", "air", "exciter", "presence", "treble", "eq"],
        "dark": ["dark", "lofi", "lo-fi", "filter", "low pass", "lowpass", "vinyl", "degrad"],
        "lofi": ["lofi", "lo-fi", "bitcrush", "crush", "vinyl", "degrad", "cassette", "decimat"],
        "echo": ["delay", "echo", "tape", "repeat"],
        "delay": ["delay", "echo", "repeat", "ping"],
        "dirty": ["distort", "saturat", "drive", "fuzz", "crush", "clip", "grit"],
        "grit": ["grit", "distort", "saturat", "drive", "fuzz", "crush"],
        "crunch": ["crunch", "distort", "drive", "overdrive", "saturat", "crush"],
        "distorted": ["distort", "drive", "fuzz", "saturat", "overdrive"],
        "fat": ["fat", "saturat", "compress", "bass", "sub", "harmonic", "thick"],
        "thick": ["thick", "doubler", "chorus", "saturat", "fat", "ensemble"],
        "glue": ["glue", "bus", "compress", "vca", "ssl", "console"],
        "smooth": ["smooth", "opto", "compress", "de-ess", "deess", "soft", "tame"],
        "clean": ["clean", "linear", "transparent", "eq", "precise", "surgical"],
        "surgical": ["surgical", "linear", "dynamic eq", "precise", "notch", "eq"],
        "vocal": ["vocal", "voice", "de-ess", "deess", "pitch", "tune", "doubler", "sibilance"],
        "vocals": ["vocal", "voice", "de-ess", "deess", "pitch", "tune", "doubler"],
        "loud": ["limit", "maxim", "loud", "clip", "master"],
        "loudness": ["loudness", "limit", "maxim", "meter", "lufs"],
        "master": ["master", "limit", "maxim", "loudness", "multiband", "eq"],
        "movement": ["chorus", "flang", "phaser", "tremolo", "rotary", "vibrato", "ensemble", "lfo", "modulat"],
        "modulation": ["chorus", "flang", "phaser", "tremolo", "rotary", "vibrato", "ensemble", "modulat"],
        "pitch": ["pitch", "tune", "octave", "harmon", "shift"],
        "bass": ["bass", "sub", "low end", "low", "808"],
        "sub": ["sub", "bass", "low end", "808", "octave"],
        "tight": ["gate", "transient", "compress", "tight"],
        "soft": ["soft", "opto", "smooth", "gentle"],
        "aggressive": ["aggress", "distort", "drive", "clip", "fuzz", "crush"],
        "retro": ["retro", "vintage", "lofi", "vinyl", "tape", "8-bit", "bitcrush"],
        "radio": ["radio", "telephone", "band pass", "bandpass", "lofi", "filter"],
        "spacey": ["space", "reverb", "delay", "shimmer", "ambient"],
        "lush": ["lush", "chorus", "ensemble", "reverb", "shimmer", "hall"],
        "dreamy": ["dream", "shimmer", "reverb", "chorus", "ambient"],
        "huge": ["huge", "hall", "large", "big", "reverb"],
        "plate": ["plate", "reverb"],
        "hall": ["hall", "reverb"],
    ]

    private static let ignored: Set<String> = ["a", "an", "the", "and", "for", "on", "with", "of", "to", "like", "sound", "sounding", "plugin"]

    /// The search words that carry meaning.
    static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .map(String.init).filter { !ignored.contains($0) }
    }

    private static func terms(for word: String) -> [String] {
        if let v = vocabulary[word] { return [word] + v }
        if word.hasSuffix("s"), let v = vocabulary[String(word.dropLast())] { return [word] + v }
        if word.hasSuffix("y"), let v = vocabulary[String(word.dropLast())] { return [word] + v }
        return [word]
    }

    /// How well a plugin fits: 0 when it doesn't. Only queries with at least one sound word
    /// count, so a plain name search stays a name search.
    static func score(_ p: Plugin, words: [String]) -> Int {
        guard words.contains(where: { vocabulary[$0] != nil || vocabulary[String($0.dropLast())] != nil }) else { return 0 }
        let h = PluginStore.shared.hay(p)
        let hay = h.name + " " + h.description
        var matched = 0, direct = 0
        for w in words {
            if hay.contains(w) { matched += 1; direct += 1; continue }
            if terms(for: w).contains(where: { hay.contains($0) }) { matched += 1 }
        }
        // Every word, or all but one of a longer search, must fit.
        guard matched >= max(1, words.count - (words.count >= 3 ? 1 : 0)) else { return 0 }
        return matched * 10 + direct * 3
    }
}
