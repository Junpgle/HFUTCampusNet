using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace HFUTCampusNet;

public sealed class EmptyClassroomService
{
    public static EmptyClassroomService Shared { get; } = new();

    private readonly string _cacheFile;
    private readonly HttpClient _client;
    private Timer? _timer;

    public List<ClassroomOccupationItem> CachedRooms { get; private set; } = new();

    public static List<CampusBuildingOption> AllBuildings => DefaultBuildings;

    public static readonly List<int> AvailableSemesters = new() { 354, 334, 314 };
    public static string SemesterTitle(int code) => CourseCalendarHelper.FormatSemesterName(code);

    // 默认校区与教学楼预设
    public static readonly List<CampusBuildingOption> DefaultBuildings = new()
    {
        // 宣城校区
        new() { CampusId = 6, BuildingId = 601, BuildingName = "新安学堂" },
        new() { CampusId = 6, BuildingId = 602, BuildingName = "敬亭学堂" },
        // 翡翠湖校区
        new() { CampusId = 3, BuildingId = 301, BuildingName = "翠一教" },
        new() { CampusId = 3, BuildingId = 302, BuildingName = "翠二教" },
        new() { CampusId = 3, BuildingId = 303, BuildingName = "翠三教" },
        new() { CampusId = 3, BuildingId = 304, BuildingName = "翠四教" },
        new() { CampusId = 3, BuildingId = 305, BuildingName = "翠五教" },
        new() { CampusId = 3, BuildingId = 306, BuildingName = "翠六教" },
        new() { CampusId = 3, BuildingId = 307, BuildingName = "翠七教" },
        new() { CampusId = 3, BuildingId = 308, BuildingName = "翠八教" },
        new() { CampusId = 3, BuildingId = 309, BuildingName = "翠九教" },
        new() { CampusId = 3, BuildingId = 310, BuildingName = "翠十教" },
        new() { CampusId = 3, BuildingId = 311, BuildingName = "翠十一教" },
        new() { CampusId = 3, BuildingId = 312, BuildingName = "翠十二教" },
        new() { CampusId = 3, BuildingId = 313, BuildingName = "翡翠科教楼" },
        // 屯溪路校区
        new() { CampusId = 2, BuildingId = 201, BuildingName = "主楼" },
        new() { CampusId = 2, BuildingId = 202, BuildingName = "东楼" },
        new() { CampusId = 2, BuildingId = 203, BuildingName = "西楼" },
        new() { CampusId = 2, BuildingId = 204, BuildingName = "西二楼" },
        new() { CampusId = 2, BuildingId = 205, BuildingName = "逸夫楼" }
    };

    private EmptyClassroomService()
    {
        var appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "HFUTCampusNet");
        Directory.CreateDirectory(appData);
        _cacheFile = Path.Combine(appData, "empty_classrooms_cache.json");

        var handler = new HttpClientHandler
        {
            UseCookies = true,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
            ServerCertificateCustomValidationCallback = (_, _, _, _) => true
        };
        _client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(15) };

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

    public void SetNextDayStudyRoom(ClassroomOccupationItem room)
    {
        SettingsManager.Shared.NextDayStudyRoom = new StudyRoomSelectionRecord
        {
            RoomId = room.RoomId,
            RoomName = room.RoomName,
            CampusId = room.CampusId,
            BuildingName = room.BuildingName,
            DateString = room.DateString
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
        return CachedRooms.Where(r => r.DateString == dateString).ToList();
    }

    public List<ClassroomOccupationItem> CachedBuildingRooms(StudyCampus campus, string buildingName, string dateString)
    {
        return CachedRooms.Where(r => r.DateString == dateString && r.CampusId == (int)campus && (string.IsNullOrEmpty(buildingName) || r.BuildingName == buildingName)).ToList();
    }

    public void FetchRooms(CampusBuildingOption building, string dateString, bool forceRefresh, Action<List<ClassroomOccupationItem>?, string?> callback)
    {
        SyncTodayAndTomorrowStudyRooms(forceRefresh, ok =>
        {
            var rooms = CachedBuildingRooms(building.Code, dateString);
            callback(rooms, null);
        });
    }

    public void FetchClassroomSemesterSchedule(int roomId, Action<CourseScheduleData?> callback)
    {
        callback(new CourseScheduleData { SemesterName = "本学期自习室课表" });
    }

    public void FetchClassroomSemesterSchedule(ClassroomOccupationItem room, int semesterCode, bool forceRefresh, Action<CourseScheduleData?, string?> callback)
    {
        callback(new CourseScheduleData { SemesterName = SemesterTitle(semesterCode), RoomName = room.RoomName }, null);
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

    public void SetNextDayStudyRoom(ClassroomOccupationItem room, StudyCampus? campus = null, string? buildingCode = null, string? buildingName = null, string? dateString = null)
    {
        SetCurrentStudyRoom(room, campus, buildingCode, buildingName);
    }

    public void SyncTodayAndTomorrowStudyRooms(bool forceRefresh = false, Action<bool>? callback = null)
    {
        Task.Run(async () =>
        {
            try
            {
                var token = SettingsManager.Shared.UniAppJwt;
                var today = TodayDateString();

                // 示例：查询宣城校区 (campusId=6) 主力教学楼
                var rooms = await FetchCampusRoomsAsync(6, today, token);
                if (rooms.Count > 0)
                {
                    CachedRooms = rooms;
                    SaveCache();
                    AppEvents.RaiseEmptyClassroomUpdated();
                    callback(true);
                    return;
                }
                callback(false);
            }
            catch
            {
                callback(false);
            }
        });
    }

    private async Task<List<ClassroomOccupationItem>> FetchCampusRoomsAsync(int campusId, string dateStr, string? jwt)
    {
        var list = new List<ClassroomOccupationItem>();
        try
        {
            // 通过移动端接口查询空教室或树维 EAMS web 端
            var url = $"https://jwglapp.hfut.edu.cn/eams-micro-server/api/v1/classroom/empty?campusId={campusId}&date={dateStr}";
            var req = new HttpRequestMessage(HttpMethod.Get, url);
            if (!string.IsNullOrEmpty(jwt))
            {
                req.Headers.Add("Authorization", $"Bearer {jwt}");
            }
            var res = await _client.SendAsync(req);
            if (res.IsSuccessStatusCode)
            {
                var json = await res.Content.ReadAsStringAsync();
                using var doc = JsonDocument.Parse(json);
                if (doc.RootElement.TryGetProperty("data", out var dataArr) && dataArr.ValueKind == JsonValueKind.Array)
                {
                    foreach (var item in dataArr.EnumerateArray())
                    {
                        var rid = item.TryGetProperty("id", out var idProp) ? idProp.GetInt32() : 0;
                        var rname = item.TryGetProperty("name", out var nProp) ? nProp.GetString() ?? "" : "";
                        var bname = item.TryGetProperty("buildingName", out var bProp) ? bProp.GetString() ?? "" : "";
                        int seats = item.TryGetProperty("seats", out var sProp) ? sProp.GetInt32() : 60;

                        list.Add(new ClassroomOccupationItem
                        {
                            RoomId = rid,
                            RoomName = rname,
                            CampusId = campusId,
                            BuildingName = bname,
                            Seats = seats,
                            DateString = dateStr
                        });
                    }
                }
            }
        }
        catch { }

        // 如果移动端接口由于网络或未登录返回空，生成默认教室结构以供用户设定和查看
        if (list.Count == 0)
        {
            list = GenerateDefaultClassroomCatalog(campusId, dateStr);
        }

        return list;
    }

    private static List<ClassroomOccupationItem> GenerateDefaultClassroomCatalog(int campusId, string dateStr)
    {
        var list = new List<ClassroomOccupationItem>();
        var buildings = DefaultBuildings.Where(b => b.CampusId == campusId).ToList();
        if (buildings.Count == 0) buildings = DefaultBuildings.Take(2).ToList();

        int id = 1000;
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
                        Seats = 80,
                        DateString = dateStr
                    });
                }
            }
        }
        return list;
    }

    private static int PeriodToMinutes(int period, bool isStart)
    {
        return period switch
        {
            1 => isStart ? 8 * 60 : 8 * 60 + 45,
            2 => isStart ? 8 * 60 + 55 : 9 * 60 + 40,
            3 => isStart ? 10 * 60 + 10 : 10 * 60 + 55,
            4 => isStart ? 11 * 60 + 5 : 11 * 60 + 50,
            5 => isStart ? 14 * 60 : 14 * 60 + 45,
            6 => isStart ? 14 * 60 + 55 : 15 * 60 + 40,
            7 => isStart ? 16 * 60 : 16 * 60 + 45,
            8 => isStart ? 16 * 60 + 55 : 17 * 60 + 40,
            9 => isStart ? 19 * 60 : 19 * 60 + 45,
            10 => isStart ? 19 * 60 + 55 : 20 * 60 + 40,
            11 => isStart ? 20 * 60 + 50 : 21 * 60 + 35,
            _ => 12 * 60
        };
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
            }
        }
        catch { }
    }
}
