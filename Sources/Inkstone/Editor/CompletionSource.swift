import AppKit

/// One completion candidate.
struct Completion {
    /// What the source will contain when the item is accepted, `:` for emoji.
    var insert: String
    /// What is shown, and what the filter runs against.
    var label: String
    var detail: String = ""

    /// Prefix after the accepted text, so `:smile:` lands on a closing colon.
    var suffix: String = ""
}

/// The completion sources the original offers, and the rules for when each applies.
///
/// Pure text in, candidates out: the trigger that opens the popup lives in
/// `CompletionController`, which is a view concern, and the data lives here so a
/// candidate list can be reasoned about without a window.
enum CompletionSource {
    /// `:smi` -> the emoji shortcodes whose name starts with it.
    static func emoji(matching query: String, limit: Int = 12) -> [Completion] {
        guard !query.isEmpty else { return [] }
        let needle = query.lowercased()
        var out: [Completion] = []
        for name in EmojiCatalog.shortcodes where name.hasPrefix(needle) {
            out.append(
                Completion(
                    insert: ":" + name + ":",
                    label: ":" + name + ":",
                    detail: EmojiCatalog.glyph(for: name)
                )
            )
            if out.count >= limit { break }
        }
        // Exact matches first, then the shortest name: `:smile` should beat
        // `:smile_with_something` without the user having to type further.
        return out.sorted {
            $0.label.count == $1.label.count ? $0.label < $1.label : $0.label.count < $1.label.count
        }
    }

    /// A path that exists, for `![](` or `[](`.
    ///
    /// Only siblings of the document and its enclosing folder: a completion list that
    /// walks the whole disk is not a completion list.
    static func paths(
        matching query: String, in directory: URL?, limit: Int = 12
    ) -> [Completion] {
        guard let directory else { return [] }
        let fm = FileManager.default
        guard
            let names = try? fm.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        let needle = query.lowercased()
        var out: [Completion] = []
        for name in names.sorted() {
            guard name.lowercased().hasPrefix(needle) || needle.isEmpty else { continue }
            if name.hasPrefix(".") { continue }
            let values = try? directory.appendingPathComponent(name)
                .resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = values?.isDirectory == true
            out.append(
                Completion(
                    insert: name + (isDirectory ? "/" : ""),
                    label: name,
                    detail: isDirectory ? "folder" : "file"
                )
            )
            if out.count >= limit { break }
        }
        return out
    }
}

/// The `:shortcode:` table.
///
/// A curated subset rather than all of Unicode: a full emoji table is thousands of
/// entries and a megabyte of binary, and the shortcodes people actually type are a
/// few hundred. What is here covers the ones the original's own list leads with.
enum EmojiCatalog {
    /// Shortcode -> the character it renders as.
    static let table: [String: String] = [
        "smile": "\u{1F604}", "smiley": "\u{1F603}", "grinning": "\u{1F600}",
        "grin": "\u{1F601}", "laughing": "\u{1F606}", "sweat_smile": "\u{1F605}",
        "joy": "\u{1F602}", "rofl": "\u{1F923}", "relaxed": "\u{263A}\u{FE0F}",
        "blush": "\u{1F60A}", "innocent": "\u{1F607}", "slightly_smiling_face": "\u{1F642}",
        "upside_down_face": "\u{1F643}", "wink": "\u{1F609}", "relieved": "\u{1F60C}",
        "heart_eyes": "\u{1F60D}", "kissing_heart": "\u{1F618}", "yum": "\u{1F60B}",
        "stuck_out_tongue": "\u{1F61B}", "stuck_out_tongue_winking_eye": "\u{1F61C}",
        "zany_face": "\u{1F92A}", "money_mouth_face": "\u{1F911}",
        "hugs": "\u{1F917}", "thinking": "\u{1F914}", "zipper_mouth_face": "\u{1F910}",
        "neutral_face": "\u{1F610}", "expressionless": "\u{1F611}", "no_mouth": "\u{1F636}",
        "smirk": "\u{1F60F}", "unamused": "\u{1F612}", "roll_eyes": "\u{1F644}",
        "grimacing": "\u{1F62C}", "lying_face": "\u{1F925}", "pensive": "\u{1F614}",
        "sleepy": "\u{1F62A}", "drooling_face": "\u{1F924}", "sleeping": "\u{1F634}",
        "mask": "\u{1F637}", "face_with_thermometer": "\u{1F912}", "nauseated_face": "\u{1F922}",
        "sneezing_face": "\u{1F927}", "hot_face": "\u{1F975}", "cold_face": "\u{1F976}",
        "woozy_face": "\u{1F974}", "dizzy_face": "\u{1F635}", "exploding_head": "\u{1F92F}",
        "cowboy_hat_face": "\u{1F920}", "partying_face": "\u{1F973}", "sunglasses": "\u{1F60E}",
        "nerd_face": "\u{1F913}", "monocle_face": "\u{1F9D0}", "confused": "\u{1F615}",
        "worried": "\u{1F61F}", "slightly_frowning_face": "\u{1F641}", "frowning_face": "\u{26DE}",
        "open_mouth": "\u{1F62E}", "hushed": "\u{1F62F}", "astonished": "\u{1F632}",
        "flushed": "\u{1F633}", "pleading_face": "\u{1F97A}", "frowning": "\u{1F626}",
        "anguished": "\u{1F627}", "fearful": "\u{1F628}", "cold_sweat": "\u{1F630}",
        "cry": "\u{1F622}", "sob": "\u{1F62D}", "scream": "\u{1F631}",
        "confounded": "\u{1F616}", "persevere": "\u{1F623}", "disappointed": "\u{1F61E}",
        "sweat": "\u{1F613}", "weary": "\u{1F629}", "tired_face": "\u{1F62B}",
        "triumph": "\u{1F624}", "rage": "\u{1F621}", "angry": "\u{1F620}",
        "cursing_face": "\u{1F92C}", "smiling_imp": "\u{1F608}", "imp": "\u{1F47F}",
        "skull": "\u{1F480}", "skull_and_crossbones": "\u{2620}\u{FE0F}",
        "ghost": "\u{1F47B}", "alien": "\u{1F47D}", "robot": "\u{1F916}",
        "clown_face": "\u{1F921}", "poop": "\u{1F4A9}", "shit": "\u{1F4A9}",
        "jack_o_lantern": "\u{1F383}", "fire": "\u{1F525}", "sparkles": "\u{2728}",
        "star": "\u{2B50}", "star2": "\u{1F31F}", "dizzy": "\u{1F4AB}",
        "sparkler": "\u{1F387}", "boom": "\u{1F4A5}", "zap": "\u{26A1}",
        "rainbow": "\u{1F308}", "sunny": "\u{2600}\u{FE0F}", "cloud": "\u{2601}\u{FE0F}",
        "snowflake": "\u{2744}\u{FE0F}", "ocean": "\u{1F30A}", "earth_americas": "\u{1F30E}",
        "house": "\u{1F3E0}", "office": "\u{1F3E2}", "hospital": "\u{1F3E5}",
        "coffee": "\u{2615}", "tea": "\u{1F375}", "beer": "\u{1F37A}", "beers": "\u{1F37B}",
        "wine_glass": "\u{1F377}", "cocktail": "\u{1F378}", "cake": "\u{1F370}",
        "birthday": "\u{1F382}", "gift": "\u{1F381}", "balloon": "\u{1F388}",
        "tada": "\u{1F389}", "confetti_ball": "\u{1F38A}", "ribbon": "\u{1F380}",
        "trophy": "\u{1F3C6}", "medal": "\u{1F3C5}", "dart": "\u{1F3AF}",
        "game_die": "\u{1F3B2}", "video_game": "\u{1F3AE}", "musical_note": "\u{1F3B5}",
        "notes": "\u{1F3B6}", "microphone": "\u{1F3A4}", "headphones": "\u{1F3A7}",
        "guitar": "\u{1F3B8}", "camera": "\u{1F4F7}", "video_camera": "\u{1F4F9}",
        "tv": "\u{1F4FA}", "computer": "\u{1F4BB}", "keyboard": "\u{2328}\u{FE0F}",
        "printer": "\u{1F5A8}\u{FE0F}", "telephone": "\u{260E}\u{FE0F}", "mobile_phone": "\u{1F4F1}",
        "battery": "\u{1F50B}", "electric_plug": "\u{1F50C}", "bulb": "\u{1F4A1}",
        "flashlight": "\u{1F526}", "book": "\u{1F4D6}", "books": "\u{1F4DA}",
        "memo": "\u{1F4DD}", "pencil2": "\u{1F4DD}", "page_facing_up": "\u{1F4C4}",
        "clipboard": "\u{1F4CB}", "calendar": "\u{1F4C5}", "date": "\u{1F4C5}",
        "chart_with_upwards_trend": "\u{1F4C8}", "bar_chart": "\u{1F4CA}",
        "moneybag": "\u{1F4B0}", "credit_card": "\u{1F4B3}", "gem": "\u{1F48E}",
        "lock": "\u{1F512}", "unlock": "\u{1F513}", "key": "\u{1F511}",
        "hammer": "\u{1F528}", "wrench": "\u{1F527}", "gear": "\u{2699}\u{FE0F}",
        "link": "\u{1F517}", "paperclip": "\u{1F4CE}", "scissors": "\u{2702}\u{FE0F}",
        "pencil": "\u{270F}\u{FE0F}", "mag": "\u{1F50D}", "mag_right": "\u{1F50E}",
        "package": "\u{1F4E6}", "mailbox": "\u{1F4EB}", "inbox_tray": "\u{1F4E5}",
        "outbox_tray": "\u{1F4E4}", "bell": "\u{1F514}", "no_bell": "\u{1F515}",
        "warning": "\u{26A0}\u{FE0F}", "no_entry": "\u{26D4}", "question": "\u{2753}",
        "exclamation": "\u{2757}", "information_source": "\u{2139}\u{FE0F}",
        "recycle": "\u{267B}\u{FE0F}", "arrow_right": "\u{27A1}\u{FE0F}",
        "arrow_left": "\u{2B05}\u{FE0F}", "arrow_up": "\u{2B06}\u{FE0F}",
        "arrow_down": "\u{2B07}\u{FE0F}", "arrows_counterclockwise": "\u{1F504}",
        "check_mark": "\u{2705}", "x": "\u{274C}", "heavy_check_mark": "\u{2714}\u{FE0F}",
        "white_check_mark": "\u{2705}", "ballot_box_with_check": "\u{2611}\u{FE0F}",
        "hourglass": "\u{231B}", "watch": "\u{231A}", "alarm_clock": "\u{23F0}",
        "bug": "\u{1F41B}", "wastebasket": "\u{1F5D1}\u{FE0F}", "memo_emoji": "\u{1F4DD}",
    ]

    /// Shortcodes in a stable order, so completion does not reshuffle between keystrokes.
    static let shortcodes: [String] = table.keys.sorted()

    static func glyph(for name: String) -> String { table[name] ?? "" }
}
