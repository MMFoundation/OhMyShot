import CoreGraphics
import Foundation

/// An editor's line numbers are not part of the code. Vision reads them as lines of their own, and with
/// them in place a listing no longer reads as code, so it also loses its indentation. Beside a narrow gutter
/// (Xcode, Vim's `number`, a compact theme) it also reads a number and the code after it as one line,
/// "12 let x = 1".
///
/// A gutter is a column of numbers, aligned, left of every other line, counting up from top to bottom: three
/// or more, or two that follow each other (a snippet of two lines). A number is a line of digits alone, or the
/// digits a line starts with before a space. Short readings inside the same column ("S5" for 55) and numbers
/// Vision read together ("757677") go with it, and a line that starts inside the column keeps only the code
/// after its number ("12 let x = 1", "13}", a misread "З import" between two of its numbers). A line that starts
/// left of the column is code the numbers belong to, so there is no gutter. It goes only when what remains is a
/// code listing, so a numbered list or `cat -n` output keeps its numbers.
enum LineNumbers {
    /// The lines less the gutter, and where the gutter ends: its numbers' right edge, or where the code starts if
    /// that is further left. A reading of the code again keeps right of it, or it reads the numbers back in.
    ///
    /// - Parameter ink: the ink in a box of the picture, which tells where the code read with a number starts;
    ///   without it, that is worked out from the line's characters.
    static func removed(from lines: [OCRLine], ink: ((CGRect) -> InkProfile?)? = nil) -> (lines: [OCRLine], end: CGFloat?) {
        let numbers = lines.compactMap(number).sorted { $0.box.midY < $1.box.midY }
        guard numbers.count >= 2 else { return (lines, nil) }
        let height = numbers.map(\.box.height).sorted()[numbers.count / 2]
        let rightEdges = numbers.map(\.box.maxX).sorted()
        let leftEdges = numbers.map(\.box.minX).sorted()
        let right = rightEdges[rightEdges.count / 2]
        let left = leftEdges[0]
        let aligned = rightEdges.filter { abs($0 - right) <= height / 2 }.count * 4 >= numbers.count * 3
            || leftEdges.filter { abs($0 - left) <= height / 2 }.count * 4 >= numbers.count * 3
        let values = numbers.map(\.value)
        let rising = zip(values, values.dropFirst()).filter { $0 < $1 }.count
        let counting = numbers.count == 2 ? values[1] == values[0] + 1 : rising * 4 >= (values.count - 1) * 3
        guard aligned, counting else { return (lines, nil) }

        let rows = numbers[0].box.midY...numbers[numbers.count - 1].box.midY
        var remaining: [OCRLine] = []
        for line in lines {
            if line.box.maxX <= right + height / 2 {
                // Misread numbers ("S5"), and numbers read together across rows ("757677"), are in it too.
                let characters = line.text.filter { !$0.isWhitespace }
                if characters.count > 5, !characters.allSatisfy({ $0.isASCII && $0.isNumber }) { remaining.append(line) }
            } else if line.box.minX < right, line.box.minX >= left - height / 2,
                      let code = code(after: line, misread: rows.contains(line.box.midY), ink: ink) {
                remaining.append(code)
            } else {
                remaining.append(line)
            }
        }
        guard let textStart = remaining.map(\.box.minX).min(), right <= textStart + height / 4,
              TextAssembler.isCodeListing(ReadingOrder.sorted(remaining)) else { return (lines, nil) }
        return (remaining, min(right, textStart))
    }

    /// The number a line holds and the box of its digits: the line itself, or the digits it starts with before a
    /// space, their box told from the line's characters.
    private static func number(_ line: OCRLine) -> (value: Int, box: CGRect)? {
        let digits = line.text.prefix { $0.isASCII && $0.isNumber }
        guard (1...5).contains(digits.count), let value = Int(digits) else { return nil }
        let rest = line.text[digits.endIndex...]
        if rest.allSatisfy(\.isWhitespace) { return (value, line.box) }
        guard rest.first?.isWhitespace == true else { return nil }
        let width = line.box.width / CGFloat(line.text.count) * CGFloat(digits.count)
        return (value, CGRect(x: line.box.minX, y: line.box.minY, width: width, height: line.box.height))
    }

    /// A line that starts inside the gutter less what it read there: its digits ("12 let x = 1", "13}"), or, where it
    /// may be a misread number, a short reading before a space ("З import"). The code starts at the first ink past
    /// them, or as far along as the characters before it reach.
    private static func code(after line: OCRLine, misread: Bool, ink: ((CGRect) -> InkProfile?)?) -> OCRLine? {
        let text = line.text
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        let number = digits.isEmpty && misread ? text.prefix { !$0.isWhitespace } : digits
        let code = text[number.endIndex...].drop(while: \.isWhitespace)
        guard (1...5).contains(number.count), !code.isEmpty, !digits.isEmpty || code.startIndex > number.endIndex else { return nil }
        let width = line.box.width / CGFloat(text.count)
        var start = line.box.minX + width * CGFloat(text.distance(from: text.startIndex, to: code.startIndex))
        let past = line.box.minX + width * (CGFloat(number.count) - 0.25)
        if let run = ink?(line.box)?.runs.first(where: { CGFloat($0.lowerBound) >= past }) {
            start = CGFloat(run.lowerBound)
        }
        guard start < line.box.maxX else { return nil }
        var trimmed = line
        trimmed.text = String(code)
        trimmed.box = CGRect(x: start, y: line.box.minY, width: line.box.maxX - start, height: line.box.height)
        return trimmed
    }
}
