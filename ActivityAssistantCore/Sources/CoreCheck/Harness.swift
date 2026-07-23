import Foundation

/// A ~40-line stand-in for XCTest.
///
/// The iOS app is built in Xcode, but this package deliberately verifies with
/// nothing but the Swift toolchain so the flow can be checked on any machine
/// (and in CI) without a 10 GB Xcode install. Same assertions, same failures,
/// non-zero exit code when something breaks.
@MainActor
enum Check {
    private(set) static var passed = 0
    private(set) static var failures: [String] = []
    private static var currentCase = ""

    static func suite(_ name: String) {
        print("\n\u{001B}[1m\(name)\u{001B}[0m")
    }

    /// Runs one named check. Failures are collected, not thrown, so a single
    /// broken expectation doesn't hide the rest of the run.
    static func test(_ name: String, _ body: () async throws -> Void) async {
        currentCase = name
        let before = failures.count
        do {
            try await body()
        } catch {
            failures.append("\(name): threw \(error)")
        }
        if failures.count == before {
            passed += 1
            print("  \u{001B}[32m✓\u{001B}[0m \(name)")
        } else {
            for failure in failures[before...] {
                print("  \u{001B}[31m✗\u{001B}[0m \(failure)")
            }
        }
    }

    static func expect(
        _ condition: Bool,
        _ message: @autoclosure () -> String,
        line: UInt = #line
    ) {
        guard !condition else { return }
        failures.append("\(currentCase) (line \(line)): \(message())")
    }

    static func equal<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ context: @autoclosure () -> String = "",
        line: UInt = #line
    ) {
        guard actual != expected else { return }
        let suffix = context().isEmpty ? "" : " — \(context())"
        failures.append("\(currentCase) (line \(line)): expected \(expected), got \(actual)\(suffix)")
    }

    static func close(
        _ actual: Double,
        _ expected: Double,
        accuracy: Double = 1e-9,
        line: UInt = #line
    ) {
        guard abs(actual - expected) > accuracy else { return }
        failures.append("\(currentCase) (line \(line)): expected \(expected) ± \(accuracy), got \(actual)")
    }

    static func throwsError(
        _ body: () throws -> Void,
        _ verify: (Error) -> Void = { _ in },
        line: UInt = #line
    ) {
        do {
            try body()
            failures.append("\(currentCase) (line \(line)): expected a thrown error, none was thrown")
        } catch {
            verify(error)
        }
    }

    static func fail(_ message: String, line: UInt = #line) {
        failures.append("\(currentCase) (line \(line)): \(message)")
    }

    /// Prints the tally and returns the process exit code.
    static func summarize() -> Int32 {
        print("")
        if failures.isEmpty {
            print("\u{001B}[32m\(passed) checks passed.\u{001B}[0m")
            return 0
        }
        print("\u{001B}[31m\(failures.count) failure(s), \(passed) passed.\u{001B}[0m")
        return 1
    }
}
