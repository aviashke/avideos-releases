import Foundation

/// Turns an email body into an ordered list of `ContentBlock`s: sentences to
/// speak, interleaved with the images encountered along the way.
///
/// This is deliberately dependency-free. For HTML we scan for `<img>` tags to
/// preserve image position, strip the remaining markup, decode common entities,
/// and split the text into sentences using Foundation's sentence tokenizer.
enum EmailParser {

    static func parse(_ email: Email) -> ParsedEmail {
        let blocks: [ContentBlock]
        var links: [EmailLink] = []
        if let html = email.bodyHTML, !html.isEmpty {
            blocks = parseHTML(html)
            links = extractLinks(from: html)
        } else {
            blocks = sentences(from: email.bodyText ?? email.snippet, startIndex: 0)
        }

        // Drop the boilerplate footer newsletters (Substack et al.) tack on:
        // "Share / Comment / Restack / Upgrade to paid / © … / Subscribe for free…".
        let trimmed = trimTrailingBoilerplate(blocks)
        // Don't let trimming wipe everything (e.g. a body that's all footer).
        let kept = trimmed.isEmpty ? blocks : trimmed

        // Guarantee at least one block so the player always has something to read.
        let finalBlocks = kept.isEmpty
            ? sentences(from: email.snippet, startIndex: 0)
            : kept
        let canonicalURL = findCanonicalLink(links: links, subject: email.subject)
        return ParsedEmail(email: email, blocks: finalBlocks, links: links, canonicalURL: canonicalURL)
    }

    /// The link whose visible text matches the subject line — virtually every
    /// newsletter (Substack included) makes its headline a link to the post's
    /// own web page, so this reliably finds "this email's own link" without
    /// guessing at domains or URL shapes. Exact match first, then a loose
    /// contains-either-way match (an aggregator/reader can trim or requote the
    /// subject slightly); nil when nothing lines up closely enough.
    private static func findCanonicalLink(links: [EmailLink], subject: String) -> URL? {
        let normalizedSubject = normalized(subject)
        guard normalizedSubject.count >= 6 else { return nil }
        if let exact = links.first(where: { normalized($0.text) == normalizedSubject }) {
            return exact.url
        }
        return links.first {
            let t = normalized($0.text)
            guard t.count >= 6 else { return false }
            return t.contains(normalizedSubject) || normalizedSubject.contains(t)
        }?.url
    }

    // MARK: - Links

    private static let anchorRegex = try! NSRegularExpression(
        pattern: "<a\\b[^>]*\\bhref\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>",
        options: [.caseInsensitive]
    )

    /// Anchor text (or, for image-only links, the link itself) that marks a link
    /// as chrome rather than content the reader would want to save.
    private static let junkLinkPhrases: [String] = [
        "unsubscribe", "view in browser", "view this email", "view online",
        "manage your subscription", "manage preferences", "update your preferences",
        "email preferences", "notification settings", "privacy policy",
        "terms of service", "terms of use", "read in app", "read in the app",
        "open in app", "get the app", "leave a comment", "share", "restack",
        "like", "comment"
    ]

    /// Pull http(s) links out of the email HTML, in document order, deduped by
    /// URL, skipping the standard newsletter chrome (unsubscribe, "read in app", …)
    /// so the list is just the links worth reading.
    static func extractLinks(from rawHTML: String) -> [EmailLink] {
        let html = stripNonContent(rawHTML)
        let ns = html as NSString
        var seen = Set<String>()
        var out: [EmailLink] = []

        for m in anchorRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let scheme = URL(string: href)?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let url = URL(string: href) else { continue }

            let text = stripTags(ns.substring(with: m.range(at: 2)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isJunkLink(text: text) { continue }

            guard seen.insert(url.absoluteString).inserted else { continue }
            let label = text.isEmpty ? (url.host ?? url.absoluteString) : text
            out.append(EmailLink(text: label, url: url))
        }
        return out
    }

    private static func isJunkLink(text: String) -> Bool {
        let t = normalized(text)
        guard !t.isEmpty else { return false }   // empty text → keep (use host)
        return junkLinkPhrases.contains { t == $0 || t.contains($0) }
    }

    // MARK: - Trailing boilerplate

    /// Strip the newsletter footer. Two passes, both confined to the *tail* of the
    /// email so real body text is never cut:
    ///  1. If a strong footer anchor (a "Like"/"Comment"/"Upgrade to paid"/"Read in
    ///     app"/copyright… line) appears in the tail, cut from there to the end —
    ///     this clears the whole footer block even when non-matching lines sit
    ///     between the anchors.
    ///  2. Otherwise, trim a contiguous run of footer lines off the very end.
    private static func trimTrailingBoilerplate(_ blocks: [ContentBlock]) -> [ContentBlock] {
        guard !blocks.isEmpty else { return blocks }

        // Search only the tail (latter half, capped to the last ~30 blocks).
        let searchStart = max(blocks.count / 2, blocks.count - 30)
        for i in searchStart..<blocks.count {
            if case .sentence(let s) = blocks[i], isFooterAnchor(s.text) {
                return Array(blocks[0..<i])
            }
        }

        // No anchor — just peel footer lines off the end.
        var end = blocks.count
        while end > 0, case .sentence(let s) = blocks[end - 1], isFooterLine(s.text) {
            end -= 1
        }
        return Array(blocks[0..<end])
    }

    private static func normalized(_ text: String) -> String {
        let punct = CharacterSet(charactersIn: ".,!?:;·•|-–—()[]\"'“”")
        return text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: punct)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Short UI labels that appear as their own line in newsletter footers.
    private static let footerExactLines: Set<String> = [
        "share", "comment", "comments", "like", "likes", "restack", "restacks",
        "subscribe", "subscribe now", "unsubscribe", "follow", "view in browser",
        "open in app", "read in app", "read online", "get the app", "start writing",
        "leave a comment", "share this post", "upgrade to paid", "pledge",
        "give a gift subscription", "listen now", "watch now", "view comments",
        "refer a friend", "no posts", "ready for more"
    ]

    /// Phrases that, appearing in a trailing line, mark it as footer regardless of
    /// length (Substack's standard sign-off / legal / promo / app-promo lines).
    private static let footerMarkers: [String] = [
        "is the home for great culture", "subscribe for free to receive",
        "to receive new posts and support", "collection notice", "privacy ∙ terms",
        "privacy · terms", "© 20", "(c) 20", "you're a free subscriber",
        "you’re a free subscriber", "you're currently a free subscriber",
        "you’re currently a free subscriber", "this post is for paid subscribers",
        "upgrade to paid", "in the substack app", "available for ios and android",
        "available on ios and android"
    ]

    /// A line at the end is footer if it's a known UI label or contains a marker.
    private static func isFooterLine(_ text: String) -> Bool {
        let t = normalized(text)
        if t.isEmpty { return true }
        if footerExactLines.contains(t) { return true }
        return footerMarkers.contains { t.contains($0) }
    }

    /// A *strong* signal that the footer block has begun (used to cut from here to
    /// the end). Stricter than `isFooterLine` to stay safe deep in the body.
    private static func isFooterAnchor(_ text: String) -> Bool {
        let t = normalized(text)
        if footerExactLines.contains(t) { return true }
        // "Read <publication> in the app" buttons.
        if t.hasPrefix("read ") && (t.hasSuffix("in the app") || t.contains("in the substack app")) {
            return true
        }
        let anchorMarkers = [
            "upgrade to paid", "is the home for great culture",
            "subscribe for free to receive", "in the substack app",
            "available for ios and android", "© 20", "(c) 20",
            "you're a free subscriber", "you’re a free subscriber",
            "this post is for paid subscribers"
        ]
        return anchorMarkers.contains { t.contains($0) }
    }

    // MARK: - HTML

    private static let imgRegex = try! NSRegularExpression(
        pattern: "<img\\b[^>]*>", options: [.caseInsensitive]
    )

    /// `<style>`/`<script>`/`<head>` blocks and comments carry no spoken content,
    /// but real-world (esp. marketing) email HTML packs tens of KB of CSS/JS into
    /// them. Left in, that text floods the sentence tokenizer — garbage on screen
    /// and a long main-thread stall. Strip them before anything else.
    private static let nonContentRegex = try! NSRegularExpression(
        pattern: "<(script|style|head)\\b[^>]*>[\\s\\S]*?</\\1>|<!--[\\s\\S]*?-->",
        options: [.caseInsensitive]
    )

    private static func stripNonContent(_ html: String) -> String {
        let ns = html as NSString
        return nonContentRegex.stringByReplacingMatches(
            in: html,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: " "
        )
    }

    private static func parseHTML(_ rawHTML: String) -> [ContentBlock] {
        // Preserve the HTML's visible block boundaries *before* tags are stripped,
        // and carry list markers through as well. Without this, adjacent paragraphs
        // such as "...effort dial" and "Forwarded this email?" collapse into one
        // sentence whenever the first block has no terminal punctuation.
        let html = annotateStructure(stripNonContent(rawHTML))
        var blocks: [ContentBlock] = []
        var index = 0
        let ns = html as NSString
        var cursor = 0

        let matches = imgRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            // Text before this image.
            let textRange = NSRange(location: cursor, length: match.range.location - cursor)
            let textChunk = ns.substring(with: textRange)
            let chunkBlocks = renderText(textChunk, startIndex: index)
            blocks.append(contentsOf: chunkBlocks)
            index += chunkBlocks.count

            // The image itself.
            let imgTag = ns.substring(with: match.range)
            cursor = match.range.location + match.range.length

            // Drop spacers, tracking pixels, and the rows of tiny social/footer
            // icons that newsletters (Substack, CNBC, …) pile up — they'd just be
            // announced as "there's an image here" over and over.
            if isDecorative(imgTag) { continue }

            let url = resolveBestSource(from: imgTag)
            let cid = contentID(from: attribute("src", in: imgTag))
            // Nothing we can actually show (empty/unsupported source) — skip it
            // rather than announce a blank image.
            if url == nil, cid == nil { continue }

            let image = InlineImage(
                blockIndex: index,
                remoteURL: url,
                contentID: cid,
                altText: attribute("alt", in: imgTag)
            )
            blocks.append(.image(image))
            index += 1
        }

        // Trailing text after the last image.
        if cursor < ns.length {
            let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            let tailBlocks = renderText(tail, startIndex: index)
            blocks.append(contentsOf: tailBlocks)
        }

        return blocks
    }

    /// Best loadable image URL for an `<img>`. Marketing/newsletter HTML often
    /// lazy-loads: the real URL sits in `data-src`/`srcset` while plain `src` is a
    /// 1×1 placeholder or `data:` URI. Prefer the real ones, take the largest
    /// `srcset` candidate, normalize protocol-relative `//host/x.png`, and only
    /// accept http(s) (so `cid:`/`data:` fall through to the content-id path).
    private static func resolveBestSource(from tag: String) -> URL? {
        func httpURL(_ raw: String?) -> URL? {
            guard let raw else { return nil }
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("//") { s = "https:" + s }
            guard let url = URL(string: s),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return nil
            }
            return url
        }
        // "urlA 320w, urlB 640w" / "urlA 1x, urlB 2x" → last (largest) candidate.
        func fromSrcset(_ raw: String?) -> URL? {
            guard let last = raw?.split(separator: ",").last else { return nil }
            return httpURL(last.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init))
        }
        return httpURL(attribute("data-src", in: tag))
            ?? fromSrcset(attribute("data-srcset", in: tag))
            ?? fromSrcset(attribute("srcset", in: tag))
            ?? httpURL(attribute("src", in: tag))
    }

    /// True for images that carry no spoken/visual value: hidden elements, 1×1
    /// spacers/tracking pixels, and the small icons (≤ ~64px) common in footers.
    private static func isDecorative(_ tag: String) -> Bool {
        if let style = attribute("style", in: tag)?.lowercased(),
           style.contains("display:none") || style.contains("display: none")
            || style.contains("visibility:hidden") || style.contains("visibility: hidden") {
            return true
        }
        // Social / share / subscribe buttons (Substack et al.) — UI controls, not
        // content — usually carry a tell-tale alt even without small dimensions.
        if let alt = attribute("alt", in: tag)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           uiControlAlts.contains(alt) {
            return true
        }
        let w = pixelDimension("width", in: tag)
        let h = pixelDimension("height", in: tag)
        if let w, w <= 2 { return true }
        if let h, h <= 2 { return true }
        if let maxDim = [w, h].compactMap({ $0 }).max(), maxDim < 64 { return true }
        return false
    }

    private static let uiControlAlts: Set<String> = [
        "share", "comment", "comments", "like", "likes", "restack", "subscribe",
        "subscribe now", "unsubscribe", "follow", "view in browser", "open in app",
        "twitter", "x", "facebook", "instagram", "linkedin", "youtube", "threads",
        "tiktok", "pinterest", "whatsapp", "telegram", "app store", "google play"
    ]

    /// A pixel dimension from a `width`/`height` attribute (quoted or not) or an
    /// inline `style`. Percentages (e.g. width="100%") return nil — unknown, keep.
    private static func pixelDimension(_ name: String, in tag: String) -> Int? {
        func firstInt(_ pattern: String, in string: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let ns = string as NSString
            guard let m = regex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)),
                  m.range(at: 1).location != NSNotFound else { return nil }
            return Int(ns.substring(with: m.range(at: 1)))
        }
        // width=48 / width="48" / width="48px" — but not when it's a percentage.
        if let attr = attribute(name, in: tag), attr.contains("%") { /* percentage: skip */ }
        else if let value = firstInt("(?<![\\w-])\(name)\\s*=\\s*[\"']?(\\d+)", in: tag) { return value }
        // style="width:48px"
        if let style = attribute("style", in: tag) {
            return firstInt("(?<![\\w-])\(name)\\s*:\\s*(\\d+)\\s*px", in: style)
        }
        return nil
    }

    private static func contentID(from src: String?) -> String? {
        guard let src, src.lowercased().hasPrefix("cid:") else { return nil }
        return String(src.dropFirst(4))
    }

    private static let attrRegexCache = NSCache<NSString, NSRegularExpression>()

    private static func attribute(_ name: String, in tag: String) -> String? {
        let key = name as NSString
        let regex: NSRegularExpression
        if let cached = attrRegexCache.object(forKey: key) {
            regex = cached
        } else {
            // Matches name="..." or name='...'. The leading look-behind keeps
            // `src` from matching `data-src`/`srcset` and `width` from `max-width`.
            let pattern = "(?<![\\w-])\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
            regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            attrRegexCache.setObject(regex, forKey: key)
        }
        let ns = tag as NSString
        guard let m = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        for i in 1...2 where m.range(at: i).location != NSNotFound {
            return decodeEntities(ns.substring(with: m.range(at: i)))
        }
        return nil
    }

    private static let tagRegex = try! NSRegularExpression(pattern: "<[^>]+>", options: [])

    /// Strip remaining tags. Block-level tags become spaces so sentences don't
    /// run together; everything else is removed.
    private static func stripTags(_ html: String) -> String {
        let ns = html as NSString
        let spaced = tagRegex.stringByReplacingMatches(
            in: html,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: " "
        )
        return decodeEntities(spaced)
    }

    // MARK: - Entities

    private static let entityMap: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—",
        "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘",
        "&ldquo;": "“", "&rdquo;": "”"
    ]

    private static func decodeEntities(_ s: String) -> String {
        var result = s
        for (entity, value) in entityMap {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        // Numeric entities like &#8217;
        if let numeric = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let ns = result as NSString
            let matches = numeric.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches {
                let code = ns.substring(with: m.range(at: 1))
                if let scalarValue = UInt32(code), let scalar = Unicode.Scalar(scalarValue) {
                    result = (result as NSString).replacingCharacters(in: m.range, with: String(scalar))
                }
            }
        }
        return result
    }

    // MARK: - Lists & line structure

    /// Invisible delimiters that carry a list item's depth and bullet marker from
    /// `annotateStructure`, through tag-stripping, into `renderText` — without ever
    /// appearing as visible text.
    private static let listSentinel = "\u{2063}"   // invisible separator
    private static let listFieldSep = "\u{241F}"   // unit separator
    /// Marks a line break we deliberately introduced (a new list item / end of a
    /// list). A private-use scalar so it can't collide with body text, and it's a
    /// non-whitespace character so it survives whitespace-collapsing — letting us
    /// fold the email's own incidental newlines into spaces while keeping ours.
    private static let lineBreak = "\u{F8FF}"

    /// HTML elements that create visible text boundaries in a rendered email.
    /// Preserve them as reader-unit boundaries so a visually separate label never
    /// gets joined to the preceding paragraph merely because that paragraph lacks
    /// punctuation. Both opening and closing tags are included deliberately: email
    /// HTML is often malformed or omits optional closing tags.
    private static let textBoundaryTags: Set<String> = [
        "br", "hr",
        "p", "/p", "div", "/div", "section", "/section",
        "article", "/article", "header", "/header", "footer", "/footer",
        "blockquote", "/blockquote", "pre", "/pre",
        "h1", "/h1", "h2", "/h2", "h3", "/h3",
        "h4", "/h4", "h5", "/h5", "h6", "/h6",
        "table", "/table", "tr", "/tr", "td", "/td", "th", "/th"
    ]

    /// Rewrite structural tags into sentinel-delimited reader lines. Every `<li>`
    /// also carries its nesting depth and bullet/number through tag stripping.
    /// `<img>` and inline tags pass through untouched so the image scanner and
    /// later tag-stripper still work.
    private static func annotateStructure(_ html: String) -> String {
        let ns = html as NSString
        let tags = tagRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var output = ""
        var cursor = 0
        var lists: [(ordered: Bool, count: Int)] = []   // stack of open lists

        for tag in tags {
            if tag.range.location > cursor {
                output += ns.substring(with: NSRange(location: cursor, length: tag.range.location - cursor))
            }
            cursor = tag.range.location + tag.range.length
            let raw = ns.substring(with: tag.range)
            switch tagName(raw) {
            case "ul": lists.append((false, 0))
            case "ol": lists.append((true, 0))
            case "/ul", "/ol":
                if !lists.isEmpty { lists.removeLast() }
                output += lineBreak
            case "li":
                let depth = max(lists.count, 1)
                let marker: String
                if var top = lists.last, top.ordered {
                    top.count += 1
                    lists[lists.count - 1] = top
                    marker = "\(top.count)."
                } else {
                    marker = unorderedGlyph(depth: depth)
                }
                output += lineBreak + listSentinel + "\(depth)" + listFieldSep + marker + listSentinel
            default:
                if textBoundaryTags.contains(tagName(raw)) {
                    output += lineBreak
                } else {
                    output += raw   // keep <img>, <a>, and other inline tags
                }
            }
        }
        if cursor < ns.length {
            output += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return output
    }

    /// Lowercased element name from a raw tag: "<li ...>" → "li", "</ul>" → "/ul".
    private static func tagName(_ rawTag: String) -> String {
        let s = rawTag.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\n"))
        var out = ""
        for ch in s {
            if ch == "/" && out.isEmpty { out.append(ch); continue }
            if ch.isLetter || ch.isNumber { out.append(ch); continue }
            break
        }
        return out
    }

    private static func unorderedGlyph(depth: Int) -> String {
        switch depth {
        case 1: return "•"
        case 2: return "◦"
        default: return "▪"
        }
    }

    /// Strip tags from a chunk while keeping the structural boundaries and list
    /// sentinels that `annotateStructure` inserted, then split into blocks: each
    /// visual HTML block becomes an independent reader unit, while prose inside
    /// that block still splits into normal sentences.
    private static func renderText(_ htmlChunk: String, startIndex: Int) -> [ContentBlock] {
        let ns = htmlChunk as NSString
        let noTags = tagRegex.stringByReplacingMatches(
            in: htmlChunk, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        let decoded = decodeEntities(noTags)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            // Collapse all real whitespace (incl. the email's own newlines) to
            // single spaces; only our `lineBreak` sentinel splits lines.
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        var result: [ContentBlock] = []
        var index = startIndex
        for rawLine in decoded.components(separatedBy: lineBreak) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            var depth = 0
            var marker = ""
            if line.hasPrefix(listSentinel),
               let close = line.range(of: listSentinel,
                                      range: line.index(after: line.startIndex)..<line.endIndex) {
                let fields = line[line.index(after: line.startIndex)..<close.lowerBound]
                    .components(separatedBy: listFieldSep)
                if fields.count == 2 { depth = Int(fields[0]) ?? 0; marker = fields[1] }
                line = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            for (k, part) in splitSentences(line).enumerated() {
                result.append(.sentence(Sentence(
                    blockIndex: index, text: part,
                    listDepth: depth,
                    bulletMarker: k == 0 ? marker : "")))
                index += 1
            }
        }
        return result
    }

    // MARK: - Sentences

    /// Split free text into `Sentence` blocks, numbering them from `startIndex`.
    static func sentences(from text: String, startIndex: Int) -> [ContentBlock] {
        let cleaned = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        var result: [ContentBlock] = []
        var index = startIndex
        for part in splitSentences(cleaned) {
            result.append(.sentence(Sentence(blockIndex: index, text: part)))
            index += 1
        }
        return result
    }

    /// Tokenize already-cleaned text into sentence strings, falling back to the
    /// whole string when there's no terminal punctuation to split on. Drops
    /// "sentences" with no real words (e.g. "0 0 ." / "0 . . . ." from leaked CSS
    /// or numeric noise on JS-heavy pages) so the player never reads them aloud.
    private static func splitSentences(_ text: String) -> [String] {
        var parts: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { substring, _, _, _ in
            let trimmed = substring?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if hasReadableText(trimmed) { parts.append(trimmed) }
        }
        if parts.isEmpty, hasReadableText(text) { parts.append(text) }
        return parts
    }

    /// True when the string has at least two letters — i.e. actual words, not just
    /// digits, punctuation, or symbols. Counts letters in any script (so Hebrew,
    /// Arabic, CJK, … all qualify).
    private static func hasReadableText(_ s: String) -> Bool {
        var letters = 0
        for ch in s where ch.isLetter {
            letters += 1
            if letters >= 2 { return true }
        }
        return false
    }
}
