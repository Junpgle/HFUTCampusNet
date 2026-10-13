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
            UseCookies = true,
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

    private async Task<string?> ExchangeCasTicketForEamsSessionAsync(string tgc)
    {
        try
        {
            var ssoUrl = "https://cas.hfut.edu.cn/cas/login?service=http%3A%2F%2Fjxglstu.hfut.edu.cn%2Feams5-student%2Fneusoft-sso%2Flogin";
            var req = new HttpRequestMessage(HttpMethod.Get, ssoUrl);
            req.Headers.Add("Cookie", $"CASTGC={tgc}");
            var res = await _client.SendAsync(req);
            if (res.Headers.TryGetValues("Set-Cookie", out var cookies))
            {
                foreach (var c in cookies)
                {
                    if (c.Contains("SESSION="))
                    {
                        var m = Regex.Match(c, @"SESSION=([^;]+)");
                        if (m.Success) return $"SESSION={m.Groups[1].Value}";
                    }
                }
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

            // 1. 如果没有 stdId 则先请求 /for-std/course-table 自动提取
            if (string.IsNullOrEmpty(stdId))
            {
                var pageReq = new HttpRequestMessage(HttpMethod.Get, "http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table");
                pageReq.Headers.Add("Cookie", sessionCookie);
                var pageHtml = await (await _client.SendAsync(pageReq)).Content.ReadAsStringAsync();
                var stdMatch = Regex.Match(pageHtml, @"/for-std/course-table/get-data\?.*dataId=([0-9]+)");
                if (stdMatch.Success)
                {
                    stdId = stdMatch.Groups[1].Value;
                    SettingsManager.Shared.CourseStudentId = stdId;
                    SettingsManager.Shared.Save();
                }
            }

            if (string.IsNullOrEmpty(stdId)) stdId = "178506";

            // 2. 请求 datum JSON
            var url = $"http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table/get-data?bizTypeId={bizId}&semesterId={semId}&dataId={stdId}";
            var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Add("Cookie", sessionCookie);
            var json = await (await _client.SendAsync(req)).Content.ReadAsStringAsync();

            var lessons = ParseScheduleJson(json);
            return new CourseScheduleData
            {
                StudentId = stdId,
                SemesterId = semId,
                SemesterName = CourseCalendarHelper.FormatSemesterName(int.Parse(semId)),
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

    private static List<CourseLesson> ParseScheduleJson(string json)
    {
        var list = new List<CourseLesson>();
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("lessons", out var lessonsArr)) return list;

            int idx = 0;
            foreach (var lesson in lessonsArr.EnumerateArray())
            {
                var cName = lesson.TryGetProperty("courseName", out var cn) ? cn.GetString() ?? "" : "";
                var cCode = lesson.TryGetProperty("courseCode", out var cc) ? cc.GetString() : null;
                var teacher = lesson.TryGetProperty("teachers", out var tc) ? tc.GetString() : null;
                var room = lesson.TryGetProperty("room", out var rm) ? rm.GetString() : null;
                var dateStr = lesson.TryGetProperty("date", out var dt) ? dt.GetString() ?? "" : "";
                int start = lesson.TryGetProperty("startTime", out var st) ? st.GetInt32() : 800;
                int end = lesson.TryGetProperty("endTime", out var et) ? et.GetInt32() : 940;
                int? week = lesson.TryGetProperty("weekIndex", out var wk) ? wk.GetInt32() : null;
                int weekday = lesson.TryGetProperty("weekday", out var wd) ? wd.GetInt32() : 1;

                list.Add(new CourseLesson
                {
                    Id = $"lesson-{idx++}-{dateStr}-{start}",
                    LessonId = idx,
                    CourseName = cName,
                    CourseCode = cCode,
                    Teacher = teacher,
                    Classroom = room,
                    DateString = dateStr,
                    StartTime = start,
                    EndTime = end,
                    WeekIndex = week,
                    Weekday = weekday
                });
            }
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
            }
        }
        catch { }
    }
}

#endregion

#region 2. 教务与培养方案服务 AcademicService

public sealed class AcademicService
{
    public static AcademicService Shared { get; } = new();

    public AcademicDataSnapshot? LatestData { get; private set; }

    public int UnreadGradeCount => SettingsManager.Shared.UnreadGradeIds.Count;

    private readonly string _cacheFile;
    private readonly HttpClient _client;
    private Timer? _timer;

    private AcademicService()
    {
        var appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "HFUTCampusNet");
        Directory.CreateDirectory(appData);
        _cacheFile = Path.Combine(appData, "academic_data.json");

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
        SyncAll(silent: true);
        _timer = new Timer(_ => SyncAll(silent: true), null, 15 * 60 * 1000, 15 * 60 * 1000); // 15分钟轮询
    }

    public void StopMonitoring()
    {
        _timer?.Dispose();
        _timer = null;
    }

    public void ClearCache()
    {
        LatestData = null;
        SaveCache();
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
            try
            {
                var cookie = SettingsManager.Shared.CourseSessionCookie;
                var stdId = SettingsManager.Shared.CourseStudentId;
                if (string.IsNullOrEmpty(stdId)) stdId = "178506";

                if (string.IsNullOrEmpty(cookie) && !string.IsNullOrEmpty(SettingsManager.Shared.CasTgcCookie))
                {
                    CourseScheduleService.Shared.TryBackgroundLogin();
                    cookie = SettingsManager.Shared.CourseSessionCookie;
                }

                if (string.IsNullOrEmpty(cookie))
                {
                    callback?.Invoke(false);
                    return;
                }

                var snapshot = new AcademicDataSnapshot { StudentId = stdId };

                // 1. 成绩单 HTML
                var grades = await FetchGradesHtmlAsync(cookie, stdId);
                snapshot.AllGrades = grades;
                snapshot.LastGradesSyncTime = DateTime.Now;

                // 2. 排考 HTML
                var exams = await FetchExamsHtmlAsync(cookie, stdId);
                snapshot.Exams = exams;
                snapshot.LastExamsSyncTime = DateTime.Now;

                // 3. 培养方案 JSON
                var prog = await FetchProgramCompletionAsync(cookie, stdId);
                snapshot.ProgramCompletion = prog;

                // 4. 教材 JSON
                var semId = SettingsManager.Shared.CourseSemesterId;
                var bizId = SettingsManager.Shared.CourseBizTypeId;
                var books = await FetchTextbooksAsync(cookie, semId, bizId, stdId);
                snapshot.Textbooks = books;

                // 5. 评教 JSON
                var surveys = await FetchSurveysAsync(cookie, semId, stdId);
                snapshot.Surveys = surveys;

                // 差异比对：新出分静默提醒
                CheckNewGradesNotification(grades);

                LatestData = snapshot;
                SaveCache();
                AppEvents.RaiseAcademicDataUpdated();
                callback?.Invoke(true);
            }
            catch (Exception ex)
            {
                if (LatestData != null) LatestData.LastErrorMessage = ex.Message;
                callback?.Invoke(false);
            }
        });
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

    private async Task<List<GradeItem>> FetchGradesHtmlAsync(string cookie, string stdId)
    {
        var list = new List<GradeItem>();
        try
        {
            var url = $"http://jxglstu.hfut.edu.cn/eams5-student/for-std/grade/sheet/info/{stdId}?semester=";
            var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Add("Cookie", cookie);
            var html = await (await _client.SendAsync(req)).Content.ReadAsStringAsync();

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

    private async Task<List<ExamItem>> FetchExamsHtmlAsync(string cookie, string stdId)
    {
        var list = new List<ExamItem>();
        try
        {
            var url = $"http://jxglstu.hfut.edu.cn/eams5-student/for-std/exam-arrange/info/{stdId}";
            var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Add("Cookie", cookie);
            var html = await (await _client.SendAsync(req)).Content.ReadAsStringAsync();

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

    private async Task<ProgramCompletionSummary?> FetchProgramCompletionAsync(string cookie, string stdId)
    {
        try
        {
            var url = $"http://jxglstu.hfut.edu.cn/eams5-student/for-std/program-completion-preview/json/{stdId}";
            var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Add("Cookie", cookie);
            var json = await (await _client.SendAsync(req)).Content.ReadAsStringAsync();

            using var doc = JsonDocument.Parse(json);
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

            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("lessons", out var lessons))
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

            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("forStdLessonSurveySearchVms", out var vms))
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
