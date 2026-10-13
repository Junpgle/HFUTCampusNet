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
using System.Windows.Threading;
using WinForms = System.Windows.Forms;
using MediaColor = System.Windows.Media.Color;
using MediaBrushes = System.Windows.Media.Brushes;

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
        Background = new SolidColorBrush(MediaColor.FromArgb(245, 34, 36, 44));
        BorderBrush = new SolidColorBrush(MediaColor.FromArgb(45, 255, 255, 255));
        BorderThickness = new Thickness(1);

        var root = new StackPanel { Orientation = Orientation.Vertical };

        // Daily section header
        var dailyHeader = new DockPanel { Margin = new Thickness(0, 0, 0, 5) };
        var dailyTitle = new TextBlock
        {
            Text = "今日免费额度 (30 GB)",
            FontSize = 11.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(235, 238, 245))
        };
        _dailyValueLabel = new TextBlock
        {
            Text = "-- / 30 GB",
            FontSize = 11,
            FontWeight = FontWeights.Medium,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(185, 192, 205)),
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
            Background = new SolidColorBrush(MediaColor.FromArgb(45, 255, 255, 255)),
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
            Foreground = new SolidColorBrush(MediaColor.FromRgb(235, 238, 245))
        };
        _monthlyValueLabel = new TextBlock
        {
            Text = "-- / 200 GB",
            FontSize = 11,
            FontWeight = FontWeights.Medium,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(185, 192, 205)),
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
            Background = new SolidColorBrush(MediaColor.FromArgb(45, 255, 255, 255)),
            Margin = new Thickness(0, 0, 0, 8),
            ClipToBounds = true
        };
        _monthlyBarFill = new Border
        {
            Height = 7,
            CornerRadius = new CornerRadius(3.5),
            HorizontalAlignment = HorizontalAlignment.Left,
            Width = 0,
            Background = new SolidColorBrush(MediaColor.FromRgb(10, 132, 255))
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
            Foreground = new SolidColorBrush(MediaColor.FromRgb(155, 162, 178))
        };
        _footerRightLabel = new TextBlock
        {
            Text = "点击查看详细报表 ›",
            FontSize = 10.5,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(120, 175, 255)),
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

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern bool DestroyIcon(IntPtr handle);

    private WinForms.NotifyIcon? _notifyIcon;
    private ContextMenu? _contextMenu;
    private CampusQuotaCardControl? _quotaCardControl;

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
        AppEvents.SpeedUpdated += (_, _) => AppEvents.InvokeOnUI(UpdateTrayTooltip);
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
        if (elec != null && elec.IsSuccess && double.TryParse(elec.RemainingKWh, NumberStyles.Any, CultureInfo.InvariantCulture, out double kwh))
        {
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

    private ContextMenu BuildTrayContextMenu()
    {
        var menu = new ContextMenu
        {
            Background = new SolidColorBrush(MediaColor.FromArgb(250, 26, 28, 35)),
            Foreground = new SolidColorBrush(MediaColor.FromRgb(238, 240, 246)),
            BorderBrush = new SolidColorBrush(MediaColor.FromArgb(65, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(4, 6, 4, 6),
            HasDropShadow = true
        };

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
        quitItem.Foreground = new SolidColorBrush(MediaColor.FromRgb(255, 105, 97));
        quitItem.Click += (_, _) =>
        {
            Dispose();
            Application.Current?.Shutdown();
        };
        menu.Items.Add(quitItem);

        return menu;
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
            CampusNetworkClient.Shared.ClearManualLogout();
            PortalAuthService.Shared.Login(null, null, (ok, msg) =>
            {
                ShowNotification(ok ? "校园网认证成功" : "校园网认证提示", msg,
                    ok ? WinForms.ToolTipIcon.Info : WinForms.ToolTipIcon.Warning);
                CampusNetworkClient.Shared.FetchData();
            });
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
            rootItem.Items.Add(CreateInfoMenuItem($"本周消费：¥{card.WeekSpentYuan:F2}   |   本月消费：¥{card.MonthSpentYuan:F2}"));
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
                string bName = r.Building?.NameZh ?? "教学楼";
                var rItem = CreateStyledMenuItem($"  {bName} · {r.NameZh} ({r.SeatsForSection ?? 0}座)", null);
                rItem.Click += (_, _) =>
                {
                    EmptyClassroomService.Shared.SetCurrentStudyRoom(
                        r,
                        EmptyClassroomService.Shared.InferCampus(r),
                        r.Building?.Code ?? "",
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
            Foreground = new SolidColorBrush(MediaColor.FromRgb(235, 238, 245)),
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
            Foreground = new SolidColorBrush(MediaColor.FromRgb(155, 162, 178)),
            FontSize = 11.5,
            Padding = new Thickness(8, 3, 10, 3)
        };
    }

    private static Separator CreateSeparator()
    {
        return new Separator
        {
            Background = new SolidColorBrush(MediaColor.FromArgb(35, 255, 255, 255)),
            Margin = new Thickness(6, 4, 6, 4)
        };
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
