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

    public int CurrentScheduleGeneration
    {
        get
        {
            lock (_scheduleStateLock)
            {
                return _scheduleGeneration;
            }
        }
    }

    private readonly string _cacheFile;
    private readonly HttpClient _client;
    private readonly object _scheduleStateLock = new();
    private int _scheduleGeneration;

    private CourseScheduleService()
    {
        var appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "HFUTCampusNet");
        Directory.CreateDirectory(appData);
        _cacheFile = Path.Combine(appData, "course_schedule.json");

        var handler = new HttpClientHandler
        {
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
        };
        _client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(15) };

        LoadCache();
    }

    private int BeginScheduleOperation()
    {
        lock (_scheduleStateLock)
        {
            return ++_scheduleGeneration;
        }
    }

    private bool IsScheduleGenerationCurrent(int generation, long accountGeneration)
    {
        lock (_scheduleStateLock)
        {
            return generation == _scheduleGeneration &&
                AccountSessionManager.IsGenerationCurrent(accountGeneration);
        }
    }

    private bool TryUpdateCourseSettings(int? generation, long accountGeneration, Action update)
    {
        lock (_scheduleStateLock)
        {
            if (generation.HasValue && generation.Value != _scheduleGeneration) return false;
            return AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
            {
                update();
                SettingsManager.Shared.Save();
            });
        }
    }

    private bool IsSessionExchangeCurrent(int? scheduleGeneration, long accountGeneration)
    {
        return AccountSessionManager.IsGenerationCurrent(accountGeneration) &&
            (!scheduleGeneration.HasValue || IsScheduleGenerationCurrent(scheduleGeneration.Value, accountGeneration));
    }

    private bool TryApplySyncedSchedule(CourseScheduleData schedule, int generation, long accountGeneration)
    {
        EnsureSemesterOptions(schedule);
        lock (_scheduleStateLock)
        {
            if (generation != _scheduleGeneration) return false;
            return AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
            {
                CurrentSchedule = schedule;
                SaveCache();
            });
        }
    }

    private static void EnsureSemesterOptions(CourseScheduleData schedule)
    {
        var namesById = new Dictionary<int, string>();
        foreach (var option in schedule.Semesters ?? new List<SemesterOptionItem>())
        {
            if (option != null && int.TryParse(option.Id, out var semesterId) && semesterId > 0 &&
                !namesById.ContainsKey(semesterId))
            {
                namesById[semesterId] = option.NameZh;
            }
        }

        var semesterIds = new HashSet<int>(namesById.Keys);
        var latestSemesterId = CourseCalendarHelper.InferSemesterId();
        for (var offset = 0; offset < 8; offset++)
        {
            var semesterId = latestSemesterId - offset * 20;
            if (semesterId > 0) semesterIds.Add(semesterId);
        }
        if (int.TryParse(schedule.SemesterId, out var currentSemesterId) && currentSemesterId > 0)
            semesterIds.Add(currentSemesterId);

        schedule.Semesters = semesterIds
            .OrderByDescending(semesterId => semesterId)
            .Select(semesterId => new SemesterOptionItem
            {
                Id = semesterId.ToString(CultureInfo.InvariantCulture),
                NameZh = namesById.TryGetValue(semesterId, out var name) && !string.IsNullOrWhiteSpace(name)
                    ? name
                    : CourseCalendarHelper.FormatSemesterName(semesterId)
            })
            .ToList();
    }

    public void TryBackgroundLogin(Action<bool>? callback = null)
    {
        SyncSchedule(callback);
    }

    public void SwitchSemester(string semesterId)
    {
        var accountGeneration = AccountSessionManager.Generation;
        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return;
        BeginScheduleOperation();
        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
        {
            SettingsManager.Shared.CourseSemesterId = semesterId;
            SettingsManager.Shared.CourseSemesterIdManuallySelected = true;
            SettingsManager.Shared.Save();
        })) return;
        SyncSchedule(_ => { });
    }

    public void SwitchSemester(string semesterId, Action<CourseScheduleData?, string?>? callback)
    {
        var accountGeneration = AccountSessionManager.Generation;
        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration))
        {
            callback?.Invoke(null, "账号已切换");
            return;
        }
        BeginScheduleOperation();
        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
        {
            SettingsManager.Shared.CourseSemesterId = semesterId;
            SettingsManager.Shared.CourseSemesterIdManuallySelected = true;
            SettingsManager.Shared.Save();
        }))
        {
            callback?.Invoke(null, "账号已切换");
            return;
        }
        SyncSchedule(callback);
    }

    public void SyncSchedule(Action<bool>? callback = null, long? expectedAccountGeneration = null)
    {
        var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration))
        {
            callback?.Invoke(false);
            return;
        }
        var generation = BeginScheduleOperation();
        Task.Run(async () =>
        {
            try
            {
                if (!IsScheduleGenerationCurrent(generation, accountGeneration))
                {
                    callback?.Invoke(false);
                    return;
                }

                string? cookie = null;
                string? tgc = null;
                if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                {
                    cookie = SettingsManager.Shared.CourseSessionCookie;
                    tgc = SettingsManager.Shared.CasTgcCookie;
                }))
                {
                    callback?.Invoke(false);
                    return;
                }
                if (!string.IsNullOrEmpty(cookie))
                {
                    var data = await FetchFromEamsAsync(cookie, generation, accountGeneration);
                    if (data != null && TryApplySyncedSchedule(data, generation, accountGeneration))
                    {
                        AppEvents.RaiseCourseScheduleUpdated();
                        callback?.Invoke(true);
                        return;
                    }
                }

                if (!IsScheduleGenerationCurrent(generation, accountGeneration))
                {
                    callback?.Invoke(false);
                    return;
                }

                // 尝试 CAS 静默换取 SESSION
                if (!string.IsNullOrEmpty(tgc))
                {
                    var sessionCookie = await ExchangeCasTicketForEamsSessionAsync(tgc, generation, accountGeneration);
                    if (!string.IsNullOrEmpty(sessionCookie))
                    {
                        var data = await FetchFromEamsAsync(sessionCookie, generation, accountGeneration);
                        if (data != null && TryApplySyncedSchedule(data, generation, accountGeneration))
                        {
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

    public void ClearSchedule(bool clearCourseCredentials = false)
    {
        lock (_scheduleStateLock)
        {
            _scheduleGeneration++;
            CurrentSchedule = null;
            if (clearCourseCredentials)
            {
                SettingsManager.Shared.CourseSessionCookie = "";
                SettingsManager.Shared.CasTgcCookie = "";
                SettingsManager.Shared.Save();
            }
            try
            {
                if (File.Exists(_cacheFile)) File.Delete(_cacheFile);
            }
            catch { }
        }
        AppEvents.RaiseCourseScheduleUpdated();
    }

    public void FetchAndApplyFromHTML(string html, Action<bool>? callback = null)
    {
        SyncSchedule(callback);
    }

    public bool ApplyCustomSchedule(
        CourseScheduleData schedule,
        long? expectedAccountGeneration = null,
        int? expectedScheduleGeneration = null)
    {
        var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
        EnsureSemesterOptions(schedule);
        CourseLesson.EnrichLessons(schedule.Lessons);
        bool applied = false;
        lock (_scheduleStateLock)
        {
            if (expectedScheduleGeneration.HasValue && expectedScheduleGeneration.Value != _scheduleGeneration)
                return false;

            applied = AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
            {
                _scheduleGeneration++;
                CurrentSchedule = schedule;
                SaveCache();
            });
        }
        if (applied && AccountSessionManager.IsGenerationCurrent(accountGeneration))
            AppEvents.RaiseCourseScheduleUpdated();
        return applied;
    }

    public CourseScheduleData? ApplyDatumJSONString(
        string jsonString,
        string studentId,
        string semesterId,
        string bizTypeId,
        long? expectedAccountGeneration = null,
        int? expectedScheduleGeneration = null)
    {
        try
        {
            var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
            var parsedLessons = ParseDatumScheduleJson(jsonString);
            if (parsedLessons.Count == 0 && !HasValidEmptyDatumSchedule(jsonString)) return null;

            CourseLesson.EnrichLessons(parsedLessons);

            CourseScheduleData? schedule = null;
            lock (_scheduleStateLock)
            {
                if (expectedScheduleGeneration.HasValue && expectedScheduleGeneration.Value != _scheduleGeneration)
                    return null;

                if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                {
                    _scheduleGeneration++;
                    if (!string.IsNullOrEmpty(studentId)) SettingsManager.Shared.CourseStudentId = studentId;
                    if (!string.IsNullOrEmpty(semesterId) && !SettingsManager.Shared.CourseSemesterIdManuallySelected)
                        SettingsManager.Shared.CourseSemesterId = semesterId;
                    if (!string.IsNullOrEmpty(bizTypeId)) SettingsManager.Shared.CourseBizTypeId = bizTypeId;
                    SettingsManager.Shared.Save();

                    int.TryParse(semesterId, out int sIdNum);
                    schedule = new CourseScheduleData
                    {
                        StudentId = !string.IsNullOrEmpty(studentId) ? studentId : SettingsManager.Shared.CourseStudentId,
                        SemesterId = !string.IsNullOrEmpty(semesterId) ? semesterId : SettingsManager.Shared.CourseSemesterId,
                        SemesterName = CourseCalendarHelper.FormatSemesterName(
                            sIdNum > 0 ? sIdNum : CourseCalendarHelper.InferSemesterId()),
                        BizTypeId = !string.IsNullOrEmpty(bizTypeId) ? bizTypeId : SettingsManager.Shared.CourseBizTypeId,
                        LastSyncTime = DateTime.Now,
                        Lessons = parsedLessons
                    };
                    EnsureSemesterOptions(schedule);

                    CurrentSchedule = schedule;
                    SaveCache();
                })) return null;
            }
            if (schedule == null) return null;
            AppEvents.RaiseCourseScheduleUpdated();
            return schedule;
        }
        catch
        {
            return null;
        }
    }

    public async Task<string?> EnsureSessionAsync(bool forceRefresh = false, long? expectedAccountGeneration = null)
    {
        var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return null;
        string? cookie = null;
        string? tgc = null;
        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
        {
            cookie = SettingsManager.Shared.CourseSessionCookie;
            tgc = SettingsManager.Shared.CasTgcCookie;
        })) return null;
        if (!forceRefresh && !string.IsNullOrEmpty(cookie))
        {
            return cookie;
        }

        // 尝试通过 CAS TGC 换取
        if (!string.IsNullOrEmpty(tgc))
        {
            var session = await ExchangeCasTicketForEamsSessionAsync(
                tgc,
                scheduleGeneration: null,
                accountGeneration: accountGeneration);
            if (AccountSessionManager.IsGenerationCurrent(accountGeneration) && !string.IsNullOrEmpty(session))
            {
                return session;
            }
        }

        return null;
    }

    public Task<string?> ExchangeCasTicketForEamsSessionAsync(string tgc, long? expectedAccountGeneration = null)
    {
        var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration))
            return Task.FromResult<string?>(null);
        return ExchangeCasTicketForEamsSessionAsync(tgc, BeginScheduleOperation(), accountGeneration);
    }

    private async Task<string?> ExchangeCasTicketForEamsSessionAsync(string tgc, int? scheduleGeneration, long accountGeneration)
    {
        if (!IsSessionExchangeCurrent(scheduleGeneration, accountGeneration)) return null;
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
                AutomaticDecompression = DecompressionMethods.All
            };
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(15) };
            client.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");

            // 1. 请求 CAS SSO 获取服务 Ticket
            var ssoUrl = "https://cas.hfut.edu.cn/cas/login?service=http%3A%2F%2Fjxglstu.hfut.edu.cn%2Feams5-student%2Fneusoft-sso%2Flogin";
            using var req1 = new HttpRequestMessage(HttpMethod.Get, ssoUrl);
            using var res1 = await client.SendAsync(req1);
            if (!IsSessionExchangeCurrent(scheduleGeneration, accountGeneration)) return null;

            Uri? redirectUrl = null;
            if (res1.StatusCode is HttpStatusCode.Redirect or HttpStatusCode.Moved or HttpStatusCode.Found or HttpStatusCode.SeeOther)
            {
                redirectUrl = res1.Headers.Location;
            }

            if (redirectUrl == null)
            {
                return null;
            }
            if (!redirectUrl.IsAbsoluteUri ||
                !(redirectUrl.Scheme.Equals("http", StringComparison.OrdinalIgnoreCase) ||
                  redirectUrl.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase)) ||
                !redirectUrl.Host.Equals("jxglstu.hfut.edu.cn", StringComparison.OrdinalIgnoreCase) ||
                !redirectUrl.AbsolutePath.Equals("/eams5-student/neusoft-sso/login", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            // 2. 跟随重定向到教务系统 (http://jxglstu.hfut.edu.cn/eams5-student/neusoft-sso/login?ticket=ST-...)
            using var req2 = new HttpRequestMessage(HttpMethod.Get, redirectUrl);
            using var res2 = await client.SendAsync(req2);
            if (!IsSessionExchangeCurrent(scheduleGeneration, accountGeneration)) return null;

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
                if (!TryUpdateCourseSettings(scheduleGeneration, accountGeneration, () =>
                    SettingsManager.Shared.CourseSessionCookie = cookieHeader)) return null;

                // 3. 顺便访问 /for-std/course-table 自动发现真实 studentId
                try
                {
                    using var tableReq = new HttpRequestMessage(HttpMethod.Get, "http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table");
                    tableReq.Headers.TryAddWithoutValidation("Cookie", cookieHeader);
                    using var tableRes = await client.SendAsync(tableReq);
                    if (!IsSessionExchangeCurrent(scheduleGeneration, accountGeneration)) return null;
                    if (tableRes.IsSuccessStatusCode)
                    {
                        var html = await tableRes.Content.ReadAsStringAsync();
                        if (!IsSessionExchangeCurrent(scheduleGeneration, accountGeneration)) return null;
                        var match = Regex.Match(html, @"/for-std/course-table/info/(\d+)");
                        if (match.Success)
                        {
                            if (!TryUpdateCourseSettings(scheduleGeneration, accountGeneration, () =>
                                SettingsManager.Shared.CourseStudentId = match.Groups[1].Value)) return null;
                        }
                    }
                }
                catch { }

                if (!IsSessionExchangeCurrent(scheduleGeneration, accountGeneration)) return null;

                if (scheduleGeneration.HasValue)
                {
                    // 4. 课表登录流程完成后联动推导 UniApp 密码并同步其他校园数据
                    _ = Task.Run(async () =>
                    {
                        try
                        {
                            if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return;
                            await EmptyClassroomService.Shared.EnsureValidTokenAsync(
                                forceRelogin: true,
                                expectedAccountGeneration: accountGeneration);
                            AcademicService.Shared.SyncAll(silent: true, expectedAccountGeneration: accountGeneration);
                            EmptyClassroomService.Shared.SyncTodayAndTomorrowStudyRooms(forceRefresh: true);
                        }
                        catch { }
                    });
                }

                return cookieHeader;
            }
        }
        catch { }
        return null;
    }

    private async Task<CourseScheduleData?> FetchFromEamsAsync(string sessionCookie, int scheduleGeneration, long accountGeneration)
    {
        if (!IsScheduleGenerationCurrent(scheduleGeneration, accountGeneration)) return null;
        try
        {
            string semId = string.Empty;
            string stdId = string.Empty;
            string bizId = string.Empty;
            if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
            {
                semId = SettingsManager.Shared.CourseSemesterId;
                stdId = SettingsManager.Shared.CourseStudentId;
                bizId = SettingsManager.Shared.CourseBizTypeId;
            })) return null;
            if (string.IsNullOrEmpty(bizId) || bizId == "2") bizId = "23";
            if (string.IsNullOrWhiteSpace(semId))
            {
                semId = CourseCalendarHelper.InferSemesterId().ToString(CultureInfo.InvariantCulture);
                if (!TryUpdateCourseSettings(scheduleGeneration, accountGeneration, () =>
                {
                    if (!SettingsManager.Shared.CourseSemesterIdManuallySelected)
                        SettingsManager.Shared.CourseSemesterId = semId;
                })) return null;
            }

            // 1. 如果没有真实 stdId 则先请求 /for-std/course-table 自动提取
            if (string.IsNullOrEmpty(stdId) || stdId == "178506")
            {
                stdId = string.Empty;
                using var pageReq = new HttpRequestMessage(HttpMethod.Get, "http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table");
                pageReq.Headers.TryAddWithoutValidation("Cookie", sessionCookie);
                pageReq.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)");
                using var pageRes = await _client.SendAsync(pageReq);
                var pageHtml = await pageRes.Content.ReadAsStringAsync();
                if (!IsScheduleGenerationCurrent(scheduleGeneration, accountGeneration)) return null;

                var stdMatch = Regex.Match(pageHtml, @"/for-std/course-table/info/(\d+)");
                if (!stdMatch.Success) stdMatch = Regex.Match(pageHtml, @"var\s+studentId\s*=\s*(\d+)");
                if (!stdMatch.Success) stdMatch = Regex.Match(pageHtml, @"/for-std/course-table/get-data\?.*dataId=(\d+)");
                if (stdMatch.Success)
                {
                    stdId = stdMatch.Groups[1].Value;
                }
                var semMatch = Regex.Match(pageHtml, @"semesterId\s*:\s*(\d+)");
                if (!semMatch.Success) semMatch = Regex.Match(pageHtml, @"'fileInfoAssoc'\s*:\s*null\s*,\s*'id'\s*:\s*(\d+)");
                if (semMatch.Success)
                {
                    if (!SettingsManager.Shared.CourseSemesterIdManuallySelected)
                        semId = semMatch.Groups[1].Value;
                }
                var bizMatch = Regex.Match(pageHtml, @"bizTypeId\s*:\s*(\d+)");
                if (bizMatch.Success)
                {
                    bizId = bizMatch.Groups[1].Value;
                }
                if (!TryUpdateCourseSettings(scheduleGeneration, accountGeneration, () =>
                {
                    if (stdMatch.Success) SettingsManager.Shared.CourseStudentId = stdId;
                    if (semMatch.Success && !SettingsManager.Shared.CourseSemesterIdManuallySelected)
                        SettingsManager.Shared.CourseSemesterId = semId;
                    if (bizMatch.Success) SettingsManager.Shared.CourseBizTypeId = bizId;
                })) return null;
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
            if (!IsScheduleGenerationCurrent(scheduleGeneration, accountGeneration)) return null;
            if (!getResp.IsSuccessStatusCode) return null;

            var lessonIds = new List<int>();
            bool hasLessonIdsArray = false;
            bool hasInvalidLessonId = false;
            using (var doc = SafeParseJson(getJson))
            {
                if (doc != null && doc.RootElement.TryGetProperty("lessonIds", out var idsElem) && idsElem.ValueKind == JsonValueKind.Array)
                {
                    hasLessonIdsArray = true;
                    foreach (var item in idsElem.EnumerateArray())
                    {
                        if (!item.TryGetInt32(out int idVal) || idVal <= 0)
                        {
                            hasInvalidLessonId = true;
                            continue;
                        }
                        lessonIds.Add(idVal);
                    }
                }
            }

            if (!hasLessonIdsArray || hasInvalidLessonId) return null;
            if (lessonIds.Count == 0)
            {
                int.TryParse(semId, NumberStyles.Integer, CultureInfo.InvariantCulture, out int emptySemesterNumber);
                return new CourseScheduleData
                {
                    StudentId = stdId,
                    SemesterId = semId,
                    SemesterName = CourseCalendarHelper.FormatSemesterName(
                        emptySemesterNumber > 0 ? emptySemesterNumber : CourseCalendarHelper.InferSemesterId()),
                    BizTypeId = bizId,
                    LastSyncTime = DateTime.Now,
                    Lessons = new List<CourseLesson>()
                };
            }

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
            if (!IsScheduleGenerationCurrent(scheduleGeneration, accountGeneration)) return null;
            if (!datumResp.IsSuccessStatusCode) return null;

            var lessons = ParseDatumScheduleJson(datumJson);
            if (lessons.Count == 0 && !HasValidEmptyDatumSchedule(datumJson)) return null;

            int.TryParse(semId, out int sIdNum);
            return new CourseScheduleData
            {
                StudentId = stdId,
                SemesterId = semId,
                SemesterName = CourseCalendarHelper.FormatSemesterName(
                    sIdNum > 0 ? sIdNum : CourseCalendarHelper.InferSemesterId()),
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
                    string dateStr = slot.TryGetProperty("date", out var dtElem) ? dtElem.GetString() ?? "" : "";
                    int weekday;
                    if (slot.TryGetProperty("weekday", out var wdElem)
                        && wdElem.ValueKind == JsonValueKind.Number
                        && wdElem.TryGetInt32(out var parsedWeekday)
                        && parsedWeekday is >= 1 and <= 7)
                    {
                        weekday = parsedWeekday;
                    }
                    else if (CourseCalendarHelper.ParseDate(dateStr, "00:00") is DateTime lessonDate)
                    {
                        weekday = CourseCalendarHelper.Weekday(lessonDate);
                    }
                    else
                    {
                        weekday = 1;
                    }
                    int startTime = slot.TryGetProperty("startTime", out var stElem) && stElem.ValueKind == JsonValueKind.Number ? stElem.GetInt32() : 800;
                    int endTime = slot.TryGetProperty("endTime", out var etElem) && etElem.ValueKind == JsonValueKind.Number ? etElem.GetInt32() : 940;

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

    private static bool HasValidEmptyDatumSchedule(string json)
    {
        using var doc = SafeParseJson(json);
        if (doc == null || !doc.RootElement.TryGetProperty("result", out var result) ||
            result.ValueKind != JsonValueKind.Object ||
            !result.TryGetProperty("lessonList", out var lessons) || lessons.ValueKind != JsonValueKind.Array ||
            !result.TryGetProperty("scheduleList", out var schedules) || schedules.ValueKind != JsonValueKind.Array)
        {
            return false;
        }

        return schedules.GetArrayLength() == 0;
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
                if (CurrentSchedule != null)
                {
                    EnsureSemesterOptions(CurrentSchedule);
                }
            }
        }
        catch { }
    }

    public async Task<string?> DiscoverStudentIdAsync(string cookie, long? expectedAccountGeneration = null)
    {
        int scheduleGeneration;
        lock (_scheduleStateLock)
        {
            scheduleGeneration = _scheduleGeneration;
        }
        var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return null;

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
                    lock (_scheduleStateLock)
                    {
                        if (scheduleGeneration != _scheduleGeneration ||
                            !AccountSessionManager.IsGenerationCurrent(accountGeneration))
                            return null;

                        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                        {
                            SettingsManager.Shared.CourseStudentId = stdId;
                            SettingsManager.Shared.Save();
                        })) return null;
                    }
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

    public int UnreadGradeCount
    {
        get
        {
            lock (_stateLock)
            {
                return SettingsManager.Shared.UnreadGradeIds.Count;
            }
        }
    }

    private readonly string _cacheFile;
    private readonly HttpClient _client;
    private Timer? _timer;
    private readonly SemaphoreSlim _syncLock = new(1, 1);
    private readonly object _stateLock = new();
    private readonly object _syncCallbacksLock = new();
    private readonly HashSet<(long AccountGeneration, long CacheGeneration)> _activeSyncs = new();
    private readonly Dictionary<(long AccountGeneration, long CacheGeneration), List<Action<bool>>> _pendingSyncCallbacks = new();
    private long _cacheGeneration;

    private AcademicService()
    {
        var appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "HFUTCampusNet");
        Directory.CreateDirectory(appData);
        _cacheFile = Path.Combine(appData, "academic_data.json");

        var handler = new HttpClientHandler
        {
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
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
        lock (_stateLock)
        {
            _cacheGeneration++;
            LatestData = null;
            try { if (File.Exists(_cacheFile)) File.Delete(_cacheFile); } catch { }
            SettingsManager.Shared.NotifiedGradeIds.Clear();
            SettingsManager.Shared.UnreadGradeIds.Clear();
            SettingsManager.Shared.Save();
        }
        AppEvents.RaiseAcademicDataUpdated();
    }

    public void MarkAllGradesAsRead()
    {
        lock (_stateLock)
        {
            SettingsManager.Shared.UnreadGradeIds.Clear();
            SettingsManager.Shared.Save();
        }
        AppEvents.RaiseAcademicDataUpdated();
    }

    public void SyncAll(bool silent, Action<bool>? callback = null, long? expectedAccountGeneration = null)
    {
        var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration))
        {
            callback?.Invoke(false);
            return;
        }
        long expectedCacheGeneration;
        lock (_stateLock)
        {
            expectedCacheGeneration = _cacheGeneration;
        }
        var syncKey = (AccountGeneration: accountGeneration, CacheGeneration: expectedCacheGeneration);

        lock (_syncCallbacksLock)
        {
            if (_activeSyncs.Contains(syncKey))
            {
                if (callback != null)
                    _pendingSyncCallbacks[syncKey].Add(callback);
                return;
            }

            _activeSyncs.Add(syncKey);
            _pendingSyncCallbacks[syncKey] = callback == null
                ? new List<Action<bool>>()
                : new List<Action<bool>> { callback };
        }

        Task.Run(async () =>
        {
            var succeeded = false;
            var acquiredSyncLock = false;
            var generation = expectedCacheGeneration;
            try
            {
                await _syncLock.WaitAsync();
                acquiredSyncLock = true;

                if (!IsCurrentCacheGeneration(generation, accountGeneration)) return;

                // 通道 1：合工大教务移动端 (UniApp JWT 主源)
                var uniAppTask = FetchFromUniAppAsync(accountGeneration);

                // 通道 2：树维教务系统网页端 (jxglstu EAMS 5.0 辅源)
                var eamsWebTask = FetchFromEamsWebAsync(accountGeneration);

                await Task.WhenAll(uniAppTask, eamsWebTask);
                if (!IsCurrentCacheGeneration(generation, accountGeneration))
                {
                    return;
                }

                var (uniGrades, uniExams) = await uniAppTask;
                var (webGrades, webExams, webProgram, webBooks, webSurveys) = await eamsWebTask;

                // 双源合并成绩与考试
                var mergedGrades = MergeGrades(uniGrades, webGrades);
                var mergedExams = MergeExams(uniExams, webExams);

                if (mergedGrades.Count == 0 && mergedExams.Count == 0 && webProgram == null &&
                    webBooks.Count == 0 && webSurveys.Count == 0)
                {
                    bool staleEmptyResult = false;
                    lock (_stateLock)
                    {
                        if (generation != _cacheGeneration)
                        {
                            staleEmptyResult = true;
                        }
                        else if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                        {
                            if (LatestData == null) return;
                            LatestData.LastErrorMessage = "教务系统未返回有效数据，请检查认证状态或网络连接。";
                            SaveCache();
                        })) staleEmptyResult = true;
                    }

                    if (!staleEmptyResult)
                        AppEvents.RaiseAcademicDataUpdated();
                    return;
                }

                bool staleGeneration = false;
                lock (_stateLock)
                {
                    if (generation != _cacheGeneration)
                    {
                        staleGeneration = true;
                    }
                    else if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                    {
                        var prevSnapshot = LatestData;
                        var studentId = SettingsManager.Shared.CourseStudentId;
                        if (string.IsNullOrEmpty(studentId)) studentId = SettingsManager.Shared.PortalUsername;

                        var newSnapshot = new AcademicDataSnapshot
                        {
                            StudentId = studentId,
                            AllGrades = mergedGrades.Count > 0 ? mergedGrades : (prevSnapshot?.AllGrades ?? new()),
                            Exams = mergedExams.Count > 0 ? mergedExams : (prevSnapshot?.Exams ?? new()),
                            ProgramCompletion = webProgram ?? prevSnapshot?.ProgramCompletion,
                            Textbooks = webBooks.Count > 0 ? webBooks : (prevSnapshot?.Textbooks ?? new()),
                            Surveys = webSurveys.Count > 0 ? webSurveys : (prevSnapshot?.Surveys ?? new()),
                            LastGradesSyncTime = mergedGrades.Count > 0 ? DateTime.Now : prevSnapshot?.LastGradesSyncTime,
                            LastExamsSyncTime = mergedExams.Count > 0 ? DateTime.Now : prevSnapshot?.LastExamsSyncTime
                        };

                        // 出分静默通知检测
                        CheckNewGradesNotification(newSnapshot.AllGrades, isInitialSnapshot: prevSnapshot == null);

                        LatestData = newSnapshot;
                        SaveCache();
                    })) staleGeneration = true;
                }
                if (staleGeneration)
                {
                    return;
                }
                AppEvents.RaiseAcademicDataUpdated();
                succeeded = true;
            }
            catch (Exception ex)
            {
                lock (_stateLock)
                {
                    if (generation == _cacheGeneration && LatestData != null)
                    {
                        AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                            LatestData.LastErrorMessage = ex.Message);
                    }
                }
            }
            finally
            {
                if (acquiredSyncLock) _syncLock.Release();
                CompleteSyncCallbacks(syncKey, succeeded);
            }
        });
    }

    private void CompleteSyncCallbacks((long AccountGeneration, long CacheGeneration) syncKey, bool succeeded)
    {
        List<Action<bool>> callbacks;
        lock (_syncCallbacksLock)
        {
            _activeSyncs.Remove(syncKey);
            callbacks = _pendingSyncCallbacks.TryGetValue(syncKey, out var pending)
                ? pending
                : new List<Action<bool>>();
            _pendingSyncCallbacks.Remove(syncKey);
        }

        foreach (var pendingCallback in callbacks)
        {
            try { pendingCallback(succeeded); } catch { }
        }
    }

    // MARK: - 通道 1：UniApp 移动端数据拉取

    private async Task<(List<GradeItem> Grades, List<ExamItem> Exams)> FetchFromUniAppAsync(long accountGeneration)
    {
        var token = await EmptyClassroomService.Shared.EnsureValidTokenAsync(
            forceRelogin: false,
            expectedAccountGeneration: accountGeneration);
        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration) || string.IsNullOrEmpty(token))
        {
            return (new(), new());
        }

        var (grades, exams, needRetry) = await RequestUniAppDataAsync(token);
        if (needRetry)
        {
            var newToken = await EmptyClassroomService.Shared.EnsureValidTokenAsync(
                forceRelogin: true,
                expectedAccountGeneration: accountGeneration);
            if (AccountSessionManager.IsGenerationCurrent(accountGeneration) && !string.IsNullOrEmpty(newToken))
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
                        bool? passed = item.TryGetProperty("passed", out var ps) &&
                            ps.ValueKind is JsonValueKind.True or JsonValueKind.False
                                ? ps.GetBoolean()
                                : null;

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
                            PassedOverride = passed,
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
                        if (!item.TryGetProperty("startTime", out var startProp) ||
                            !TryParseApiExamTime(startProp, out var startStr) ||
                            !item.TryGetProperty("endTime", out var endProp) ||
                            !TryParseApiExamTime(endProp, out var endStr) ||
                            !TryParseExamDateTime(examDate, startStr, endStr, out var startDateTime, out var endDateTime))
                        {
                            continue;
                        }
                        startStr = startDateTime.ToString("HH:mm", CultureInfo.InvariantCulture);
                        endStr = endDateTime.ToString("HH:mm", CultureInfo.InvariantCulture);
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

    private async Task<(List<GradeItem> Grades, List<ExamItem> Exams, ProgramCompletionSummary? Program, List<CourseTextbookItem> Books, List<LessonSurveyItem> Surveys)> FetchFromEamsWebAsync(long accountGeneration)
    {
        try
        {
            var cookie = await CourseScheduleService.Shared.EnsureSessionAsync(
                expectedAccountGeneration: accountGeneration);
            if (!AccountSessionManager.IsGenerationCurrent(accountGeneration) || string.IsNullOrEmpty(cookie))
            {
                return (new(), new(), null, new(), new());
            }

            string stdId = string.Empty;
            string semId = string.Empty;
            string bizId = string.Empty;
            if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
            {
                stdId = SettingsManager.Shared.CourseStudentId;
                semId = SettingsManager.Shared.CourseSemesterId;
                bizId = SettingsManager.Shared.CourseBizTypeId;
            })) return (new(), new(), null, new(), new());
            if (string.IsNullOrEmpty(stdId) || stdId == "178506")
            {
                var discoveredStudentId = await CourseScheduleService.Shared.DiscoverStudentIdAsync(cookie, accountGeneration);
                if (!AccountSessionManager.IsGenerationCurrent(accountGeneration) || string.IsNullOrWhiteSpace(discoveredStudentId))
                    return (new(), new(), null, new(), new());
                stdId = discoveredStudentId;
            }

            var gTask = FetchGradesHtmlAsync(cookie, stdId);
            var eTask = FetchExamsHtmlAsync(cookie, stdId);
            var pTask = FetchProgramCompletionAsync(cookie, stdId);

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
        var existingKeys = new HashSet<string>(primary.Select(GradeMergeKey), StringComparer.OrdinalIgnoreCase);

        foreach (var sec in secondary)
        {
            var key = GradeMergeKey(sec);
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

    private static string GradeMergeKey(GradeItem grade)
    {
        var term = (grade.TermName ?? string.Empty).Trim().ToUpperInvariant();
        var courseCode = grade.CourseCode?.Trim();
        var lessonCode = grade.LessonCode?.Trim();
        var courseName = (grade.CourseName ?? string.Empty).Trim();
        var courseIdentity = !string.IsNullOrWhiteSpace(courseCode)
            ? $"code:{courseCode.ToUpperInvariant()}"
            : !string.IsNullOrWhiteSpace(lessonCode)
                ? $"lesson:{lessonCode.ToUpperInvariant()}"
                : $"name:{courseName.ToUpperInvariant()}";
        return $"{term}|{courseIdentity}";
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

    private void CheckNewGradesNotification(List<GradeItem> grades, bool isInitialSnapshot = false)
    {
        var notified = SettingsManager.Shared.NotifiedGradeIds;
        var unread = SettingsManager.Shared.UnreadGradeIds;
        var newOnes = new List<GradeItem>();

        if (isInitialSnapshot && notified.Count == 0)
        {
            foreach (var grade in grades)
            {
                if (!string.IsNullOrWhiteSpace(grade.Id))
                    notified.Add(grade.Id);
            }

            if (notified.Count > 0)
            {
                SettingsManager.Shared.NotifiedGradeIds = notified;
                SettingsManager.Shared.Save();
            }
            return;
        }

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

    public void ApplyWebGradeAndExamHtml(
        string? gradeHtml,
        string? examHtml,
        long? expectedAccountGeneration = null)
    {
        try
        {
            var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
            if (!AccountSessionManager.IsGenerationCurrent(accountGeneration))
                return;
            long generation;
            AcademicDataSnapshot? prevSnapshot;
            lock (_stateLock)
            {
                generation = _cacheGeneration;
                prevSnapshot = LatestData;
            }

            var webGrades = !string.IsNullOrWhiteSpace(gradeHtml) ? ParseGradesHtml(gradeHtml) : new List<GradeItem>();
            var webExams = !string.IsNullOrWhiteSpace(examHtml) ? ParseExamsHtml(examHtml) : new List<ExamItem>();

            if (webGrades.Count == 0 && webExams.Count == 0) return;

            var mergedGrades = MergeGrades(prevSnapshot?.AllGrades ?? new(), webGrades);
            var mergedExams = MergeExams(prevSnapshot?.Exams ?? new(), webExams);

            var studentId = SettingsManager.Shared.CourseStudentId;
            if (string.IsNullOrEmpty(studentId)) studentId = SettingsManager.Shared.PortalUsername;

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

            lock (_stateLock)
            {
                if (generation != _cacheGeneration) return;
                if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                {
                    CheckNewGradesNotification(newSnapshot.AllGrades, isInitialSnapshot: prevSnapshot == null);
                    LatestData = newSnapshot;
                    SaveCache();
                })) return;
            }
            AppEvents.RaiseAcademicDataUpdated();
        }
        catch { }
    }

    private bool IsCurrentCacheGeneration(long generation, long accountGeneration)
    {
        lock (_stateLock)
        {
            return generation == _cacheGeneration &&
                AccountSessionManager.IsGenerationCurrent(accountGeneration);
        }
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
                    var dateTimeMatch = Regex.Match(
                        dtStr,
                        @"^(?<date>\d{4}-\d{2}-\d{2})\s+(?<start>\d{1,2}:\d{2})~(?<end>\d{1,2}:\d{2})$");
                    if (string.IsNullOrEmpty(name) || !dateTimeMatch.Success) continue;

                    var datePart = dateTimeMatch.Groups["date"].Value;
                    var startTime = dateTimeMatch.Groups["start"].Value;
                    var endTime = dateTimeMatch.Groups["end"].Value;
                    if (!TryParseExamDateTime(datePart, startTime, endTime, out var startDateTime, out var endDateTime))
                    {
                        continue;
                    }

                    list.Add(new ExamItem
                    {
                        Id = $"{name}|{dtStr}",
                        CourseName = name,
                        ExamType = type,
                        DateTimeString = dtStr,
                        DateString = datePart,
                        StartTimeString = startDateTime.ToString("HH:mm", CultureInfo.InvariantCulture),
                        EndTimeString = endDateTime.ToString("HH:mm", CultureInfo.InvariantCulture),
                        Place = place,
                        SeatNumber = seat
                    });
                }
            }
        }
        catch { }
        return list;
    }

    private static bool TryParseApiExamTime(JsonElement value, out string formattedTime)
    {
        formattedTime = string.Empty;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var numericTime))
            return TryFormatExamTime(numericTime, out formattedTime);

        if (value.ValueKind != JsonValueKind.String) return false;
        var text = value.GetString()?.Trim();
        if (string.IsNullOrEmpty(text)) return false;
        if (int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out numericTime))
            return TryFormatExamTime(numericTime, out formattedTime);

        if (!DateTime.TryParseExact(
                text,
                new[] { "H:mm", "HH:mm" },
                CultureInfo.InvariantCulture,
                DateTimeStyles.None,
                out var parsedTime))
        {
            return false;
        }

        formattedTime = parsedTime.ToString("HH:mm", CultureInfo.InvariantCulture);
        return true;
    }

    private static bool TryFormatExamTime(int value, out string formattedTime)
    {
        formattedTime = string.Empty;
        var hour = value / 100;
        var minute = value % 100;
        if (value < 0 || hour >= 24 || minute >= 60) return false;
        formattedTime = $"{hour:D2}:{minute:D2}";
        return true;
    }

    private static bool TryParseExamDateTime(
        string date,
        string startTime,
        string endTime,
        out DateTime startDateTime,
        out DateTime endDateTime)
    {
        startDateTime = default;
        endDateTime = default;
        var formats = new[] { "yyyy-MM-dd H:mm", "yyyy-MM-dd HH:mm" };
        return DateTime.TryParseExact(
                $"{date} {startTime}", formats, CultureInfo.InvariantCulture, DateTimeStyles.None, out startDateTime) &&
            DateTime.TryParseExact(
                $"{date} {endTime}", formats, CultureInfo.InvariantCulture, DateTimeStyles.None, out endDateTime) &&
            endDateTime >= startDateTime;
    }

    private static bool IsValidExamSchedule(ExamItem exam) =>
        TryParseExamDateTime(exam.DateString, exam.StartTimeString, exam.EndTimeString, out _, out _);

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
                var cached = JsonSerializer.Deserialize<AcademicDataSnapshot>(json);
                if (cached == null) return;

                var cachedExams = cached.Exams ?? new List<ExamItem>();
                var validExams = cachedExams.Where(exam => exam != null && IsValidExamSchedule(exam)).ToList();
                bool removedInvalidExams = validExams.Count != cachedExams.Count;
                cached.Exams = validExams;
                LatestData = cached;
                if (removedInvalidExams) SaveCache();
            }
        }
        catch { }
    }
}

#endregion
