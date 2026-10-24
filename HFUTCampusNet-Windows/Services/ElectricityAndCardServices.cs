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
using System.Threading.Tasks;

namespace HFUTCampusNet;

public sealed class ElectricityService
{
    public static ElectricityService Shared { get; } = new ElectricityService();

    public ElectricityData? LatestData { get; private set; }

    private readonly object _stateLock = new();
    private long _requestGeneration;
    private readonly object _tokenStateLock = new();
    private long _tokenRequestGeneration;
    private readonly string _cacheFilePath;
    private readonly HttpClient _httpClient;

    private const string StaleRequestMessage = "宿舍信息或查询请求已更新，已忽略旧查询结果";

    private readonly record struct DormIdentity(string Campus, string Building, string Room, string EndNumber)
    {
        public bool IsConfigured => !string.IsNullOrWhiteSpace(Building) && !string.IsNullOrWhiteSpace(Room);

        public static DormIdentity Capture(SettingsManager settings) => new(
            settings.DormCampus ?? "宣城校区",
            settings.DormBuilding ?? string.Empty,
            settings.DormRoom ?? string.Empty,
            settings.DormEndNumber ?? "11");

        public bool Matches(SettingsManager settings) =>
            string.Equals(Campus, settings.DormCampus ?? "宣城校区", StringComparison.Ordinal) &&
            string.Equals(Building, settings.DormBuilding ?? string.Empty, StringComparison.Ordinal) &&
            string.Equals(Room, settings.DormRoom ?? string.Empty, StringComparison.Ordinal) &&
            string.Equals(EndNumber, settings.DormEndNumber ?? "11", StringComparison.Ordinal);
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    private ElectricityService()
    {
        var appData = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "HFUTCampusNet");
        Directory.CreateDirectory(appData);
        _cacheFilePath = Path.Combine(appData, "dorm_electricity.json");

        var handler = new HttpClientHandler
        {
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
        };
        _httpClient = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(12)
        };

        LoadCachedData();
    }

    private void LoadCachedData()
    {
        try
        {
            if (!SettingsManager.Shared.IsDormConfigured || !File.Exists(_cacheFilePath))
                return;

            var json = File.ReadAllText(_cacheFilePath, Encoding.UTF8);
            var cached = JsonSerializer.Deserialize<ElectricityData>(json, JsonOptions);
            if (cached == null)
                return;

            if (cached.Campus != SettingsManager.Shared.DormCampus ||
                cached.Building != SettingsManager.Shared.DormBuilding ||
                cached.Room != SettingsManager.Shared.DormRoom ||
                cached.EndNumber != SettingsManager.Shared.DormEndNumber)
            {
                return;
            }

            LatestData = cached;
        }
        catch
        {
            // Ignore malformed cache
        }
    }

    private void SaveCachedData(ElectricityData data)
    {
        LatestData = data;
        try
        {
            var json = JsonSerializer.Serialize(data, JsonOptions);
            File.WriteAllText(_cacheFilePath, json, Encoding.UTF8);
        }
        catch
        {
            // Ignore IO errors
        }
    }

    /// <summary>
    /// 当用户在偏好设置中修改了宿舍校区/楼栋/房间号/端口时，清理旧宿舍缓存并切换历史分区
    /// </summary>
    public void InvalidateCacheIfDormChanged()
    {
        CampusHistoryManager.Shared.ActivateCurrentElectricityDorm();
        bool hadDataOrCache;
        lock (_stateLock)
        {
            _requestGeneration++;
            var dorm = DormIdentity.Capture(SettingsManager.Shared);
            if (LatestData is { } cached &&
                dorm.IsConfigured &&
                cached.Campus == dorm.Campus &&
                cached.Building == dorm.Building &&
                cached.Room == dorm.Room &&
                cached.EndNumber == dorm.EndNumber)
            {
                return;
            }

            hadDataOrCache = LatestData != null || File.Exists(_cacheFilePath);
            LatestData = null;
            try
            {
                if (File.Exists(_cacheFilePath))
                    File.Delete(_cacheFilePath);
            }
            catch { }
        }

        if (hadDataOrCache)
        {
            AppEvents.InvokeOnUI(AppEvents.RaiseDormElectricityUpdated);
        }
    }

    public void CancelPendingRequests()
    {
        lock (_stateLock)
        {
            _requestGeneration++;
        }
        lock (_tokenStateLock)
        {
            _tokenRequestGeneration++;
        }
    }

    public void ClearAccountScopedCache()
    {
        lock (_stateLock)
        {
            _requestGeneration++;
            LatestData = null;
            try
            {
                if (File.Exists(_cacheFilePath))
                    File.Delete(_cacheFilePath);
            }
            catch { }
        }
        lock (_tokenStateLock)
        {
            _tokenRequestGeneration++;
        }

        AppEvents.InvokeOnUI(AppEvents.RaiseDormElectricityUpdated);
    }

    public void FetchData(Action<ElectricityData?, string?>? completion = null)
    {
        var accountGeneration = AccountSessionManager.Generation;
        _ = Task.Run(async () =>
        {
            var (data, err) = await FetchDataAsync();
            if (completion != null && AccountSessionManager.IsGenerationCurrent(accountGeneration))
            {
                AppEvents.InvokeOnUI(() =>
                {
                    if (AccountSessionManager.IsGenerationCurrent(accountGeneration))
                        completion(data, err);
                });
            }
        });
    }

    /// <summary>
    /// 查询宿舍电费信息（支持静默自动登录）
    /// </summary>
    public async Task<(ElectricityData? Data, string? ErrorMessage)> FetchDataAsync()
    {
        var accountGeneration = AccountSessionManager.Generation;
        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration))
            return (null, StaleRequestMessage);
        var dorm = DormIdentity.Capture(SettingsManager.Shared);
        long generation;
        lock (_stateLock)
        {
            generation = ++_requestGeneration;
        }

        if (!dorm.IsConfigured)
        {
            return (null, "尚未配置宿舍楼栋与房间号，请在「设置」中填写您的宿舍信息");
        }

        string? token = null;
        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
            token = SettingsManager.Shared.HuixinAuthToken))
            return (null, StaleRequestMessage);
        if (!string.IsNullOrWhiteSpace(token))
        {
            var (firstData, firstErr, isConfigErr) = await ExecuteFeeQueryAsync(token!, generation, dorm, accountGeneration);
            if (firstData != null)
            {
                return (firstData, null);
            }
            if (!IsCurrentRequest(generation, dorm, accountGeneration))
                return (null, StaleRequestMessage);
            if (isConfigErr)
                return (null, firstErr);

            // Token 可能失效，尝试通过已保存学号密码静默重新登录
            var (newToken, loginErr) = await ObtainHuiXinTokenAsync(
                tokenValue => TryPersistTokenForCurrentRequest(generation, dorm, accountGeneration, tokenValue),
                accountGeneration);
            if (!IsCurrentRequest(generation, dorm, accountGeneration))
                return (null, StaleRequestMessage);
            if (!string.IsNullOrWhiteSpace(newToken))
            {
                var (retryData, retryErr, _) = await ExecuteFeeQueryAsync(newToken!, generation, dorm, accountGeneration);
                if (retryData != null)
                    return (retryData, null);
                if (!IsCurrentRequest(generation, dorm, accountGeneration))
                    return (null, StaleRequestMessage);
                return (null, retryErr);
            }

            return (null, loginErr ?? firstErr);
        }
        else
        {
            var (newToken, loginErr) = await ObtainHuiXinTokenAsync(
                tokenValue => TryPersistTokenForCurrentRequest(generation, dorm, accountGeneration, tokenValue),
                accountGeneration);
            if (!IsCurrentRequest(generation, dorm, accountGeneration))
                return (null, StaleRequestMessage);
            if (string.IsNullOrWhiteSpace(newToken))
            {
                return (null, loginErr ?? "慧新易校授权失败，请核对学号与密码");
            }
            var (data, err, _) = await ExecuteFeeQueryAsync(newToken!, generation, dorm, accountGeneration);
            return (data, err);
        }
    }

    public void ObtainHuiXinToken(
        Action<string?, string?>? completion,
        long? expectedAccountGeneration = null)
    {
        var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
        _ = Task.Run(async () =>
        {
            var (token, err) = await ObtainHuiXinTokenAsync(
                tryPersistToken: null,
                expectedAccountGeneration: accountGeneration);
            if (completion != null && AccountSessionManager.IsGenerationCurrent(accountGeneration))
            {
                AppEvents.InvokeOnUI(() =>
                {
                    if (AccountSessionManager.IsGenerationCurrent(accountGeneration))
                        completion(token, err);
                });
            }
        });
    }

    /// <summary>
    /// 静默调用慧新易校 OAuth 登录获取 Token（支持依次尝试校园网密码与信息门户密码，并正确编码特殊字符）
    /// </summary>
    public Task<(string? Token, string? ErrorMessage)> ObtainHuiXinTokenAsync() =>
        ObtainHuiXinTokenAsync(tryPersistToken: null, expectedAccountGeneration: null);

    internal async Task<(string? Token, string? ErrorMessage)> ObtainHuiXinTokenAsync(
        Func<string, bool>? tryPersistToken,
        long? expectedAccountGeneration = null)
    {
        var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration))
            return (null, "账号已切换");
        long tokenGeneration;
        lock (_tokenStateLock)
        {
            tokenGeneration = _tokenRequestGeneration;
        }

        string username = string.Empty;
        string portalPwd = string.Empty;
        string casPwd = string.Empty;
        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
        {
            username = (SettingsManager.Shared.PortalUsername ?? string.Empty).Trim();
            portalPwd = (SettingsManager.Shared.PortalPassword ?? string.Empty).Trim();
            casPwd = (SettingsManager.Shared.CasPassword ?? string.Empty).Trim();
        })) return (null, "账号已切换");

        var candidates = new List<string>();
        if (!string.IsNullOrEmpty(portalPwd))
            candidates.Add(portalPwd);
        if (!string.IsNullOrEmpty(casPwd) && !candidates.Contains(casPwd))
            candidates.Add(casPwd);

        if (string.IsNullOrEmpty(username) || candidates.Count == 0)
        {
            return (null, "尚未配置学号或密码，请在设置中保存学号与密码，或通过「统一身份认证同步」登录");
        }

        string? lastError = null;
        foreach (var password in candidates)
        {
            if (!IsCurrentTokenGeneration(tokenGeneration, accountGeneration))
                return (null, "授权结果已过期，请重新操作");
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Post, "http://121.251.19.62/berserker-auth/oauth/token");
                var oauthClientCredentials = "mobile_service_platform:mobile_service_platform_secret";
                var basicAuthorization = Convert.ToBase64String(Encoding.UTF8.GetBytes(oauthClientCredentials));
                req.Headers.TryAddWithoutValidation(
                    "Authorization",
                    $"Basic {basicAuthorization}");
                var body = $"username={EncodeFormField(username)}&password={EncodeFormField(password)}&grant_type=password&logintype=sno";
                req.Content = new StringContent(body, Encoding.UTF8, "application/x-www-form-urlencoded");

                using var resp = await _httpClient.SendAsync(req);
                if (!IsCurrentTokenGeneration(tokenGeneration, accountGeneration))
                    return (null, "授权结果已过期，请重新操作");
                var respBytes = await resp.Content.ReadAsByteArrayAsync();
                var respText = Encoding.UTF8.GetString(respBytes);

                using var doc = JsonDocument.Parse(respText);
                if (doc.RootElement.ValueKind == JsonValueKind.Object &&
                    doc.RootElement.TryGetProperty("access_token", out var tokenElem) &&
                    tokenElem.ValueKind == JsonValueKind.String)
                {
                    var accessToken = tokenElem.GetString();
                    if (!string.IsNullOrWhiteSpace(accessToken))
                    {
                        lock (_tokenStateLock)
                        {
                            if (tokenGeneration != _tokenRequestGeneration ||
                                !AccountSessionManager.IsGenerationCurrent(accountGeneration))
                                return (null, "授权结果已过期，请重新操作");

                            if (tryPersistToken != null)
                            {
                                if (!tryPersistToken(accessToken))
                                    return (null, "授权结果已过期，请重新操作");
                            }
                            else
                            {
                                if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                                    SettingsManager.Shared.HuixinAuthToken = accessToken))
                                    return (null, "授权结果已过期，请重新操作");
                            }
                        }
                        return (accessToken, null);
                    }
                }
            }
            catch (Exception ex)
            {
                lastError = ex.Message;
            }
        }

        return (null, lastError ?? "慧新易校授权失败，请核对学号与密码");
    }

    private async Task<(ElectricityData? Data, string? ErrorMessage, bool IsRoomConfigError)> ExecuteFeeQueryAsync(
        string token,
        long generation,
        DormIdentity dorm,
        long accountGeneration)
    {
        if (!IsCurrentRequest(generation, dorm, accountGeneration))
            return (null, StaleRequestMessage, false);

        var campus = dorm.Campus;
        var building = dorm.Building;
        var room = dorm.Room;
        var endNumber = dorm.EndNumber;

        var authHeader = token.StartsWith("bearer ", StringComparison.OrdinalIgnoreCase)
            ? token
            : $"bearer {token}";

        var formParams = new Dictionary<string, string>();
        bool isXuancheng = campus.Contains("宣城") || campus.Equals("xuancheng", StringComparison.OrdinalIgnoreCase);
        if (isXuancheng)
        {
            formParams["feeitemid"] = "261";
            formParams["type"] = "IEC";
            var cleanBuilding = new string(building.Where(char.IsDigit).ToArray());
            var cleanRoom = new string(room.Where(char.IsDigit).ToArray());
            var cleanEnd = new string(endNumber.Where(char.IsDigit).ToArray());

            string roomCode;
            if (cleanRoom.StartsWith("30") && cleanRoom.Length == 9)
            {
                roomCode = cleanRoom;
            }
            else
            {
                int bNum = int.TryParse(cleanBuilding, out var bParsed) ? bParsed : 0;
                string bStr = bNum.ToString("D2", CultureInfo.InvariantCulture);
                int rNum = int.TryParse(cleanRoom, out var rParsed) ? rParsed : 0;
                string rStr = cleanRoom.Length >= 3 ? cleanRoom : rNum.ToString("D3", CultureInfo.InvariantCulture);
                // 宣城房间编码使用设置页中的端口值 (11/12/21/22) 作为末两位。
                string suffix = string.IsNullOrEmpty(cleanEnd) ? "11" : cleanEnd;
                roomCode = $"30{bStr}{rStr}{suffix}";
            }
            // 宣城慧新易校接口使用 rooms 查询参数。
            formParams["rooms"] = roomCode;
        }
        else
        {
            formParams["feeitemid"] = "1";
            formParams["type"] = "IEC";
            formParams["campus"] = "1sh";
            formParams["level"] = "1";
            formParams["building"] = building;
            formParams["room"] = room;
        }

        var queryString = string.Join("&", formParams.Select(kv => $"{EncodeFormField(kv.Key)}={EncodeFormField(kv.Value)}"));

        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, $"http://121.251.19.62/charge/feeitem/getThirdData?{queryString}");
            req.Headers.TryAddWithoutValidation("synjones-auth", authHeader);
            req.Headers.TryAddWithoutValidation("Authorization", authHeader);
            req.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15");
            using var resp = await _httpClient.SendAsync(req);
            if (!IsCurrentRequest(generation, dorm, accountGeneration))
                return (null, StaleRequestMessage, false);

            int statusCode = (int)resp.StatusCode;
            if (statusCode == 401 || statusCode == 403)
            {
                ClearExpiredTokenIfCurrent(token, generation, dorm, accountGeneration);
                return (null, "登录凭据已过期", false);
            }

            var respBytes = await resp.Content.ReadAsByteArrayAsync();
            var respText = Encoding.UTF8.GetString(respBytes);
            if (!IsCurrentRequest(generation, dorm, accountGeneration))
                return (null, StaleRequestMessage, false);

            using var doc = JsonDocument.Parse(respText);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return (null, "服务器响应格式非 JSON", false);
            }

            if (root.TryGetProperty("code", out var codeElem) &&
                codeElem.ValueKind == JsonValueKind.Number &&
                codeElem.TryGetInt32(out int jsonCode) &&
                (jsonCode == 401 || jsonCode == 403))
            {
                ClearExpiredTokenIfCurrent(token, generation, dorm, accountGeneration);
                return (null, "登录凭据已过期", false);
            }

            string? defaultMsg = root.TryGetProperty("msg", out var msgElem) && msgElem.ValueKind == JsonValueKind.String
                ? msgElem.GetString()
                : null;

            JsonElement showDataElem = default;
            bool hasShowData = root.TryGetProperty("map", out var mapElem) &&
                mapElem.ValueKind == JsonValueKind.Object &&
                mapElem.TryGetProperty("showData", out showDataElem) &&
                showDataElem.ValueKind == JsonValueKind.Object;
            if (!hasShowData && root.TryGetProperty("data", out var dataElem) && dataElem.ValueKind == JsonValueKind.Object)
            {
                if (dataElem.TryGetProperty("showData", out var nestedShowData) && nestedShowData.ValueKind == JsonValueKind.Object)
                {
                    showDataElem = nestedShowData;
                    hasShowData = true;
                }
                else
                {
                    showDataElem = dataElem;
                    hasShowData = true;
                }
            }
            if (!hasShowData)
            {
                return (null, defaultMsg ?? "未能获取到电费详情，请核对楼栋与寝室号配置", true);
            }

            var stringMap = new Dictionary<string, string>();
            double? parsedBalance = null;
            double? parsedKWh = null;

            foreach (var prop in showDataElem.EnumerateObject())
            {
                var k = prop.Name;
                var vStr = JsonElementToString(prop.Value);
                stringMap[k] = vStr;

                // 精准提取剩余金额：必须截取 "剩余金额" 后方的子字符串进行正则数字匹配，严防把房间号 (300731511) 误识别为金额
                if (vStr.Contains("剩余金额"))
                {
                    var parts = vStr.Split(new[] { "剩余金额" }, StringSplitOptions.None);
                    var afterKeyword = parts.LastOrDefault() ?? string.Empty;
                    if (TryExtractDouble(afterKeyword, out double val))
                    {
                        parsedBalance = Math.Round(val * 100.0) / 100.0;
                    }
                }
                else if (k.Contains("剩余金额") || k.Contains("余额"))
                {
                    if (TryExtractDouble(vStr, out double val))
                    {
                        parsedBalance = Math.Round(val * 100.0) / 100.0;
                    }
                }

                // 精准提取剩余电量
                if (vStr.Contains("剩余电量"))
                {
                    var parts = vStr.Split(new[] { "剩余电量" }, StringSplitOptions.None);
                    var afterKeyword = parts.LastOrDefault() ?? string.Empty;
                    if (TryExtractDouble(afterKeyword, out double val))
                    {
                        parsedKWh = val;
                    }
                }
                else if (k.Contains("剩余电量") || k.Contains("度"))
                {
                    if (TryExtractDouble(vStr, out double val))
                    {
                        parsedKWh = val;
                    }
                }
            }

            if (parsedBalance == null && parsedKWh == null)
            {
                var detailHint = stringMap.Values.FirstOrDefault(s => !string.IsNullOrWhiteSpace(s));
                var msg = detailHint ?? defaultMsg ?? "未能解析到有效电费数据，请核对楼栋、房间号及端口配置";
                return (null, msg, true);
            }

            if (parsedKWh == null && parsedBalance.HasValue)
            {
                parsedKWh = Math.Round((parsedBalance.Value / 0.58) * 10.0) / 10.0;
            }

            var elecData = new ElectricityData
            {
                Campus = campus,
                Building = building,
                Room = room,
                EndNumber = endNumber,
                BalanceRMB = parsedBalance,
                RemainingKWh = parsedKWh,
                LastUpdated = DateTime.Now,
                RawDetails = stringMap
            };

            if (!await CommitFetchedDataAsync(elecData, generation, dorm, accountGeneration).ConfigureAwait(false))
                return (null, StaleRequestMessage, false);

            return (elecData, null, false);
        }
        catch (Exception ex)
        {
            return (null, ex.Message, false);
        }
    }

    private bool IsCurrentRequest(long generation, DormIdentity dorm, long accountGeneration)
    {
        lock (_stateLock)
        {
            return IsCurrentRequestLocked(generation, dorm, accountGeneration);
        }
    }

    private bool IsCurrentRequestLocked(long generation, DormIdentity dorm, long accountGeneration) =>
        _requestGeneration == generation &&
        AccountSessionManager.IsGenerationCurrent(accountGeneration) &&
        dorm.Matches(SettingsManager.Shared);

    private void ClearExpiredTokenIfCurrent(string token, long generation, DormIdentity dorm, long accountGeneration)
    {
        lock (_stateLock)
        {
            if (!IsCurrentRequestLocked(generation, dorm, accountGeneration)) return;
            AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
            {
                if (string.Equals(SettingsManager.Shared.HuixinAuthToken, token, StringComparison.Ordinal))
                    SettingsManager.Shared.HuixinAuthToken = null;
            });
        }
    }

    private bool TryPersistTokenForCurrentRequest(long generation, DormIdentity dorm, long accountGeneration, string token)
    {
        lock (_stateLock)
        {
            if (!IsCurrentRequestLocked(generation, dorm, accountGeneration))
                return false;

            return AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                SettingsManager.Shared.HuixinAuthToken = token);
        }
    }

    private Task<bool> CommitFetchedDataAsync(ElectricityData data, long generation, DormIdentity dorm, long accountGeneration)
    {
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        AppEvents.InvokeOnUI(() =>
        {
            try
            {
                bool committed = false;
                lock (_stateLock)
                {
                    if (IsCurrentRequestLocked(generation, dorm, accountGeneration))
                    {
                        committed = AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                        {
                            SaveCachedData(data);
                            if (data.BalanceRMB.HasValue)
                            {
                                CampusHistoryManager.Shared.RecordElectricity(data.BalanceRMB.Value, data.RemainingKWh);
                            }
                            CheckLowBalanceWarning(data);
                            AppEvents.RaiseDormElectricityUpdated();
                        });
                    }
                }
                completion.TrySetResult(committed);
            }
            catch (Exception ex)
            {
                completion.TrySetException(ex);
            }
        });
        return completion.Task;
    }

    private void CheckLowBalanceWarning(ElectricityData data)
    {
        if (!data.BalanceRMB.HasValue)
            return;

        double bal = data.BalanceRMB.Value;
        double threshold = SettingsManager.Shared.ElectricityLowWarningThreshold;
        if (bal < threshold)
        {
            string today = DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            if (SettingsManager.Shared.LastNotifiedLowElectricityDate != today)
            {
                SettingsManager.Shared.LastNotifiedLowElectricityDate = today;
                NotificationHelper.Send(
                    "⚠️ 宿舍电费不足预警",
                    $"{SettingsManager.Shared.DormRoomName} 电费仅剩 {data.DisplayBalance}，低于预警线 ({threshold:F0}元)，请及时充值以免断电！",
                    "electricity_low_warning");
            }
        }
    }

    public void FetchSchoolNetInfoFromHuiXin(Action<string?, string?>? completion)
    {
        var accountGeneration = AccountSessionManager.Generation;
        _ = Task.Run(async () =>
        {
            var (flow, balance) = await FetchSchoolNetInfoFromHuiXinAsync(accountGeneration);
            if (completion != null && AccountSessionManager.IsGenerationCurrent(accountGeneration))
            {
                AppEvents.InvokeOnUI(() =>
                {
                    if (AccountSessionManager.IsGenerationCurrent(accountGeneration))
                        completion(flow, balance);
                });
            }
        });
    }

    /// <summary>
    /// 离线/校外模式下通过慧新易校查询校园网流量与余额 (feeitemid=281)
    /// </summary>
    public async Task<(string? Flow, string? Balance)> FetchSchoolNetInfoFromHuiXinAsync(
        long? expectedAccountGeneration = null)
    {
        var accountGeneration = expectedAccountGeneration ?? AccountSessionManager.Generation;
        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return (null, null);
        long tokenGeneration;
        lock (_tokenStateLock)
        {
            tokenGeneration = _tokenRequestGeneration;
        }

        string? token = null;
        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
            token = SettingsManager.Shared.HuixinAuthToken))
            return (null, null);
        if (string.IsNullOrWhiteSpace(token))
        {
            var (newToken, _) = await ObtainHuiXinTokenAsync(
                tokenValue => TryPersistTokenForTokenGeneration(tokenGeneration, accountGeneration, tokenValue),
                accountGeneration);
            if (!IsCurrentTokenGeneration(tokenGeneration, accountGeneration) || string.IsNullOrWhiteSpace(newToken))
                return (null, null);
            return await QuerySchoolNetHuiXinInternalAsync(newToken!, false, tokenGeneration, accountGeneration);
        }

        return await QuerySchoolNetHuiXinInternalAsync(token!, true, tokenGeneration, accountGeneration);
    }

    private async Task<(string? Flow, string? Balance)> QuerySchoolNetHuiXinInternalAsync(
        string token,
        bool allowRetry,
        long tokenGeneration,
        long accountGeneration)
    {
        if (!IsCurrentTokenGeneration(tokenGeneration, accountGeneration))
            return (null, null);

        try
        {
            var authHeader = token.StartsWith("bearer ", StringComparison.OrdinalIgnoreCase)
                ? token
                : $"bearer {token}";

            using var req = new HttpRequestMessage(HttpMethod.Post, "http://121.251.19.62/charge/feeitem/getThirdData?feeitemid=281&type=IEC&level=0");
            req.Headers.TryAddWithoutValidation("synjones-auth", authHeader);
            req.Content = new StringContent("feeitemid=281&type=IEC&level=0", Encoding.UTF8, "application/x-www-form-urlencoded");

            using var resp = await _httpClient.SendAsync(req);
            if (!IsCurrentTokenGeneration(tokenGeneration, accountGeneration))
                return (null, null);

            int httpStatus = (int)resp.StatusCode;
            var respText = await resp.Content.ReadAsStringAsync();
            if (!IsCurrentTokenGeneration(tokenGeneration, accountGeneration))
                return (null, null);

            JsonDocument? doc = null;
            int? jsonCode = null;
            try
            {
                doc = JsonDocument.Parse(respText);
                if (doc.RootElement.ValueKind == JsonValueKind.Object &&
                    doc.RootElement.TryGetProperty("code", out var cElem) &&
                    cElem.ValueKind == JsonValueKind.Number &&
                    cElem.TryGetInt32(out int cVal))
                {
                    jsonCode = cVal;
                }
            }
            catch { }

            using (doc)
            {
                if (httpStatus == 401 || httpStatus == 403 || jsonCode == 401 || jsonCode == 403)
                {
                    if (!TryResolveSchoolNetRetryToken(token, tokenGeneration, accountGeneration, out var retryToken))
                        return (null, null);

                    if (allowRetry)
                    {
                        var newToken = retryToken;
                        if (string.IsNullOrWhiteSpace(newToken))
                        {
                            var (obtainedToken, _) = await ObtainHuiXinTokenAsync(
                                tokenValue => TryPersistTokenForTokenGeneration(tokenGeneration, accountGeneration, tokenValue),
                                accountGeneration);
                            if (!IsCurrentTokenGeneration(tokenGeneration, accountGeneration))
                                return (null, null);
                            newToken = obtainedToken;
                        }
                        if (!string.IsNullOrWhiteSpace(newToken))
                            return await QuerySchoolNetHuiXinInternalAsync(newToken!, false, tokenGeneration, accountGeneration);
                    }
                    return (null, null);
                }

                if (doc == null || doc.RootElement.ValueKind != JsonValueKind.Object)
                {
                    return (null, null);
                }

                var root = doc.RootElement;
                JsonElement showDataElem = default;
                bool hasShowData = root.TryGetProperty("map", out var mapElem) &&
                    mapElem.ValueKind == JsonValueKind.Object &&
                    mapElem.TryGetProperty("showData", out showDataElem) &&
                    showDataElem.ValueKind == JsonValueKind.Object;
                if (!hasShowData && root.TryGetProperty("data", out var dataElem) && dataElem.ValueKind == JsonValueKind.Object)
                {
                    if (dataElem.TryGetProperty("showData", out var nestedShowData) && nestedShowData.ValueKind == JsonValueKind.Object)
                    {
                        showDataElem = nestedShowData;
                        hasShowData = true;
                    }
                    else
                    {
                        showDataElem = dataElem;
                        hasShowData = true;
                    }
                }
                if (!hasShowData)
                    return (null, null);

                string? rawFlow = TryGetShowDataString(showDataElem, "本期已使用流量")
                    ?? TryGetShowDataString(showDataElem, "已使用流量")
                    ?? TryGetShowDataString(showDataElem, "已用流量");
                string? rawFee = TryGetShowDataString(showDataElem, "储值余额")
                    ?? TryGetShowDataString(showDataElem, "账户余额")
                    ?? TryGetShowDataString(showDataElem, "余额");

                if (rawFlow == null || rawFee == null)
                {
                    foreach (var prop in showDataElem.EnumerateObject())
                    {
                        if (rawFlow == null && (prop.Name.Contains("已使用流量") || prop.Name.Contains("已用流量")))
                            rawFlow = JsonElementToString(prop.Value);
                        else if (rawFee == null && prop.Name.Contains("余额"))
                            rawFee = JsonElementToString(prop.Value);
                    }
                }

                string? cleanFlow = rawFlow?.Split('（', '(').FirstOrDefault()?.Trim();
                if (!string.IsNullOrEmpty(cleanFlow) &&
                    double.TryParse(cleanFlow, NumberStyles.Any, CultureInfo.InvariantCulture, out _))
                {
                    cleanFlow = $"{cleanFlow} M";
                }

                string? cleanFee = rawFee?.Split('（', '(').FirstOrDefault()?.Trim();
                if (!string.IsNullOrEmpty(cleanFee))
                {
                    var numPart = cleanFee.Replace("元", "").Trim();
                    if (double.TryParse(numPart, NumberStyles.Any, CultureInfo.InvariantCulture, out double feeVal))
                    {
                        cleanFee = $"{feeVal:F2} 元";
                    }
                }

                if (!IsCurrentTokenGeneration(tokenGeneration, accountGeneration))
                    return (null, null);

                return (cleanFlow, cleanFee);
            }
        }
        catch
        {
            return (null, null);
        }
    }

    private bool IsCurrentTokenGeneration(long tokenGeneration, long accountGeneration)
    {
        lock (_tokenStateLock)
        {
            return _tokenRequestGeneration == tokenGeneration &&
                AccountSessionManager.IsGenerationCurrent(accountGeneration);
        }
    }

    private bool TryPersistTokenForTokenGeneration(long tokenGeneration, long accountGeneration, string token)
    {
        lock (_tokenStateLock)
        {
            if (_tokenRequestGeneration != tokenGeneration ||
                !AccountSessionManager.IsGenerationCurrent(accountGeneration))
                return false;

            return AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                SettingsManager.Shared.HuixinAuthToken = token);
        }
    }

    private bool TryResolveSchoolNetRetryToken(
        string expiredToken,
        long tokenGeneration,
        long accountGeneration,
        out string? retryToken)
    {
        lock (_tokenStateLock)
        {
            if (_tokenRequestGeneration != tokenGeneration ||
                !AccountSessionManager.IsGenerationCurrent(accountGeneration))
            {
                retryToken = null;
                return false;
            }

            retryToken = SettingsManager.Shared.HuixinAuthToken;
            if (string.Equals(retryToken, expiredToken, StringComparison.Ordinal))
            {
                if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                    SettingsManager.Shared.HuixinAuthToken = null))
                {
                    retryToken = null;
                    return false;
                }
                retryToken = null;
            }
            return true;
        }
    }

    private static string? TryGetShowDataString(JsonElement showData, string key)
    {
        if (showData.TryGetProperty(key, out var elem))
            return JsonElementToString(elem);
        return null;
    }

    internal static string JsonElementToString(JsonElement elem)
    {
        return elem.ValueKind switch
        {
            JsonValueKind.String => elem.GetString() ?? string.Empty,
            JsonValueKind.Number => elem.GetRawText(),
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            _ => elem.GetRawText()
        };
    }

    private static bool TryExtractDouble(string text, out double value)
    {
        var m = Regex.Match(text, @"-?[0-9]+(?:\.[0-9]+)?");
        if (m.Success && double.TryParse(m.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out value))
            return true;
        value = 0;
        return false;
    }

    internal static string EncodeFormField(string input)
    {
        if (string.IsNullOrEmpty(input))
            return string.Empty;
        return Uri.EscapeDataString(input);
    }
}

public sealed class CampusCardService
{
    public static CampusCardService Shared { get; } = new CampusCardService();

    public CampusCardData? LatestData { get; private set; }

    private readonly object _stateLock = new();
    private long _requestGeneration;
    private readonly string _cacheFilePath;
    private readonly HttpClient _httpClient;

    private const string StaleRequestMessage = "一卡通查询请求已更新，已忽略旧查询结果";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    private CampusCardService()
    {
        var appData = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "HFUTCampusNet");
        Directory.CreateDirectory(appData);
        _cacheFilePath = Path.Combine(appData, "campus_card_cache.json");

        var handler = new HttpClientHandler
        {
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
        };
        _httpClient = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(12)
        };

        LoadCachedData();
    }

    private void LoadCachedData()
    {
        try
        {
            if (!File.Exists(_cacheFilePath))
                return;

            var json = File.ReadAllText(_cacheFilePath, Encoding.UTF8);
            var cached = JsonSerializer.Deserialize<CampusCardData>(json, JsonOptions);
            if (cached != null)
            {
                LatestData = cached;
            }
        }
        catch
        {
            // Ignore malformed cache
        }
    }

    private void SaveCachedData(CampusCardData data)
    {
        LatestData = data;
        try
        {
            var json = JsonSerializer.Serialize(data, JsonOptions);
            File.WriteAllText(_cacheFilePath, json, Encoding.UTF8);
        }
        catch
        {
            // Ignore IO errors
        }
    }

    public void ClearCache()
    {
        lock (_stateLock)
        {
            _requestGeneration++;
            LatestData = null;
            try
            {
                if (File.Exists(_cacheFilePath))
                    File.Delete(_cacheFilePath);
            }
            catch { }
        }

        AppEvents.InvokeOnUI(AppEvents.RaiseCampusCardUpdated);
    }

    public void FetchData(Action<CampusCardData?, string?>? completion = null)
    {
        var accountGeneration = AccountSessionManager.Generation;
        _ = Task.Run(async () =>
        {
            var (data, err) = await FetchDataAsync();
            if (completion != null && AccountSessionManager.IsGenerationCurrent(accountGeneration))
            {
                AppEvents.InvokeOnUI(() =>
                {
                    if (AccountSessionManager.IsGenerationCurrent(accountGeneration))
                        completion(data, err);
                });
            }
        });
    }

    /// <summary>
    /// 拉取校园卡余额与近期消费账单（自动复用或静默获取慧新易校 Token）
    /// </summary>
    public async Task<(CampusCardData? Data, string? ErrorMessage)> FetchDataAsync()
    {
        var accountGeneration = AccountSessionManager.Generation;
        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration))
            return (null, StaleRequestMessage);
        long generation;
        lock (_stateLock)
        {
            generation = ++_requestGeneration;
        }

        string? token = null;
        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
            token = SettingsManager.Shared.HuixinAuthToken))
            return (null, StaleRequestMessage);
        if (!string.IsNullOrWhiteSpace(token))
        {
            return await ExecuteCardQueryAsync(token!, generation, accountGeneration, allowRetry: true);
        }

        var (newToken, loginErr) = await ElectricityService.Shared.ObtainHuiXinTokenAsync(
            tokenValue => TryPersistTokenForCurrentRequest(generation, accountGeneration, tokenValue),
            accountGeneration);
        if (!IsCurrentRequest(generation, accountGeneration))
            return (null, StaleRequestMessage);
        if (string.IsNullOrWhiteSpace(newToken))
        {
            return (null, loginErr ?? "慧新易校授权失败，请核对学号与密码");
        }

        return await ExecuteCardQueryAsync(newToken!, generation, accountGeneration, allowRetry: false);
    }

    private async Task<(CampusCardData? Data, string? ErrorMessage)> ExecuteCardQueryAsync(
        string token,
        long generation,
        long accountGeneration,
        bool allowRetry,
        bool useLegacyEndpoint = false)
    {
        if (!IsCurrentRequest(generation, accountGeneration))
            return (null, StaleRequestMessage);

        var authHeader = token.StartsWith("bearer ", StringComparison.OrdinalIgnoreCase)
            ? token
            : $"bearer {token}";

        try
        {
            var cardUrl = useLegacyEndpoint
                ? "http://121.251.19.62/berserker-app/ykt/tsm/queryCard"
                : "http://121.251.19.62/berserker-app/ykt/tsm/getCampusCards?synAccessSource=h5";
            using var cardReq = new HttpRequestMessage(HttpMethod.Get, cardUrl);
            cardReq.Headers.TryAddWithoutValidation("synjones-auth", authHeader);
            cardReq.Headers.TryAddWithoutValidation("Authorization", authHeader);
            cardReq.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15");

            using var resp = await _httpClient.SendAsync(cardReq);
            if (!IsCurrentRequest(generation, accountGeneration))
                return (null, StaleRequestMessage);

            int httpStatus = (int)resp.StatusCode;
            var respText = await resp.Content.ReadAsStringAsync();
            if (!IsCurrentRequest(generation, accountGeneration))
                return (null, StaleRequestMessage);

            JsonDocument? doc = null;
            int jsonCode = httpStatus;
            try
            {
                doc = JsonDocument.Parse(respText);
                if (doc.RootElement.ValueKind == JsonValueKind.Object &&
                    doc.RootElement.TryGetProperty("code", out var cElem) &&
                    cElem.ValueKind == JsonValueKind.Number &&
                    cElem.TryGetInt32(out int cVal))
                {
                    jsonCode = cVal;
                }
            }
            catch { }

            using (doc)
            {
                if (httpStatus == 401 || httpStatus == 403 || jsonCode == 401 || jsonCode == 403)
                {
                    ClearExpiredTokenIfCurrent(token, generation, accountGeneration);
                    if (allowRetry)
                    {
                        var (newToken, retryErr) = await ElectricityService.Shared.ObtainHuiXinTokenAsync(
                            tokenValue => TryPersistTokenForCurrentRequest(generation, accountGeneration, tokenValue),
                            accountGeneration);
                        if (!IsCurrentRequest(generation, accountGeneration))
                            return (null, StaleRequestMessage);
                        if (!string.IsNullOrWhiteSpace(newToken))
                        {
                            return await ExecuteCardQueryAsync(newToken!, generation, accountGeneration, allowRetry: false, useLegacyEndpoint: useLegacyEndpoint);
                        }
                        return (null, retryErr ?? "慧新易校授权已过期，请核对学号与密码");
                    }
                    return (null, "慧新易校授权已过期，请核对学号与密码");
                }

                if (doc == null || doc.RootElement.ValueKind != JsonValueKind.Object)
                {
                    if (!useLegacyEndpoint)
                        return await ExecuteCardQueryAsync(token, generation, accountGeneration, allowRetry: false, useLegacyEndpoint: true);
                    return (null, "未能解析到校园一卡通账户信息");
                }

                var root = doc.RootElement;
                var dataElem = root.TryGetProperty("data", out var dataValue) ? dataValue : default;
                JsonElement cardArrElem = default;
                bool hasCards = dataElem.ValueKind == JsonValueKind.Array;
                if (hasCards)
                {
                    cardArrElem = dataElem;
                }
                else if (dataElem.ValueKind == JsonValueKind.Object)
                {
                    foreach (var key in new[] { "card", "cards", "cardList", "list" })
                    {
                        if (dataElem.TryGetProperty(key, out cardArrElem))
                        {
                            hasCards = true;
                            break;
                        }
                    }
                }
                if (!hasCards || cardArrElem.ValueKind != JsonValueKind.Array || cardArrElem.GetArrayLength() == 0)
                {
                    if (!useLegacyEndpoint)
                        return await ExecuteCardQueryAsync(token, generation, accountGeneration, allowRetry: false, useLegacyEndpoint: true);
                    return (null, "未能解析到校园一卡通账户信息");
                }

                var firstCard = cardArrElem[0];
                var account = GetJsonString(firstCard, "account") ?? string.Empty;
                var holderName = (GetJsonString(firstCard, "name") ?? string.Empty).Trim();
                var deptName = GetJsonString(firstCard, "department_name")?.Trim();
                int dbBalanceFen = GetJsonInt(firstCard, "db_balance") ?? 0;
                int unsettleFen = GetJsonInt(firstCard, "unsettle_amount") ?? 0;
                int lostFlag = GetJsonInt(firstCard, "lostflag") ?? 0;
                int freezeFlag = GetJsonInt(firstCard, "freezeflag") ?? 0;

                string statusText = lostFlag != 0 ? "已挂失" : (freezeFlag != 0 ? "已冻结" : "正常");
                double balanceRMB = dbBalanceFen / 100.0;
                double unsettleRMB = unsettleFen / 100.0;

                var fetchedTransactions = await FetchTransactionsAsync(authHeader, 150);
                if (!IsCurrentRequest(generation, accountGeneration))
                    return (null, StaleRequestMessage);

                List<CampusCardTransaction> previousTransactions;
                lock (_stateLock)
                {
                    previousTransactions = _requestGeneration == generation &&
                        AccountSessionManager.IsGenerationCurrent(accountGeneration) &&
                        LatestData?.CardAccount == account
                        ? LatestData.Transactions?.ToList() ?? new List<CampusCardTransaction>()
                        : new List<CampusCardTransaction>();
                }
                var transactions = MergeTransactions(previousTransactions.Concat(fetchedTransactions));

                var cardData = new CampusCardData
                {
                    CardAccount = account,
                    HolderName = holderName,
                    DepartmentName = deptName,
                    BalanceRMB = balanceRMB,
                    UnsettleAmountRMB = unsettleRMB,
                    CardStatusText = statusText,
                    Transactions = transactions,
                    LastUpdated = DateTime.Now
                };

                if (!await CommitFetchedDataAsync(cardData, generation, accountGeneration).ConfigureAwait(false))
                    return (null, StaleRequestMessage);

                return (cardData, null);
            }
        }
        catch (Exception ex)
        {
            return (null, ex.Message);
        }
    }

    private bool IsCurrentRequest(long generation, long accountGeneration)
    {
        lock (_stateLock)
        {
            return _requestGeneration == generation &&
                AccountSessionManager.IsGenerationCurrent(accountGeneration);
        }
    }

    private void ClearExpiredTokenIfCurrent(string token, long generation, long accountGeneration)
    {
        lock (_stateLock)
        {
            if (_requestGeneration != generation ||
                !AccountSessionManager.IsGenerationCurrent(accountGeneration)) return;
            AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
            {
                if (string.Equals(SettingsManager.Shared.HuixinAuthToken, token, StringComparison.Ordinal))
                    SettingsManager.Shared.HuixinAuthToken = null;
            });
        }
    }

    private bool TryPersistTokenForCurrentRequest(long generation, long accountGeneration, string token)
    {
        lock (_stateLock)
        {
            if (_requestGeneration != generation ||
                !AccountSessionManager.IsGenerationCurrent(accountGeneration))
                return false;

            return AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                SettingsManager.Shared.HuixinAuthToken = token);
        }
    }

    private Task<bool> CommitFetchedDataAsync(CampusCardData data, long generation, long accountGeneration)
    {
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        AppEvents.InvokeOnUI(() =>
        {
            try
            {
                bool committed = false;
                lock (_stateLock)
                {
                    if (_requestGeneration == generation &&
                        AccountSessionManager.IsGenerationCurrent(accountGeneration))
                    {
                        committed = AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                        {
                            SaveCachedData(data);
                            CheckLowBalanceAndBudgetWarning(data);
                            AppEvents.RaiseCampusCardUpdated();
                        });
                    }
                }
                completion.TrySetResult(committed);
            }
            catch (Exception ex)
            {
                completion.TrySetException(ex);
            }
        });
        return completion.Task;
    }

    private async Task<List<CampusCardTransaction>> FetchTransactionsAsync(string authHeader, int size)
    {
        const int maximumPages = 100;
        var byId = new Dictionary<string, CampusCardTransaction>(StringComparer.Ordinal);

        for (var page = 1; page <= maximumPages; page++)
        {
            try
            {
                var url = $"http://121.251.19.62/berserker-search/search/personal/turnover?current={page}&size={size}&synAccessSource=h5";
                using var req = new HttpRequestMessage(HttpMethod.Get, url);
                req.Headers.TryAddWithoutValidation("synjones-auth", authHeader);
                req.Headers.TryAddWithoutValidation("Authorization", authHeader);
                req.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15");

                using var resp = await _httpClient.SendAsync(req);
                var respText = await resp.Content.ReadAsStringAsync();
                if (!resp.IsSuccessStatusCode || string.IsNullOrWhiteSpace(respText) ||
                    (!respText.TrimStart().StartsWith("{") && !respText.TrimStart().StartsWith("[")))
                {
                    break;
                }

                using var doc = JsonDocument.Parse(respText);
                if (doc.RootElement.ValueKind != JsonValueKind.Object ||
                    !doc.RootElement.TryGetProperty("data", out var dataElem) ||
                    dataElem.ValueKind != JsonValueKind.Object ||
                    !dataElem.TryGetProperty("records", out var recordsElem) ||
                    recordsElem.ValueKind != JsonValueKind.Array)
                {
                    break;
                }

                foreach (var rec in recordsElem.EnumerateArray())
                {
                    var resume = GetJsonString(rec, "resume") ?? "校园卡交易";
                    var turnoverType = GetJsonString(rec, "turnoverType") ?? "消费";
                    var jnTimeStr = GetJsonString(rec, "jndatetimeStr")
                        ?? GetJsonString(rec, "effectdateStr")
                        ?? string.Empty;
                    int tranAmtFen = GetJsonInt(rec, "tranamt") ?? 0;
                    int? cardBalFen = GetJsonInt(rec, "cardBalance");
                    var orderId = GetJsonString(rec, "orderId");
                    if (string.IsNullOrWhiteSpace(orderId))
                    {
                        orderId = $"tx-{jnTimeStr}|{resume}|{turnoverType}|{tranAmtFen}|{cardBalFen?.ToString(CultureInfo.InvariantCulture) ?? "-1"}";
                    }

                    byId[orderId] = new CampusCardTransaction
                    {
                        Id = orderId,
                        MerchantName = resume,
                        AmountRMB = Math.Abs(tranAmtFen) / 100.0,
                        BalanceAfterRMB = cardBalFen.HasValue ? cardBalFen.Value / 100.0 : null,
                        TurnoverType = turnoverType,
                        DateTimeString = jnTimeStr
                    };
                }

                int? total = GetJsonInt(dataElem, "total");
                int? totalPages = GetJsonInt(dataElem, "pages");
                bool reachedEnd = recordsElem.GetArrayLength() == 0 || recordsElem.GetArrayLength() < size ||
                    (total.HasValue && byId.Count >= total.Value) ||
                    (totalPages.HasValue && page >= totalPages.Value);
                if (reachedEnd) break;
            }
            catch
            {
                // Keep already fetched pages; the caller merges them with same-card cached history.
                break;
            }
        }

        return MergeTransactions(byId.Values);
    }

    private void CheckLowBalanceAndBudgetWarning(CampusCardData data)
    {
        double threshold = SettingsManager.Shared.CampusCardLowWarningThreshold;
        string todayStr = CourseCalendarHelper.DateString(DateTime.Now);

        if (data.BalanceRMB < threshold && SettingsManager.Shared.LastNotifiedLowCardBalanceDate != todayStr)
        {
            SettingsManager.Shared.LastNotifiedLowCardBalanceDate = todayStr;
            NotificationHelper.Send(
                "💳 校园一卡通余额不足预警",
                $"当前卡内余额仅剩 {data.DisplayBalance}，已低于预警线 ({threshold:F0}元)，去食堂或超市前请记得在慧新易校或支付宝充值！",
                "campus_card_low_warning");
        }
    }

    private static List<CampusCardTransaction> MergeTransactions(IEnumerable<CampusCardTransaction> transactions)
    {
        var byId = new Dictionary<string, CampusCardTransaction>(StringComparer.Ordinal);
        var index = 0;
        foreach (var transaction in transactions)
        {
            var stableId = string.IsNullOrEmpty(transaction.Id)
                ? $"{transaction.DateTimeString}|{transaction.MerchantName}|{transaction.TurnoverType}|{transaction.AmountRMB.ToString(CultureInfo.InvariantCulture)}|{index}"
                : transaction.Id;
            byId[stableId] = transaction;
            index++;
        }

        return byId.Values
            .OrderByDescending(transaction => transaction.DateTimeString, StringComparer.Ordinal)
            .ThenByDescending(transaction => transaction.Id, StringComparer.Ordinal)
            .ToList();
    }

    private static string? GetJsonString(JsonElement obj, string propName)
    {
        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(propName, out var val))
        {
            if (val.ValueKind == JsonValueKind.String)
                return val.GetString();
            if (val.ValueKind == JsonValueKind.Number)
                return val.GetRawText();
        }
        return null;
    }

    private static int? GetJsonInt(JsonElement obj, string propName)
    {
        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(propName, out var val))
        {
            if (val.ValueKind == JsonValueKind.Number)
            {
                if (val.TryGetInt32(out int i))
                    return i;
                if (val.TryGetDouble(out double d))
                    return (int)d;
            }
            else if (val.ValueKind == JsonValueKind.String &&
                     double.TryParse(val.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out double ds))
            {
                return (int)ds;
            }
        }
        return null;
    }
}
