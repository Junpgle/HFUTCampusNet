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

    public static void RaiseNetworkDataUpdated() => NetworkDataUpdated?.Invoke();
    public static void RaiseSpeedUpdated(string d, string u, string c) => SpeedUpdated?.Invoke(d, u, c);
    public static void RaiseCourseScheduleUpdated() => CourseScheduleUpdated?.Invoke();
    public static void RaiseEmptyClassroomUpdated() => EmptyClassroomUpdated?.Invoke();
    public static void RaiseDormElectricityUpdated() => DormElectricityUpdated?.Invoke();
    public static void RaiseHistoryStatsUpdated() => HistoryStatsUpdated?.Invoke();
    public static void RaiseCampusCardUpdated() => CampusCardUpdated?.Invoke();
    public static void RaiseAcademicDataUpdated() => AcademicDataUpdated?.Invoke();
    public static void RaiseUpdateCheckFinished() => UpdateCheckFinished?.Invoke();

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
    public string CourseBizTypeId { get; set; } = "23";
    public string? CourseSessionCookie { get; set; }
    public bool CourseTableEnabled { get; set; } = true;
    public bool CourseShowOnWidget { get; set; } = true;

    public string? HuixinAuthToken { get; set; }
    public string? CasTgcCookie { get; set; }
    public string? UniAppJwt { get; set; }

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
                using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true);
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
        try
        {
            Directory.CreateDirectory(AppDataFolder);
            var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(SettingsFile, json, Encoding.UTF8);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[SettingsManager] Save failed: {ex.Message}");
        }
    }

    private static SettingsManager Load()
    {
        try
        {
            if (File.Exists(SettingsFile))
            {
                var json = File.ReadAllText(SettingsFile, Encoding.UTF8);
                var obj = JsonSerializer.Deserialize<SettingsManager>(json);
                if (obj != null) return obj;
            }
        }
        catch { }
        return new SettingsManager();
    }
}

#endregion

#region 3. 历史统计管理器 CampusHistoryManager

public sealed class CampusHistoryManager
{
    public static CampusHistoryManager Shared { get; } = new();

    private readonly string _historyFile;
    private readonly object _lock = new();

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
                var today = DateTime.Now.ToString("yyyy-MM-dd");
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
                var cutoff = DateTime.Now.Date.AddDays(-7).ToString("yyyy-MM-dd");
                return FlowRecords.Where(r => string.CompareOrdinal(r.DateString, cutoff) >= 0).Sum(r => r.DeltaMB);
            }
        }
    }

    public double Past7DaysFlowDailyAverageMB
    {
        get
        {
            lock (_lock)
            {
                var cutoff = DateTime.Now.Date.AddDays(-7).ToString("yyyy-MM-dd");
                var records = FlowRecords.Where(r => string.CompareOrdinal(r.DateString, cutoff) >= 0).ToList();
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
                var today = DateTime.Now.ToString("yyyy-MM-dd");
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
                var cutoff = DateTime.Now.Date.AddDays(-7).ToString("yyyy-MM-dd");
                var records = ElectricityRecords.Where(r => string.CompareOrdinal(r.DateString, cutoff) >= 0 && r.CostRMB > 0).ToList();
                return records.Count > 0 ? records.Average(r => r.CostRMB) : 1.20;
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
                var prefix = DateTime.Now.ToString("yyyy-MM");
                return FlowRecords.Where(r => r.DateString.StartsWith(prefix)).Sum(r => r.DeltaMB);
            }
        }
    }
    public string DailyResetCountdownString
    {
        get
        {
            var now = DateTime.Now;
            var endOfDay = now.Date.AddDays(1);
            var diff = endOfDay - now;
            return $"距重置 {(int)diff.TotalHours}时{diff.Minutes}分";
        }
    }
    public string MonthlyResetCountdownString
    {
        get
        {
            var now = DateTime.Now;
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
                return FlowRecords.LastOrDefault()?.BalanceRMB;
            }
        }
    }

    public int? EstimatedElectricityDaysRemaining
    {
        get
        {
            lock (_lock)
            {
                var latest = ElectricityRecords.OrderByDescending(r => r.DateString).FirstOrDefault();
                if (latest == null || latest.LatestBalanceRMB <= 0) return null;
                var avg = Math.Max(0.5, Past7DaysElectricityDailyAverageRMB);
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
                return ElectricityRecords.OrderByDescending(r => r.DateString).FirstOrDefault();
            }
        }
    }

    public List<FlowDailyRecord> GetPastDaysFlowRecords(int days = 7)
    {
        lock (_lock)
        {
            var cutoff = DateTime.Now.Date.AddDays(-days).ToString("yyyy-MM-dd");
            return FlowRecords.Where(r => string.CompareOrdinal(r.DateString, cutoff) >= 0)
                .OrderBy(r => r.DateString)
                .ToList();
        }
    }

    public List<ElectricityDailyRecord> GetPastDaysElectricityRecords(int days = 7)
    {
        lock (_lock)
        {
            var cutoff = DateTime.Now.Date.AddDays(-days).ToString("yyyy-MM-dd");
            return ElectricityRecords.Where(r => string.CompareOrdinal(r.DateString, cutoff) >= 0)
                .OrderBy(r => r.DateString)
                .ToList();
        }
    }

    public void RecordFlow(double usedMB)
    {
        lock (_lock)
        {
            var today = DateTime.Now.ToString("yyyy-MM-dd");
            var record = FlowRecords.FirstOrDefault(r => r.DateString == today);
            if (record == null)
            {
                record = new FlowDailyRecord
                {
                    DateString = today,
                    StartUsedMB = usedMB,
                    LatestUsedMB = usedMB,
                    LastUpdated = DateTime.Now
                };
                FlowRecords.Add(record);
            }
            else
            {
                if (usedMB < record.StartUsedMB) record.StartUsedMB = usedMB; // 新月重置
                record.LatestUsedMB = usedMB;
                record.LastUpdated = DateTime.Now;
            }
            Save();
        }
        AppEvents.RaiseHistoryStatsUpdated();
    }

    public void RecordElectricity(double balanceRMB, double? remainingKWh)
    {
        lock (_lock)
        {
            var today = DateTime.Now.ToString("yyyy-MM-dd");
            var record = ElectricityRecords.FirstOrDefault(r => r.DateString == today);
            if (record == null)
            {
                record = new ElectricityDailyRecord
                {
                    DateString = today,
                    StartBalanceRMB = balanceRMB,
                    LatestBalanceRMB = balanceRMB,
                    RemainingKWh = remainingKWh,
                    LastUpdated = DateTime.Now
                };
                ElectricityRecords.Add(record);
            }
            else
            {
                if (balanceRMB > record.StartBalanceRMB) record.StartBalanceRMB = balanceRMB; // 充值后调整基准
                record.LatestBalanceRMB = balanceRMB;
                record.RemainingKWh = remainingKWh;
                record.LastUpdated = DateTime.Now;
            }
            Save();
        }
        AppEvents.RaiseHistoryStatsUpdated();
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
        try
        {
            var data = new { Flow = FlowRecords, Electricity = ElectricityRecords };
            var json = JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(_historyFile, json, Encoding.UTF8);
        }
        catch { }
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_historyFile)) return;
            var json = File.ReadAllText(_historyFile, Encoding.UTF8);
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("Flow", out var flowProp))
            {
                FlowRecords = JsonSerializer.Deserialize<List<FlowDailyRecord>>(flowProp.GetRawText()) ?? new();
            }
            if (doc.RootElement.TryGetProperty("Electricity", out var elecProp))
            {
                ElectricityRecords = JsonSerializer.Deserialize<List<ElectricityDailyRecord>>(elecProp.GetRawText()) ?? new();
            }
        }
        catch { }
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
            var res = await _client.GetStringAsync("http://172.18.3.3/");
            if (res.Contains("v4ip") || res.Contains("ss5"))
            {
                var uid = ExtractVar("uid", res) ?? "";
                var v4ip = ExtractVar("v4ip", res) ?? "";
                double.TryParse(ExtractVar("flow", res), NumberStyles.Float, CultureInfo.InvariantCulture, out double flowKB);
                double.TryParse(ExtractVar("fee", res), NumberStyles.Float, CultureInfo.InvariantCulture, out double feeCent);
                int.TryParse(ExtractVar("time", res), out int timeSec);

                return (true, uid, v4ip, flowKB / 1024.0, feeCent / 100.0, timeSec / 60);
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
            var url = $"http://172.18.3.3:801/eportal/?c=Portal&a=login&callback=dr1003&login_method=1&user_account={Uri.EscapeDataString(username)}&user_password={Uri.EscapeDataString(password)}";
            var res = await _client.GetStringAsync(url);
            if (res.Contains("\"result\":1") || res.Contains("\"result\":\"1\""))
            {
                return (true, "校园网认证成功");
            }
            var msg = ExtractVar("msg", res) ?? "认证未通过";
            return (false, msg);
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

    public void Login(string? username, string? password, Action<bool, string>? callback = null)
    {
        var u = !string.IsNullOrEmpty(username) ? username : SettingsManager.Shared.PortalUsername;
        var p = !string.IsNullOrEmpty(password) ? password : SettingsManager.Shared.PortalPassword;
        if (string.IsNullOrEmpty(u) || string.IsNullOrEmpty(p))
        {
            callback?.Invoke(false, "未配置校园网认证账号或密码");
            return;
        }

        Task.Run(async () =>
        {
            var (ok, msg) = await LoginAsync(u, p);
            AppEvents.InvokeOnUI(() => callback?.Invoke(ok, msg));
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

    private CampusNetworkClient()
    {
        var handler = new HttpClientHandler
        {
            UseCookies = true,
            ServerCertificateCustomValidationCallback = (_, _, _, _) => true,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
        };
        _client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(8) };
    }

    public void StartMonitoring()
    {
        _syncTimer?.Dispose();
        FetchData();
        var intervalMs = (int)(Math.Max(30, SettingsManager.Shared.RefreshInterval) * 1000);
        _syncTimer = new Timer(_ => FetchData(), null, intervalMs, intervalMs);
    }

    public void FetchData()
    {
        Task.Run(async () =>
        {
            try
            {
                var (online, uid, ip, flowMB, fee, timeMin) = await PortalAuthService.Shared.CheckStatusAsync();
                if (online)
                {
                    LatestData.IsLoggedIn = true;
                    LatestData.UsedFlow = flowMB >= 1024 ? $"{flowMB / 1024.0:F2} G" : $"{flowMB:F0} M";
                    LatestData.Balance = $"{fee:F2} 元";
                    LatestData.AvailableFlow = $"{Math.Max(0, 200.0 * 1024.0 - flowMB):F0} M";
                    LatestData.LastUpdated = DateTime.Now;
                    LatestData.ErrorMessage = null;

                    CampusHistoryManager.Shared.RecordFlow(flowMB);
                }
                else if (SettingsManager.Shared.AutoLoginPortal && !string.IsNullOrEmpty(SettingsManager.Shared.PortalUsername))
                {
                    var (ok, _) = await PortalAuthService.Shared.LoginAsync(
                        SettingsManager.Shared.PortalUsername,
                        SettingsManager.Shared.PortalPassword);
                    if (ok)
                    {
                        FetchData();
                        return;
                    }
                    LatestData.IsLoggedIn = false;
                    LatestData.ErrorMessage = "未登录校园网";
                }
                else
                {
                    LatestData.IsLoggedIn = false;
                    LatestData.ErrorMessage = "未登录校园网";
                }
            }
            catch (Exception ex)
            {
                LatestData.ErrorMessage = ex.Message;
            }
            finally
            {
                AppEvents.RaiseNetworkDataUpdated();
            }
        });
    }

    public void KickDevice(OnlineDeviceSession session, Action<bool, string> callback)
    {
        Task.Run(async () =>
        {
            try
            {
                // 向 xywzz:8443 发送踢下线指令
                var url = $"https://xywzz.hfut.edu.cn:8443/Self/dashboard/offline?sessionId={Uri.EscapeDataString(session.SessionId)}";
                var req = new HttpRequestMessage(HttpMethod.Post, url);
                req.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
                if (!string.IsNullOrEmpty(SettingsManager.Shared.SessionCookie))
                {
                    req.Headers.Add("Cookie", SettingsManager.Shared.SessionCookie);
                }
                var res = await _client.SendAsync(req);
                var content = await res.Content.ReadAsStringAsync();
                if (res.IsSuccessStatusCode && content.Contains("success"))
                {
                    callback(true, "设备已强制下线");
                    FetchData();
                }
                else
                {
                    callback(false, "下线失败，请重新登录自服务系统后重试");
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

    public void FetchOnlineDevices(Action<bool, string>? callback = null)
    {
        FetchData();
    }

    public void KickOnlineDevice(string sessionId, Action<bool, string> callback)
    {
        var session = LatestData.OnlineDevices.FirstOrDefault(d => d.SessionId == sessionId) ?? new OnlineDeviceSession { SessionId = sessionId };
        KickDevice(session, callback);
    }

    public bool IsManualLogout { get; set; }
    public void ClearManualLogout() => IsManualLogout = false;
    public void MarkManualLogout() => IsManualLogout = true;
    public void UpdateInterval(double sec) => StartMonitoring();
    public void ApplyParsedDashboardHTML(string html) => FetchData();
}

#endregion

#region 7. 更新检查器 UpdateChecker

public sealed class UpdateChecker
{
    public static UpdateChecker Shared { get; } = new();

    public string CurrentVersion => "1.8.2";

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
