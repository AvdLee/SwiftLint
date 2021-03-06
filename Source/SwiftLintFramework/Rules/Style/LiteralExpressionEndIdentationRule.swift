import Foundation
import SourceKittenFramework

public struct LiteralExpressionEndIdentationRule: Rule, ConfigurationProviderRule, OptInRule, AutomaticTestableRule {
    public var configuration = SeverityConfiguration(.warning)

    public init() {}

    public static let description = RuleDescription(
        identifier: "literal_expression_end_indentation",
        name: "Literal Expression End Indentation",
        description: "Array and dictionary literal end should have the same indentation as the line that started it.",
        kind: .style,
        nonTriggeringExamples: [
            "[1, 2, 3]",
            "[1,\n" +
            " 2\n" +
            "]",
            "[\n" +
            "   1,\n" +
            "   2\n" +
            "]",
            "[\n" +
            "   1,\n" +
            "   2]\n",
            "   let x = [\n" +
            "       1,\n" +
            "       2\n" +
            "   ]",
            "[key: 2, key2: 3]",
            "[key: 1,\n" +
            " key2: 2\n" +
            "]",
            "[\n" +
            "   key: 0,\n" +
            "   key2: 20\n" +
            "]"
        ],
        triggeringExamples: [
            "let x = [\n" +
            "   1,\n" +
            "   2\n" +
            "   ↓]",
            "   let x = [\n" +
            "       1,\n" +
            "       2\n" +
            "↓]",
            "let x = [\n" +
            "   key: value\n" +
            "   ↓]"
        ],
        corrections: [
            "let x = [\n" +
            "   key: value\n" +
            "↓   ]":
            "let x = [\n" +
            "   key: value\n" +
            "]",
            "   let x = [\n" +
            "       1,\n" +
            "       2\n" +
            "↓]":
            "   let x = [\n" +
            "       1,\n" +
            "       2\n" +
            "   ]",
            "let x = [\n" +
            "   1,\n" +
            "   2\n" +
            "↓   ]":
            "let x = [\n" +
            "   1,\n" +
            "   2\n" +
            "]",
            "let x = [\n" +
            "   1,\n" +
            "   2\n" +
            "↓   ] + [\n" +
            "   3,\n" +
            "   4\n" +
            "↓   ]":
            "let x = [\n" +
            "   1,\n" +
            "   2\n" +
            "] + [\n" +
            "   3,\n" +
            "   4\n" +
            "]"
        ]
    )

    public func validate(file: File) -> [StyleViolation] {
        return violations(in: file).map { violation in
            return styleViolation(for: violation, in: file)
        }
    }

    private func styleViolation(for violation: Violation, in file: File) -> StyleViolation {
        let reason = "\(LiteralExpressionEndIdentationRule.description.description) " +
                     "Expected \(violation.indentationRanges.expected.length), " +
                     "got \(violation.indentationRanges.actual.length)."

        return StyleViolation(ruleDescription: type(of: self).description,
                              severity: configuration.severity,
                              location: Location(file: file, byteOffset: violation.endOffset),
                              reason: reason)
    }

    fileprivate static let notWhitespace = regex("[^\\s]")

}

extension LiteralExpressionEndIdentationRule: CorrectableRule {
    public func correct(file: File) -> [Correction] {
        let allViolations = violations(in: file).reversed().filter {
            !file.ruleEnabled(violatingRanges: [$0.range], for: self).isEmpty
        }

        guard !allViolations.isEmpty else {
            return []
        }

        var correctedContents = file.contents
        var correctedLocations: [Int] = []

        let actualLookup = actualViolationLookup(for: allViolations)

        for violation in allViolations {
            let expected = actualLookup(violation).indentationRanges.expected
            let actual = violation.indentationRanges.actual
            if correct(contents: &correctedContents, expected: expected, actual: actual) {
                correctedLocations.append(actual.location)
            }
        }

        var corrections = correctedLocations.map {
            return Correction(ruleDescription: type(of: self).description,
                              location: Location(file: file, characterOffset: $0))
        }

        file.write(correctedContents)

        // Re-correct to catch cascading indentation from the first round.
        corrections += correct(file: file)

        return corrections
    }

    private func correct(contents: inout String, expected: NSRange, actual: NSRange) -> Bool {
        guard let actualIndices = contents.nsrangeToIndexRange(actual) else {
            return false
        }

        let correction = contents.substring(from: expected.location, length: expected.length)
        contents = contents.replacingCharacters(in: actualIndices, with: correction)

        return true
    }

    private func actualViolationLookup(for violations: [Violation]) -> (Violation) -> Violation {
        let lookup = violations.reduce(into: [NSRange: Violation](), { result, violation in
            result[violation.indentationRanges.actual] = violation
        })

        func actualViolation(for violation: Violation) -> Violation {
            guard let actual = lookup[violation.indentationRanges.expected] else { return violation }
            return actualViolation(for: actual)
        }

        return actualViolation
    }
}

extension LiteralExpressionEndIdentationRule {
    fileprivate struct Violation {
        var indentationRanges: (expected: NSRange, actual: NSRange)
        var endOffset: Int
        var range: NSRange
    }

    fileprivate func violations(in file: File) -> [Violation] {
        return violations(in: file, dictionary: file.structure.dictionary)
    }

    private func violations(in file: File,
                            dictionary: [String: SourceKitRepresentable]) -> [Violation] {
        return dictionary.substructure.flatMap { subDict -> [Violation] in
            var subViolations = violations(in: file, dictionary: subDict)

            if let kindString = subDict.kind,
                let kind = SwiftExpressionKind(rawValue: kindString),
                let violation = violation(in: file, of: kind, dictionary: subDict) {
                subViolations.append(violation)
            }

            return subViolations
        }
    }

    private func violation(in file: File, of kind: SwiftExpressionKind,
                           dictionary: [String: SourceKitRepresentable]) -> Violation? {
        guard kind == .dictionary || kind == .array else {
            return nil
        }

        let elements = dictionary.elements.filter { $0.kind == "source.lang.swift.structure.elem.expr" }

        let contents = file.contents.bridge()
        guard !elements.isEmpty,
            let offset = dictionary.offset,
            let length = dictionary.length,
            let (startLine, _) = contents.lineAndCharacter(forByteOffset: offset),
            let firstParamOffset = elements[0].offset,
            let (firstParamLine, _) = contents.lineAndCharacter(forByteOffset: firstParamOffset),
            startLine != firstParamLine,
            let lastParamOffset = elements.last?.offset,
            let (lastParamLine, _) = contents.lineAndCharacter(forByteOffset: lastParamOffset),
            case let endOffset = offset + length - 1,
            let (endLine, endPosition) = contents.lineAndCharacter(forByteOffset: endOffset),
            lastParamLine != endLine else {
                return nil
        }

        let range = file.lines[startLine - 1].range
        let regex = LiteralExpressionEndIdentationRule.notWhitespace
        let actual = endPosition - 1
        guard let match = regex.firstMatch(in: file.contents, options: [], range: range)?.range,
            case let expected = match.location - range.location,
            expected != actual  else {
                return nil
        }

        var expectedRange = range
        expectedRange.length = expected

        var actualRange = file.lines[endLine - 1].range
        actualRange.length = actual

        return Violation(indentationRanges: (expected: expectedRange, actual: actualRange),
                         endOffset: endOffset,
                         range: NSRange(location: offset, length: length))
    }
}
