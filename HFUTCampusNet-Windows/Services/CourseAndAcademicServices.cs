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

#region 1. 课程表服务 CourseScheduleService

public sealed class CourseScheduleService
{
    public static CourseScheduleService Shared { get; } = new();

    public CourseScheduleData? CurrentSchedule { get; private set; }

    private readonly string _cacheFile;
    private readonly HttpClient _client;

    private CourseScheduleService()
    {
        var appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "HFUTCampusNet");
        Directory.CreateDirectory(appData);
        _cacheFile = Path.Combine(appData, "course_schedule.json");

        var handler = new HttpClientHandler
        {
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
            ServerCertificateCustomValidationCallback = (_, _, _, _) => true
        };
        _client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(15) };

        LoadCache();
    }

    public void TryBackgroundLogin(Action<bool>? callback = null)
    {
        SyncSchedule(callback);
    }

    public void SwitchSemester(string semesterId)
    {
        SettingsManager.Shared.CourseSemesterId = semesterId;
        SettingsManager.Shared.Save();
        SyncSchedule(_ => { });
    }

    public void SwitchSemester(string semesterId, Action<CourseScheduleData?, string?>? callback)
    {
        SettingsManager.Shared.CourseSemesterId = semesterId;
        SettingsManager.Shared.Save();
        SyncSchedule(callback);
    }

    public void SyncSchedule(Action<bool>? callback = null)
    {
        Task.Run(async () =>
        {
            try
            {
                var cookie = SettingsManager.Shared.CourseSessionCookie;
                if (!string.IsNullOrEmpty(cookie))
                {
                    var data = await FetchFromEamsAsync(cookie);
                    if (data != null && data.Lessons.Count > 0)
                    {
                        CurrentSchedule = data;
                        SaveCache();
                        AppEvents.RaiseCourseScheduleUpdated();
                        callback?.Invoke(true);
                        return;
                    }
                }

                // 尝试 CAS 静默换取 SESSION
                if (!string.IsNullOrEmpty(SettingsManager.Shared.CasTgcCookie))
                {
                    var sessionCookie = await ExchangeCasTicketForEamsSessionAsync(SettingsManager.Shared.CasTgcCookie);
                    if (!string.IsNullOrEmpty(sessionCookie))
                    {
                        SettingsManager.Shared.CourseSessionCookie = sessionCookie;
                        SettingsManager.Shared.Save();
                        var data = await FetchFromEamsAsync(sessionCookie);
                        if (data != null)
                        {
                            CurrentSchedule = data;
                            SaveCache();
                            AppEvents.RaiseCourseScheduleUpdated();
                            callback?.Invoke(true);
                            return;
                        }
                    }
                }

                callback?.Invoke(false);
            }
            catch
            {
                callback?.Invoke(false);
            }
        });
    }

    public void SyncSchedule(Action<CourseScheduleData?, string?> callback)
    {
        SyncSchedule(ok =>
        {
            if (ok) callback(CurrentSchedule, null);
            else callback(null, "课表同步失败，请重新登录");
        });
    }

    public void ClearSchedule()
    {
        CurrentSchedule = null;
        SaveCache();
        AppEvents.RaiseCourseScheduleUpdated();
    }

    public void FetchAndApplyFromHTML(string html, Action<bool>? callback = null)
    {
        SyncSchedule(callback);
    }

    public void ApplyCustomSchedule(CourseScheduleData schedule)
    {
        CourseLesson.EnrichLessons(schedule.Lessons);
        CurrentSchedule = schedule;
        SaveCache();
        AppEvents.RaiseCourseScheduleUpdated();
    }

    public CourseScheduleData? ApplyDatumJSONString(string jsonString, string studentId, string semesterId, string bizTypeId)
    {
        try
        {
            var parsedLessons = ParseDatumScheduleJson(jsonString);
            if (parsedLessons.Count == 0) return null;

            CourseLesson.EnrichLessons(parsedLessons);

            if (!string.IsNullOrEmpty(studentId)) SettingsManager.Shared.CourseStudentId = studentId;
            if (!string.IsNullOrEmpty(semesterId)) SettingsManager.Shared.CourseSemesterId = semesterId;
            if (!string.IsNullOrEmpty(bizTypeId)) SettingsManager.Shared.CourseBizTypeId = bizTypeId;
            SettingsManager.Shared.Save();

            int.TryParse(semesterId, out int sIdNum);
            var schedule = new CourseScheduleData
            {
                StudentId = !string.IsNullOrEmpty(studentId) ? studentId : SettingsManager.Shared.CourseStudentId,
                SemesterId = !string.IsNullOrEmpty(semesterId) ? semesterId : SettingsManager.Shared.CourseSemesterId,
                SemesterName = CourseCalendarHelper.FormatSemesterName(sIdNum > 0 ? sIdNum : 354),
                BizTypeId = !string.IsNullOrEmpty(bizTypeId) ? bizTypeId : SettingsManager.Shared.CourseBizTypeId,
                LastSyncTime = DateTime.Now,
                Lessons = parsedLessons
            };

            CurrentSchedule = schedule;
            SaveCache();
            AppEvents.RaiseCourseScheduleUpdated();
            return schedule;
        }
        catch
        {
            return null;
        }
    }

    public async Task<string?> EnsureSessionAsync(bool forceRefresh = false)
    {
        var cookie = SettingsManager.Shared.CourseSessionCookie;
        if (!forceRefresh && !string.IsNullOrEmpty(cookie))
        {
            return cookie;
        }

        // 尝试通过 CAS TGC 换取
        var tgc = SettingsManager.Shared.CasTgcCookie;
        if (!string.IsNullOrEmpty(tgc))
        {
            var session = await ExchangeCasTicketForEamsSessionAsync(tgc);
            if (!string.IsNullOrEmpty(session))
            {
                return session;
            }
        }

        return null;
    }

    public async Task<string?> ExchangeCasTicketForEamsSessionAsync(string tgc)
    {
        try
        {
            var cookieContainer = new CookieContainer();
            cookieContainer.Add(new Cookie("CASTGC", tgc, "/", "cas.hfut.edu.cn"));
            cookieContainer.Add(new Cookie("TGC", tgc, "/cas", "cas.hfut.edu.cn"));

            var handler = new HttpClientHandler
            {
                CookieContainer = cookieContainer,
                UseCookies = true,
                AllowAutoRedirect = false, // 手动处理跨协议 (https -> http) 302 重定向
                AutomaticDecompression = DecompressionMethods.All,
                ServerCertificateCustomValidationCallback = (_, _, _, _) => true
            };
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(15) };
            client.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");

            // 1. 请求 CAS SSO 获取服务 Ticket
            var ssoUrl = "https://cas.hfut.edu.cn/cas/login?service=http%3A%2F%2Fjxglstu.hfut.edu.cn%2Feams5-student%2Fneusoft-sso%2Flogin";
            using var req1 = new HttpRequestMessage(HttpMethod.Get, ssoUrl);
            using var res1 = await client.SendAsync(req1);

            Uri? redirectUrl = null;
            if (res1.StatusCode is HttpStatusCode.Redirect or HttpStatusCode.Moved or HttpStatusCode.Found or HttpStatusCode.SeeOther)
            {
                redirectUrl = res1.Headers.Location;
            }

            if (redirectUrl == null)
            {
                return null;
            }

            // 2. 跟随重定向到教务系统 (http://jxglstu.hfut.edu.cn/eams5-student/neusoft-sso/login?ticket=ST-...)
            using var req2 = new HttpRequestMessage(HttpMethod.Get, redirectUrl);
            using var res2 = await client.SendAsync(req2);

            // 检查教务系统的 Set-Cookie（涵盖带 path 的完整 URL）
            string? sess = null;
            string? srv = null;
            var cookieUrls = new[] { redirectUrl, new Uri("http://jxglstu.hfut.edu.cn/eams5-student/"), new Uri("http://jxglstu.hfut.edu.cn/") };
            foreach (var curUri in cookieUrls)
            {
                var jxCookies = cookieContainer.GetCookies(curUri);
                foreach (Cookie c in jxCookies)
                {
                    if (c.Name.Equals("SESSION", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(c.Value)) sess = c.Value;
                    if (c.Name.Equals("SRVID", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(c.Value)) srv = c.Value;
                }
                if (!string.IsNullOrEmpty(sess)) break;
            }

            // 从 Header 兜底查找
            if (string.IsNullOrEmpty(sess))
            {
                IEnumerable<string> rawHeaders = res2.Headers.TryGetValues("Set-Cookie", out var h) ? h : Array.Empty<string>();
                foreach (var header in rawHeaders)
                {
                    if (header.Contains("SESSION="))
                    {
                        var m = Regex.Match(header, @"SESSION=([^;]+)");
                        if (m.Success) sess = m.Groups[1].Value;
                    }
                    if (header.Contains("SRVID="))
                    {
                        var m = Regex.Match(header, @"SRVID=([^;]+)");
                        if (m.Success) srv = m.Groups[1].Value;
                    }
                }
            }

            if (!string.IsNullOrEmpty(sess))
            {
                var cookieHeader = !string.IsNullOrEmpty(srv) ? $"SESSION={sess}; SRVID={srv}" : $"SESSION={sess}";
                SettingsManager.Shared.CourseSessionCookie = cookieHeader;
                SettingsManager.Shared.Save();

                // 3. 顺便访问 /for-std/course-table 自动发现真实 studentId
                try
                {
                    using var tableReq = new HttpRequestMessage(HttpMethod.Get, "http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table");
                    tableReq.Headers.TryAddWithoutValidation("Cookie", cookieHeader);
                    using var tableRes = await client.SendAsync(tableReq);
                    if (tableRes.IsSuccessStatusCode)
                    {
                        var html = await tableRes.Content.ReadAsStringAsync();
                        var match = Regex.Match(html, @"/for-std/course-table/info/(\d+)");
                        if (match.Success)
                        {
                            SettingsManager.Shared.CourseStudentId = match.Groups[1].Value;
                            SettingsManager.Shared.Save();
                        }
                    }
                }
                catch { }

                // 4. 联动推导 UniApp 密码并全量同步
                _ = Task.Run(async () =>
                {
                    try
                    {
                        await EmptyClassroomService.Shared.EnsureValidTokenAsync(forceRelogin: true);
                        AcademicService.Shared.SyncAll(silent: true);
                        EmptyClassroomService.Shared.SyncTodayAndTomorrowStudyRooms(forceRefresh: true);
                    }
                    catch { }
                });

                return cookieHeader;
            }
        }
        catch { }
        return null;
    }

    private async Task<CourseScheduleData?> FetchFromEamsAsync(string sessionCookie)
    {
        try
        {
            var semId = SettingsManager.Shared.CourseSemesterId;
            var stdId = SettingsManager.Shared.CourseStudentId;
            var bizId = SettingsManager.Shared.CourseBizTypeId;
            if (string.IsNullOrEmpty(bizId) || bizId == "2") bizId = "23";

            // 1. 如果没有真实 stdId 则先请求 /for-std/course-table 自动提取
            if (string.IsNullOrEmpty(stdId) || stdId == "178506")
            {
                using var pageReq = new HttpRequestMessage(HttpMethod.Get, "http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table");
                pageReq.Headers.TryAddWithoutValidation("Cookie", sessionCookie);
                pageReq.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
                using var pageRes = await _client.SendAsync(pageReq);
                var pageHtml = await pageRes.Content.ReadAsStringAsync();

                var stdMatch = Regex.Match(pageHtml, @"/for-std/course-table/info/(\d+)");
                if (!stdMatch.Success) stdMatch = Regex.Match(pageHtml, @"var\s+studentId\s*=\s*(\d+)");
                if (!stdMatch.Success) stdMatch = Regex.Match(pageHtml, @"/for-std/course-table/get-data\?.*dataId=(\d+)");
                if (stdMatch.Success)
                {
                    stdId = stdMatch.Groups[1].Value;
                    SettingsManager.Shared.CourseStudentId = stdId;
                }
                var semMatch = Regex.Match(pageHtml, @"semesterId\s*:\s*(\d+)");
                if (!semMatch.Success) semMatch = Regex.Match(pageHtml, @"'fileInfoAssoc'\s*:\s*null\s*,\s*'id'\s*:\s*(\d+)");
                if (semMatch.Success)
                {
                    semId = semMatch.Groups[1].Value;
                    SettingsManager.Shared.CourseSemesterId = semId;
                }
                var bizMatch = Regex.Match(pageHtml, @"bizTypeId\s*:\s*(\d+)");
                if (bizMatch.Success)
                {
                    bizId = bizMatch.Groups[1].Value;
                    SettingsManager.Shared.CourseBizTypeId = bizId;
                }
                SettingsManager.Shared.Save();
            }

            if (string.IsNullOrEmpty(stdId)) return null;

            // 2. 第一步：请求 get-data 获取 lessonIds 数组
            var getDataUrl = $"http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table/get-data?bizTypeId={bizId}&semesterId={semId}&dataId={stdId}";
            using var getReq = new HttpRequestMessage(HttpMethod.Get, getDataUrl);
            getReq.Headers.TryAddWithoutValidation("Cookie", sessionCookie);
            getReq.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
            getReq.Headers.TryAddWithoutValidation("Accept", "application/json, text/javascript, */*; q=0.01");
            using var getResp = await _client.SendAsync(getReq);
            var getJson = await getResp.Content.ReadAsStringAsync();

            var lessonIds = new List<int>();
            using (var doc = SafeParseJson(getJson))
            {
                if (doc != null && doc.RootElement.TryGetProperty("lessonIds", out var idsElem) && idsElem.ValueKind == JsonValueKind.Array)
                {
                    foreach (var item in idsElem.EnumerateArray())
                    {
                        if (item.TryGetInt32(out int idVal))
                            lessonIds.Add(idVal);
                    }
                }
            }

            if (lessonIds.Count == 0) return null;

            // 3. 第二步：请求 ws/schedule-table/datum 获取真实课程与排期
            var datumUrl = "http://jxglstu.hfut.edu.cn/eams5-student/ws/schedule-table/datum";
            using var datumReq = new HttpRequestMessage(HttpMethod.Post, datumUrl);
            datumReq.Headers.TryAddWithoutValidation("Cookie", sessionCookie);
            datumReq.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
            int.TryParse(stdId, out int stdIdInt);
            var datumBody = JsonSerializer.Serialize(new
            {
                lessonIds = lessonIds,
                studentId = stdIdInt,
                weekIndex = ""
            });
            datumReq.Content = new StringContent(datumBody, Encoding.UTF8, "application/json");

            using var datumResp = await _client.SendAsync(datumReq);
            var datumJson = await datumResp.Content.ReadAsStringAsync();

            var lessons = ParseDatumScheduleJson(datumJson);
            if (lessons.Count == 0) return null;

            int.TryParse(semId, out int sIdNum);
            return new CourseScheduleData
            {
                StudentId = stdId,
                SemesterId = semId,
                SemesterName = CourseCalendarHelper.FormatSemesterName(sIdNum > 0 ? sIdNum : 354),
                BizTypeId = bizId,
                LastSyncTime = DateTime.Now,
                Lessons = lessons
            };
        }
        catch
        {
            return null;
        }
    }

    public static JsonDocument? SafeParseJson(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var trimmed = text.TrimStart();
        if (!trimmed.StartsWith("{") && !trimmed.StartsWith("[")) return null;
        try
        {
            return JsonDocument.Parse(text);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static List<CourseLesson> ParseDatumScheduleJson(string json)
    {
        var list = new List<CourseLesson>();
        try
        {
            using var doc = SafeParseJson(json);
            if (doc == null || !doc.RootElement.TryGetProperty("result", out var resElem) || resElem.ValueKind != JsonValueKind.Object)
                return list;

            var courseMap = new Dictionary<string, (string Name, string? Code)>();
            if (resElem.TryGetProperty("lessonList", out var lessonArr) && lessonArr.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in lessonArr.EnumerateArray())
                {
                    var id = item.TryGetProperty("id", out var idElem) ? idElem.ToString() : "";
                    var name = item.TryGetProperty("courseName", out var nameElem) ? nameElem.GetString() ?? "未命名课程" : "未命名课程";
                    var code = item.TryGetProperty("code", out var codeElem) ? codeElem.GetString() : null;
                    if (!string.IsNullOrEmpty(id))
                    {
                        courseMap[id] = (name, code);
                    }
                }
            }

            if (resElem.TryGetProperty("scheduleList", out var schedArr) && schedArr.ValueKind == JsonValueKind.Array)
            {
                int idx = 0;
                foreach (var slot in schedArr.EnumerateArray())
                {
                    int lId = slot.TryGetProperty("lessonId", out var lidElem) ? lidElem.GetInt32() : 0;
                    string lIdStr = lId.ToString();
                    var courseInfo = courseMap.TryGetValue(lIdStr, out var cVal) ? cVal : ($"课程 {lId}", null);

                    string? teacher = slot.TryGetProperty("personName", out var pElem) ? pElem.GetString() : null;
                    string? room = null;
                    if (slot.TryGetProperty("room", out var roomElem) && roomElem.ValueKind == JsonValueKind.Object &&
                        roomElem.TryGetProperty("nameZh", out var rnz))
                    {
                        room = rnz.GetString();
                    }

                    int? weekIndex = slot.TryGetProperty("weekIndex", out var wiElem) && wiElem.ValueKind == JsonValueKind.Number ? wiElem.GetInt32() : null;
                    int weekday = slot.TryGetProperty("weekday", out var wdElem) && wdElem.ValueKind == JsonValueKind.Number ? wdElem.GetInt32() : 1;
                    int startTime = slot.TryGetProperty("startTime", out var stElem) && stElem.ValueKind == JsonValueKind.Number ? stElem.GetInt32() : 800;
                    int endTime = slot.TryGetProperty("endTime", out var etElem) && etElem.ValueKind == JsonValueKind.Number ? etElem.GetInt32() : 940;
                    string dateStr = slot.TryGetProperty("date", out var dtElem) ? dtElem.GetString() ?? "" : "";

                    list.Add(new CourseLesson
                    {
                        Id = $"{lId}-{dateStr}-{startTime}-{idx++}",
                        LessonId = lId,
                        CourseName = courseInfo.Name,
                        CourseCode = courseInfo.Code,
                        Teacher = teacher,
                        Classroom = room,
                        DateString = dateStr,
                        StartTime = startTime,
                        EndTime = endTime,
                        WeekIndex = weekIndex,
                        Weekday = weekday,
                        StartUnit = CourseLesson.CalculateStartUnit(startTime),
                        EndUnit = CourseLesson.CalculateEndUnit(endTime, CourseLesson.CalculateStartUnit(startTime))
                    });
                }
            }

            CourseLesson.EnrichLessons(list);
        }
        catch { }
        return list;
    }

    private void SaveCache()
    {
        try
        {
            if (CurrentSchedule == null) return;
            var json = JsonSerializer.Serialize(CurrentSchedule, new JsonSerializerOptions { WriteIndented = true });
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
                CurrentSchedule = JsonSerializer.Deserialize<CourseScheduleData>(json);
                if (CurrentSchedule?.Lessons != null && CurrentSchedule.Lessons.Count > 0)
                {
                    CourseLesson.EnrichLessons(CurrentSchedule.Lessons);
                }
            }
        }
        catch { }
    }

    public async Task<string?> DiscoverStudentIdAsync(string cookie)
    {
        try
        {
            var cleanCookie = cookie.Contains("SESSION=") ? cookie : $"SESSION={cookie}";
            using var tableReq = new HttpRequestMessage(HttpMethod.Get, "http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table");
            tableReq.Headers.TryAddWithoutValidation("Cookie", cleanCookie);
            tableReq.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
            using var tableRes = await _client.SendAsync(tableReq);
            if (tableRes.IsSuccessStatusCode)
            {
                var html = await tableRes.Content.ReadAsStringAsync();
                var m = Regex.Match(html, @"/for-std/course-table/info/(\d+)");
                if (!m.Success) m = Regex.Match(html, @"var\s+studentId\s*=\s*(\d+)");
                if (!m.Success) m = Regex.Match(html, @"/for-std/course-table/get-data\?.*dataId=(\d+)");
                if (m.Success)
                {
                    var stdId = m.Groups[1].Value;
                    SettingsManager.Shared.CourseStudentId = stdId;
                    SettingsManager.Shared.Save();
                    return stdId;
                }
            }
        }
        catch { }
        return null;
    }
}

#endregion

#region 2. 教务与培养方案服务 AcademicService

public sealed class AcademicService
{
    public static AcademicService Shared { get; } = new();

    private const string UniAppBaseUrl = "https://jwglapp.hfut.edu.cn";
    private const string EamsBaseUrl = "http://jxglstu.hfut.edu.cn/eams5-student";

    public AcademicDataSnapshot? LatestData { get; private set; }

    public int UnreadGradeCount => SettingsManager.Shared.UnreadGradeIds.Count;

    private readonly string _cacheFile;
    private readonly HttpClient _client;
    private Timer? _timer;
    private readonly SemaphoreSlim _syncLock = new(1, 1);

    private AcademicService()
    {
        var appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "HFUTCampusNet");
        Directory.CreateDirectory(appData);
        _cacheFile = Path.Combine(appData, "academic_data.json");

        var handler = new HttpClientHandler
        {
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
            ServerCertificateCustomValidationCallback = (_, _, _, _) => true
        };
        _client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(25) };

        LoadCache();
    }

    public void StartMonitoring()
    {
        _timer?.Dispose();
        Task.Delay(5000).ContinueWith(_ => SyncAll(silent: true));
        _timer = new Timer(_ => SyncAll(silent: true), null, 15 * 60 * 1000, 15 * 60 * 1000);
    }

    public void StopMonitoring()
    {
        _timer?.Dispose();
        _timer = null;
    }

    public void ClearCache()
    {
        LatestData = null;
        try { if (File.Exists(_cacheFile)) File.Delete(_cacheFile); } catch { }
        SettingsManager.Shared.NotifiedGradeIds.Clear();
        SettingsManager.Shared.UnreadGradeIds.Clear();
        SettingsManager.Shared.Save();
        AppEvents.RaiseAcademicDataUpdated();
    }

    public void MarkAllGradesAsRead()
    {
        SettingsManager.Shared.UnreadGradeIds.Clear();
        SettingsManager.Shared.Save();
        AppEvents.RaiseAcademicDataUpdated();
    }

    public void SyncAll(bool silent, Action<bool>? callback = null)
    {
        Task.Run(async () =>
        {
            if (!await _syncLock.WaitAsync(0))
            {
                callback?.Invoke(false);
                return;
            }

            try
            {
                // 通道 1：合工大教务移动端 (UniApp JWT 主源)
                var uniAppTask = FetchFromUniAppAsync();

                // 通道 2：树维教务系统网页端 (jxglstu EAMS 5.0 辅源)
                var eamsWebTask = FetchFromEamsWebAsync();

                await Task.WhenAll(uniAppTask, eamsWebTask);

                var (uniGrades, uniExams) = await uniAppTask;
                var (webGrades, webExams, webProgram, webBooks, webSurveys) = await eamsWebTask;

                // 双源合并成绩与考试
                var mergedGrades = MergeGrades(uniGrades, webGrades);
                var mergedExams = MergeExams(uniExams, webExams);

                var prevSnapshot = LatestData;

                // 若网络完全无响应且已有旧缓存，保留旧缓存
                if (mergedGrades.Count == 0 && mergedExams.Count == 0 && webProgram == null && webBooks.Count == 0)
                {
                    if (prevSnapshot != null && prevSnapshot.AllGrades.Count > 0)
                    {
                        callback?.Invoke(true);
                        return;
                    }
                }

                var studentId = SettingsManager.Shared.CourseStudentId;
                if (string.IsNullOrEmpty(studentId)) studentId = SettingsManager.Shared.PortalUsername;
                if (string.IsNullOrEmpty(studentId)) studentId = "178506";

                var newSnapshot = new AcademicDataSnapshot
                {
                    StudentId = studentId,
                    AllGrades = mergedGrades.Count > 0 ? mergedGrades : (prevSnapshot?.AllGrades ?? new()),
                    Exams = mergedExams.Count > 0 ? mergedExams : (prevSnapshot?.Exams ?? new()),
                    ProgramCompletion = webProgram ?? prevSnapshot?.ProgramCompletion,
                    Textbooks = webBooks.Count > 0 ? webBooks : (prevSnapshot?.Textbooks ?? new()),
                    Surveys = webSurveys.Count > 0 ? webSurveys : (prevSnapshot?.Surveys ?? new()),
                    LastGradesSyncTime = DateTime.Now,
                    LastExamsSyncTime = DateTime.Now
                };

                // 出分静默通知检测
                CheckNewGradesNotification(newSnapshot.AllGrades);

                LatestData = newSnapshot;
                SaveCache();
                AppEvents.RaiseAcademicDataUpdated();
                callback?.Invoke(true);
            }
            catch (Exception ex)
            {
                if (LatestData != null) LatestData.LastErrorMessage = ex.Message;
                callback?.Invoke(false);
            }
            finally
            {
                _syncLock.Release();
            }
        });
    }

    // MARK: - 通道 1：UniApp 移动端数据拉取

    private async Task<(List<GradeItem> Grades, List<ExamItem> Exams)> FetchFromUniAppAsync()
    {
        var token = await EmptyClassroomService.Shared.EnsureValidTokenAsync(forceRelogin: false);
        if (string.IsNullOrEmpty(token))
        {
            return (new(), new());
        }

        var (grades, exams, needRetry) = await RequestUniAppDataAsync(token);
        if (needRetry)
        {
            var newToken = await EmptyClassroomService.Shared.EnsureValidTokenAsync(forceRelogin: true);
            if (!string.IsNullOrEmpty(newToken))
            {
                var retried = await RequestUniAppDataAsync(newToken);
                return (retried.Grades, retried.Exams);
            }
        }

        return (grades, exams);
    }

    private async Task<(List<GradeItem> Grades, List<ExamItem> Exams, bool NeedRetry)> RequestUniAppDataAsync(string token)
    {
        var grades = new List<GradeItem>();
        var exams = new List<ExamItem>();
        bool needRetry = false;

        // 1. 请求成绩单
        try
        {
            var gradesUrl = $"{UniAppBaseUrl}/eams-micro-server/api/v1/grade/student/grades";
            using var req = new HttpRequestMessage(HttpMethod.Get, gradesUrl);
            req.Headers.TryAddWithoutValidation("Authorization", token);

            using var res = await _client.SendAsync(req);
            if (res.StatusCode == HttpStatusCode.Unauthorized || res.StatusCode == HttpStatusCode.Forbidden)
            {
                needRetry = true;
            }
            else if (res.IsSuccessStatusCode)
            {
                var json = await res.Content.ReadAsStringAsync();
                using var doc = JsonDocument.Parse(json);
                if (doc.RootElement.TryGetProperty("data", out var dataArr) && dataArr.ValueKind == JsonValueKind.Array)
                {
                    foreach (var item in dataArr.EnumerateArray())
                    {
                        var cName = item.TryGetProperty("courseNameZh", out var cn) ? cn.GetString() ?? "" : "";
                        if (string.IsNullOrWhiteSpace(cName)) continue;

                        var cCode = item.TryGetProperty("courseCode", out var cc) ? cc.GetString() ?? "" : "";
                        var lCode = item.TryGetProperty("lessonCode", out var lc) ? lc.GetString() ?? "" : "";
                        double credits = item.TryGetProperty("credits", out var cd) && cd.ValueKind == JsonValueKind.Number ? cd.GetDouble() : 0.0;
                        double? gp = item.TryGetProperty("gp", out var gpProp) && gpProp.ValueKind == JsonValueKind.Number ? gpProp.GetDouble() : null;
                        var finalGrade = item.TryGetProperty("finalGrade", out var fg) ? fg.GetString() ?? "--" : "--";
                        bool passed = !item.TryGetProperty("passed", out var ps) || ps.ValueKind != JsonValueKind.False;

                        var termName = "未知学期";
                        int? semId = null;
                        if (item.TryGetProperty("semester", out var semObj))
                        {
                            if (semObj.TryGetProperty("nameZh", out var nz)) termName = nz.GetString() ?? termName;
                            else if (semObj.TryGetProperty("name", out var n)) termName = n.GetString() ?? termName;
                            if (semObj.TryGetProperty("id", out var idProp) && idProp.ValueKind == JsonValueKind.Number) semId = idProp.GetInt32();
                        }

                        grades.Add(new GradeItem
                        {
                            Id = $"{semId}_{cCode}_{cName}",
                            TermName = termName,
                            SemesterId = semId,
                            CourseName = cName,
                            CourseCode = cCode,
                            LessonCode = lCode,
                            Credits = credits,
                            Gpa = gp,
                            ScoreText = finalGrade
                        });
                    }
                }
            }
        }
        catch { }

        // 2. 请求考试安排
        try
        {
            var examsUrl = $"{UniAppBaseUrl}/eams-micro-server/api/v1/exam/student/exam";
            using var req = new HttpRequestMessage(HttpMethod.Get, examsUrl);
            req.Headers.TryAddWithoutValidation("Authorization", token);

            using var res = await _client.SendAsync(req);
            if (res.StatusCode == HttpStatusCode.Unauthorized || res.StatusCode == HttpStatusCode.Forbidden)
            {
                needRetry = true;
            }
            else if (res.IsSuccessStatusCode)
            {
                var json = await res.Content.ReadAsStringAsync();
                using var doc = JsonDocument.Parse(json);
                if (doc.RootElement.TryGetProperty("data", out var dataArr) && dataArr.ValueKind == JsonValueKind.Array)
                {
                    foreach (var item in dataArr.EnumerateArray())
                    {
                        var cName = item.TryGetProperty("courseNameZh", out var cn) ? cn.GetString()?.Trim() ?? "" : "";
                        if (string.IsNullOrEmpty(cName)) continue;

                        var cCode = item.TryGetProperty("courseCode", out var cc) ? cc.GetString() : null;
                        var examDate = item.TryGetProperty("examDate", out var ed) ? ed.GetString()?.Trim() ?? "" : "";
                        int startInt = item.TryGetProperty("startTime", out var st) && st.ValueKind == JsonValueKind.Number ? st.GetInt32() : 0;
                        int endInt = item.TryGetProperty("endTime", out var et) && et.ValueKind == JsonValueKind.Number ? et.GetInt32() : 0;

                        var startStr = $"{startInt / 100:D2}:{startInt % 100:D2}";
                        var endStr = $"{endInt / 100:D2}:{endInt % 100:D2}";
                        var dtStr = $"{examDate} {startStr}~{endStr}";

                        var place = item.TryGetProperty("place", out var pl) ? pl.GetString()?.Trim() : null;
                        var examType = "期末考试";
                        if (item.TryGetProperty("examType", out var typeObj))
                        {
                            if (typeObj.TryGetProperty("nameZh", out var tn)) examType = tn.GetString() ?? examType;
                        }

                        exams.Add(new ExamItem
                        {
                            Id = $"{cName}_{dtStr}",
                            CourseName = cName,
                            CourseCode = cCode,
                            DateTimeString = dtStr,
                            DateString = examDate,
                            StartTimeString = startStr,
                            EndTimeString = endStr,
                            Place = place,
                            ExamType = examType
                        });
                    }
                }
            }
        }
        catch { }

        return (grades, exams, needRetry);
    }

    // MARK: - 通道 2：树维 EAMS 网页端数据拉取

    private async Task<(List<GradeItem> Grades, List<ExamItem> Exams, ProgramCompletionSummary? Program, List<CourseTextbookItem> Books, List<LessonSurveyItem> Surveys)> FetchFromEamsWebAsync()
    {
        try
        {
            var cookie = await CourseScheduleService.Shared.EnsureSessionAsync();
            if (string.IsNullOrEmpty(cookie))
            {
                return (new(), new(), null, new(), new());
            }

            var stdId = SettingsManager.Shared.CourseStudentId;
            if (string.IsNullOrEmpty(stdId) || stdId == "178506")
            {
                stdId = await CourseScheduleService.Shared.DiscoverStudentIdAsync(cookie) ?? "178506";
            }

            var gTask = FetchGradesHtmlAsync(cookie, stdId);
            var eTask = FetchExamsHtmlAsync(cookie, stdId);
            var pTask = FetchProgramCompletionAsync(cookie, stdId);

            var semId = SettingsManager.Shared.CourseSemesterId;
            var bizId = SettingsManager.Shared.CourseBizTypeId;
            var bTask = FetchTextbooksAsync(cookie, semId, bizId, stdId);
            var sTask = FetchSurveysAsync(cookie, semId, stdId);

            await Task.WhenAll(gTask, eTask, pTask, bTask, sTask);

            return (await gTask, await eTask, await pTask, await bTask, await sTask);
        }
        catch
        {
            return (new(), new(), null, new(), new());
        }
    }

    // MARK: - 数据合并算法

    private static List<GradeItem> MergeGrades(List<GradeItem> primary, List<GradeItem> secondary)
    {
        if (primary.Count == 0) return secondary;
        if (secondary.Count == 0) return primary;

        var result = new List<GradeItem>(primary);
        var existingKeys = new HashSet<string>(primary.Select(g => $"{g.TermName}|{g.CourseName}"));

        foreach (var sec in secondary)
        {
            var key = $"{sec.TermName}|{sec.CourseName}";
            if (!existingKeys.Contains(key))
            {
                result.Add(sec);
                existingKeys.Add(key);
            }
        }

        // 按学期降序排序
        return result.OrderByDescending(g => g.SemesterId ?? 0)
                     .ThenByDescending(g => g.TermName)
                     .ToList();
    }

    private static List<ExamItem> MergeExams(List<ExamItem> uniExams, List<ExamItem> webExams)
    {
        if (uniExams.Count == 0) return webExams;
        if (webExams.Count == 0) return uniExams;

        var result = new List<ExamItem>(uniExams);

        // 如果 Web 端有具体的座位号，补充进结果
        foreach (var item in result)
        {
            var match = webExams.FirstOrDefault(w => w.CourseName == item.CourseName && w.DateString == item.DateString);
            if (match != null && !string.IsNullOrEmpty(match.SeatNumber))
            {
                item.SeatNumber = match.SeatNumber;
            }
            if (match != null && string.IsNullOrEmpty(item.Place) && !string.IsNullOrEmpty(match.Place))
            {
                item.Place = match.Place;
            }
        }

        // 补充 UniApp 未包含的 Web 端排考
        var existingNames = new HashSet<string>(result.Select(e => $"{e.CourseName}_{e.DateString}"));
        foreach (var w in webExams)
        {
            var key = $"{w.CourseName}_{w.DateString}";
            if (!existingNames.Contains(key))
            {
                result.Add(w);
                existingNames.Add(key);
            }
        }

        return result.OrderBy(e => e.DateString).ThenBy(e => e.StartTimeString).ToList();
    }

    private void CheckNewGradesNotification(List<GradeItem> grades)
    {
        var notified = SettingsManager.Shared.NotifiedGradeIds;
        var unread = SettingsManager.Shared.UnreadGradeIds;
        var newOnes = new List<GradeItem>();

        foreach (var g in grades)
        {
            if (!notified.Contains(g.Id))
            {
                notified.Add(g.Id);
                unread.Add(g.Id);
                newOnes.Add(g);
            }
        }

        if (newOnes.Count > 0)
        {
            SettingsManager.Shared.NotifiedGradeIds = notified;
            SettingsManager.Shared.UnreadGradeIds = unread;
            SettingsManager.Shared.Save();

            // 发送系统通知（若开启隐藏具体分数，则只提示有新科目出分）
            if (SettingsManager.Shared.HideScoreInNotification)
            {
                NotificationHelper.Send("教务成绩更新提醒", $"检测到 {newOnes.Count} 门科目最新出分，请点击面板查看详情。");
            }
            else
            {
                var names = string.Join("、", newOnes.Take(3).Select(g => $"{g.CourseName} ({g.ScoreText})"));
                NotificationHelper.Send("教务新出分提醒", $"{names} 已录入系统。");
            }
        }
    }

    public void ApplyWebGradeAndExamHtml(string? gradeHtml, string? examHtml)
    {
        try
        {
            var webGrades = !string.IsNullOrWhiteSpace(gradeHtml) ? ParseGradesHtml(gradeHtml) : new List<GradeItem>();
            var webExams = !string.IsNullOrWhiteSpace(examHtml) ? ParseExamsHtml(examHtml) : new List<ExamItem>();

            if (webGrades.Count == 0 && webExams.Count == 0) return;

            var prevSnapshot = LatestData;
            var mergedGrades = MergeGrades(prevSnapshot?.AllGrades ?? new(), webGrades);
            var mergedExams = MergeExams(prevSnapshot?.Exams ?? new(), webExams);

            var studentId = SettingsManager.Shared.CourseStudentId;
            if (string.IsNullOrEmpty(studentId)) studentId = SettingsManager.Shared.PortalUsername;
            if (string.IsNullOrEmpty(studentId)) studentId = "178506";

            var newSnapshot = new AcademicDataSnapshot
            {
                StudentId = studentId,
                AllGrades = mergedGrades,
                Exams = mergedExams,
                ProgramCompletion = prevSnapshot?.ProgramCompletion,
                Textbooks = prevSnapshot?.Textbooks ?? new(),
                Surveys = prevSnapshot?.Surveys ?? new(),
                LastGradesSyncTime = DateTime.Now,
                LastExamsSyncTime = DateTime.Now
            };

            CheckNewGradesNotification(newSnapshot.AllGrades);
            LatestData = newSnapshot;
            SaveCache();
            AppEvents.RaiseAcademicDataUpdated();
        }
        catch { }
    }

    public static List<GradeItem> ParseGradesHtml(string html)
    {
        var list = new List<GradeItem>();
        try
        {
            var trMatches = Regex.Matches(html, @"<tr[^>]*>(.*?)</tr>", RegexOptions.Singleline);
            foreach (Match tr in trMatches)
            {
                var tdMatches = Regex.Matches(tr.Groups[1].Value, @"<td[^>]*>(.*?)</td>", RegexOptions.Singleline);
                if (tdMatches.Count >= 7)
                {
                    var term = CleanHtml(tdMatches[0].Groups[1].Value);
                    var code = CleanHtml(tdMatches[1].Groups[1].Value);
                    var name = CleanHtml(tdMatches[2].Groups[1].Value);
                    double.TryParse(CleanHtml(tdMatches[3].Groups[1].Value), NumberStyles.Float, CultureInfo.InvariantCulture, out double credits);
                    double.TryParse(CleanHtml(tdMatches[4].Groups[1].Value), NumberStyles.Float, CultureInfo.InvariantCulture, out double gpa);
                    var score = CleanHtml(tdMatches[5].Groups[1].Value);

                    if (!string.IsNullOrEmpty(name) && name != "课程名称")
                    {
                        list.Add(new GradeItem
                        {
                            Id = $"{term}|{code}|{name}",
                            TermName = term,
                            CourseCode = code,
                            CourseName = name,
                            Credits = credits,
                            Gpa = gpa > 0 ? gpa : null,
                            ScoreText = score
                        });
                    }
                }
            }
        }
        catch { }
        return list;
    }

    public static List<ExamItem> ParseExamsHtml(string html)
    {
        var list = new List<ExamItem>();
        try
        {
            var trMatches = Regex.Matches(html, @"<tr[^>]*>(.*?)</tr>", RegexOptions.Singleline);
            foreach (Match tr in trMatches)
            {
                var tdMatches = Regex.Matches(tr.Groups[1].Value, @"<td[^>]*>(.*?)</td>", RegexOptions.Singleline);
                if (tdMatches.Count >= 6)
                {
                    var name = CleanHtml(tdMatches[1].Groups[1].Value);
                    var type = CleanHtml(tdMatches[2].Groups[1].Value);
                    var dtStr = CleanHtml(tdMatches[3].Groups[1].Value); // 2026-11-05 08:30~10:30
                    var place = CleanHtml(tdMatches[4].Groups[1].Value);
                    var seat = CleanHtml(tdMatches[5].Groups[1].Value);

                    if (!string.IsNullOrEmpty(name) && dtStr.Contains('~'))
                    {
                        var parts = dtStr.Split(' ');
                        var datePart = parts[0];
                        var times = parts.Length > 1 ? parts[1].Split('~') : new[] { "08:00", "10:00" };

                        list.Add(new ExamItem
                        {
                            Id = $"{name}|{dtStr}",
                            CourseName = name,
                            ExamType = type,
                            DateTimeString = dtStr,
                            DateString = datePart,
                            StartTimeString = times[0],
                            EndTimeString = times.Length > 1 ? times[1] : "",
                            Place = place,
                            SeatNumber = seat
                        });
                    }
                }
            }
        }
        catch { }
        return list;
    }

    private async Task<List<GradeItem>> FetchGradesHtmlAsync(string cookie, string stdId)
    {
        try
        {
            var cleanCookie = cookie.Contains("SESSION=") ? cookie : $"SESSION={cookie}";
            var url = $"http://jxglstu.hfut.edu.cn/eams5-student/for-std/grade/sheet/info/{stdId}?semester=";
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("Cookie", cleanCookie);
            using var res = await _client.SendAsync(req);
            if (res.IsSuccessStatusCode)
            {
                var html = await res.Content.ReadAsStringAsync();
                return ParseGradesHtml(html);
            }
        }
        catch { }
        return new List<GradeItem>();
    }

    private async Task<List<ExamItem>> FetchExamsHtmlAsync(string cookie, string stdId)
    {
        try
        {
            var cleanCookie = cookie.Contains("SESSION=") ? cookie : $"SESSION={cookie}";
            var url = $"http://jxglstu.hfut.edu.cn/eams5-student/for-std/exam-arrange/info/{stdId}";
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("Cookie", cleanCookie);
            using var res = await _client.SendAsync(req);
            if (res.IsSuccessStatusCode)
            {
                var html = await res.Content.ReadAsStringAsync();
                return ParseExamsHtml(html);
            }
        }
        catch { }
        return new List<ExamItem>();
    }

    private async Task<ProgramCompletionSummary?> FetchProgramCompletionAsync(string cookie, string stdId)
    {
        try
        {
            var url = $"http://jxglstu.hfut.edu.cn/eams5-student/for-std/program-completion-preview/json/{stdId}";
            var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Add("Cookie", cookie);
            var json = await (await _client.SendAsync(req)).Content.ReadAsStringAsync();

            using var doc = CourseScheduleService.SafeParseJson(json);
            if (doc == null) return null;
            var root = doc.RootElement;
            var progName = root.TryGetProperty("program", out var p) && p.TryGetProperty("nameZh", out var nz) ? nz.GetString() ?? "" : "培养方案";
            double reqCred = root.TryGetProperty("requireInfo", out var rq) && rq.TryGetProperty("credits", out var rc) ? rc.GetDouble() : 165;
            double passCred = root.TryGetProperty("completionSummary", out var cs) && cs.TryGetProperty("passedCredits", out var pc) ? pc.GetDouble() : 0;
            double takeCred = cs.TryGetProperty("takingCredits", out var tc) ? tc.GetDouble() : 0;

            var modules = new List<ProgramModuleItem>();
            if (root.TryGetProperty("moduleList", out var ml))
            {
                TraverseModules(ml, 0, modules);
            }

            return new ProgramCompletionSummary
            {
                ProgramName = progName,
                RequiredCredits = reqCred,
                PassedCredits = passCred,
                TakingCredits = takeCred,
                Modules = modules
            };
        }
        catch { return null; }
    }

    private static void TraverseModules(JsonElement arr, int level, List<ProgramModuleItem> list)
    {
        foreach (var mod in arr.EnumerateArray())
        {
            var name = mod.TryGetProperty("nameZh", out var nz) ? nz.GetString() ?? "" : "";
            double req = mod.TryGetProperty("requireInfo", out var ri) && ri.TryGetProperty("credits", out var rc) ? rc.GetDouble() : 0;
            double pass = mod.TryGetProperty("completionSummary", out var cs) && cs.TryGetProperty("passedCredits", out var pc) ? pc.GetDouble() : 0;
            double take = cs.TryGetProperty("takingCredits", out var tc) ? tc.GetDouble() : 0;

            var takingNames = new List<string>();
            var unrepairedNames = new List<string>();

            if (mod.TryGetProperty("courseList", out var cl))
            {
                foreach (var c in cl.EnumerateArray())
                {
                    var cName = c.TryGetProperty("nameZh", out var cn) ? cn.GetString() ?? "" : "";
                    var resType = c.TryGetProperty("resultType", out var rt) ? rt.GetString() ?? "" : "";
                    double cr = c.TryGetProperty("credits", out var cd) ? cd.GetDouble() : 0;
                    if (resType == "TAKING") takingNames.Add($"{cName}({cr}分)");
                    else if (resType == "UNREPAIRED") unrepairedNames.Add($"{cName}({cr}分)");
                }
            }

            list.Add(new ProgramModuleItem
            {
                Id = $"{level}-{name}-{list.Count}",
                Name = name,
                Level = level,
                RequiredCredits = req,
                PassedCredits = pass,
                TakingCredits = take,
                TakingCourseNames = takingNames,
                UnrepairedCourseNames = unrepairedNames
            });

            if (mod.TryGetProperty("children", out var ch) && ch.ValueKind == JsonValueKind.Array)
            {
                TraverseModules(ch, level + 1, list);
            }
        }
    }

    private async Task<List<CourseTextbookItem>> FetchTextbooksAsync(string cookie, string semId, string bizId, string stdId)
    {
        var list = new List<CourseTextbookItem>();
        try
        {
            var url = $"http://jxglstu.hfut.edu.cn/eams5-student/for-std/lesson-textbook/get-data?bizTypeId={bizId}&semesterId={semId}&dataId={stdId}";
            var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Add("Cookie", cookie);
            var json = await (await _client.SendAsync(req)).Content.ReadAsStringAsync();

            using var doc = CourseScheduleService.SafeParseJson(json);
            if (doc != null && doc.RootElement.TryGetProperty("lessons", out var lessons))
            {
                foreach (var l in lessons.EnumerateArray())
                {
                    var cName = l.TryGetProperty("courseName", out var cn) ? cn.GetString() ?? "" : "";
                    var cCode = l.TryGetProperty("courseCode", out var cc) ? cc.GetString() ?? "" : "";
                    var lCode = l.TryGetProperty("lessonCode", out var lc) ? lc.GetString() ?? "" : "";
                    double cred = l.TryGetProperty("credits", out var cr) ? cr.GetDouble() : 0;
                    var type = l.TryGetProperty("courseType", out var ct) ? ct.GetString() ?? "" : "";
                    var exam = l.TryGetProperty("examMode", out var em) ? em.GetString() ?? "考试" : "考试";
                    var dept = l.TryGetProperty("department", out var dp) ? dp.GetString() ?? "" : "";
                    var book = l.TryGetProperty("textbook", out var tb) ? tb.GetString() ?? "" : "";

                    list.Add(new CourseTextbookItem
                    {
                        Id = $"{cCode}-{lCode}",
                        CourseName = cName,
                        CourseCode = cCode,
                        LessonCode = lCode,
                        Credits = cred,
                        CourseType = type,
                        ExamMode = exam,
                        Department = dept,
                        TextbookName = book
                    });
                }
            }
        }
        catch { }
        return list;
    }

    private async Task<List<LessonSurveyItem>> FetchSurveysAsync(string cookie, string semId, string stdId)
    {
        var list = new List<LessonSurveyItem>();
        try
        {
            var url = $"http://jxglstu.hfut.edu.cn/eams5-student/for-std/lesson-survey/{semId}/search/{stdId}";
            var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Add("Cookie", cookie);
            var json = await (await _client.SendAsync(req)).Content.ReadAsStringAsync();

            using var doc = CourseScheduleService.SafeParseJson(json);
            if (doc != null && doc.RootElement.TryGetProperty("forStdLessonSurveySearchVms", out var vms))
            {
                foreach (var vm in vms.EnumerateArray())
                {
                    var cName = vm.TryGetProperty("courseName", out var cn) ? cn.GetString() ?? "" : "";
                    var lCode = vm.TryGetProperty("lessonCode", out var lc) ? lc.GetString() ?? "" : "";
                    list.Add(new LessonSurveyItem
                    {
                        Id = lCode,
                        LessonCode = lCode,
                        CourseName = cName
                    });
                }
            }
        }
        catch { }
        return list;
    }

    private static string CleanHtml(string html)
    {
        return Regex.Replace(html, "<.*?>", "").Trim();
    }

    private void SaveCache()
    {
        try
        {
            if (LatestData == null) return;
            var json = JsonSerializer.Serialize(LatestData, new JsonSerializerOptions { WriteIndented = true });
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
                LatestData = JsonSerializer.Deserialize<AcademicDataSnapshot>(json);
            }
        }
        catch { }
    }
}

#endregion
