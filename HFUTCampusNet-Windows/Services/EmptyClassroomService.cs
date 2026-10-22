using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace HFUTCampusNet;

public sealed class EmptyClassroomService
{
    public static EmptyClassroomService Shared { get; } = new();

    private const string UniAppBaseUrl = "https://jwglapp.hfut.edu.cn";
    private const string RsaPublicKeyBase64 = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCFY5N+9UX+0BF+xz1svFguI4CIDvmQTfINkOZ1HOO3ltBNHGQTUirUPQTyEph/+q/l8b16YYw3I2fyTH6y15s3tHf5jMei+R/20jFRGo5udwVJUwq/RozKQIRzCtPYkXG4YWBnHKhXalZ5K2fhd5i/QtB016nVugH/7eiBDWbKVwIDAQAB";

    private readonly string _cacheFile;
    private readonly HttpClient _client;
    private Timer? _timer;
    private readonly SemaphoreSlim _tokenLock = new(1, 1);
    private readonly SemaphoreSlim _syncLock = new(1, 1);
    private readonly ConcurrentDictionary<string, bool> _campusSnapshotCompleteness = new();
    private List<CampusBuildingOption> _buildingCatalog = new();

    public List<ClassroomOccupationItem> CachedRooms { get; private set; } = new();
    public bool IsSyncing { get; private set; }
    public DateTime? LastSyncTime { get; private set; }
    public string FormattedLastSync()
    {
        if (!LastSyncTime.HasValue) return "上次刷新：暂未同步";
        var diff = DateTime.Now - LastSyncTime.Value;
        if (diff.TotalMinutes < 1) return $"上次刷新 {LastSyncTime.Value:HH:mm} (刚刚)";
        if (diff.TotalHours < 1) return $"上次刷新 {LastSyncTime.Value:HH:mm} ({(int)diff.TotalMinutes}分钟前)";
        return $"上次刷新 {LastSyncTime.Value:HH:mm}";
    }

    public bool IsCampusSnapshotComplete(int campusId, string dateString) =>
        _campusSnapshotCompleteness.TryGetValue($"{campusId}|{dateString}", out var isComplete) && isComplete;

    public static List<CampusBuildingOption> AllBuildings =>
        Shared._buildingCatalog.Count > 0 ? Shared._buildingCatalog : DefaultBuildings;

    public static readonly List<int> AvailableSemesters = new() { 354, 334, 314 };
    public static string SemesterTitle(int code) => CourseCalendarHelper.FormatSemesterName(code);

    // 默认校区与教学楼预设
    public static readonly List<CampusBuildingOption> DefaultBuildings = new()
    {
        // 宣城校区
        new() { CampusId = 6, BuildingId = 601, BuildingName = "新安学堂", Code = "601" },
        new() { CampusId = 6, BuildingId = 602, BuildingName = "敬亭学堂", Code = "602" },
        // 翡翠湖校区
        new() { CampusId = 3, BuildingId = 301, BuildingName = "翠一教", Code = "301" },
        new() { CampusId = 3, BuildingId = 302, BuildingName = "翠二教", Code = "302" },
        new() { CampusId = 3, BuildingId = 303, BuildingName = "翠三教", Code = "303" },
        new() { CampusId = 3, BuildingId = 304, BuildingName = "翠四教", Code = "304" },
        new() { CampusId = 3, BuildingId = 305, BuildingName = "翠五教", Code = "305" },
        new() { CampusId = 3, BuildingId = 306, BuildingName = "翠六教", Code = "306" },
        new() { CampusId = 3, BuildingId = 307, BuildingName = "翠七教", Code = "307" },
        new() { CampusId = 3, BuildingId = 308, BuildingName = "翠八教", Code = "308" },
        new() { CampusId = 3, BuildingId = 309, BuildingName = "翠九教", Code = "309" },
        new() { CampusId = 3, BuildingId = 310, BuildingName = "翠十教", Code = "310" },
        new() { CampusId = 3, BuildingId = 311, BuildingName = "翠十一教", Code = "311" },
        new() { CampusId = 3, BuildingId = 312, BuildingName = "翠十二教", Code = "312" },
        new() { CampusId = 3, BuildingId = 313, BuildingName = "翡翠科教楼", Code = "313" },
        // 屯溪路校区
        new() { CampusId = 2, BuildingId = 201, BuildingName = "主楼", Code = "201" },
        new() { CampusId = 2, BuildingId = 202, BuildingName = "东楼", Code = "202" },
        new() { CampusId = 2, BuildingId = 203, BuildingName = "西楼", Code = "203" },
        new() { CampusId = 2, BuildingId = 204, BuildingName = "西二楼", Code = "204" },
        new() { CampusId = 2, BuildingId = 205, BuildingName = "逸夫楼", Code = "205" }
    };

    private EmptyClassroomService()
    {
        var appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "HFUTCampusNet");
        Directory.CreateDirectory(appData);
        _cacheFile = Path.Combine(appData, "empty_classrooms_cache.json");

        var handler = new HttpClientHandler
        {
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
            ServerCertificateCustomValidationCallback = (_, _, _, _) => true
        };
        _client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(35) };

        LoadCache();
    }

    public void StartMonitoring()
    {
        _timer?.Dispose();
        SyncTodayAndTomorrowStudyRooms(forceRefresh: false, _ => { });
        _timer = new Timer(_ => SyncTodayAndTomorrowStudyRooms(forceRefresh: false, _ => { }), null, 30 * 60 * 1000, 30 * 60 * 1000);
    }

    public void StopMonitoring()
    {
        _timer?.Dispose();
        _timer = null;
    }

    public static string TodayDateString() => DateTime.Now.ToString("yyyy-MM-dd");
    public static string TomorrowDateString() => DateTime.Now.AddDays(1).ToString("yyyy-MM-dd");

    public static int CurrentMinutesOfDay(DateTime? dt = null)
    {
        var now = dt ?? DateTime.Now;
        return now.Hour * 60 + now.Minute;
    }

    public StudyRoomSelectionRecord? CurrentStudyRoomItem() => SettingsManager.Shared.CurrentStudyRoom;

    public void SetCurrentStudyRoom(ClassroomOccupationItem room, StudyCampus? campus = null, string? buildingCode = null, string? buildingName = null)
    {
        SettingsManager.Shared.CurrentStudyRoom = new StudyRoomSelectionRecord
        {
            RoomId = room.RoomId,
            RoomName = room.RoomName,
            CampusId = (int)(campus ?? (StudyCampus)room.CampusId),
            BuildingName = buildingName ?? room.BuildingName,
            BuildingCode = buildingCode ?? string.Empty,
            DateString = room.DateString
        };
        SettingsManager.Shared.Save();
        AppEvents.RaiseEmptyClassroomUpdated();
    }

    public void ClearCurrentStudyRoom()
    {
        SettingsManager.Shared.CurrentStudyRoom = null;
        SettingsManager.Shared.Save();
        AppEvents.RaiseEmptyClassroomUpdated();
    }

    public void ClearNextDayStudyRoom()
    {
        SettingsManager.Shared.NextDayStudyRoom = null;
        SettingsManager.Shared.Save();
        AppEvents.RaiseEmptyClassroomUpdated();
    }

    public void SetNextDayStudyRoom(ClassroomOccupationItem room)
    {
        SetNextDayStudyRoom(room, (StudyCampus)room.CampusId, room.BuildingCode, room.BuildingName, room.DateString);
    }

    public void SetNextDayStudyRoom(ClassroomOccupationItem room, StudyCampus? campus = null, string? buildingCode = null, string? buildingName = null, string? dateString = null)
    {
        SettingsManager.Shared.NextDayStudyRoom = new StudyRoomSelectionRecord
        {
            RoomId = room.RoomId,
            RoomName = room.RoomName,
            CampusId = (int)(campus ?? (StudyCampus)room.CampusId),
            BuildingName = buildingName ?? room.BuildingName,
            BuildingCode = buildingCode ?? room.BuildingCode,
            DateString = string.IsNullOrWhiteSpace(dateString) ? room.DateString : dateString
        };
        SettingsManager.Shared.Save();
        AppEvents.RaiseEmptyClassroomUpdated();
    }

    public List<ClassroomOccupationItem> RecommendedTodayAllDayFreeRooms(int limit = 6)
    {
        var today = TodayDateString();
        return CachedRooms
            .Where(r => r.DateString == today && r.IsAllDayFree)
            .Take(limit)
            .ToList();
    }

    public (RoomOccupationSlot? Conflict, bool IsOngoing, int? MinsUntil, List<ClassroomNearbyRecommendation> Recs) NearbySwitchRecommendations(
        StudyRoomSelectionRecord studyRoom, int limit = 2)
    {
        var nowMin = CurrentMinutesOfDay();
        var today = TodayDateString();
        var room = CachedRooms.FirstOrDefault(r => r.RoomId == studyRoom.RoomId && r.DateString == today);
        if (room == null)
        {
            return (null, false, null, new());
        }
        return NearbySwitchRecommendations(room, limit);
    }

    public (RoomOccupationSlot? Conflict, bool IsOngoing, int? MinsUntil, List<ClassroomNearbyRecommendation> Recs) NearbySwitchRecommendations(
        ClassroomOccupationItem room, int limit = 2)
    {
        var nowMin = CurrentMinutesOfDay();
        var today = TodayDateString();
        var recs = CachedRooms
            .Where(r => r.BuildingName == room.BuildingName && r.RoomId != room.RoomId && r.DateString == today && r.IsAllDayFree)
            .Take(limit)
            .Select(r => new ClassroomNearbyRecommendation { Room = r, Proximity = new ClassroomProximity { BadgeText = r.Floor == room.Floor ? "同楼层" : $"{r.Floor}楼" } })
            .ToList();

        var occ = room.CurrentOccupation(nowMin);
        if (occ != null)
        {
            return (occ, true, null, recs);
        }
        var next = room.NextOccupation(nowMin);
        if (next != null)
        {
            var diff = room.MinutesUntilNextOccupation(nowMin);
            if (diff.HasValue && diff.Value <= 40)
            {
                return (next, false, diff.Value, recs);
            }
        }
        return (null, false, null, recs);
    }

    public List<ClassroomOccupationItem> NearbySwitchRecommendations(
        ClassroomOccupationItem room, int startUnit, int nowMin, int limit = 4)
    {
        var today = TodayDateString();
        return CachedRooms
            .Where(r => r.BuildingName == room.BuildingName && r.RoomId != room.RoomId && r.DateString == today && !r.IsOccupiedAtPeriod(startUnit))
            .Take(limit)
            .ToList();
    }

    public List<ClassroomOccupationItem> NearbySwitchRecommendations(
        StudyRoomSelectionRecord studyRoom, int startUnit, int nowMin, int limit = 4)
    {
        var today = TodayDateString();
        var room = CachedRooms.FirstOrDefault(r => r.RoomId == studyRoom.RoomId && r.DateString == today);
        if (room == null) return new();
        return NearbySwitchRecommendations(room, startUnit, nowMin, limit);
    }

    public StudyCampus CurrentPreferredCampus => StudyCampus.Xuancheng;

    public List<ClassroomOccupationItem> CachedStudyRooms(StudyCampus campus, string dateString)
    {
        return CachedRooms.Where(r => r.DateString == dateString && r.CampusId == (int)campus).ToList();
    }

    public List<ClassroomOccupationItem> CachedBuildingRooms(string buildingCode, string dateString)
    {
        return CachedRooms
            .Where(r => r.DateString == dateString && r.BuildingCode == buildingCode)
            .ToList();
    }

    public List<ClassroomOccupationItem> CachedBuildingRooms(CampusBuildingOption building, string dateString)
    {
        var buildingCode = !string.IsNullOrWhiteSpace(building.Code)
            ? building.Code
            : building.BuildingId.ToString(CultureInfo.InvariantCulture);

        return CachedRooms
            .Where(r => r.DateString == dateString
                && r.CampusId == building.CampusId
                && (r.BuildingCode == buildingCode || r.BuildingName == building.BuildingName))
            .ToList();
    }

    public List<ClassroomOccupationItem> CachedBuildingRooms(StudyCampus campus, string buildingName, string dateString)
    {
        return CachedRooms.Where(r => r.DateString == dateString && r.CampusId == (int)campus && (string.IsNullOrEmpty(buildingName) || r.BuildingName == buildingName)).ToList();
    }

    public void FetchBuildings(Action<List<CampusBuildingOption>?, string?> callback, bool forceRefresh = false)
    {
        if (!forceRefresh && _buildingCatalog.Count > 0)
        {
            callback(_buildingCatalog, null);
            return;
        }

        Task.Run(async () =>
        {
            var token = await EnsureValidTokenAsync(forceRelogin: false);
            if (string.IsNullOrWhiteSpace(token))
            {
                callback(null, "无法获取教务系统登录凭据");
                return;
            }

            var buildings = await RequestBuildingsWithTokenAsync(token);
            if (buildings == null)
            {
                var refreshedToken = await EnsureValidTokenAsync(forceRelogin: true);
                if (!string.IsNullOrWhiteSpace(refreshedToken))
                {
                    buildings = await RequestBuildingsWithTokenAsync(refreshedToken);
                }
            }

            if (buildings == null || buildings.Count == 0)
            {
                callback(null, "拉取教学楼列表失败");
                return;
            }

            _buildingCatalog = buildings;
            callback(_buildingCatalog, null);
        });
    }

    private async Task<List<CampusBuildingOption>?> RequestBuildingsWithTokenAsync(string token)
    {
        try
        {
            var url = $"{UniAppBaseUrl}/eams-micro-server/api/v1/room/place/building?campusAssoc=";
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("Authorization", token);

            using var res = await _client.SendAsync(req);
            if (!res.IsSuccessStatusCode)
            {
                return null;
            }

            var respJson = await res.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(respJson);
            if (!doc.RootElement.TryGetProperty("data", out var buildingList) || buildingList.ValueKind != JsonValueKind.Array)
            {
                return null;
            }

            var validCampuses = StudyCampusExtensions.AllCases.Select(c => (int)c).ToHashSet();
            return buildingList.EnumerateArray()
                .Select(item =>
                {
                    var id = item.TryGetProperty("id", out var idProp) && idProp.ValueKind == JsonValueKind.Number ? idProp.GetInt32() : 0;
                    var name = item.TryGetProperty("nameZh", out var nameProp) ? nameProp.GetString() ?? string.Empty : string.Empty;
                    var campusId = item.TryGetProperty("campusAssoc", out var campusProp) && campusProp.ValueKind == JsonValueKind.Number ? campusProp.GetInt32() : 0;
                    name = name.Replace("（宣城）", string.Empty).Replace("(宣)", string.Empty).Trim();

                    return new CampusBuildingOption
                    {
                        CampusId = campusId,
                        BuildingId = id,
                        BuildingName = name,
                        Code = id.ToString(CultureInfo.InvariantCulture)
                    };
                })
                .Where(b => b.BuildingId > 0 && !string.IsNullOrWhiteSpace(b.BuildingName) && validCampuses.Contains(b.CampusId))
                .GroupBy(b => b.BuildingId)
                .Select(g => g.First())
                .OrderBy(b => b.CampusId)
                .ThenBy(b => b.BuildingName, StringComparer.Ordinal)
                .ToList();
        }
        catch
        {
            return null;
        }
    }

    public void FetchRooms(CampusBuildingOption building, string dateString, bool forceRefresh, Action<List<ClassroomOccupationItem>?, string?> callback)
    {
        SyncTodayAndTomorrowStudyRooms(building.CampusId, forceRefresh, (success, error) =>
        {
            var rooms = CachedBuildingRooms(building, dateString);
            callback(rooms, success ? null : error);
        });
    }

    private readonly ConcurrentDictionary<string, CourseScheduleData> _roomScheduleCache = new();

    public void FetchClassroomSemesterSchedule(int roomId, Action<CourseScheduleData?> callback)
    {
        Task.Run(async () =>
        {
            var sched = await FetchClassroomSemesterScheduleAsync(roomId, CourseCalendarHelper.InferSemesterId());
            callback(sched);
        });
    }

    public void FetchClassroomSemesterSchedule(ClassroomOccupationItem room, int semesterCode, bool forceRefresh, Action<CourseScheduleData?, string?> callback)
    {
        Task.Run(async () =>
        {
            var sched = await FetchClassroomSemesterScheduleAsync(room.RoomId, semesterCode, forceRefresh, room.RoomName);
            callback(sched, sched == null ? "获取教室排课失败" : null);
        });
    }

    public StudyCampus InferCampus(ClassroomOccupationItem room) => (StudyCampus)room.CampusId;

    public List<ClassroomOccupationItem> BuildTomorrowRecommendation(StudyCampus campus)
    {
        var tomorrow = TomorrowDateString();
        return CachedRooms.Where(r => r.CampusId == (int)campus && r.DateString == tomorrow && r.IsAllDayFree).Take(5).ToList();
    }

    public TomorrowStudyRecommendation? BuildTomorrowRecommendation(int limit = 3)
    {
        var tomorrow = TomorrowDateString();
        var rooms = CachedRooms.Where(r => r.DateString == tomorrow && r.IsAllDayFree).Take(limit).ToList();
        if (rooms.Count == 0) return null;
        return new TomorrowStudyRecommendation
        {
            Reason = "精选明日全天空闲自习室",
            RecommendedRooms = rooms,
            TargetBuildingCode = rooms.FirstOrDefault()?.BuildingCode ?? string.Empty,
            TargetBuildingName = rooms.FirstOrDefault()?.BuildingName ?? string.Empty,
            DateString = tomorrow
        };
    }

    // MARK: - RSA 加密与 UniApp 身份认证

    public static string? RsaEncrypt(string plainText, string publicKeyBase64)
    {
        try
        {
            var keyBytes = Convert.FromBase64String(publicKeyBase64);
            using var rsa = RSA.Create();
            rsa.ImportSubjectPublicKeyInfo(keyBytes, out _);
            var plainBytes = Encoding.UTF8.GetBytes(plainText);
            var cipherBytes = rsa.Encrypt(plainBytes, RSAEncryptionPadding.Pkcs1);
            return Convert.ToBase64String(cipherBytes);
        }
        catch
        {
            return null;
        }
    }

    public async Task<string?> EnsureValidTokenAsync(bool forceRelogin = false)
    {
        await _tokenLock.WaitAsync();
        try
        {
            if (!forceRelogin)
            {
                var savedJwt = SettingsManager.Shared.UniAppJwt?.Trim();
                if (!string.IsNullOrEmpty(savedJwt))
                {
                    return savedJwt;
                }
            }

            var username = SettingsManager.Shared.PortalUsername?.Trim();
            if (string.IsNullOrEmpty(username)) username = SettingsManager.Shared.CasUsername?.Trim();
            if (string.IsNullOrEmpty(username)) username = SettingsManager.Shared.CourseStudentId?.Trim();

            if (string.IsNullOrEmpty(username))
            {
                return null;
            }

            var candidatePasswords = await ResolveCandidatePasswordsAsync();
            if (candidatePasswords.Count == 0)
            {
                return null;
            }

            foreach (var rawPwd in candidatePasswords)
            {
                var encryptedPwd = RsaEncrypt(rawPwd, RsaPublicKeyBase64);
                if (string.IsNullOrEmpty(encryptedPwd)) continue;

                var loginUrl = $"{UniAppBaseUrl}/token/password/passwordLogin?username={Uri.EscapeDataString(username)}&password={Uri.EscapeDataString(encryptedPwd)}&appId=APP_ID&deviceId=DEVICE_ID";
                using var req = new HttpRequestMessage(HttpMethod.Post, loginUrl);
                req.Content = new ByteArrayContent(Array.Empty<byte>()); // 必须空 Body

                try
                {
                    using var res = await _client.SendAsync(req);
                    if (res.IsSuccessStatusCode)
                    {
                        var json = await res.Content.ReadAsStringAsync();
                        using var doc = JsonDocument.Parse(json);
                        if (doc.RootElement.TryGetProperty("data", out var dataObj) &&
                            dataObj.TryGetProperty("idToken", out var idTokenProp))
                        {
                            var token = idTokenProp.GetString();
                            if (!string.IsNullOrEmpty(token))
                            {
                                SettingsManager.Shared.UniAppJwt = token;
                                SettingsManager.Shared.Save();
                                return token;
                            }
                        }
                    }
                }
                catch { }
            }

            return null;
        }
        finally
        {
            _tokenLock.Release();
        }
    }

    private async Task<List<string>> ResolveCandidatePasswordsAsync()
    {
        var list = new List<string>();

        // 1. 教务 UniApp 密码主源为统一身份认证 CAS 密码
        var casPwd = SettingsManager.Shared.CasPassword?.Trim();
        if (!string.IsNullOrEmpty(casPwd) && !list.Contains(casPwd))
        {
            list.Add(casPwd);
        }

        // 2. 辅源：门户/校园网密码
        var portalPwd = SettingsManager.Shared.PortalPassword?.Trim();
        if (!string.IsNullOrEmpty(portalPwd) && !list.Contains(portalPwd))
        {
            list.Add(portalPwd);
        }

        // 3. 兜底备选：若之前缓存过教务默认密码
        if (!string.IsNullOrEmpty(SettingsManager.Shared.JxglstuDefaultPasswordCache))
        {
            var cached = SettingsManager.Shared.JxglstuDefaultPasswordCache.Trim();
            if (!list.Contains(cached))
            {
                list.Add(cached);
            }
        }
        else
        {
            // 若尚未推导过且前序密码可能未设置，尝试从教务网页端推导默认密码兜底
            var derived = await FetchJxglstuDefaultPasswordAsync();
            if (!string.IsNullOrEmpty(derived))
            {
                SettingsManager.Shared.JxglstuDefaultPasswordCache = derived;
                SettingsManager.Shared.Save();
                if (!list.Contains(derived))
                {
                    list.Add(derived);
                }
            }
        }

        return list;
    }

    private async Task<string?> FetchJxglstuDefaultPasswordAsync()
    {
        try
        {
            var stdId = SettingsManager.Shared.CourseStudentId?.Trim();
            var cookie = await CourseScheduleService.Shared.EnsureSessionAsync();
            if (string.IsNullOrEmpty(cookie))
            {
                return null;
            }

            var cleanCookie = cookie.Contains("SESSION=") ? cookie : $"SESSION={cookie}";

            // 1. 若当前 stdId 为空或为默认值，先从 /for-std/course-table 自动发现真实 stdId
            if (string.IsNullOrEmpty(stdId) || stdId == "178506")
            {
                try
                {
                    using var tableReq = new HttpRequestMessage(HttpMethod.Get, "http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table");
                    tableReq.Headers.TryAddWithoutValidation("Cookie", cleanCookie);
                    tableReq.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
                    using var tableRes = await _client.SendAsync(tableReq);
                    if (tableRes.IsSuccessStatusCode)
                    {
                        var tHtml = await tableRes.Content.ReadAsStringAsync();
                        var m = Regex.Match(tHtml, @"/for-std/course-table/info/(\d+)");
                        if (m.Success)
                        {
                            stdId = m.Groups[1].Value;
                            SettingsManager.Shared.CourseStudentId = stdId;
                            SettingsManager.Shared.Save();
                        }
                    }
                }
                catch { }
            }

            if (string.IsNullOrEmpty(stdId)) return null;

            var derived = await RequestDefaultPasswordFromInfoAsync(stdId, cleanCookie);
            if (!string.IsNullOrEmpty(derived))
            {
                return derived;
            }

            // 若第一次解析失败可能是 session 过期，强制刷新 session 重试一次
            var refreshedCookie = await CourseScheduleService.Shared.EnsureSessionAsync(forceRefresh: true);
            if (!string.IsNullOrEmpty(refreshedCookie) && refreshedCookie != cookie)
            {
                var cleanRefreshed = refreshedCookie.Contains("SESSION=") ? refreshedCookie : $"SESSION={refreshedCookie}";
                return await RequestDefaultPasswordFromInfoAsync(stdId, cleanRefreshed);
            }
        }
        catch { }

        return null;
    }

    private async Task<string?> RequestDefaultPasswordFromInfoAsync(string stdId, string cookie)
    {
        try
        {
            var url = $"http://jxglstu.hfut.edu.cn/eams5-student/for-std/student-info/info/{stdId}";
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("Cookie", cookie);
            req.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");

            using var res = await _client.SendAsync(req);
            if (!res.IsSuccessStatusCode) return null;

            var html = await res.Content.ReadAsStringAsync();
            var match = Regex.Match(html, @"证件[号|码][\s\S]{0,200}?<span[^>]*>\s*([0-9Xx]{15,18})\s*</span>");
            if (!match.Success)
            {
                match = Regex.Match(html, @"[1-9]\d{5}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx]");
            }
            if (match.Success)
            {
                var idCard = (match.Groups.Count > 1 && match.Groups[1].Success ? match.Groups[1].Value : match.Value).Trim();
                if (idCard.Length >= 6)
                {
                    var last6 = idCard[^6..];
                    return "Hfut@#$%" + last6;
                }
            }
        }
        catch { }
        return null;
    }

    // MARK: - 空教室查询核心方法

    public void SyncTodayAndTomorrowStudyRooms(bool forceRefresh = false, Action<bool>? callback = null)
    {
        SyncTodayAndTomorrowStudyRooms(null, forceRefresh, (ok, _) => callback?.Invoke(ok));
    }

    public void SyncTodayAndTomorrowStudyRooms(int? targetCampusId, bool forceRefresh, Action<bool, string?>? callback = null)
    {
        Task.Run(async () =>
        {
            PromoteOrClearNextDayStudyRoom(TodayDateString());

            if (!await _syncLock.WaitAsync(0))
            {
                callback?.Invoke(false, "正在同步中，请稍候...");
                return;
            }

            IsSyncing = true;
            AppEvents.RaiseEmptyClassroomUpdated();

            try
            {
                var today = TodayDateString();
                var tomorrow = TomorrowDateString();

                // 若未指定校区，优先同步当前自习室所在校区（宣城 6 / 翡翠湖 3 / 屯溪路 2）
                var activeCampusId = targetCampusId ?? (int)CurrentPreferredCampus;
                if (!targetCampusId.HasValue && CurrentStudyRoomItem() is { } currentStudyRoom &&
                    StudyCampusExtensions.AllCases.Contains((StudyCampus)currentStudyRoom.CampusId))
                {
                    activeCampusId = currentStudyRoom.CampusId;
                }
                var campusesToSync = targetCampusId.HasValue ? new[] { targetCampusId.Value } : new[] { activeCampusId };

                var allResults = new List<ClassroomOccupationItem>();

                foreach (var campusId in campusesToSync)
                {
                    // 并发拉取当前校区的今日与明日数据
                    var todayTask = FetchCampusRoomsAsync(campusId, today, forceRefresh);
                    var tomorrowTask = FetchCampusRoomsAsync(campusId, tomorrow, forceRefresh);

                    await Task.WhenAll(todayTask, tomorrowTask);

                    AddSnapshotOrKeepCache(campusId, today, await todayTask, allResults);
                    AddSnapshotOrKeepCache(campusId, tomorrow, await tomorrowTask, allResults);
                }

                var hasCompleteSnapshot = campusesToSync.Any(campusId =>
                    IsCampusSnapshotComplete(campusId, today)
                    || IsCampusSnapshotComplete(campusId, tomorrow));
                if (allResults.Count > 0 || hasCompleteSnapshot)
                {
                    // 将新拉取校区的数据合并进 CachedRooms，替换旧的该校区数据
                    var merged = CachedRooms.Where(r => !campusesToSync.Contains(r.CampusId)).ToList();
                    merged.AddRange(allResults);
                    CachedRooms = merged;
                    LastSyncTime = DateTime.Now;
                    SaveCache();
                    AppEvents.RaiseEmptyClassroomUpdated();
                    var incompleteCount = campusesToSync.Sum(campusId =>
                        (IsCampusSnapshotComplete(campusId, today) ? 0 : 1) +
                        (IsCampusSnapshotComplete(campusId, tomorrow) ? 0 : 1));
                    callback?.Invoke(true, incompleteCount == 0
                        ? $"成功同步 {allResults.Count} 间教室！"
                        : $"已更新 {allResults.Count} 间教室；部分分页数据未完整，食堂拥挤估算暂不可用");
                    return;
                }

                if (CachedRooms.Count > 0)
                {
                    LastSyncTime = DateTime.Now;
                    callback?.Invoke(true, "已加载本地缓存数据");
                    return;
                }

                // 兜底生成默认空教室
                var fallback = new List<ClassroomOccupationItem>();
                foreach (var c in campusesToSync)
                {
                    fallback.AddRange(GenerateDefaultClassroomCatalog(c, today));
                    fallback.AddRange(GenerateDefaultClassroomCatalog(c, tomorrow));
                }
                CachedRooms = fallback;
                LastSyncTime = DateTime.Now;
                SaveCache();
                AppEvents.RaiseEmptyClassroomUpdated();
                callback?.Invoke(false, "未从教务获取到排课，已加载基础教室列表");
            }
            catch (Exception ex)
            {
                callback?.Invoke(false, ex.Message);
            }
            finally
            {
                IsSyncing = false;
                _syncLock.Release();
                AppEvents.RaiseEmptyClassroomUpdated();
            }
        });
    }

    private static void PromoteOrClearNextDayStudyRoom(string today)
    {
        var settings = SettingsManager.Shared;
        var nextDayRoom = settings.NextDayStudyRoom;
        if (nextDayRoom == null) return;

        var comparison = string.CompareOrdinal(nextDayRoom.DateString, today);
        if (comparison == 0)
        {
            settings.CurrentStudyRoom = nextDayRoom;
        }
        if (comparison <= 0)
        {
            settings.NextDayStudyRoom = null;
            settings.Save();
            AppEvents.RaiseEmptyClassroomUpdated();
        }
    }

    private void AddSnapshotOrKeepCache(int campusId, string dateString, List<ClassroomOccupationItem> fetched, List<ClassroomOccupationItem> destination)
    {
        if (IsCampusSnapshotComplete(campusId, dateString) || !CachedRooms.Any(room => room.CampusId == campusId && room.DateString == dateString))
        {
            destination.AddRange(fetched);
            return;
        }

        destination.AddRange(CachedRooms.Where(room => room.CampusId == campusId && room.DateString == dateString));
    }

    public async Task<List<ClassroomOccupationItem>> FetchCampusRoomsAsync(int campusId, string dateStr, bool forceRefresh = false)
    {
        const int pageSize = 350;
        const int maxPages = 50;
        var cacheKey = $"{campusId}|{dateStr}";
        _campusSnapshotCompleteness[cacheKey] = false;
        var rooms = new List<ClassroomOccupationItem>();
        var seenRoomIds = new HashSet<int>();
        var isComplete = false;

        for (var page = 1; page <= maxPages; page++)
        {
            var token = await EnsureValidTokenAsync(forceRelogin: false);
            var pageRooms = string.IsNullOrEmpty(token) ? null : await RequestRoomsWithTokenAsync(token, campusId, dateStr, page);
            if (pageRooms == null)
            {
                var newToken = await EnsureValidTokenAsync(forceRelogin: true);
                if (!string.IsNullOrEmpty(newToken))
                    pageRooms = await RequestRoomsWithTokenAsync(newToken, campusId, dateStr, page);
            }

            if (pageRooms == null) break;
            var freshRooms = pageRooms.Where(room => seenRoomIds.Add(room.RoomId)).ToList();
            rooms.AddRange(freshRooms);

            if (pageRooms.Count < pageSize)
            {
                isComplete = true;
                break;
            }
            if (freshRooms.Count == 0 || page == maxPages) break;
        }

        _campusSnapshotCompleteness[cacheKey] = isComplete;
        return rooms.OrderBy(room => room.CleanBuildingName)
            .ThenBy(room => room.InferredFloor)
            .ThenBy(room => room.RoomName)
            .ToList();
    }

    private async Task<List<ClassroomOccupationItem>?> RequestRoomsWithTokenAsync(string token, int campusId, string dateStr, int currentPage)
    {
        try
        {
            var url = $"{UniAppBaseUrl}/eams-micro-server/api/v1/room/place/rooms";
            using var req = new HttpRequestMessage(HttpMethod.Post, url);
            req.Headers.TryAddWithoutValidation("Authorization", token);

            var bodyObj = new
            {
                currentPage,
                date = dateStr,
                campusAssoc = campusId,
                pageSize = 350
            };
            var jsonPayload = JsonSerializer.Serialize(bodyObj);
            req.Content = new StringContent(jsonPayload, Encoding.UTF8, "application/json");

            using var res = await _client.SendAsync(req);
            if (res.StatusCode == HttpStatusCode.Unauthorized || res.StatusCode == HttpStatusCode.Forbidden)
            {
                return null;
            }

            if (!res.IsSuccessStatusCode)
            {
                return null;
            }

            var respJson = await res.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(respJson);
            if (!doc.RootElement.TryGetProperty("data", out var dataWrapper) ||
                !dataWrapper.TryGetProperty("data", out var roomList) ||
                roomList.ValueKind != JsonValueKind.Array)
            {
                return null;
            }

            var list = new List<ClassroomOccupationItem>();

            foreach (var item in roomList.EnumerateArray())
            {
                var rid = item.TryGetProperty("id", out var idProp) ? idProp.GetInt32() : 0;
                var rname = item.TryGetProperty("nameZh", out var nzProp) ? nzProp.GetString() ?? "" : "";
                var code = item.TryGetProperty("code", out var cProp) ? cProp.GetString() ?? "" : "";
                var buildingId = item.TryGetProperty("buildingId", out var bIdProp) && bIdProp.ValueKind == JsonValueKind.Number ? bIdProp.GetInt32() : 0;
                var floor = item.TryGetProperty("floor", out var flProp) && flProp.ValueKind == JsonValueKind.Number ? flProp.GetInt32() : 1;
                var seats = item.TryGetProperty("seatsForLesson", out var seatProp) && seatProp.ValueKind == JsonValueKind.Number ? seatProp.GetInt32() : 60;

                // 解析教学楼名称
                var buildingName = ResolveBuildingName(rname, buildingId, campusId);

                // 解析占用条目
                var occupations = new List<RoomOccupationSlot>();
                if (item.TryGetProperty("roomOccupationInfoVms", out var occArr) && occArr.ValueKind == JsonValueKind.Array)
                {
                    foreach (var occ in occArr.EnumerateArray())
                    {
                        var startStr = occ.TryGetProperty("startTimeString", out var stProp) ? stProp.GetString() ?? "" : "";
                        var endStr = occ.TryGetProperty("endTimeString", out var etProp) ? etProp.GetString() ?? "" : "";
                        var actType = occ.TryGetProperty("activityType", out var atProp) ? atProp.GetString() ?? "" : "";
                        var actName = occ.TryGetProperty("activityName", out var anProp) ? anProp.GetString() ?? "" : "";
                        var teacher = occ.TryGetProperty("teacherName", out var tnProp) ? tnProp.GetString() ?? "" : "";
                        int? activityId = occ.TryGetProperty("activityId", out var activityIdProp) && activityIdProp.ValueKind == JsonValueKind.Number
                            ? activityIdProp.GetInt32()
                            : null;

                        var causeTitle = actType switch
                        {
                            "Lesson" => "课程占用",
                            "Exam" => "考试占用",
                            "Borrow" => "教室借用",
                            _ => "其他占用"
                        };

                        if (!string.IsNullOrEmpty(startStr) && !string.IsNullOrEmpty(endStr))
                        {
                            occupations.Add(new RoomOccupationSlot
                            {
                                CourseName = CleanActivityName(actName, causeTitle),
                                Teacher = teacher,
                                CauseTitle = causeTitle,
                                ActivityId = activityId,
                                ActivityType = actType,
                                ActivityName = actName,
                                StartTimeString = startStr,
                                EndTimeString = endStr,
                                TimeString = $"{startStr}~{endStr}",
                                PeriodStart = ParseTimeToPeriod(startStr, isStart: true),
                                PeriodEnd = ParseTimeToPeriod(endStr, isStart: false)
                            });
                        }
                    }
                }

                list.Add(new ClassroomOccupationItem
                {
                    RoomId = rid,
                    RoomName = rname,
                    CampusId = campusId,
                    BuildingName = buildingName,
                    BuildingCode = buildingId.ToString(),
                    Floor = floor,
                    Seats = seats,
                    DateString = dateStr,
                    Occupations = occupations
                });
            }

            // 排序：先按教学楼，再按楼层，再按房间号
            return list.OrderBy(r => r.BuildingName)
                       .ThenBy(r => r.Floor)
                       .ThenBy(r => r.RoomName)
                       .ToList();
        }
        catch
        {
            return null;
        }
    }

    public async Task<CourseScheduleData?> FetchClassroomSemesterScheduleAsync(int roomId, int semesterId, bool forceRefresh = false, string roomName = "")
    {
        string cacheKey = $"{roomId}_{semesterId}";
        if (!forceRefresh && _roomScheduleCache.TryGetValue(cacheKey, out var cachedData) && cachedData != null)
        {
            return cachedData;
        }

        try
        {
            var token = await EnsureValidTokenAsync(forceRelogin: false);
            if (string.IsNullOrEmpty(token)) return null;

            var result = await RequestClassroomSemesterScheduleWithTokenAsync(token, roomId, semesterId, roomName);
            if (result != null)
            {
                _roomScheduleCache[cacheKey] = result;
                return result;
            }

            // 若首次失败，强制重新登录刷新 Token 再试一次（对齐 macOS 逻辑）
            var refreshedToken = await EnsureValidTokenAsync(forceRelogin: true);
            if (!string.IsNullOrEmpty(refreshedToken) && refreshedToken != token)
            {
                result = await RequestClassroomSemesterScheduleWithTokenAsync(refreshedToken, roomId, semesterId, roomName);
                if (result != null)
                {
                    _roomScheduleCache[cacheKey] = result;
                    return result;
                }
            }
        }
        catch { }

        return null;
    }

    private async Task<CourseScheduleData?> RequestClassroomSemesterScheduleWithTokenAsync(string token, int roomId, int semesterId, string roomName)
    {
        try
        {
            var url = $"{UniAppBaseUrl}/eams-micro-server/api/v1/lesson/room/getLessons?semesterAssoc={semesterId}&roomAssoc={roomId}";
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("Authorization", token);

            using var res = await _client.SendAsync(req);
            if (!res.IsSuccessStatusCode) return null;

            var json = await res.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("data", out var dataArr) || dataArr.ValueKind != JsonValueKind.Array)
            {
                return null;
            }

            var lessons = new List<CourseLesson>();
            foreach (var dto in dataArr.EnumerateArray())
            {
                int lessonId = dto.TryGetProperty("id", out var idProp) ? idProp.GetInt32() : 0;
                string? rawCourseName = null;
                string? rawCourseCode = null;

                if (dto.TryGetProperty("course", out var courseObj) && courseObj.ValueKind == JsonValueKind.Object)
                {
                    if (courseObj.TryGetProperty("nameZh", out var cnZh)) rawCourseName = cnZh.GetString();
                    if (courseObj.TryGetProperty("code", out var cc)) rawCourseCode = cc.GetString();
                }

                if (string.IsNullOrWhiteSpace(rawCourseName) && dto.TryGetProperty("nameZh", out var nmZh))
                {
                    rawCourseName = nmZh.GetString();
                }
                if (string.IsNullOrWhiteSpace(rawCourseCode) && dto.TryGetProperty("code", out var cd))
                {
                    rawCourseCode = cd.GetString();
                }

                string courseName = !string.IsNullOrWhiteSpace(rawCourseName) ? rawCourseName.Trim() : "未知课程";
                string classTitle = dto.TryGetProperty("nameZh", out var nz) ? nz.GetString()?.Trim() ?? "" : "";
                int stdCount = dto.TryGetProperty("stdCount", out var sc) ? sc.GetInt32() : 0;
                string stdCountText = stdCount > 0 ? $"{stdCount}人" : "";

                string classSummary;
                if (!string.IsNullOrEmpty(classTitle) && !string.IsNullOrEmpty(stdCountText))
                    classSummary = $"{classTitle} ({stdCountText})";
                else if (!string.IsNullOrEmpty(classTitle))
                    classSummary = classTitle;
                else if (!string.IsNullOrEmpty(stdCountText))
                    classSummary = stdCountText;
                else
                    classSummary = !string.IsNullOrWhiteSpace(roomName) ? roomName : "教学班";

                string fallbackTeacher = "";
                if (dto.TryGetProperty("teacherAssignmentList", out var tList) && tList.ValueKind == JsonValueKind.Array)
                {
                    var names = new List<string>();
                    foreach (var t in tList.EnumerateArray())
                    {
                        var ts = t.GetString()?.Trim();
                        if (!string.IsNullOrEmpty(ts)) names.Add(ts);
                    }
                    fallbackTeacher = string.Join(",", names);
                }

                // 判断是否有 nested schedules 数组
                if (dto.TryGetProperty("schedules", out var schedArr) && schedArr.ValueKind == JsonValueKind.Array)
                {
                    int schedIdx = 0;
                    foreach (var sched in schedArr.EnumerateArray())
                    {
                        schedIdx++;
                        // 过滤非本教室的安排
                        if (sched.TryGetProperty("room", out var rObj) && rObj.ValueKind == JsonValueKind.Object)
                        {
                            if (rObj.TryGetProperty("id", out var rIdProp) && rIdProp.GetInt32() != 0 && rIdProp.GetInt32() != roomId)
                            {
                                continue;
                            }
                        }

                        string dateStr = sched.TryGetProperty("date", out var dProp) ? dProp.GetString() ?? "" : "";
                        int sTime = sched.TryGetProperty("startTime", out var stProp) ? stProp.GetInt32() : 800;
                        int eTime = sched.TryGetProperty("endTime", out var etProp) ? etProp.GetInt32() : 950;
                        int? weekIndex = sched.TryGetProperty("weekIndex", out var wiProp) ? wiProp.GetInt32() : null;
                        int wDay = sched.TryGetProperty("weekday", out var wdProp) ? wdProp.GetInt32() : 1;

                        if (wDay <= 0 && !string.IsNullOrEmpty(dateStr) && DateTime.TryParse(dateStr, out var parsedDate))
                        {
                            wDay = ((int)parsedDate.DayOfWeek == 0) ? 7 : (int)parsedDate.DayOfWeek;
                        }

                        string teacherStr = "";
                        if (sched.TryGetProperty("teacherName", out var tnProp)) teacherStr = tnProp.GetString()?.Trim() ?? "";
                        if (string.IsNullOrEmpty(teacherStr)) teacherStr = fallbackTeacher;

                        int calcStart = CourseLesson.CalculateStartUnit(sTime);
                        int calcEnd = CourseLesson.CalculateEndUnit(eTime, calcStart);

                        lessons.Add(new CourseLesson
                        {
                            Id = $"room-{roomId}-{lessonId}-{dateStr}-{sTime}-{schedIdx}",
                            LessonId = lessonId,
                            CourseName = courseName,
                            CourseCode = rawCourseCode,
                            Teacher = teacherStr,
                            Classroom = classSummary,
                            AdminClassText = classSummary,
                            DateString = dateStr,
                            StartTime = sTime,
                            EndTime = eTime,
                            StartUnit = calcStart,
                            EndUnit = calcEnd,
                            WeekIndex = weekIndex,
                            Weekday = wDay
                        });
                    }
                }
                else
                {
                    // 兼容旧格式或扁平结构
                    var cName = dto.TryGetProperty("courseNameZh", out var cn) ? cn.GetString() ?? courseName : courseName;
                    var tName = dto.TryGetProperty("teacherNameZh", out var tn) ? tn.GetString() ?? fallbackTeacher : fallbackTeacher;
                    var rName = dto.TryGetProperty("roomNameZh", out var rn) ? rn.GetString() ?? classSummary : classSummary;
                    var weekday = dto.TryGetProperty("weekday", out var wd) ? wd.GetInt32() : 1;
                    var startUnit = dto.TryGetProperty("startUnit", out var su) ? su.GetInt32() : 1;
                    var endUnit = dto.TryGetProperty("endUnit", out var eu) ? eu.GetInt32() : 2;

                    int sTime = startUnit switch
                    {
                        1 => 800, 2 => 855, 3 => 1010, 4 => 1105, 5 => 1400,
                        6 => 1455, 7 => 1600, 8 => 1655, 9 => 1900, 10 => 1955, _ => 800
                    };
                    int eTime = endUnit switch
                    {
                        1 => 845, 2 => 940, 3 => 1055, 4 => 1150, 5 => 1445,
                        6 => 1540, 7 => 1645, 8 => 1740, 9 => 1945, 10 => 2040, _ => 940
                    };

                    lessons.Add(new CourseLesson
                    {
                        Id = $"room-{roomId}-{lessonId}-{weekday}-{startUnit}",
                        LessonId = lessonId,
                        CourseName = cName,
                        Teacher = tName,
                        Classroom = rName,
                        AdminClassText = rName,
                        Weekday = weekday,
                        StartUnit = startUnit,
                        EndUnit = endUnit,
                        StartTime = sTime,
                        EndTime = eTime
                    });
                }
            }

            // 计算周次汇总信息
            CourseLesson.EnrichLessons(lessons);

            return new CourseScheduleData
            {
                StudentId = $"room_{roomId}",
                SemesterId = semesterId.ToString(),
                SemesterName = SemesterTitle(semesterId),
                BizTypeId = "room",
                RoomName = !string.IsNullOrWhiteSpace(roomName) ? roomName : $"教室 {roomId}",
                LastSyncTime = DateTime.Now,
                Lessons = lessons
            };
        }
        catch
        {
            return null;
        }
    }

    private static string ResolveBuildingName(string roomName, int buildingId, int campusId)
    {
        if (roomName.Contains("新安学堂")) return "新安学堂";
        if (roomName.Contains("敬亭学堂")) return "敬亭学堂";

        string[] fcPref = { "翠一教", "翠二教", "翠三教", "翠四教", "翠五教", "翠六教", "翠七教", "翠八教", "翠九教", "翠十教", "翠十一教", "翠十二教", "翡翠科教楼" };
        foreach (var b in fcPref)
        {
            if (roomName.Contains(b)) return b;
        }

        string[] txPref = { "东楼", "西楼", "主楼", "西二", "逸夫楼" };
        foreach (var b in txPref)
        {
            if (roomName.Contains(b)) return b;
        }

        if (buildingId > 0)
        {
            var match = AllBuildings.FirstOrDefault(b => b.CampusId == campusId && b.BuildingId == buildingId);
            if (match != null) return match.BuildingName;
        }

        var meta = ClassroomOccupationItem.ExtractMetadata(roomName, 0, null);
        if (!string.IsNullOrWhiteSpace(meta.Prefix))
        {
            return meta.Prefix;
        }

        return campusId switch
        {
            6 => "新安学堂",
            3 => "翠一教",
            2 => "主楼",
            _ => "教学楼"
        };
    }

    private static string CleanActivityName(string raw, string fallback)
    {
        if (string.IsNullOrWhiteSpace(raw)) return fallback;
        var text = raw;
        var prefixes = new[] { "课程：", "课程:", "考试：", "考试:", "活动名称：", "活动名称:", "借用：", "借用:", "教室借用：", "教室借用:" };
        foreach (var p in prefixes)
        {
            text = text.Replace(p, "");
        }
        text = text.Trim();
        var parenIdx = text.IndexOfAny(new[] { '(', '（', '，', ';', '；' });
        if (parenIdx > 0)
        {
            text = text[..parenIdx].Trim();
        }
        return string.IsNullOrEmpty(text) ? fallback : text;
    }

    private static int ParseTimeToPeriod(string timeStr, bool isStart)
    {
        var parts = timeStr.Split(':');
        if (parts.Length == 2 && int.TryParse(parts[0], out int h) && int.TryParse(parts[1], out int m))
        {
            int totalM = h * 60 + m;
            if (totalM <= 8 * 60 + 50) return 1;
            if (totalM <= 9 * 60 + 45) return 2;
            if (totalM <= 10 * 60 + 55) return 3;
            if (totalM <= 12 * 60) return 4;
            if (totalM <= 14 * 60 + 50) return 5;
            if (totalM <= 15 * 60 + 45) return 6;
            if (totalM <= 16 * 60 + 50) return 7;
            if (totalM <= 18 * 60) return 8;
            if (totalM <= 19 * 60 + 50) return 9;
            if (totalM <= 20 * 60 + 45) return 10;
            return 11;
        }
        return isStart ? 1 : 2;
    }

    private static List<ClassroomOccupationItem> GenerateDefaultClassroomCatalog(int campusId, string dateStr)
    {
        var list = new List<ClassroomOccupationItem>();
        var buildings = AllBuildings.Where(b => b.CampusId == campusId).ToList();
        if (buildings.Count == 0) buildings = DefaultBuildings.Take(2).ToList();

        int id = campusId * 1000;
        foreach (var b in buildings)
        {
            for (int floor = 1; floor <= 4; floor++)
            {
                for (int roomNum = 1; roomNum <= 6; roomNum++)
                {
                    var rname = $"{b.BuildingName} {floor:D1}{roomNum:D2}";
                    list.Add(new ClassroomOccupationItem
                    {
                        RoomId = id++,
                        RoomName = rname,
                        CampusId = campusId,
                        BuildingName = b.BuildingName,
                        BuildingCode = b.BuildingId.ToString(),
                        Floor = floor,
                        Seats = 80,
                        DateString = dateStr,
                        Occupations = new List<RoomOccupationSlot>()
                    });
                }
            }
        }
        return list;
    }

    private void SaveCache()
    {
        try
        {
            var json = JsonSerializer.Serialize(CachedRooms, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(_cacheFile, json, Encoding.UTF8);
        }
        catch { }
    }

    private void LoadCache()
    {
        try
        {
            if (File.Exists(_cacheFile))
            {
                var json = File.ReadAllText(_cacheFile, Encoding.UTF8);
                CachedRooms = JsonSerializer.Deserialize<List<ClassroomOccupationItem>>(json) ?? new();
                foreach (var r in CachedRooms)
                {
                    r.Floor = r.InferredFloor;
                    r.BuildingName = r.CleanBuildingName;
                }
            }
        }
        catch { }
    }
}
