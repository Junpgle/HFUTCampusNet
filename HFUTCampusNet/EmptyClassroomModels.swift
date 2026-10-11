import Foundation

/// 校区枚举（与 HFUT-Schedule 的 UniAppCampusDto 一致）
public enum StudyCampus: Int, CaseIterable, Codable {
    case xuancheng = 6   // 宣城校区
    case feicuihu = 3    // 合肥翡翠湖校区
    case tunxilu = 2     // 合肥屯溪路校区

    public var displayName: String {
        switch self {
        case .xuancheng: return "宣城校区"
        case .feicuihu: return "翡翠湖校区"
        case .tunxilu: return "屯溪路校区"
        }
    }

    /// 各校区学生最常去自习的主力教学楼名称关键词（默认优先加载）
    public var preferredStudyBuildingNames: [String] {
        switch self {
        case .xuancheng:
            return ["敬亭学堂", "新安学堂"]
        case .feicuihu:
            return ["翠一教", "翠二教", "翠三教", "翠四教", "翠五教", "翠六教", "翠七教", "翠八教", "翠九教", "翠十教", "翠十一教", "翠十二教", "翡翠科教楼"]
        case .tunxilu:
            return ["东楼", "西楼", "主楼", "西二", "逸夫楼"]
        }
    }

    /// 计算教学楼或教室前缀在当前校区的自然排序权重（使「翠一教、翠二教…翠十二教」按数字顺序排列，而非按汉字 Unicode 编码乱序）
    public func buildingSortRank(for text: String) -> Int {
        let pairs = preferredStudyBuildingNames.enumerated().sorted { $0.element.count > $1.element.count }
        for (idx, keyword) in pairs {
            if text.contains(keyword) {
                return idx
            }
        }
        return 999
    }

    public func compareBuildingNames(_ a: String, _ b: String) -> Bool {
        let rankA = buildingSortRank(for: a)
        let rankB = buildingSortRank(for: b)
        if rankA != rankB {
            return rankA < rankB
        }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    public static func from(dormCampusString: String) -> StudyCampus {
        if dormCampusString.contains("翡翠湖") {
            return .feicuihu
        } else if dormCampusString.contains("屯溪路") {
            return .tunxilu
        } else {
            return .xuancheng
        }
    }
}

/// 教学楼模型（对应 eams-micro-server/api/v1/room/place/building）
public struct ClassroomBuilding: Codable, Identifiable, Equatable, Hashable {
    public var id: Int
    public var nameZh: String
    public var campusAssoc: Int

    public init(id: Int, nameZh: String, campusAssoc: Int) {
        self.id = id
        self.nameZh = nameZh
        self.campusAssoc = campusAssoc
    }

    /// 去除后缀的简洁楼栋名（与 HFUT-Schedule 一致）
    public var cleanName: String {
        nameZh
            .replacingOccurrences(of: "（宣城）", with: "")
            .replacingOccurrences(of: "(宣)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否属于自习主力教学楼（排除操场、各类纯实验室、印刷厂平房等）
    public var isPreferredStudyBuilding: Bool {
        guard let campus = StudyCampus(rawValue: campusAssoc) else { return false }
        let name = cleanName
        return campus.preferredStudyBuildingNames.contains { name.contains($0) }
    }
}

/// 教室占用原因枚举（对应 HFUT-Schedule 的 ClassroomOccupiedCause）
public enum ClassroomOccupiedCause: String, Codable {
    case lesson = "Lesson"
    case exam = "Exam"
    case borrowed = "RoomBorrow"

    public var label: String {
        switch self {
        case .lesson: return "上课"
        case .exam: return "考试"
        case .borrowed: return "借用"
        }
    }
}

/// 单条教室占用记录（对应 UniAppEmptyClassroomLesson）
public struct ClassroomOccupation: Codable, Equatable, Identifiable {
    public var id: String {
        "\(activityId ?? 0)-\(date)-\(startTimeString)-\(endTimeString)"
    }

    public var activityId: Int?
    public var roomName: String?
    public var date: String
    public var startTime: Int?
    public var endTime: Int?
    public var startTimeString: String
    public var endTimeString: String
    public var activityType: String
    public var activityName: String
    public var teacherName: String?

    public let startMinutes: Int
    public let endMinutes: Int
    public let shortCourseName: String

    private enum CodingKeys: String, CodingKey {
        case activityId, roomName, date, startTime, endTime, startTimeString, endTimeString, activityType, activityName, teacherName
    }

    public init(
        activityId: Int? = nil,
        roomName: String? = nil,
        date: String,
        startTime: Int? = nil,
        endTime: Int? = nil,
        startTimeString: String,
        endTimeString: String,
        activityType: String,
        activityName: String,
        teacherName: String? = nil
    ) {
        self.activityId = activityId
        self.roomName = roomName
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.startTimeString = startTimeString
        self.endTimeString = endTimeString
        self.activityType = activityType
        self.activityName = activityName
        self.teacherName = teacherName

        self.startMinutes = Self.parseMinutes(from: startTimeString, fallbackInt: startTime)
        self.endMinutes = Self.parseMinutes(from: endTimeString, fallbackInt: endTime)
        let fallbackCause = ClassroomOccupiedCause(rawValue: activityType)?.label ?? "占用"
        self.shortCourseName = Self.cleanCourseName(activityName, fallback: fallbackCause)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let activityId = try c.decodeIfPresent(Int.self, forKey: .activityId)
        let roomName = try c.decodeIfPresent(String.self, forKey: .roomName)
        let date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        let startTime = try c.decodeIfPresent(Int.self, forKey: .startTime)
        let endTime = try c.decodeIfPresent(Int.self, forKey: .endTime)
        let startTimeString = try c.decodeIfPresent(String.self, forKey: .startTimeString) ?? ""
        let endTimeString = try c.decodeIfPresent(String.self, forKey: .endTimeString) ?? ""
        let activityType = try c.decodeIfPresent(String.self, forKey: .activityType) ?? "Lesson"
        let activityName = try c.decodeIfPresent(String.self, forKey: .activityName) ?? ""
        let teacherName = try c.decodeIfPresent(String.self, forKey: .teacherName)

        self.init(
            activityId: activityId,
            roomName: roomName,
            date: date,
            startTime: startTime,
            endTime: endTime,
            startTimeString: startTimeString,
            endTimeString: endTimeString,
            activityType: activityType,
            activityName: activityName,
            teacherName: teacherName
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(activityId, forKey: .activityId)
        try c.encodeIfPresent(roomName, forKey: .roomName)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(startTime, forKey: .startTime)
        try c.encodeIfPresent(endTime, forKey: .endTime)
        try c.encode(startTimeString, forKey: .startTimeString)
        try c.encode(endTimeString, forKey: .endTimeString)
        try c.encode(activityType, forKey: .activityType)
        try c.encode(activityName, forKey: .activityName)
        try c.encodeIfPresent(teacherName, forKey: .teacherName)
    }

    public static func parseMinutes(from str: String, fallbackInt: Int? = nil) -> Int {
        let parts = str.split(separator: ":")
        if parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) {
            return h * 60 + m
        }
        if let raw = fallbackInt {
            return (raw / 100) * 60 + (raw % 100)
        }
        return 0
    }

    /// 占用类型中文描述
    public var causeTitle: String {
        ClassroomOccupiedCause(rawValue: activityType)?.label ?? "占用"
    }

    private static func cleanCourseName(_ raw: String, fallback: String) -> String {
        var text = raw
        let prefixes = ["课程：", "课程:", "考试：", "考试:", "活动名称：", "活动名称:", "借用：", "借用:", "教室借用：", "教室借用:"]
        for p in prefixes {
            text = text.replacingOccurrences(of: p, with: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parenRange = text.range(of: "(") ?? text.range(of: "（") ?? text.range(of: "，") ?? text.range(of: ";") ?? text.range(of: "；") {
            let prefix = String(text[..<parenRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty {
                text = prefix
            }
        }
        return text.isEmpty ? fallback : text
    }

    /// 在给定时间分钟数是否正在占用
    public func isOngoing(atMinutes nowMin: Int) -> Bool {
        return nowMin >= startMinutes && nowMin <= endMinutes
    }
}

/// 单个空教室状态模型（对应 UniAppEmptyClassroom）
public struct EmptyClassroomItem: Codable, Identifiable, Equatable {
    public var id: Int
    public var nameZh: String
    public var nameEn: String?
    public var code: String?
    public var buildingId: Int?
    public var campusNameZh: String
    public var floor: Int?
    public var seatsForLesson: Int?
    public var roomOccupationInfoVms: [ClassroomOccupation]?

    // 预计算的缓存字段（避免在筛选、排序、渲染时重复执行正则与数组排序）
    public let inferredRoomNumber: Int
    public let inferredFloor: Int
    public let buildingPrefix: String
    public let shortRoomCode: String
    public let sortedOccupations: [ClassroomOccupation]

    private enum CodingKeys: String, CodingKey {
        case id, nameZh, nameEn, code, buildingId, campusNameZh, floor, seatsForLesson, roomOccupationInfoVms
    }

    public init(
        id: Int,
        nameZh: String,
        nameEn: String? = nil,
        code: String? = nil,
        buildingId: Int? = nil,
        campusNameZh: String,
        floor: Int? = nil,
        seatsForLesson: Int? = nil,
        roomOccupationInfoVms: [ClassroomOccupation]? = nil
    ) {
        self.id = id
        self.nameZh = nameZh
        self.nameEn = nameEn
        self.code = code
        self.buildingId = buildingId
        self.campusNameZh = campusNameZh
        self.floor = floor
        self.seatsForLesson = seatsForLesson
        self.roomOccupationInfoVms = roomOccupationInfoVms

        let meta = Self.extractMetadata(nameZh: nameZh, fallbackId: id, rawFloor: floor)
        self.inferredRoomNumber = meta.roomNum
        self.inferredFloor = meta.floor
        self.buildingPrefix = meta.prefix
        self.shortRoomCode = meta.shortCode
        self.sortedOccupations = Self.sortOccupations(roomOccupationInfoVms)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(Int.self, forKey: .id)
        let nameZh = try c.decode(String.self, forKey: .nameZh)
        let nameEn = try c.decodeIfPresent(String.self, forKey: .nameEn)
        let code = try c.decodeIfPresent(String.self, forKey: .code)
        let buildingId = try c.decodeIfPresent(Int.self, forKey: .buildingId)
        let campusNameZh = try c.decodeIfPresent(String.self, forKey: .campusNameZh) ?? ""
        let floor = try c.decodeIfPresent(Int.self, forKey: .floor)
        let seatsForLesson = try c.decodeIfPresent(Int.self, forKey: .seatsForLesson)
        let vms = try c.decodeIfPresent([ClassroomOccupation].self, forKey: .roomOccupationInfoVms)

        self.init(
            id: id,
            nameZh: nameZh,
            nameEn: nameEn,
            code: code,
            buildingId: buildingId,
            campusNameZh: campusNameZh,
            floor: floor,
            seatsForLesson: seatsForLesson,
            roomOccupationInfoVms: vms
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(nameZh, forKey: .nameZh)
        try c.encodeIfPresent(nameEn, forKey: .nameEn)
        try c.encodeIfPresent(code, forKey: .code)
        try c.encodeIfPresent(buildingId, forKey: .buildingId)
        try c.encode(campusNameZh, forKey: .campusNameZh)
        try c.encodeIfPresent(floor, forKey: .floor)
        try c.encodeIfPresent(seatsForLesson, forKey: .seatsForLesson)
        try c.encodeIfPresent(roomOccupationInfoVms, forKey: .roomOccupationInfoVms)
    }

    private static func sortOccupations(_ vms: [ClassroomOccupation]?) -> [ClassroomOccupation] {
        guard let vms = vms, !vms.isEmpty else { return [] }
        return vms.sorted {
            if $0.startMinutes != $1.startMinutes {
                return $0.startMinutes < $1.startMinutes
            }
            return $0.endMinutes < $1.endMinutes
        }
    }

    /// 零正则开销的高速字符扫描：提取末尾房间号、楼层与楼栋前缀
    private static func extractMetadata(nameZh: String, fallbackId: Int, rawFloor: Int?) -> (roomNum: Int, floor: Int, prefix: String, shortCode: String) {
        let chars = Array(nameZh)
        var endIdx = chars.count
        // 若末尾有单个字母后缀（如 101A），跳过该字母
        if endIdx > 0, chars[endIdx - 1].isASCII && chars[endIdx - 1].isLetter {
            endIdx -= 1
        }
        var digitStart = endIdx
        while digitStart > 0 && chars[digitStart - 1].isASCII && chars[digitStart - 1].isNumber {
            digitStart -= 1
        }
        let digitCount = endIdx - digitStart
        var roomNum = fallbackId
        var prefix = nameZh
        var shortCode = nameZh

        if digitCount >= 3 && digitCount <= 4 {
            let numStr = String(chars[digitStart..<endIdx])
            if let parsed = Int(numStr) {
                roomNum = parsed
            }
            let rawPrefix = String(chars[0..<digitStart]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawPrefix.isEmpty {
                prefix = rawPrefix
                shortCode = String(chars[digitStart..<chars.count])
            }
        }

        let inferredFloor: Int
        if roomNum >= 100 && roomNum <= 1999 {
            inferredFloor = roomNum / 100
        } else if let f = rawFloor, f > 0 {
            inferredFloor = f
        } else {
            inferredFloor = 1
        }

        return (roomNum, inferredFloor, prefix, shortCode)
    }

    /// 房间尾号（如 101 -> 1, 215 -> 15），用于判断同楼层或上下楼的水平距离
    public var roomIndexOnFloor: Int {
        inferredRoomNumber % 100
    }

    /// 是否全天完全无课/无占用 (08:00 - 22:00)
    public var isAllDayFree: Bool {
        sortedOccupations.isEmpty
    }

    /// 在指定分钟数是否正在被占用
    public func currentOccupation(atMinutes nowMin: Int) -> ClassroomOccupation? {
        sortedOccupations.first { $0.isOngoing(atMinutes: nowMin) }
    }

    /// 在指定分钟数之后的下一场占用
    public func nextOccupation(afterMinutes nowMin: Int) -> ClassroomOccupation? {
        sortedOccupations.first { $0.startMinutes > nowMin }
    }

    /// 距离下一场占用的剩余分钟数（若当前已占用返回 0，若后续全空返回 nil）
    public func minutesUntilNextOccupation(atMinutes nowMin: Int) -> Int? {
        if currentOccupation(atMinutes: nowMin) != nil {
            return 0
        }
        guard let next = nextOccupation(afterMinutes: nowMin) else {
            return nil
        }
        return max(0, next.startMinutes - nowMin)
    }

    /// 从当前时刻起到晚上 22:00 是否一直空闲（当前无课且后续无课）
    public func isRestOfDayFree(atMinutes nowMin: Int) -> Bool {
        return currentOccupation(atMinutes: nowMin) == nil && nextOccupation(afterMinutes: nowMin) == nil
    }

    /// 在给定时间区间 [startMin, endMin] 内是否完全空闲
    public func isFree(from startMin: Int, to endMin: Int) -> Bool {
        for occ in sortedOccupations {
            if max(startMin, occ.startMinutes) < min(endMin, occ.endMinutes) {
                return false
            }
        }
        return true
    }

    /// 从给定时间点开始，可连续自习的分钟数（直到下一节课开始或 22:00 闭楼）
    public func continuousFreeMinutes(from startMin: Int) -> Int {
        let closeMin = 22 * 60
        let effectiveStart = max(8 * 60, startMin)
        guard effectiveStart < closeMin else { return 0 }
        if currentOccupation(atMinutes: effectiveStart) != nil {
            return 0
        }
        if let next = nextOccupation(afterMinutes: effectiveStart) {
            return max(0, next.startMinutes - effectiveStart)
        }
        return max(0, closeMin - effectiveStart)
    }

    /// 状态简短标签（用于列表与菜单展示）
    public func statusSummary(isToday: Bool, nowMin: Int) -> (text: String, level: RoomFreeLevel) {
        if isAllDayFree {
            return ("全天空闲 (08:00-22:00)", .allDayFree)
        }
        guard isToday else {
            return ("当日有 \(sortedOccupations.count) 节占用", .partiallyFree)
        }
        if let ongoing = currentOccupation(atMinutes: nowMin) {
            return ("占用中 · \(ongoing.shortCourseName) (至\(ongoing.endTimeString))", .occupied)
        }
        if let next = nextOccupation(afterMinutes: nowMin) {
            let minsLeft = max(0, next.startMinutes - nowMin)
            if minsLeft <= 30 {
                return ("即将上课 · \(next.startTimeString) \(next.shortCourseName) (\(minsLeft)分钟后)", .soonOccupied)
            }
            return ("当前空闲 · 空至 \(next.startTimeString) (\(next.shortCourseName))", .partiallyFree)
        }
        return ("余下全空 (当前至 22:00 无课)", .restOfDayFree)
    }

    /// 计算从源教室（当前自习教室）切换到本教室的物理距离与推荐理由
    public func proximity(to source: EmptyClassroomItem) -> ClassroomProximityInfo {
        let sameBuilding = (buildingId != nil && buildingId == source.buildingId) || (buildingPrefix == source.buildingPrefix)
        let floorDiff = abs(inferredFloor - source.inferredFloor)
        let roomGap = abs(roomIndexOnFloor - source.roomIndexOnFloor)

        if sameBuilding && floorDiff == 0 {
            let desc: String
            if roomGap <= 1 {
                desc = "同楼层 · 隔壁教室"
            } else if roomGap <= 3 {
                desc = "同楼层 · 仅隔\(roomGap)间"
            } else {
                desc = "同楼层 · \(inferredFloor)F"
            }
            return ClassroomProximityInfo(
                tier: 0,
                floorDiff: 0,
                roomGap: roomGap,
                badgeText: desc,
                sortScore: roomGap
            )
        } else if sameBuilding {
            let dir = inferredFloor > source.inferredFloor ? "楼上" : "楼下"
            let desc = "同楼\(dir)\(floorDiff)层 · \(inferredFloor)F"
            return ClassroomProximityInfo(
                tier: 1,
                floorDiff: floorDiff,
                roomGap: roomGap,
                badgeText: desc,
                sortScore: 100 + floorDiff * 30 + roomGap
            )
        } else {
            let desc = "邻楼 · \(buildingPrefix) \(inferredFloor)F"
            return ClassroomProximityInfo(
                tier: 2,
                floorDiff: floorDiff,
                roomGap: roomGap,
                badgeText: desc,
                sortScore: 500 + inferredFloor * 20 + roomGap
            )
        }
    }
}

public enum RoomFreeLevel: Int {
    case allDayFree = 0     // 全天空闲
    case restOfDayFree = 1  // 今日余下时间全空
    case partiallyFree = 2  // 当前空闲但稍后有课
    case soonOccupied = 3   // 30分钟内即将有课
    case occupied = 4       // 当前正在上课/占用
}

/// 两个教室之间的物理邻近度描述
public struct ClassroomProximityInfo: Equatable {
    public var tier: Int          // 0: 同楼同层, 1: 同楼不同层, 2: 邻近教学楼
    public var floorDiff: Int
    public var roomGap: Int
    public var badgeText: String
    public var sortScore: Int
}

/// 当自习教室有课时的附近换座推荐项
public struct RecommendedSwitchRoom: Identifiable, Equatable {
    public var id: Int { room.id }
    public var room: EmptyClassroomItem
    public var proximity: ClassroomProximityInfo
    public var isRestOfDayFree: Bool
    public var freeUntilText: String
}

/// 晚上走前推荐第二天空闲教室（搬书占座）的数据结构
public struct TomorrowCandidateRoom: Identifiable, Equatable {
    public var id: Int { room.id }
    public var room: EmptyClassroomItem
    public var isTonightCurrentlyFree: Bool
    public var proximityToCurrent: ClassroomProximityInfo?
    public var badgeText: String
}

public struct TomorrowStudyRecommendation: Equatable {
    public var tomorrowDateString: String
    public var currentStudyRoomName: String?
    public var isCurrentRoomAllDayFreeTomorrow: Bool
    public var currentRoomTomorrowFirstOccupation: ClassroomOccupation?
    public var headline: String
    public var subheadline: String
    public var candidates: [TomorrowCandidateRoom]
}

/// 用户设定的当前自习室持久化记录
public struct CurrentStudyRoomRecord: Codable, Equatable {
    public var roomId: Int
    public var roomName: String
    public var buildingId: Int?
    public var campusAssoc: Int
    public var dateString: String

    public init(
        roomId: Int,
        roomName: String,
        buildingId: Int? = nil,
        campusAssoc: Int,
        dateString: String
    ) {
        self.roomId = roomId
        self.roomName = roomName
        self.buildingId = buildingId
        self.campusAssoc = campusAssoc
        self.dateString = dateString
    }
}
