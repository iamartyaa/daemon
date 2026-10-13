import XCTest
@testable import DaemonCore

final class SearchQueryParserTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2   // Monday
        return c
    }()
    private lazy var now = day(2026, 10, 14, hour: 15)   // Wednesday

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func parse(_ q: String) -> ParsedQuery {
        QueryParser.parse(q, now: now, calendar: calendar)
    }

    func testSourceTimeAndText() {
        let p = parse("from:safari last week flight")
        XCTAssertEqual(p.text, "flight")
        XCTAssertEqual(p.filters.sources, ["safari"])
        XCTAssertEqual(p.filters.dateRange, day(2026, 10, 5)..<day(2026, 10, 12))
        XCTAssertEqual(p.filters.kinds, [])
    }

    func testBareTypeWord() {
        let p = parse("image pricing table")
        XCTAssertEqual(p.text, "pricing table")
        XCTAssertEqual(p.filters.kinds, [.image, .screenshot])
        XCTAssertNil(p.filters.dateRange)
    }

    func testTypeTextOnlyWithPrefix() {
        XCTAssertEqual(parse("type:text docker").filters.kinds, [.text])
        XCTAssertEqual(parse("type:text docker").text, "docker")
        let bare = parse("text from mom")
        XCTAssertEqual(bare.text, "text from mom")
        XCTAssertEqual(bare.filters.kinds, [])
        XCTAssertEqual(parse("type:file x").filters.kinds, [.file])
        XCTAssertEqual(parse("type:bogus x").text, "type:bogus x")
    }

    func testOtherTypeWords() {
        XCTAssertEqual(parse("voice notes about rent").filters.kinds, [.audio, .voice])
        XCTAssertEqual(parse("voice notes about rent").text, "about rent")
        XCTAssertEqual(parse("videos").filters.kinds, [.video])
        XCTAssertEqual(parse("PDFs lease").filters.kinds, [.pdf])
        XCTAssertEqual(parse("links react").filters.kinds, [.link])
        XCTAssertEqual(parse("screenshots audio").filters.kinds, [.image, .screenshot, .audio, .voice])
    }

    func testInMonth() {
        XCTAssertEqual(parse("in march").filters.dateRange, day(2026, 3, 1)..<day(2026, 4, 1))
        XCTAssertEqual(parse("in march").text, "")
        // Current month counts; a later month means last year.
        XCTAssertEqual(parse("in october").filters.dateRange, day(2026, 10, 1)..<day(2026, 11, 1))
        XCTAssertEqual(parse("receipt in Nov").filters.dateRange, day(2025, 11, 1)..<day(2025, 12, 1))
        XCTAssertEqual(parse("in sept").filters.dateRange, day(2026, 9, 1)..<day(2026, 10, 1))
        // "in" without a month is plain text.
        XCTAssertEqual(parse("in figma").text, "in figma")
    }

    func testRelativeRanges() {
        XCTAssertEqual(parse("today").filters.dateRange, day(2026, 10, 14)..<day(2026, 10, 15))
        XCTAssertEqual(parse("yesterday").filters.dateRange, day(2026, 10, 13)..<day(2026, 10, 14))
        XCTAssertEqual(parse("this week").filters.dateRange, day(2026, 10, 12)..<day(2026, 10, 19))
        XCTAssertEqual(parse("this month").filters.dateRange, day(2026, 10, 1)..<day(2026, 11, 1))
        XCTAssertEqual(parse("last month").filters.dateRange, day(2026, 9, 1)..<day(2026, 10, 1))
        XCTAssertEqual(parse("this year").filters.dateRange, day(2026, 1, 1)..<day(2027, 1, 1))
        XCTAssertEqual(parse("last year").filters.dateRange, day(2025, 1, 1)..<day(2026, 1, 1))
        XCTAssertEqual(parse("3 days ago").filters.dateRange, day(2026, 10, 11)..<day(2026, 10, 12))
        XCTAssertEqual(parse("2 weeks ago").filters.dateRange, day(2026, 9, 28)..<day(2026, 10, 5))
        XCTAssertEqual(parse("last call").text, "last call")
    }

    func testMixedCaseAndWhitespace() {
        let p = parse("  FROM:Figma   Last Week   Onboarding  Flow ")
        XCTAssertEqual(p.text, "Onboarding Flow")
        XCTAssertEqual(p.filters.sources, ["figma"])
        XCTAssertEqual(p.filters.dateRange, day(2026, 10, 5)..<day(2026, 10, 12))
        XCTAssertEqual(parse("Image Logo").filters.kinds, [.image, .screenshot])
    }

    func testUnknownAndMultipleSources() {
        let p = parse("from:SomeApp from:com.apple.Notes recipe")
        XCTAssertEqual(p.filters.sources, ["someapp", "com.apple.notes"])
        XCTAssertEqual(p.text, "recipe")
        XCTAssertEqual(parse("from: recipe").text, "from: recipe")
    }
}
