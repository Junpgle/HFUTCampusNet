using System;
using System.Diagnostics;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
namespace HFUTCampusNet;

/// <summary>
/// 1:1 Windows Port of main.swift.
/// Application entry point: Single-instance Mutex enforcement,
/// WPF Application initialization with ShutdownMode.OnExplicitShutdown,
/// System Tray & Desktop Widget setup, and background service lifecycle start.
/// </summary>
public static class Program
{
    private const string MutexName = "Global\\HFUTCampusNet_SingleInstance_Mutex_2026";
    private static Mutex? _instanceMutex;

    [STAThread]
    public static void Main(string[] args)
    {
        // 1. Single instance enforcement
        _instanceMutex = new Mutex(true, MutexName, out bool isOnlyInstance);
        if (!isOnlyInstance)
        {
            MessageBox.Show(
                "合工大校园助手已经在运行中，请在任务栏右下角系统托盘区查看图标。",
                "提示",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }

        try
        {
            // 2. Create and configure WPF Application
            var app = new Application
            {
                ShutdownMode = ShutdownMode.OnExplicitShutdown
            };
            ThemeManager.Shared.InitializeApplicationControlStyles();

            // Setup global exception handling
            SetupExceptionHandling(app);

            // Startup handler
            app.Startup += (_, _) =>
            {
                OnApplicationStartup();
            };

            // Exit handler
            app.Exit += (_, _) =>
            {
                OnApplicationExit();
            };

            // 3. Run application loop
            app.Run();
        }
        finally
        {
            if (_instanceMutex != null)
            {
                try
                {
                    _instanceMutex.ReleaseMutex();
                    _instanceMutex.Dispose();
                }
                catch { }
                _instanceMutex = null;
            }
        }
    }

    private static void OnApplicationStartup()
    {
        // A. Initialize System Tray Controller (NotifyIcon, menus, alerts)
        TrayMenuController.Shared.Initialize();

        // B. Initialize and show Desktop Widget if configured
        var widget = DesktopWidgetWindow.Shared;
        if (SettingsManager.Shared.ShowDesktopWidget)
        {
            widget.SetWidgetVisible(true);
        }

        // C. Start Campus Network monitoring
        CampusNetworkClient.Shared.StartMonitoring();

        // D. Trigger initial sync for auxiliary services
        if (SettingsManager.Shared.IsDormConfigured)
        {
            ElectricityService.Shared.FetchData();
        }

        CampusCardService.Shared.FetchData();

        // E. Start Academic & Empty Classroom monitoring
        AcademicService.Shared.StartMonitoring();
        EmptyClassroomService.Shared.StartMonitoring();

        // F. Try background course schedule sync if enabled
        if (SettingsManager.Shared.CourseTableEnabled)
        {
            CourseScheduleService.Shared.TryBackgroundLogin();
        }

        // G. Check updates in background if enabled
        if (SettingsManager.Shared.AutoCheckUpdate)
        {
            UpdateChecker.Shared.CheckForUpdates(manual: false, (release, _) =>
            {
                if (release != null)
                {
                    AppEvents.InvokeOnUI(() =>
                    {
                        TrayMenuController.Shared.ShowNotification(
                            "发现新版本",
                            $"合工大校园助手 v{release.Version} 已发布，点击托盘菜单可查看更新内容。");
                    });
                }
            });
        }
    }

    private static void OnApplicationExit()
    {
        try
        {
            SettingsManager.Shared.Save();
            TrayMenuController.Shared.Dispose();
            DesktopWidgetWindow.Shared.Close();
            CampusNetworkClient.Shared.StopMonitoring();
            AcademicService.Shared.StopMonitoring();
            EmptyClassroomService.Shared.StopMonitoring();
        }
        catch { }
    }

    private static void SetupExceptionHandling(Application app)
    {
        app.DispatcherUnhandledException += (s, e) =>
        {
            Debug.WriteLine($"[WPF Dispatcher Error]: {e.Exception}");
            e.Handled = true; // Prevent crash on minor UI dispatcher exceptions
        };

        AppDomain.CurrentDomain.UnhandledException += (s, e) =>
        {
            Debug.WriteLine($"[AppDomain Unhandled Exception]: {e.ExceptionObject}");
        };

        TaskScheduler.UnobservedTaskException += (s, e) =>
        {
            Debug.WriteLine($"[TaskScheduler Unobserved Task Exception]: {e.Exception}");
            e.SetObserved(); // Prevent app crashing from background task network exceptions
        };
    }
}
