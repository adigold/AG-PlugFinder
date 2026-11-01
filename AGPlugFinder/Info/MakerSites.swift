import AppKit

/// The maker's own website for a plugin (BL-114): the plugin's page on the maker's site when the
/// maker is known, otherwise a web search for the plugin.
@MainActor
enum MakerSites {
    /// Part of the maker's name → the maker's site. Checked in order, so longer names come first.
    private static let sites: [(String, String)] = [
        ("plugin alliance", "plugin-alliance.com"), ("universal audio", "uaudio.com"), ("ik multimedia", "ikmultimedia.com"),
        ("native instruments", "native-instruments.com"), ("air music", "airmusictech.com"), ("steven slate", "slatedigital.com"),
        ("slate digital", "slatedigital.com"), ("spitfire", "spitfireaudio.com"), ("safari pedals", "safaripedals.com"),
        ("mastering the mix", "masteringthemix.com"), ("tokyo dawn", "tokyodawn.net"), ("audio damage", "audiodamage.com"),
        ("audio ease", "audioease.com"), ("synchro arts", "synchroarts.com"), ("sonic charge", "soniccharge.com"),
        ("newfangled", "newfangledaudio.com"), ("neural dsp", "neuraldsp.com"), ("polyverse", "polyversemusic.com"),
        ("xfer", "xferrecords.com"), ("xln", "xlnaudio.com"), ("pulsar", "pulsarmodular.com"), ("crow hill", "thecrowhillcompany.com"),
        ("valhalla", "valhalladsp.com"), ("devious machines", "deviousmachines.com"), ("sugar bytes", "sugar-bytes.de"),
        ("baby audio", "babyaud.io"), ("kush", "thekushaudio.com"), ("leapwing", "leapwingaudio.com"), ("nuro", "nuroaudio.com"),
        ("excite audio", "exciteaudio.com"), ("felt instruments", "feltinstruments.com"), ("denise", "denise.io"),
        ("sa recordings", "sarecordings.com"), ("d16", "d16.pl"), ("lennardigital", "lennardigital.com"), ("reveal sound", "revealsound.com"),
        ("waves", "waves.com"), ("izotope", "izotope.com"), ("arturia", "arturia.com"), ("softube", "softube.com"),
        ("roland", "roland.com"), ("kilohearts", "kilohearts.com"), ("acustica", "acustica-audio.com"), ("soundtoys", "soundtoys.com"),
        ("ssl", "solidstatelogic.com"), ("klevgrand", "klevgrand.com"), ("goodhertz", "goodhertz.com"), ("fabfilter", "fabfilter.com"),
        ("lexicon", "lexiconpro.com"), ("ujam", "ujam.com"), ("antares", "antarestech.com"), ("sonible", "sonible.com"),
        ("eventide", "eventideaudio.com"), ("landr", "landr.com"), ("u-he", "u-he.com"), ("elektron", "elektron.se"),
        ("wavesfactory", "wavesfactory.com"), ("splice", "splice.com"), ("strymon", "strymon.net"), ("psp", "pspaudioware.com"),
        ("output", "output.com"), ("spectrasonics", "spectrasonics.net"), ("mcdsp", "mcdsp.com"), ("melda", "meldaproduction.com"),
        ("oeksound", "oeksound.com"), ("cableguys", "cableguys.com"), ("toontrack", "toontrack.com"), ("uvi", "uvi.net"),
        ("dmgaudio", "dmgaudio.com"), ("sonnox", "sonnox.com"), ("celemony", "celemony.com"), ("steinberg", "steinberg.net"),
        ("zynaptiq", "zynaptiq.com"), ("sonarworks", "sonarworks.com"), ("overloud", "overloud.com"), ("audiothing", "audiothing.net"),
        ("refx", "refx.com"), ("hofa", "hofa-plugins.de"), ("kazrog", "kazrog.com"), ("techivation", "techivation.com"),
        ("audiomodern", "audiomodern.com"), ("ohm force", "ohmforce.com"), ("harrison", "harrisonaudio.com"),
        ("soundtheory", "soundtheory.com"), ("metric halo", "mhsecure.com"), ("logic pro", "support.apple.com"), ("apple", "support.apple.com"),
    ]

    static func site(for maker: String) -> String? {
        let m = maker.lowercased()
        return sites.first { m.contains($0.0) }?.1
    }

    static func open(_ plugin: Plugin) {
        // The exact page, found and checked once for everyone (BL-119).
        if let url = PlugDB.productURL(plugin.id) { NSWorkspace.shared.open(url); return }
        let name = plugin.isLogic && !plugin.name.hasPrefix("Logic") ? "Logic Pro \(plugin.name)" : plugin.name
        var q: String
        if let site = site(for: plugin.manufacturer) {
            // Straight to the best match on the maker's own site.
            q = "!ducky site:\(site) \(name)"
        } else {
            q = "\(plugin.manufacturer) \(name) plugin"
        }
        q = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "+", with: "%2B") ?? q
        if let url = URL(string: "https://duckduckgo.com/?q=\(q)") { NSWorkspace.shared.open(url) }
    }
}
