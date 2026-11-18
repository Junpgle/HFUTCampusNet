import Foundation

@main
struct AcademicOneFormRankTests {
    static func assertTrue(_ cond: Bool, _ msg: String) {
        if !cond {
            fputs("ASSERTION FAILED: \(msg)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        testParseOneFormRankJSON()
        testApplyOneFormRanksAndFallback()
        testSnapshotBackwardsCompatibleDecoding()
        print("All AcademicOneFormRankTests passed!")
    }

    static func testParseOneFormRankJSON() {
        let json = """
        {
          "code": 1,
          "msg": "success",
          "data": {
            "jdpmList": [
              {"SORT": 1, "XN": "2025-2026", "ZJD": "109.8", "ZYPM": "50"},
              {"SORT": 2, "XN": "2024-2025", "ZJD": "106.6", "ZYPM": "18"}
            ],
            "kccjList": [
              {"SORT": 1, "KCMC": "形势与政策（1）", "XN": "2024-2025", "XQ": "2024-2025学年第一学期", "KCCJ": "89", "XF": "0.25", "ZYPM": "109"},
              {"SORT": 41, "KCMC": "计算机组成原理 ", "XN": "2025-2026", "XQ": "2025-2026学年第二学期", "KCCJ": "90", "XF": "4.00", "ZYPM": "58"},
              {"SORT": 46, "KCMC": "编译原理 ", "XN": "2025-2026", "XQ": "2025-2026学年第二学期", "KCCJ": "93", "XF": "3.00", "ZYPM": "11"}
            ]
          }
        }
        """
        let data = Data(json.utf8)
        let payload = AcademicService.shared.parseOneFormRankJSON(data)
        assertTrue(payload != nil, "payload should not be nil")
        assertTrue(payload?.yearRanks.count == 2, "expected 2 yearRanks")
        assertTrue(payload?.yearRanks[0].academicYear == "2025-2026", "latest year first")
        assertTrue(payload?.yearRanks[0].majorRank == 50, "2025-2026 rank should be 50")
        assertTrue(payload?.yearRanks[0].totalGpaPoints == "109.8", "ZJD should be 109.8")
        assertTrue(payload?.yearRanks[1].majorRank == 18, "2024-2025 rank should be 18")

        assertTrue(payload?.courseRanks.count == 3, "expected 3 courseRanks")
        assertTrue(payload?.courseRanks[1].courseName == "计算机组成原理", "courseName should be trimmed")
        assertTrue(payload?.courseRanks[1].majorRank == 58, "计算机组成原理 rank should be 58")
    }

    static func testApplyOneFormRanksAndFallback() {
        let g1 = GradeItem(
            termName: "2024-2025学年第一学期",
            courseName: "形势与政策(1)",
            courseCode: "C001",
            lessonCode: "L001",
            credits: 0.25,
            gpa: 3.7,
            scoreText: "89",
            detailText: "",
            passed: true
        )
        let g2 = GradeItem(
            termName: "2025-2026学年第二学期",
            courseName: "计算机组成原理",
            courseCode: "C002",
            lessonCode: "L002",
            credits: 4.0,
            gpa: 4.0,
            scoreText: "90",
            detailText: "",
            passed: true
        )
        let groups = [
            TermGradeGroup(termName: "2025-2026学年第二学期", semesterId: 2, grades: [g2]),
            TermGradeGroup(termName: "2024-2025学年第一学期", semesterId: 1, grades: [g1])
        ]
        let payload = AcademicService.OneFormRankPayload(
            courseRanks: [
                .init(termName: "2024-2025学年第一学期", courseName: "形势与政策（1）", academicYear: "2024-2025", majorRank: 109),
                .init(termName: "2025-2026学年第二学期", courseName: "计算机组成原理 ", academicYear: "2025-2026", majorRank: 58)
            ],
            yearRanks: [
                AcademicYearGpaRank(academicYear: "2025-2026", totalGpaPoints: "109.8", majorRank: 50)
            ]
        )

        let merged = AcademicService.shared.applyOneFormRanks(payload, to: groups)
        assertTrue(merged[0].grades[0].majorRank == 58, "计算机组成原理 should get rank 58")
        assertTrue(merged[1].grades[0].majorRank == 109, "形势与政策(1) should match 形势与政策（1） and get rank 109")

        // When payload is nil on subsequent sync, preserve previous majorRank
        let preserved = AcademicService.shared.applyOneFormRanks(nil, to: groups, previousGroups: merged)
        assertTrue(preserved[0].grades[0].majorRank == 58, "previous rank 58 should be preserved")
        assertTrue(preserved[1].grades[0].majorRank == 109, "previous rank 109 should be preserved")
    }

    static func testSnapshotBackwardsCompatibleDecoding() {
        let oldJSON = """
        {
          "exams": [],
          "termGroups": [
            {
              "termName": "2024-2025学年第一学期",
              "grades": [
                {
                  "id": "2024-2025学年第一学期|L001",
                  "termName": "2024-2025学年第一学期",
                  "courseName": "线性代数",
                  "courseCode": "M001",
                  "lessonCode": "L001",
                  "credits": 2.5,
                  "gpa": 4.0,
                  "scoreText": "94",
                  "numericScore": 94,
                  "detailText": "",
                  "passed": true
                }
              ]
            }
          ],
          "textbooks": [],
          "surveys": [],
          "lastSyncTime": 0
        }
        """
        let decoded = try? JSONDecoder().decode(AcademicDataSnapshot.self, from: Data(oldJSON.utf8))
        assertTrue(decoded != nil, "old AcademicDataSnapshot should decode cleanly")
        assertTrue(decoded?.yearGpaRanks.isEmpty == true, "missing yearGpaRanks should default to empty")
        assertTrue(decoded?.allGrades.first?.majorRank == nil, "missing majorRank should default to nil")
    }
}
