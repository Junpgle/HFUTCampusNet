using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace HFUTCampusNet;

#region 1. 校园网与在线设备模型

public sealed class OnlineDeviceSession
{
    [JsonPropertyName("sessionId")]
    public string SessionId { get; set; } = string.Empty;

    [JsonPropertyName("ip")]
    public string Ip { get; set; } = string.Empty;

    [JsonPropertyName("mac")]
    public string Mac { get; set; } = string.Empty;

    [JsonPropertyName("loginTime")]
    public string LoginTime { get; set; } = string.Empty;

    [JsonPropertyName("useMinutes")]
    public int UseMinutes { get; set; }

    [JsonPropertyName("usedFlowMB")]
    public double UsedFlowMB { get; set; }

    [JsonPropertyName("terminalType")]
    public string TerminalType { get; set; } = string.Empty;

    [JsonPropertyName("hostName")]
    public string HostName { get; set; } = string.Empty;

    public string FormattedMAC
    {
        get
        {
            var raw = Mac.Replace("-", "").Replace(":", "");
            if (raw.Length != 12) return Mac;
            var parts = new List<string>();
            for (int i = 0; i < 12; i += 2)
            {
                parts.Add(raw.Substring(i, 2));
            }
            return string.Join("-", parts);
        }
    }

    public string DisplayTitle
    {
        get
        {
            var hostPart = string.IsNullOrWhiteSpace(HostName) ? "" : $" ({HostName})";
            return $"{TerminalType}{hostPart} · {Ip}  [{UsedFlowMB:F1} M · {UseMinutes} 分钟]";
        }
    }

    public string DisplayType => string.IsNullOrWhiteSpace(TerminalType) ? "终端设备" : TerminalType;
    public string UsedFlow => UsedFlowMB >= 1024 ? $"{UsedFlowMB / 1024.0:F2} GB" : $"{UsedFlowMB:F1} MB";
}

public enum NetworkStatus
{
    Idle,
    Loading,
    Success,
    NeedLogin,
    Failed
}

public sealed class CampusNetworkData
{
    [JsonPropertyName("usedFlow")]
    public string UsedFlow { get; set; } = "-- M";

    [JsonPropertyName("availableFlow")]
    public string AvailableFlow { get; set; } = "-- M";

    [JsonPropertyName("flowProtection")]
    public string FlowProtection { get; set; } = "-- 元";

    [JsonPropertyName("balance")]
    public string Balance { get; set; } = "-- 元";

    [JsonPropertyName("lastUpdated")]
    public DateTime? LastUpdated { get; set; }

    [JsonPropertyName("errorMessage")]
    public string? ErrorMessage { get; set; }

    [JsonPropertyName("isLoggedIn")]
    public bool IsLoggedIn { get; set; }

    [JsonPropertyName("onlineDevices")]
    public List<OnlineDeviceSession> OnlineDevices { get; set; } = new();

    public bool IsSuccess => IsLoggedIn && string.IsNullOrEmpty(ErrorMessage);
    public NetworkStatus Status => IsLoggedIn ? NetworkStatus.Success : (string.IsNullOrEmpty(ErrorMessage) ? NetworkStatus.Idle : NetworkStatus.NeedLogin);

    public double? AvailableMB => ParseMB(AvailableFlow);

    public double? UsedMB => ParseMB(UsedFlow);

    public string FormattedAvailable
    {
        get
        {
            var mb = AvailableMB;
            if (!mb.HasValue) return AvailableFlow;
            return mb.Value >= 1024 ? $"{mb.Value / 1024.0:F1} G" : $"{mb.Value:F0} M";
        }
    }

    public string FormattedUsed
    {
        get
        {
            var mb = UsedMB;
            if (!mb.HasValue) return UsedFlow;
            return mb.Value >= 1024 ? $"{mb.Value / 1024.0:F2} G" : $"{mb.Value:F0} M";
        }
    }

    public double UsagePercentage
    {
        get
        {
            var used = UsedMB;
            if (!used.HasValue || used.Value < 0) return 0.0;
            return Math.Min(1.0, used.Value / (200.0 * 1024.0));
        }
    }

    private static double? ParseMB(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var match = Regex.Match(text, @"([0-9]+(?:\.[0-9]+)?)");
        if (!match.Success || !double.TryParse(match.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out double num))
        {
            return null;
        }

        var upper = text.ToUpperInvariant();
        if (upper.Contains('G')) return num * 1024.0;
        if (upper.Contains('K')) return num / 1024.0;
        return num;
    }
}

#endregion

#region 2. 宿舍电费模型

public sealed class ElectricityData
{
    [JsonPropertyName("campus")]
    public string Campus { get; set; } = "宣城校区";

    [JsonPropertyName("building")]
    public string Building { get; set; } = string.Empty;

    [JsonPropertyName("room")]
    public string Room { get; set; } = string.Empty;

    [JsonPropertyName("endNumber")]
    public string EndNumber { get; set; } = "11";

    [JsonPropertyName("balanceRMB")]
    public double? BalanceRMB { get; set; }

    [JsonPropertyName("remainingKWh")]
    public double? RemainingKWh { get; set; }

    [JsonPropertyName("lastUpdated")]
    public DateTime? LastUpdated { get; set; }

    [JsonPropertyName("rawDetails")]
    public Dictionary<string, string> RawDetails { get; set; } = new();

    public bool IsSuccess => BalanceRMB.HasValue || RemainingKWh.HasValue;
    public string RoomName => FormattedRoom;
    public string? ErrorMessage { get; set; }

    public string FormattedRoom
    {
        get
        {
            if (string.IsNullOrEmpty(Building) && string.IsNullOrEmpty(Room))
                return "未配置宿舍";
            return $"{Building}号楼 {Room}室";
        }
    }

    public string DisplayBalance => BalanceRMB.HasValue ? $"{BalanceRMB.Value:F2} 元" : "-- 元";

    public string DisplayPower => RemainingKWh.HasValue ? $"{RemainingKWh.Value:F1} 度" : "-- 度";

    public bool IsLowBalance => BalanceRMB.HasValue && BalanceRMB.Value < SettingsManager.Shared.ElectricityLowWarningThreshold;
}

#endregion

#region 3. 课程与校历模型

public sealed class CourseLesson
{
    public string Id { get; set; } = string.Empty;
    public int LessonId { get; set; }
    public string CourseName { get; set; } = string.Empty;
    public string? CourseCode { get; set; }
    public string? Teacher { get; set; }
    public string? Classroom { get; set; }
    public string DateString { get; set; } = string.Empty;
    public int StartTime { get; set; } // e.g. 800
    public int EndTime { get; set; }   // e.g. 940
    public int? WeekIndex { get; set; }
    public int Weekday { get; set; } = 1;

    public string FormattedTime => $"{StartTime / 100:D2}:{StartTime % 100:D2} - {EndTime / 100:D2}:{EndTime % 100:D2}";
    public string FormattedStartTime => $"{StartTime / 100:D2}:{StartTime % 100:D2}";
    public string FormattedEndTime => $"{EndTime / 100:D2}:{EndTime % 100:D2}";

    public int StartMinutes => (StartTime / 100) * 60 + (StartTime % 100);
    public int EndMinutes => (EndTime / 100) * 60 + (EndTime % 100);
    public int DurationMinutes => Math.Max(0, EndMinutes - StartMinutes);

    public DateTime? StartDate => CourseCalendarHelper.ParseDate(DateString, FormattedStartTime);
    public DateTime? EndDate => CourseCalendarHelper.ParseDate(DateString, FormattedEndTime);

    public bool IsOngoing(DateTime? date = null)
    {
        var now = date ?? DateTime.Now;
        var s = StartDate;
        var e = EndDate;
        if (!s.HasValue || !e.HasValue) return false;
        return s.Value <= now && now < e.Value;
    }

    public bool IsUpcoming(DateTime? date = null)
    {
        var now = date ?? DateTime.Now;
        var s = StartDate;
        return s.HasValue && s.Value > now;
    }

    public string CompactSummary
    {
        get
        {
            var roomStr = string.IsNullOrWhiteSpace(Classroom) ? "" : $"@ {Classroom}";
            var teacherStr = string.IsNullOrWhiteSpace(Teacher) ? "" : $"({Teacher})";
            return $"{FormattedStartTime} {CourseName} {roomStr} {teacherStr}".Trim();
        }
    }

    public string SimplifiedRoomText => Classroom ?? string.Empty;
    public string RoomText => Classroom ?? string.Empty;
    public string TeachersText => Teacher ?? string.Empty;

    private int _startUnit = 0;
    private int _endUnit = 0;

    public int StartUnit
    {
        get
        {
            if (_startUnit > 0) return _startUnit;
            return CalculateStartUnit(StartTime);
        }
        set => _startUnit = value;
    }

    public int EndUnit
    {
        get
        {
            if (_endUnit > 0) return Math.Max(StartUnit, _endUnit);
            return CalculateEndUnit(EndTime, StartUnit);
        }
        set => _endUnit = value;
    }

    public static int CalculateStartUnit(int startTime)
    {
        if (startTime <= 0) return 1;
        int minutes = (startTime / 100) * 60 + (startTime % 100);
        if (minutes < 535) return 1;       // 08:00 (480) ~ 08:50 (530)
        if (minutes < 595) return 2;       // 09:00 (540) ~ 09:50 (590)
        if (minutes < 655) return 3;       // 10:10 (610) ~ 11:00 (660) (兼容 10:00 填报)
        if (minutes < 730) return 4;       // 11:10 (670) ~ 12:00 (720)
        if (minutes < 895) return 5;       // 14:00 (840) ~ 14:50 (890)
        if (minutes < 955) return 6;       // 15:00 (900) ~ 15:50 (950)
        if (minutes < 1015) return 7;      // 16:00 (960) ~ 16:50 (1010)
        if (minutes < 1075) return 8;      // 17:00 (1020) ~ 17:50 (1070)
        if (minutes < 1195) return 9;      // 19:00 (1140) ~ 19:50 (1190)
        if (minutes < 1255) return 10;     // 20:00 (1200) ~ 20:50 (1250)
        return 11;                         // 21:00 (1260) ~ 21:50
    }

    public static int CalculateEndUnit(int endTime, int startUnit = 1)
    {
        if (endTime <= 0) return Math.Min(11, Math.Max(1, startUnit + 1));
        int minutes = (endTime / 100) * 60 + (endTime % 100);
        if (minutes <= 540) return 1;      // <= 09:00
        if (minutes <= 600) return 2;      // <= 10:00 (09:40 / 09:50)
        if (minutes <= 670) return 3;      // <= 11:10
        if (minutes <= 750) return 4;      // <= 12:30 (11:40 / 12:00)
        if (minutes <= 900) return 5;      // <= 15:00
        if (minutes <= 960) return 6;      // <= 16:00 (15:40 / 15:50)
        if (minutes <= 1020) return 7;     // <= 17:00
        if (minutes <= 1080) return 8;     // <= 18:00 (17:40 / 17:50)
        if (minutes <= 1200) return 9;     // <= 20:00
        if (minutes <= 1260) return 10;    // <= 21:00 (20:40 / 20:50)
        return 11;                         // > 21:00
    }

    public static string FormatWeekRanges(IEnumerable<int> weeks)
    {
        var list = weeks.Distinct().OrderBy(w => w).ToList();
        if (list.Count == 0) return "全学期";

        var segments = new List<string>();
        int start = list[0];
        int prev = list[0];

        for (int i = 1; i < list.Count; i++)
        {
            int w = list[i];
            if (w == prev + 1)
            {
                prev = w;
            }
            else
            {
                segments.Add(start == prev ? $"{start}" : $"{start}-{prev}");
                start = w;
                prev = w;
            }
        }
        segments.Add(start == prev ? $"{start}" : $"{start}-{prev}");
        return string.Join(",", segments) + "周";
    }

    public static void EnrichLessons(List<CourseLesson>? lessons)
    {
        if (lessons == null || lessons.Count == 0) return;

        var groups = lessons.GroupBy(l => $"{l.CourseName}_{l.Weekday}_{l.StartTime}");
        foreach (var g in groups)
        {
            var validWeeks = g.Where(l => l.WeekIndex.HasValue && l.WeekIndex > 0)
                              .Select(l => l.WeekIndex!.Value)
                              .ToList();

            string weekText = validWeeks.Count > 0 ? FormatWeekRanges(validWeeks) : "全学期";
            foreach (var lesson in g)
            {
                lesson.WeekText = weekText;
                lesson.StartUnit = CalculateStartUnit(lesson.StartTime);
                lesson.EndUnit = CalculateEndUnit(lesson.EndTime, lesson.StartUnit);
            }
        }
    }

    public string StartTimeText => FormattedStartTime;
    public string EndTimeText => FormattedEndTime;
    public string WeekText { get; set; } = string.Empty;
    public string LessonCode { get => CourseCode ?? string.Empty; set => CourseCode = value; }
    public string CreditsText { get; set; } = string.Empty;
    public string TeacherName => TeachersText;
    public string AdminClassText { get; set; } = string.Empty;
    public int SpanUnits => Math.Max(1, EndUnit - StartUnit + 1);
    public string Name => CourseName;
    public string Room => Classroom ?? string.Empty;
}

public sealed class SemesterOptionItem
{
    public string Id { get; set; } = string.Empty;
    public string NameZh { get; set; } = string.Empty;
}

public sealed class CourseMilestone
{
    public bool IsOngoing { get; set; }
    public CourseLesson Course { get; set; } = new();
}

public sealed class CourseScheduleData
{
    public string StudentId { get; set; } = string.Empty;
    public string SemesterId { get; set; } = "354";
    public string? SemesterName { get; set; }
    public string BizTypeId { get; set; } = "23";
    public DateTime? LastSyncTime { get; set; }
    public List<CourseLesson> Lessons { get; set; } = new();

    public List<SemesterOptionItem> Semesters { get; set; } = new();
    public string CurrentSemesterId { get => SemesterId; set => SemesterId = value; }
    public string CurrentSemesterName { get => SemesterName ?? string.Empty; set => SemesterName = value; }
    public int MaxWeek => 20;
    public int CalculatedCurrentWeek(DateTime? date = null) => CurrentWeek(date ?? DateTime.Now) ?? 1;
    public List<CourseLesson> Items => Lessons;
    public List<CourseLesson> Courses(int forWeek) => LessonsForWeek(forWeek);
    public List<CourseLesson> Activities(int forWeek) => LessonsForWeek(forWeek);
    public List<CourseLesson> CoursesOn(int week, int weekday) => LessonsForWeek(week).Where(l => l.Weekday == weekday).ToList();
    public string SemesterStartDateString { get; set; } = string.Empty;
    public string RoomName { get; set; } = string.Empty;

    public CourseMilestone? NextCourseMilestone(DateTime? now = null)
    {
        var dt = now ?? DateTime.Now;
        var cur = CurrentLesson(dt);
        if (cur != null)
        {
            return new CourseMilestone { IsOngoing = true, Course = cur };
        }
        var next = NextLesson(dt);
        if (next != null)
        {
            return new CourseMilestone { IsOngoing = false, Course = next };
        }
        return null;
    }

    public List<CourseLesson> LessonsForDate(string dateStr)
    {
        return Lessons.Where(l => l.DateString == dateStr).OrderBy(l => l.StartTime).ToList();
    }

    public List<CourseLesson> LessonsForWeek(int week)
    {
        return Lessons.Where(l => l.WeekIndex == week)
            .OrderBy(l => l.Weekday)
            .ThenBy(l => l.StartTime)
            .ToList();
    }

    public Dictionary<int, DateTime> DatesForWeek(int week)
    {
        var result = new Dictionary<int, DateTime>();
        var weekItems = Lessons.Where(l => l.WeekIndex == week).ToList();
        var anchor = weekItems.FirstOrDefault();
        if (anchor != null && CourseCalendarHelper.ParseDate(anchor.DateString, "00:00") is DateTime anchorDate)
        {
            for (int d = 1; d <= 7; d++)
            {
                result[d] = anchorDate.AddDays(d - anchor.Weekday);
            }
            return result;
        }

        var refLesson = Lessons.FirstOrDefault(l => l.WeekIndex.HasValue);
        if (refLesson != null && refLesson.WeekIndex.HasValue && CourseCalendarHelper.ParseDate(refLesson.DateString, "00:00") is DateTime refDate)
        {
            for (int d = 1; d <= 7; d++)
            {
                int dayOffset = (week - refLesson.WeekIndex.Value) * 7 + (d - refLesson.Weekday);
                result[d] = refDate.AddDays(dayOffset);
            }
        }
        return result;
    }

    public List<CourseLesson> TodayLessons(DateTime? now = null)
    {
        var dateStr = CourseCalendarHelper.DateString(now ?? DateTime.Now);
        return LessonsForDate(dateStr);
    }

    public CourseLesson? CurrentLesson(DateTime? now = null)
    {
        var dt = now ?? DateTime.Now;
        return TodayLessons(dt).FirstOrDefault(l => l.IsOngoing(dt));
    }

    public CourseLesson? NextLesson(DateTime? now = null)
    {
        var dt = now ?? DateTime.Now;
        return TodayLessons(dt).FirstOrDefault(l => l.IsUpcoming(dt));
    }

    public List<int> AllWeeks => Lessons.Where(l => l.WeekIndex.HasValue).Select(l => l.WeekIndex!.Value).Distinct().OrderBy(w => w).ToList();

    public int? CurrentWeek(DateTime? now = null)
    {
        var dt = now ?? DateTime.Now;
        var todayStr = CourseCalendarHelper.DateString(dt);
        var match = Lessons.FirstOrDefault(l => l.DateString == todayStr && l.WeekIndex.HasValue);
        if (match != null) return match.WeekIndex;

        var refLesson = Lessons.FirstOrDefault(l => l.WeekIndex.HasValue && !string.IsNullOrEmpty(l.DateString));
        if (refLesson != null && refLesson.WeekIndex.HasValue
            && CourseCalendarHelper.ParseDate(refLesson.DateString, "00:00") is DateTime refDate
            && CourseCalendarHelper.ParseDate(todayStr, "00:00") is DateTime todayDate)
        {
            var refMonday = refDate.AddDays(-(refLesson.Weekday - 1));
            var daysDiff = (todayDate - refMonday).Days;
            var weekOffset = (int)Math.Floor(daysDiff / 7.0);
            var computed = refLesson.WeekIndex.Value + weekOffset;
            var maxW = Math.Max(AllWeeks.LastOrDefault(), 20);
            if (computed >= 1 && computed <= maxW) return computed;
            return null;
        }

        var future = Lessons.Where(l => string.CompareOrdinal(l.DateString, todayStr) >= 0 && l.WeekIndex.HasValue)
            .OrderBy(l => l.DateString)
            .FirstOrDefault();
        return future?.WeekIndex;
    }
}

public static class CourseCalendarHelper
{
    private static readonly TimeZoneInfo BeijingZone = GetBeijingTimeZone();

    private static TimeZoneInfo GetBeijingTimeZone()
    {
        try { return TimeZoneInfo.FindSystemTimeZoneById("China Standard Time"); }
        catch { return TimeZoneInfo.Local; }
    }

    public static DateTime? ParseDate(string dateStr, string timeStr)
    {
        if (string.IsNullOrWhiteSpace(dateStr)) return null;
        var combined = $"{dateStr.Trim()} {timeStr.Trim()}";
        if (DateTime.TryParseExact(combined, "yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt))
        {
            return dt;
        }
        if (DateTime.TryParse(combined, CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt2))
        {
            return dt2;
        }
        return null;
    }

    public static string DateString(DateTime date) => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    public static int Weekday(DateTime date)
    {
        // Monday = 1 ... Sunday = 7
        return date.DayOfWeek switch
        {
            DayOfWeek.Monday => 1,
            DayOfWeek.Tuesday => 2,
            DayOfWeek.Wednesday => 3,
            DayOfWeek.Thursday => 4,
            DayOfWeek.Friday => 5,
            DayOfWeek.Saturday => 6,
            DayOfWeek.Sunday => 7,
            _ => 1
        };
    }

    public static string WeekdayName(int weekday)
    {
        return weekday switch
        {
            1 => "周一",
            2 => "周二",
            3 => "周三",
            4 => "周四",
            5 => "周五",
            6 => "周六",
            7 => "周日",
            _ => $"周{weekday}"
        };
    }

    public static int InferSemesterId(DateTime? date = null)
    {
        var dt = date ?? DateTime.Now;
        var month = dt.Month;
        var year = dt.Year - (month <= 7 ? 1 : 0);
        var isSpring = month >= 2 && month <= 7;
        return ((year - 2018) * 4 + 3) * 10 + 4 + (isSpring ? 20 : 0);
    }

    public static string FormatSemesterName(int semesterId)
    {
        if (semesterId >= 34 && (semesterId - 34) % 20 == 0)
        {
            var k = (semesterId - 34) / 20;
            var startYear = 2018 + (k / 2);
            var term = (k % 2) + 1;
            return $"{startYear}-{startYear + 1}学年 第{term}学期";
        }
        return $"学期 ID: {semesterId}";
    }
}

#endregion

#region 4. 学业成绩、考场安排与培养方案模型

public sealed class ExamItem
{
    public string Id { get; set; } = string.Empty;
    public string CourseName { get; set; } = string.Empty;
    public string? CourseCode { get; set; }
    public string DateTimeString { get; set; } = string.Empty;
    public string DateString { get; set; } = string.Empty;
    public string StartTimeString { get; set; } = string.Empty;
    public string EndTimeString { get; set; } = string.Empty;
    public string? Place { get; set; }
    public string? Building { get; set; }
    public string? Campus { get; set; }
    public string? ExamType { get; set; } = "期末考试";
    public string? SeatNumber { get; set; }
    public string? Teacher { get; set; }

    public DateTime? StartDate => CourseCalendarHelper.ParseDate(DateString, StartTimeString);
    public DateTime? ExamStartDate => StartDate;
    public DateTime? EndDate => CourseCalendarHelper.ParseDate(DateString, EndTimeString);
    public string DateTimeText => DateTimeString;
    public string Room => DisplayLocation;

    public bool IsFinished(DateTime? now = null) => (EndDate ?? DateTime.MinValue) <= (now ?? DateTime.Now);
    public bool IsOngoing(DateTime? now = null)
    {
        var dt = now ?? DateTime.Now;
        var s = StartDate;
        var e = EndDate;
        return s.HasValue && e.HasValue && s.Value <= dt && dt < e.Value;
    }

    public int DaysRemaining(DateTime? now = null)
    {
        var dt = (now ?? DateTime.Now).Date;
        if (CourseCalendarHelper.ParseDate(DateString, "00:00") is DateTime examDay)
        {
            return (examDay.Date - dt).Days;
        }
        return 0;
    }

    public string CountdownBadgeText(DateTime? now = null)
    {
        var dt = now ?? DateTime.Now;
        if (IsOngoing(dt)) return "正在考试";
        if (IsFinished(dt)) return "已结束";
        var days = DaysRemaining(dt);
        if (days == 0) return $"今天 {StartTimeString}";
        if (days == 1) return $"明天 {StartTimeString}";
        if (days == 2) return $"后天 {StartTimeString}";
        return $"还有 {days} 天";
    }

    public string DisplayLocation
    {
        get
        {
            var parts = new[] { Campus, Building, Place }
                .Where(s => !string.IsNullOrWhiteSpace(s))
                .Select(s => s!.Trim())
                .Distinct()
                .ToList();
            var seat = string.IsNullOrWhiteSpace(SeatNumber) ? "" : $" · 座位号: {SeatNumber}";
            return parts.Count == 0 ? "考场待定" : $"{string.Join(" · ", parts)}{seat}";
        }
    }
}

public sealed record CourseExamForecast(
    int LessonId,
    string CourseName,
    string? CourseCode,
    string LastLessonDateString,
    string PredictedDateString)
{
    public string PredictedDateDisplayText => $"{PredictedDateString}（预计）";
    public string BasisDisplayText => $"最后一次课 {LastLessonDateString} · 按所在周取次次周周一";
}

public static class CourseExamForecastService
{
    /// <summary>Estimates the Monday of the second week after each teaching group's final lesson week.</summary>
    public static List<CourseExamForecast> Upcoming(
        CourseScheduleData? schedule,
        IEnumerable<ExamItem>? officialExams = null,
        DateTime? now = null)
    {
        if (schedule?.Lessons == null || schedule.Lessons.Count == 0) return new List<CourseExamForecast>();

        var dt = now ?? DateTime.Now;
        var today = CourseCalendarHelper.ParseDate(CourseCalendarHelper.DateString(dt), "00:00") ?? dt.Date;
        var finalExams = (officialExams ?? Enumerable.Empty<ExamItem>())
            .Where(exam => string.IsNullOrWhiteSpace(exam.ExamType) || !exam.ExamType!.Contains("期中", StringComparison.OrdinalIgnoreCase))
            .ToList();
        var forecasts = new List<CourseExamForecast>();

        foreach (var group in schedule.Lessons.GroupBy(lesson => lesson.LessonId))
        {
            if (group.Key <= 0) continue;
            var lastLesson = group
                .Select(lesson => new
                {
                    Lesson = lesson,
                    Date = CourseCalendarHelper.ParseDate(lesson.DateString, "00:00")
                })
                .Where(item => item.Date.HasValue)
                .OrderByDescending(item => item.Date)
                .FirstOrDefault();

            if (lastLesson?.Date is not DateTime lastDate) continue;
            var daysUntilSecondNextMonday = 15 - CourseCalendarHelper.Weekday(lastDate);
            var predictedDate = lastDate.Date.AddDays(daysUntilSecondNextMonday);
            if (predictedDate < today) continue;

            bool hasPublishedFinalExam = finalExams.Any(exam => MatchesCourse(
                lastLesson.Lesson.CourseName,
                lastLesson.Lesson.CourseCode,
                exam.CourseName,
                exam.CourseCode));
            if (hasPublishedFinalExam) continue;

            forecasts.Add(new CourseExamForecast(
                group.Key,
                lastLesson.Lesson.CourseName,
                lastLesson.Lesson.CourseCode,
                CourseCalendarHelper.DateString(lastDate),
                CourseCalendarHelper.DateString(predictedDate)));
        }

        return forecasts
            .OrderBy(item => item.PredictedDateString, StringComparer.Ordinal)
            .ThenBy(item => item.CourseName, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static bool MatchesCourse(string courseName, string? courseCode, string examName, string? examCode)
    {
        var normalizedCourseCode = Normalize(courseCode);
        var normalizedExamCode = Normalize(examCode);
        if (normalizedCourseCode != null && normalizedExamCode != null)
            return string.Equals(normalizedCourseCode, normalizedExamCode, StringComparison.OrdinalIgnoreCase);

        var normalizedCourseName = Normalize(courseName);
        var normalizedExamName = Normalize(examName);
        return normalizedCourseName != null && normalizedExamName != null
            && string.Equals(normalizedCourseName, normalizedExamName, StringComparison.OrdinalIgnoreCase);
    }

    private static string? Normalize(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var normalized = new string(value.Where(character => !char.IsWhiteSpace(character)).ToArray()).ToUpperInvariant();
        return normalized.Length == 0 ? null : normalized;
    }
}

public sealed class GradeItem
{
    public string Id { get; set; } = string.Empty;
    public string TermName { get; set; } = string.Empty;
    public int? SemesterId { get; set; }
    public string CourseName { get; set; } = string.Empty;
    public string CourseCode { get; set; } = string.Empty;
    public string LessonCode { get; set; } = string.Empty;
    public double Credits { get; set; }
    public double? Gpa { get; set; }
    public string ScoreText { get; set; } = string.Empty;
    public bool? PassedOverride { get; set; }
    public string Score => ScoreText;
    public string Gp => Gpa.HasValue ? $"{Gpa.Value:F1}" : "--";

    public double? NumericScore
    {
        get
        {
            if (double.TryParse(ScoreText, NumberStyles.Float, CultureInfo.InvariantCulture, out double val))
                return val;
            return ScoreText switch
            {
                "优秀" => 95,
                "良好" => 85,
                "中等" => 75,
                "及格" => 65,
                "不及格" => 50,
                "通过" or "P" => 85,
                _ => null
            };
        }
    }

    public bool Passed => PassedOverride ??
        (ScoreText != "不及格" && ScoreText != "F" && ScoreText != "NP" && (NumericScore == null || NumericScore.Value >= 60));

    public double EffectiveNumericScore
    {
        get
        {
            if (NumericScore.HasValue) return NumericScore.Value;
            if (Gpa.HasValue) return 60 + Gpa.Value * 10;
            return 80;
        }
    }

    public string DetailText
    {
        get
        {
            var gpaStr = Gpa.HasValue ? $"{Gpa.Value:F1}" : "--";
            return $"{Credits:F1}学分 · 绩点: {gpaStr}";
        }
    }
}

public sealed class SemesterGradeGroup
{
    public string TermName { get; set; } = string.Empty;
    public int? SemesterId { get; set; }
    public List<GradeItem> Grades { get; set; } = new();

    public double TotalCredits => Grades.Where(g => g.Passed).Sum(g => g.Credits);

    public double? WeightedGPA
    {
        get
        {
            var valid = Grades.Where(g => g.Gpa.HasValue && g.Credits > 0).ToList();
            if (valid.Count == 0) return null;
            var totalC = valid.Sum(g => g.Credits);
            if (totalC <= 0) return null;
            return valid.Sum(g => g.Gpa!.Value * g.Credits) / totalC;
        }
    }

    public double? WeightedAverageScore
    {
        get
        {
            var valid = Grades.Where(g => g.Credits > 0).ToList();
            if (valid.Count == 0) return null;
            var totalC = valid.Sum(g => g.Credits);
            if (totalC <= 0) return null;
            return valid.Sum(g => g.EffectiveNumericScore * g.Credits) / totalC;
        }
    }
}

public sealed class ProgramModuleItem
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public int Level { get; set; }
    public double RequiredCredits { get; set; }
    public double PassedCredits { get; set; }
    public double TakingCredits { get; set; }
    public int PassedCourseCount { get; set; }
    public int TakingCourseCount { get; set; }
    public List<string> TakingCourseNames { get; set; } = new();
    public List<string> UnrepairedCourseNames { get; set; } = new();

    public string IndentedDisplayName
    {
        get
        {
            return Level switch
            {
                0 => $"■ {Name}",
                1 => $"   ▶ {Name}",
                2 => $"      • {Name}",
                _ => $"         - {Name}"
            };
        }
    }

    public double DeficitAfterPassed => Math.Max(0.0, RequiredCredits - PassedCredits);
    public double DeficitAfterTaking => Math.Max(0.0, RequiredCredits - PassedCredits - TakingCredits);

    public string StatusBadgeText
    {
        get
        {
            if (RequiredCredits <= 0)
            {
                if (PassedCredits > 0 || TakingCredits > 0)
                    return $"已修 {PassedCredits + TakingCredits:F1} 分";
                return "任选子模块";
            }
            if (PassedCredits >= RequiredCredits - 0.01) return "✅ 已达标 (100%)";
            if (PassedCredits + TakingCredits >= RequiredCredits - 0.01) return "⏳ 含在修达标";
            return $"差 {DeficitAfterPassed:F1} 学分 (含在修差 {DeficitAfterTaking:F1})";
        }
    }

    public string CourseDetailSummary
    {
        get
        {
            var parts = new List<string>();
            if (TakingCourseNames.Count > 0)
            {
                var preview = string.Join("、", TakingCourseNames.Take(5));
                var suffix = TakingCourseNames.Count > 5 ? $" 等{TakingCourseNames.Count}门" : "";
                parts.Add($"【在修】{preview}{suffix}");
            }
            if (UnrepairedCourseNames.Count > 0 && Level <= 1)
            {
                var preview = string.Join("、", UnrepairedCourseNames.Take(5));
                var suffix = UnrepairedCourseNames.Count > 5 ? $" 等{UnrepairedCourseNames.Count}门" : "";
                parts.Add($"【待修】{preview}{suffix}");
            }
            return parts.Count == 0 ? (PassedCourseCount > 0 ? $"已修过 {PassedCourseCount} 门课程" : "--") : string.Join("  ", parts);
        }
    }
}

public sealed class ProgramCompletionSummary
{
    public string ProgramName { get; set; } = string.Empty;
    public string GradeYear { get; set; } = string.Empty;
    public string AuditDateTime { get; set; } = string.Empty;
    public double RequiredCredits { get; set; }
    public double PassedCredits { get; set; }
    public double TakingCredits { get; set; }
    public int PassedCourseCount { get; set; }
    public int TakingCourseCount { get; set; }
    public double OuterPassedCredits { get; set; }
    public double OuterTakingCredits { get; set; }
    public List<ProgramModuleItem> Modules { get; set; } = new();

    public double CompletionPercentage => RequiredCredits > 0 ? Math.Min(100.0, (PassedCredits / RequiredCredits) * 100.0) : 0;
    public double ProjectedPercentageWithTaking => RequiredCredits > 0 ? Math.Min(100.0, ((PassedCredits + TakingCredits) / RequiredCredits) * 100.0) : 0;
    public double RemainingCreditsAfterTaking => Math.Max(0.0, RequiredCredits - PassedCredits - TakingCredits);
}

public sealed class CourseTextbookItem
{
    public string Id { get; set; } = string.Empty;
    public string CourseName { get; set; } = string.Empty;
    public string CourseCode { get; set; } = string.Empty;
    public string LessonCode { get; set; } = string.Empty;
    public double Credits { get; set; }
    public string CourseType { get; set; } = string.Empty;
    public string ExamMode { get; set; } = "考试";
    public string Department { get; set; } = string.Empty;
    public string TextbookName { get; set; } = string.Empty;
    public string ReferenceBookName { get; set; } = string.Empty;
    public string ScheduleSummary { get; set; } = string.Empty;

    public string DisplayTextbook
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(TextbookName)) return TextbookName;
            if (!string.IsNullOrWhiteSpace(ReferenceBookName)) return ReferenceBookName;
            return "暂未指定教材 / 教师自编讲义";
        }
    }
}

public sealed class LessonSurveyItem
{
    public string Id { get; set; } = string.Empty;
    public string LessonCode { get; set; } = string.Empty;
    public string CourseName { get; set; } = string.Empty;
    public string OpenEndTimeText { get; set; } = string.Empty;
    public List<string> PendingTeachers { get; set; } = new();
    public List<string> CompletedTeachers { get; set; } = new();

    public bool IsAllCompleted => PendingTeachers.Count == 0;
}

public sealed class SemesterMilestoneInfo
{
    public int SemesterId { get; set; }
    public string SemesterName { get; set; } = string.Empty;
    public string StartDateString { get; set; } = string.Empty;
    public string EndDateString { get; set; } = string.Empty;
    public int CurrentWeek { get; set; } = 1;
    public int TotalWeeks { get; set; } = 19;
    public double ProgressPercentage { get; set; }
    public int DaysUntilExamWeek { get; set; }
    public int DaysUntilVacation { get; set; }
    public string VacationName { get; set; } = "假期";

    public string StatusSummaryText => $"校历: 第 {CurrentWeek}/{TotalWeeks} 周 ({ProgressPercentage:F0}%) · 距期末周约 {DaysUntilExamWeek} 天";

    public static SemesterMilestoneInfo Calculate(int? semId = null, CourseScheduleData? schedule = null, DateTime? date = null)
    {
        var now = (date ?? DateTime.Now).Date;
        var hasScheduleSemesterId = int.TryParse(
            schedule?.SemesterId,
            NumberStyles.Integer,
            CultureInfo.InvariantCulture,
            out var scheduleSemesterId) && scheduleSemesterId > 0;
        var sid = semId ?? (hasScheduleSemesterId
            ? scheduleSemesterId
            : CourseCalendarHelper.InferSemesterId(now));

        // 合工大校历官方起止日期表 (学期ID -> (开始日期, 结束日期, 总周数))
        var dates = new Dictionary<int, (string Start, string End, int Weeks, string Vacation)>
        {
            [354] = ("2026-08-31", "2027-01-17", 20, "寒假"),
            [334] = ("2026-02-23", "2026-07-12", 20, "暑假"),
            [314] = ("2025-09-01", "2026-01-18", 20, "寒假"),
            [294] = ("2025-02-24", "2025-07-13", 20, "暑假"),
            [274] = ("2024-09-02", "2025-01-19", 20, "寒假"),
        };

        (string Start, string End, int Weeks, string Vacation) defaultConfig = ("2026-08-31", "2027-01-17", 20, "寒假");
        var config = dates.TryGetValue(sid, out var tuple) ? tuple : defaultConfig;
        var startDate = DateTime.ParseExact(config.Start, "yyyy-MM-dd", CultureInfo.InvariantCulture);
        var endDate = DateTime.ParseExact(config.End, "yyyy-MM-dd", CultureInfo.InvariantCulture);

        var curWeek = schedule?.CurrentWeek(now) ?? Math.Clamp((int)Math.Floor((now - startDate).Days / 7.0) + 1, 1, config.Weeks);
        var totalDays = Math.Max(1, (endDate - startDate).Days);
        var passedDays = Math.Clamp((now - startDate).Days, 0, totalDays);
        var progress = Math.Round((double)passedDays / totalDays * 100.0, 1);

        var examWeekStart = endDate.AddDays(-14);
        var daysToExam = Math.Max(0, (examWeekStart - now).Days);
        var daysToVac = Math.Max(0, (endDate - now).Days);

        return new SemesterMilestoneInfo
        {
            SemesterId = sid,
            SemesterName = CourseCalendarHelper.FormatSemesterName(sid),
            StartDateString = config.Start,
            EndDateString = config.End,
            CurrentWeek = curWeek,
            TotalWeeks = config.Weeks,
            ProgressPercentage = progress,
            DaysUntilExamWeek = daysToExam,
            DaysUntilVacation = daysToVac,
            VacationName = config.Vacation
        };
    }
}

public sealed class AcademicGpaSummary
{
    public string Gpa { get; set; } = string.Empty;
    public string WeightedAvg { get; set; } = string.Empty;
    public string MajorRank { get; set; } = string.Empty;
}

public sealed class AcademicDataSnapshot
{
    public string StudentId { get; set; } = string.Empty;
    public DateTime? LastGradesSyncTime { get; set; }
    public DateTime? LastExamsSyncTime { get; set; }
    public List<GradeItem> AllGrades { get; set; } = new();
    public List<ExamItem> Exams { get; set; } = new();
    public ProgramCompletionSummary? ProgramCompletion { get; set; }
    public List<CourseTextbookItem> Textbooks { get; set; } = new();
    public List<LessonSurveyItem> Surveys { get; set; } = new();
    public string? LastErrorMessage { get; set; }

    public double TotalEarnedCredits => AllGrades.Where(g => g.Passed).Sum(g => g.Credits);

    public double? OverallWeightedGPA
    {
        get
        {
            var valid = AllGrades.Where(g => g.Gpa.HasValue && g.Credits > 0).ToList();
            if (valid.Count == 0) return null;
            var totalC = valid.Sum(g => g.Credits);
            return totalC > 0 ? valid.Sum(g => g.Gpa!.Value * g.Credits) / totalC : null;
        }
    }

    public double? OverallWeightedAverageScore
    {
        get
        {
            var valid = AllGrades.Where(g => g.Credits > 0).ToList();
            if (valid.Count == 0) return null;
            var totalC = valid.Sum(g => g.Credits);
            return totalC > 0 ? valid.Sum(g => g.EffectiveNumericScore * g.Credits) / totalC : null;
        }
    }

    public List<GradeItem> Grades => AllGrades;

    public AcademicGpaSummary? GpaSummary => OverallWeightedGPA.HasValue ? new AcademicGpaSummary
    {
        Gpa = OverallWeightedGPA.Value.ToString("F2"),
        WeightedAvg = OverallWeightedAverageScore.HasValue ? OverallWeightedAverageScore.Value.ToString("F1") : "--",
        MajorRank = "--"
    } : null;

    public ExamItem? NextUpcomingExam(DateTime? now = null)
    {
        var dt = now ?? DateTime.Now;
        return Exams.Where(e => !e.IsFinished(dt)).OrderBy(e => e.ExamStartDate ?? DateTime.MaxValue).FirstOrDefault();
    }

    public List<SemesterGradeGroup> SemesterGroups
    {
        get
        {
            return AllGrades.GroupBy(g => g.TermName)
                .Select(grp => new SemesterGradeGroup
                {
                    TermName = grp.Key,
                    SemesterId = grp.FirstOrDefault()?.SemesterId,
                    Grades = grp.ToList()
                })
                .OrderByDescending(g => g.SemesterId ?? 0)
                .ToList();
        }
    }

    public List<ExamItem> UpcomingExams(DateTime? now = null)
    {
        var dt = now ?? DateTime.Now;
        return Exams.Where(e => !e.IsFinished(dt)).OrderBy(e => e.DateString).ThenBy(e => e.StartTimeString).ToList();
    }

    public int PendingSurveyCount => Surveys.Sum(s => s.PendingTeachers.Count);
}

#endregion

#region 5. 校园一卡通与流水模型

public sealed class CampusCardTransaction
{
    public string Id { get; set; } = string.Empty;
    public string TimeString { get; set; } = string.Empty;
    public string DateTimeString { get => TimeString; set => TimeString = value; }
    public string MerchantName { get; set; } = string.Empty;
    public string TxType { get; set; } = string.Empty;
    public string TurnoverType { get => TxType; set => TxType = value; }
    public double AmountRMB { get; set; }
    public double? BalanceAfterRMB { get; set; }
    public bool IsRecharge =>
        TurnoverType.Contains("充值") || TurnoverType.Contains("补助") ||
        MerchantName.Contains("充值") || MerchantName.Contains("补助");
    public bool IsRefund =>
        TurnoverType.Contains("退款") || TurnoverType.Contains("退费") || TurnoverType.Contains("冲正") ||
        MerchantName.Contains("退款") || MerchantName.Contains("退费") || MerchantName.Contains("冲正");
    public bool IsExpense => !IsRecharge && !IsRefund;
    public string Time => TimeString;
    public string Merchant => CleanMerchantName;
    public double AmountYuan => AmountRMB;

    public string CleanMerchantName
    {
        get
        {
            var name = MerchantName.Replace("合肥", "").Replace("安徽", "").Replace("宣城", "").Trim();
            if (name.Contains("食堂") || name.Contains("餐饮") || name.Contains("超市") || name.Contains("咖啡"))
                return name;
            return string.IsNullOrWhiteSpace(name) ? "校园消费" : name;
        }
    }

    public string DateOnlyString => TimeString.Length >= 10 ? TimeString.Substring(0, 10) : TimeString;
    public string MonthPrefixString => TimeString.Length >= 7 ? TimeString.Substring(0, 7) : TimeString;
    public string TimeOnlyString => TimeString.Length >= 16 ? TimeString.Substring(11, 5) : "";

    public int HourOfDay
    {
        get
        {
            if (TimeString.Length >= 13 && int.TryParse(TimeString.Substring(11, 2), out int h))
                return h;
            return 12;
        }
    }

    public string SceneCategoryTag
    {
        get
        {
            if (IsRefund) return "退款退费";
            if (IsRecharge) return "充值转账";
            var m = MerchantName;
            if (m.Contains("超市") || m.Contains("便利")) return "超市购物";
            if (m.Contains("洗浴") || m.Contains("水控") || m.Contains("开水")) return "洗浴水控";
            if (m.Contains("医院") || m.Contains("门诊")) return "校医院";
            if (m.Contains("电费")) return "宿舍电费";

            var h = HourOfDay;
            if (h >= 6 && h <= 9) return "早餐餐段";
            if (h >= 10 && h <= 14) return "午餐餐段";
            if (h >= 16 && h <= 21) return "晚餐餐段";
            return "夜宵/其他";
        }
    }

    public string FormattedAmount => $"{(IsExpense ? "-" : "+")}¥{AmountRMB:F2}";
}

public sealed class ExpenseStructureBreakdownResult
{
    public double BreakfastRMB { get; set; }
    public double LunchRMB { get; set; }
    public double DinnerRMB { get; set; }
    public double OtherRMB { get; set; }
    public string TopMerchantsText { get; set; } = string.Empty;
    public string RatioSummaryText { get; set; } = string.Empty;

    public double Breakfast => BreakfastRMB;
    public double Lunch => LunchRMB;
    public double Dinner => DinnerRMB;
    public double Other => OtherRMB;
    public string TopMerchants => TopMerchantsText;
    public string RatioSummary => RatioSummaryText;

    public void Deconstruct(out double b, out double l, out double d, out double o, out string top, out string ratio)
    {
        b = BreakfastRMB;
        l = LunchRMB;
        d = DinnerRMB;
        o = OtherRMB;
        top = TopMerchantsText;
        ratio = RatioSummaryText;
    }
}

public sealed class CampusCardData
{
    public string CardNumber { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public double BalanceRMB { get; set; }
    public double UnclaimedRMB { get; set; }
    public string StatusText { get; set; } = "正常";
    public bool IsFrozenOrLost { get; set; }
    public List<CampusCardTransaction> Transactions { get; set; } = new();
    public DateTime? LastUpdated { get; set; }

    public bool IsSuccess => !string.IsNullOrEmpty(CardNumber) || BalanceRMB > 0;
    public double BalanceYuan => BalanceRMB;
    public string CardAccount { get => CardNumber; set => CardNumber = value; }
    public string HolderName { get => Name; set => Name = value; }
    public string DepartmentName { get; set; } = string.Empty;
    public double UnsettleAmountRMB { get => UnclaimedRMB; set => UnclaimedRMB = value; }
    public string CardStatusText { get => StatusText; set => StatusText = value; }
    public string CardStatus => StatusText;
    public double TodaySpentYuan => TodaySpentRMB();
    public double WeekSpentYuan => Transactions.Where(t => string.CompareOrdinal(t.DateOnlyString, DateTime.Now.Date.AddDays(-7).ToString("yyyy-MM-dd")) >= 0 && t.IsExpense).Sum(t => t.AmountRMB);
    public double MonthSpentYuan => CurrentMonthSpentRMB();
    public string ErrorMessage { get; set; } = string.Empty;

    public string DisplayBalance => $"{BalanceRMB:F2} 元";
    public bool IsLowBalance => BalanceRMB < SettingsManager.Shared.CampusCardLowWarningThreshold;

    public double TodaySpentRMB(DateTime? now = null)
    {
        var today = CourseCalendarHelper.DateString(now ?? DateTime.Now);
        return Transactions.Where(t => t.DateOnlyString == today && t.IsExpense).Sum(t => t.AmountRMB);
    }

    public int TodayExpenseCount(DateTime? now = null)
    {
        var today = CourseCalendarHelper.DateString(now ?? DateTime.Now);
        return Transactions.Count(t => t.DateOnlyString == today && t.IsExpense);
    }

    public double Past7DaysAverageSpentRMB(DateTime? now = null)
    {
        var dt = (now ?? DateTime.Now).Date;
        var cutoff = dt.AddDays(-7).ToString("yyyy-MM-dd");
        var expenses = Transactions.Where(t => string.CompareOrdinal(t.DateOnlyString, cutoff) >= 0 && t.IsExpense).ToList();
        var activeDays = Math.Max(1, expenses.Select(t => t.DateOnlyString).Distinct().Count());
        return expenses.Sum(t => t.AmountRMB) / activeDays;
    }

    public double CurrentMonthSpentRMB(DateTime? now = null)
    {
        var prefix = (now ?? DateTime.Now).ToString("yyyy-MM");
        return Transactions.Where(t => t.MonthPrefixString == prefix && t.IsExpense).Sum(t => t.AmountRMB);
    }

    public int CurrentMonthExpenseCount(DateTime? now = null)
    {
        var prefix = (now ?? DateTime.Now).ToString("yyyy-MM");
        return Transactions.Count(t => t.MonthPrefixString == prefix && t.IsExpense);
    }

    public double CurrentMonthRechargedRMB(DateTime? now = null)
    {
        var prefix = (now ?? DateTime.Now).ToString("yyyy-MM");
        return Transactions.Where(t => t.MonthPrefixString == prefix && t.IsRecharge).Sum(t => t.AmountRMB);
    }

    public ExpenseStructureBreakdownResult ExpenseStructureBreakdown()
    {
        var expenses = Transactions.Where(t => t.IsExpense).ToList();
        var total = Math.Max(0.01, expenses.Sum(t => t.AmountRMB));

        double b = 0, l = 0, d = 0, o = 0;
        var merchMap = new Dictionary<string, double>();

        foreach (var tx in expenses)
        {
            var tag = tx.SceneCategoryTag;
            if (tag.StartsWith("早餐")) b += tx.AmountRMB;
            else if (tag.StartsWith("午餐")) l += tx.AmountRMB;
            else if (tag.StartsWith("晚餐")) d += tx.AmountRMB;
            else o += tx.AmountRMB;

            var name = tx.CleanMerchantName;
            merchMap[name] = merchMap.GetValueOrDefault(name) + tx.AmountRMB;
        }

        int bPct = (int)Math.Round(b / total * 100);
        int lPct = (int)Math.Round(l / total * 100);
        int dPct = (int)Math.Round(d / total * 100);
        int oPct = Math.Max(0, 100 - bPct - lPct - dPct);

        var parts = new List<string>();
        if (lPct > 0) parts.Add($"午{lPct}%");
        if (dPct > 0) parts.Add($"晚{dPct}%");
        if (bPct > 0) parts.Add($"早{bPct}%");
        if (oPct > 0) parts.Add($"其他{oPct}%");

        var ratioSummary = parts.Count > 0 ? string.Join(" · ", parts) : "暂无消费结构";
        var top2 = merchMap.OrderByDescending(kv => kv.Value).Take(2).Select(kv => kv.Key).ToList();
        var topText = top2.Count > 0 ? $"常去：{string.Join(" / ", top2)}" : "常去商户：--";

        return new ExpenseStructureBreakdownResult
        {
            BreakfastRMB = b,
            LunchRMB = l,
            DinnerRMB = d,
            OtherRMB = o,
            TopMerchantsText = topText,
            RatioSummaryText = ratioSummary
        };
    }

    public List<(string DateString, double SpentRMB)> DailyExpenseSummary(int days = 7, DateTime? now = null)
    {
        var today = (now ?? DateTime.Now).Date;
        var result = new List<(string, double)>();
        for (int i = days - 1; i >= 0; i--)
        {
            var d = today.AddDays(-i);
            var dStr = CourseCalendarHelper.DateString(d);
            var spent = Transactions.Where(t => t.DateOnlyString == dStr && t.IsExpense).Sum(t => t.AmountRMB);
            result.Add((dStr, Math.Round(spent, 2)));
        }
        return result;
    }
}

#endregion

#region 6. 自习空教室模型

public sealed class CampusBuildingOption
{
    public StudyCampus Campus { get; set; } = StudyCampus.Xuancheng;
    public string Code { get; set; } = string.Empty;
    public string Title { get => BuildingName; set => BuildingName = value; }
    public int CampusId { get => (int)Campus; set => Campus = (StudyCampus)value; }
    public string BuildingName { get; set; } = string.Empty;
    public int BuildingId { get; set; }

    public override string ToString() => BuildingName;
}

public sealed class RoomOccupationSlot
{
    public int PeriodStart { get; set; }
    public int PeriodEnd { get; set; }
    public int StartUnit { get => PeriodStart; set => PeriodStart = value; }
    public int EndUnit { get => PeriodEnd; set => PeriodEnd = value; }
    public string CourseName { get; set; } = string.Empty;
    public string Teacher { get; set; } = string.Empty;
    public string TimeString { get; set; } = string.Empty;
    public string CauseTitle { get; set; } = "课程占用";
    public string StartTimeString { get; set; } = "08:00";
    public string EndTimeString { get; set; } = "09:40";
    public int? ActivityId { get; set; }
    public string ActivityType { get; set; } = string.Empty;
    public string ActivityName { get; set; } = string.Empty;
    public bool IsLesson => ActivityType == "Lesson" || (string.IsNullOrEmpty(ActivityType) && CauseTitle == "课程占用");
    public string ShortCourseName => string.IsNullOrEmpty(CourseName) ? CauseTitle : CourseName;
}

public sealed record CurrentLessonMetrics(int LessonSessionCount, int OccupiedRoomCount)
{
    public static CurrentLessonMetrics Calculate(IEnumerable<ClassroomOccupationItem> rooms, int currentMinute)
    {
        var sessions = new HashSet<string>();
        var occupiedRoomIds = new HashSet<int>();
        foreach (var room in rooms)
        {
            var currentLessons = room.Occupations.Where(o => o.IsLesson && IsOngoing(o, currentMinute)).ToList();
            if (currentLessons.Count == 0) continue;
            occupiedRoomIds.Add(room.RoomId);
            foreach (var lesson in currentLessons) sessions.Add(SessionKey(room, lesson));
        }
        return new CurrentLessonMetrics(sessions.Count, occupiedRoomIds.Count);
    }

    internal static string SessionKey(ClassroomOccupationItem room, RoomOccupationSlot lesson)
    {
        if (lesson.ActivityId.HasValue)
            return $"{lesson.ActivityId.Value}|{room.DateString}|{Minute(lesson.StartTimeString)}|{Minute(lesson.EndTimeString)}";
        return $"{room.RoomId}|{room.DateString}|{Minute(lesson.StartTimeString)}|{Minute(lesson.EndTimeString)}|{lesson.ActivityName}|{lesson.Teacher}";
    }

    internal static bool IsOngoing(RoomOccupationSlot occupation, int minute)
    {
        var start = Minute(occupation.StartTimeString, 8 * 60);
        var end = Minute(occupation.EndTimeString, 21 * 60);
        return minute >= start && minute < end;
    }

    internal static int Minute(string value, int fallback = 0)
    {
        var parts = value.Split(':');
        return parts.Length >= 2 && int.TryParse(parts[0], out var hour) && int.TryParse(parts[1], out var minute)
            ? hour * 60 + minute
            : fallback;
    }
}

public enum DiningCrowdLevel { Low, Moderate, High }

public sealed record MealRushForecast(int LessonReleaseCount, int PeakThirtyMinuteCount, DiningCrowdLevel? CrowdLevel, int? CrowdPercentage = null)
{
    public string CrowdLabel
    {
        get
        {
            if (!CrowdPercentage.HasValue)
            {
                return CrowdLevel switch
                {
                    DiningCrowdLevel.Low => "空闲",
                    DiningCrowdLevel.Moderate => "适中",
                    DiningCrowdLevel.High => "挤",
                    _ => "资料不足"
                };
            }
            int pct = CrowdPercentage.Value;
            string desc = pct >= 90 ? "极挤" : pct >= 75 ? "挤" : pct >= 40 ? "适中" : "空闲";
            return $"{pct}%（{desc}）";
        }
    }
}

public sealed record DiningHallEstimate(
    string HallName,
    string ShortName,
    string AreaDescription,
    MealRushForecast Lunch,
    MealRushForecast Dinner
);

public sealed record CampusDiningEstimate(
    int CampusId,
    string DateString,
    bool IsComplete,
    MealRushForecast Lunch,
    MealRushForecast Dinner,
    IReadOnlyList<DiningHallEstimate>? HallEstimates = null
)
{
    private static readonly Dictionary<string, int> _observedPeaks = new();

    public record CampusZoneDefinition(
        string Id,
        string HallName,
        string ShortName,
        string AreaDescription,
        int BaselinePeak,
        Func<ClassroomOccupationItem, bool> Matches
    );

    public static IReadOnlyList<CampusZoneDefinition> ZoneDefinitions(int campusId)
    {
        return campusId switch
        {
            3 => new List<CampusZoneDefinition> // 翡翠湖校区
            {
                new("feicuihu_north", "风华食堂 (北区)", "风华食堂(北)", "翠一～四教、3#/4#实验楼等北侧教学楼", 65,
                    room => new[] { "翠一", "翠二", "翠三", "翠四", "3#", "4#", "4＃", "地质" }.Any(k => (room.BuildingPrefix ?? room.NameZh).Contains(k))),
                new("feicuihu_south", "风雅食堂 (南区)", "风雅食堂(南)", "翠五～十二教、科教楼、建艺馆等南侧教学楼", 80,
                    room => !new[] { "翠一", "翠二", "翠三", "翠四", "3#", "4#", "4＃", "地质" }.Any(k => (room.BuildingPrefix ?? room.NameZh).Contains(k)))
            },
            2 => new List<CampusZoneDefinition> // 屯溪路校区
            {
                new("tunxilu_east", "德胜食堂 (东区)", "德胜食堂(东)", "东楼、逸夫楼、电机楼、纬地楼、材料/理化楼等", 38,
                    room => new[] { "东", "逸夫", "电机", "纬地", "材料", "理化", "升华", "化工", "分析", "三立苑" }.Any(k => (room.BuildingPrefix ?? room.NameZh).Contains(k))),
                new("tunxilu_west", "馨园食堂 (西区)", "馨园食堂(西)", "主楼、西楼、西二、电教楼、管院楼、格物楼等", 52,
                    room => !new[] { "东", "逸夫", "电机", "纬地", "材料", "理化", "升华", "化工", "分析", "三立苑" }.Any(k => (room.BuildingPrefix ?? room.NameZh).Contains(k)))
            },
            6 => new List<CampusZoneDefinition> // 宣城校区
            {
                new("xuancheng_jingting", "敬亭学堂", "敬亭学堂", "敬亭学堂各教室内所有课程下课放学人流", 46,
                    room => (room.BuildingPrefix ?? room.NameZh).Contains("敬亭")),
                new("xuancheng_xinan", "新安学堂", "新安学堂", "新安学堂各教室内所有课程下课放学人流", 38,
                    room => !(room.BuildingPrefix ?? room.NameZh).Contains("敬亭"))
            },
            _ => Array.Empty<CampusZoneDefinition>()
        };
    }

    public static int BaselineSemesterPeak(int campusId)
    {
        return campusId switch
        {
            6 => 82,   // 宣城校区
            3 => 140,  // 翡翠湖校区
            2 => 88,   // 屯溪路校区
            _ => 100
        };
    }

    public static int SemesterPeak(string key, int baseline)
    {
        return _observedPeaks.TryGetValue(key, out var observed) ? Math.Max(baseline, observed) : baseline;
    }

    public static void RecordObservedPeak(int peak, string key, int baseline)
    {
        var current = SemesterPeak(key, baseline);
        if (peak > current)
        {
            _observedPeaks[key] = peak;
        }
    }

    public static int SemesterPeak(int campusId) => SemesterPeak($"campus_{campusId}", BaselineSemesterPeak(campusId));
    public static void RecordObservedPeak(int peak, int campusId) => RecordObservedPeak(peak, $"campus_{campusId}", BaselineSemesterPeak(campusId));

    public static CampusDiningEstimate Calculate(int campusId, string dateString, IEnumerable<ClassroomOccupationItem> sourceRooms, bool isComplete)
    {
        var rooms = sourceRooms.ToList();

        (MealRushForecast Lunch, MealRushForecast Dinner) CalculateForecast(IEnumerable<ClassroomOccupationItem> subset, string zoneKey, int baseline)
        {
            var lessons = subset.SelectMany(room => room.Occupations
                    .Where(occupation => occupation.IsLesson)
                    .Select(occupation => (Room: room, Occupation: occupation)))
                .GroupBy(item => CurrentLessonMetrics.SessionKey(item.Room, item.Occupation))
                .Select(group => group.First().Occupation)
                .ToList();
            var releases = lessons.Select(lesson => CurrentLessonMetrics.Minute(lesson.EndTimeString))
                .Where(minute => minute > 0)
                .ToList();

            MealRushForecast Forecast(int start, int end)
            {
                var mealReleases = releases.Where(minute => minute >= start && minute < end).ToList();
                var peak = PeakCount(mealReleases, start, end);
                if (!isComplete)
                {
                    return new MealRushForecast(mealReleases.Count, peak, null, null);
                }

                RecordObservedPeak(peak, zoneKey, baseline);
                var maxRush = SemesterPeak(zoneKey, baseline);
                int pct = 0;
                if (mealReleases.Count == 0 || peak == 0)
                {
                    pct = 0;
                }
                else if (maxRush > 0)
                {
                    pct = Math.Min(100, Math.Max(0, (int)Math.Round((double)peak / maxRush * 100.0)));
                }

                var level = pct >= 75 ? DiningCrowdLevel.High : pct >= 40 ? DiningCrowdLevel.Moderate : DiningCrowdLevel.Low;
                return new MealRushForecast(mealReleases.Count, peak, level, pct);
            }

            return (Forecast(11 * 60 + 30, 12 * 60 + 30), Forecast(17 * 60, 18 * 60 + 30));
        }

        var total = CalculateForecast(rooms, $"campus_{campusId}", BaselineSemesterPeak(campusId));
        var zones = ZoneDefinitions(campusId);
        var hallEstimates = new List<DiningHallEstimate>();
        foreach (var zone in zones)
        {
            var zoneRooms = rooms.Where(zone.Matches).ToList();
            var zf = CalculateForecast(zoneRooms, zone.Id, zone.BaselinePeak);
            hallEstimates.Add(new DiningHallEstimate(zone.HallName, zone.ShortName, zone.AreaDescription, zf.Lunch, zf.Dinner));
        }

        return new CampusDiningEstimate(campusId, dateString, isComplete, total.Lunch, total.Dinner, hallEstimates);
    }

    private static int PeakCount(IReadOnlyCollection<int> releases, int start, int end)
    {
        if (end - start < 30) return releases.Count;
        var peak = 0;
        for (var windowStart = start; windowStart <= end - 30; windowStart++)
        {
            var count = releases.Count(minute => minute >= windowStart && minute < windowStart + 30);
            if (count > peak) peak = count;
        }
        return peak;
    }
}

public sealed class StudyRoomStatusInfo
{
    public string SubLabel { get; set; } = "全天自习空闲";
    public bool ShouldRecommendSwitch { get; set; }
    public RoomOccupationSlot? OccupiedPeriod { get; set; }
}

public sealed class ClassroomNearbyRecommendation
{
    public ClassroomOccupationItem Room { get; set; } = new();
    public ClassroomProximity Proximity { get; set; } = new();
}

public sealed class ClassroomProximity
{
    public string BadgeText { get; set; } = "同楼层";
}

public sealed class ClassroomOccupationItem
{
    private int _floor = 0;

    public int RoomId { get; set; }
    public int Id { get => RoomId; set => RoomId = value; }
    public string RoomName { get; set; } = string.Empty;
    public string NameZh { get => RoomName; set => RoomName = value; }
    public int CampusId { get; set; }
    public string CampusName => CampusId switch
    {
        6 => "宣城校区",
        3 => "翡翠湖校区",
        2 => "屯溪路校区",
        _ => "合肥工业大学"
    };
    public string BuildingName { get; set; } = string.Empty;
    public string Building { get => BuildingName; set => BuildingName = value; }
    public string BuildingCode { get; set; } = string.Empty;

    public int Floor
    {
        get => InferredFloor;
        set => _floor = value;
    }

    public int InferredFloor
    {
        get
        {
            var meta = ExtractMetadata(RoomName, RoomId, _floor > 0 ? _floor : null);
            return meta.Floor;
        }
    }

    public string CleanBuildingName
    {
        get
        {
            if (RoomName.Contains("新安学堂")) return "新安学堂";
            if (RoomName.Contains("敬亭学堂")) return "敬亭学堂";

            // 翡翠湖
            string[] fcPref = { "翠一教", "翠二教", "翠三教", "翠四教", "翠五教", "翠六教", "翠七教", "翠八教", "翠九教", "翠十教", "翠十一教", "翠十二教", "翡翠科教楼" };
            foreach (var b in fcPref)
            {
                if (RoomName.Contains(b)) return b;
            }

            // 屯溪路
            string[] txPref = { "东楼", "西楼", "主楼", "西二", "逸夫楼" };
            foreach (var b in txPref)
            {
                if (RoomName.Contains(b)) return b;
            }

            if (!string.IsNullOrWhiteSpace(BuildingName) && BuildingName != "教学楼" && !BuildingName.Any(char.IsDigit))
            {
                return BuildingName;
            }

            var meta = ExtractMetadata(RoomName, RoomId, null);
            if (!string.IsNullOrWhiteSpace(meta.Prefix))
            {
                return meta.Prefix;
            }

            return !string.IsNullOrWhiteSpace(BuildingName) ? BuildingName : "教学楼";
        }
    }

    public static (int RoomNum, int Floor, string Prefix, string ShortCode) ExtractMetadata(string nameZh, int fallbackId, int? rawFloor)
    {
        if (string.IsNullOrWhiteSpace(nameZh))
            return (fallbackId, rawFloor is > 0 ? rawFloor.Value : 1, "", "");

        var match = System.Text.RegularExpressions.Regex.Match(nameZh, @"(?:(?<prefix>.*?)\s*(?:[(（])?)?(?<num>\d{3,4})(?:[)）])?(?<suffix>[A-Za-z]?)");
        if (match.Success && int.TryParse(match.Groups["num"].Value, out int rNum))
        {
            int f = (rNum >= 100 && rNum <= 1999) ? (rNum / 100) : (rawFloor is > 0 ? rawFloor.Value : 1);
            string p = match.Groups["prefix"].Value.Trim();
            string s = match.Groups["num"].Value + match.Groups["suffix"].Value;
            if (string.IsNullOrEmpty(p)) p = nameZh;
            return (rNum, f, p, s);
        }

        int inferred = rawFloor is > 0 ? rawFloor.Value : 1;
        return (fallbackId, inferred, nameZh, nameZh);
    }

    public int Seats { get; set; }
    public int? SeatsForSection { get => Seats > 0 ? Seats : null; set => Seats = value ?? 0; }
    public string DateString { get; set; } = string.Empty;
    public List<RoomOccupationSlot> Occupations { get; set; } = new();

    public string SimplifiedRoomName => RoomName;
    public bool IsAllDayFree => Occupations.Count == 0;

    public bool IsOccupiedAtPeriod(int period)
    {
        return Occupations.Any(o => period >= o.PeriodStart && period <= o.PeriodEnd);
    }

    public RoomOccupationSlot? CurrentOccupation(int currentMinute)
    {
        return Occupations.FirstOrDefault(o =>
        {
            var s = ParseMinute(o.StartTimeString, 8 * 60);
            var e = ParseMinute(o.EndTimeString, 21 * 60);
            return currentMinute >= s && currentMinute < e;
        });
    }

    public RoomOccupationSlot? NextOccupation(int currentMinute)
    {
        return Occupations.FirstOrDefault(o => ParseMinute(o.StartTimeString, 8 * 60) > currentMinute);
    }

    public int? MinutesUntilNextOccupation(int currentMinute)
    {
        var next = NextOccupation(currentMinute);
        return next != null ? Math.Max(0, ParseMinute(next.StartTimeString, 8 * 60) - currentMinute) : null;
    }

    public StudyRoomStatusInfo StudyStatus(int currentMinute)
    {
        var cur = CurrentOccupation(currentMinute);
        if (cur != null)
        {
            return new StudyRoomStatusInfo
            {
                SubLabel = $"当前{cur.CauseTitle}中至 {cur.EndTimeString}",
                ShouldRecommendSwitch = true,
                OccupiedPeriod = cur
            };
        }
        var next = NextOccupation(currentMinute);
        if (next != null)
        {
            int diff = Math.Max(0, ParseMinute(next.StartTimeString, 8 * 60) - currentMinute);
            return new StudyRoomStatusInfo
            {
                SubLabel = $"空闲至 {next.StartTimeString} (约余 {diff} 分钟)",
                ShouldRecommendSwitch = diff <= 35,
                OccupiedPeriod = diff <= 35 ? next : null
            };
        }
        return new StudyRoomStatusInfo
        {
            SubLabel = "全天自习空闲",
            ShouldRecommendSwitch = false,
            OccupiedPeriod = null
        };
    }

    private static int ParseMinute(string timeStr, int fallback)
    {
        var parts = timeStr.Split(':');
        if (parts.Length == 2 && int.TryParse(parts[0], out int h) && int.TryParse(parts[1], out int m))
            return h * 60 + m;
        return fallback;
    }
}

public sealed class StudyRoomSelectionRecord
{
    public int RoomId { get; set; }
    public string RoomName { get; set; } = string.Empty;
    public string NameZh { get => RoomName; set => RoomName = value; }
    public int CampusId { get; set; }
    public string BuildingName { get; set; } = string.Empty;
    public string BuildingCode { get; set; } = string.Empty;
    public string DateString { get; set; } = string.Empty;

    public ClassroomOccupationItem? LiveRoom
    {
        get
        {
            var today = EmptyClassroomService.TodayDateString();
            var matchingRooms = EmptyClassroomService.Shared.CachedRooms
                .Where(r => r.RoomId == RoomId)
                .ToList();
            if (CampusId != 0)
            {
                matchingRooms = matchingRooms.Where(r => r.CampusId == CampusId).ToList();
            }
            else if (matchingRooms.Select(r => r.CampusId).Distinct().Count() > 1)
            {
                return null;
            }

            return matchingRooms.FirstOrDefault(r => r.DateString == today || r.DateString == DateString)
                ?? matchingRooms.FirstOrDefault();
        }
    }

    public RoomOccupationSlot? CurrentOccupation(int minute) => LiveRoom?.CurrentOccupation(minute);
    public RoomOccupationSlot? NextOccupation(int minute) => LiveRoom?.NextOccupation(minute);
    public int? MinutesUntilNextOccupation(int minute) => LiveRoom?.MinutesUntilNextOccupation(minute);
    public StudyRoomStatusInfo StudyStatus(int minute) => LiveRoom?.StudyStatus(minute) ?? new StudyRoomStatusInfo();
}

public sealed class EmptyClassroomSnapshot
{
    public int CampusId { get; set; }
    public string DateString { get; set; } = string.Empty;
    public DateTime LastSyncTime { get; set; } = DateTime.Now;
    public List<ClassroomOccupationItem> Rooms { get; set; } = new();
}

public sealed class TomorrowStudyRecommendation
{
    public string Reason { get; set; } = "全天自习空闲教室";
    public List<ClassroomOccupationItem> RecommendedRooms { get; set; } = new();
    public string TargetBuildingCode { get; set; } = string.Empty;
    public string TargetBuildingName { get; set; } = string.Empty;
    public string DateString { get; set; } = string.Empty;
}

public sealed class PeriodTimeSlot
{
    public int PeriodIndex { get; set; } // 1..11
    public string StartTime { get; set; } = string.Empty;
    public string EndTime { get; set; } = string.Empty;
    public string Label => $"第{PeriodIndex}节 ({StartTime}-{EndTime})";
}

public static class PeriodScheduleHelper
{
    public static readonly List<PeriodTimeSlot> DefaultSlots = new()
    {
        new PeriodTimeSlot { PeriodIndex = 1, StartTime = "08:00", EndTime = "08:45" },
        new PeriodTimeSlot { PeriodIndex = 2, StartTime = "08:55", EndTime = "09:40" },
        new PeriodTimeSlot { PeriodIndex = 3, StartTime = "10:00", EndTime = "10:45" },
        new PeriodTimeSlot { PeriodIndex = 4, StartTime = "10：55", EndTime = "11:40" },
        new PeriodTimeSlot { PeriodIndex = 5, StartTime = "14:00", EndTime = "14:45" },
        new PeriodTimeSlot { PeriodIndex = 6, StartTime = "14:55", EndTime = "15:40" },
        new PeriodTimeSlot { PeriodIndex = 7, StartTime = "15：50", EndTime = "16:35" },
        new PeriodTimeSlot { PeriodIndex = 8, StartTime = "16:45", EndTime = "17:30" },
        new PeriodTimeSlot { PeriodIndex = 9, StartTime = "19:20", EndTime = "20：05" },
        new PeriodTimeSlot { PeriodIndex = 10, StartTime = "20：15", EndTime = "21：00" },
        new PeriodTimeSlot { PeriodIndex = 11, StartTime = "21：10", EndTime = "21:55" }
    };
}

#endregion

#region 7. 历史统计持久化模型与校区枚举

public enum StudyCampus
{
    Xuancheng = 6,
    Feicuihu = 3,
    Tunxilu = 2
}

public static class StudyCampusExtensions
{
    public static readonly StudyCampus[] AllCases = new[] { StudyCampus.Xuancheng, StudyCampus.Feicuihu, StudyCampus.Tunxilu };

    public static string Title(this StudyCampus campus) => campus switch
    {
        StudyCampus.Feicuihu => "翡翠湖校区",
        StudyCampus.Tunxilu => "屯溪路校区",
        StudyCampus.Xuancheng => "宣城校区",
        _ => "宣城校区"
    };
}

public sealed class FlowDailyRecord
{
    public string DateString { get; set; } = string.Empty;
    public double StartUsedMB { get; set; }
    public double LatestUsedMB { get; set; }
    public double TotalUsedMB => LatestUsedMB;
    public double DeltaMB => Math.Max(0.0, LatestUsedMB - StartUsedMB);
    public double TodayUsedMB => DeltaMB;
    public double DailyDeltaMB => DeltaMB;
    public string FormattedDailyDelta => DeltaMB >= 1024 ? $"{DeltaMB / 1024.0:F2} GB" : $"{DeltaMB:F0} MB";
    public double? BalanceRMB { get; set; }
    public DateTime LastUpdated { get; set; } = DateTime.Now;
}

public sealed class ElectricityDailyRecord
{
    public string DateString { get; set; } = string.Empty;
    public double StartBalanceRMB { get; set; }
    public double LatestBalanceRMB { get; set; }
    public double BalanceRMB => LatestBalanceRMB;
    public double? RemainingKWh { get; set; }
    public double CostRMB => Math.Max(0.0, StartBalanceRMB - LatestBalanceRMB);
    public double DailyCostRMB => CostRMB;
    public string FormattedDailyCost => $"{CostRMB:F2} 元";
    public string FormattedDailyKWh => RemainingKWh.HasValue ? $"{RemainingKWh.Value:F1} 度" : "--";
    public DateTime LastUpdated { get; set; } = DateTime.Now;
}

public sealed class GitHubReleaseInfo
{
    public string TagName { get; set; } = string.Empty;
    public string Version { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Body { get; set; } = string.Empty;
    public string HtmlUrl { get; set; } = string.Empty;
    public string? DownloadUrl { get; set; }
}

#endregion
