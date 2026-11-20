import CoreGraphics
import Testing
@testable import OMSOCR

/// Brackets of a code listing that Vision lost or misread, put back from the listing's layout.
struct LoneBracketTests {
    /// 10 px a character, 4 spaces an indent, 30 px a row.
    private func line(_ text: String, indent: Int = 0, row: Int) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: 40 + CGFloat(indent) * 40, y: CGFloat(row) * 30, width: CGFloat(text.count) * 10, height: 20), confidence: 1)
    }

    private func glyph(indent: Int = 0, row: Int) -> CGRect {
        CGRect(x: 40 + CGFloat(indent) * 40, y: CGFloat(row) * 30 + 2, width: 8, height: 18)
    }

    private func texts(_ lines: [OCRLine], glyphs: [CGRect] = []) -> [String] {
        VisionPipeline.withBrackets(lines, glyphs: glyphs, characterWidth: 10).sorted { $0.box.minY < $1.box.minY }.map(\.text)
    }

    @Test func anUnreadGlyphClosesTheBracketOpenedInItsColumn() {
        let lines = [line("func run() {", row: 0), line("let values = [", indent: 1, row: 1), line("1, 2,", indent: 2, row: 2), line("print(values)", indent: 1, row: 4)]
        #expect(texts(lines, glyphs: [glyph(indent: 1, row: 3), glyph(row: 5)]) == ["func run() {", "let values = [", "1, 2,", "]", "print(values)", "}"])
        // No bracket is open in the glyph's column: nothing is guessed.
        #expect(texts([line("let total = 0", row: 0), line("print(total)", row: 1)], glyphs: [glyph(row: 2)]) == ["let total = 0", "print(total)"])
    }

    @Test func aCloserReadAsAnotherCharacterIsPutBack() {
        // The Chinese model reads "}" alone on its line as "子" and "]" as "J".
        let lines = [
            line("func thumbnail() -> Int {", row: 0),
            line("guard ready else {", indent: 1, row: 1),
            line("return 0", indent: 2, row: 2),
            line("子", indent: 1, row: 3),
            line("let sizes = [", indent: 1, row: 4),
            line("16, 32,", indent: 2, row: 5),
            line("J", indent: 1, row: 6),
            line("return sizes.count", indent: 1, row: 7),
        ]
        #expect(texts(lines, glyphs: [glyph(row: 8)]) == [
            "func thumbnail() -> Int {", "guard ready else {", "return 0", "}", "let sizes = [", "16, 32,", "]", "return sizes.count", "}",
        ])
    }

    @Test func anOpeningBraceReadAsADigitOrLetterIsPutBack() {
        // "else {" read as "else 1" and "? {" as "? l": the body is indented under the line and the block closes in
        // its column, by a glyph nothing read or by a brace that was.
        let lines = [
            line("func size(of url: URL) -> Int? l", row: 0),
            line("guard let file = open(url) else 1", indent: 1, row: 1),
            line("return nil", indent: 2, row: 2),
            line("if file.isEmpty { return 0 }", indent: 1, row: 4),
            line("return file.count", indent: 1, row: 5),
            line("}", row: 6),
        ]
        #expect(texts(lines, glyphs: [glyph(indent: 1, row: 3)]) == [
            "func size(of url: URL) -> Int? {", "guard let file = open(url) else {", "return nil", "}", "if file.isEmpty { return 0 }",
            "return file.count", "}",
        ])
        let call = [line("values.forEach(print) l", row: 0), line("total += 1", indent: 1, row: 1), line("} else 1", row: 2), line("total = 0", indent: 1, row: 3), line("}", row: 4)]
        #expect(texts(call) == ["values.forEach(print) {", "total += 1", "} else {", "total = 0", "}"])
    }

    @Test func variablesOfOneCharacterAreLeftAsTheyAre() {
        // A variable alone on its line is indented under the line that opened the block, not in its column.
        let returned = [line("var count: Int {", row: 0), line("let l = items.count", indent: 1, row: 1), line("l", indent: 1, row: 2), line("}", row: 3)]
        #expect(texts(returned) == returned.map(\.text))
        // "else 1" and "= l" that end a statement: no line is indented under them, or nothing closes in their column.
        let ternaries = [
            line("def weight(done, l):", row: 0),
            line("step = 0 if done else 1", indent: 1, row: 1),
            line("scale = max(step, 2) if l else 1", indent: 1, row: 2),
            line("+ offset(l)", indent: 2, row: 3),
            line("return scale * step", indent: 1, row: 4),
        ]
        #expect(texts(ternaries) == ternaries.map(\.text))
        // A line carried on under "+ 1", and the brace of the block around them: it closes a column further left.
        let carried = [line("func scale() -> Int {", row: 0), line("let l = base + 1", indent: 1, row: 1), line("+ offset", indent: 2, row: 2), line("}", row: 3)]
        #expect(texts(carried) == carried.map(\.text))
        let trailing = [line("let l = 1", row: 0), line("let I = l", row: 1), line("print(I, l)", row: 2), line("print(I) l", row: 3)]
        #expect(texts(trailing, glyphs: [glyph(row: 4)]) == trailing.map(\.text))
        // After its block has closed, one character in the same column is a statement.
        let after = [line("let rows = [", row: 0), line("1, 2,", indent: 1, row: 1), line("]", row: 2), line("J", row: 3)]
        #expect(texts(after) == after.map(\.text))
    }

    @Test func aCharacterThatIsNoKnownMisreadingIsLeftAsItIs() {
        // Rust: the brace is in a string, and the variable on the next line is the block's value.
        let value = [line(#"let x = "{";"#, row: 0), line("x", row: 1)]
        #expect(texts(value) == value.map(\.text))
        // An element under the line that opened the list, and the list's own closer after it.
        let element = [line("let values = [", row: 0), line("1", row: 1), line("]", row: 2)]
        #expect(texts(element) == element.map(\.text))
        // Whatever is open above it: "x" in the column of a "[" that nothing closes further down.
        let open = [line("let rows = [", row: 0), line("1, 2,", indent: 1, row: 1), line("x", row: 2)]
        #expect(texts(open) == open.map(\.text))
    }

    @Test func aBracketInAStringOrACommentOpensNothing() {
        // "子" under a line whose only brace is in a string; a glyph nothing read under brackets in comments, and under
        // brackets written as characters.
        let string = [line(#"let brace = "{""#, row: 0), line("子", row: 1)]
        #expect(texts(string) == string.map(\.text))
        let comments = [line("// the block opens with {", row: 0), line("# rows[", row: 1), line("total = 0", row: 2)]
        #expect(texts(comments, glyphs: [glyph(row: 3)]) == comments.map(\.text))
        let characters = [line("if next == '{' || next == '[' { depth += 1 }", row: 0), line("print(depth)", row: 1)]
        #expect(texts(characters, glyphs: [glyph(row: 2)]) == characters.map(\.text))
        #expect(VisionPipeline.codeBrackets(#"let pair = ("{", [1]) // (x"#).map(\.character) == ["(", "[", "]", ")"])
        #expect(VisionPipeline.codeBrackets("} else {").map(\.startsLine) == [true, false])
        // A lifetime's quote has no partner on the line: the brace after it is the code's.
        #expect(VisionPipeline.codeBrackets("impl<'a> Reader {").map(\.character) == ["{"])
    }

    @Test func aBracketTheCodeClosesItselfIsNotClosedTwice() {
        // "J", and a glyph nothing read, under the line that opened a list whose own "]" follows in its column.
        let named = [line("let rows = [", row: 0), line("J", row: 1), line("]", row: 2)]
        #expect(texts(named) == named.map(\.text))
        #expect(texts([named[0], named[2]], glyphs: [glyph(row: 1)]) == ["let rows = [", "]"])
        // The closer of the block around it is not the inner block's: the glyph still closes the one opened in its column.
        let nested = [line("func run() {", row: 0), line("if ready {", indent: 1, row: 1), line("start()", indent: 2, row: 2), line("}", row: 4)]
        #expect(texts(nested, glyphs: [glyph(indent: 1, row: 3)]) == ["func run() {", "if ready {", "start()", "}", "}"])
    }
}
