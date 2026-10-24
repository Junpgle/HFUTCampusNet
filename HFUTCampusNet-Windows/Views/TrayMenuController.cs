using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Interop;
using System.Windows.Threading;
using WinForms = System.Windows.Forms;
using MediaColor = System.Windows.Media.Color;
using MediaBrushes = System.Windows.Media.Brushes;
using System.Windows.Markup;

namespace HFUTCampusNet;

/// <summary>
/// 1:1 Windows Port of MenubarQuoteCardView.swift (CampusQuotaCardView).
/// Displays Daily Free Quota (30GB) and Monthly Total Quota (200GB/400GB) progress bars
/// inside the top of the System Tray menu or History Stats window.
/// </summary>
public class CampusQuotaCardControl : Border
{
    private readonly TextBlock _dailyValueLabel;
    private readonly Border _dailyBarTrack;
    private readonly Border _dailyBarFill;

    private readonly TextBlock _monthlyTitleLabel;
    private readonly TextBlock _monthlyValueLabel;
    private readonly Border _monthlyBarTrack;
    private readonly Border _monthlyBarFill;

    private readonly TextBlock _footerLeftLabel;
    private readonly TextBlock _footerRightLabel;

    private double _dailyRatio;
    private double _monthlyRatio;

    public CampusQuotaCardControl(bool compact = false)
    {
        CornerRadius = new CornerRadius(10);
        Padding = compact ? new Thickness(12, 10, 12, 10) : new Thickness(14, 12, 14, 12);
        Margin = compact ? new Thickness(6, 4, 6, 4) : new Thickness(0);
        MinWidth = compact ? 290 : 300;
        Background = ThemeManager.Shared.IsDarkTheme
            ? new SolidColorBrush(MediaColor.FromArgb(245, 34, 36, 44))
            : new SolidColorBrush(MediaColor.FromArgb(250, 255, 255, 255));
        BorderBrush = ThemeManager.Shared.CardBorderBrush;
        BorderThickness = new Thickness(1);

        var root = new StackPanel { Orientation = Orientation.Vertical };

        // Daily section header
        var dailyHeader = new DockPanel { Margin = new Thickness(0, 0, 0, 5) };
        var dailyTitle = new TextBlock
        {
            Text = "今日免费额度 (30 GB)",
            FontSize = 11.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeManager.Shared.TextPrimary
        };
        _dailyValueLabel = new TextBlock
        {
            Text = "-- / 30 GB",
            FontSize = 11,
            FontWeight = FontWeights.Medium,
            Foreground = ThemeManager.Shared.TextSecondary,
            HorizontalAlignment = HorizontalAlignment.Right
        };
        DockPanel.SetDock(dailyTitle, Dock.Left);
        DockPanel.SetDock(_dailyValueLabel, Dock.Right);
        dailyHeader.Children.Add(dailyTitle);
        dailyHeader.Children.Add(_dailyValueLabel);
        root.Children.Add(dailyHeader);

        // Daily bar
        _dailyBarTrack = new Border
        {
            Height = 7,
            CornerRadius = new CornerRadius(3.5),
            Background = ThemeManager.Shared.IsDarkTheme
                ? new SolidColorBrush(MediaColor.FromArgb(45, 255, 255, 255))
                : new SolidColorBrush(MediaColor.FromArgb(35, 0, 0, 0)),
            Margin = new Thickness(0, 0, 0, 10),
            ClipToBounds = true
        };
        _dailyBarFill = new Border
        {
            Height = 7,
            CornerRadius = new CornerRadius(3.5),
            HorizontalAlignment = HorizontalAlignment.Left,
            Width = 0,
            Background = new SolidColorBrush(MediaColor.FromRgb(52, 199, 89))
        };
        _dailyBarTrack.Child = _dailyBarFill;
        _dailyBarTrack.SizeChanged += (_, _) => UpdateBarWidths();
        root.Children.Add(_dailyBarTrack);

        // Monthly section header
        var monthlyHeader = new DockPanel { Margin = new Thickness(0, 0, 0, 5) };
        _monthlyTitleLabel = new TextBlock
        {
            Text = "本月累计流量 (200 GB)",
            FontSize = 11.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeManager.Shared.TextPrimary
        };
        _monthlyValueLabel = new TextBlock
        {
            Text = "-- / 200 GB",
            FontSize = 11,
            FontWeight = FontWeights.Medium,
            Foreground = ThemeManager.Shared.TextSecondary,
            HorizontalAlignment = HorizontalAlignment.Right
        };
        DockPanel.SetDock(_monthlyTitleLabel, Dock.Left);
        DockPanel.SetDock(_monthlyValueLabel, Dock.Right);
        monthlyHeader.Children.Add(_monthlyTitleLabel);
        monthlyHeader.Children.Add(_monthlyValueLabel);
        root.Children.Add(monthlyHeader);

        // Monthly bar
        _monthlyBarTrack = new Border
        {
            Height = 7,
            CornerRadius = new CornerRadius(3.5),
            Background = ThemeManager.Shared.IsDarkTheme
                ? new SolidColorBrush(MediaColor.FromArgb(45, 255, 255, 255))
                : new SolidColorBrush(MediaColor.FromArgb(35, 0, 0, 0)),
            Margin = new Thickness(0, 0, 0, 8),
            ClipToBounds = true
        };
        _monthlyBarFill = new Border
        {
            Height = 7,
            CornerRadius = new CornerRadius(3.5),
            HorizontalAlignment = HorizontalAlignment.Left,
            Width = 0,
            Background = ThemeManager.Shared.Accent
        };
        _monthlyBarTrack.Child = _monthlyBarFill;
        _monthlyBarTrack.SizeChanged += (_, _) => UpdateBarWidths();
        root.Children.Add(_monthlyBarTrack);

        // Footer row
        var footerRow = new DockPanel();
        _footerLeftLabel = new TextBlock
        {
            Text = "今日剩余 30.0 GB",
            FontSize = 10.5,
            Foreground = ThemeManager.Shared.TextMuted
        };
        _footerRightLabel = new TextBlock
        {
            Text = "点击查看详细报表 ›",
            FontSize = 10.5,
            Foreground = ThemeManager.Shared.Accent,
            HorizontalAlignment = HorizontalAlignment.Right
        };
        DockPanel.SetDock(_footerLeftLabel, Dock.Left);
        DockPanel.SetDock(_footerRightLabel, Dock.Right);
        footerRow.Children.Add(_footerLeftLabel);
        footerRow.Children.Add(_footerRightLabel);
        root.Children.Add(footerRow);

        Child = root;
    }

    public void UpdateQuota(double todayUsedMB, double monthUsedMB, string? balanceStr)
    {
        double todayUsedGB = Math.Max(0, todayUsedMB / 1024.0);
        const double dailyLimitGB = 30.0;
        _dailyRatio = Math.Clamp(todayUsedGB / dailyLimitGB, 0.0, 1.0);
        double todayRemainGB = Math.Max(0.0, dailyLimitGB - todayUsedGB);

        _dailyValueLabel.Text = $"{todayUsedGB:F2} / 30 GB ({_dailyRatio * 100.0:F0}%)";
        if (_dailyRatio >= 0.90)
            _dailyBarFill.Background = new SolidColorBrush(MediaColor.FromRgb(255, 69, 58));
        else if (_dailyRatio >= 0.70)
            _dailyBarFill.Background = new SolidColorBrush(MediaColor.FromRgb(255, 159, 10));
        else
            _dailyBarFill.Background = new SolidColorBrush(MediaColor.FromRgb(52, 199, 89));

        double monthUsedGB = Math.Max(0, monthUsedMB / 1024.0);
        double monthLimitGB = monthUsedGB > 200.0 ? 400.0 : 200.0;
        _monthlyRatio = Math.Clamp(monthUsedGB / monthLimitGB, 0.0, 1.0);

        _monthlyTitleLabel.Text = $"本月累计流量 ({monthLimitGB:F0} GB)";
        _monthlyValueLabel.Text = $"{monthUsedGB:F1} / {monthLimitGB:F0} GB ({_monthlyRatio * 100.0:F0}%)";
        if (_monthlyRatio >= 0.90)
            _monthlyBarFill.Background = new SolidColorBrush(MediaColor.FromRgb(255, 69, 58));
        else if (_monthlyRatio >= 0.75)
            _monthlyBarFill.Background = new SolidColorBrush(MediaColor.FromRgb(255, 159, 10));
        else
            _monthlyBarFill.Background = new SolidColorBrush(MediaColor.FromRgb(10, 132, 255));

        string balDisplay = string.IsNullOrWhiteSpace(balanceStr) || balanceStr == "--" ? "--" : $"¥{balanceStr}";
        _footerLeftLabel.Text = $"今日剩余 {todayRemainGB:F1} GB · 网费余额 {balDisplay}";

        UpdateBarWidths();
    }

    private void UpdateBarWidths()
    {
        if (_dailyBarTrack.ActualWidth > 0)
            _dailyBarFill.Width = Math.Max(4, _dailyBarTrack.ActualWidth * _dailyRatio);
        if (_monthlyBarTrack.ActualWidth > 0)
            _monthlyBarFill.Width = Math.Max(4, _monthlyBarTrack.ActualWidth * _monthlyRatio);
    }
}

/// <summary>
/// 1:1 Windows Port of MenubarController.swift.
/// Provides the Windows System Tray NotifyIcon, rotating tooltip/status summary,
/// native balloon notifications, and rich dark-mode ContextMenu with all submenus.
/// </summary>
public sealed class TrayMenuController : IDisposable
{
    public static TrayMenuController Shared { get; } = new TrayMenuController();

    private const int WhMouseLl = 14;
    private const int WmLButtonDown = 0x0201;
    private const int WmRButtonDown = 0x0204;
    private const int WmMButtonDown = 0x0207;
    private const int WmXButtonDown = 0x020B;
    private const int WmNcLButtonDown = 0x00A1;
    private const int WmNcRButtonDown = 0x00A4;
    private const int WmNcMButtonDown = 0x00A7;
    private const uint GaRoot = 2;

    private delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LowLevelMouseData
    {
        public NativePoint Point;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern bool DestroyIcon(IntPtr handle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? moduleName);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc callback, IntPtr moduleHandle, uint threadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hookHandle);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hookHandle, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(NativePoint point);

    [DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr windowHandle, uint flags);

    [DllImport("user32.dll")]
    private static extern bool IsChild(IntPtr parentHandle, IntPtr childHandle);

    private WinForms.NotifyIcon? _notifyIcon;
    private ContextMenu? _contextMenu;
    private CampusQuotaCardControl? _quotaCardControl;
    private readonly LowLevelMouseProc _outsideClickHookProc;
    private ContextMenu? _outsideClickMonitoredMenu;
    private readonly HashSet<IntPtr> _outsideClickPopupWindows = new();
    private readonly List<MenuItem> _outsideClickTrackedMenuItems = new();
    private IntPtr _outsideClickHook;

    private readonly DispatcherTimer _carouselTimer;
    private int _carouselSlotIndex;
    private bool _disposed;

    // Alert state flags (matching MenubarController.swift)
    private bool _hasShownDaily25GWarning;
    private bool _hasShownDaily29GWarning;
    private int _lastAlertDayOfYear = -1;
    private bool _hasShownLowElectricityAlert;
    private bool _hasShownLowCampusCardAlert;

    private TrayMenuController()
    {
        _outsideClickHookProc = HandleOutsideMouseClick;
        _carouselTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(Math.Max(2.0, SettingsManager.Shared.CarouselInterval))
        };
        _carouselTimer.Tick += (_, _) =>
        {
            _carouselSlotIndex = (_carouselSlotIndex + 1) % 6;
            UpdateTrayTooltip();
        };
    }

    public void Initialize()
    {
        if (_notifyIcon != null) return;

        _notifyIcon = new WinForms.NotifyIcon
        {
            Icon = CreateCampusTrayIcon(isOnline: true),
            Visible = true,
            Text = "合工大校园助手 - 正在监测"
        };

        _notifyIcon.MouseClick += (_, e) =>
        {
            if (e.Button == WinForms.MouseButtons.Right || e.Button == WinForms.MouseButtons.Left)
            {
                Application.Current?.Dispatcher.BeginInvoke(DispatcherPriority.Normal, new Action(ShowTrayContextMenu));
            }
        };

        _notifyIcon.DoubleClick += (_, _) =>
        {
            Application.Current?.Dispatcher.BeginInvoke(DispatcherPriority.Normal, new Action(() =>
            {
                HistoryStatsWindow.Shared.ShowWindow(0);
            }));
        };

        // Subscribe to AppEvents
        AppEvents.NetworkDataUpdated += () => AppEvents.InvokeOnUI(OnDataUpdated);
        AppEvents.DormElectricityUpdated += () => AppEvents.InvokeOnUI(OnDataUpdated);
        AppEvents.CampusCardUpdated += () => AppEvents.InvokeOnUI(OnDataUpdated);
        AppEvents.CourseScheduleUpdated += () => AppEvents.InvokeOnUI(OnDataUpdated);
        AppEvents.AcademicDataUpdated += () => AppEvents.InvokeOnUI(OnDataUpdated);
        AppEvents.EmptyClassroomUpdated += () => AppEvents.InvokeOnUI(OnDataUpdated);
        AppEvents.SpeedUpdated += (_, _, _) => AppEvents.InvokeOnUI(UpdateTrayTooltip);
        AppEvents.UpdateCheckFinished += () => AppEvents.InvokeOnUI(UpdateTrayTooltip);

        _carouselTimer.Start();
        UpdateTrayTooltip();
    }

    public void UpdateCarouselInterval(double seconds)
    {
        _carouselTimer.Interval = TimeSpan.FromSeconds(Math.Clamp(seconds, 2.0, 30.0));
    }

    public void ShowNotification(string title, string message, WinForms.ToolTipIcon icon = WinForms.ToolTipIcon.Info)
    {
        try
        {
            _notifyIcon?.ShowBalloonTip(4000, title, message, icon);
        }
        catch
        {
            // Ignore balloon tip errors if explorer is restarting
        }
    }

    private void OnDataUpdated()
    {
        CheckThresholdAlerts();
        UpdateTrayIconState();
        UpdateTrayTooltip();
    }

    private void CheckThresholdAlerts()
    {
        int dayOfYear = DateTime.Now.DayOfYear;
        if (_lastAlertDayOfYear != dayOfYear)
        {
            _lastAlertDayOfYear = dayOfYear;
            _hasShownDaily25GWarning = false;
            _hasShownDaily29GWarning = false;
        }

        double todayMB = SafeGetTodayUsedMB();
        double todayGB = todayMB / 1024.0;
        if (todayGB >= 29.0 && !_hasShownDaily29GWarning)
        {
            _hasShownDaily29GWarning = true;
            _hasShownDaily25GWarning = true;
            ShowNotification("今日免费流量即将耗尽", $"今日已用 {todayGB:F2} GB / 30 GB，超出部分将按流量计费。", WinForms.ToolTipIcon.Warning);
        }
        else if (todayGB >= 25.0 && !_hasShownDaily25GWarning)
        {
            _hasShownDaily25GWarning = true;
            ShowNotification("今日流量提醒", $"今日已使用 {todayGB:F1} GB，接近 30 GB 每日免费额度。", WinForms.ToolTipIcon.Info);
        }

        var elec = ElectricityService.Shared.LatestData;
        if (elec != null && elec.IsSuccess && elec.RemainingKWh.HasValue)
        {
            double kwh = elec.RemainingKWh.Value;
            double threshold = SettingsManager.Shared.ElectricityLowWarningThreshold;
            if (threshold > 0 && kwh <= threshold)
            {
                if (!_hasShownLowElectricityAlert)
                {
                    _hasShownLowElectricityAlert = true;
                    ShowNotification("宿舍电量低预警", $"{elec.RoomName} 剩余电量仅 {kwh:F1} 度，请及时充电。", WinForms.ToolTipIcon.Warning);
                }
            }
            else if (kwh > threshold + 2.0)
            {
                _hasShownLowElectricityAlert = false;
            }
        }

        var card = CampusCardService.Shared.LatestData;
        if (card != null && card.IsSuccess)
        {
            double threshold = SettingsManager.Shared.CampusCardLowWarningThreshold;
            if (threshold > 0 && card.BalanceYuan <= threshold)
            {
                if (!_hasShownLowCampusCardAlert)
                {
                    _hasShownLowCampusCardAlert = true;
                    ShowNotification("校园一卡通余额不足", $"当前卡余额 ¥{card.BalanceYuan:F2}，低于预警阈值 ¥{threshold:F0}。", WinForms.ToolTipIcon.Warning);
                }
            }
            else if (card.BalanceYuan > threshold + 5.0)
            {
                _hasShownLowCampusCardAlert = false;
            }
        }
    }

    private void UpdateTrayIconState()
    {
        if (_notifyIcon == null) return;
        var net = CampusNetworkClient.Shared.LatestData;
        bool online = net == null || net.IsSuccess || net.Status == NetworkStatus.Idle || net.Status == NetworkStatus.Loading;

        var oldIcon = _notifyIcon.Icon;
        _notifyIcon.Icon = CreateCampusTrayIcon(online);
        if (oldIcon != null)
        {
            try
            {
                DestroyIcon(oldIcon.Handle);
                oldIcon.Dispose();
            }
            catch { }
        }
    }

    private void UpdateTrayTooltip()
    {
        if (_notifyIcon == null) return;

        var net = CampusNetworkClient.Shared.LatestData;
        double todayGB = SafeGetTodayUsedMB() / 1024.0;
        double monthMB = ParseFlowToMB(net?.UsedFlow);
        string flowText = monthMB > 0 ? FormatTrafficMB(monthMB) : "--";
        string balText = !string.IsNullOrWhiteSpace(net?.Balance) && net!.Balance != "--" ? $"¥{net.Balance}" : "--";

        var elec = ElectricityService.Shared.LatestData;
        string elecText = elec != null && elec.IsSuccess && elec.RemainingKWh.HasValue
            ? $"{elec.RemainingKWh.Value:F1}度"
            : "--";

        var card = CampusCardService.Shared.LatestData;
        string cardText = card != null && card.IsSuccess ? $"¥{card.BalanceYuan:F1}" : "--";

        // NotifyIcon.Text on Windows is limited to 127 characters (63 on older shells, 127 on Win10/11)
        string tooltip = $"合工大校园助手\n月流量: {flowText} | 今日: {todayGB:F1}G\n网费: {balText} | 电费: {elecText} | 饭卡: {cardText}";
        if (tooltip.Length > 63)
        {
            tooltip = $"工大助手 月:{flowText} 日:{todayGB:F1}G\n电:{elecText} 卡:{cardText}";
        }
        if (tooltip.Length > 63)
        {
            tooltip = tooltip.Substring(0, 63);
        }

        try
        {
            _notifyIcon.Text = tooltip;
        }
        catch { }
    }

    private void ShowTrayContextMenu()
    {
        _contextMenu = BuildTrayContextMenu();
        _contextMenu.Placement = PlacementMode.MousePoint;
        _contextMenu.IsOpen = true;
    }

    private void StartOutsideClickMonitor(ContextMenu menu)
    {
        StopOutsideClickMonitor();
        _outsideClickMonitoredMenu = menu;
        AttachSubmenuStateHandlers(menu);
        RefreshOpenMenuPopupWindows();
        _outsideClickHook = SetWindowsHookEx(WhMouseLl, _outsideClickHookProc, GetModuleHandle(null), 0);

        if (_outsideClickHook == IntPtr.Zero)
        {
            int error = Marshal.GetLastWin32Error();
            Debug.WriteLine($"[Tray Menu] Could not install outside-click hook: {error}");
            StopOutsideClickMonitor(menu);
        }
    }

    private void StopOutsideClickMonitor(ContextMenu? menu = null)
    {
        if (menu != null && !ReferenceEquals(_outsideClickMonitoredMenu, menu))
        {
            return;
        }

        if (_outsideClickHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_outsideClickHook);
            _outsideClickHook = IntPtr.Zero;
        }

        foreach (var menuItem in _outsideClickTrackedMenuItems)
        {
            menuItem.SubmenuOpened -= OnSubmenuStateChanged;
            menuItem.SubmenuClosed -= OnSubmenuStateChanged;
        }

        _outsideClickTrackedMenuItems.Clear();
        _outsideClickPopupWindows.Clear();
        _outsideClickMonitoredMenu = null;
    }

    private IntPtr HandleOutsideMouseClick(int code, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (code >= 0 && IsMouseButtonDownMessage(wParam.ToInt32()) &&
                _outsideClickMonitoredMenu is { IsOpen: true } menu)
            {
                var mouseData = Marshal.PtrToStructure<LowLevelMouseData>(lParam);
                if (!IsPointInsideOpenMenu(mouseData.Point))
                {
                    menu.Dispatcher.BeginInvoke(DispatcherPriority.Send, new Action(() =>
                    {
                        if (ReferenceEquals(_outsideClickMonitoredMenu, menu) && menu.IsOpen)
                        {
                            menu.IsOpen = false;
                        }
                    }));
                }
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Tray Menu] Outside-click handling failed: {ex.Message}");
        }

        return CallNextHookEx(_outsideClickHook, code, wParam, lParam);
    }

    private static bool IsMouseButtonDownMessage(int message) => message is
        WmLButtonDown or WmRButtonDown or WmMButtonDown or WmXButtonDown or
        WmNcLButtonDown or WmNcRButtonDown or WmNcMButtonDown;

    private bool IsPointInsideOpenMenu(NativePoint point)
    {
        if (_outsideClickPopupWindows.Count == 0)
        {
            return false;
        }

        var clickedWindow = WindowFromPoint(point);
        if (clickedWindow == IntPtr.Zero)
        {
            return false;
        }

        var clickedRoot = GetAncestor(clickedWindow, GaRoot);
        return _outsideClickPopupWindows.Any(popupWindow =>
            clickedWindow == popupWindow || clickedRoot == popupWindow || IsChild(popupWindow, clickedWindow));
    }

    private void RefreshOpenMenuPopupWindows()
    {
        var menu = _outsideClickMonitoredMenu;
        if (menu == null)
        {
            return;
        }

        _outsideClickPopupWindows.Clear();
        if (PresentationSource.FromVisual(menu) is HwndSource menuSource && menuSource.Handle != IntPtr.Zero)
        {
            _outsideClickPopupWindows.Add(menuSource.Handle);
        }

        CollectOpenSubmenuPopupWindows(menu, _outsideClickPopupWindows);
    }

    private void AttachSubmenuStateHandlers(ItemsControl parent)
    {
        foreach (var item in parent.Items)
        {
            if (item is not MenuItem menuItem)
            {
                continue;
            }

            menuItem.SubmenuOpened += OnSubmenuStateChanged;
            menuItem.SubmenuClosed += OnSubmenuStateChanged;
            _outsideClickTrackedMenuItems.Add(menuItem);
            AttachSubmenuStateHandlers(menuItem);
        }
    }

    private void OnSubmenuStateChanged(object? sender, RoutedEventArgs e)
    {
        var menu = _outsideClickMonitoredMenu;
        if (menu == null)
        {
            return;
        }

        menu.Dispatcher.BeginInvoke(DispatcherPriority.ContextIdle, new Action(() =>
        {
            if (ReferenceEquals(_outsideClickMonitoredMenu, menu) && menu.IsOpen)
            {
                RefreshOpenMenuPopupWindows();
            }
        }));
    }

    private static void CollectOpenSubmenuPopupWindows(ItemsControl parent, HashSet<IntPtr> popupWindows)
    {
        foreach (var item in parent.Items)
        {
            if (item is not MenuItem menuItem)
            {
                continue;
            }

            if (menuItem.IsSubmenuOpen &&
                menuItem.Template?.FindName("PART_Popup", menuItem) is Popup { IsOpen: true, Child: Visual popupVisual } popup &&
                PresentationSource.FromVisual(popupVisual) is HwndSource popupSource &&
                popupSource.Handle != IntPtr.Zero)
            {
                popupWindows.Add(popupSource.Handle);
            }

            CollectOpenSubmenuPopupWindows(menuItem, popupWindows);
        }
    }

    private ContextMenu BuildTrayContextMenu()
    {
        var menu = new ContextMenu
        {
            Background = ThemeManager.Shared.WindowBackground,
            Foreground = ThemeManager.Shared.TextPrimary,
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(1),
            Padding = new Thickness(4, 6, 4, 6),
            HasDropShadow = true,
            StaysOpen = false
        };
        menu.Opened += (_, _) => StartOutsideClickMonitor(menu);
        menu.Closed += (_, _) =>
        {
            StopOutsideClickMonitor(menu);
            CloseOpenSubmenus(menu);
        };
        ApplyThemeToContextMenu(menu);

        var net = CampusNetworkClient.Shared.LatestData;
        double todayUsedMB = SafeGetTodayUsedMB();
        double monthUsedMB = ParseFlowToMB(net?.UsedFlow);
        if (monthUsedMB <= 0)
        {
            monthUsedMB = SafeGetMonthUsedMB();
        }

        // 1. Top Quota Card Item
        _quotaCardControl = new CampusQuotaCardControl(compact: true);
        _quotaCardControl.UpdateQuota(todayUsedMB, monthUsedMB, net?.Balance);
        _quotaCardControl.Cursor = Cursors.Hand;
        _quotaCardControl.MouseLeftButtonUp += (_, _) =>
        {
            menu.IsOpen = false;
            HistoryStatsWindow.Shared.ShowWindow(0);
        };

        var quotaMenuItem = new MenuItem
        {
            Header = _quotaCardControl,
            StaysOpenOnClick = false,
            Padding = new Thickness(0)
        };
        quotaMenuItem.Click += (_, _) => HistoryStatsWindow.Shared.ShowWindow(0);
        menu.Items.Add(quotaMenuItem);
        menu.Items.Add(CreateSeparator());

        // 2. 校园网 Submenu
        menu.Items.Add(BuildCampusNetworkMenuItem(net, todayUsedMB, monthUsedMB));

        // 3. 宿舍电费 Item
        menu.Items.Add(BuildElectricityMenuItem());

        // 4. 校园一卡通 Submenu
        menu.Items.Add(BuildCampusCardMenuItem());

        menu.Items.Add(CreateSeparator());

        // 5. 今日课程 Submenu
        if (SettingsManager.Shared.CourseTableEnabled)
        {
            menu.Items.Add(BuildCourseMenuItem());
        }

        // 6. 考试与成绩 Submenu
        menu.Items.Add(BuildAcademicMenuItem());

        // 7. 自习教室 Submenu
        menu.Items.Add(BuildEmptyClassroomMenuItem());

        menu.Items.Add(CreateSeparator());

        // 8. 用量统计与历史分析...
        var historyItem = CreateStyledMenuItem("📊 用量统计与历史分析...", "Ctrl+H");
        historyItem.Click += (_, _) => HistoryStatsWindow.Shared.ShowWindow(0);
        menu.Items.Add(historyItem);

        // 9. 统一身份认证同步...
        var ssoItem = CreateStyledMenuItem("🔐 统一身份认证同步...", null);
        ssoItem.Click += (_, _) => UnifiedLoginWebWindow.Shared.ShowWindow();
        menu.Items.Add(ssoItem);

        // 10. 立即刷新数据
        var refreshItem = CreateStyledMenuItem("🔄 立即刷新数据", "Ctrl+R");
        refreshItem.Click += (_, _) => RefreshAllDataNow();
        menu.Items.Add(refreshItem);

        // 11. 显示与刷新选项 Submenu
        menu.Items.Add(BuildDisplayAndRefreshSubmenu());

        // 12. 偏好设置...
        var settingsItem = CreateStyledMenuItem("⚙️ 偏好设置...", "Ctrl+,");
        settingsItem.Click += (_, _) => SettingsWindow.Shared.ShowWindow();
        menu.Items.Add(settingsItem);

        // 13. 检查软件更新...
        var updateInfo = UpdateChecker.Shared.AvailableUpdate;
        string updateTitle = updateInfo != null
            ? $"⬆️ 发现新版本 ({updateInfo.Version})..."
            : $"✨ 检查软件更新 (当前 v{UpdateChecker.Shared.CurrentVersion})...";
        var updateItem = CreateStyledMenuItem(updateTitle, null);
        updateItem.Click += (_, _) => CheckSoftwareUpdateManually();
        menu.Items.Add(updateItem);

        menu.Items.Add(CreateSeparator());

        // 14. 退出校园网监测
        var quitItem = CreateStyledMenuItem("⏻ 退出校园网监测", "Ctrl+Q");
        quitItem.Foreground = ThemeManager.Shared.Danger;
        quitItem.Click += (_, _) =>
        {
            Dispose();
            Application.Current?.Shutdown();
        };
        menu.Items.Add(quitItem);

        return menu;
    }

    private static void CloseOpenSubmenus(ItemsControl parent)
    {
        foreach (var item in parent.Items)
        {
            if (item is not MenuItem menuItem)
            {
                continue;
            }

            // The themed menu template hosts submenus in separate Popup windows.
            // Reset their bound state when the parent context menu closes so none are left behind.
            if (menuItem.IsSubmenuOpen)
            {
                menuItem.IsSubmenuOpen = false;
            }

            CloseOpenSubmenus(menuItem);
        }
    }

    private MenuItem BuildCampusNetworkMenuItem(CampusNetworkData? net, double todayUsedMB, double monthUsedMB)
    {
        string monthStr = monthUsedMB > 0 ? FormatTrafficMB(monthUsedMB) : (net?.UsedFlow ?? "--");
        string balStr = !string.IsNullOrWhiteSpace(net?.Balance) && net!.Balance != "--" ? $"¥{net.Balance}" : "--";
        string headerText = $"🌐 校园网：{monthStr}  |  余额 {balStr}";

        var rootItem = CreateStyledMenuItem(headerText, null);

        // Detailed items inside submenu
        string statusDesc = net?.Status switch
        {
            NetworkStatus.Success => "在线 · 数据正常",
            NetworkStatus.Loading => "正在同步...",
            NetworkStatus.NeedLogin => "会话已过期 (需认证)",
            NetworkStatus.Failed => $"异常 ({net.ErrorMessage ?? "连接失败"})",
            _ => "待机中"
        };
        rootItem.Items.Add(CreateInfoMenuItem($"状态：{statusDesc}"));
        rootItem.Items.Add(CreateInfoMenuItem($"今日已用：{todayUsedMB / 1024.0:F2} GB / 30.00 GB (免费额度)"));
        rootItem.Items.Add(CreateInfoMenuItem($"本月累计：{monthStr}"));
        rootItem.Items.Add(CreateInfoMenuItem($"账户余额：{balStr}"));

        if (net?.LastUpdated != null)
        {
            rootItem.Items.Add(CreateInfoMenuItem($"更新时间：{net.LastUpdated.Value:HH:mm:ss}"));
        }

        rootItem.Items.Add(CreateSeparator());

        // Portal quick actions
        var portalLoginItem = CreateStyledMenuItem("⚡ 一键认证校园网 (Portal 登录)", null);
        portalLoginItem.Click += (_, _) =>
        {
            var accountGeneration = AccountSessionManager.Generation;
            CampusNetworkClient.Shared.ClearManualLogout();
            PortalAuthService.Shared.Login(null, null, (ok, msg) =>
            {
                ShowNotification(ok ? "校园网认证成功" : "校园网认证提示", msg,
                    ok ? WinForms.ToolTipIcon.Info : WinForms.ToolTipIcon.Warning);
                CampusNetworkClient.Shared.FetchData();
            }, expectedAccountGeneration: accountGeneration);
        };
        rootItem.Items.Add(portalLoginItem);

        var portalLogoutItem = CreateStyledMenuItem("🔌 断开当前设备校园网 (Portal 注销)", null);
        portalLogoutItem.Click += (_, _) =>
        {
            CampusNetworkClient.Shared.MarkManualLogout();
            PortalAuthService.Shared.Logout((ok, msg) =>
            {
                ShowNotification(ok ? "校园网已注销" : "注销提示", msg,
                    ok ? WinForms.ToolTipIcon.Info : WinForms.ToolTipIcon.Warning);
                CampusNetworkClient.Shared.FetchData();
            });
        };
        rootItem.Items.Add(portalLogoutItem);

        var webSelfServiceItem = CreateStyledMenuItem("🌐 自助服务网页登录...", null);
        webSelfServiceItem.Click += (_, _) => LoginWebWindow.Shared.ShowWindow();
        rootItem.Items.Add(webSelfServiceItem);

        rootItem.Items.Add(CreateSeparator());

        // Online Devices list & kick
        var devices = net?.OnlineDevices ?? new List<OnlineDevice>();
        var devicesHeader = CreateInfoMenuItem($"在线终端设备 ({devices.Count} 台)");
        rootItem.Items.Add(devicesHeader);

        if (devices.Count == 0)
        {
            var refreshDevicesItem = CreateStyledMenuItem("🔍 刷新在线终端列表", null);
            refreshDevicesItem.Click += (_, _) => CampusNetworkClient.Shared.FetchOnlineDevices();
            rootItem.Items.Add(refreshDevicesItem);
        }
        else
        {
            foreach (var dev in devices)
            {
                string devTitle = $"💻 {dev.DisplayType} · {dev.Ip}" +
                                  (string.IsNullOrWhiteSpace(dev.UsedFlow) ? "" : $" ({dev.UsedFlow})") +
                                  "  [点击强制下线]";
                var devItem = CreateStyledMenuItem(devTitle, null);
                string sessionId = dev.SessionId;
                string ip = dev.Ip;
                devItem.Click += (_, _) =>
                {
                    if (string.IsNullOrWhiteSpace(sessionId)) return;
                    CampusNetworkClient.Shared.KickOnlineDevice(sessionId, (ok, msg) =>
                    {
                        ShowNotification(ok ? "终端已强制下线" : "下线操作失败", $"{ip}: {msg}",
                            ok ? WinForms.ToolTipIcon.Info : WinForms.ToolTipIcon.Warning);
                    });
                };
                rootItem.Items.Add(devItem);
            }

            var refreshDevicesItem = CreateStyledMenuItem("🔄 刷新在线设备列表", null);
            refreshDevicesItem.Click += (_, _) => CampusNetworkClient.Shared.FetchOnlineDevices();
            rootItem.Items.Add(refreshDevicesItem);
        }

        rootItem.Items.Add(CreateSeparator());
        var openNetStatsItem = CreateStyledMenuItem("📈 打开校园网流量统计面板...", null);
        openNetStatsItem.Click += (_, _) => HistoryStatsWindow.Shared.ShowWindow(0);
        rootItem.Items.Add(openNetStatsItem);

        return rootItem;
    }

    private MenuItem BuildElectricityMenuItem()
    {
        var elec = ElectricityService.Shared.LatestData;
        string header;
        if (!SettingsManager.Shared.IsDormConfigured)
        {
            header = "⚡ 宿舍电费：未配置寝室 (点击前往设置)";
        }
        else if (elec != null && elec.IsSuccess && elec.RemainingKWh.HasValue)
        {
            string roomName = !string.IsNullOrWhiteSpace(elec.RoomName)
                ? elec.RoomName
                : SettingsManager.Shared.DormRoomName;
            header = $"⚡ 宿舍电费：{elec.RemainingKWh.Value:F1} 度" +
                     (string.IsNullOrWhiteSpace(roomName) ? "" : $" ({roomName})");
        }
        else
        {
            header = $"⚡ 宿舍电费：{elec?.ErrorMessage ?? "点击查看详情"}";
        }

        var item = CreateStyledMenuItem(header, null);
        item.Click += (_, _) =>
        {
            if (!SettingsManager.Shared.IsDormConfigured)
            {
                SettingsWindow.Shared.ShowWindow();
            }
            else
            {
                HistoryStatsWindow.Shared.ShowWindow(1);
            }
        };
        return item;
    }

    private MenuItem BuildCampusCardMenuItem()
    {
        var card = CampusCardService.Shared.LatestData;
        string header = card != null && card.IsSuccess
            ? $"💳 校园一卡通：¥{card.BalanceYuan:F2}  (今日 ¥{card.TodaySpentYuan:F2})"
            : "💳 校园一卡通：点击查看消费统计";

        var rootItem = CreateStyledMenuItem(header, null);

        if (card != null && card.IsSuccess)
        {
            double budget = SettingsManager.Shared.CampusCardDailyBudget;
            rootItem.Items.Add(CreateInfoMenuItem($"卡内余额：¥{card.BalanceYuan:F2}   ({card.CardStatus})"));
            rootItem.Items.Add(CreateInfoMenuItem($"今日消费：¥{card.TodaySpentYuan:F2}   (日预算 ¥{budget:F0})"));
            rootItem.Items.Add(CreateInfoMenuItem($"近 7 天消费：¥{card.WeekSpentYuan:F2}   |   本月消费：¥{card.MonthSpentYuan:F2}"));
            rootItem.Items.Add(CreateSeparator());

            rootItem.Items.Add(CreateInfoMenuItem("最近 6 笔流水记录："));
            var recent = card.Transactions.Take(6).ToList();
            if (recent.Count == 0)
            {
                rootItem.Items.Add(CreateInfoMenuItem("  暂无近期消费流水"));
            }
            else
            {
                foreach (var tx in recent)
                {
                    string sign = tx.IsExpense ? "-" : "+";
                    string timePart = tx.Time.Length >= 16 ? tx.Time.Substring(5, 11) : tx.Time;
                    string line = $"  {timePart}  {tx.Merchant}  {sign}¥{Math.Abs(tx.AmountYuan):F2}";
                    var txItem = CreateStyledMenuItem(line, null);
                    txItem.Click += (_, _) => HistoryStatsWindow.Shared.ShowWindow(2);
                    rootItem.Items.Add(txItem);
                }
            }
        }
        else
        {
            rootItem.Items.Add(CreateInfoMenuItem(card?.ErrorMessage ?? "尚未同步一卡通数据，请先完成统一认证"));
        }

        rootItem.Items.Add(CreateSeparator());
        var openCardStats = CreateStyledMenuItem("📊 查看完整一卡通消费分析...", null);
        openCardStats.Click += (_, _) => HistoryStatsWindow.Shared.ShowWindow(2);
        rootItem.Items.Add(openCardStats);

        var refreshCard = CreateStyledMenuItem("🔄 立即刷新一卡通数据", null);
        refreshCard.Click += (_, _) => CampusCardService.Shared.FetchData();
        rootItem.Items.Add(refreshCard);

        return rootItem;
    }

    private MenuItem BuildCourseMenuItem()
    {
        var schedule = CourseScheduleService.Shared.CurrentSchedule;
        DateTime now = DateTime.Now;
        var milestone = schedule?.NextCourseMilestone(now);

        string header;
        if (schedule == null)
        {
            header = "📅 今日课程：未同步课表";
        }
        else if (milestone != null)
        {
            string stateTag = milestone.IsOngoing ? "进行中" : "下一节";
            header = $"📅 今日课程：{stateTag}《{milestone.Course.Name}》 {milestone.Course.Room}";
        }
        else
        {
            header = "📅 今日课程：今日课程已全部结束";
        }

        var rootItem = CreateStyledMenuItem(header, null);

        if (schedule != null)
        {
            int? cw = schedule.CurrentWeek(now);
            string weekText = cw.HasValue ? $"第 {cw.Value} 教学周" : "非教学周/假期";
            rootItem.Items.Add(CreateInfoMenuItem($"{schedule.SemesterName} · {weekText}"));
            rootItem.Items.Add(CreateSeparator());

            if (cw.HasValue)
            {
                int weekday = ((int)now.DayOfWeek == 0) ? 7 : (int)now.DayOfWeek;
                var todayCourses = schedule.CoursesOn(cw.Value, weekday);
                if (todayCourses.Count == 0)
                {
                    rootItem.Items.Add(CreateInfoMenuItem("🎉 今日全天无课"));
                }
                else
                {
                    foreach (var c in todayCourses)
                    {
                        string timeRange = $"{c.StartTimeText ?? "--"}-{c.EndTimeText ?? "--"}";
                        string itemText = $"  第{c.StartUnit}-{c.EndUnit}节 ({timeRange})  {c.Name}  @{c.Room}";
                        var cItem = CreateStyledMenuItem(itemText, null);
                        cItem.Click += (_, _) => CourseScheduleWindow.Shared.ShowWindow();
                        rootItem.Items.Add(cItem);
                    }
                }
            }
        }
        else
        {
            rootItem.Items.Add(CreateInfoMenuItem("尚未同步教务系统课表"));
        }

        rootItem.Items.Add(CreateSeparator());
        var openTableItem = CreateStyledMenuItem("🗓️ 打开完整周课表窗口...", null);
        openTableItem.Click += (_, _) => CourseScheduleWindow.Shared.ShowWindow();
        rootItem.Items.Add(openTableItem);

        var syncCourseItem = CreateStyledMenuItem("🔄 立即同步教务课表", null);
        syncCourseItem.Click += (_, _) =>
        {
            CourseScheduleService.Shared.TryBackgroundLogin(ok =>
            {
                if (!ok)
                {
                    AppEvents.InvokeOnUI(() => CourseLoginWebWindow.Shared.ShowWindow());
                }
            });
        };
        rootItem.Items.Add(syncCourseItem);

        return rootItem;
    }

    private MenuItem BuildAcademicMenuItem()
    {
        var acad = AcademicService.Shared.LatestData;
        int unread = AcademicService.Shared.UnreadGradeCount;
        var nextExam = acad?.NextUpcomingExam();

        string header;
        if (unread > 0)
        {
            header = $"🎓 考试与成绩：🔴 {unread} 门新出分成绩！";
        }
        else if (nextExam != null)
        {
            int days = Math.Max(0, nextExam.DaysRemaining());
            string dayStr = days == 0 ? "今天考试" : $"{days}天后";
            header = $"🎓 考试与成绩：近期《{nextExam.CourseName}》({dayStr})";
        }
        else if (acad?.GpaSummary != null && !string.IsNullOrWhiteSpace(acad.GpaSummary.Gpa))
        {
            header = $"🎓 考试与成绩：GPA {acad.GpaSummary.Gpa}  |  排名 {acad.GpaSummary.MajorRank}";
        }
        else
        {
            header = "🎓 考试与成绩：点击查看考表与成绩单";
        }

        var rootItem = CreateStyledMenuItem(header, null);

        if (acad != null)
        {
            if (acad.GpaSummary != null)
            {
                rootItem.Items.Add(CreateInfoMenuItem(
                    $"平均绩点：{acad.GpaSummary.Gpa}   |   算术均分：{acad.GpaSummary.WeightedAvg}   |   专业排名：{acad.GpaSummary.MajorRank}"));
                rootItem.Items.Add(CreateSeparator());
            }

            // Upcoming exams
            var upcoming = acad.Exams.Where(e => !e.IsFinished()).OrderBy(e => e.ExamStartDate ?? DateTime.MaxValue).Take(4).ToList();
            rootItem.Items.Add(CreateInfoMenuItem($"近期考试安排 ({upcoming.Count} 场)："));
            if (upcoming.Count == 0)
            {
                rootItem.Items.Add(CreateInfoMenuItem("  暂无待考科目"));
            }
            else
            {
                foreach (var ex in upcoming)
                {
                    int d = Math.Max(0, ex.DaysRemaining());
                    string tag = d == 0 ? "今天" : $"{d}天后";
                    var exItem = CreateStyledMenuItem($"  [{tag}] {ex.CourseName} · {ex.DateTimeText} @{ex.Room}", null);
                    exItem.Click += (_, _) => AcademicWindow.Shared.ShowWindow(0);
                    rootItem.Items.Add(exItem);
                }
            }

            rootItem.Items.Add(CreateSeparator());

            // Latest grades
            var recentGrades = acad.Grades.Take(5).ToList();
            rootItem.Items.Add(CreateInfoMenuItem("最新出分课程："));
            if (recentGrades.Count == 0)
            {
                rootItem.Items.Add(CreateInfoMenuItem("  暂无成绩数据"));
            }
            else
            {
                bool hideScore = SettingsManager.Shared.HideScoreInNotification;
                foreach (var g in recentGrades)
                {
                    string scoreText = hideScore ? "***" : $"{g.Score} (GPA {g.Gp})";
                    var gItem = CreateStyledMenuItem($"  {g.CourseName}：{scoreText}", null);
                    gItem.Click += (_, _) => AcademicWindow.Shared.ShowWindow(1);
                    rootItem.Items.Add(gItem);
                }
            }
        }
        else
        {
            rootItem.Items.Add(CreateInfoMenuItem("尚未同步考表与成绩数据"));
        }

        rootItem.Items.Add(CreateSeparator());
        var openExamItem = CreateStyledMenuItem("📝 打开考试安排面板...", null);
        openExamItem.Click += (_, _) => AcademicWindow.Shared.ShowWindow(0);
        rootItem.Items.Add(openExamItem);

        var openGradeItem = CreateStyledMenuItem("🏆 打开成绩与绩点面板...", null);
        openGradeItem.Click += (_, _) => AcademicWindow.Shared.ShowWindow(1);
        rootItem.Items.Add(openGradeItem);

        var syncAcadItem = CreateStyledMenuItem("🔄 立即同步考表与成绩", null);
        syncAcadItem.Click += (_, _) => AcademicService.Shared.SyncAll(silent: false);
        rootItem.Items.Add(syncAcadItem);

        return rootItem;
    }

    private MenuItem BuildEmptyClassroomMenuItem()
    {
        var currentSelection = SettingsManager.Shared.CurrentStudyRoom;
        var currentRoomItem = EmptyClassroomService.Shared.CurrentStudyRoomItem();
        int nowMin = EmptyClassroomService.CurrentMinutesOfDay();

        string header;
        if (currentSelection != null && currentRoomItem != null)
        {
            var status = currentRoomItem.StudyStatus(nowMin);
            header = $"🏫 自习教室：{currentSelection.RoomName} ({status.SubLabel})";
        }
        else if (currentSelection != null)
        {
            header = $"🏫 自习教室：{currentSelection.RoomName}";
        }
        else
        {
            header = "🏫 自习教室：点击查询空教室与推荐";
        }

        var rootItem = CreateStyledMenuItem(header, null);

        // Current study room status & switch recommendations
        if (currentSelection != null)
        {
            if (currentRoomItem != null)
            {
                var st = currentRoomItem.StudyStatus(nowMin);
                rootItem.Items.Add(CreateInfoMenuItem($"当前登记：{currentSelection.BuildingName} · {currentSelection.RoomName} ({st.SubLabel})"));

                if (st.ShouldRecommendSwitch && st.OccupiedPeriod != null)
                {
                    var switches = EmptyClassroomService.Shared.NearbySwitchRecommendations(
                        currentRoomItem, st.OccupiedPeriod.StartUnit, nowMin, limit: 4);
                    if (switches.Count > 0)
                    {
                        rootItem.Items.Add(CreateInfoMenuItem("⚠️ 即将有课，同楼层/同楼换教室推荐："));
                        foreach (var rec in switches)
                        {
                            var recStatus = rec.StudyStatus(nowMin);
                            var switchItem = CreateStyledMenuItem($"  👉 切换至 {rec.NameZh} ({recStatus.SubLabel})", null);
                            switchItem.Click += (_, _) =>
                            {
                                EmptyClassroomService.Shared.SetCurrentStudyRoom(
                                    rec,
                                    EmptyClassroomService.Shared.InferCampus(rec),
                                    currentSelection.BuildingCode,
                                    currentSelection.BuildingName);
                            };
                            rootItem.Items.Add(switchItem);
                        }
                    }
                }
            }
            else
            {
                rootItem.Items.Add(CreateInfoMenuItem($"当前登记：{currentSelection.RoomName}"));
            }

            var clearCurrentItem = CreateStyledMenuItem("✖ 取消当前登记自习室", null);
            clearCurrentItem.Click += (_, _) => EmptyClassroomService.Shared.ClearCurrentStudyRoom();
            rootItem.Items.Add(clearCurrentItem);
            rootItem.Items.Add(CreateSeparator());
        }

        // Today all-day free rooms
        var allDayRooms = EmptyClassroomService.Shared.RecommendedTodayAllDayFreeRooms(limit: 4);
        if (allDayRooms.Count > 0)
        {
            rootItem.Items.Add(CreateInfoMenuItem("🌟 今日余下时段全空教室推荐："));
            foreach (var r in allDayRooms)
            {
                string bName = !string.IsNullOrEmpty(r.BuildingName) ? r.BuildingName : "教学楼";
                var rItem = CreateStyledMenuItem($"  {bName} · {r.NameZh} ({r.SeatsForSection ?? 0}座)", null);
                rItem.Click += (_, _) =>
                {
                    EmptyClassroomService.Shared.SetCurrentStudyRoom(
                        r,
                        EmptyClassroomService.Shared.InferCampus(r),
                        r.BuildingCode,
                        bName);
                };
                rootItem.Items.Add(rItem);
            }
            rootItem.Items.Add(CreateSeparator());
        }

        // Tomorrow recommendation
        var tomorrowPlan = EmptyClassroomService.Shared.BuildTomorrowRecommendation(limit: 3);
        if (tomorrowPlan != null && tomorrowPlan.RecommendedRooms.Count > 0)
        {
            rootItem.Items.Add(CreateInfoMenuItem($"🌅 明日自习推荐 ({tomorrowPlan.Reason})："));
            foreach (var r in tomorrowPlan.RecommendedRooms)
            {
                var rItem = CreateStyledMenuItem($"  [设为明日自习室] {r.NameZh} ({r.SeatsForSection ?? 0}座)", null);
                rItem.Click += (_, _) =>
                {
                    EmptyClassroomService.Shared.SetNextDayStudyRoom(
                        r,
                        EmptyClassroomService.Shared.InferCampus(r),
                        tomorrowPlan.TargetBuildingCode,
                        tomorrowPlan.TargetBuildingName,
                        tomorrowPlan.DateString);
                };
                rootItem.Items.Add(rItem);
            }
            rootItem.Items.Add(CreateSeparator());
        }

        var openRoomWindowItem = CreateStyledMenuItem("🔍 打开空教室查询与自习规划窗口...", null);
        openRoomWindowItem.Click += (_, _) => EmptyClassroomWindow.Shared.ShowWindowAndSync(selectTomorrow: false);
        rootItem.Items.Add(openRoomWindowItem);

        var openTomorrowWindowItem = CreateStyledMenuItem("📅 规划明日自习教室...", null);
        openTomorrowWindowItem.Click += (_, _) => EmptyClassroomWindow.Shared.ShowWindowAndSync(selectTomorrow: true);
        rootItem.Items.Add(openTomorrowWindowItem);

        return rootItem;
    }

    private MenuItem BuildDisplayAndRefreshSubmenu()
    {
        var rootItem = CreateStyledMenuItem("🖥️ 显示与刷新选项", null);

        // Toggle Desktop Widget visibility
        var showWidgetItem = CreateStyledMenuItem("显示桌面小组件", null);
        showWidgetItem.IsCheckable = true;
        showWidgetItem.IsChecked = SettingsManager.Shared.ShowDesktopWidget;
        showWidgetItem.Click += (_, _) =>
        {
            bool next = !SettingsManager.Shared.ShowDesktopWidget;
            DesktopWidgetWindow.Shared.SetWidgetVisible(next);
        };
        rootItem.Items.Add(showWidgetItem);

        // Toggle Pin to Desktop (Win+D resident)
        var pinWidgetItem = CreateStyledMenuItem("小组件嵌入桌面层 (不遮挡窗口，Win+D驻留)", null);
        pinWidgetItem.IsCheckable = true;
        pinWidgetItem.IsChecked = SettingsManager.Shared.WidgetPinToDesktop;
        pinWidgetItem.Click += (_, _) =>
        {
            bool next = !SettingsManager.Shared.WidgetPinToDesktop;
            DesktopWidgetWindow.Shared.UpdatePinLevel(next);
        };
        rootItem.Items.Add(pinWidgetItem);

        rootItem.Items.Add(CreateSeparator());

        // Refresh interval choices
        rootItem.Items.Add(CreateInfoMenuItem("数据自动刷新间隔："));
        double currentRefresh = SettingsManager.Shared.RefreshInterval;
        (string label, double sec)[] intervals =
        {
            ("每 30 秒", 30),
            ("每 1 分钟 (推荐)", 60),
            ("每 3 分钟", 180),
            ("每 5 分钟", 300),
            ("每 10 分钟", 600)
        };

        foreach (var (label, sec) in intervals)
        {
            var intervalItem = CreateStyledMenuItem(label, null);
            intervalItem.IsCheckable = true;
            intervalItem.IsChecked = Math.Abs(currentRefresh - sec) < 1.0;
            intervalItem.Click += (_, _) =>
            {
                SettingsManager.Shared.RefreshInterval = sec;
                SettingsManager.Shared.Save();
                CampusNetworkClient.Shared.UpdateInterval(sec);
            };
            rootItem.Items.Add(intervalItem);
        }

        return rootItem;
    }

    public void RefreshAllDataNow()
    {
        CampusNetworkClient.Shared.FetchData();
        CampusNetworkClient.Shared.FetchOnlineDevices();
        ElectricityService.Shared.FetchData();
        CampusCardService.Shared.FetchData();
        if (SettingsManager.Shared.CourseTableEnabled)
        {
            CourseScheduleService.Shared.TryBackgroundLogin();
        }
        AcademicService.Shared.SyncAll(silent: true);
        EmptyClassroomService.Shared.SyncTodayAndTomorrowStudyRooms(forceRefresh: true);
    }

    private void CheckSoftwareUpdateManually()
    {
        UpdateChecker.Shared.CheckForUpdates(manual: true, (release, err) =>
        {
            AppEvents.InvokeOnUI(() =>
            {
                if (release != null)
                {
                    var res = MessageBox.Show(
                        $"发现新版本 {release.Version} (当前版本 v{UpdateChecker.Shared.CurrentVersion})\n\n更新内容：\n{release.Body}\n\n是否立即前往下载页面？",
                        "发现新版本",
                        MessageBoxButton.YesNo,
                        MessageBoxImage.Information);
                    if (res == MessageBoxResult.Yes && !string.IsNullOrWhiteSpace(release.HtmlUrl))
                    {
                        try
                        {
                            Process.Start(new ProcessStartInfo(release.HtmlUrl) { UseShellExecute = true });
                        }
                        catch { }
                    }
                }
                else if (!string.IsNullOrWhiteSpace(err))
                {
                    MessageBox.Show($"检查更新失败：{err}", "检查更新", MessageBoxButton.OK, MessageBoxImage.Warning);
                }
                else
                {
                    MessageBox.Show($"当前已是最新版本 (v{UpdateChecker.Shared.CurrentVersion})！", "检查更新", MessageBoxButton.OK, MessageBoxImage.Information);
                }
            });
        });
    }

    private static MenuItem CreateStyledMenuItem(string header, string? gestureText)
    {
        var item = new MenuItem
        {
            Header = header,
            Foreground = ThemeManager.Shared.TextPrimary,
            Background = MediaBrushes.Transparent,
            FontSize = 12.5,
            Padding = new Thickness(8, 5, 10, 5)
        };
        if (!string.IsNullOrWhiteSpace(gestureText))
        {
            item.InputGestureText = gestureText;
        }
        return item;
    }

    private static MenuItem CreateInfoMenuItem(string text)
    {
        return new MenuItem
        {
            Header = text,
            IsEnabled = false,
            Foreground = ThemeManager.Shared.TextSecondary,
            FontSize = 11.5,
            Padding = new Thickness(8, 3, 10, 3)
        };
    }

    private static Separator CreateSeparator()
    {
        return new Separator
        {
            Background = ThemeManager.Shared.IsDarkTheme
                ? new SolidColorBrush(MediaColor.FromArgb(35, 255, 255, 255))
                : new SolidColorBrush(MediaColor.FromArgb(25, 0, 0, 0)),
            Margin = new Thickness(6, 4, 6, 4)
        };
    }

    private static void ApplyThemeToContextMenu(ContextMenu menu)
    {
        const string Xaml = @"
<ResourceDictionary xmlns=""http://schemas.microsoft.com/winfx/2006/xaml/presentation""
                    xmlns:x=""http://schemas.microsoft.com/winfx/2006/xaml"">

    <!-- 极简现代深色 ScrollBar 样式（消除系统浅色/反色大白条） -->
    <Style TargetType=""ScrollBar"">
        <Setter Property=""SnapsToDevicePixels"" Value=""True""/>
        <Setter Property=""OverridesDefaultStyle"" Value=""True""/>
        <Style.Triggers>
            <Trigger Property=""Orientation"" Value=""Vertical"">
                <Setter Property=""Width"" Value=""6""/>
                <Setter Property=""Template"">
                    <Setter.Value>
                        <ControlTemplate TargetType=""ScrollBar"">
                            <Grid Background=""Transparent"" SnapsToDevicePixels=""True"">
                                <Track x:Name=""PART_Track"" IsDirectionReversed=""True"">
                                    <Track.Thumb>
                                        <Thumb>
                                            <Thumb.Template>
                                                <ControlTemplate TargetType=""Thumb"">
                                                    <Border x:Name=""ThumbBorder"" Background=""#586074"" CornerRadius=""3""/>
                                                    <ControlTemplate.Triggers>
                                                        <Trigger Property=""IsMouseOver"" Value=""True"">
                                                            <Setter TargetName=""ThumbBorder"" Property=""Background"" Value=""#828EA8""/>
                                                        </Trigger>
                                                        <Trigger Property=""IsDragging"" Value=""True"">
                                                            <Setter TargetName=""ThumbBorder"" Property=""Background"" Value=""#A6B4D4""/>
                                                        </Trigger>
                                                    </ControlTemplate.Triggers>
                                                </ControlTemplate>
                                            </Thumb.Template>
                                        </Thumb>
                                    </Track.Thumb>
                                </Track>
                            </Grid>
                        </ControlTemplate>
                    </Setter.Value>
                </Setter>
            </Trigger>
            <Trigger Property=""Orientation"" Value=""Horizontal"">
                <Setter Property=""Height"" Value=""0""/>
                <Setter Property=""Visibility"" Value=""Collapsed""/>
            </Trigger>
        </Style.Triggers>
    </Style>

    <!-- 深色 ScrollViewer 样式 -->
    <Style TargetType=""ScrollViewer"">
        <Setter Property=""OverridesDefaultStyle"" Value=""True""/>
        <Setter Property=""HorizontalScrollBarVisibility"" Value=""Disabled""/>
        <Setter Property=""VerticalScrollBarVisibility"" Value=""Auto""/>
        <Setter Property=""Template"">
            <Setter.Value>
                <ControlTemplate TargetType=""ScrollViewer"">
                    <Grid Background=""Transparent"">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width=""*""/>
                            <ColumnDefinition Width=""Auto""/>
                        </Grid.ColumnDefinitions>
                        <ScrollContentPresenter Grid.Column=""0"" CanContentScroll=""{TemplateBinding CanContentScroll}""/>
                        <ScrollBar x:Name=""PART_VerticalScrollBar""
                                   Grid.Column=""1""
                                   Orientation=""Vertical""
                                   Margin=""1,2,1,2""
                                   Value=""{TemplateBinding VerticalOffset}""
                                   Maximum=""{TemplateBinding ScrollableHeight}""
                                   ViewportSize=""{TemplateBinding ViewportHeight}""
                                   Visibility=""{TemplateBinding ComputedVerticalScrollBarVisibility}""/>
                    </Grid>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType=""ContextMenu"">
        <Setter Property=""SnapsToDevicePixels"" Value=""True""/>
        <Setter Property=""OverridesDefaultStyle"" Value=""True""/>
        <Setter Property=""Grid.IsSharedSizeScope"" Value=""True""/>
        <Setter Property=""HasDropShadow"" Value=""True""/>
        <Setter Property=""Template"">
            <Setter.Value>
                <ControlTemplate TargetType=""ContextMenu"">
                    <Border Background=""#F61C1E26""
                            BorderBrush=""#38FFFFFF""
                            BorderThickness=""1""
                            CornerRadius=""10""
                            Padding=""4,6,4,6"">
                        <Border.Effect>
                            <DropShadowEffect BlurRadius=""16"" ShadowDepth=""4"" Direction=""270"" Opacity=""0.45"" Color=""Black""/>
                        </Border.Effect>
                        <ScrollViewer CanContentScroll=""True""
                                      VerticalScrollBarVisibility=""Auto""
                                      HorizontalScrollBarVisibility=""Disabled""
                                      MaxHeight=""640"">
                            <StackPanel IsItemsHost=""True"" KeyboardNavigation.DirectionalNavigation=""Cycle""/>
                        </ScrollViewer>
                    </Border>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType=""MenuItem"">
        <Setter Property=""FontSize"" Value=""12.5""/>
        <Setter Property=""Foreground"" Value=""#EBEEF5""/>
        <Setter Property=""Background"" Value=""Transparent""/>
        <Setter Property=""Padding"" Value=""8,5,10,5""/>
        <Setter Property=""Template"">
            <Setter.Value>
                <ControlTemplate TargetType=""MenuItem"">
                    <Grid SnapsToDevicePixels=""True"">
                        <Border x:Name=""BgBorder""
                                Background=""{TemplateBinding Background}""
                                CornerRadius=""6""
                                Padding=""{TemplateBinding Padding}""
                                Margin=""1,1,1,1"">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width=""Auto"" SharedSizeGroup=""Icon""/>
                                    <ColumnDefinition Width=""*""/>
                                    <ColumnDefinition Width=""Auto"" SharedSizeGroup=""Shortcut""/>
                                    <ColumnDefinition Width=""Auto""/>
                                </Grid.ColumnDefinitions>

                                <ContentPresenter x:Name=""IconPresenter""
                                                  Grid.Column=""0""
                                                  Content=""{TemplateBinding Icon}""
                                                  Margin=""0,0,8,0""
                                                  VerticalAlignment=""Center""/>

                                <ContentPresenter x:Name=""HeaderPresenter""
                                                  Grid.Column=""1""
                                                  Content=""{TemplateBinding Header}""
                                                  ContentTemplate=""{TemplateBinding HeaderTemplate}""
                                                  RecognizesAccessKey=""True""
                                                  VerticalAlignment=""Center""/>

                                <TextBlock x:Name=""GestureText""
                                           Grid.Column=""2""
                                           Text=""{TemplateBinding InputGestureText}""
                                           Margin=""16,0,0,0""
                                           Foreground=""#8E98B0""
                                           FontSize=""11""
                                           VerticalAlignment=""Center""/>

                                <TextBlock x:Name=""SubmenuArrow""
                                           Grid.Column=""3""
                                           Text=""›""
                                           FontWeight=""Bold""
                                           FontSize=""13""
                                           Margin=""10,0,2,0""
                                           Foreground=""#7E88A6""
                                           VerticalAlignment=""Center""
                                           Visibility=""Collapsed""/>
                            </Grid>
                        </Border>

                        <Popup x:Name=""PART_Popup""
                               AllowsTransparency=""True""
                               Placement=""Right""
                               VerticalOffset=""-5""
                               HorizontalOffset=""2""
                               IsOpen=""{Binding IsSubmenuOpen, RelativeSource={RelativeSource TemplatedParent}}""
                               Focusable=""False""
                               PopupAnimation=""Fade"">
                            <Border Background=""#F61C1E26""
                                    BorderBrush=""#38FFFFFF""
                                    BorderThickness=""1""
                                    CornerRadius=""10""
                                    Padding=""4,6,4,6""
                                    SnapsToDevicePixels=""True"">
                                <Border.Effect>
                                    <DropShadowEffect BlurRadius=""16"" ShadowDepth=""4"" Direction=""270"" Opacity=""0.45"" Color=""Black""/>
                                </Border.Effect>
                                <ScrollViewer CanContentScroll=""True""
                                              VerticalScrollBarVisibility=""Auto""
                                              HorizontalScrollBarVisibility=""Disabled""
                                              MaxHeight=""600"">
                                    <StackPanel IsItemsHost=""True"" KeyboardNavigation.DirectionalNavigation=""Cycle""/>
                                </ScrollViewer>
                            </Border>
                        </Popup>
                    </Grid>

                    <ControlTemplate.Triggers>
                        <!-- 有子菜单时显示展开箭头 -->
                        <Trigger Property=""HasItems"" Value=""True"">
                            <Setter TargetName=""SubmenuArrow"" Property=""Visibility"" Value=""Visible""/>
                        </Trigger>
                        <!-- 鼠标悬停高亮状态 -->
                        <Trigger Property=""IsHighlighted"" Value=""True"">
                            <Setter TargetName=""BgBorder"" Property=""Background"" Value=""#323646""/>
                            <Setter Property=""Foreground"" Value=""#FFFFFF""/>
                            <Setter TargetName=""SubmenuArrow"" Property=""Foreground"" Value=""#CAD4F0""/>
                        </Trigger>
                        <!-- 子菜单已展开状态保持深色高亮 -->
                        <Trigger Property=""IsSubmenuOpen"" Value=""True"">
                            <Setter TargetName=""BgBorder"" Property=""Background"" Value=""#282B38""/>
                        </Trigger>
                        <!-- 禁用态保持高对比度颜色，避免对比度过低看不清 -->
                        <Trigger Property=""IsEnabled"" Value=""False"">
                            <Setter Property=""Foreground"" Value=""#8E98B0""/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType=""Separator"">
        <Setter Property=""Background"" Value=""#22FFFFFF""/>
        <Setter Property=""Margin"" Value=""6,4,6,4""/>
        <Setter Property=""Height"" Value=""1""/>
        <Setter Property=""Template"">
            <Setter.Value>
                <ControlTemplate TargetType=""Separator"">
                    <Border Background=""{TemplateBinding Background}""
                            Height=""{TemplateBinding Height}""
                            Margin=""{TemplateBinding Margin}""/>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
</ResourceDictionary>";

        string themedXaml = Xaml;
        if (!ThemeManager.Shared.IsDarkTheme)
        {
            themedXaml = themedXaml
                .Replace("#586074", "#A6ADB8")
                .Replace("#828EA8", "#7A8492")
                .Replace("#A6B4D4", "#596270")
                .Replace("#F61C1E26", "#FAFFFFFF")
                .Replace("#38FFFFFF", "#26000000")
                .Replace("#282B38", "#E8EEF6")
                .Replace("#323646", "#E6F1FF")
                .Replace("#EBEEF5", "#1D1D1F")
                .Replace("#FFFFFF", "#1D1D1F")
                .Replace("#CAD4F0", "#3D526B")
                .Replace("#7E88A6", "#6E6E73")
                .Replace("#8E98B0", "#8E8E93")
                .Replace("#22FFFFFF", "#1F000000");
        }

        try
        {
            var dict = (ResourceDictionary)XamlReader.Parse(themedXaml);
            menu.Resources.MergedDictionaries.Add(dict);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[MenuTheme Error]: {ex.Message}");
        }
    }

    private static Icon CreateCampusTrayIcon(bool isOnline)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(System.Drawing.Color.Transparent);

            var bgColor = isOnline
                ? System.Drawing.Color.FromArgb(255, 10, 132, 255)
                : System.Drawing.Color.FromArgb(255, 255, 149, 0);

            using var brush = new SolidBrush(bgColor);
            g.FillEllipse(brush, 2, 2, 28, 28);

            using var pen = new System.Drawing.Pen(System.Drawing.Color.White, 2.4f)
            {
                StartCap = LineCap.Round,
                EndCap = LineCap.Round
            };
            // Draw stylized Wi-Fi / Campus signal arcs
            g.DrawArc(pen, 7, 9, 18, 16, 205, 130);
            g.DrawArc(pen, 10, 13, 12, 12, 210, 120);
            using var dotBrush = new SolidBrush(System.Drawing.Color.White);
            g.FillEllipse(dotBrush, 14, 20, 4, 4);
        }

        IntPtr hIcon = bmp.GetHicon();
        return Icon.FromHandle(hIcon);
    }

    private static double SafeGetTodayUsedMB()
    {
        try
        {
            return Math.Max(0, CampusHistoryManager.Shared.TodayFlowDeltaMB);
        }
        catch
        {
            return 0;
        }
    }

    private static double SafeGetMonthUsedMB()
    {
        try
        {
            return CampusNetworkClient.Shared.LatestData.UsedMB ?? 0.0;
        }
        catch
        {
            return 0;
        }
    }

    private static double ParseFlowToMB(string? flowStr)
    {
        if (string.IsNullOrWhiteSpace(flowStr) || flowStr == "--") return 0;
        string s = flowStr.Trim().ToUpperInvariant();
        double multiplier = 1.0;
        if (s.EndsWith("GB") || s.EndsWith("G"))
        {
            multiplier = 1024.0;
            s = s.Replace("GB", "").Replace("G", "").Trim();
        }
        else if (s.EndsWith("MB") || s.EndsWith("M"))
        {
            multiplier = 1.0;
            s = s.Replace("MB", "").Replace("M", "").Trim();
        }
        else if (s.EndsWith("KB") || s.EndsWith("K"))
        {
            multiplier = 1.0 / 1024.0;
            s = s.Replace("KB", "").Replace("K", "").Trim();
        }

        return double.TryParse(s, NumberStyles.Any, CultureInfo.InvariantCulture, out double val)
            ? val * multiplier
            : 0;
    }

    private static string FormatTrafficMB(double mb)
    {
        if (mb >= 1024.0)
            return $"{mb / 1024.0:F2} GB";
        return $"{mb:F0} MB";
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _carouselTimer.Stop();
        StopOutsideClickMonitor();

        if (_contextMenu?.IsOpen == true)
        {
            _contextMenu.IsOpen = false;
        }

        if (_notifyIcon != null)
        {
            _notifyIcon.Visible = false;
            var icon = _notifyIcon.Icon;
            _notifyIcon.Dispose();
            _notifyIcon = null;
            if (icon != null)
            {
                try
                {
                    DestroyIcon(icon.Handle);
                    icon.Dispose();
                }
                catch { }
            }
        }
    }
}
