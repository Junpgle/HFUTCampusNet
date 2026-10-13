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
}

public sealed class CourseScheduleData
{
    public string StudentId { get; set; } = string.Empty;
    public string SemesterId { get; set; } = "354";
    public string? SemesterName { get; set; }
    public string BizTypeId { get; set; } = "23";
    public DateTime? LastSyncTime { get; set; }
    public List<CourseLesson> Lessons { get; set; } = new();

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
    public DateTime? EndDate => CourseCalendarHelper.ParseDate(DateString, EndTimeString);

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

    public bool Passed => ScoreText != "不及格" && ScoreText != "F" && ScoreText != "NP" && (NumericScore == null || NumericScore.Value >= 60);

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
        var sid = semId ?? int.Parse(schedule?.SemesterId ?? "354");
        var now = (date ?? DateTime.Now).Date;

        // 合工大校历官方起止日期表 (学期ID -> (开始日期, 结束日期, 总周数))
        var dates = new Dictionary<int, (string Start, string End, int Weeks, string Vacation)>
        {
            [354] = ("2026-08-31", "2027-01-17", 20, "寒假"),
            [334] = ("2026-02-23", "2026-07-12", 20, "暑假"),
            [314] = ("2025-09-01", "2026-01-18", 20, "寒假"),
            [294] = ("2025-02-24", "2025-07-13", 20, "暑假"),
            [274] = ("2024-09-02", "2025-01-19", 20, "寒假"),
        };

        var config = dates.TryGetValue(sid, out var tuple) ? tuple : ("2026-08-31", "2027-01-17", 20, "寒假");
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
    public string MerchantName { get; set; } = string.Empty;
    public string TxType { get; set; } = string.Empty;
    public double AmountRMB { get; set; }
    public double BalanceAfterRMB { get; set; }
    public bool IsExpense { get; set; } = true;

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
            if (!IsExpense) return "充值转账";
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
        return Transactions.Where(t => t.MonthPrefixString == prefix && !t.IsExpense).Sum(t => t.AmountRMB);
    }

    public (double Breakfast, double Lunch, double Dinner, double Other, string TopMerchants, string RatioSummary) ExpenseStructureBreakdown()
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

        return (b, l, d, o, topText, ratioSummary);
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
    public int CampusId { get; set; }
    public string BuildingName { get; set; } = string.Empty;
    public int BuildingId { get; set; }

    public override string ToString() => BuildingName;
}

public sealed class RoomOccupationSlot
{
    public int PeriodStart { get; set; }
    public int PeriodEnd { get; set; }
    public string CourseName { get; set; } = string.Empty;
    public string Teacher { get; set; } = string.Empty;
    public string TimeString { get; set; } = string.Empty;
}

public sealed class ClassroomOccupationItem
{
    public int RoomId { get; set; }
    public string RoomName { get; set; } = string.Empty;
    public int CampusId { get; set; }
    public string BuildingName { get; set; } = string.Empty;
    public int Seats { get; set; }
    public string DateString { get; set; } = string.Empty;
    public List<RoomOccupationSlot> Occupations { get; set; } = new();

    public bool IsAllDayFree => Occupations.Count == 0;

    public bool IsOccupiedAtPeriod(int period)
    {
        return Occupations.Any(o => period >= o.PeriodStart && period <= o.PeriodEnd);
    }
}

public sealed class StudyRoomSelectionRecord
{
    public int RoomId { get; set; }
    public string RoomName { get; set; } = string.Empty;
    public int CampusId { get; set; }
    public string BuildingName { get; set; } = string.Empty;
    public string DateString { get; set; } = string.Empty;
}

public sealed class EmptyClassroomSnapshot
{
    public int CampusId { get; set; }
    public string DateString { get; set; } = string.Empty;
    public DateTime LastSyncTime { get; set; } = DateTime.Now;
    public List<ClassroomOccupationItem> Rooms { get; set; } = new();
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
        new PeriodTimeSlot { PeriodIndex = 3, StartTime = "10:10", EndTime = "10:55" },
        new PeriodTimeSlot { PeriodIndex = 4, StartTime = "11:05", EndTime = "11:50" },
        new PeriodTimeSlot { PeriodIndex = 5, StartTime = "14:00", EndTime = "14:45" },
        new PeriodTimeSlot { PeriodIndex = 6, StartTime = "14:55", EndTime = "15:40" },
        new PeriodTimeSlot { PeriodIndex = 7, StartTime = "16:00", EndTime = "16:45" },
        new PeriodTimeSlot { PeriodIndex = 8, StartTime = "16:55", EndTime = "17:40" },
        new PeriodTimeSlot { PeriodIndex = 9, StartTime = "19:00", EndTime = "19:45" },
        new PeriodTimeSlot { PeriodIndex = 10, StartTime = "19:55", EndTime = "20:40" },
        new PeriodTimeSlot { PeriodIndex = 11, StartTime = "20:50", EndTime = "21:35" }
    };
}

#endregion

#region 7. 历史统计持久化模型

public sealed class FlowDailyRecord
{
    public string DateString { get; set; } = string.Empty;
    public double StartUsedMB { get; set; }
    public double LatestUsedMB { get; set; }
    public double DeltaMB => Math.Max(0.0, LatestUsedMB - StartUsedMB);
    public DateTime LastUpdated { get; set; } = DateTime.Now;
}

public sealed class ElectricityDailyRecord
{
    public string DateString { get; set; } = string.Empty;
    public double StartBalanceRMB { get; set; }
    public double LatestBalanceRMB { get; set; }
    public double? RemainingKWh { get; set; }
    public double CostRMB => Math.Max(0.0, StartBalanceRMB - LatestBalanceRMB);
    public DateTime LastUpdated { get; set; } = DateTime.Now;
}

#endregion
