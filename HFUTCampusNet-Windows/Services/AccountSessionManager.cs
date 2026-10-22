using System.Threading;

namespace HFUTCampusNet;

public static class AccountSessionManager
{
    private static long _generation;

    public static long Generation => Interlocked.Read(ref _generation);

    public static void InvalidateForAccountSwitch(
        string newUsername,
        bool preserveCourseWebViewCookies = false)
    {
        Interlocked.Increment(ref _generation);

        var settings = SettingsManager.Shared;
        settings.PortalUsername = newUsername;
        UnifiedLoginWebWindow.ClearAuthCookiesForAccountSwitch();
        LoginWebWindow.ClearAuthCookiesForAccountSwitch();
        if (!preserveCourseWebViewCookies)
            CourseLoginWebWindow.ClearAuthCookiesForAccountSwitch();
        ElectricityService.Shared.ClearAccountScopedCache();
        EmptyClassroomService.Shared.CancelPendingAuthentication();
        CourseScheduleService.Shared.ClearSchedule();
        CampusCardService.Shared.ClearCache();

        settings.SessionCookie = string.Empty;
        settings.CourseSessionCookie = string.Empty;
        settings.CasTgcCookie = string.Empty;
        settings.HuixinAuthToken = string.Empty;
        settings.UniAppJwt = string.Empty;
        settings.JxglstuDefaultPasswordCache = string.Empty;
        settings.CourseStudentId = string.Empty;
        settings.LastNotifiedLowElectricityDate = string.Empty;
        settings.LastNotifiedLowCardBalanceDate = string.Empty;
        AcademicService.Shared.ClearCache();

        settings.Save();

        AppEvents.RaiseAuthStatusUpdated();
    }
}
