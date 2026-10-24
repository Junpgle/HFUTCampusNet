using System;
using System.Threading;

namespace HFUTCampusNet;

public static class AccountSessionManager
{
    private static long _generation;
    private static int _switchInProgress;
    private static readonly object GenerationGate = new();
    private static readonly object SwitchGate = new();

    public static long Generation => Interlocked.Read(ref _generation);

    public static bool IsGenerationCurrent(long generation)
    {
        lock (GenerationGate)
        {
            return Volatile.Read(ref _switchInProgress) == 0 && generation == Generation;
        }
    }

    public static bool TryRunForGeneration(long generation, Action action)
    {
        lock (GenerationGate)
        {
            if (!IsGenerationCurrent(generation)) return false;
            action();
            return true;
        }
    }

    public static void InvalidateForAccountSwitch(
        string newUsername,
        bool preserveCourseWebViewCookies = false,
        bool preserveSavedPasswords = false)
    {
        lock (SwitchGate)
        {
            lock (GenerationGate)
            {
                Volatile.Write(ref _switchInProgress, 1);
                Interlocked.Increment(ref _generation);
            }

            try
            {
                var settings = SettingsManager.Shared;
                if (!preserveSavedPasswords)
                {
                    settings.PortalPassword = string.Empty;
                    settings.CasPassword = string.Empty;
                }
                CampusHistoryManager.Shared.ActivateCurrentFlowAccount(newUsername);
                UnifiedLoginWebWindow.ClearAuthCookiesForAccountSwitch();
                LoginWebWindow.ClearAuthCookiesForAccountSwitch();
                if (!preserveCourseWebViewCookies)
                    CourseLoginWebWindow.ClearAuthCookiesForAccountSwitch();
                CampusNetworkClient.Shared.ClearAccountScopedData();
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

                // Persist the new identity only after clearing account-scoped data so an interrupted switch
                // cannot leave the new username paired with the previous account's caches.
                settings.PortalUsername = newUsername;
                settings.Save();

                AppEvents.RaiseAuthStatusUpdated();
            }
            finally
            {
                lock (GenerationGate)
                {
                    Volatile.Write(ref _switchInProgress, 0);
                }
            }
        }
    }
}
