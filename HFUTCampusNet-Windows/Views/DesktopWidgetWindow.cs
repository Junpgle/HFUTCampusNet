using System;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Microsoft.Win32;

namespace HFUTCampusNet;

/// <summary>
/// Windows 原生桌面小组件窗口（1:1 移植自 macOS DesktopWidgetController.swift）
/// 支持：
/// 1. 嵌入 Windows 桌面图标层上方（HWND_BOTTOM + 桌面宿主关联 + WM_WINDOWPOSCHANGING 钩子），不遮挡普通应用窗口，按 Win+D 显示桌面时稳固驻留；
/// 2. 置顶悬浮窗模式（Topmost）；
/// 3. 22pt 圆角亚克力/毛玻璃深浅色自适应外观，右上角按钮鼠标悬停平滑渐显；
/// 4. 四格核心指标卡片 + 跨列课程/自习/考试智能提醒卡片 + 6 槽位底部轮播状态栏。
/// </summary>
public sealed class DesktopWidgetWindow : Window
{
    private static DesktopWidgetWindow? _shared;
    public static DesktopWidgetWindow Shared => _shared ??= new DesktopWidgetWindow();

    // Win32 P/Invoke 常量与结构
    private const int GWL_EXSTYLE = -20;
    private const int GWLP_HWNDPARENT = -8;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int WS_EX_NOACTIVATE = 0x08000000;

    private const int WM_WINDOWPOSCHANGING = 0x0046;
    private const int WM_ACTIVATE = 0x0006;
    private const int WM_SYSCOMMAND = 0x0112;
    private const int SC_MINIMIZE = 0xF020;

    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOMOVE = 0x0002;
    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private const uint SWP_HIDEWINDOW = 0x0080;

    private static readonly IntPtr HWND_BOTTOM = new(1);
    private static readonly IntPtr HWND_TOPMOST = new(-1);
    private static readonly IntPtr HWND_NOTOPMOST = new(-2);

    [StructLayout(LayoutKind.Sequential)]
    private struct WINDOWPOS
    {
        public IntPtr hwnd;
        public IntPtr hwndInsertAfter;
        public int x;
        public int y;
        public int cx;
        public int cy;
        public uint flags;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [DllImport("user32.dll", EntryPoint = "SetWindowLong", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr32(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    private static IntPtr SetWindowLongPtrHelper(IntPtr hWnd, int nIndex, IntPtr dwNewLong)
    {
        return IntPtr.Size == 8
            ? SetWindowLongPtr64(hWnd, nIndex, dwNewLong)
            : SetWindowLongPtr32(hWnd, nIndex, dwNewLong);
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int X,
        int Y,
        int cx,
        int cy,
        uint uFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindow(string? lpClassName, string? lpWindowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string? lpszWindow);

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    // UI 控件引用
    private Border _rootBorder = null!;
    private TextBlock _titleLabel = null!;
    private TextBlock _speedBadgeLabel = null!;
    private Button _pinModeBtn = null!;
    private Button _refreshBtn = null!;
    private Button _closeBtn = null!;

    private Border _card1Border = null!;
    private Border _card2Border = null!;
    private Border _card3Border = null!;
    private Border _card4Border = null!;
    private Border _courseCardBorder = null!;

    private TextBlock _usedFlowNumLabel = null!;
    private TextBlock _usedFlowUnitLabel = null!;
    private TextBlock _availFlowNumLabel = null!;
    private TextBlock _availFlowUnitLabel = null!;
    private TextBlock _protNumLabel = null!;
    private TextBlock _protUnitLabel = null!;
    private TextBlock _balNumLabel = null!;
    private TextBlock _balUnitLabel = null!;

    private TextBlock _courseIconLabel = null!;
    private TextBlock _courseTitleLabel = null!;
    private TextBlock _courseDetailLabel = null!;

    private Border _progressTrack = null!;
    private Border _progressFill = null!;
    private TextBlock _updateTimeLabel = null!;

    private MenuItem _ctxPinDesktopItem = null!;
    private MenuItem _ctxFloatTopItem = null!;

    // 状态字段
    private CampusNetworkData _currentData = new();
    private string _currentSpeedString = "↓ 0B/s  ↑ 0B/s";
    private double _currentProgressPercentage;
    private DispatcherTimer? _carouselTimer;
    private int _carouselIndex;
    private bool _isDragging;
    private HwndSource? _hwndSource;
    private bool _isDarkTheme = true;

    private DesktopWidgetWindow()
    {
        ThemeManager.Shared.ApplyWindowIcon(this);
        Width = 340;
        Height = 256;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;

        RestoreWindowPosition();
        DetectSystemTheme();
        SetupUI();
        ApplyThemeColors();

        SourceInitialized += OnWindowSourceInitialized;
        Loaded += (_, _) =>
        {
            ApplyWindowLayerMode();
            UpdateCourseDisplay();
            RenderBottomLabel();
        };

        SystemEvents.UserPreferenceChanged += (_, _) =>
        {
            Dispatcher.BeginInvoke(() =>
            {
                DetectSystemTheme();
                ApplyThemeColors();
                UpdateCourseDisplay();
                RenderBottomLabel();
            });
        };

        // 订阅全局服务更新事件
        AppEvents.NetworkDataUpdated += () => Dispatcher.BeginInvoke(() =>
        {
            UpdateData(CampusNetworkClient.Shared.LatestData);
        });
        AppEvents.SpeedUpdated += (down, up, compact) => Dispatcher.BeginInvoke(() =>
        {
            SpeedMonitorDidUpdate(down, up, compact);
        });
        AppEvents.CourseScheduleUpdated += () => Dispatcher.BeginInvoke(UpdateCourseDisplay);
        AppEvents.EmptyClassroomUpdated += () => Dispatcher.BeginInvoke(() =>
        {
            UpdateCourseDisplay();
            RenderBottomLabel();
        });
        AppEvents.DormElectricityUpdated += () => Dispatcher.BeginInvoke(RenderBottomLabel);
        AppEvents.HistoryStatsUpdated += () => Dispatcher.BeginInvoke(OnHistoryStatsUpdated);
        AppEvents.CampusCardUpdated += () => Dispatcher.BeginInvoke(RenderBottomLabel);
        AppEvents.AcademicDataUpdated += () => Dispatcher.BeginInvoke(() =>
        {
            UpdateCourseDisplay();
            RenderBottomLabel();
        });

        NetworkSpeedMonitor.Shared.Start();
        StartSpeedCarousel();
    }

    private void RestoreWindowPosition()
    {
        var workArea = SystemParameters.WorkArea;
        double initialX = workArea.Right - Width - 24;
        double initialY = workArea.Top + 36;

        if (SettingsManager.Shared.WidgetX.HasValue && SettingsManager.Shared.WidgetY.HasValue)
        {
            double savedX = SettingsManager.Shared.WidgetX.Value;
            double savedY = SettingsManager.Shared.WidgetY.Value;
            initialX = Math.Clamp(savedX, workArea.Left + 8, Math.Max(workArea.Left + 8, workArea.Right - Width - 8));
            initialY = Math.Clamp(savedY, workArea.Top + 8, Math.Max(workArea.Top + 8, workArea.Bottom - Height - 8));
        }

        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = initialX;
        Top = initialY;
    }

    private void SaveWindowPosition()
    {
        SettingsManager.Shared.WidgetX = Left;
        SettingsManager.Shared.WidgetY = Top;
        SettingsManager.Shared.Save();
    }

    private void DetectSystemTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            if (key?.GetValue("AppsUseLightTheme") is int lightVal)
            {
                _isDarkTheme = (lightVal == 0);
                return;
            }
        }
        catch { }
        _isDarkTheme = true;
    }

    private Brush PrimaryTextBrush => _isDarkTheme
        ? new SolidColorBrush(Color.FromArgb(242, 248, 250, 252))
        : new SolidColorBrush(Color.FromArgb(235, 24, 24, 27));

    private Brush SecondaryTextBrush => _isDarkTheme
        ? new SolidColorBrush(Color.FromArgb(175, 226, 232, 240))
        : new SolidColorBrush(Color.FromArgb(165, 63, 63, 70));

    private Brush TertiaryTextBrush => _isDarkTheme
        ? new SolidColorBrush(Color.FromArgb(135, 203, 213, 225))
        : new SolidColorBrush(Color.FromArgb(135, 113, 113, 122));

    private void ApplyThemeColors()
    {
        double opacity = Math.Clamp(SettingsManager.Shared.WidgetOpacity, 0.55, 1.0);
        byte alpha = (byte)Math.Round(opacity * (_isDarkTheme ? 228 : 242));

        _rootBorder.Background = _isDarkTheme
            ? new SolidColorBrush(Color.FromArgb(alpha, 26, 28, 34))
            : new SolidColorBrush(Color.FromArgb(alpha, 248, 250, 252));

        _rootBorder.BorderBrush = _isDarkTheme
            ? new SolidColorBrush(Color.FromArgb(72, 255, 255, 255))
            : new SolidColorBrush(Color.FromArgb(65, 148, 163, 184));

        var cardBg = _isDarkTheme
            ? new SolidColorBrush(Color.FromArgb(22, 255, 255, 255))
            : new SolidColorBrush(Color.FromArgb(15, 15, 23, 42));
        var cardBorder = _isDarkTheme
            ? new SolidColorBrush(Color.FromArgb(36, 255, 255, 255))
            : new SolidColorBrush(Color.FromArgb(28, 15, 23, 42));

        foreach (var card in new[] { _card1Border, _card2Border, _card3Border, _card4Border, _courseCardBorder })
        {
            card.Background = cardBg;
            card.BorderBrush = cardBorder;
        }

        _titleLabel.Foreground = SecondaryTextBrush;
        _speedBadgeLabel.Foreground = new SolidColorBrush( _isDarkTheme ? Color.FromRgb(45, 212, 191) : Color.FromRgb(13, 148, 136));

        var numBrush = _isDarkTheme
            ? new SolidColorBrush(Color.FromRgb(96, 165, 250))
            : new SolidColorBrush(Color.FromRgb(51, 115, 217));

        foreach (var num in new[] { _usedFlowNumLabel, _availFlowNumLabel, _protNumLabel, _balNumLabel })
        {
            num.Foreground = numBrush;
        }

        foreach (var unit in new[] { _usedFlowUnitLabel, _availFlowUnitLabel, _protUnitLabel, _balUnitLabel })
        {
            unit.Foreground = SecondaryTextBrush;
        }

        _progressTrack.Background = _isDarkTheme
            ? new SolidColorBrush(Color.FromArgb(45, 255, 255, 255))
            : new SolidColorBrush(Color.FromArgb(40, 15, 23, 42));
        _progressFill.Background = new SolidColorBrush(Color.FromRgb(59, 130, 246));

        UpdatePinButtonAppearance();
    }

    // MARK: - Win32 桌面层嵌入与 Win+D 防最小化钩子

    private void OnWindowSourceInitialized(object? sender, EventArgs e)
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero)
            return;

        _hwndSource = HwndSource.FromHwnd(hwnd);
        _hwndSource?.AddHook(WndProc);

        int exStyle = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, exStyle | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);

        ApplyWindowLayerMode();
    }

    /// <summary>
    /// 查找 Windows 桌面宿主句柄（Progman 或包含 SHELLDLL_DefView 的 WorkerW），
    /// 将其设为小组件的 Owner 后，按 Win+D (显示桌面) 时系统不会最小化该小组件。
    /// </summary>
    private static IntPtr FindDesktopShellWindow()
    {
        IntPtr progman = FindWindow("Progman", "Program Manager");
        if (progman == IntPtr.Zero)
            progman = FindWindow("Progman", null);

        IntPtr defViewParent = IntPtr.Zero;
        if (progman != IntPtr.Zero)
        {
            IntPtr defView = FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (defView != IntPtr.Zero)
                return progman;
        }

        EnumWindows((topHwnd, _) =>
        {
            IntPtr shellView = FindWindowEx(topHwnd, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (shellView != IntPtr.Zero)
            {
                defViewParent = topHwnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);

        return defViewParent != IntPtr.Zero ? defViewParent : progman;
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        bool pinnedToDesktop = SettingsManager.Shared.WidgetPinToDesktop;

        if (msg == WM_SYSCOMMAND)
        {
            int cmd = wParam.ToInt32() & 0xFFF0;
            if (cmd == SC_MINIMIZE)
            {
                handled = true;
                return IntPtr.Zero;
            }
        }
        else if (msg == WM_WINDOWPOSCHANGING && pinnedToDesktop && lParam != IntPtr.Zero)
        {
            var pos = Marshal.PtrToStructure<WINDOWPOS>(lParam);
            // 始终锁定在桌面图标层正上方（所有普通窗口底部），并阻止 Win+D 隐藏窗口
            pos.hwndInsertAfter = HWND_BOTTOM;
            pos.flags &= ~SWP_HIDEWINDOW;
            if (IsVisible)
            {
                pos.flags |= SWP_SHOWWINDOW;
            }
            Marshal.StructureToPtr(pos, lParam, false);
        }
        else if (msg == WM_ACTIVATE && pinnedToDesktop)
        {
            int wa = wParam.ToInt32() & 0xFFFF;
            if (wa != 0)
            {
                SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
            }
        }

        return IntPtr.Zero;
    }

    /// <summary>
    /// 应用桌面小组件层级模式（嵌入桌面图标层 vs 置顶悬浮窗）
    /// </summary>
    public void ApplyWindowLayerMode()
    {
        bool pinned = SettingsManager.Shared.WidgetPinToDesktop;
        var hwnd = new WindowInteropHelper(this).Handle;

        if (pinned)
        {
            Topmost = false;
            if (hwnd != IntPtr.Zero)
            {
                int exStyle = GetWindowLong(hwnd, GWL_EXSTYLE);
                SetWindowLong(hwnd, GWL_EXSTYLE, exStyle | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);

                IntPtr desktopHost = FindDesktopShellWindow();
                if (desktopHost != IntPtr.Zero)
                {
                    SetWindowLongPtrHelper(hwnd, GWLP_HWNDPARENT, desktopHost);
                }

                SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
            }
        }
        else
        {
            if (hwnd != IntPtr.Zero)
            {
                int exStyle = GetWindowLong(hwnd, GWL_EXSTYLE);
                SetWindowLong(hwnd, GWL_EXSTYLE, exStyle | WS_EX_TOOLWINDOW);
                SetWindowLongPtrHelper(hwnd, GWLP_HWNDPARENT, IntPtr.Zero);
                SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
            }
            Topmost = true;
        }

        UpdatePinButtonAppearance();
    }

    private void UpdatePinButtonAppearance()
    {
        if (_pinModeBtn == null)
            return;

        bool pinned = SettingsManager.Shared.WidgetPinToDesktop;
        _pinModeBtn.Content = pinned ? "▣" : "📌";
        _pinModeBtn.Foreground = pinned
            ? SecondaryTextBrush
            : new SolidColorBrush(Color.FromRgb(249, 115, 22));
        _pinModeBtn.ToolTip = pinned
            ? "当前：嵌入桌面层模式 (不遮挡普通窗口，按 Win+D 驻留桌面) · 点击切换为置顶悬浮"
            : "当前：始终置顶悬浮模式 · 点击切换为嵌入桌面层 (原生小组件模式)";

        if (_ctxPinDesktopItem != null)
            _ctxPinDesktopItem.IsChecked = pinned;
        if (_ctxFloatTopItem != null)
            _ctxFloatTopItem.IsChecked = !pinned;
    }

    public void TogglePinToDesktopMode()
    {
        SettingsManager.Shared.WidgetPinToDesktop = !SettingsManager.Shared.WidgetPinToDesktop;
        SettingsManager.Shared.Save();
        ApplyWindowLayerMode();
    }

    public void ShowWidget()
    {
        SettingsManager.Shared.ShowDesktopWidget = true;
        SettingsManager.Shared.Save();
        if (!IsVisible)
        {
            Show();
        }
        ApplyWindowLayerMode();
    }

    public void HideWidget()
    {
        SettingsManager.Shared.ShowDesktopWidget = false;
        SettingsManager.Shared.Save();
        Hide();
    }

    public void ToggleWidget()
    {
        if (IsVisible)
            HideWidget();
        else
            ShowWidget();
    }

    public void SetWidgetVisible(bool visible)
    {
        if (visible)
            ShowWidget();
        else
            HideWidget();
    }

    public void UpdatePinLevel(bool pinToDesktop)
    {
        ApplyWindowLayerMode();
    }

    public void UpdateOpacity(double opacity)
    {
        Opacity = opacity;
    }

    public void UpdateCarouselInterval(double seconds)
    {
    }

    // MARK: - 界面布局构建 (340 x 256)

    private void SetupUI()
    {
        var outerGrid = new Grid
        {
            Width = 340,
            Height = 256
        };

        _rootBorder = new Border
        {
            CornerRadius = new CornerRadius(22),
            BorderThickness = new Thickness(1),
            SnapsToDevicePixels = true,
            Effect = new DropShadowEffect
            {
                BlurRadius = 16,
                ShadowDepth = 4,
                Direction = 270,
                Opacity = 0.28,
                Color = Colors.Black
            },
            ContextMenu = BuildContextMenu()
        };

        _rootBorder.MouseEnter += (_, _) => AnimateHeaderButtons(true);
        _rootBorder.MouseLeave += (_, _) => AnimateHeaderButtons(false);
        _rootBorder.MouseLeftButtonDown += OnRootMouseLeftButtonDown;

        var canvas = new Canvas
        {
            Width = 340,
            Height = 256
        };

        // 1. 顶部标题与实时网速胶囊
        _titleLabel = new TextBlock
        {
            Text = "合工大校园网",
            FontSize = 11.5,
            FontWeight = FontWeights.SemiBold
        };
        Canvas.SetLeft(_titleLabel, 16);
        Canvas.SetTop(_titleLabel, 11);
        canvas.Children.Add(_titleLabel);

        _speedBadgeLabel = new TextBlock
        {
            Text = "↓ 0K/s  ↑ 0K/s",
            FontSize = 11,
            FontWeight = FontWeights.Medium,
            FontFamily = new FontFamily("Consolas, Microsoft YaHei UI")
        };
        Canvas.SetLeft(_speedBadgeLabel, 98);
        Canvas.SetTop(_speedBadgeLabel, 11);
        canvas.Children.Add(_speedBadgeLabel);

        // 顶部右侧悬停渐显控制按钮 (PinMode / Refresh / Close)
        _pinModeBtn = CreateHeaderButton("▣", TogglePinToDesktopMode);
        Canvas.SetLeft(_pinModeBtn, 340 - 76);
        Canvas.SetTop(_pinModeBtn, 9);
        canvas.Children.Add(_pinModeBtn);

        _refreshBtn = CreateHeaderButton("↻", RefreshClicked, "立即刷新数据");
        Canvas.SetLeft(_refreshBtn, 340 - 52);
        Canvas.SetTop(_refreshBtn, 9);
        canvas.Children.Add(_refreshBtn);

        _closeBtn = CreateHeaderButton("✕", HideWidget, "隐藏桌面小组件 (可在托盘菜单重新开启)");
        Canvas.SetLeft(_closeBtn, 340 - 28);
        Canvas.SetTop(_closeBtn, 9);
        canvas.Children.Add(_closeBtn);

        // 2. 四格核心指标卡片 (2x2)
        const double cardW = 148;
        const double cardH = 62;
        const double marginX = 14;
        const double row1Top = 36;
        const double row2Top = 106;

        // 卡片 1: 本月已用 (左上)
        (_card1Border, _usedFlowNumLabel, _usedFlowUnitLabel) = MakeMetricCard(
            width: cardW,
            height: cardH,
            label: "本月已用 (限200G)",
            defaultNum: "--",
            defaultUnit: "M",
            hasHelpIcon: false,
            onClick: () => HistoryStatsWindow.Shared.ShowWindow(0),
            toolTip: "本月校园网累计已用流量（每月 200GB 免费额度，400GB 封顶）· 点击查看流量统计");
        Canvas.SetLeft(_card1Border, marginX);
        Canvas.SetTop(_card1Border, row1Top);
        canvas.Children.Add(_card1Border);

        // 卡片 2: 今日已用 (右上)
        (_card2Border, _availFlowNumLabel, _availFlowUnitLabel) = MakeMetricCard(
            width: cardW,
            height: cardH,
            label: "今日已用 (限30G)",
            defaultNum: "--",
            defaultUnit: "M",
            hasHelpIcon: false,
            onClick: () => HistoryStatsWindow.Shared.ShowWindow(0),
            toolTip: "今日新增校园网流量消耗（单日 30GB 限额）· 点击查看详细统计");
        Canvas.SetLeft(_card2Border, marginX + cardW + 12);
        Canvas.SetTop(_card2Border, row1Top);
        canvas.Children.Add(_card2Border);

        // 卡片 3: 消费保护 (左下)
        (_card3Border, _protNumLabel, _protUnitLabel) = MakeMetricCard(
            width: cardW,
            height: cardH,
            label: "消费保护",
            defaultNum: "--",
            defaultUnit: "元",
            hasHelpIcon: true,
            onClick: () => LoginWebWindow.Shared.ShowLoginWindow(),
            toolTip: "点击授权自服务获取保护额度");
        Canvas.SetLeft(_card3Border, marginX);
        Canvas.SetTop(_card3Border, row2Top);
        canvas.Children.Add(_card3Border);

        // 卡片 4: 账户余额 (右下)
        (_card4Border, _balNumLabel, _balUnitLabel) = MakeMetricCard(
            width: cardW,
            height: cardH,
            label: "账户余额",
            defaultNum: "--",
            defaultUnit: "元",
            hasHelpIcon: false,
            onClick: () => HistoryStatsWindow.Shared.ShowWindow(0),
            toolTip: "校园网账户余额 · 点击查看历史用量与余额统计");
        Canvas.SetLeft(_card4Border, marginX + cardW + 12);
        Canvas.SetTop(_card4Border, row2Top);
        canvas.Children.Add(_card4Border);

        // 3. 跨两列课程/自习/考试智能卡片 (y = 176, height = 44)
        (_courseCardBorder, _courseIconLabel, _courseTitleLabel, _courseDetailLabel) = MakeCourseCard(
            width: 340 - marginX * 2,
            height: 44);
        Canvas.SetLeft(_courseCardBorder, marginX);
        Canvas.SetTop(_courseCardBorder, 176);
        canvas.Children.Add(_courseCardBorder);

        // 4. 底部月度限额进度条 (y = 229, height = 4)
        double barFullW = 340 - marginX * 2;
        _progressTrack = new Border
        {
            Width = barFullW,
            Height = 4,
            CornerRadius = new CornerRadius(2)
        };
        _progressFill = new Border
        {
            Width = 0,
            Height = 4,
            CornerRadius = new CornerRadius(2),
            HorizontalAlignment = HorizontalAlignment.Left
        };
        _progressTrack.Child = _progressFill;
        Canvas.SetLeft(_progressTrack, marginX);
        Canvas.SetTop(_progressTrack, 229);
        canvas.Children.Add(_progressTrack);

        // 5. 底部 6 槽位轮播文本栏 (y = 236)
        _updateTimeLabel = new TextBlock
        {
            Text = "等待更新...",
            Width = barFullW,
            FontSize = 10,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Cursor = Cursors.Hand,
            ToolTip = "点击打开对应详情分析窗口"
        };
        _updateTimeLabel.MouseLeftButtonUp += (_, e) =>
        {
            if (!_isDragging)
            {
                e.Handled = true;
                BottomLabelClicked();
            }
        };
        Canvas.SetLeft(_updateTimeLabel, marginX);
        Canvas.SetTop(_updateTimeLabel, 236);
        canvas.Children.Add(_updateTimeLabel);

        _rootBorder.Child = canvas;
        outerGrid.Children.Add(_rootBorder);
        Content = outerGrid;
    }

    private Button CreateHeaderButton(string text, Action onClick, string? toolTip = null)
    {
        var btn = new Button
        {
            Content = text,
            Width = 20,
            Height = 20,
            FontSize = 11.5,
            FontWeight = FontWeights.Bold,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Foreground = SecondaryTextBrush,
            Cursor = Cursors.Hand,
            Opacity = 0.0,
            ToolTip = toolTip
        };

        // 去除 WPF 默认 Button 悬停蓝色背景框模板
        var template = new ControlTemplate(typeof(Button));
        var bd = new FrameworkElementFactory(typeof(Border));
        bd.SetValue(Border.BackgroundProperty, new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)));
        bd.SetValue(Border.CornerRadiusProperty, new CornerRadius(5));
        var cp = new FrameworkElementFactory(typeof(ContentPresenter));
        cp.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        cp.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        bd.AppendChild(cp);
        template.VisualTree = bd;
        btn.Template = template;

        btn.Click += (_, e) =>
        {
            e.Handled = true;
            onClick();
        };
        return btn;
    }

    private void AnimateHeaderButtons(bool hovering)
    {
        double targetOpacity = hovering ? 0.90 : 0.0;
        var anim = new DoubleAnimation(targetOpacity, new Duration(TimeSpan.FromMilliseconds(180)));
        _pinModeBtn.BeginAnimation(OpacityProperty, anim);
        _refreshBtn.BeginAnimation(OpacityProperty, anim);
        _closeBtn.BeginAnimation(OpacityProperty, anim);
    }

    private (Border Card, TextBlock NumLabel, TextBlock UnitLabel) MakeMetricCard(
        double width,
        double height,
        string label,
        string defaultNum,
        string defaultUnit,
        bool hasHelpIcon,
        Action onClick,
        string toolTip)
    {
        var card = new Border
        {
            Width = width,
            Height = height,
            CornerRadius = new CornerRadius(12),
            BorderThickness = new Thickness(1),
            Cursor = Cursors.Hand,
            ToolTip = toolTip
        };

        var cardCanvas = new Canvas { Width = width, Height = height };

        if (hasHelpIcon)
        {
            var helpText = new TextBlock
            {
                Text = "?",
                FontSize = 10,
                FontWeight = FontWeights.Bold,
                Foreground = TertiaryTextBrush
            };
            Canvas.SetLeft(helpText, 8);
            Canvas.SetTop(helpText, 6);
            cardCanvas.Children.Add(helpText);
        }

        var numLabel = new TextBlock
        {
            Text = defaultNum,
            Width = width - 38,
            FontSize = 21,
            FontWeight = FontWeights.Bold,
            TextAlignment = TextAlignment.Center
        };
        Canvas.SetLeft(numLabel, 8);
        Canvas.SetTop(numLabel, 8);
        cardCanvas.Children.Add(numLabel);

        var unitLabel = new TextBlock
        {
            Text = defaultUnit,
            Width = 28,
            FontSize = 11,
            FontWeight = FontWeights.Medium
        };
        Canvas.SetLeft(unitLabel, width - 30);
        Canvas.SetTop(unitLabel, 18);
        cardCanvas.Children.Add(unitLabel);

        var titleBlock = new TextBlock
        {
            Text = label,
            Width = width,
            FontSize = 11,
            Foreground = SecondaryTextBrush,
            TextAlignment = TextAlignment.Center
        };
        Canvas.SetLeft(titleBlock, 0);
        Canvas.SetTop(titleBlock, 40);
        cardCanvas.Children.Add(titleBlock);

        card.Child = cardCanvas;
        card.MouseLeftButtonUp += (_, e) =>
        {
            if (!_isDragging)
            {
                e.Handled = true;
                onClick();
            }
        };

        return (card, numLabel, unitLabel);
    }

    private (Border Card, TextBlock IconLabel, TextBlock TitleLabel, TextBlock DetailLabel) MakeCourseCard(double width, double height)
    {
        var card = new Border
        {
            Width = width,
            Height = height,
            CornerRadius = new CornerRadius(12),
            BorderThickness = new Thickness(1),
            Cursor = Cursors.Hand
        };

        var canvas = new Canvas { Width = width, Height = height };

        var iconLabel = new TextBlock
        {
            Text = "📘",
            FontSize = 13,
            Foreground = new SolidColorBrush(Color.FromRgb(99, 102, 241))
        };
        Canvas.SetLeft(iconLabel, 10);
        Canvas.SetTop(iconLabel, 13);
        canvas.Children.Add(iconLabel);

        var titleLabel = new TextBlock
        {
            Text = "正在加载今日课程...",
            Width = width - 40,
            FontSize = 11.5,
            FontWeight = FontWeights.Bold,
            Foreground = PrimaryTextBrush,
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        Canvas.SetLeft(titleLabel, 32);
        Canvas.SetTop(titleLabel, 5);
        canvas.Children.Add(titleLabel);

        var detailLabel = new TextBlock
        {
            Text = "点击查看完整周课表",
            Width = width - 40,
            FontSize = 10,
            Foreground = SecondaryTextBrush,
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        Canvas.SetLeft(detailLabel, 32);
        Canvas.SetTop(detailLabel, 24);
        canvas.Children.Add(detailLabel);

        card.Child = canvas;
        card.MouseLeftButtonUp += (_, e) =>
        {
            if (!_isDragging)
            {
                e.Handled = true;
                CourseCardClicked();
            }
        };

        return (card, iconLabel, titleLabel, detailLabel);
    }

    private ContextMenu BuildContextMenu()
    {
        var menu = new ContextMenu();

        var refreshItem = new MenuItem { Header = "立即刷新全部数据" };
        refreshItem.Click += (_, _) => RefreshClicked();
        menu.Items.Add(refreshItem);

        menu.Items.Add(new Separator());

        _ctxPinDesktopItem = new MenuItem
        {
            Header = "嵌入桌面层 (不遮挡窗口，Win+D驻留)",
            IsCheckable = true,
            IsChecked = SettingsManager.Shared.WidgetPinToDesktop
        };
        _ctxPinDesktopItem.Click += (_, _) =>
        {
            SettingsManager.Shared.WidgetPinToDesktop = true;
            SettingsManager.Shared.Save();
            ApplyWindowLayerMode();
        };
        menu.Items.Add(_ctxPinDesktopItem);

        _ctxFloatTopItem = new MenuItem
        {
            Header = "置顶悬浮于所有窗口上方",
            IsCheckable = true,
            IsChecked = !SettingsManager.Shared.WidgetPinToDesktop
        };
        _ctxFloatTopItem.Click += (_, _) =>
        {
            SettingsManager.Shared.WidgetPinToDesktop = false;
            SettingsManager.Shared.Save();
            ApplyWindowLayerMode();
        };
        menu.Items.Add(_ctxFloatTopItem);

        menu.Items.Add(new Separator());

        var hideItem = new MenuItem { Header = "隐藏桌面小组件" };
        hideItem.Click += (_, _) => HideWidget();
        menu.Items.Add(hideItem);

        menu.Opened += (_, _) => UpdatePinButtonAppearance();
        return menu;
    }

    private void OnRootMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed)
        {
            try
            {
                Point startPt = PointToScreen(e.GetPosition(this));
                _isDragging = false;
                DragMove();
                Point endPt = PointToScreen(e.GetPosition(this));
                if (Math.Abs(endPt.X - startPt.X) > 3 || Math.Abs(endPt.Y - startPt.Y) > 3)
                {
                    _isDragging = true;
                    SaveWindowPosition();
                }
                if (SettingsManager.Shared.WidgetPinToDesktop)
                {
                    ApplyWindowLayerMode();
                }
            }
            catch
            {
                // Ignore DragMove exceptions if mouse released quickly
            }
        }
    }

    // MARK: - 数据与课程/自习/考试卡片更新逻辑

    private void OnHistoryStatsUpdated()
    {
        double todayMB = CampusHistoryManager.Shared.TodayFlowDeltaMB;
        string todayFormatted = todayMB >= 1024.0
            ? $"{todayMB / 1024.0:F2} G"
            : $"{todayMB:F0} M";
        var (todayNum, todayUnit) = SplitNumAndUnit(todayFormatted, "M");
        _availFlowNumLabel.Text = todayNum;
        _availFlowUnitLabel.Text = todayUnit;
        RenderBottomLabel();
    }

    public void SpeedMonitorDidUpdate(string download, string upload, string compact)
    {
        _currentSpeedString = $"↓ {download}   ↑ {upload}";
        if (_speedBadgeLabel != null)
        {
            _speedBadgeLabel.Text = compact;
        }
        if (_carouselIndex == 0 && _updateTimeLabel != null)
        {
            _updateTimeLabel.Text = $"实时速率：{_currentSpeedString}";
            _updateTimeLabel.Foreground = new SolidColorBrush(_isDarkTheme ? Color.FromRgb(45, 212, 191) : Color.FromRgb(13, 148, 136));
        }
    }

    public void UpdateData(CampusNetworkData data)
    {
        _currentData = data;
        var (usedNum, usedUnit) = SplitNumAndUnit(data.FormattedUsed, "M");
        double todayMB = CampusHistoryManager.Shared.TodayFlowDeltaMB;
        string todayFormatted = todayMB >= 1024.0
            ? $"{todayMB / 1024.0:F2} G"
            : $"{todayMB:F0} M";
        var (todayNum, todayUnit) = SplitNumAndUnit(todayFormatted, "M");
        var (protNum, protUnit) = SplitNumAndUnit(data.FlowProtection, "元");
        var (balNum, balUnit) = SplitNumAndUnit(data.Balance, "元");

        _usedFlowNumLabel.Text = usedNum;
        _usedFlowUnitLabel.Text = usedUnit;

        _availFlowNumLabel.Text = todayNum;
        _availFlowUnitLabel.Text = todayUnit;

        _protNumLabel.Text = protNum;
        _protUnitLabel.Text = protUnit;

        _balNumLabel.Text = balNum;
        _balUnitLabel.Text = balUnit;

        _currentProgressPercentage = Math.Clamp(data.UsagePercentage * 100.0, 0.0, 100.0);
        double trackW = _progressTrack.Width;
        _progressFill.Width = Math.Max(0, trackW * (_currentProgressPercentage / 100.0));

        UpdateCourseDisplay();
        RenderBottomLabel();
    }

    public void UpdateCourseDisplay()
    {
        if (_courseTitleLabel == null || _courseDetailLabel == null)
            return;

        DateTime now = DateTime.Now;
        int nowMin = EmptyClassroomService.CurrentMinutesOfDay(now);
        var service = EmptyClassroomService.Shared;

        // 1. 若当前自习室正在被占用或 35 分钟内即将被占用，优先弹出醒目换教室提醒
        var studyRoom = service.CurrentStudyRoomItem();
        if (studyRoom != null)
        {
            var (conflict, isOngoing, minsUntil, recs) = service.NearbySwitchRecommendations(studyRoom, limit: 2);
            if (conflict != null && isOngoing)
            {
                string nearNames = string.Join("、", recs.Select(r => $"{r.Room.NameZh}({r.Proximity.BadgeText})"));
                _courseTitleLabel.Text = $"自习冲突：{studyRoom.NameZh} 正在{conflict.CauseTitle}";
                _courseTitleLabel.Foreground = new SolidColorBrush(Color.FromRgb(239, 68, 68));
                _courseDetailLabel.Text = string.IsNullOrEmpty(nearNames)
                    ? $"占用时段 {conflict.StartTimeString}-{conflict.EndTimeString} · 点击打开空教室面板切换"
                    : $"推荐换至：{nearNames}";
                _courseDetailLabel.Foreground = PrimaryTextBrush;
                return;
            }
            if (conflict != null && minsUntil.HasValue && minsUntil.Value <= 35)
            {
                string nearNames = string.Join("、", recs.Select(r => $"{r.Room.NameZh}({r.Proximity.BadgeText})"));
                _courseTitleLabel.Text = $"自习提醒：{studyRoom.NameZh} {minsUntil.Value} 分钟后有{conflict.CauseTitle}";
                _courseTitleLabel.Foreground = new SolidColorBrush(Color.FromRgb(249, 115, 22));
                _courseDetailLabel.Text = string.IsNullOrEmpty(nearNames)
                    ? $"{conflict.StartTimeString}-{conflict.EndTimeString} 占用 · 点击查看附近空教室"
                    : $"建议切换：{nearNames}";
                _courseDetailLabel.Foreground = PrimaryTextBrush;
                return;
            }
        }

        // 2. 若未开启课表展示，展示当前自习或今日全天空闲教室推荐
        if (!SettingsManager.Shared.CourseTableEnabled)
        {
            if (studyRoom != null)
            {
                _courseTitleLabel.Text = $"当前自习：{studyRoom.NameZh}";
                _courseTitleLabel.Foreground = new SolidColorBrush(Color.FromRgb(34, 197, 94));
                var nextOcc = studyRoom.NextOccupation(nowMin);
                _courseDetailLabel.Text = nextOcc != null
                    ? $"空闲至 {nextOcc.StartTimeString} ({nextOcc.ShortCourseName}) · 点击查看空教室推荐"
                    : "今日余下时段全部空闲 · 点击查看明日自习推荐";
                _courseDetailLabel.Foreground = SecondaryTextBrush;
                return;
            }

            var picks = service.RecommendedTodayAllDayFreeRooms(limit: 2);
            if (picks.Count > 0)
            {
                string names = string.Join("、", picks.Select(p => p.NameZh));
                _courseTitleLabel.Text = $"自习空教室：{names} 全天空闲";
                _courseTitleLabel.Foreground = new SolidColorBrush(Color.FromRgb(59, 130, 246));
                _courseDetailLabel.Text = "点击打开自习空教室与时间轴面板";
            }
            else
            {
                _courseTitleLabel.Text = "自习空教室查询与推荐";
                _courseTitleLabel.Foreground = new SolidColorBrush(Color.FromRgb(59, 130, 246));
                _courseDetailLabel.Text = "点击查看全天空闲教室、课前换座与明日留座推荐";
            }
            _courseDetailLabel.Foreground = SecondaryTextBrush;
            return;
        }

        // 3. 检查本地课表缓存
        var schedule = CourseScheduleService.Shared.CurrentSchedule;
        if (schedule == null || schedule.Lessons.Count == 0)
        {
            if (studyRoom != null)
            {
                _courseTitleLabel.Text = $"当前自习：{studyRoom.NameZh}";
                _courseTitleLabel.Foreground = new SolidColorBrush(Color.FromRgb(34, 197, 94));
                var nextOcc = studyRoom.NextOccupation(nowMin);
                _courseDetailLabel.Text = nextOcc != null
                    ? $"空闲至 {nextOcc.StartTimeString} ({nextOcc.ShortCourseName}) · 点击查看空教室推荐"
                    : "今日余下时段全部空闲 · 点击查看明日自习推荐";
                _courseDetailLabel.Foreground = SecondaryTextBrush;
                return;
            }

            _courseTitleLabel.Text = "教务课表：点击同步课程";
            _courseTitleLabel.Foreground = new SolidColorBrush(Color.FromRgb(59, 130, 246));
            _courseDetailLabel.Text = "支持合工大 EAMS 5.0 课表与自习空教室智能推荐";
            _courseDetailLabel.Foreground = SecondaryTextBrush;
            return;
        }

        var todayLessons = schedule.TodayLessons(now);
        int currentWeek = schedule.CurrentWeek(now) ?? 1;
        string weekStr = $"第 {currentWeek} 周";

        var ongoing = schedule.CurrentLesson(now);
        var next = schedule.NextLesson(now);

        if (ongoing != null)
        {
            _courseTitleLabel.Text = $"上课中：{ongoing.CourseName}";
            _courseTitleLabel.Foreground = new SolidColorBrush(Color.FromRgb(34, 197, 94));
            string room = !string.IsNullOrEmpty(ongoing.Classroom) ? $"· {ongoing.Classroom}" : "";
            string teacher = !string.IsNullOrEmpty(ongoing.Teacher) ? ongoing.Teacher! : "--";
            _courseDetailLabel.Text = $"{ongoing.FormattedTime} {room} | 教师: {teacher}";
            _courseDetailLabel.Foreground = PrimaryTextBrush;
        }
        else if (next != null)
        {
            _courseTitleLabel.Text = $"下一节：{next.FormattedStartTime} {next.CourseName}";
            _courseTitleLabel.Foreground = new SolidColorBrush(Color.FromRgb(129, 140, 248));
            string room = !string.IsNullOrEmpty(next.Classroom) ? next.Classroom! : "待定";
            _courseDetailLabel.Text = $"地点: {room} | {next.FormattedTime}";
            _courseDetailLabel.Foreground = SecondaryTextBrush;
        }
        else if (studyRoom != null)
        {
            _courseTitleLabel.Text = $"当前自习：{studyRoom.NameZh}";
            _courseTitleLabel.Foreground = new SolidColorBrush(Color.FromRgb(34, 197, 94));
            var nextOcc = studyRoom.NextOccupation(nowMin);
            _courseDetailLabel.Text = nextOcc != null
                ? $"空闲至 {nextOcc.StartTimeString} · 点击查看附近空教室与明日推荐"
                : "今日余下全空 · 点击查看明日自习推荐";
            _courseDetailLabel.Foreground = SecondaryTextBrush;
        }
        else if (AcademicService.Shared.LatestData?.UpcomingExams(now).FirstOrDefault() is { } upcomingExam &&
                 upcomingExam.DaysRemaining(now) <= 21)
        {
            int days = upcomingExam.DaysRemaining(now);
            _courseTitleLabel.Text = $"考试倒计时：距《{upcomingExam.CourseName}》{upcomingExam.CountdownBadgeText(now)}";
            _courseTitleLabel.Foreground = days <= 3
                ? new SolidColorBrush(Color.FromRgb(239, 68, 68))
                : new SolidColorBrush(Color.FromRgb(249, 115, 22));
            _courseDetailLabel.Text = $"时间: {upcomingExam.DateTimeString} | 地点: {upcomingExam.DisplayLocation}";
            _courseDetailLabel.Foreground = SecondaryTextBrush;
        }
        else if (todayLessons.Count > 0)
        {
            _courseTitleLabel.Text = "今日课程已全部结束";
            _courseTitleLabel.Foreground = PrimaryTextBrush;
            _courseDetailLabel.Text = $"今日共 {todayLessons.Count} 节课 · {weekStr} · 点击查看完整课表";
            _courseDetailLabel.Foreground = SecondaryTextBrush;
        }
        else
        {
            _courseTitleLabel.Text = "今日暂无排课";
            _courseTitleLabel.Foreground = PrimaryTextBrush;
            string weekdayStr = CourseCalendarHelper.WeekdayName(CourseCalendarHelper.Weekday(now));
            _courseDetailLabel.Text = $"{weekStr} · {weekdayStr} · 点击查看完整周课表";
            _courseDetailLabel.Foreground = SecondaryTextBrush;
        }
    }

    private void CourseCardClicked()
    {
        if (!SettingsManager.Shared.CourseTableEnabled)
        {
            EmptyClassroomWindow.Shared.ShowWindowAndSync();
            return;
        }

        var schedule = CourseScheduleService.Shared.CurrentSchedule;
        if (schedule == null || schedule.Lessons.Count == 0)
        {
            CourseScheduleWindow.Shared.ShowWindow();
            CourseScheduleService.Shared.SyncSchedule((sched, err) =>
            {
                if (sched == null && !string.IsNullOrEmpty(err))
                {
                    CourseLoginWebWindow.Shared.ShowLoginWindow();
                }
            });
            return;
        }

        DateTime now = DateTime.Now;
        int nowMin = EmptyClassroomService.CurrentMinutesOfDay(now);
        var studyRoom = EmptyClassroomService.Shared.CurrentStudyRoomItem();
        if (studyRoom != null)
        {
            if (studyRoom.CurrentOccupation(nowMin) != null ||
                (studyRoom.MinutesUntilNextOccupation(nowMin) ?? 999) <= 35)
            {
                EmptyClassroomWindow.Shared.ShowWindowAndSync();
                return;
            }
            if (schedule.CurrentLesson(now) == null && schedule.NextLesson(now) == null)
            {
                EmptyClassroomWindow.Shared.ShowWindowAndSync();
                return;
            }
        }

        if (schedule.CurrentLesson(now) == null && schedule.NextLesson(now) == null &&
            AcademicService.Shared.LatestData?.UpcomingExams(now).FirstOrDefault() is { } upcomingExam &&
            upcomingExam.DaysRemaining(now) <= 21)
        {
            AcademicWindow.Shared.ShowWindow(1);
            return;
        }

        CourseScheduleWindow.Shared.ShowWindow();
    }

    // MARK: - 底部 6 槽位轮播栏 (3.5s 周期)

    private void StartSpeedCarousel()
    {
        _carouselTimer?.Stop();
        _carouselTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(3.5)
        };
        _carouselTimer.Tick += (_, _) =>
        {
            _carouselIndex = (_carouselIndex + 1) % 6;
            if (_carouselIndex == 0)
            {
                UpdateCourseDisplay();
            }
            RenderBottomLabel();
        };
        _carouselTimer.Start();
    }

    private void RenderBottomLabel()
    {
        if (_updateTimeLabel == null)
            return;

        switch (_carouselIndex)
        {
            case 0:
                // 槽位 0: 实时网速
                _updateTimeLabel.Text = $"实时速率：{_currentSpeedString}";
                _updateTimeLabel.Foreground = new SolidColorBrush(_isDarkTheme ? Color.FromRgb(45, 212, 191) : Color.FromRgb(13, 148, 136));
                break;

            case 1:
                // 槽位 1: 更新时间与百分比
                double pct = _currentData.UsagePercentage * 100.0;
                if (!string.IsNullOrEmpty(_currentData.ErrorMessage))
                {
                    if (_currentData.UsedMB.HasValue)
                    {
                        _updateTimeLabel.Text = $"{_currentData.ErrorMessage} · 本月已用 {pct:F1}%";
                        _updateTimeLabel.Foreground = new SolidColorBrush(Color.FromRgb(249, 115, 22));
                    }
                    else
                    {
                        _updateTimeLabel.Text = _currentData.ErrorMessage;
                        _updateTimeLabel.Foreground = new SolidColorBrush(Color.FromRgb(239, 68, 68));
                    }
                    return;
                }
                string timeStr = _currentData.LastUpdated.HasValue
                    ? $"更新于 {_currentData.LastUpdated.Value:HH:mm:ss}"
                    : "未更新";
                _updateTimeLabel.Text = $"{timeStr} · 已用 {pct:F1}%";
                _updateTimeLabel.Foreground = TertiaryTextBrush;
                break;

            case 2:
                // 槽位 2: 宿舍电费
                ElectricityData? elecData = ElectricityService.Shared.LatestData;
                if (elecData == null && SettingsManager.Shared.IsDormConfigured &&
                    CampusHistoryManager.Shared.LatestElectricityRecord is { } lastRec)
                {
                    elecData = new ElectricityData
                    {
                        Campus = SettingsManager.Shared.DormCampus,
                        Building = SettingsManager.Shared.DormBuilding,
                        Room = SettingsManager.Shared.DormRoom,
                        EndNumber = SettingsManager.Shared.DormEndNumber,
                        BalanceRMB = lastRec.BalanceRMB,
                        RemainingKWh = lastRec.RemainingKWh ?? Math.Round(lastRec.BalanceRMB / 0.58, 1),
                        LastUpdated = lastRec.LastUpdated
                    };
                }
                if (elecData != null)
                {
                    string warn = elecData.IsLowBalance ? "余额偏低 · " : "";
                    int? daysLeft = CampusHistoryManager.Shared.EstimatedElectricityDaysRemaining;
                    string daysText = daysLeft.HasValue ? $" · 约余 {daysLeft.Value} 天" : "";
                    _updateTimeLabel.Text = $"{warn}宿舍电费：{elecData.DisplayBalance}{daysText}";
                    _updateTimeLabel.Foreground = elecData.IsLowBalance
                        ? new SolidColorBrush(Color.FromRgb(239, 68, 68))
                        : new SolidColorBrush(Color.FromRgb(249, 115, 22));
                }
                else
                {
                    _updateTimeLabel.Text = "宿舍电费：点击查看历史用量与配置";
                    _updateTimeLabel.Foreground = new SolidColorBrush(Color.FromRgb(249, 115, 22));
                }
                break;

            case 3:
                // 槽位 3: 校园一卡通余额与今日消费
                if (CampusCardService.Shared.LatestData is { } card)
                {
                    DateTime now = DateTime.Now;
                    string warn = card.IsLowBalance ? "余额偏低 · " : "";
                    int todayCount = card.TodayExpenseCount(now);
                    double todaySpent = card.TodaySpentRMB(now);
                    string todayPart = todayCount > 0 ? $" · 今日消费 ¥{todaySpent:F2}" : " · 今日无消费";
                    _updateTimeLabel.Text = $"{warn}校园一卡通：{card.DisplayBalance}{todayPart}";
                    _updateTimeLabel.Foreground = card.IsLowBalance
                        ? new SolidColorBrush(Color.FromRgb(239, 68, 68))
                        : new SolidColorBrush(Color.FromRgb(34, 197, 94));
                }
                else
                {
                    _updateTimeLabel.Text = "校园一卡通：点击查看卡内余额与消费流水";
                    _updateTimeLabel.Foreground = new SolidColorBrush(Color.FromRgb(34, 197, 94));
                }
                break;

            case 4:
                // 槽位 4: 考试与成绩
                DateTime nowAc = DateTime.Now;
                var snap = AcademicService.Shared.LatestData;
                int unreadCount = AcademicService.Shared.UnreadGradeCount;
                if (unreadCount > 0)
                {
                    _updateTimeLabel.Text = $"考试与成绩：检测到 {unreadCount} 门新出分，点击查看详情";
                    _updateTimeLabel.Foreground = new SolidColorBrush(Color.FromRgb(249, 115, 22));
                }
                else if (snap?.UpcomingExams(nowAc).FirstOrDefault() is { } nextExam)
                {
                    _updateTimeLabel.Text = $"考试倒计时：距《{nextExam.CourseName}》{nextExam.CountdownBadgeText(nowAc)} ({nextExam.DisplayLocation})";
                    int days = nextExam.DaysRemaining(nowAc);
                    _updateTimeLabel.Foreground = days <= 3
                        ? new SolidColorBrush(Color.FromRgb(239, 68, 68))
                        : new SolidColorBrush(Color.FromRgb(249, 115, 22));
                }
                else if (snap != null && snap.AllGrades.Count > 0)
                {
                    _updateTimeLabel.Text = "考试与成绩：暂无新出分 · 点击查看成绩单与考试安排";
                    _updateTimeLabel.Foreground = new SolidColorBrush(Color.FromRgb(168, 85, 247));
                }
                else
                {
                    _updateTimeLabel.Text = "考试与成绩：点击查看考场倒计时与 GPA 测算";
                    _updateTimeLabel.Foreground = new SolidColorBrush(Color.FromRgb(168, 85, 247));
                }
                break;

            default:
                // 槽位 5: 自习空教室状态与推荐
                int nowMin = EmptyClassroomService.CurrentMinutesOfDay();
                if (SettingsManager.Shared.CurrentStudyRoom is { } record)
                {
                    if (EmptyClassroomService.Shared.CurrentStudyRoomItem() is { } live)
                    {
                        if (live.CurrentOccupation(nowMin) is { } curOcc)
                        {
                            _updateTimeLabel.Text = $"自习室：{record.RoomName} (当前{curOcc.CauseTitle}中至 {curOcc.EndTimeString} · 点击切换)";
                            _updateTimeLabel.Foreground = new SolidColorBrush(Color.FromRgb(239, 68, 68));
                        }
                        else if (live.NextOccupation(nowMin) is { } nextOcc)
                        {
                            _updateTimeLabel.Text = $"自习室：{record.RoomName} (空至 {nextOcc.StartTimeString} · 点击管理)";
                            _updateTimeLabel.Foreground = new SolidColorBrush(Color.FromRgb(34, 197, 94));
                        }
                        else
                        {
                            _updateTimeLabel.Text = $"自习室：{record.RoomName} (今日余下全空 · 点击管理)";
                            _updateTimeLabel.Foreground = new SolidColorBrush(Color.FromRgb(34, 197, 94));
                        }
                    }
                    else
                    {
                        _updateTimeLabel.Text = $"自习室：{record.RoomName} (点击查看占用与推荐)";
                        _updateTimeLabel.Foreground = new SolidColorBrush(Color.FromRgb(34, 197, 94));
                    }
                }
                else
                {
                    var picks = EmptyClassroomService.Shared.RecommendedTodayAllDayFreeRooms(limit: 2);
                    if (picks.Count > 0)
                    {
                        string names = string.Join("、", picks.Select(p => p.NameZh));
                        _updateTimeLabel.Text = $"今日全空推荐：{names} (点击设定自习室)";
                    }
                    else
                    {
                        _updateTimeLabel.Text = "自习空教室：点击查询全天空闲教室与自习管理";
                    }
                    _updateTimeLabel.Foreground = new SolidColorBrush(Color.FromRgb(59, 130, 246));
                }
                break;
        }
    }

    private void BottomLabelClicked()
    {
        switch (_carouselIndex)
        {
            case 2:
                HistoryStatsWindow.Shared.ShowWindow(1);
                break;
            case 3:
                HistoryStatsWindow.Shared.ShowWindow(2);
                break;
            case 4:
                bool hasUpcoming = (AcademicService.Shared.LatestData?.UpcomingExams(DateTime.Now).Count ?? 0) > 0;
                AcademicWindow.Shared.ShowWindow(hasUpcoming ? 1 : 0);
                break;
            case 5:
                EmptyClassroomWindow.Shared.ShowWindowAndSync();
                break;
            default:
                HistoryStatsWindow.Shared.ShowWindow(0);
                break;
        }
    }

    private static (string Num, string Unit) SplitNumAndUnit(string text, string fallbackUnit)
    {
        string trimmed = (text ?? string.Empty).Trim();
        if (trimmed == "未设置" || trimmed == "无")
            return (trimmed, string.Empty);

        if (trimmed.StartsWith("--", StringComparison.Ordinal))
        {
            string rest = trimmed.Substring(2).Trim();
            return ("--", string.IsNullOrEmpty(rest) ? fallbackUnit : rest);
        }

        var match = Regex.Match(trimmed, @"^(-?[0-9\.]+)\s*(.*)$");
        if (!match.Success)
            return (trimmed, string.Empty);

        string num = match.Groups[1].Value;
        string unit = string.IsNullOrWhiteSpace(match.Groups[2].Value) ? fallbackUnit : match.Groups[2].Value.Trim();
        return (num, unit);
    }

    private void RefreshClicked()
    {
        CampusNetworkClient.Shared.FetchData();
        CampusCardService.Shared.FetchData();
        AcademicService.Shared.SyncAll(silent: true);
        if (SettingsManager.Shared.CourseTableEnabled)
        {
            CourseScheduleService.Shared.SyncSchedule();
        }
        EmptyClassroomService.Shared.SyncTodayAndTomorrowStudyRooms(forceRefresh: true);
    }
}
