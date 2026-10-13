using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using MediaColor = System.Windows.Media.Color;
using MediaBrushes = System.Windows.Media.Brushes;

namespace HFUTCampusNet;

#region Settings Window

/// <summary>
/// 1:1 Windows WPF Port of SettingsWindowController.swift.
/// Tabbed modern Dark/Light capable settings window with 4 tabs:
/// 1) 网络与认证 (Portal credentials, SSO, self-service extraction)
/// 2) 宿舍与生活 (Campus, building, room, electricity & card thresholds)
/// 3) 小组件与外观 (Opacity, desktop pin level, intervals, course table)
/// 4) 通用与关于 (Startup on boot, auto update, version info)
/// </summary>
public class SettingsWindow : Window
{
    private static SettingsWindow? _shared;
    public static SettingsWindow Shared => _shared ??= new SettingsWindow();

    // Tab 1: Net & Auth
    private TextBox _portalUsernameBox = null!;
    private PasswordBox _portalPasswordBox = null!;
    private PasswordBox _casPasswordBox = null!;
    private CheckBox _autoLoginCheck = null!;
    private TextBlock _cookieStatusBlock = null!;

    // Tab 2: Dorm & Life
    private ComboBox _campusCombo = null!;
    private TextBox _buildingBox = null!;
    private TextBox _roomBox = null!;
    private TextBox _endNumberBox = null!;
    private TextBox _roomNameBox = null!;
    private TextBox _elecThresholdBox = null!;
    private TextBox _cardThresholdBox = null!;
    private TextBox _cardBudgetBox = null!;

    // Tab 3: Widget & Appearance
    private CheckBox _showWidgetCheck = null!;
    private CheckBox _pinWidgetCheck = null!;
    private Slider _opacitySlider = null!;
    private TextBlock _opacityValueBlock = null!;
    private Slider _carouselSlider = null!;
    private TextBlock _carouselValueBlock = null!;
    private ComboBox _refreshIntervalCombo = null!;
    private CheckBox _courseTableCheck = null!;
    private CheckBox _hideScoreNotificationCheck = null!;

    // Tab 4: General
    private CheckBox _bootCheck = null!;
    private CheckBox _updateCheck = null!;
    private TextBlock _versionBlock = null!;

    public SettingsWindow()
    {
        Title = "偏好设置 - 合工大校园助手";
        Width = 620;
        Height = 560;
        MinWidth = 560;
        MinHeight = 500;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(MediaColor.FromRgb(22, 24, 30));
        Foreground = new SolidColorBrush(MediaColor.FromRgb(235, 238, 245));
        ResizeMode = ResizeMode.CanResize;

        Content = BuildContent();

        Closing += (_, e) =>
        {
            e.Cancel = true;
            SaveSettings();
            Hide();
        };

        Loaded += (_, _) => LoadSettings();
    }

    public void ShowWindow()
    {
        LoadSettings();
        if (WindowState == WindowState.Minimized)
            WindowState = WindowState.Normal;
        Show();
        Activate();
    }

    public void ShowSettings() => ShowWindow();

    private UIElement BuildContent()
    {
        var mainGrid = new Grid();
        mainGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // Header
        mainGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); // Tabs
        mainGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // Footer buttons

        // Header
        var header = new Border
        {
            Background = new SolidColorBrush(MediaColor.FromArgb(180, 28, 30, 38)),
            Padding = new Thickness(24, 18, 24, 16),
            BorderBrush = new SolidColorBrush(MediaColor.FromArgb(40, 255, 255, 255)),
            BorderThickness = new Thickness(0, 0, 0, 1)
        };
        var headerStack = new StackPanel();
        var headerTitle = new TextBlock
        {
            Text = "⚙️ 偏好设置",
            FontSize = 18,
            FontWeight = FontWeights.Bold,
            Foreground = MediaBrushes.White
        };
        var headerSub = new TextBlock
        {
            Text = "配置校园网认证、宿舍电费、一卡通、课表以及桌面小组件参数",
            FontSize = 12,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(160, 166, 180)),
            Margin = new Thickness(0, 4, 0, 0)
        };
        headerStack.Children.Add(headerTitle);
        headerStack.Children.Add(headerSub);
        header.Child = headerStack;
        Grid.SetRow(header, 0);
        mainGrid.Children.Add(header);

        // Tab Control
        var tabControl = new TabControl
        {
            Background = MediaBrushes.Transparent,
            BorderThickness = new Thickness(0),
            Margin = new Thickness(16, 12, 16, 12)
        };

        tabControl.Items.Add(new TabItem { Header = "🌐 网络与认证", Content = BuildNetTab() });
        tabControl.Items.Add(new TabItem { Header = "⚡ 宿舍与生活", Content = BuildDormTab() });
        tabControl.Items.Add(new TabItem { Header = "🖥️ 小组件与外观", Content = BuildAppearanceTab() });
        tabControl.Items.Add(new TabItem { Header = "⚙️ 通用与关于", Content = BuildGeneralTab() });

        Grid.SetRow(tabControl, 1);
        mainGrid.Children.Add(tabControl);

        // Footer buttons
        var footer = new Border
        {
            Background = new SolidColorBrush(MediaColor.FromArgb(140, 24, 26, 33)),
            Padding = new Thickness(20, 12, 20, 14),
            BorderBrush = new SolidColorBrush(MediaColor.FromArgb(35, 255, 255, 255)),
            BorderThickness = new Thickness(0, 1, 0, 0)
        };
        var footerPanel = new DockPanel();
        var statusHint = new TextBlock
        {
            Text = "设置已自动保存，更改将实时生效",
            FontSize = 11.5,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(140, 146, 160)),
            VerticalAlignment = VerticalAlignment.Center
        };
        DockPanel.SetDock(statusHint, Dock.Left);
        footerPanel.Children.Add(statusHint);

        var saveBtn = CreatePrimaryButton("保存并应用", () =>
        {
            SaveSettings();
            Hide();
        });
        saveBtn.HorizontalAlignment = HorizontalAlignment.Right;
        DockPanel.SetDock(saveBtn, Dock.Right);
        footerPanel.Children.Add(saveBtn);

        footer.Child = footerPanel;
        Grid.SetRow(footer, 2);
        mainGrid.Children.Add(footer);

        return mainGrid;
    }

    private UIElement BuildNetTab()
    {
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var stack = new StackPanel { Margin = new Thickness(12, 12, 12, 12) };

        // Group 1: Portal Login
        stack.Children.Add(CreateGroupHeader("校园网 Portal 认证 (锐捷/合工大热点认证)"));

        _portalUsernameBox = CreateStyledTextBox();
        stack.Children.Add(CreateFormField("学号 / 工号：", _portalUsernameBox, "用于校园网出校网页认证"));

        _portalPasswordBox = CreateStyledPasswordBox();
        stack.Children.Add(CreateFormField("Portal 认证密码：", _portalPasswordBox, "校园网开户密码"));

        _autoLoginCheck = CreateStyledCheckBox("网络离线或断开时自动登录校园网 (Auto-Login)");
        _autoLoginCheck.Margin = new Thickness(0, 4, 0, 10);
        stack.Children.Add(_autoLoginCheck);

        // Group 2: CAS SSO Login
        stack.Children.Add(CreateGroupHeader("统一身份认证 (CAS SSO 账户)"));

        _casPasswordBox = CreateStyledPasswordBox();
        stack.Children.Add(CreateFormField("CAS 统一认证密码：", _casPasswordBox, "用于一卡通、宿舍电费、教务课表及成绩查询"));

        var ssoRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 12) };
        var ssoBtn = CreateSecondaryButton("🔐 统一身份认证网页快速登录...", () =>
        {
            UnifiedLoginWebWindow.Shared.ShowWindow();
        });
        var testNetBtn = CreateSecondaryButton("⚡ 一键测试 Portal 登录", () =>
        {
            SaveSettings();
            CampusNetworkClient.Shared.ClearManualLogout();
            PortalAuthService.Shared.Login(_portalUsernameBox.Text, _portalPasswordBox.Password, (ok, msg) =>
            {
                AppEvents.InvokeOnUI(() =>
                {
                    MessageBox.Show(this, ok ? "校园网认证成功！" : $"认证失败：{msg}", "校园网测试", MessageBoxButton.OK,
                        ok ? MessageBoxImage.Information : MessageBoxImage.Warning);
                });
            });
        });
        testNetBtn.Margin = new Thickness(10, 0, 0, 0);
        ssoRow.Children.Add(ssoBtn);
        ssoRow.Children.Add(testNetBtn);
        stack.Children.Add(ssoRow);

        // Group 3: Auxiliary Cookie status & extraction
        stack.Children.Add(CreateGroupHeader("会话凭证状态与辅助同步"));
        _cookieStatusBlock = new TextBlock
        {
            Text = "正在检测当前凭据状态...",
            FontSize = 11.5,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(165, 172, 185)),
            Margin = new Thickness(0, 2, 0, 8),
            TextWrapping = TextWrapping.Wrap
        };
        stack.Children.Add(_cookieStatusBlock);

        var auxRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 10) };
        var selfServiceBtn = CreateSecondaryButton("🌐 自助服务登录 (提取流量)", () =>
        {
            LoginWebWindow.Shared.ShowWindow();
        });
        var courseLoginBtn = CreateSecondaryButton("📚 教务系统登录 (提取课表)", () =>
        {
            CourseLoginWebWindow.Shared.ShowWindow();
        });
        courseLoginBtn.Margin = new Thickness(10, 0, 0, 0);

        var clearCredsBtn = CreateSecondaryButton("🗑️ 清除所有凭证缓存", () =>
        {
            if (MessageBox.Show(this, "确定要清除所有保存的 Cookie、Token 及课表缓存吗？", "清除凭证", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
            {
                SettingsManager.Shared.SessionCookie = "";
                SettingsManager.Shared.CourseSessionCookie = "";
                SettingsManager.Shared.CasTgcCookie = "";
                SettingsManager.Shared.HuixinAuthToken = "";
                SettingsManager.Shared.UniAppJwt = "";
                SettingsManager.Shared.Save();
                CourseScheduleService.Shared.ClearSchedule();
                AcademicService.Shared.ClearCache();
                CampusCardService.Shared.ClearCache();
                UpdateCookieStatusLabel();
            }
        });
        clearCredsBtn.Margin = new Thickness(10, 0, 0, 0);

        auxRow.Children.Add(selfServiceBtn);
        auxRow.Children.Add(courseLoginBtn);
        auxRow.Children.Add(clearCredsBtn);
        stack.Children.Add(auxRow);

        scroll.Content = stack;
        return scroll;
    }

    private UIElement BuildDormTab()
    {
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var stack = new StackPanel { Margin = new Thickness(12, 12, 12, 12) };

        stack.Children.Add(CreateGroupHeader("宿舍信息配置 (获取剩余电量及充电信息)"));

        _campusCombo = new ComboBox
        {
            Height = 32,
            Background = new SolidColorBrush(MediaColor.FromArgb(200, 32, 34, 42)),
            Foreground = MediaBrushes.White,
            BorderBrush = new SolidColorBrush(MediaColor.FromArgb(50, 255, 255, 255)),
            Margin = new Thickness(0, 0, 0, 10)
        };
        _campusCombo.Items.Add(new ComboBoxItem { Content = "屯溪路校区 (tunxi)", Tag = "tunxi" });
        _campusCombo.Items.Add(new ComboBoxItem { Content = "翡翠湖校区 (feicui)", Tag = "feicui" });
        _campusCombo.Items.Add(new ComboBoxItem { Content = "宣城校区 (xuancheng)", Tag = "xuancheng" });
        stack.Children.Add(CreateFormField("所在校区：", _campusCombo, "请选择您的宿舍所在校区"));

        _buildingBox = CreateStyledTextBox();
        stack.Children.Add(CreateFormField("楼栋名称/编号：", _buildingBox, "例如：翡翠湖 5号楼 / 屯溪路 7号楼"));

        _roomBox = CreateStyledTextBox();
        stack.Children.Add(CreateFormField("房间号：", _roomBox, "例如：312"));

        _endNumberBox = CreateStyledTextBox();
        stack.Children.Add(CreateFormField("电表端号/结尾编号：", _endNumberBox, "通常与房间号末位相同或系统特定分配"));

        _roomNameBox = CreateStyledTextBox();
        stack.Children.Add(CreateFormField("房间自定义备注名称：", _roomNameBox, "选填，小组件中展示的简称，例如：翠5-312"));

        var testDormRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 16) };
        var testDormBtn = CreateSecondaryButton("⚡ 测试拉取电费数据", () =>
        {
            SaveSettings();
            ElectricityService.Shared.InvalidateCacheIfDormChanged();
            ElectricityService.Shared.FetchData((data, err) =>
            {
                AppEvents.InvokeOnUI(() =>
                {
                    if (data != null && data.IsSuccess)
                        MessageBox.Show(this, $"电费查询成功！\n剩余电量：{data.RemainingKWh} 度\n房间：{data.RoomName}", "电费测试", MessageBoxButton.OK, MessageBoxImage.Information);
                    else
                        MessageBox.Show(this, $"查询失败：{err ?? data?.ErrorMessage ?? "未知错误"}", "电费测试", MessageBoxButton.OK, MessageBoxImage.Warning);
                });
            });
        });
        testDormRow.Children.Add(testDormBtn);
        stack.Children.Add(testDormRow);

        stack.Children.Add(CreateGroupHeader("预警阈值与校园卡预算"));

        _elecThresholdBox = CreateStyledTextBox();
        stack.Children.Add(CreateFormField("电量低预警阈值 (度)：", _elecThresholdBox, "低于该数值时发送气泡通知，设为 0 关闭"));

        _cardThresholdBox = CreateStyledTextBox();
        stack.Children.Add(CreateFormField("一卡通余额预警阈值 (元)：", _cardThresholdBox, "低于该金额时发送通知，设为 0 关闭"));

        _cardBudgetBox = CreateStyledTextBox();
        stack.Children.Add(CreateFormField("一卡通单日消费预算 (元)：", _cardBudgetBox, "用于仪表盘进度条超支预警，默认 30 元"));

        scroll.Content = stack;
        return scroll;
    }

    private UIElement BuildAppearanceTab()
    {
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var stack = new StackPanel { Margin = new Thickness(12, 12, 12, 12) };

        stack.Children.Add(CreateGroupHeader("桌面小组件显示与层级"));

        _showWidgetCheck = CreateStyledCheckBox("显示透明悬浮小组件 (Desktop Widget)");
        _showWidgetCheck.Click += (_, _) =>
        {
            DesktopWidgetWindow.Shared.SetWidgetVisible(_showWidgetCheck.IsChecked == true);
        };
        stack.Children.Add(_showWidgetCheck);

        _pinWidgetCheck = CreateStyledCheckBox("小组件嵌入桌面底层 (不遮挡其他窗口，按 Win+D 不会最小化)");
        _pinWidgetCheck.Margin = new Thickness(0, 8, 0, 16);
        _pinWidgetCheck.Click += (_, _) =>
        {
            DesktopWidgetWindow.Shared.UpdatePinLevel(_pinWidgetCheck.IsChecked == true);
        };
        stack.Children.Add(_pinWidgetCheck);

        stack.Children.Add(CreateGroupHeader("小组件透明度与轮播速度"));

        // Opacity
        var opacityDock = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        var opLabel = new TextBlock { Text = "小组件不透明度：", Width = 150, Foreground = MediaBrushes.White, VerticalAlignment = VerticalAlignment.Center };
        _opacityValueBlock = new TextBlock { Text = "100%", Width = 45, TextAlignment = TextAlignment.Right, Foreground = new SolidColorBrush(MediaColor.FromRgb(10, 132, 255)), VerticalAlignment = VerticalAlignment.Center };
        _opacitySlider = new Slider { Minimum = 30, Maximum = 100, SmallChange = 5, LargeChange = 10 };
        _opacitySlider.ValueChanged += (_, e) =>
        {
            _opacityValueBlock.Text = $"{e.NewValue:F0}%";
            DesktopWidgetWindow.Shared.UpdateOpacity(e.NewValue / 100.0);
        };
        DockPanel.SetDock(opLabel, Dock.Left);
        DockPanel.SetDock(_opacityValueBlock, Dock.Right);
        opacityDock.Children.Add(opLabel);
        opacityDock.Children.Add(_opacityValueBlock);
        opacityDock.Children.Add(_opacitySlider);
        stack.Children.Add(opacityDock);

        // Carousel interval
        var carouselDock = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
        var carLabel = new TextBlock { Text = "底部栏轮播切换周期：", Width = 150, Foreground = MediaBrushes.White, VerticalAlignment = VerticalAlignment.Center };
        _carouselValueBlock = new TextBlock { Text = "4 秒", Width = 45, TextAlignment = TextAlignment.Right, Foreground = new SolidColorBrush(MediaColor.FromRgb(10, 132, 255)), VerticalAlignment = VerticalAlignment.Center };
        _carouselSlider = new Slider { Minimum = 2, Maximum = 15, SmallChange = 1, LargeChange = 2 };
        _carouselSlider.ValueChanged += (_, e) =>
        {
            _carouselValueBlock.Text = $"{e.NewValue:F0} 秒";
            DesktopWidgetWindow.Shared.UpdateCarouselInterval(e.NewValue);
            TrayMenuController.Shared.UpdateCarouselInterval(e.NewValue);
        };
        DockPanel.SetDock(carLabel, Dock.Left);
        DockPanel.SetDock(_carouselValueBlock, Dock.Right);
        carouselDock.Children.Add(carLabel);
        carouselDock.Children.Add(_carouselValueBlock);
        carouselDock.Children.Add(_carouselSlider);
        stack.Children.Add(carouselDock);

        stack.Children.Add(CreateGroupHeader("数据自动刷新频率"));

        _refreshIntervalCombo = new ComboBox
        {
            Height = 32,
            Background = new SolidColorBrush(MediaColor.FromArgb(200, 32, 34, 42)),
            Foreground = MediaBrushes.White,
            BorderBrush = new SolidColorBrush(MediaColor.FromArgb(50, 255, 255, 255)),
            Margin = new Thickness(0, 0, 0, 16)
        };
        _refreshIntervalCombo.Items.Add(new ComboBoxItem { Content = "每 30 秒", Tag = 30.0 });
        _refreshIntervalCombo.Items.Add(new ComboBoxItem { Content = "每 60 秒 (推荐)", Tag = 60.0 });
        _refreshIntervalCombo.Items.Add(new ComboBoxItem { Content = "每 180 秒 (3分钟)", Tag = 180.0 });
        _refreshIntervalCombo.Items.Add(new ComboBoxItem { Content = "每 300 秒 (5分钟)", Tag = 300.0 });
        _refreshIntervalCombo.Items.Add(new ComboBoxItem { Content = "每 600 秒 (10分钟)", Tag = 600.0 });
        stack.Children.Add(_refreshIntervalCombo);

        stack.Children.Add(CreateGroupHeader("功能与隐私选项"));

        _courseTableCheck = CreateStyledCheckBox("启用教务系统课表与考试倒计时集成");
        _courseTableCheck.Margin = new Thickness(0, 0, 0, 8);
        stack.Children.Add(_courseTableCheck);

        _hideScoreNotificationCheck = CreateStyledCheckBox("在系统出分通知及小组件中隐藏成绩具体分数 (防偷窥)");
        _hideScoreNotificationCheck.Margin = new Thickness(0, 0, 0, 8);
        stack.Children.Add(_hideScoreNotificationCheck);

        scroll.Content = stack;
        return scroll;
    }

    private UIElement BuildGeneralTab()
    {
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var stack = new StackPanel { Margin = new Thickness(12, 12, 12, 12) };

        stack.Children.Add(CreateGroupHeader("系统集成"));

        _bootCheck = CreateStyledCheckBox("开机自动启动校园助手");
        _bootCheck.Margin = new Thickness(0, 0, 0, 8);
        stack.Children.Add(_bootCheck);

        _updateCheck = CreateStyledCheckBox("启动时自动检查更新");
        _updateCheck.Margin = new Thickness(0, 0, 0, 16);
        stack.Children.Add(_updateCheck);

        stack.Children.Add(CreateGroupHeader("关于 HFUT CampusNet"));

        var aboutCard = new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(MediaColor.FromArgb(140, 28, 30, 38)),
            Padding = new Thickness(14),
            Margin = new Thickness(0, 0, 0, 16)
        };
        var aboutStack = new StackPanel();

        var appTitle = new TextBlock
        {
            Text = "合工大校园网与生活助手 (Windows 原生版)",
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            Foreground = MediaBrushes.White
        };
        _versionBlock = new TextBlock
        {
            Text = $"当前版本：v{UpdateChecker.Shared.CurrentVersion}",
            FontSize = 12,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(160, 166, 180)),
            Margin = new Thickness(0, 4, 0, 8)
        };
        var desc = new TextBlock
        {
            Text = "基于 .NET 8 与 WPF 原生打造，深度对接合肥工业大学校园网 Portal、统一身份认证 CAS、慧新校园生活服务与新版教务系统 EAMS。\n提供实时网速、免费流量倒计时、宿舍电费、一卡通、周课表与全天空教室推荐。",
            FontSize = 11.5,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(180, 186, 200)),
            TextWrapping = TextWrapping.Wrap,
            LineHeight = 18
        };

        aboutStack.Children.Add(appTitle);
        aboutStack.Children.Add(_versionBlock);
        aboutStack.Children.Add(desc);
        aboutCard.Child = aboutStack;
        stack.Children.Add(aboutCard);

        var actionRow = new StackPanel { Orientation = Orientation.Horizontal };
        var checkUpdateBtn = CreateSecondaryButton("✨ 立即检查新版本", () =>
        {
            UpdateChecker.Shared.CheckForUpdates(manual: true, (rel, err) =>
            {
                AppEvents.InvokeOnUI(() =>
                {
                    if (rel != null)
                        MessageBox.Show(this, $"发现新版本 {rel.Version}！\n\n{rel.Body}", "检查更新", MessageBoxButton.OK, MessageBoxImage.Information);
                    else if (!string.IsNullOrWhiteSpace(err))
                        MessageBox.Show(this, $"检查失败：{err}", "检查更新", MessageBoxButton.OK, MessageBoxImage.Warning);
                    else
                        MessageBox.Show(this, "当前已是最新版本！", "检查更新", MessageBoxButton.OK, MessageBoxImage.Information);
                });
            });
        });

        var githubBtn = CreateSecondaryButton("🌐 访问开源项目主页", () =>
        {
            try
            {
                Process.Start(new ProcessStartInfo("https://github.com/hfut-community/HFUTCampusNet") { UseShellExecute = true });
            }
            catch { }
        });
        githubBtn.Margin = new Thickness(10, 0, 0, 0);

        actionRow.Children.Add(checkUpdateBtn);
        actionRow.Children.Add(githubBtn);
        stack.Children.Add(actionRow);

        scroll.Content = stack;
        return scroll;
    }

    private void LoadSettings()
    {
        var s = SettingsManager.Shared;

        _portalUsernameBox.Text = s.PortalUsername;
        _portalPasswordBox.Password = s.PortalPassword;
        _casPasswordBox.Password = s.CasPassword;
        _autoLoginCheck.IsChecked = s.AutoLoginPortal;

        // Dorm
        foreach (ComboBoxItem item in _campusCombo.Items)
        {
            if (item.Tag?.ToString() == s.DormCampus)
            {
                _campusCombo.SelectedItem = item;
                break;
            }
        }
        if (_campusCombo.SelectedItem == null && _campusCombo.Items.Count > 0)
            _campusCombo.SelectedIndex = 0;

        _buildingBox.Text = s.DormBuilding;
        _roomBox.Text = s.DormRoom;
        _endNumberBox.Text = s.DormEndNumber;
        _roomNameBox.Text = s.DormRoomName;
        _elecThresholdBox.Text = s.ElectricityLowWarningThreshold.ToString("F1", CultureInfo.InvariantCulture);
        _cardThresholdBox.Text = s.CampusCardLowWarningThreshold.ToString("F1", CultureInfo.InvariantCulture);
        _cardBudgetBox.Text = s.CampusCardDailyBudget.ToString("F1", CultureInfo.InvariantCulture);

        // Widget
        _showWidgetCheck.IsChecked = s.ShowDesktopWidget;
        _pinWidgetCheck.IsChecked = s.WidgetPinToDesktop;
        _opacitySlider.Value = Math.Clamp(s.WidgetOpacity * 100.0, 30.0, 100.0);
        _carouselSlider.Value = Math.Clamp(s.CarouselInterval, 2.0, 15.0);

        foreach (ComboBoxItem item in _refreshIntervalCombo.Items)
        {
            if (item.Tag is double val && Math.Abs(val - s.RefreshInterval) < 1.0)
            {
                _refreshIntervalCombo.SelectedItem = item;
                break;
            }
        }
        if (_refreshIntervalCombo.SelectedItem == null && _refreshIntervalCombo.Items.Count > 1)
            _refreshIntervalCombo.SelectedIndex = 1;

        _courseTableCheck.IsChecked = s.CourseTableEnabled;
        _hideScoreNotificationCheck.IsChecked = s.HideScoreInNotification;

        // General
        _bootCheck.IsChecked = s.AutoStartOnBoot;
        _updateCheck.IsChecked = s.AutoCheckUpdate;
        _versionBlock.Text = $"当前版本：v{UpdateChecker.Shared.CurrentVersion}";

        UpdateCookieStatusLabel();
    }

    private void SaveSettings()
    {
        var s = SettingsManager.Shared;

        s.PortalUsername = _portalUsernameBox.Text.Trim();
        s.PortalPassword = _portalPasswordBox.Password;
        s.CasPassword = _casPasswordBox.Password;
        s.AutoLoginPortal = _autoLoginCheck.IsChecked == true;

        if (_campusCombo.SelectedItem is ComboBoxItem cItem && cItem.Tag != null)
            s.DormCampus = cItem.Tag.ToString()!;

        s.DormBuilding = _buildingBox.Text.Trim();
        s.DormRoom = _roomBox.Text.Trim();
        s.DormEndNumber = _endNumberBox.Text.Trim();
        s.DormRoomName = _roomNameBox.Text.Trim();

        if (double.TryParse(_elecThresholdBox.Text, NumberStyles.Any, CultureInfo.InvariantCulture, out double elecTh))
            s.ElectricityLowWarningThreshold = elecTh;

        if (double.TryParse(_cardThresholdBox.Text, NumberStyles.Any, CultureInfo.InvariantCulture, out double cardTh))
            s.CampusCardLowWarningThreshold = cardTh;

        if (double.TryParse(_cardBudgetBox.Text, NumberStyles.Any, CultureInfo.InvariantCulture, out double budget))
            s.CampusCardDailyBudget = budget;

        s.ShowDesktopWidget = _showWidgetCheck.IsChecked == true;
        s.WidgetPinToDesktop = _pinWidgetCheck.IsChecked == true;
        s.WidgetOpacity = _opacitySlider.Value / 100.0;
        s.CarouselInterval = _carouselSlider.Value;

        if (_refreshIntervalCombo.SelectedItem is ComboBoxItem rItem && rItem.Tag is double sec)
        {
            s.RefreshInterval = sec;
            CampusNetworkClient.Shared.UpdateInterval(sec);
        }

        s.CourseTableEnabled = _courseTableCheck.IsChecked == true;
        s.HideScoreInNotification = _hideScoreNotificationCheck.IsChecked == true;
        s.AutoStartOnBoot = _bootCheck.IsChecked == true;
        s.AutoCheckUpdate = _updateCheck.IsChecked == true;

        s.Save();
    }

    private void UpdateCookieStatusLabel()
    {
        var s = SettingsManager.Shared;
        bool hasTgc = !string.IsNullOrWhiteSpace(s.CasTgcCookie);
        bool hasHuixin = !string.IsNullOrWhiteSpace(s.HuixinAuthToken);
        bool hasNetSession = !string.IsNullOrWhiteSpace(s.SessionCookie);
        bool hasCourse = !string.IsNullOrWhiteSpace(s.CourseSessionCookie);

        string tgcTag = hasTgc ? "✅ CAS TGC 有效" : "❌ CAS 未认证";
        string hxTag = hasHuixin ? "✅ 慧新 Token 有效" : "❌ 慧新未绑定";
        string netTag = hasNetSession ? "✅ 自助服务 Session 正常" : "⚠️ 自助未同步";
        string crsTag = hasCourse ? "✅ 教务 Cookie 正常" : "⚠️ 教务未同步";

        _cookieStatusBlock.Text = $"{tgcTag} · {hxTag}\n{netTag} · {crsTag}";
    }

    #region Helpers

    private static TextBlock CreateGroupHeader(string title)
    {
        return new TextBlock
        {
            Text = title,
            FontSize = 13,
            FontWeight = FontWeights.Bold,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(10, 132, 255)),
            Margin = new Thickness(0, 12, 0, 8)
        };
    }

    private static UIElement CreateFormField(string labelText, UIElement inputControl, string hintText)
    {
        var panel = new StackPanel { Margin = new Thickness(0, 0, 0, 8) };
        var label = new TextBlock
        {
            Text = labelText,
            FontSize = 12,
            FontWeight = FontWeights.Medium,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(220, 224, 235)),
            Margin = new Thickness(0, 0, 0, 4)
        };
        panel.Children.Add(label);
        panel.Children.Add(inputControl);

        if (!string.IsNullOrWhiteSpace(hintText))
        {
            var hint = new TextBlock
            {
                Text = hintText,
                FontSize = 11,
                Foreground = new SolidColorBrush(MediaColor.FromRgb(140, 146, 160)),
                Margin = new Thickness(0, 2, 0, 0)
            };
            panel.Children.Add(hint);
        }

        return panel;
    }

    private static TextBox CreateStyledTextBox()
    {
        return new TextBox
        {
            Height = 30,
            Background = new SolidColorBrush(MediaColor.FromArgb(200, 32, 34, 42)),
            Foreground = MediaBrushes.White,
            BorderBrush = new SolidColorBrush(MediaColor.FromArgb(50, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(6, 4, 6, 4),
            VerticalContentAlignment = VerticalAlignment.Center
        };
    }

    private static PasswordBox CreateStyledPasswordBox()
    {
        return new PasswordBox
        {
            Height = 30,
            Background = new SolidColorBrush(MediaColor.FromArgb(200, 32, 34, 42)),
            Foreground = MediaBrushes.White,
            BorderBrush = new SolidColorBrush(MediaColor.FromArgb(50, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(6, 4, 6, 4),
            VerticalContentAlignment = VerticalAlignment.Center
        };
    }

    private static CheckBox CreateStyledCheckBox(string content)
    {
        return new CheckBox
        {
            Content = content,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(220, 224, 235)),
            FontSize = 12,
            VerticalContentAlignment = VerticalAlignment.Center
        };
    }

    private static Button CreatePrimaryButton(string content, Action onClick)
    {
        var btn = new Button
        {
            Content = content,
            Background = new SolidColorBrush(MediaColor.FromRgb(10, 132, 255)),
            Foreground = MediaBrushes.White,
            BorderThickness = new Thickness(0),
            FontWeight = FontWeights.SemiBold,
            FontSize = 12.5,
            Padding = new Thickness(16, 7, 16, 7),
            Cursor = Cursors.Hand
        };
        btn.Click += (_, _) => onClick();
        return btn;
    }

    private static Button CreateSecondaryButton(string content, Action onClick)
    {
        var btn = new Button
        {
            Content = content,
            Background = new SolidColorBrush(MediaColor.FromArgb(220, 42, 45, 56)),
            Foreground = new SolidColorBrush(MediaColor.FromRgb(230, 234, 245)),
            BorderBrush = new SolidColorBrush(MediaColor.FromArgb(60, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            FontSize = 12,
            Padding = new Thickness(12, 6, 12, 6),
            Cursor = Cursors.Hand
        };
        btn.Click += (_, _) => onClick();
        return btn;
    }

    #endregion
}

#endregion

#region Unified Login (CAS SSO) WebView2 Window

/// <summary>
/// 1:1 Windows WPF Port of UnifiedLoginWebViewController.swift.
/// Uses Microsoft.Web.WebView2 to render CAS login (https://cas.hfut.edu.cn/cas/login),
/// automatically injects saved student ID and password, captures CASTGC cookie,
/// follows redirect chains to extract HuiXin Token, UniApp JWT, and triggers full background sync.
/// </summary>
public class UnifiedLoginWebWindow : Window
{
    private static UnifiedLoginWebWindow? _shared;
    public static UnifiedLoginWebWindow Shared => _shared ??= new UnifiedLoginWebWindow();

    private readonly WebView2 _webView;
    private readonly TextBlock _statusText;
    private readonly ProgressBar _progressBar;
    private bool _hasInterceptedAuth;

    public UnifiedLoginWebWindow()
    {
        Title = "统一身份认证登录 - 合工大校园助手";
        Width = 500;
        Height = 650;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(MediaColor.FromRgb(22, 24, 30));

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // Header/status bar
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); // WebView2

        var topBar = new Border
        {
            Background = new SolidColorBrush(MediaColor.FromArgb(220, 28, 30, 38)),
            Padding = new Thickness(14, 10, 14, 10),
            BorderBrush = new SolidColorBrush(MediaColor.FromArgb(40, 255, 255, 255)),
            BorderThickness = new Thickness(0, 0, 0, 1)
        };
        var topStack = new StackPanel();

        _statusText = new TextBlock
        {
            Text = "正在加载统一身份认证页面...",
            FontSize = 12,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(180, 186, 200)),
            Margin = new Thickness(0, 0, 0, 6)
        };
        _progressBar = new ProgressBar
        {
            Height = 3,
            IsIndeterminate = true,
            Background = MediaBrushes.Transparent,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(10, 132, 255))
        };
        topStack.Children.Add(_statusText);
        topStack.Children.Add(_progressBar);
        topBar.Child = topStack;
        Grid.SetRow(topBar, 0);
        root.Children.Add(topBar);

        _webView = new WebView2();
        Grid.SetRow(_webView, 1);
        root.Children.Add(_webView);

        Content = root;

        Closing += (_, e) =>
        {
            e.Cancel = true;
            Hide();
        };

        InitWebView();
    }

    public void ShowLoginWindow(string serviceName = "统一身份认证", string? targetUrl = null, Action<bool, string>? callback = null)
    {
        Title = $"{serviceName} - 合工大校园助手";
        _statusText.Text = $"正在加载 {serviceName}...";
        Show();
        Activate();
        if (!string.IsNullOrEmpty(targetUrl) && _webView.CoreWebView2 != null)
        {
            _webView.CoreWebView2.Navigate(targetUrl);
        }
    }

    private async void InitWebView()
    {
        try
        {
            string userDataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HFUTCampusNet", "WebView2_SSO");
            var env = await CoreWebView2Environment.CreateAsync(null, userDataDir);
            await _webView.EnsureCoreWebView2Async(env);

            _webView.CoreWebView2.NavigationStarting += OnNavigationStarting;
            _webView.CoreWebView2.NavigationCompleted += OnNavigationCompleted;
        }
        catch (Exception ex)
        {
            _statusText.Text = $"WebView2 初始化失败: {ex.Message}";
            _progressBar.Visibility = Visibility.Collapsed;
        }
    }

    public async void ShowWindow()
    {
        _hasInterceptedAuth = false;
        _progressBar.Visibility = Visibility.Visible;
        _statusText.Text = "正在打开统一身份认证登录页...";

        if (WindowState == WindowState.Minimized)
            WindowState = WindowState.Normal;
        Show();
        Activate();

        await _webView.EnsureCoreWebView2Async();
        _webView.CoreWebView2.Navigate("https://cas.hfut.edu.cn/cas/login?service=https%3A%2F%2Fcas.hfut.edu.cn%2Fcas%2Flogin");
    }

    private void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs e)
    {
        _statusText.Text = $"正在跳转: {e.Uri}";
        _progressBar.Visibility = Visibility.Visible;
    }

    private async void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        _progressBar.Visibility = Visibility.Collapsed;
        if (!e.IsSuccess)
        {
            _statusText.Text = "加载页面失败，请检查网络连接";
            return;
        }

        string currentUrl = _webView.Source?.ToString() ?? "";
        _statusText.Text = "页面已就绪";

        // Auto-fill credentials if on login form
        if (currentUrl.Contains("cas.hfut.edu.cn/cas/login"))
        {
            string username = SettingsManager.Shared.PortalUsername;
            string password = !string.IsNullOrWhiteSpace(SettingsManager.Shared.CasPassword)
                ? SettingsManager.Shared.CasPassword
                : SettingsManager.Shared.PortalPassword;

            if (!string.IsNullOrWhiteSpace(username) && !string.IsNullOrWhiteSpace(password))
            {
                string script = $@"
                    (function() {{
                        var u = document.getElementById('username') || document.querySelector('input[name=""username""]');
                        var p = document.getElementById('password') || document.querySelector('input[name=""password""]');
                        if (u && !u.value) {{
                            u.value = '{EscapeJs(username)}';
                            u.dispatchEvent(new Event('input', {{ bubbles: true }}));
                        }}
                        if (p && !p.value) {{
                            p.value = '{EscapeJs(password)}';
                            p.dispatchEvent(new Event('input', {{ bubbles: true }}));
                        }}
                    }})();";
                await _webView.ExecuteScriptAsync(script);
            }
        }

        // Check cookies for CASTGC
        if (!_hasInterceptedAuth && _webView.CoreWebView2 != null)
        {
            var cookieList = await _webView.CoreWebView2.CookieManager.GetCookiesAsync("https://cas.hfut.edu.cn");
            var tgcCookie = cookieList.FirstOrDefault(c => c.Name.Equals("CASTGC", StringComparison.OrdinalIgnoreCase));
            if (tgcCookie != null && !string.IsNullOrWhiteSpace(tgcCookie.Value))
            {
                _hasInterceptedAuth = true;
                SettingsManager.Shared.CasTgcCookie = tgcCookie.Value;
                SettingsManager.Shared.Save();

                _statusText.Text = "✅ 已捕获统一认证凭证 (CASTGC)！正在换取慧新生活与教务授权...";

                // Background exchange
                _ = Task.Run(async () =>
                {
                    try
                    {
                        await ElectricityService.Shared.ObtainHuiXinTokenAsync();
                        ElectricityService.Shared.FetchData();
                        CampusCardService.Shared.FetchData();
                        AcademicService.Shared.SyncAll(silent: false);
                        CourseScheduleService.Shared.TryBackgroundLogin();
                    }
                    catch { }

                    AppEvents.InvokeOnUI(() =>
                    {
                        _statusText.Text = "🎉 统一身份认证同步成功！凭证已更新。";
                        TrayMenuController.Shared.ShowNotification("统一身份认证成功", "一卡通、宿舍电费及教务系统凭证已全量更新。");
                        Task.Delay(1200).ContinueWith(_ => AppEvents.InvokeOnUI(Hide));
                    });
                });
            }
        }
    }

    private static string EscapeJs(string s) => s.Replace("\\", "\\\\").Replace("'", "\\'").Replace("\n", "");
}

#endregion

#region Self-Service Login Web Window

/// <summary>
/// 1:1 Windows WPF Port of LoginWebViewController.swift.
/// Opens self-service portal (http://172.18.2.2/ or http://172.18.3.3/),
/// grabs JSESSIONID cookie and HTML dashboard content, passes to CampusNetworkClient.
/// </summary>
public class LoginWebWindow : Window
{
    private static LoginWebWindow? _shared;
    public static LoginWebWindow Shared => _shared ??= new LoginWebWindow();

    private readonly WebView2 _webView;
    private readonly TextBlock _statusText;

    public LoginWebWindow()
    {
        Title = "校园网自助服务 - 合工大校园助手";
        Width = 800;
        Height = 600;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(MediaColor.FromRgb(22, 24, 30));

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var topBar = new Border
        {
            Background = new SolidColorBrush(MediaColor.FromArgb(220, 28, 30, 38)),
            Padding = new Thickness(14, 8, 14, 8),
            BorderBrush = new SolidColorBrush(MediaColor.FromArgb(40, 255, 255, 255)),
            BorderThickness = new Thickness(0, 0, 0, 1)
        };
        _statusText = new TextBlock
        {
            Text = "正在打开校园网自助服务系统...",
            FontSize = 12,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(180, 186, 200))
        };
        topBar.Child = _statusText;
        Grid.SetRow(topBar, 0);
        root.Children.Add(topBar);

        _webView = new WebView2();
        Grid.SetRow(_webView, 1);
        root.Children.Add(_webView);

        Content = root;

        Closing += (_, e) =>
        {
            e.Cancel = true;
            Hide();
        };

        InitWebView();
    }

    private async void InitWebView()
    {
        try
        {
            string userDataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HFUTCampusNet", "WebView2_SelfService");
            var env = await CoreWebView2Environment.CreateAsync(null, userDataDir);
            await _webView.EnsureCoreWebView2Async(env);
            _webView.CoreWebView2.NavigationCompleted += OnNavigationCompleted;
        }
        catch (Exception ex)
        {
            _statusText.Text = $"WebView2 初始化失败: {ex.Message}";
        }
    }

    public async void ShowWindow()
    {
        if (WindowState == WindowState.Minimized)
            WindowState = WindowState.Normal;
        Show();
        Activate();

        await _webView.EnsureCoreWebView2Async();
        _webView.CoreWebView2.Navigate("http://172.18.2.2/");
    }

    private async void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (!e.IsSuccess) return;

        string currentUrl = _webView.Source?.ToString() ?? "";
        _statusText.Text = $"当前页面: {currentUrl}";

        if (_webView.CoreWebView2 != null)
        {
            var cookies = await _webView.CoreWebView2.CookieManager.GetCookiesAsync(currentUrl);
            var jsession = cookies.FirstOrDefault(c => c.Name.Equals("JSESSIONID", StringComparison.OrdinalIgnoreCase));
            if (jsession != null && !string.IsNullOrWhiteSpace(jsession.Value))
            {
                SettingsManager.Shared.SessionCookie = $"JSESSIONID={jsession.Value}";
                SettingsManager.Shared.Save();
            }

            string html = await _webView.ExecuteScriptAsync("document.documentElement.outerHTML");
            if (!string.IsNullOrWhiteSpace(html) && html.Length > 20)
            {
                // ExecuteScriptAsync returns JSON string
                string decoded = Regex.Unescape(html.Trim('"'));
                CampusNetworkClient.Shared.ApplyParsedDashboardHTML(decoded);
                _statusText.Text = "✅ 成功提取流量与在线终端数据！";
            }
        }
    }
}

#endregion

#region Course Schedule Login Web Window

/// <summary>
/// 1:1 Windows WPF Port of CourseLoginWebViewController.swift.
/// Loads the EAMS Course Schedule page (https://jxglstu.hfut.edu.cn/eams/courseTableForStd.action),
/// intercepts authentication cookies, fetches HTML/JSON datum, and feeds CourseScheduleService.
/// </summary>
public class CourseLoginWebWindow : Window
{
    private static CourseLoginWebWindow? _shared;
    public static CourseLoginWebWindow Shared => _shared ??= new CourseLoginWebWindow();

    private readonly WebView2 _webView;
    private readonly TextBlock _statusText;

    public CourseLoginWebWindow()
    {
        Title = "教务课表同步登录 - 合工大校园助手";
        Width = 850;
        Height = 650;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(MediaColor.FromRgb(22, 24, 30));

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var topBar = new Border
        {
            Background = new SolidColorBrush(MediaColor.FromArgb(220, 28, 30, 38)),
            Padding = new Thickness(14, 8, 14, 8),
            BorderBrush = new SolidColorBrush(MediaColor.FromArgb(40, 255, 255, 255)),
            BorderThickness = new Thickness(0, 0, 0, 1)
        };
        _statusText = new TextBlock
        {
            Text = "正在打开新版教务系统课表页面...",
            FontSize = 12,
            Foreground = new SolidColorBrush(MediaColor.FromRgb(180, 186, 200))
        };
        topBar.Child = _statusText;
        Grid.SetRow(topBar, 0);
        root.Children.Add(topBar);

        _webView = new WebView2();
        Grid.SetRow(_webView, 1);
        root.Children.Add(_webView);

        Content = root;

        Closing += (_, e) =>
        {
            e.Cancel = true;
            Hide();
        };

        InitWebView();
    }

    private async void InitWebView()
    {
        try
        {
            string userDataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HFUTCampusNet", "WebView2_Course");
            var env = await CoreWebView2Environment.CreateAsync(null, userDataDir);
            await _webView.EnsureCoreWebView2Async(env);
            _webView.CoreWebView2.NavigationCompleted += OnNavigationCompleted;
        }
        catch (Exception ex)
        {
            _statusText.Text = $"WebView2 初始化失败: {ex.Message}";
        }
    }

    public async void ShowWindow()
    {
        if (WindowState == WindowState.Minimized)
            WindowState = WindowState.Normal;
        Show();
        Activate();

        await _webView.EnsureCoreWebView2Async();
        _webView.CoreWebView2.Navigate("https://jxglstu.hfut.edu.cn/eams/courseTableForStd.action");
    }

    public void ShowLoginWindow() => ShowWindow();

    private async void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (!e.IsSuccess) return;

        string currentUrl = _webView.Source?.ToString() ?? "";
        _statusText.Text = $"正在解析教务数据...";

        if (_webView.CoreWebView2 != null)
        {
            var cookies = await _webView.CoreWebView2.CookieManager.GetCookiesAsync("https://jxglstu.hfut.edu.cn");
            var cookieHeader = string.Join("; ", cookies.Select(c => $"{c.Name}={c.Value}"));
            if (!string.IsNullOrWhiteSpace(cookieHeader))
            {
                SettingsManager.Shared.CourseSessionCookie = cookieHeader;
                SettingsManager.Shared.Save();
            }

            string html = await _webView.ExecuteScriptAsync("document.documentElement.outerHTML");
            if (!string.IsNullOrWhiteSpace(html) && html.Length > 20)
            {
                string decoded = Regex.Unescape(html.Trim('"'));
                CourseScheduleService.Shared.FetchAndApplyFromHTML(decoded);
                _statusText.Text = "✅ 教务课表已成功解析并同步！";
                Task.Delay(1000).ContinueWith(_ => AppEvents.InvokeOnUI(Hide));
            }
        }
    }
}

#endregion
