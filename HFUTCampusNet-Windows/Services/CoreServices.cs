using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Win32;

namespace HFUTCampusNet;

#region 1. 全局应用事件总线 AppEvents

public static class AppEvents
{
    public static event Action? NetworkDataUpdated;
    public static event Action<string, string, string>? SpeedUpdated; // downloadStr, uploadStr, compactStr
    public static event Action? CourseScheduleUpdated;
    public static event Action? EmptyClassroomUpdated;
    public static event Action? DormElectricityUpdated;
    public static event Action? HistoryStatsUpdated;
    public static event Action? CampusCardUpdated;
    public static event Action? AcademicDataUpdated;
    public static event Action? UpdateCheckFinished;
    public static event Action? AuthStatusUpdated;

    public static void RaiseNetworkDataUpdated() => NetworkDataUpdated?.Invoke();
    public static void RaiseSpeedUpdated(string d, string u, string c) => SpeedUpdated?.Invoke(d, u, c);
    public static void RaiseCourseScheduleUpdated() => CourseScheduleUpdated?.Invoke();
    public static void RaiseEmptyClassroomUpdated() => EmptyClassroomUpdated?.Invoke();
    public static void RaiseDormElectricityUpdated() => DormElectricityUpdated?.Invoke();
    public static void RaiseHistoryStatsUpdated() => HistoryStatsUpdated?.Invoke();
    public static void RaiseCampusCardUpdated() => CampusCardUpdated?.Invoke();
    public static void RaiseAcademicDataUpdated() => AcademicDataUpdated?.Invoke();
    public static void RaiseUpdateCheckFinished() => UpdateCheckFinished?.Invoke();
    public static void RaiseAuthStatusUpdated() => AuthStatusUpdated?.Invoke();

    public static void InvokeOnUI(Action action)
    {
        if (Application.Current != null && !Application.Current.Dispatcher.CheckAccess())
        {
            Application.Current.Dispatcher.BeginInvoke(action);
        }
        else
        {
            action();
        }
    }
}

#endregion

#region 2. 设置管理器 SettingsManager

public sealed class SettingsManager
{
    private static SettingsManager? _shared;
    public static SettingsManager Shared => _shared ??= Load();

    private static readonly string AppDataFolder = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "HFUTCampusNet");
    private static readonly string SettingsFile = Path.Combine(AppDataFolder, "settings.json");
    private static readonly object SaveLock = new();
    private static bool _settingsBackupRequired;

    // 配置字段
    public string? SessionCookie { get; set; }
    public double RefreshInterval { get; set; } = 300.0;
    public bool ShowDesktopWidget { get; set; } = true;
    public bool WidgetPinToDesktop { get; set; } = true;
    public double WidgetOpacity { get; set; } = 0.92;
    public double? WidgetX { get; set; }
    public double? WidgetY { get; set; }
    public int MenubarStyle { get; set; } = 0; // 0: 智能轮播, 1: 仅流量余额, 2: 仅网速, 3: 并排
    public double CarouselInterval { get; set; } = 3.5;

    public string PortalUsername { get; set; } = string.Empty;
    public string PortalPassword { get; set; } = string.Empty;
    public string CasPassword { get; set; } = string.Empty;
    public bool AutoLoginPortal { get; set; } = true;

    public string CourseStudentId { get; set; } = string.Empty;
    public string CourseSemesterId { get; set; } = "354";
    public bool CourseSemesterIdManuallySelected { get; set; }
    public string CourseBizTypeId { get; set; } = "23";
    public string? CourseSessionCookie { get; set; }
    public bool CourseTableEnabled { get; set; } = true;
    public bool CourseShowOnWidget { get; set; } = true;

    public string? HuixinAuthToken { get; set; }
    public string? CasTgcCookie { get; set; }
    public string? UniAppJwt { get; set; }
    public string? JxglstuDefaultPasswordCache { get; set; }
    public string CasUsername => PortalUsername;

    public string DormCampus { get; set; } = "宣城校区";
    public string DormBuilding { get; set; } = string.Empty;
    public string DormRoom { get; set; } = string.Empty;
    public string DormEndNumber { get; set; } = "11";
    public string DormRoomName { get; set; } = string.Empty;
    public double ElectricityLowWarningThreshold { get; set; } = 10.0;
    public string LastNotifiedLowElectricityDate { get; set; } = string.Empty;

    public double CampusCardLowWarningThreshold { get; set; } = 15.0;
    public string LastNotifiedLowCardBalanceDate { get; set; } = string.Empty;
    public double CampusCardDailyBudget { get; set; } = 30.0;

    public bool HideScoreInNotification { get; set; } = false;
    public bool AutoCheckUpdate { get; set; } = true;

    public StudyRoomSelectionRecord? CurrentStudyRoom { get; set; }
    public StudyRoomSelectionRecord? NextDayStudyRoom { get; set; }

    public HashSet<string> NotifiedGradeIds { get; set; } = new();
    public HashSet<string> UnreadGradeIds { get; set; } = new();

    public bool IsDormConfigured => !string.IsNullOrWhiteSpace(DormBuilding) && !string.IsNullOrWhiteSpace(DormRoom);

    public bool AutoStartOnBoot
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", false);
                return key?.GetValue("HFUTCampusNet") != null;
            }
            catch { return false; }
        }
        set
        {
            try
            {
                const string runKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
                using var key = value
                    ? Registry.CurrentUser.CreateSubKey(runKeyPath)
                    : Registry.CurrentUser.OpenSubKey(runKeyPath, true);
                if (key == null) return;
                if (value)
                {
                    var exePath = Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule?.FileName;
                    if (!string.IsNullOrEmpty(exePath))
                    {
                        key.SetValue("HFUTCampusNet", $"\"{exePath}\"");
                    }
                }
                else
                {
                    key.DeleteValue("HFUTCampusNet", false);
                }
            }
            catch { }
        }
    }

    public void Save()
    {
        lock (SaveLock)
        {
            var temporaryFile = SettingsFile + ".tmp";
            try
            {
                if (_settingsBackupRequired)
                {
                    if (!TryBackupUnreadableSettings()) return;
                    _settingsBackupRequired = false;
                }

                Directory.CreateDirectory(AppDataFolder);
                var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(temporaryFile, json, Encoding.UTF8);
                File.Move(temporaryFile, SettingsFile, overwrite: true);
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[SettingsManager] Save failed: {ex.Message}");
                try
                {
                    if (File.Exists(temporaryFile)) File.Delete(temporaryFile);
                }
                catch { }
            }
        }
    }

    private static SettingsManager Load()
    {
        if (!File.Exists(SettingsFile)) return new SettingsManager();

        try
        {
            var json = File.ReadAllText(SettingsFile, Encoding.UTF8);
            var obj = JsonSerializer.Deserialize<SettingsManager>(json);
            if (obj == null) throw new JsonException("Settings file does not contain a JSON object.");
            obj.NotifiedGradeIds ??= new();
            obj.UnreadGradeIds ??= new();
            return obj;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[SettingsManager] Load failed: {ex.Message}");
            _settingsBackupRequired = !TryBackupUnreadableSettings();
        }
        return new SettingsManager();
    }

    private static bool TryBackupUnreadableSettings()
    {
        if (!File.Exists(SettingsFile)) return true;

        var backupFile = SettingsFile + $".load-failure-{DateTime.UtcNow:yyyyMMddHHmmssfff}-{Guid.NewGuid():N}.bak";
        try
        {
            File.Copy(SettingsFile, backupFile, overwrite: false);
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[SettingsManager] Could not preserve unreadable settings: {ex.Message}");
            return false;
        }
    }
}

#endregion

#region 3. 历史统计管理器 CampusHistoryManager

public sealed class CampusHistoryManager
{
    public static CampusHistoryManager Shared { get; } = new();
    private const int FlowAccountingVersion = 2;
    private const int FlowHistoryPartitionVersion = 1;
    private const int FlowHistoryContinuityVersion = 1;

    private readonly string _historyFile;
    private readonly object _lock = new();
    private Dictionary<string, List<ElectricityDailyRecord>> _archivedElectricityRecords = new(StringComparer.Ordinal);
    private Dictionary<string, List<FlowDailyRecord>> _archivedFlowRecords = new(StringComparer.Ordinal);
    private string _activeElectricityDormKey = string.Empty;
    private string _activeFlowAccountKey = string.Empty;
    private bool _historyBackupRequired;
    private bool _electricityPartitionBackupRequired;
    private bool _flowAccountPartitionBackupRequired;
    private bool _flowAccountingMigrationBackupRequired;
    private bool _flowContinuityMigrationBackupRequired;

    public List<FlowDailyRecord> FlowRecords { get; private set; } = new();
    public List<ElectricityDailyRecord> ElectricityRecords { get; private set; } = new();

    private CampusHistoryManager()
    {
        var appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "HFUTCampusNet");
        Directory.CreateDirectory(appData);
        _historyFile = Path.Combine(appData, "campus_history_stats.json");
        Load();
    }

    public double TodayFlowDeltaMB
    {
        get
        {
            lock (_lock)
            {
                var today = CourseCalendarHelper.DateString(CourseCalendarHelper.BeijingNow);
                return FlowRecords.FirstOrDefault(r => r.DateString == today)?.DeltaMB ?? 0.0;
            }
        }
    }

    public double Past7DaysFlowTotalMB
    {
        get
        {
            lock (_lock)
            {
                var now = CourseCalendarHelper.BeijingNow;
                var today = CourseCalendarHelper.DateString(now);
                var cutoff = now.Date.AddDays(-6).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                return FlowRecords.Where(r =>
                    string.CompareOrdinal(r.DateString, cutoff) >= 0 &&
                    string.CompareOrdinal(r.DateString, today) <= 0).Sum(r => r.DeltaMB);
            }
        }
    }

    public double Past7DaysFlowDailyAverageMB
    {
        get
        {
            lock (_lock)
            {
                var now = CourseCalendarHelper.BeijingNow;
                var today = CourseCalendarHelper.DateString(now);
                var cutoff = now.Date.AddDays(-6).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                var records = FlowRecords.Where(r =>
                    string.CompareOrdinal(r.DateString, cutoff) >= 0 &&
                    string.CompareOrdinal(r.DateString, today) <= 0).ToList();
                return records.Count > 0 ? records.Average(r => r.DeltaMB) : 0.0;
            }
        }
    }

    public double TodayElectricityCostRMB
    {
        get
        {
            lock (_lock)
            {
                var today = CourseCalendarHelper.DateString(CourseCalendarHelper.BeijingNow);
                return ElectricityRecords.FirstOrDefault(r => r.DateString == today)?.CostRMB ?? 0.0;
            }
        }
    }

    public double TodayElectricityUsedKWh => Math.Round(TodayElectricityCostRMB / 0.58, 1);

    public double Past7DaysElectricityDailyAverageRMB
    {
        get
        {
            lock (_lock)
            {
                var now = CourseCalendarHelper.BeijingNow;
                var today = CourseCalendarHelper.DateString(now);
                var cutoff = now.Date.AddDays(-6).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                var records = ElectricityRecords.Where(r =>
                    string.CompareOrdinal(r.DateString, cutoff) >= 0 &&
                    string.CompareOrdinal(r.DateString, today) <= 0 &&
                    r.CostRMB > 0).ToList();
                return records.Count > 0 ? records.Average(r => r.CostRMB) : 0.0;
            }
        }
    }

    public double Past7DaysElectricityDailyAverageCostRMB => Past7DaysElectricityDailyAverageRMB;
    public double CurrentMonthUsedFlowMB
    {
        get
        {
            lock (_lock)
            {
                var today = CourseCalendarHelper.DateString(CourseCalendarHelper.BeijingNow);
                var prefix = today.Substring(0, 7);
                // LatestUsedMB is the portal's month-to-date cumulative counter. Summing
                // daily deltas loses usage before the first sample when monitoring starts mid-month.
                return FlowRecords
                    .Where(r => r.DateString.StartsWith(prefix, StringComparison.Ordinal) &&
                        string.CompareOrdinal(r.DateString, today) <= 0)
                    .OrderByDescending(r => r.DateString)
                    .FirstOrDefault()?.LatestUsedMB ?? 0.0;
            }
        }
    }
    public string DailyResetCountdownString
    {
        get
        {
            var now = CourseCalendarHelper.BeijingNow;
            var endOfDay = now.Date.AddDays(1);
            var diff = endOfDay - now;
            return $"距重置 {(int)diff.TotalHours}时{diff.Minutes}分";
        }
    }
    public string MonthlyResetCountdownString
    {
        get
        {
            var now = CourseCalendarHelper.BeijingNow;
            var firstOfNextMonth = new DateTime(now.Year, now.Month, 1).AddMonths(1);
            var days = (firstOfNextMonth - now.Date).Days;
            return $"距重置 {days} 天";
        }
    }
    public double? LatestFlowBalanceRMB
    {
        get
        {
            lock (_lock)
            {
                var today = CourseCalendarHelper.DateString(CourseCalendarHelper.BeijingNow);
                return FlowRecords
                    .Where(r => string.CompareOrdinal(r.DateString, today) <= 0)
                    .OrderBy(r => r.DateString)
                    .LastOrDefault()?.BalanceRMB;
            }
        }
    }

    public int? EstimatedElectricityDaysRemaining
    {
        get
        {
            lock (_lock)
            {
                var today = CourseCalendarHelper.DateString(CourseCalendarHelper.BeijingNow);
                var latest = ElectricityRecords
                    .Where(r => string.CompareOrdinal(r.DateString, today) <= 0)
                    .OrderByDescending(r => r.DateString)
                    .FirstOrDefault();
                if (latest == null || latest.LatestBalanceRMB <= 0) return null;
                var avg = Past7DaysElectricityDailyAverageRMB;
                if (avg <= 0.001) return null;
                return (int)Math.Max(1, Math.Floor(latest.LatestBalanceRMB / avg));
            }
        }
    }

    public ElectricityDailyRecord? LatestElectricityRecord
    {
        get
        {
            lock (_lock)
            {
                var today = CourseCalendarHelper.DateString(CourseCalendarHelper.BeijingNow);
                return ElectricityRecords
                    .Where(r => string.CompareOrdinal(r.DateString, today) <= 0)
                    .OrderByDescending(r => r.DateString)
                    .FirstOrDefault();
            }
        }
    }

    public List<FlowDailyRecord> GetPastDaysFlowRecords(int days = 7)
    {
        lock (_lock)
        {
            var now = CourseCalendarHelper.BeijingNow;
            var today = CourseCalendarHelper.DateString(now);
            var cutoff = now.Date.AddDays(-(Math.Max(1, days) - 1)).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            return FlowRecords.Where(r =>
                    string.CompareOrdinal(r.DateString, cutoff) >= 0 &&
                    string.CompareOrdinal(r.DateString, today) <= 0)
                .OrderBy(r => r.DateString)
                .ToList();
        }
    }

    public List<ElectricityDailyRecord> GetPastDaysElectricityRecords(int days = 7)
    {
        lock (_lock)
        {
            var now = CourseCalendarHelper.BeijingNow;
            var today = CourseCalendarHelper.DateString(now);
            var cutoff = now.Date.AddDays(-(Math.Max(1, days) - 1)).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            return ElectricityRecords.Where(r =>
                    string.CompareOrdinal(r.DateString, cutoff) >= 0 &&
                    string.CompareOrdinal(r.DateString, today) <= 0)
                .OrderBy(r => r.DateString)
                .ToList();
        }
    }

    public void RecordFlow(double usedMB, double? balanceRMB = null, DateTime? observedAt = null)
    {
        if (!double.IsFinite(usedMB) || usedMB < 0) return;

        lock (_lock)
        {
            var sampleTime = observedAt ?? CourseCalendarHelper.BeijingNow;
            var today = CourseCalendarHelper.DateString(sampleTime);
            var currentDay = CourseCalendarHelper.DateString(CourseCalendarHelper.BeijingNow);
            if (!today.StartsWith(currentDay[..7], StringComparison.Ordinal)) return;

            if (!CompleteFlowAccountingMigrationIfNeeded()) return;
            var validBalanceRMB = balanceRMB.HasValue &&
                double.IsFinite(balanceRMB.Value) && balanceRMB.Value >= 0
                ? balanceRMB
                : null;
            var monthPrefix = today[..7];
            // 网关流量是本月累计值；用同月最近一次采样衔接当天，避免跨日后首次刷新漏算。
            var previousRecord = FlowRecords
                .Where(r => string.CompareOrdinal(r.DateString, today) < 0 &&
                    r.DateString.StartsWith(monthPrefix, StringComparison.Ordinal))
                .OrderBy(r => r.DateString)
                .LastOrDefault();
            var record = FlowRecords.FirstOrDefault(r => r.DateString == today);
            var isMonthlyReset = record != null && today.EndsWith("-01", StringComparison.Ordinal) &&
                usedMB < record.LatestUsedMB * 0.5;
            var effectiveUsedMB = isMonthlyReset
                ? usedMB
                : Math.Max(usedMB, Math.Max(record?.LatestUsedMB ?? 0.0, previousRecord?.LatestUsedMB ?? 0.0));
            if (record == null)
            {
                var startUsedMB = effectiveUsedMB;
                if (previousRecord == null)
                {
                    if (today.EndsWith("-01", StringComparison.Ordinal)) startUsedMB = 0.0;
                }
                else if (effectiveUsedMB >= previousRecord.LatestUsedMB)
                {
                    startUsedMB = previousRecord.LatestUsedMB;
                }
                record = new FlowDailyRecord
                {
                    DateString = today,
                    StartUsedMB = startUsedMB,
                    LatestUsedMB = effectiveUsedMB,
                    BalanceRMB = validBalanceRMB,
                    LastUpdated = DateTime.Now
                };
                FlowRecords.Add(record);
            }
            else
            {
                if (isMonthlyReset || (previousRecord == null && today.EndsWith("-01", StringComparison.Ordinal)))
                    record.StartUsedMB = 0.0;
                else if (previousRecord != null)
                {
                    record.StartUsedMB = previousRecord.LatestUsedMB;
                }
                record.LatestUsedMB = effectiveUsedMB;
                if (validBalanceRMB.HasValue) record.BalanceRMB = validBalanceRMB;
                record.LastUpdated = DateTime.Now;
            }
            ReconcileFlowContinuity(FlowRecords);
            Save();
        }
        AppEvents.RaiseHistoryStatsUpdated();
    }

    public void RecordElectricity(double balanceRMB, double? remainingKWh)
    {
        lock (_lock)
        {
            var today = CourseCalendarHelper.DateString(CourseCalendarHelper.BeijingNow);
            var previousRecord = ElectricityRecords
                .Where(r => string.CompareOrdinal(r.DateString, today) < 0)
                .OrderBy(r => r.DateString)
                .LastOrDefault();
            var record = ElectricityRecords.FirstOrDefault(r => r.DateString == today);
            if (record == null)
            {
                var startBalanceRMB = previousRecord != null && balanceRMB <= previousRecord.LatestBalanceRMB
                    ? previousRecord.LatestBalanceRMB
                    : balanceRMB;
                record = new ElectricityDailyRecord
                {
                    DateString = today,
                    StartBalanceRMB = startBalanceRMB,
                    LatestBalanceRMB = balanceRMB,
                    RemainingKWh = remainingKWh,
                    LastUpdated = DateTime.Now
                };
                ElectricityRecords.Add(record);
            }
            else
            {
                var accumulatedCostRMB = record.CostRMB;
                if (balanceRMB > record.LatestBalanceRMB + 0.05)
                {
                    record.StartBalanceRMB = balanceRMB + accumulatedCostRMB;
                }
                else if (balanceRMB > record.LatestBalanceRMB)
                {
                    record.StartBalanceRMB += balanceRMB - record.LatestBalanceRMB;
                }
                record.LatestBalanceRMB = balanceRMB;
                record.RemainingKWh = remainingKWh;
                record.LastUpdated = DateTime.Now;
            }
            Save();
        }
        AppEvents.RaiseHistoryStatsUpdated();
    }

    public bool ActivateCurrentElectricityDorm()
    {
        var targetDormKey = CreateElectricityDormKey(SettingsManager.Shared);
        bool changed;
        lock (_lock)
        {
            changed = SwitchElectricityDormLocked(targetDormKey);
            if (changed) Save();
        }
        if (changed) AppEvents.RaiseHistoryStatsUpdated();
        return changed;
    }

    public bool ActivateCurrentFlowAccount(string username)
    {
        var targetAccountKey = CreateFlowAccountKey(username);
        bool changed;
        lock (_lock)
        {
            if (string.Equals(_activeFlowAccountKey, targetAccountKey, StringComparison.Ordinal))
                return false;

            if (string.Equals(_activeFlowAccountKey, CreateFlowAccountKey(string.Empty), StringComparison.Ordinal) &&
                _archivedFlowRecords.Count == 0)
            {
                // Legacy records migrated before a username was configured belong to the first configured account.
                _activeFlowAccountKey = targetAccountKey;
                Save();
                changed = true;
            }
            else
            {
                _archivedFlowRecords[_activeFlowAccountKey] = FlowRecords.ToList();
                if (_archivedFlowRecords.Remove(targetAccountKey, out var targetRecords))
                    FlowRecords = targetRecords ?? new();
                else
                    FlowRecords = new();

                _activeFlowAccountKey = targetAccountKey;
                Save();
                changed = true;
            }
        }
        if (changed) AppEvents.RaiseHistoryStatsUpdated();
        return changed;
    }

    public void ClearElectricityHistory()
    {
        lock (_lock)
        {
            ElectricityRecords.Clear();
            Save();
        }
        AppEvents.RaiseHistoryStatsUpdated();
    }

    private void Save()
    {
        if (_historyBackupRequired && !TryBackupUnreadableHistory()) return;
        _historyBackupRequired = false;
        if (_flowAccountPartitionBackupRequired && !BackupHistoryBeforeFlowAccountPartitionMigration()) return;
        _flowAccountPartitionBackupRequired = false;
        if (_electricityPartitionBackupRequired && !BackupHistoryBeforeElectricityPartitionMigration()) return;
        _electricityPartitionBackupRequired = false;
        if (_flowContinuityMigrationBackupRequired && !BackupHistoryBeforeFlowContinuityMigration()) return;
        _flowContinuityMigrationBackupRequired = false;
        if (!CompleteFlowAccountingMigrationIfNeeded()) return;

        var temporaryFile = _historyFile + ".tmp";
        try
        {
            var flowRecordsByAccount = new Dictionary<string, List<FlowDailyRecord>>(_archivedFlowRecords, StringComparer.Ordinal)
            {
                [_activeFlowAccountKey] = FlowRecords
            };
            var data = new
            {
                FlowAccountingVersion,
                FlowHistoryPartitionVersion,
                FlowHistoryContinuityVersion,
                FlowRecordsByAccount = flowRecordsByAccount,
                ElectricityDormKey = _activeElectricityDormKey,
                ArchivedElectricityRecords = _archivedElectricityRecords,
                Flow = FlowRecords,
                Electricity = ElectricityRecords
            };
            var json = JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(temporaryFile, json, Encoding.UTF8);
            File.Move(temporaryFile, _historyFile, overwrite: true);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[CampusHistoryManager] Save failed: {ex.Message}");
            try
            {
                if (File.Exists(temporaryFile)) File.Delete(temporaryFile);
            }
            catch { }
        }
    }

    private void Load()
    {
        _activeElectricityDormKey = CreateElectricityDormKey(SettingsManager.Shared);
        _activeFlowAccountKey = CreateFlowAccountKey(SettingsManager.Shared.PortalUsername);
        try
        {
            if (!File.Exists(_historyFile)) return;
            var json = File.ReadAllText(_historyFile, Encoding.UTF8);
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            bool needsSave = false;
            int flowPartitionVersion = root.TryGetProperty("FlowHistoryPartitionVersion", out var flowPartitionVersionProp) &&
                flowPartitionVersionProp.TryGetInt32(out var parsedPartitionVersion) ? parsedPartitionVersion : 0;
            bool loadedFlowPartitions = false;
            if (flowPartitionVersion >= FlowHistoryPartitionVersion &&
                root.TryGetProperty("FlowRecordsByAccount", out var flowPartitionsProp))
            {
                try
                {
                    var flowPartitions = JsonSerializer.Deserialize<Dictionary<string, List<FlowDailyRecord>>>(flowPartitionsProp.GetRawText());
                    if (flowPartitions != null &&
                        flowPartitions.Values.All(records => records != null && records.All(record => record != null)))
                    {
                        _archivedFlowRecords = new Dictionary<string, List<FlowDailyRecord>>(flowPartitions, StringComparer.Ordinal);
                        if (_archivedFlowRecords.Remove(_activeFlowAccountKey, out var accountRecords))
                            FlowRecords = accountRecords ?? new();
                        else
                            FlowRecords = new();
                        loadedFlowPartitions = true;
                    }
                }
                catch (JsonException ex)
                {
                    Debug.WriteLine($"Flow account partitions are invalid; recovering legacy flow history: {ex.Message}");
                }
            }

            if (!loadedFlowPartitions)
            {
                // Keep the readable legacy snapshot when a newer partition field is malformed.
                LoadLegacyFlowRecords(root);
                if (!BackupHistoryBeforeFlowAccountPartitionMigration())
                    _flowAccountPartitionBackupRequired = true;
                needsSave = true;
            }
            if (doc.RootElement.TryGetProperty("Electricity", out var elecProp))
            {
                ElectricityRecords = JsonSerializer.Deserialize<List<ElectricityDailyRecord>>(elecProp.GetRawText()) ?? new();
            }
            if (root.TryGetProperty("ArchivedElectricityRecords", out var archivedProp))
            {
                bool loadedElectricityArchive = false;
                try
                {
                    var archived = JsonSerializer.Deserialize<Dictionary<string, List<ElectricityDailyRecord>>>(archivedProp.GetRawText());
                    if (archived != null &&
                        archived.Values.All(records => records != null && records.All(record => record != null)))
                    {
                        _archivedElectricityRecords = new Dictionary<string, List<ElectricityDailyRecord>>(archived, StringComparer.Ordinal);
                        loadedElectricityArchive = true;
                    }
                }
                catch (JsonException ex)
                {
                    Debug.WriteLine($"Electricity history archive is invalid: {ex.Message}");
                }

                if (!loadedElectricityArchive)
                {
                    Debug.WriteLine("Electricity history archive is invalid; preserving the original history file before continuing.");
                    if (!_historyBackupRequired)
                        _historyBackupRequired = !TryBackupUnreadableHistory();
                }
            }

            var currentDormKey = CreateElectricityDormKey(SettingsManager.Shared);
            bool hasPersistedDormKey = root.TryGetProperty("ElectricityDormKey", out var dormKeyProp) &&
                dormKeyProp.ValueKind == JsonValueKind.String && !string.IsNullOrEmpty(dormKeyProp.GetString());
            if (hasPersistedDormKey)
            {
                _activeElectricityDormKey = dormKeyProp.GetString()!;
                if (!SwitchElectricityDormLocked(currentDormKey))
                    _archivedElectricityRecords.Remove(currentDormKey);
                else
                    needsSave = true;
            }
            else
            {
                // Legacy records belong to the dorm currently configured in settings.
                if (BackupHistoryBeforeElectricityPartitionMigration())
                {
                    _activeElectricityDormKey = currentDormKey;
                    _archivedElectricityRecords.Remove(currentDormKey);
                    needsSave = true;
                }
                else
                {
                    _electricityPartitionBackupRequired = true;
                }
            }

            int version = doc.RootElement.TryGetProperty("FlowAccountingVersion", out var versionProp) &&
                versionProp.TryGetInt32(out var parsedVersion) ? parsedVersion : 0;
            if (version < FlowAccountingVersion)
            {
                _flowAccountingMigrationBackupRequired = true;
                CompleteFlowAccountingMigrationIfNeeded();
                needsSave = true;
            }

            int continuityVersion = root.TryGetProperty("FlowHistoryContinuityVersion", out var continuityVersionProp) &&
                continuityVersionProp.TryGetInt32(out var parsedContinuityVersion) ? parsedContinuityVersion : 0;
            if (continuityVersion < FlowHistoryContinuityVersion)
            {
                _flowContinuityMigrationBackupRequired = true;
                ReconcileFlowContinuity(FlowRecords);
                foreach (var records in _archivedFlowRecords.Values)
                    ReconcileFlowContinuity(records);
                needsSave = true;
            }
            if (needsSave) Save();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[CampusHistoryManager] Load failed: {ex.Message}");
            _historyBackupRequired = !TryBackupUnreadableHistory();
        }
    }

    private bool SwitchElectricityDormLocked(string targetDormKey)
    {
        if (string.Equals(_activeElectricityDormKey, targetDormKey, StringComparison.Ordinal))
            return false;

        if (!string.IsNullOrEmpty(_activeElectricityDormKey))
            _archivedElectricityRecords[_activeElectricityDormKey] = ElectricityRecords.ToList();

        if (_archivedElectricityRecords.Remove(targetDormKey, out var targetRecords))
            ElectricityRecords = targetRecords ?? new();
        else
            ElectricityRecords = new();

        _activeElectricityDormKey = targetDormKey;
        return true;
    }

    private static string CreateElectricityDormKey(SettingsManager settings) => JsonSerializer.Serialize(new[]
    {
        settings.DormCampus ?? "宣城校区",
        settings.DormBuilding ?? string.Empty,
        settings.DormRoom ?? string.Empty,
        settings.DormEndNumber ?? "11"
    });

    private static string CreateFlowAccountKey(string? username)
    {
        var normalizedUsername = username?.Trim().ToUpperInvariant();
        if (string.IsNullOrEmpty(normalizedUsername)) normalizedUsername = "UNCONFIGURED";
        using var sha256 = SHA256.Create();
        var hash = sha256.ComputeHash(Encoding.UTF8.GetBytes($"portal-username:{normalizedUsername}"));
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private void LoadLegacyFlowRecords(JsonElement root)
    {
        if (root.TryGetProperty("Flow", out var flowProp))
            FlowRecords = JsonSerializer.Deserialize<List<FlowDailyRecord>>(flowProp.GetRawText()) ?? new();
        else
            FlowRecords = new();
    }

    private bool BackupHistoryBeforeFlowAccountPartitionMigration()
    {
        if (!File.Exists(_historyFile)) return true;
        var backupFile = _historyFile + ".pre-flow-account-partition-v1.bak";
        if (File.Exists(backupFile)) return true;
        try
        {
            File.Copy(_historyFile, backupFile, overwrite: false);
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Flow account history migration backup failed: {ex.Message}");
            return false;
        }
    }

    private bool BackupHistoryBeforeElectricityPartitionMigration()
    {
        if (!File.Exists(_historyFile)) return true;
        var backupFile = _historyFile + ".pre-dorm-history-partition.bak";
        if (File.Exists(backupFile)) return true;
        try
        {
            File.Copy(_historyFile, backupFile, overwrite: false);
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Electricity history migration backup failed: {ex.Message}");
            return false;
        }
    }

    private bool BackupHistoryBeforeFlowMigration()
    {
        if (!File.Exists(_historyFile)) return true;
        var backupFile = _historyFile + ".pre-traffic-scale-v2.bak";
        if (File.Exists(backupFile)) return true;
        try
        {
            File.Copy(_historyFile, backupFile, overwrite: false);
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Flow history migration backup failed: {ex.Message}");
            return false;
        }
    }

    private bool BackupHistoryBeforeFlowContinuityMigration()
    {
        if (!File.Exists(_historyFile)) return true;
        var backupFile = _historyFile + ".pre-flow-continuity-v1.bak";
        if (File.Exists(backupFile)) return true;
        try
        {
            File.Copy(_historyFile, backupFile, overwrite: false);
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Flow continuity migration backup failed: {ex.Message}");
            return false;
        }
    }

    private static bool ReconcileFlowContinuity(List<FlowDailyRecord> records)
    {
        if (records.Count < 2) return false;

        records.Sort((left, right) => string.CompareOrdinal(left.DateString, right.DateString));
        var expanded = new List<FlowDailyRecord>(records.Count);
        expanded.Add(records[0]);
        bool modified = false;

        for (int i = 1; i < records.Count; i++)
        {
            var previous = expanded[^1];
            var current = records[i];
            if (DateTime.TryParseExact(previous.DateString, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                    DateTimeStyles.None, out var previousDate) &&
                DateTime.TryParseExact(current.DateString, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                    DateTimeStyles.None, out var currentDate) &&
                previousDate.Year == currentDate.Year && previousDate.Month == currentDate.Month &&
                current.LatestUsedMB >= previous.LatestUsedMB)
            {
                int gap = (currentDate.Date - previousDate.Date).Days;
                if (gap > 1 && gap <= 30)
                {
                    double targetEndOfPreviousDay;
                    if (current.StartUsedMB > previous.LatestUsedMB + 0.01 &&
                        current.StartUsedMB <= current.LatestUsedMB)
                    {
                        targetEndOfPreviousDay = current.StartUsedMB;
                    }
                    else
                    {
                        var stepMB = (current.LatestUsedMB - previous.LatestUsedMB) / gap;
                        targetEndOfPreviousDay = previous.LatestUsedMB + stepMB * (gap - 1);
                    }

                    var offlineDailyMB = Math.Max(0.0,
                        (targetEndOfPreviousDay - previous.LatestUsedMB) / (gap - 1));
                    for (int step = 1; step < gap; step++)
                    {
                        var missingDate = previousDate.AddDays(step).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                        var startMB = previous.LatestUsedMB + offlineDailyMB * (step - 1);
                        var endMB = previous.LatestUsedMB + offlineDailyMB * step;
                        expanded.Add(new FlowDailyRecord
                        {
                            DateString = missingDate,
                            StartUsedMB = startMB,
                            LatestUsedMB = endMB,
                            BalanceRMB = previous.BalanceRMB,
                            LastUpdated = current.LastUpdated
                        });
                    }

                    current.StartUsedMB = targetEndOfPreviousDay;
                    modified = true;
                }
                else if (gap == 1 && Math.Abs(current.StartUsedMB - previous.LatestUsedMB) > 0.01)
                {
                    current.StartUsedMB = previous.LatestUsedMB;
                    modified = true;
                }
            }

            expanded.Add(current);
        }

        if (modified)
            ReplaceRecords(records, expanded);
        return modified;
    }

    private static void ReplaceRecords(List<FlowDailyRecord> target, List<FlowDailyRecord> replacement)
    {
        target.Clear();
        target.AddRange(replacement);
    }

    private bool CompleteFlowAccountingMigrationIfNeeded()
    {
        if (!_flowAccountingMigrationBackupRequired) return true;
        if (!BackupHistoryBeforeFlowMigration()) return false;

        foreach (var record in FlowRecords)
        {
            record.StartUsedMB *= 2.0;
            record.LatestUsedMB *= 2.0;
        }
        foreach (var records in _archivedFlowRecords.Values)
        {
            foreach (var record in records)
            {
                record.StartUsedMB *= 2.0;
                record.LatestUsedMB *= 2.0;
            }
        }

        _flowAccountingMigrationBackupRequired = false;
        return true;
    }

    private bool TryBackupUnreadableHistory()
    {
        if (!File.Exists(_historyFile)) return true;

        var backupFile = _historyFile + $".load-failure-{DateTime.UtcNow:yyyyMMddHHmmssfff}-{Guid.NewGuid():N}.bak";
        try
        {
            File.Copy(_historyFile, backupFile, overwrite: false);
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[CampusHistoryManager] Could not preserve unreadable history: {ex.Message}");
            return false;
        }
    }
}

#endregion

#region 4. 实时网速监控器 NetworkSpeedMonitor

public sealed class NetworkSpeedMonitor
{
    public static NetworkSpeedMonitor Shared { get; } = new();

    private Timer? _timer;
    private long _lastBytesReceived;
    private long _lastBytesSent;
    private DateTime _lastTime = DateTime.Now;
    private bool _started;

    private NetworkSpeedMonitor() { }

    public void Start()
    {
        if (_started) return;
        _started = true;

        GetTotalBytes(out _lastBytesReceived, out _lastBytesSent);
        _lastTime = DateTime.Now;

        _timer = new Timer(OnTick, null, 1000, 1000);
    }

    private void OnTick(object? state)
    {
        try
        {
            GetTotalBytes(out long curRecv, out long curSent);
            var now = DateTime.Now;
            var elapsed = Math.Max(0.5, (now - _lastTime).TotalSeconds);
            _lastTime = now;

            double downBytesPerSec = Math.Max(0, (curRecv - _lastBytesReceived) / elapsed);
            double upBytesPerSec = Math.Max(0, (curSent - _lastBytesSent) / elapsed);

            _lastBytesReceived = curRecv;
            _lastBytesSent = curSent;

            var downStr = FormatSpeed(downBytesPerSec);
            var upStr = FormatSpeed(upBytesPerSec);
            var compactStr = $"↓ {FormatCompactSpeed(downBytesPerSec)}  ↑ {FormatCompactSpeed(upBytesPerSec)}";

            AppEvents.RaiseSpeedUpdated(downStr, upStr, compactStr);
        }
        catch { }
    }

    private static void GetTotalBytes(out long bytesRecv, out long bytesSent)
    {
        bytesRecv = 0;
        bytesSent = 0;
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            if (ni.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;

            var stats = ni.GetIPStatistics();
            bytesRecv += stats.BytesReceived;
            bytesSent += stats.BytesSent;
        }
    }

    private static string FormatSpeed(double bytes)
    {
        if (bytes >= 1024 * 1024 * 1024) return $"{bytes / (1024 * 1024 * 1024):F2} GB/s";
        if (bytes >= 1024 * 1024) return $"{bytes / (1024 * 1024):F1} MB/s";
        if (bytes >= 1024) return $"{bytes / 1024:F0} KB/s";
        return $"{bytes:F0} B/s";
    }

    private static string FormatCompactSpeed(double bytes)
    {
        if (bytes >= 1024 * 1024) return $"{bytes / (1024 * 1024):F1}M/s";
        if (bytes >= 1024) return $"{bytes / 1024:F0}K/s";
        return $"{bytes:F0}B/s";
    }
}

#endregion

#region 5. 原生通知助手 NotificationHelper

public static class NotificationHelper
{
    public static void Send(string title, string body, string? identifier = null)
    {
        AppEvents.InvokeOnUI(() =>
        {
            try
            {
                TrayMenuController.Shared.ShowNotification(title, body);
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[NotificationHelper] Send failed: {ex.Message}");
            }
        });
    }
}

#endregion

#region 6. 校园网认证与自服务客户端 PortalAuthService & CampusNetworkClient

public sealed class PortalAuthService
{
    public static PortalAuthService Shared { get; } = new();

    private readonly HttpClient _client;

    private PortalAuthService()
    {
        var handler = new HttpClientHandler
        {
            UseCookies = true,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
        };
        _client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(5) };
    }

    public async Task<(bool Online, string Username, string Ip, double FlowMB, double Fee, int TimeMin)> CheckStatusAsync()
    {
        try
        {
            var resBytes = await _client.GetByteArrayAsync("http://172.18.3.3/");
            var res = DecodeHtml(resBytes);
            if (res.Contains("Dr.COMWebLoginID_1.htm") || res.Contains("DispTFM") || res.Contains("v4ip") || res.Contains("ss5"))
            {
                var uid = ExtractVar("uid", res) ?? "校园网用户";
                var v4ip = ExtractVar("v4ip", res) ?? "";
                double.TryParse(ExtractVar("flow", res), NumberStyles.Float, CultureInfo.InvariantCulture, out double flowKB);
                double.TryParse(ExtractVar("fee", res), NumberStyles.Float, CultureInfo.InvariantCulture, out double feeRaw);
                int.TryParse(ExtractVar("time", res), out int timeSec);

                double feeYuan = feeRaw >= 0 ? feeRaw / 10000.0 : 0;
                return (true, uid, v4ip, flowKB / 1024.0, feeYuan, timeSec / 60);
            }
            return (false, "", "", 0, 0, 0);
        }
        catch
        {
            return (false, "", "", 0, 0, 0);
        }
    }

    public async Task<(bool Success, string Message)> LoginAsync(string username, string password)
    {
        try
        {
            var pid = "2";
            var calg = "12345678";
            var tmpchar = $"{pid}{password}{calg}";
            using var md5 = MD5.Create();
            var hashBytes = md5.ComputeHash(Encoding.UTF8.GetBytes(tmpchar));
            var md5Hex = Convert.ToHexString(hashBytes).ToLowerInvariant();
            var upass = $"{md5Hex}{calg}{pid}";

            var body = $"DDDDD={Uri.EscapeDataString(username)}&upass={Uri.EscapeDataString(upass)}&R1=0&R2=1&para=00&0MKKey=123456&v6ip=";
            using var req = new HttpRequestMessage(HttpMethod.Post, "http://172.18.3.3/");
            req.Headers.TryAddWithoutValidation("Referer", "http://172.18.3.3/0.htm");
            req.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
            req.Content = new StringContent(body, Encoding.UTF8, "application/x-www-form-urlencoded");

            using var resp = await _client.SendAsync(req);
            var respBytes = await resp.Content.ReadAsByteArrayAsync();
            var res = DecodeHtml(respBytes);

            if (res.Contains("Dr.COMWebLoginID_1.htm") || res.Contains("DispTFM"))
            {
                return (true, "校园网认证成功");
            }
            if (res.Contains("msga='"))
            {
                var rawMsg = ExtractVar("msga", res) ?? "";
                if (rawMsg.Contains("userid error")) return (false, "学号或密码错误，请核对后重试");
                if (rawMsg.Contains("ip error")) return (false, "IP 绑定异常或超额在线");
                if (!string.IsNullOrEmpty(rawMsg)) return (false, rawMsg);
            }

            var status = await CheckStatusAsync();
            if (status.Online && string.Equals(status.Username, username, StringComparison.Ordinal))
                return (true, "当前设备已使用该账号在线");
            if (status.Online)
                return (false, $"当前设备已以账号 {status.Username} 在线，未确认 {username} 登录成功");
            return (false, "认证未通过");
        }
        catch (Exception ex)
        {
            return (false, $"连接网关超时: {ex.Message}");
        }
    }

    public async Task LogoutAsync()
    {
        try
        {
            await _client.GetStringAsync("http://172.18.3.3/F.htm");
        }
        catch { }
    }

    public void Login(
        string? username,
        string? password,
        Action<bool, string>? callback = null,
        long? expectedAccountGeneration = null)
    {
        var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
        var u = username ?? string.Empty;
        var p = password ?? string.Empty;
        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
        {
            if (string.IsNullOrEmpty(u)) u = SettingsManager.Shared.PortalUsername;
            if (string.IsNullOrEmpty(p)) p = SettingsManager.Shared.PortalPassword;
        })) return;
        if (string.IsNullOrEmpty(u) || string.IsNullOrEmpty(p))
        {
            AppEvents.InvokeOnUI(() =>
            {
                if (AccountSessionManager.IsGenerationCurrent(accountGeneration))
                    callback?.Invoke(false, "未配置校园网认证账号或密码");
            });
            return;
        }

        Task.Run(async () =>
        {
            if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return;
            var (ok, msg) = await LoginAsync(u, p);
            if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return;
            AppEvents.InvokeOnUI(() =>
            {
                if (AccountSessionManager.IsGenerationCurrent(accountGeneration))
                    callback?.Invoke(ok, msg);
            });
        });
    }

    public void Logout(Action<bool, string>? callback = null)
    {
        Task.Run(async () =>
        {
            await LogoutAsync();
            AppEvents.InvokeOnUI(() => callback?.Invoke(true, "已发送注销请求"));
        });
    }

    private static string DecodeHtml(byte[] bytes)
    {
        try
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            var gbk = Encoding.GetEncoding("GB18030");
            return gbk.GetString(bytes);
        }
        catch
        {
            return Encoding.UTF8.GetString(bytes);
        }
    }

    private static string? ExtractVar(string name, string text)
    {
        var m = Regex.Match(text, $@"""?{Regex.Escape(name)}""?\s*[:=]\s*""?([^"",;\r\n]+)""?");
        return m.Success ? m.Groups[1].Value.Trim() : null;
    }
}

public sealed class CampusNetworkClient
{
    public static CampusNetworkClient Shared { get; } = new();

    public CampusNetworkData LatestData { get; private set; } = new();

    private Timer? _syncTimer;
    private readonly HttpClient _client;
    private readonly HttpClient _selfServiceClient;
    private readonly object _accountStateLock = new();
    private readonly object _selfServiceLoginLock = new();
    private readonly AsyncLocal<long?> _fetchGenerationContext = new();
    private long _fetchGeneration;
    private long _selfServiceLoginSequence;
    private long _selfServiceLoginOwner;
    private int _lastPortalFlowMonthKey;

    private CampusNetworkClient()
    {
        var handler = new HttpClientHandler
        {
            UseCookies = true,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
        };
        _client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(8) };

        var selfHandler = new HttpClientHandler
        {
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
        };
        _selfServiceClient = new HttpClient(selfHandler) { Timeout = TimeSpan.FromSeconds(10) };
    }

    public void StartMonitoring()
    {
        _syncTimer?.Dispose();
        FetchData();
        var intervalMs = (int)(Math.Max(30, SettingsManager.Shared.RefreshInterval) * 1000);
        _syncTimer = new Timer(_ => FetchData(), null, intervalMs, intervalMs);
    }

    public void ClearAccountScopedData()
    {
        lock (_accountStateLock)
        {
            _fetchGeneration++;
            LatestData = new CampusNetworkData();
            _lastPortalFlowMonthKey = 0;
        }
        lock (_selfServiceLoginLock)
        {
            _selfServiceLoginOwner = 0;
        }
        AppEvents.InvokeOnUI(AppEvents.RaiseNetworkDataUpdated);
    }

    public bool TrySetSessionCookie(string cookie, long expectedAccountGeneration)
    {
        return TryUpdateForAccount(expectedAccountGeneration, () =>
        {
            SettingsManager.Shared.SessionCookie = cookie;
            SettingsManager.Shared.Save();
        });
    }

    private bool IsCurrentAccount(long accountGeneration)
    {
        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return false;
        var expectedFetchGeneration = _fetchGenerationContext.Value;
        if (!expectedFetchGeneration.HasValue) return true;

        lock (_accountStateLock)
        {
            return expectedFetchGeneration.Value == _fetchGeneration;
        }
    }

    private bool TryUpdateForAccount(long accountGeneration, Action update)
    {
        lock (_accountStateLock)
        {
            var expectedFetchGeneration = _fetchGenerationContext.Value;
            if (expectedFetchGeneration.HasValue && expectedFetchGeneration.Value != _fetchGeneration)
                return false;
            return AccountSessionManager.TryRunForGeneration(accountGeneration, update);
        }
    }

    private long BeginFetchRequest()
    {
        lock (_accountStateLock)
        {
            return ++_fetchGeneration;
        }
    }

    public void FetchData()
    {
        var accountGeneration = AccountSessionManager.Generation;
        var fetchGeneration = BeginFetchRequest();
        var requestTime = CourseCalendarHelper.BeijingNow;
        var requestMonthKey = requestTime.Year * 100 + requestTime.Month;
        Task.Run(async () =>
        {
            _fetchGenerationContext.Value = fetchGeneration;
            try
            {
                var (online, uid, ip, flowMB, fee, timeMin) = await PortalAuthService.Shared.CheckStatusAsync();
                if (!IsCurrentAccount(accountGeneration)) return;
                if (online)
                {
                    double actualFlowMB = flowMB * 2.0;
                    var observedAt = requestTime;
                    bool requestMonthStillCurrent = false;
                    if (!TryUpdateForAccount(accountGeneration, () =>
                    {
                        LatestData.IsLoggedIn = true;
                        var beijingNow = CourseCalendarHelper.BeijingNow;
                        var currentMonthKey = beijingNow.Year * 100 + beijingNow.Month;
                        observedAt = beijingNow;
                        requestMonthStillCurrent = requestMonthKey == currentMonthKey;
                        if (flowMB > 0 && requestMonthStillCurrent)
                        {
                            var curMB = LatestData.UsedMB ?? 0.0;
                            if (_lastPortalFlowMonthKey != requestMonthKey || curMB == 0 || actualFlowMB >= curMB)
                            {
                                LatestData.UsedFlow = actualFlowMB >= 1024 ? $"{actualFlowMB / 1024.0:F2} G" : $"{actualFlowMB:F0} M";
                            }
                            _lastPortalFlowMonthKey = requestMonthKey;
                        }
                        // 网关在部分网络状态下会返回 0；不要用它覆盖自服务里的真实余额，
                        // 也不要在自服务同步前把占位值替换成误导性的 0.00 元。
                        if (fee > 0 &&
                            (string.IsNullOrWhiteSpace(LatestData.Balance) || LatestData.Balance == "-- 元"))
                        {
                            LatestData.Balance = $"{fee:F2} 元";
                        }
                        if (flowMB > 0)
                        {
                            LatestData.AvailableFlow = $"{Math.Max(0, 200.0 * 1024.0 - actualFlowMB):F0} M";
                        }
                        LatestData.LastUpdated = DateTime.Now;
                        LatestData.ErrorMessage = null;

                        if (flowMB > 0 && requestMonthStillCurrent)
                        {
                            var balanceRMB = fee > 0
                                ? fee
                                : CampusNetworkData.ParseBalanceRMB(LatestData.Balance);
                            CampusHistoryManager.Shared.RecordFlow(actualFlowMB, balanceRMB, observedAt);
                        }
                    })) return;

                    // 在线状态也要定期刷新自服务仪表盘。以前这里仅更新网关数据，
                    // 导致自服务的月流量与余额在在线时一直停留在旧值。
                    bool dashboardRefreshed = false;
                    bool hasSelfServiceAuth = false;
                    if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                    {
                        hasSelfServiceAuth =
                            !string.IsNullOrWhiteSpace(SettingsManager.Shared.SessionCookie) ||
                            (!string.IsNullOrWhiteSpace(SettingsManager.Shared.PortalUsername) &&
                             !string.IsNullOrWhiteSpace(SettingsManager.Shared.PortalPassword));
                    })) return;
                    if (hasSelfServiceAuth)
                    {
                        try { dashboardRefreshed = await FetchDashboardDataAsync(accountGeneration); } catch { }
                    }
                    if (!IsCurrentAccount(accountGeneration)) return;

                    // 成功解析仪表盘时 ApplyParsedDashboardHTML 已会刷新设备列表；
                    // 解析失败但会话仍有效时，仍单独更新在线设备。
                    string? sessionCookie = null;
                    if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                        sessionCookie = SettingsManager.Shared.SessionCookie)) return;
                    if (!dashboardRefreshed && !string.IsNullOrWhiteSpace(sessionCookie))
                    {
                        try { await FetchOnlineDevicesAsync(accountGeneration); } catch { }
                    }
                }
                else
                {
                    // 若开启了自动登录网关，尝试自动认证
                    string portalUsername = string.Empty;
                    string portalPassword = string.Empty;
                    bool autoLoginPortal = false;
                    if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                    {
                        portalUsername = SettingsManager.Shared.PortalUsername;
                        portalPassword = SettingsManager.Shared.PortalPassword;
                        autoLoginPortal = SettingsManager.Shared.AutoLoginPortal;
                    })) return;
                    if (autoLoginPortal && !string.IsNullOrEmpty(portalUsername))
                    {
                        var (ok, _) = await PortalAuthService.Shared.LoginAsync(
                            portalUsername,
                            portalPassword);
                        if (!IsCurrentAccount(accountGeneration)) return;
                        if (ok)
                        {
                            FetchData();
                            return;
                        }
                    }

                    // 离线/校外模式下，尝试自服务抓取
                    bool dashOk = false;
                    try
                    {
                        bool hasSelfServiceAuth = false;
                        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                        {
                            hasSelfServiceAuth = !string.IsNullOrEmpty(SettingsManager.Shared.SessionCookie) ||
                                (!string.IsNullOrEmpty(SettingsManager.Shared.PortalUsername) &&
                                 !string.IsNullOrEmpty(SettingsManager.Shared.PortalPassword));
                        })) return;
                        if (hasSelfServiceAuth)
                        {
                            dashOk = await FetchDashboardDataAsync(accountGeneration);
                        }
                    }
                    catch { }
                    if (!IsCurrentAccount(accountGeneration)) return;

                    if (!dashOk)
                    {
                        // Fallback 慧新易校
                        try
                        {
                            var hxObservedAt = CourseCalendarHelper.BeijingNow;
                            var (hxFlow, hxBalance) = await ElectricityService.Shared.FetchSchoolNetInfoFromHuiXinAsync(
                                accountGeneration);
                            if (!IsCurrentAccount(accountGeneration)) return;
                            var hxRequestMonth = hxObservedAt.Year * 100 + hxObservedAt.Month;
                            var hxResponseAt = CourseCalendarHelper.BeijingNow;
                            var hxResponseMonthStillCurrent = hxRequestMonth == hxResponseAt.Year * 100 + hxResponseAt.Month;
                            if (!string.IsNullOrEmpty(hxFlow) || !string.IsNullOrEmpty(hxBalance))
                            {
                                var actualHxFlow = hxResponseMonthStillCurrent
                                    ? CampusNetworkData.ActualTrafficFlow(hxFlow) ?? hxFlow
                                    : null;
                                if (!TryUpdateForAccount(accountGeneration, () =>
                                {
                                    LatestData.IsLoggedIn = false;
                                    if (hxResponseMonthStillCurrent && !string.IsNullOrEmpty(hxFlow) &&
                                        (string.IsNullOrWhiteSpace(LatestData.UsedFlow) || LatestData.UsedFlow == "-- M"))
                                    {
                                        LatestData.UsedFlow = actualHxFlow ?? hxFlow;
                                    }
                                    if (!string.IsNullOrEmpty(hxBalance) &&
                                        (string.IsNullOrWhiteSpace(LatestData.Balance) || LatestData.Balance == "-- 元"))
                                    {
                                        LatestData.Balance = hxBalance;
                                    }
                                    LatestData.ErrorMessage = "未处于校园网Wi-Fi (已同步慧新易校数据)";
                                    LatestData.LastUpdated = DateTime.Now;

                                    if (!string.IsNullOrEmpty(actualHxFlow))
                                    {
                                        var cleanMB = Regex.Match(actualHxFlow, @"[0-9]+(?:\.[0-9]+)?");
                                        if (cleanMB.Success && double.TryParse(cleanMB.Value, NumberStyles.Any, CultureInfo.InvariantCulture, out double parsedMB))
                                        {
                                            if (actualHxFlow.Contains("G", StringComparison.OrdinalIgnoreCase)) parsedMB *= 1024.0;
                                            CampusHistoryManager.Shared.RecordFlow(
                                                parsedMB,
                                                CampusNetworkData.ParseBalanceRMB(LatestData.Balance),
                                                hxObservedAt);
                                        }
                                    }
                                })) return;
                            }
                            else
                            {
                                TryUpdateForAccount(accountGeneration, () =>
                                {
                                    LatestData.IsLoggedIn = false;
                                    LatestData.ErrorMessage = "未登录校园网";
                                });
                            }
                        }
                        catch
                        {
                            TryUpdateForAccount(accountGeneration, () =>
                            {
                                LatestData.IsLoggedIn = false;
                                LatestData.ErrorMessage = "未登录校园网";
                            });
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                TryUpdateForAccount(accountGeneration, () => LatestData.ErrorMessage = ex.Message);
            }
            finally
            {
                if (IsCurrentAccount(accountGeneration))
                    AppEvents.RaiseNetworkDataUpdated();
            }
        });
    }

    /// <summary>
    /// 获取当前自服务平台在线设备列表 (dashboard/getOnlineList)
    /// 独立拉取设备，绝不影响或重置已用流量和余额，绝不抛出异常
    /// </summary>
    public void FetchOnlineDevices(Action<bool, string>? callback = null)
    {
        var accountGeneration = AccountSessionManager.Generation;
        Task.Run(async () =>
        {
            try
            {
                var result = await FetchOnlineDevicesAsync(accountGeneration);
                if (IsCurrentAccount(accountGeneration))
                    callback?.Invoke(result.Success, result.Message);
            }
            catch (Exception ex)
            {
                if (IsCurrentAccount(accountGeneration))
                    callback?.Invoke(false, ex.Message);
            }
        });
    }

    public async Task<(bool Success, string Message, List<OnlineDeviceSession> Devices)> FetchOnlineDevicesAsync(
        long? expectedAccountGeneration = null)
    {
        var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
        try
        {
            if (!IsCurrentAccount(accountGeneration)) return (false, "账号已切换", new());
            string? cookie = null;
            string? username = null;
            string? password = null;
            if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
            {
                cookie = SettingsManager.Shared.SessionCookie?.Trim();
                username = SettingsManager.Shared.PortalUsername;
                password = SettingsManager.Shared.PortalPassword;
            })) return (false, "账号已切换", new());
            if (string.IsNullOrEmpty(cookie))
            {
                if (!string.IsNullOrEmpty(username) && !string.IsNullOrEmpty(password))
                {
                    var (loginOk, _) = await SilentLoginSelfServiceAndFetchAsync(accountGeneration);
                    if (!IsCurrentAccount(accountGeneration)) return (false, "账号已切换", new());
                    if (loginOk)
                    {
                        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                            cookie = SettingsManager.Shared.SessionCookie?.Trim()))
                            return (false, "账号已切换", new());
                    }
                }
            }

            if (string.IsNullOrEmpty(cookie))
            {
                return (false, "自服务会话未就绪", new());
            }

            string cleanCookie = cookie.Contains("JSESSIONID=") ? cookie : $"JSESSIONID={cookie}";
            using var req = new HttpRequestMessage(HttpMethod.Get, "https://xywzz.hfut.edu.cn:8443/Self/dashboard/getOnlineList");
            req.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
            req.Headers.TryAddWithoutValidation("Referer", "https://xywzz.hfut.edu.cn:8443/Self/dashboard");
            req.Headers.TryAddWithoutValidation("Cookie", cleanCookie);

            using var resp = await _selfServiceClient.SendAsync(req);
            if (!IsCurrentAccount(accountGeneration)) return (false, "账号已切换", new());
            if ((int)resp.StatusCode == 301 || (int)resp.StatusCode == 302)
            {
                TryUpdateForAccount(accountGeneration, () =>
                {
                    SettingsManager.Shared.SessionCookie = null;
                    SettingsManager.Shared.Save();
                });
                return (false, "自服务会话已失效", new());
            }

            var text = await resp.Content.ReadAsStringAsync();
            if (!IsCurrentAccount(accountGeneration)) return (false, "账号已切换", new());
            if (string.IsNullOrWhiteSpace(text) || text.Contains("欢迎登录用户自助服务系统") || text.TrimStart().StartsWith("<"))
            {
                TryUpdateForAccount(accountGeneration, () =>
                {
                    SettingsManager.Shared.SessionCookie = null;
                    SettingsManager.Shared.Save();
                });
                return (false, "自服务会话已失效", new());
            }

            var list = new List<OnlineDeviceSession>();
            using (var doc = JsonDocument.Parse(text))
            {
                if (doc.RootElement.ValueKind == JsonValueKind.Array)
                {
                    foreach (var item in doc.RootElement.EnumerateArray())
                    {
                        var sid = item.TryGetProperty("sessionId", out var sidProp) ? sidProp.GetString() ?? "" : "";
                        if (string.IsNullOrEmpty(sid)) continue;

                        var ip = item.TryGetProperty("ip", out var ipProp) ? ipProp.GetString() ?? "--" : "--";
                        var mac = item.TryGetProperty("mac", out var macProp) ? macProp.GetString() ?? "" : "";
                        var loginTime = item.TryGetProperty("loginTime", out var ltProp) ? ltProp.GetString() ?? "--" : "--";

                        int useTimeSec = 0;
                        if (item.TryGetProperty("useTime", out var utProp))
                        {
                            if (utProp.ValueKind == JsonValueKind.Number) useTimeSec = utProp.GetInt32();
                            else if (int.TryParse(utProp.GetString(), out int utVal)) useTimeSec = utVal;
                        }
                        int useMinutes = Math.Max(0, (int)Math.Round(useTimeSec / 60.0));

                        double downKB = 0, upKB = 0;
                        if (item.TryGetProperty("downFlow", out var dfProp))
                        {
                            if (dfProp.ValueKind == JsonValueKind.Number) downKB = dfProp.GetDouble();
                            else if (double.TryParse(dfProp.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out double dfVal)) downKB = dfVal;
                        }
                        if (item.TryGetProperty("upFlow", out var ufProp))
                        {
                            if (ufProp.ValueKind == JsonValueKind.Number) upKB = ufProp.GetDouble();
                            else if (double.TryParse(ufProp.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out double ufVal)) upKB = ufVal;
                        }
                        double usedMB = (downKB + upKB) / 1024.0;

                        var termType = item.TryGetProperty("terminalType", out var ttProp) ? ttProp.GetString() ?? "在线终端" : "在线终端";
                        if (termType.StartsWith("#")) termType = termType[1..];
                        if (string.IsNullOrWhiteSpace(termType)) termType = "在线终端";

                        var hostName = item.TryGetProperty("hostName", out var hnProp) ? hnProp.GetString() ?? "" : "";

                        list.Add(new OnlineDeviceSession
                        {
                            SessionId = sid,
                            Ip = ip,
                            Mac = mac,
                            LoginTime = loginTime,
                            UseMinutes = useMinutes,
                            UsedFlowMB = usedMB,
                            TerminalType = termType,
                            HostName = hostName
                        });
                    }
                }
            }

            if (!TryUpdateForAccount(accountGeneration, () => LatestData.OnlineDevices = list))
                return (false, "账号已切换", new());
            AppEvents.RaiseNetworkDataUpdated();
            return (true, $"已获取 {list.Count} 台在线终端设备", list);
        }
        catch (Exception ex)
        {
            return (false, $"获取在线设备失败: {ex.Message}", new());
        }
    }

    /// <summary>
    /// 静默后台登录校园网自服务系统 (xywzz.hfut.edu.cn:8443) 并抓取流量
    /// </summary>
    public async Task<(bool Success, string Message)> SilentLoginSelfServiceAndFetchAsync(
        long? expectedAccountGeneration = null,
        DateTime? observedAt = null)
    {
        var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
        var sampleTime = observedAt ?? CourseCalendarHelper.BeijingNow;
        string? username = null;
        string? password = null;
        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
        {
            username = SettingsManager.Shared.PortalUsername?.Trim();
            password = SettingsManager.Shared.PortalPassword?.Trim();
        })) return (false, "账号已切换");
        if (string.IsNullOrEmpty(username) || string.IsNullOrEmpty(password))
        {
            return (false, "请先在偏好设置中配置学号与密码");
        }

        long loginRequestId;
        lock (_selfServiceLoginLock)
        {
            if (_selfServiceLoginOwner != 0)
                return (false, "正在进行自服务认证中...");
            loginRequestId = ++_selfServiceLoginSequence;
            _selfServiceLoginOwner = loginRequestId;
        }

        try
        {
            // Step 1: GET /Self/login/?302=LI
            using var step1Req = new HttpRequestMessage(HttpMethod.Get, "https://xywzz.hfut.edu.cn:8443/Self/login/?302=LI");
            step1Req.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
            using var step1Resp = await _selfServiceClient.SendAsync(step1Req);
            if (!IsCurrentAccount(accountGeneration)) return (false, "账号已切换");
            var step1Html = await step1Resp.Content.ReadAsStringAsync();
            if (!IsCurrentAccount(accountGeneration)) return (false, "账号已切换");

            string? sid = null;
            if (step1Resp.Headers.TryGetValues("Set-Cookie", out var setCookies))
            {
                foreach (var sc in setCookies)
                {
                    var m = Regex.Match(sc, @"JSESSIONID=([0-9A-Za-z_]+)", RegexOptions.IgnoreCase);
                    if (m.Success) { sid = m.Groups[1].Value; break; }
                }
            }
            if (string.IsNullOrEmpty(sid))
            {
                var m = Regex.Match(step1Html, @"jsessionid=([0-9A-Za-z_]+)", RegexOptions.IgnoreCase);
                if (m.Success) sid = m.Groups[1].Value;
            }

            if (string.IsNullOrEmpty(sid))
            {
                return (false, "未能从自服务系统获取会话标识");
            }

            var checkcodeMatch = Regex.Match(step1Html, @"name=""checkcode""\s+value=""([^""]*)""", RegexOptions.IgnoreCase);
            var checkcode = checkcodeMatch.Success ? checkcodeMatch.Groups[1].Value : "";

            string cookieHeader = $"JSESSIONID={sid}";

            // Step 2: randomCode 初始化验证码环境
            var rnd = new Random().NextDouble();
            using var step2Req = new HttpRequestMessage(HttpMethod.Get, $"https://xywzz.hfut.edu.cn:8443/Self/login/randomCode?t={rnd:F4}");
            step2Req.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
            step2Req.Headers.TryAddWithoutValidation("Referer", "https://xywzz.hfut.edu.cn:8443/Self/login/?302=LI");
            step2Req.Headers.TryAddWithoutValidation("Cookie", cookieHeader);
            using var step2Resp = await _selfServiceClient.SendAsync(step2Req);
            if (!IsCurrentAccount(accountGeneration)) return (false, "账号已切换");

            // Step 3: POST verify
            using var md5 = MD5.Create();
            var md5Bytes = md5.ComputeHash(Encoding.UTF8.GetBytes(password));
            var md5Password = Convert.ToHexString(md5Bytes).ToLowerInvariant();

            var formBody = $"foo=&bar=&checkcode={Uri.EscapeDataString(checkcode)}&account={Uri.EscapeDataString(username)}&password={Uri.EscapeDataString(md5Password)}&code=";
            using var step3Req = new HttpRequestMessage(HttpMethod.Post, "https://xywzz.hfut.edu.cn:8443/Self/login/verify");
            step3Req.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
            step3Req.Headers.TryAddWithoutValidation("Referer", "https://xywzz.hfut.edu.cn:8443/Self/login/?302=LI");
            step3Req.Headers.TryAddWithoutValidation("Cookie", cookieHeader);
            step3Req.Content = new StringContent(formBody, Encoding.UTF8, "application/x-www-form-urlencoded");

            using var step3Resp = await _selfServiceClient.SendAsync(step3Req);
            if (!IsCurrentAccount(accountGeneration)) return (false, "账号已切换");
            var step3Html = await step3Resp.Content.ReadAsStringAsync();
            if (!IsCurrentAccount(accountGeneration)) return (false, "账号已切换");

            string finalSid = sid;
            if (step3Resp.Headers.TryGetValues("Set-Cookie", out var verifyCookies))
            {
                foreach (var sc in verifyCookies)
                {
                    var m = Regex.Match(sc, @"JSESSIONID=([0-9A-Za-z_]+)", RegexOptions.IgnoreCase);
                    if (m.Success) { finalSid = m.Groups[1].Value; break; }
                }
            }

            if (!TryUpdateForAccount(accountGeneration, () =>
            {
                SettingsManager.Shared.SessionCookie = $"JSESSIONID={finalSid}";
                SettingsManager.Shared.Save();
            })) return (false, "账号已切换");

            if (step3Html.Contains("可用流量") || step3Html.Contains("已用流量"))
            {
                ApplyParsedDashboardHTML(step3Html, accountGeneration, sampleTime);
                return (true, "自服务系统登录成功");
            }

            return (false, "自服务登录未返回仪表盘数据");
        }
        catch (Exception ex)
        {
            return (false, $"自服务登录异常: {ex.Message}");
        }
        finally
        {
            lock (_selfServiceLoginLock)
            {
                if (_selfServiceLoginOwner == loginRequestId)
                    _selfServiceLoginOwner = 0;
            }
        }
    }

    /// <summary>
    /// 抓取自服务仪表盘流量与余额页面（单向拉取，绝不循环递归）
    /// </summary>
    public async Task<bool> FetchDashboardDataAsync(long? expectedAccountGeneration = null)
    {
        var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
        var sampleTime = CourseCalendarHelper.BeijingNow;
        if (!IsCurrentAccount(accountGeneration)) return false;
        string? cookie = null;
        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
            cookie = SettingsManager.Shared.SessionCookie?.Trim())) return false;
        if (string.IsNullOrEmpty(cookie))
        {
            var (ok, _) = await SilentLoginSelfServiceAndFetchAsync(accountGeneration, sampleTime);
            return IsCurrentAccount(accountGeneration) && ok;
        }

        try
        {
            string cleanCookie = cookie.Contains("JSESSIONID=") ? cookie : $"JSESSIONID={cookie}";
            using var req = new HttpRequestMessage(HttpMethod.Get, "https://xywzz.hfut.edu.cn:8443/Self/dashboard");
            req.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
            req.Headers.TryAddWithoutValidation("Referer", "https://xywzz.hfut.edu.cn:8443/Self/dashboard");
            req.Headers.TryAddWithoutValidation("Cookie", cleanCookie);

            using var resp = await _selfServiceClient.SendAsync(req);
            if (!IsCurrentAccount(accountGeneration)) return false;
            if ((int)resp.StatusCode == 301 || (int)resp.StatusCode == 302)
            {
                if (!TryUpdateForAccount(accountGeneration, () =>
                {
                    SettingsManager.Shared.SessionCookie = null;
                    SettingsManager.Shared.Save();
                })) return false;
                var (ok, _) = await SilentLoginSelfServiceAndFetchAsync(accountGeneration, sampleTime);
                return IsCurrentAccount(accountGeneration) && ok;
            }

            var html = await resp.Content.ReadAsStringAsync();
            if (!IsCurrentAccount(accountGeneration)) return false;
            if (html.Contains("欢迎登录用户自助服务系统") && !html.Contains("已用流量"))
            {
                if (!TryUpdateForAccount(accountGeneration, () =>
                {
                    SettingsManager.Shared.SessionCookie = null;
                    SettingsManager.Shared.Save();
                })) return false;
                var (ok, _) = await SilentLoginSelfServiceAndFetchAsync(accountGeneration, sampleTime);
                return IsCurrentAccount(accountGeneration) && ok;
            }

            return ApplyParsedDashboardHTML(html, accountGeneration, sampleTime);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// 强制注销指定在线设备 (dashboard/tooffline?sessionid=xxx)
    /// </summary>
    public void KickDevice(OnlineDeviceSession session, Action<bool, string> callback)
    {
        var accountGeneration = AccountSessionManager.Generation;
        Task.Run(async () =>
        {
            try
            {
                string? cookie = null;
                if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                    cookie = SettingsManager.Shared.SessionCookie?.Trim()))
                {
                    callback(false, "账号已切换");
                    return;
                }
                if (string.IsNullOrEmpty(cookie))
                {
                    callback(false, "自服务会话未就绪，请先登录自服务系统");
                    return;
                }

                string cleanCookie = cookie.Contains("JSESSIONID=") ? cookie : $"JSESSIONID={cookie}";
                var url = $"https://xywzz.hfut.edu.cn:8443/Self/dashboard/tooffline?sessionid={Uri.EscapeDataString(session.SessionId)}";
                using var req = new HttpRequestMessage(HttpMethod.Get, url);
                req.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
                req.Headers.TryAddWithoutValidation("Referer", "https://xywzz.hfut.edu.cn:8443/Self/dashboard");
                req.Headers.TryAddWithoutValidation("Cookie", cleanCookie);

                using var res = await _selfServiceClient.SendAsync(req);
                var content = await res.Content.ReadAsStringAsync();
                if (!IsCurrentAccount(accountGeneration))
                {
                    callback(false, "账号已切换");
                    return;
                }
                bool ok = res.IsSuccessStatusCode && (content.Contains("success") || content.Contains("true") || content.Contains("成功"));

                if (ok)
                {
                    if (!TryUpdateForAccount(accountGeneration, () =>
                    {
                        LatestData.OnlineDevices.RemoveAll(d => d.SessionId == session.SessionId);
                    }))
                    {
                        callback(false, "账号已切换");
                        return;
                    }
                    AppEvents.RaiseNetworkDataUpdated();
                    _ = Task.Run(async () => { try { await FetchOnlineDevicesAsync(accountGeneration); } catch { } });
                    callback(true, "设备已成功强制下线");
                }
                else
                {
                    callback(false, "下线失败，该设备可能已下线或会话已过期");
                }
            }
            catch (Exception ex)
            {
                callback(false, $"网络请求失败: {ex.Message}");
            }
        });
    }

    public void StopMonitoring()
    {
        _syncTimer?.Dispose();
        _syncTimer = null;
    }

    public void KickOnlineDevice(string sessionId, Action<bool, string> callback)
    {
        var session = LatestData.OnlineDevices.FirstOrDefault(d => d.SessionId == sessionId) ?? new OnlineDeviceSession { SessionId = sessionId };
        KickDevice(session, callback);
    }

    public bool IsManualLogout { get; set; }
    public void ClearManualLogout() => IsManualLogout = false;
    public void MarkManualLogout() => IsManualLogout = true;
    public void UpdateInterval(double seconds)
    {
        var intervalMs = (int)(Math.Max(5, seconds) * 1000);
        _syncTimer?.Change(intervalMs, intervalMs);
    }

    public bool ApplyParsedDashboardHTML(
        string html,
        long? expectedAccountGeneration = null,
        DateTime? observedAt = null)
    {
        var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
        var sampleTime = observedAt ?? CourseCalendarHelper.BeijingNow;
        bool flowSampleIsCurrentMonth = IsFlowSampleInCurrentMonth(sampleTime);
        var parsed = ParseDashboardHTML(html);
        if (parsed == null) return false;

        bool hasRealData = false;
        if (!TryUpdateForAccount(accountGeneration, () =>
        {
            if (flowSampleIsCurrentMonth && !string.IsNullOrEmpty(parsed.UsedFlow) && parsed.UsedFlow != "-- M")
            {
                LatestData.UsedFlow = parsed.UsedFlow;
                hasRealData = true;
            }
            if (flowSampleIsCurrentMonth && !string.IsNullOrEmpty(parsed.AvailableFlow) && parsed.AvailableFlow != "-- M")
            {
                LatestData.AvailableFlow = parsed.AvailableFlow;
                hasRealData = true;
            }
            if (!string.IsNullOrEmpty(parsed.Balance) && parsed.Balance != "-- 元")
            {
                LatestData.Balance = parsed.Balance;
                hasRealData = true;
            }
            if (!string.IsNullOrEmpty(parsed.FlowProtection) && parsed.FlowProtection != "--")
            {
                LatestData.FlowProtection = parsed.FlowProtection;
            }

            if (!hasRealData) return;

            LatestData.IsLoggedIn = true;
            LatestData.LastUpdated = DateTime.Now;
            LatestData.ErrorMessage = null;

            // 记录历史流量
            if (flowSampleIsCurrentMonth && !string.IsNullOrEmpty(parsed.UsedFlow))
            {
                var m = Regex.Match(parsed.UsedFlow, @"[0-9]+(?:\.[0-9]+)?");
                if (m.Success && double.TryParse(m.Value, NumberStyles.Any, CultureInfo.InvariantCulture, out double flowVal))
                {
                    if (parsed.UsedFlow.Contains("G", StringComparison.OrdinalIgnoreCase)) flowVal *= 1024.0;
                    CampusHistoryManager.Shared.RecordFlow(
                        flowVal,
                        CampusNetworkData.ParseBalanceRMB(LatestData.Balance),
                        sampleTime);
                }
            }
        })) return false;
        if (!hasRealData) return false;

        AppEvents.RaiseNetworkDataUpdated();

        // 提取在线设备
        Task.Run(async () => { try { await FetchOnlineDevicesAsync(accountGeneration); } catch { } });
        return true;
    }

    public bool ApplyExplicitDashboardData(
        string? usedFlow,
        string? availFlow,
        string? balance,
        string? protection,
        long? expectedAccountGeneration = null,
        DateTime? observedAt = null)
    {
        var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
        var sampleTime = observedAt ?? CourseCalendarHelper.BeijingNow;
        bool flowSampleIsCurrentMonth = IsFlowSampleInCurrentMonth(sampleTime);
        var actualUsedFlow = CampusNetworkData.ActualTrafficFlow(usedFlow) ?? usedFlow;
        var actualAvailableFlow = CampusNetworkData.ActualTrafficFlow(availFlow) ?? availFlow;
        bool hasRealData = false;
        if (!TryUpdateForAccount(accountGeneration, () =>
        {
            if (flowSampleIsCurrentMonth && !string.IsNullOrWhiteSpace(actualUsedFlow) && actualUsedFlow != "-- M")
            {
                LatestData.UsedFlow = actualUsedFlow;
                hasRealData = true;
            }
            if (flowSampleIsCurrentMonth && !string.IsNullOrWhiteSpace(actualAvailableFlow) && actualAvailableFlow != "-- M")
            {
                LatestData.AvailableFlow = actualAvailableFlow;
                hasRealData = true;
            }
            if (!string.IsNullOrWhiteSpace(balance) && balance != "-- 元")
            {
                LatestData.Balance = balance;
                hasRealData = true;
            }
            if (!string.IsNullOrWhiteSpace(protection) && protection != "--")
            {
                LatestData.FlowProtection = protection;
            }

            if (!hasRealData) return;

            LatestData.IsLoggedIn = true;
            LatestData.LastUpdated = DateTime.Now;
            LatestData.ErrorMessage = null;

            if (flowSampleIsCurrentMonth && !string.IsNullOrEmpty(actualUsedFlow))
            {
                var m = Regex.Match(actualUsedFlow, @"[0-9]+(?:\.[0-9]+)?");
                if (m.Success && double.TryParse(m.Value, NumberStyles.Any, CultureInfo.InvariantCulture, out double flowVal))
                {
                    if (actualUsedFlow.Contains("G", StringComparison.OrdinalIgnoreCase)) flowVal *= 1024.0;
                    CampusHistoryManager.Shared.RecordFlow(
                        flowVal,
                        CampusNetworkData.ParseBalanceRMB(LatestData.Balance),
                        sampleTime);
                }
            }
        })) return false;
        if (!hasRealData) return false;

        AppEvents.RaiseNetworkDataUpdated();

        // 提取在线设备
        Task.Run(async () => { try { await FetchOnlineDevicesAsync(accountGeneration); } catch { } });
        return true;
    }

    private static bool IsFlowSampleInCurrentMonth(DateTime observedAt)
    {
        var sampleDate = CourseCalendarHelper.DateString(observedAt);
        var currentDate = CourseCalendarHelper.DateString(CourseCalendarHelper.BeijingNow);
        return sampleDate.StartsWith(currentDate[..7], StringComparison.Ordinal);
    }

    public static CampusNetworkData? ParseDashboardHTML(string html)
    {
        if (string.IsNullOrWhiteSpace(html)) return null;

        string? usedFlow = null;
        string? availFlow = null;
        string? protection = null;
        string? balance = null;

        var targets = new (string Key, string Label, string FallbackUnit)[]
        {
            ("used", "已用流量", "M"),
            ("avail", "可用流量", "M"),
            ("prot", "消费保护", "元"),
            ("bal", "账户余额", "元")
        };

        foreach (var target in targets)
        {
            var label = target.Label;
            // 1. 优先匹配 <dt>数值</dt><dd>标签</dd> 结构
            var dlPattern1 = $@"<dt[^>]*>((?:(?!</dt>)[\s\S]){{1,1500}}?)</dt>\s*<dd[^>]*>\s*{Regex.Escape(label)}\s*</dd>";
            var dlMatch1 = Regex.Match(html, dlPattern1, RegexOptions.IgnoreCase);
            if (dlMatch1.Success)
            {
                var dtClean = Regex.Replace(dlMatch1.Groups[1].Value, "<[^>]+>", " ");
                dtClean = Regex.Replace(dtClean, @"\s+", " ").Trim();

                var valMatch = Regex.Match(dtClean, @"(-?[0-9]+(?:\.[0-9]+)?)\s*([GMK]B?|M|G|元)?");
                if (valMatch.Success)
                {
                    var num = valMatch.Groups[1].Value;
                    var unit = valMatch.Groups[2].Success && !string.IsNullOrEmpty(valMatch.Groups[2].Value) ? valMatch.Groups[2].Value : target.FallbackUnit;
                    AssignValue(target.Key, $"{num} {unit}".Trim(), ref usedFlow, ref availFlow, ref protection, ref balance);
                    continue;
                }
            }

            // 1.2 匹配反向 <dd>标签</dd><dt>数值</dt> 结构
            var dlPattern2 = $@"<dd[^>]*>\s*{Regex.Escape(label)}\s*</dd>\s*<dt[^>]*>((?:(?!</dt>)[\s\S]){{1,1500}}?)</dt>";
            var dlMatch2 = Regex.Match(html, dlPattern2, RegexOptions.IgnoreCase);
            if (dlMatch2.Success)
            {
                var dtClean = Regex.Replace(dlMatch2.Groups[1].Value, "<[^>]+>", " ");
                dtClean = Regex.Replace(dtClean, @"\s+", " ").Trim();

                var valMatch = Regex.Match(dtClean, @"(-?[0-9]+(?:\.[0-9]+)?)\s*([GMK]B?|M|G|元)?");
                if (valMatch.Success)
                {
                    var num = valMatch.Groups[1].Value;
                    var unit = valMatch.Groups[2].Success && !string.IsNullOrEmpty(valMatch.Groups[2].Value) ? valMatch.Groups[2].Value : target.FallbackUnit;
                    AssignValue(target.Key, $"{num} {unit}".Trim(), ref usedFlow, ref availFlow, ref protection, ref balance);
                    continue;
                }
            }

            // 2. 标签在前 数字在后 (同级或紧随结构，禁止跨越块级元素以防串位)
            var postPattern = $@"{Regex.Escape(label)}\s*[:：]?\s*(?:<[^>]+>|\s){{0,100}}?(-?[0-9]+(?:\.[0-9]+)?)\s*([GMK]B?|M|G|元)?";
            var postMatch = Regex.Match(html, postPattern, RegexOptions.IgnoreCase);
            if (postMatch.Success)
            {
                var num = postMatch.Groups[1].Value;
                var unit = postMatch.Groups[2].Success && !string.IsNullOrEmpty(postMatch.Groups[2].Value) ? postMatch.Groups[2].Value : target.FallbackUnit;
                AssignValue(target.Key, $"{num} {unit}".Trim(), ref usedFlow, ref availFlow, ref protection, ref balance);
                continue;
            }
        }

        if (availFlow != null || usedFlow != null || balance != null || protection != null)
        {
            return new CampusNetworkData
            {
                UsedFlow = CampusNetworkData.ActualTrafficFlow(usedFlow) ?? usedFlow ?? "-- M",
                AvailableFlow = CampusNetworkData.ActualTrafficFlow(availFlow) ?? availFlow ?? "-- M",
                FlowProtection = protection ?? "--",
                Balance = balance ?? "-- 元",
                LastUpdated = DateTime.Now
            };
        }

        return null;
    }

    private static void AssignValue(string key, string val, ref string? used, ref string? avail, ref string? prot, ref string? bal)
    {
        switch (key)
        {
            case "used": used = val; break;
            case "avail": avail = val; break;
            case "prot": prot = val; break;
            case "bal": bal = val; break;
        }
    }
}

#endregion

#region 7. 更新检查器 UpdateChecker

public sealed class UpdateChecker
{
    public static UpdateChecker Shared { get; } = new();

    public string CurrentVersion => "2.1.0";

    private readonly HttpClient _client = new() { Timeout = TimeSpan.FromSeconds(10) };

    private UpdateChecker()
    {
        _client.DefaultRequestHeaders.Add("User-Agent", "HFUTCampusNet-Windows-App");
    }

    public GitHubReleaseInfo? AvailableUpdate { get; private set; }

    public void CheckForUpdates(bool manual, Action<GitHubReleaseInfo?, string?> callback)
    {
        Task.Run(async () =>
        {
            try
            {
                var url = "https://api.github.com/repos/junpgle/HFUT-Campus-Net-Monitor/releases/latest";
                var json = await _client.GetStringAsync(url);
                using var doc = JsonDocument.Parse(json);
                var tag = doc.RootElement.GetProperty("tag_name").GetString()?.TrimStart('v') ?? "";
                var body = doc.RootElement.TryGetProperty("body", out var b) ? b.GetString() ?? "" : "";
                var htmlUrl = doc.RootElement.TryGetProperty("html_url", out var h) ? h.GetString() ?? "" : "";
                var name = doc.RootElement.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "";

                if (IsNewerVersion(tag, CurrentVersion))
                {
                    var release = new GitHubReleaseInfo
                    {
                        TagName = tag,
                        Version = tag,
                        Name = name,
                        Body = body,
                        HtmlUrl = htmlUrl
                    };
                    AvailableUpdate = release;
                    callback(release, null);
                }
                else
                {
                    AvailableUpdate = null;
                    callback(null, manual ? "当前已是最新版本" : null);
                }
            }
            catch (Exception ex)
            {
                callback(null, ex.Message);
            }
        });
    }

    private static bool IsNewerVersion(string latest, string current)
    {
        if (System.Version.TryParse(latest, out var vLatest) && System.Version.TryParse(current, out var vCur))
        {
            return vLatest > vCur;
        }
        return string.CompareOrdinal(latest, current) > 0;
    }
}

#endregion
