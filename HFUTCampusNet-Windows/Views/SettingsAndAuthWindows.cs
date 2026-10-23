using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
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
    private string _loadedPortalUsername = string.Empty;
    private bool _portalPasswordEditedSinceUsernameChange;
    private bool _casPasswordEditedSinceUsernameChange;
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
    private bool _hasLoadedSettings;

    public SettingsWindow()
    {
        Title = "偏好设置 - 合工大校园助手";
        Width = 560;
        Height = 630;
        MinWidth = 520;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = ThemeManager.Shared.WindowBackground;
        Foreground = ThemeManager.Shared.TextPrimary;
        ResizeMode = ResizeMode.CanResize;

        Content = BuildContent();

        ThemeManager.Shared.ApplyWindowTheme(this);
        ThemeManager.Shared.ThemeChanged += () => AppEvents.InvokeOnUI(() =>
        {
            if (_hasLoadedSettings)
                SaveSettings();

            Content = BuildContent();
            Background = ThemeManager.Shared.WindowBackground;
            Foreground = ThemeManager.Shared.TextPrimary;
            ThemeManager.Shared.ApplyWindowTheme(this);
            if (_hasLoadedSettings)
                LoadSettings();
        });

        Closing += (_, e) =>
        {
            e.Cancel = true;
            SaveSettings();
            Hide();
        };

        Loaded += (_, _) => LoadSettings();
        Activated += (_, _) => UpdateCookieStatusLabel();
        AppEvents.AuthStatusUpdated += () => AppEvents.InvokeOnUI(UpdateCookieStatusLabel);
    }

    public void ShowWindow()
    {
        ThemeManager.Shared.ApplyWindowTheme(this);
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
            Background = ThemeManager.Shared.TopBarBackground,
            Padding = new Thickness(24, 18, 24, 16),
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(0, 0, 0, 1)
        };
        var headerStack = new StackPanel();
        var headerTitle = new TextBlock
        {
            Text = "⚙️ 偏好设置",
            FontSize = 18,
            FontWeight = FontWeights.Bold,
            Foreground = ThemeManager.Shared.TextPrimary
        };
        var headerSub = new TextBlock
        {
            Text = "配置校园网认证、宿舍电费、一卡通、课表以及桌面小组件参数",
            FontSize = 12,
            Foreground = ThemeManager.Shared.TextSecondary,
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
        ApplyDarkTabControlStyle(tabControl);

        tabControl.Items.Add(new TabItem { Header = "🌐 网络与认证", Content = BuildNetTab() });
        tabControl.Items.Add(new TabItem { Header = "⚡ 宿舍与生活", Content = BuildDormTab() });
        tabControl.Items.Add(new TabItem { Header = "🖥️ 小组件与外观", Content = BuildAppearanceTab() });
        tabControl.Items.Add(new TabItem { Header = "⚙️ 通用与关于", Content = BuildGeneralTab() });

        ThemeManager.Shared.ApplyComboBoxTheme(_campusCombo);
        ThemeManager.Shared.ApplyComboBoxTheme(_refreshIntervalCombo);

        Grid.SetRow(tabControl, 1);
        mainGrid.Children.Add(tabControl);

        // Footer buttons
        var footer = new Border
        {
            Background = ThemeManager.Shared.TopBarBackground,
            Padding = new Thickness(20, 12, 20, 14),
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(0, 1, 0, 0)
        };
        var footerPanel = new DockPanel();
        var statusHint = new TextBlock
        {
            Text = "设置已自动保存，更改将实时生效",
            FontSize = 11.5,
            Foreground = ThemeManager.Shared.TextMuted,
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
        _portalUsernameBox.LostFocus += (_, _) => SaveSettings();
        _portalUsernameBox.TextChanged += (_, _) =>
        {
            _portalPasswordEditedSinceUsernameChange = false;
            _casPasswordEditedSinceUsernameChange = false;
        };
        stack.Children.Add(CreateFormField("学号 / 工号：", _portalUsernameBox, "用于校园网出校网页认证"));

        _portalPasswordBox = CreateStyledPasswordBox();
        _portalPasswordBox.LostFocus += (_, _) => SaveSettings();
        _portalPasswordBox.PasswordChanged += (_, _) => _portalPasswordEditedSinceUsernameChange = true;
        stack.Children.Add(CreateFormField("Portal 认证密码：", _portalPasswordBox, "校园网开户密码"));

        _autoLoginCheck = CreateStyledCheckBox("网络离线或断开时自动登录校园网 (Auto-Login)");
        _autoLoginCheck.Margin = new Thickness(0, 4, 0, 10);
        stack.Children.Add(_autoLoginCheck);

        // Group 2: CAS SSO Login
        stack.Children.Add(CreateGroupHeader("统一身份认证 (CAS SSO 账户)"));

        _casPasswordBox = CreateStyledPasswordBox();
        _casPasswordBox.LostFocus += (_, _) => SaveSettings();
        _casPasswordBox.PasswordChanged += (_, _) => _casPasswordEditedSinceUsernameChange = true;
        stack.Children.Add(CreateFormField("CAS 统一认证密码：", _casPasswordBox, "用于一卡通、宿舍电费、教务课表及成绩查询"));

        var ssoRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 12) };
        var ssoBtn = CreateSecondaryButton("🔐 统一身份认证网页快速登录...", () =>
        {
            SaveSettings();
            UnifiedLoginWebWindow.Shared.ShowWindow();
        });
        var testNetBtn = CreateSecondaryButton("⚡ 一键测试 Portal 登录", () =>
        {
            SaveSettings();
            var accountGeneration = AccountSessionManager.Generation;
            CampusNetworkClient.Shared.ClearManualLogout();
            PortalAuthService.Shared.Login(_portalUsernameBox.Text, _portalPasswordBox.Password, (ok, msg) =>
            {
                AppEvents.InvokeOnUI(() =>
                {
                    MessageBox.Show(this, ok ? "校园网认证成功！" : $"认证失败：{msg}", "校园网测试", MessageBoxButton.OK,
                        ok ? MessageBoxImage.Information : MessageBoxImage.Warning);
                });
            }, expectedAccountGeneration: accountGeneration);
        });
        testNetBtn.Margin = new Thickness(10, 0, 0, 0);
        ssoRow.Children.Add(ssoBtn);
        ssoRow.Children.Add(testNetBtn);
        stack.Children.Add(ssoRow);

        // Group 3: Auxiliary Cookie status & extraction
        stack.Children.Add(CreateGroupHeader("会话凭证状态与校园服务授权"));

        var statusCard = new Border
        {
            CornerRadius = new CornerRadius(6),
            Background = ThemeManager.Shared.CardBackground,
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(1),
            Padding = new Thickness(12, 10, 12, 10),
            Margin = new Thickness(0, 2, 0, 10)
        };

        _cookieStatusBlock = new TextBlock
        {
            Text = "正在检测当前凭据状态...",
            FontSize = 11.5,
            Foreground = ThemeManager.Shared.TextSecondary,
            TextWrapping = TextWrapping.Wrap,
            LineHeight = 20
        };
        statusCard.Child = _cookieStatusBlock;
        stack.Children.Add(statusCard);

        var actionRow1 = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
        var bindHuixinBtn = CreateSecondaryButton("⚡ 一键绑定慧新生活 (电费/一卡通)", () =>
        {
            SaveSettings();
            var accountGeneration = AccountSessionManager.Generation;
            _cookieStatusBlock.Text = "⏳ 正在通过保存的学号与密码请求慧新生活授权 Token...";
            ElectricityService.Shared.ObtainHuiXinToken((token, err) =>
            {
                AppEvents.InvokeOnUI(() =>
                {
                    if (!string.IsNullOrWhiteSpace(token))
                    {
                        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                        {
                            SettingsManager.Shared.HuixinAuthToken = token;
                            SettingsManager.Shared.Save();
                        })) return;
                        ElectricityService.Shared.FetchData();
                        CampusCardService.Shared.FetchData();
                        AppEvents.RaiseAuthStatusUpdated();
                        MessageBox.Show(this, "🎉 慧新易校生活授权成功！宿舍电费与一卡通数据已自动更新。", "授权成功", MessageBoxButton.OK, MessageBoxImage.Information);
                    }
                    else
                    {
                        UpdateCookieStatusLabel();
                        MessageBox.Show(this, $"慧新生活授权失败：{err ?? "请核对学号与密码"}", "授权提示", MessageBoxButton.OK, MessageBoxImage.Warning);
                    }
                });
            }, accountGeneration);
        });

        var refreshStatusBtn = CreateSecondaryButton("🔄 刷新凭证状态", () =>
        {
            UpdateCookieStatusLabel();
        });
        refreshStatusBtn.Margin = new Thickness(10, 0, 0, 0);

        actionRow1.Children.Add(bindHuixinBtn);
        actionRow1.Children.Add(refreshStatusBtn);
        stack.Children.Add(actionRow1);

        var actionRow2 = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 10) };
        var selfServiceBtn = CreateSecondaryButton("🌐 自助服务登录 (提取流量)", () =>
        {
            SaveSettings();
            LoginWebWindow.Shared.ShowWindow();
        });
        var courseLoginBtn = CreateSecondaryButton("📚 教务系统登录 (提取课表)", () =>
        {
            SaveSettings();
            CourseLoginWebWindow.Shared.ShowWindow();
        });
        courseLoginBtn.Margin = new Thickness(10, 0, 0, 0);

        var clearCredsBtn = CreateSecondaryButton("🗑️ 清除所有凭证缓存", () =>
        {
            if (MessageBox.Show(this, "确定要清除所有保存的 Cookie、Token 及课表缓存吗？", "清除凭证", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
            {
                ElectricityService.Shared.CancelPendingRequests();
                EmptyClassroomService.Shared.CancelPendingAuthentication();
                CourseScheduleService.Shared.ClearSchedule(clearCourseCredentials: true);
                SettingsManager.Shared.SessionCookie = "";
                SettingsManager.Shared.HuixinAuthToken = "";
                SettingsManager.Shared.UniAppJwt = "";
                SettingsManager.Shared.Save();
                AcademicService.Shared.ClearCache();
                CampusCardService.Shared.ClearCache();
                UpdateCookieStatusLabel();
                AppEvents.RaiseAuthStatusUpdated();
            }
        });
        clearCredsBtn.Margin = new Thickness(10, 0, 0, 0);

        actionRow2.Children.Add(selfServiceBtn);
        actionRow2.Children.Add(courseLoginBtn);
        actionRow2.Children.Add(clearCredsBtn);
        stack.Children.Add(actionRow2);

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
            Background = ThemeManager.Shared.ControlBackground,
            Foreground = ThemeManager.Shared.TextPrimary,
            BorderBrush = ThemeManager.Shared.ControlBorderBrush,
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
        var opLabel = new TextBlock { Text = "小组件不透明度：", Width = 150, Foreground = ThemeManager.Shared.TextPrimary, VerticalAlignment = VerticalAlignment.Center };
        _opacityValueBlock = new TextBlock { Text = "100%", Width = 45, TextAlignment = TextAlignment.Right, Foreground = ThemeManager.Shared.Accent, VerticalAlignment = VerticalAlignment.Center };
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
        var carLabel = new TextBlock { Text = "底部栏轮播切换周期：", Width = 150, Foreground = ThemeManager.Shared.TextPrimary, VerticalAlignment = VerticalAlignment.Center };
        _carouselValueBlock = new TextBlock { Text = "4 秒", Width = 45, TextAlignment = TextAlignment.Right, Foreground = ThemeManager.Shared.Accent, VerticalAlignment = VerticalAlignment.Center };
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
            Background = ThemeManager.Shared.ControlBackground,
            Foreground = ThemeManager.Shared.TextPrimary,
            BorderBrush = ThemeManager.Shared.ControlBorderBrush,
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
            Background = ThemeManager.Shared.CardBackground,
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(1),
            Padding = new Thickness(14),
            Margin = new Thickness(0, 0, 0, 16)
        };
        var aboutStack = new StackPanel();

        var appTitle = new TextBlock
        {
            Text = "合工大校园网与生活助手 (Windows 原生版)",
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeManager.Shared.TextPrimary
        };
        _versionBlock = new TextBlock
        {
            Text = $"当前版本：v{UpdateChecker.Shared.CurrentVersion}",
            FontSize = 12,
            Foreground = ThemeManager.Shared.TextSecondary,
            Margin = new Thickness(0, 4, 0, 8)
        };
        var desc = new TextBlock
        {
            Text = "基于 .NET 8 与 WPF 原生打造，深度对接合肥工业大学校园网 Portal、统一身份认证 CAS、慧新校园生活服务与新版教务系统 EAMS。\n提供实时网速、免费流量倒计时、宿舍电费、一卡通、周课表与全天空教室推荐。",
            FontSize = 11.5,
            Foreground = ThemeManager.Shared.TextSecondary,
            TextWrapping = TextWrapping.Wrap,
            LineHeight = 18
        };

        var ackTitle = new TextBlock
        {
            Text = "🙏 特别鸣谢参考的开源项目：",
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeManager.Shared.TextPrimary,
            Margin = new Thickness(0, 12, 0, 4)
        };
        var ackDesc = new TextBlock
        {
            Text = "• Chiu-xaH/HFUT-Schedule (聚在工大) — 教务系统、统一认证 CAS 与慧新易校生活服务协议参考\n• elonzh/hfut — 合肥工业大学教务系统 (EAMS) 交互开发库参考\n• drcom-generic 与工大校园网认证工具 — Dr.COM 网关协议与断线重连参考",
            FontSize = 11,
            Foreground = ThemeManager.Shared.TextSecondary,
            TextWrapping = TextWrapping.Wrap,
            LineHeight = 17
        };

        aboutStack.Children.Add(appTitle);
        aboutStack.Children.Add(_versionBlock);
        aboutStack.Children.Add(desc);
        aboutStack.Children.Add(ackTitle);
        aboutStack.Children.Add(ackDesc);
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
                Process.Start(new ProcessStartInfo("https://github.com/Junpgle/HFUTCampusNet") { UseShellExecute = true });
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
        _loadedPortalUsername = (s.PortalUsername ?? string.Empty).Trim();
        _portalPasswordEditedSinceUsernameChange = false;
        _casPasswordEditedSinceUsernameChange = false;
        _hasLoadedSettings = true;
    }

    private void SaveSettings()
    {
        var s = SettingsManager.Shared;
        var previousPortalUsername = (s.PortalUsername ?? string.Empty).Trim();
        var nextPortalUsername = _portalUsernameBox.Text.Trim();

        // A CAS login can switch accounts while this settings window is still open.
        // If its username field was untouched, refresh the stale credentials instead of
        // switching the saved account back when a later LostFocus/close saves settings.
        if (!string.Equals(previousPortalUsername, _loadedPortalUsername, StringComparison.Ordinal) &&
            string.Equals(nextPortalUsername, _loadedPortalUsername, StringComparison.Ordinal))
        {
            nextPortalUsername = previousPortalUsername;
            _portalUsernameBox.Text = nextPortalUsername;
            _portalPasswordBox.Password = s.PortalPassword ?? string.Empty;
            _casPasswordBox.Password = s.CasPassword ?? string.Empty;
            _portalPasswordEditedSinceUsernameChange = false;
            _casPasswordEditedSinceUsernameChange = false;
        }

        bool accountChanged = !string.Equals(previousPortalUsername, nextPortalUsername, StringComparison.Ordinal);
        if (accountChanged)
        {
            AccountSessionManager.InvalidateForAccountSwitch(nextPortalUsername);

            // Passwords that were present before the username changed belong to the old
            // account. Keep only values the user entered after changing the username.
            if (!_portalPasswordEditedSinceUsernameChange) _portalPasswordBox.Clear();
            if (!_casPasswordEditedSinceUsernameChange) _casPasswordBox.Clear();
            _portalPasswordEditedSinceUsernameChange = false;
            _casPasswordEditedSinceUsernameChange = false;
        }

        var previousDormCampus = s.DormCampus;
        var previousDormBuilding = s.DormBuilding;
        var previousDormRoom = s.DormRoom;
        var previousDormEndNumber = s.DormEndNumber;

        var accountGeneration = AccountSessionManager.Generation;
        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
        {
            s.PortalUsername = nextPortalUsername;
            s.PortalPassword = _portalPasswordBox.Password;
            s.CasPassword = _casPasswordBox.Password;
        })) return;
        _loadedPortalUsername = nextPortalUsername;
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

        bool dormIdentityChanged =
            !string.Equals(previousDormCampus, s.DormCampus, StringComparison.Ordinal) ||
            !string.Equals(previousDormBuilding, s.DormBuilding, StringComparison.Ordinal) ||
            !string.Equals(previousDormRoom, s.DormRoom, StringComparison.Ordinal) ||
            !string.Equals(previousDormEndNumber, s.DormEndNumber, StringComparison.Ordinal);
        if (dormIdentityChanged)
        {
            ElectricityService.Shared.InvalidateCacheIfDormChanged();
        }
    }

    private void UpdateCookieStatusLabel()
    {
        var s = SettingsManager.Shared;
        bool hasTgc = !string.IsNullOrWhiteSpace(s.CasTgcCookie);
        bool hasHuixin = !string.IsNullOrWhiteSpace(s.HuixinAuthToken);
        bool hasNetSession = !string.IsNullOrWhiteSpace(s.SessionCookie);
        bool hasCourse = !string.IsNullOrWhiteSpace(s.CourseSessionCookie) || (CourseScheduleService.Shared.CurrentSchedule?.Lessons.Count > 0);

        string tgcLine = hasTgc 
            ? "🟢 统一认证 (CAS TGC)：已就绪" 
            : "⚪ 统一认证 (CAS SSO)：未登录 (点击上方「统一身份认证快速登录」)";
        string hxLine = hasHuixin 
            ? "🟢 慧新生活 (电费/一卡通)：已授权绑定" 
            : "⚪ 慧新易校 (电费/一卡通)：未绑定 (点击下方「一键绑定慧新生活」)";
        string netLine = hasNetSession 
            ? "🟢 校园网自服务 (流量统计)：已就绪" 
            : "⚪ 校园网自服务 (流量统计)：未同步 (点击下方「自助服务登录」)";
        string crsLine = hasCourse
            ? (CourseScheduleService.Shared.CurrentSchedule?.Lessons.Count > 0
                ? $"🟢 教务系统课表：已载入 ({CourseScheduleService.Shared.CurrentSchedule.Lessons.Count} 节课程)"
                : "🟢 教务系统 Cookie：有效")
            : "⚪ 教务系统课表：未同步 (点击下方「教务系统登录」)";

        _cookieStatusBlock.Text = $"{tgcLine}\n{hxLine}\n{netLine}\n{crsLine}";
    }

    #region Helpers

    private static TextBlock CreateGroupHeader(string title)
    {
        return new TextBlock
        {
            Text = title,
            FontSize = 13,
            FontWeight = FontWeights.Bold,
            Foreground = ThemeManager.Shared.Accent,
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
            Foreground = ThemeManager.Shared.TextPrimary,
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
                Foreground = ThemeManager.Shared.TextMuted,
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
            Background = ThemeManager.Shared.ControlBackground,
            Foreground = ThemeManager.Shared.TextPrimary,
            BorderBrush = ThemeManager.Shared.ControlBorderBrush,
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
            Background = ThemeManager.Shared.ControlBackground,
            Foreground = ThemeManager.Shared.TextPrimary,
            BorderBrush = ThemeManager.Shared.ControlBorderBrush,
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
            Foreground = ThemeManager.Shared.TextPrimary,
            FontSize = 12,
            VerticalContentAlignment = VerticalAlignment.Center
        };
    }

    private static Button CreatePrimaryButton(string content, Action onClick)
    {
        var btn = new Button
        {
            Content = content,
            Background = ThemeManager.Shared.Accent,
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
            Background = ThemeManager.Shared.ControlBackground,
            Foreground = ThemeManager.Shared.TextPrimary,
            BorderBrush = ThemeManager.Shared.ControlBorderBrush,
            BorderThickness = new Thickness(1),
            FontSize = 12,
            Padding = new Thickness(12, 6, 12, 6),
            Cursor = Cursors.Hand
        };
        btn.Click += (_, _) => onClick();
        return btn;
    }

    private static void ApplyDarkTabControlStyle(TabControl tc)
    {
        const string Xaml = @"
<ResourceDictionary xmlns=""http://schemas.microsoft.com/winfx/2006/xaml/presentation""
                    xmlns:x=""http://schemas.microsoft.com/winfx/2006/xaml"">
    <Style TargetType=""TabItem"">
        <Setter Property=""FontSize"" Value=""12.5""/>
        <Setter Property=""Foreground"" Value=""#94A3B8""/>
        <Setter Property=""Cursor"" Value=""Hand""/>
        <Setter Property=""Padding"" Value=""12,7,12,7""/>
        <Setter Property=""Margin"" Value=""0,0,6,0""/>
        <Setter Property=""Template"">
            <Setter.Value>
                <ControlTemplate TargetType=""TabItem"">
                    <Border x:Name=""TabBorder""
                            Background=""Transparent""
                            BorderThickness=""0""
                            CornerRadius=""6""
                            Padding=""{TemplateBinding Padding}""
                            SnapsToDevicePixels=""True"">
                        <ContentPresenter ContentSource=""Header""
                                          HorizontalAlignment=""Center""
                                          VerticalAlignment=""Center""/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property=""IsMouseOver"" Value=""True"">
                            <Setter TargetName=""TabBorder"" Property=""Background"" Value=""#2238BDF8""/>
                            <Setter Property=""Foreground"" Value=""#E0F2FE""/>
                        </Trigger>
                        <Trigger Property=""IsSelected"" Value=""True"">
                            <Setter TargetName=""TabBorder"" Property=""Background"" Value=""#3338BDF8""/>
                            <Setter Property=""Foreground"" Value=""#38BDF8""/>
                            <Setter Property=""FontWeight"" Value=""SemiBold""/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
</ResourceDictionary>";

        string themedXaml = Xaml;
        if (!ThemeManager.Shared.IsDarkTheme)
        {
            themedXaml = themedXaml
                .Replace("#94A3B8", "#6E6E73")
                .Replace("#2238BDF8", "#1F0A84FF")
                .Replace("#E0F2FE", "#1D1D1F")
                .Replace("#3338BDF8", "#330A84FF")
                .Replace("#38BDF8", "#0A84FF");
        }

        try
        {
            var dict = (ResourceDictionary)System.Windows.Markup.XamlReader.Parse(themedXaml);
            tc.Resources.MergedDictionaries.Add(dict);
        }
        catch { }
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

    public static void ClearAuthCookiesForAccountSwitch()
    {
        try { _shared?._webView.CoreWebView2?.CookieManager.DeleteAllCookies(); } catch { }
    }

    private readonly WebView2 _webView;
    private readonly TextBlock _statusText;
    private readonly TextBlock _statusDetailText;
    private readonly ProgressBar _progressBar;
    private readonly TextBlock[] _stepStatusLabels = new TextBlock[4];
    private readonly StepStatus[] _stepStatuses = new StepStatus[4];
    private readonly Button[] _themeButtons = new Button[4];
    private readonly Dictionary<ulong, (Guid SessionId, long AccountGeneration)> _navigationSessions = new();
    private long _accountSessionGenerationAtStart;
    private Guid _loginWindowSessionId;
    private Border _topBar = null!;
    private Border _bottomBar = null!;
    private readonly string[] _stepNames =
    {
        "1. 统一身份认证",
        "2. 教务课表同步",
        "3. 宿舍电费查询",
        "4. 校园网与历史用量"
    };
    private bool _hasInterceptedAuth;

    public UnifiedLoginWebWindow()
    {
        Title = "合肥工业大学统一身份认证 · 一键登录并自动刷新全部服务";
        Width = 1016;
        Height = 760;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = ThemeManager.Shared.WindowBackground;

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(46) }); // Header
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); // WebView2
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(86) }); // Sync status footer

        _topBar = new Border
        {
            Background = ThemeManager.Shared.TopBarBackground,
            Padding = new Thickness(16, 5, 16, 5),
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(0, 0, 0, 1)
        };
        var headerGrid = new Grid();
        headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var headerContent = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var headerIcon = new TextBlock
        {
            Text = "🔐",
            FontSize = 19,
            Margin = new Thickness(0, 0, 10, 0),
            VerticalAlignment = VerticalAlignment.Center
        };
        headerContent.Children.Add(headerIcon);
        var headerLabels = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        headerLabels.Children.Add(new TextBlock
        {
            Text = "合肥工业大学统一身份认证 (CAS SSO)",
            FontSize = 13,
            FontWeight = FontWeights.Bold,
            Foreground = ThemeManager.Shared.TextPrimary
        });
        headerLabels.Children.Add(new TextBlock
        {
            Text = "登录信息门户后，应用将自动同步课表、宿舍电费、校园网流量与历史统计",
            FontSize = 11,
            Foreground = ThemeManager.Shared.TextSecondary,
            Margin = new Thickness(0, 1, 0, 0)
        });
        headerContent.Children.Add(headerLabels);
        headerGrid.Children.Add(headerContent);

        var reloadButton = CreateAuthToolbarButton("重新加载", isPrimary: false);
        reloadButton.Click += (_, _) => ShowWindow();
        _themeButtons[0] = reloadButton;
        Grid.SetColumn(reloadButton, 1);
        headerGrid.Children.Add(reloadButton);
        _topBar.Child = headerGrid;
        Grid.SetRow(_topBar, 0);
        root.Children.Add(_topBar);

        _webView = new WebView2();
        Grid.SetRow(_webView, 1);
        root.Children.Add(_webView);

        _bottomBar = new Border
        {
            Background = ThemeManager.Shared.TopBarBackground,
            Padding = new Thickness(16, 7, 16, 7),
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(0, 1, 0, 0)
        };
        var footerGrid = new Grid();
        footerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(420) });
        footerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footerGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        footerGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var statusStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        _statusText = new TextBlock
        {
            Text = "等待统一身份认证登录...",
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeManager.Shared.TextPrimary,
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        _statusDetailText = new TextBlock
        {
            Text = "请在上方登录信息门户，成功后应用会自动激活校园服务",
            FontSize = 11,
            Foreground = ThemeManager.Shared.TextSecondary,
            Margin = new Thickness(0, 2, 0, 0),
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        statusStack.Children.Add(_statusText);
        statusStack.Children.Add(_statusDetailText);
        Grid.SetRow(statusStack, 0);
        Grid.SetColumn(statusStack, 0);
        footerGrid.Children.Add(statusStack);

        _progressBar = new ProgressBar
        {
            Height = 3,
            IsIndeterminate = true,
            Background = ThemeManager.Shared.ControlBackground,
            Foreground = ThemeManager.Shared.Accent,
            Margin = new Thickness(0, 5, 12, 0)
        };
        Grid.SetRow(_progressBar, 1);
        Grid.SetColumn(_progressBar, 0);
        footerGrid.Children.Add(_progressBar);

        var rightFooter = new Grid();
        rightFooter.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        rightFooter.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        rightFooter.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(rightFooter, 1);
        Grid.SetRowSpan(rightFooter, 2);
        footerGrid.Children.Add(rightFooter);

        var stepsGrid = new UniformGrid { Rows = 1, Columns = 4, VerticalAlignment = VerticalAlignment.Center };
        for (int i = 0; i < _stepNames.Length; i++)
        {
            var label = new TextBlock
            {
                Text = "○ " + _stepNames[i],
                FontSize = 10.5,
                FontWeight = FontWeights.Medium,
                Foreground = ThemeManager.Shared.TextMuted,
                Margin = new Thickness(i == 0 ? 0 : 4, 0, 3, 0),
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center
            };
            _stepStatusLabels[i] = label;
            _stepStatuses[i] = StepStatus.Waiting;
            stepsGrid.Children.Add(label);
        }
        Grid.SetRow(stepsGrid, 0);
        rightFooter.Children.Add(stepsGrid);

        var actionRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 4, 0, 0)
        };
        var captureButton = CreateAuthToolbarButton("抓取凭证并完成", isPrimary: true);
        captureButton.Click += async (_, _) => await CheckCookiesAndCompleteAsync(force: true);
        _themeButtons[1] = captureButton;
        actionRow.Children.Add(captureButton);

        var scheduleButton = CreateAuthToolbarButton("查看课表", isPrimary: false);
        scheduleButton.Margin = new Thickness(8, 0, 0, 0);
        scheduleButton.Click += (_, _) => CourseScheduleWindow.Shared.ShowWindow();
        _themeButtons[2] = scheduleButton;
        actionRow.Children.Add(scheduleButton);

        var statsButton = CreateAuthToolbarButton("用量统计", isPrimary: false);
        statsButton.Margin = new Thickness(8, 0, 0, 0);
        statsButton.Click += (_, _) => HistoryStatsWindow.Shared.ShowWindow(0);
        _themeButtons[3] = statsButton;
        actionRow.Children.Add(statsButton);
        Grid.SetRow(actionRow, 1);
        rightFooter.Children.Add(actionRow);

        _bottomBar.Child = footerGrid;
        Grid.SetRow(_bottomBar, 2);
        root.Children.Add(_bottomBar);

        Content = root;

        Closing += (_, e) =>
        {
            e.Cancel = true;
            Hide();
        };

        InitWebView();
        ThemeManager.Shared.ApplyWindowTheme(this);
        ApplyTheme();
        ThemeManager.Shared.ThemeChanged += () => AppEvents.InvokeOnUI(ApplyTheme);
    }

    private static Button CreateAuthToolbarButton(string title, bool isPrimary)
    {
        return new Button
        {
            Content = title,
            Height = 28,
            MinWidth = isPrimary ? 126 : 82,
            Padding = new Thickness(10, 3, 10, 3),
            FontSize = 11.5,
            FontWeight = isPrimary ? FontWeights.SemiBold : FontWeights.Normal,
            Background = isPrimary ? ThemeManager.Shared.Accent : ThemeManager.Shared.ControlBackground,
            Foreground = isPrimary ? Brushes.White : ThemeManager.Shared.TextPrimary,
            BorderBrush = isPrimary ? ThemeManager.Shared.Accent : ThemeManager.Shared.ControlBorderBrush,
            BorderThickness = new Thickness(1),
            Cursor = Cursors.Hand
        };
    }

    private void ApplyTheme()
    {
        ThemeManager.Shared.ApplyWindowTheme(this);
        Background = ThemeManager.Shared.WindowBackground;
        _topBar.Background = ThemeManager.Shared.TopBarBackground;
        _topBar.BorderBrush = ThemeManager.Shared.CardBorderBrush;
        _bottomBar.Background = ThemeManager.Shared.TopBarBackground;
        _bottomBar.BorderBrush = ThemeManager.Shared.CardBorderBrush;
        _statusText.Foreground = ThemeManager.Shared.TextPrimary;
        _statusDetailText.Foreground = ThemeManager.Shared.TextSecondary;
        _progressBar.Background = ThemeManager.Shared.ControlBackground;
        _progressBar.Foreground = ThemeManager.Shared.Accent;

        for (int i = 0; i < _stepStatuses.Length; i++)
            UpdateStep(i, _stepStatuses[i]);

        for (int i = 0; i < _themeButtons.Length; i++)
        {
            var button = _themeButtons[i];
            if (button == null) continue;
            bool primary = i == 1;
            button.Background = primary ? ThemeManager.Shared.Accent : ThemeManager.Shared.ControlBackground;
            button.Foreground = primary ? Brushes.White : ThemeManager.Shared.TextPrimary;
            button.BorderBrush = primary ? ThemeManager.Shared.Accent : ThemeManager.Shared.ControlBorderBrush;
        }
    }

    public void ShowLoginWindow(string serviceName = "统一身份认证", string? targetUrl = null, Action<bool, string>? callback = null)
    {
        Title = $"{serviceName} - 合工大校园助手";
        _statusText.Text = $"正在加载 {serviceName}...";
        _statusDetailText.Text = "登录信息门户后，应用会自动刷新已授权的校园服务";
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
            _statusDetailText.Text = "请检查 WebView2 Runtime 是否可用，然后重新加载页面";
            _progressBar.Visibility = Visibility.Collapsed;
        }
    }

    public async void ShowWindow()
    {
        var loginWindowSessionId = Guid.NewGuid();
        _loginWindowSessionId = loginWindowSessionId;
        _navigationSessions.Clear();
        try { _webView.CoreWebView2?.Stop(); } catch { }
        _hasInterceptedAuth = false;
        _accountSessionGenerationAtStart = AccountSessionManager.Generation;
        _progressBar.Visibility = Visibility.Visible;
        _statusText.Text = "正在打开统一身份认证登录页...";
        _statusDetailText.Text = "登录成功后，应用将自动同步课表、宿舍电费及校园网自服务";
        for (int i = 0; i < _stepNames.Length; i++)
            UpdateStep(i, i == 0 ? StepStatus.InProgress : StepStatus.Waiting);

        if (WindowState == WindowState.Minimized)
            WindowState = WindowState.Normal;
        Show();
        Activate();

        await _webView.EnsureCoreWebView2Async();
        if (_loginWindowSessionId != loginWindowSessionId ||
            !AccountSessionManager.IsGenerationCurrent(_accountSessionGenerationAtStart)) return;
        _webView.CoreWebView2.Navigate("https://cas.hfut.edu.cn/cas/login?service=https%3A%2F%2Fcas.hfut.edu.cn%2Fcas%2Flogin");
    }

    private void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs e)
    {
        var sessionId = _loginWindowSessionId;
        var accountGeneration = _accountSessionGenerationAtStart;
        if (!IsLoginWindowSessionCurrent(sessionId, accountGeneration))
        {
            e.Cancel = true;
            return;
        }
        _navigationSessions[e.NavigationId] = (sessionId, accountGeneration);
        _statusText.Text = $"正在跳转: {e.Uri}";
        _statusDetailText.Text = "正在连接统一身份认证服务...";
        _progressBar.Visibility = Visibility.Visible;
        UpdateStep(0, StepStatus.InProgress);
    }

    private async void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (!_navigationSessions.Remove(e.NavigationId, out var navigationSession) ||
            !IsLoginWindowSessionCurrent(navigationSession.SessionId, navigationSession.AccountGeneration)) return;
        _progressBar.Visibility = Visibility.Collapsed;
        if (!e.IsSuccess)
        {
            _statusText.Text = "加载页面失败，请检查网络连接";
            _statusDetailText.Text = "确认网络连接后点击右上角“重新加载”";
            UpdateStep(0, StepStatus.Failure);
            return;
        }

        string currentUrl = _webView.Source?.ToString() ?? "";
        _statusText.Text = "页面已就绪";
        _statusDetailText.Text = "如页面提示验证码，请在上方网页完成验证后继续";

        // Auto-fill credentials if on login form
        if (Uri.TryCreate(currentUrl, UriKind.Absolute, out var currentUri) &&
            currentUri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase) &&
            currentUri.Host.Equals("cas.hfut.edu.cn", StringComparison.OrdinalIgnoreCase) &&
            currentUri.AbsolutePath.Equals("/cas/login", StringComparison.OrdinalIgnoreCase))
        {
            string username = string.Empty;
            string password = string.Empty;
            if (!AccountSessionManager.TryRunForGeneration(_accountSessionGenerationAtStart, () =>
            {
                username = SettingsManager.Shared.PortalUsername;
                password = !string.IsNullOrWhiteSpace(SettingsManager.Shared.CasPassword)
                    ? SettingsManager.Shared.CasPassword
                    : SettingsManager.Shared.PortalPassword;
            })) return;

            if (!string.IsNullOrWhiteSpace(username) && !string.IsNullOrWhiteSpace(password))
            {
                string script = $@"
                    (function() {{
                        var tries = 0;
                        function setVal(input, val) {{
                            if (!input || !val) return;
                            var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set;
                            if (setter) {{ setter.call(input, val); }} else {{ input.value = val; }}
                            input.dispatchEvent(new Event('input', {{ bubbles: true }}));
                            input.dispatchEvent(new Event('change', {{ bubbles: true }}));
                            input.dispatchEvent(new Event('blur', {{ bubbles: true }}));
                        }}
                        var timer = setInterval(function() {{
                            tries++;
                            var u = document.getElementById('username') || document.getElementById('u') || document.querySelector('input[name=""username""]') || document.querySelector('input[type=""text""]');
                            // 必须优先选取可见密码框 pwd，严禁选取隐藏域 <input type=""hidden"" id=""password"">
                            var p = document.getElementById('pwd') || document.querySelector('input[type=""password""]:not([type=""hidden""])') || document.querySelector('input[type=""password""]') || document.querySelector('input.password');
                            if (u && !u.value) {{
                                setVal(u, '{EscapeJs(username)}');
                            }}
                            if (p && !p.value) {{
                                setVal(p, '{EscapeJs(password)}');
                            }}
                            if ((u && u.value && p && p.value) || tries > 25) {{
                                clearInterval(timer);
                                // 自动提交登录（若无错误信息且无验证码拦截）
                                setTimeout(function() {{
                                    var errU = document.getElementById('errorusername');
                                    var errP = document.getElementById('errorpassword');
                                    var errG = document.getElementById('error');
                                    var hasErr = (errU && errU.innerText.trim() !== '') || (errP && errP.innerText.trim() !== '') || (errG && errG.innerText.trim() !== '');
                                    var needCode = (typeof isCodeShow !== 'undefined' && isCodeShow) || (typeof isDynamicVercode !== 'undefined' && isDynamicVercode);
                                    var btn = document.getElementById('sb2') || document.querySelector('.button-submit') || document.querySelector('input[type=""submit""]');
                                    if (!hasErr && !needCode && u && u.value && p && p.value && btn) {{
                                        btn.click();
                                    }}
                                }}, 350);
                            }}
                        }}, 200);
                    }})();";
                await _webView.ExecuteScriptAsync(script);
                if (!IsLoginWindowSessionCurrent(navigationSession.SessionId, navigationSession.AccountGeneration)) return;
            }
        }

        // 检查 cookies (CAS TGC 与 SESSION)
        await CheckCookiesAndCompleteAsync(
            false,
            navigationSession.SessionId,
            navigationSession.AccountGeneration);
    }

    public Task CheckCookiesAndCompleteAsync(bool force = false) =>
        CheckCookiesAndCompleteAsync(force, _loginWindowSessionId, _accountSessionGenerationAtStart);

    private async Task CheckCookiesAndCompleteAsync(bool force, Guid loginWindowSessionId, long accountGeneration)
    {
        if (_hasInterceptedAuth && !force) return;
        if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;
        if (_webView.CoreWebView2 == null) return;

        try
        {
            var cookieList = await _webView.CoreWebView2.CookieManager.GetCookiesAsync("https://cas.hfut.edu.cn");
            if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;
            var tgcCookie = cookieList.FirstOrDefault(c => c.Name.Equals("CASTGC", StringComparison.OrdinalIgnoreCase));
            
            // 兜底查根域名
            if (tgcCookie == null)
            {
                var allCasCookies = await _webView.CoreWebView2.CookieManager.GetCookiesAsync("https://cas.hfut.edu.cn/cas/login");
                if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;
                tgcCookie = allCasCookies.FirstOrDefault(c => c.Name.Equals("CASTGC", StringComparison.OrdinalIgnoreCase));
            }

            // 同时检查教务 Cookie
            var jxCookies = await _webView.CoreWebView2.CookieManager.GetCookiesAsync("http://jxglstu.hfut.edu.cn");
            if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;
            var sessionCookie = jxCookies.FirstOrDefault(c => c.Name.Equals("SESSION", StringComparison.OrdinalIgnoreCase));
            var srvidCookie = jxCookies.FirstOrDefault(c => c.Name.Equals("SRVID", StringComparison.OrdinalIgnoreCase));
            var sessionHeader = sessionCookie != null && !string.IsNullOrWhiteSpace(sessionCookie.Value)
                ? srvidCookie != null && !string.IsNullOrWhiteSpace(srvidCookie.Value)
                    ? $"SESSION={sessionCookie.Value}; SRVID={srvidCookie.Value}"
                    : $"SESSION={sessionCookie.Value}"
                : null;
            var tgcValue = tgcCookie != null && !string.IsNullOrWhiteSpace(tgcCookie.Value)
                ? tgcCookie.Value
                : null;
            if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
            {
                if (sessionHeader != null) SettingsManager.Shared.CourseSessionCookie = sessionHeader;
                if (tgcValue != null) SettingsManager.Shared.CasTgcCookie = tgcValue;
                if (sessionHeader != null || tgcValue != null) SettingsManager.Shared.Save();
            })) return;

            if (tgcValue != null)
            {
                _hasInterceptedAuth = true;
                AppEvents.RaiseAuthStatusUpdated();

                _statusText.Text = "✅ 已捕获统一认证凭证 (CASTGC)！正在换取慧新生活与教务授权...";
                _statusDetailText.Text = "校园服务正在后台同步，完成后此窗口会自动关闭";
                _progressBar.Visibility = Visibility.Visible;
                UpdateStep(0, StepStatus.Success);
                UpdateStep(1, StepStatus.InProgress);

                // Background exchange
                _ = Task.Run(async () =>
                {
                    string? syncStartError = null;
                    try
                    {
                        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return;
                        await ElectricityService.Shared.ObtainHuiXinTokenAsync(
                            tryPersistToken: null,
                            expectedAccountGeneration: accountGeneration);
                        if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;
                        ElectricityService.Shared.FetchData();
                        CampusCardService.Shared.FetchData();
                        await CourseScheduleService.Shared.ExchangeCasTicketForEamsSessionAsync(tgcValue, accountGeneration);
                        if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;
                        AppEvents.InvokeOnUI(() =>
                        {
                            if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;
                            UpdateStep(1, StepStatus.InProgress);
                            UpdateStep(2, StepStatus.InProgress);
                        });
                        await EmptyClassroomService.Shared.EnsureValidTokenAsync(
                            forceRelogin: true,
                            expectedAccountGeneration: accountGeneration);
                        if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;
                        CourseScheduleService.Shared.SyncSchedule(expectedAccountGeneration: accountGeneration);
                        AcademicService.Shared.SyncAll(silent: false, expectedAccountGeneration: accountGeneration);
                        EmptyClassroomService.Shared.SyncTodayAndTomorrowStudyRooms(forceRefresh: true);
                        AppEvents.RaiseAuthStatusUpdated();
                    }
                    catch (Exception ex)
                    {
                        syncStartError = ex.Message;
                    }

                    AppEvents.InvokeOnUI(() =>
                    {
                        if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;
                        _statusText.Text = syncStartError == null
                            ? "🎉 统一身份认证成功，校园服务刷新已启动。"
                            : "统一身份认证成功，但部分服务刷新未能启动。";
                        _statusDetailText.Text = syncStartError == null
                            ? "课表、宿舍电费、一卡通与校园网正在后台更新；请稍后查看各模块数据状态。"
                            : $"后台服务刷新启动失败：{syncStartError}";
                        UpdateStep(1, syncStartError == null ? StepStatus.InProgress : StepStatus.Failure);
                        UpdateStep(2, syncStartError == null ? StepStatus.InProgress : StepStatus.Failure);
                        UpdateStep(3, syncStartError == null ? StepStatus.InProgress : StepStatus.Failure);
                        _progressBar.Visibility = Visibility.Collapsed;
                        TrayMenuController.Shared.ShowNotification(
                            syncStartError == null ? "统一身份认证成功" : "统一身份认证成功，服务刷新受阻",
                            syncStartError == null ? "课表与校园服务数据刷新已启动。" : syncStartError);
                        Task.Delay(1200).ContinueWith(_ => AppEvents.InvokeOnUI(() =>
                        {
                            if (IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) Hide();
                        }));
                    });
                });
            }
            else if (force)
            {
                _statusText.Text = "⚠️ 未在浏览器中检测到有效的 CASTGC Cookie，请先在页面中登录成功";
                _statusDetailText.Text = "确认已在统一身份认证页面完成登录";
                _progressBar.Visibility = Visibility.Collapsed;
                UpdateStep(0, StepStatus.Failure);
            }
        }
        catch (Exception ex)
        {
            if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;
            if (force)
            {
                _statusText.Text = $"检测凭证异常: {ex.Message}";
                _statusDetailText.Text = "请检查登录页面状态后重试";
                _progressBar.Visibility = Visibility.Collapsed;
                UpdateStep(0, StepStatus.Failure);
            }
        }
    }

    private bool IsLoginWindowSessionCurrent(Guid loginWindowSessionId, long accountGeneration) =>
        _loginWindowSessionId == loginWindowSessionId &&
        AccountSessionManager.IsGenerationCurrent(accountGeneration);

    private enum StepStatus
    {
        Waiting,
        InProgress,
        Success,
        Failure
    }

    private void UpdateStep(int index, StepStatus status)
    {
        if (index < 0 || index >= _stepStatusLabels.Length || _stepStatusLabels[index] == null)
            return;

        _stepStatuses[index] = status;
        var (symbol, brush) = status switch
        {
            StepStatus.InProgress => ("●", ThemeManager.Shared.Accent),
            StepStatus.Success => ("●", ThemeManager.Shared.Success),
            StepStatus.Failure => ("●", ThemeManager.Shared.Danger),
            _ => ("○", ThemeManager.Shared.TextMuted)
        };
        _stepStatusLabels[index].Text = $"{symbol} {_stepNames[index]}";
        _stepStatusLabels[index].Foreground = brush;
    }

    private static string EscapeJs(string s) => s.Replace("\\", "\\\\").Replace("'", "\\'").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", "");
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

    public static void ClearAuthCookiesForAccountSwitch()
    {
        try { _shared?._webView.CoreWebView2?.CookieManager.DeleteAllCookies(); } catch { }
    }

    private readonly WebView2 _webView;
    private readonly TextBlock _statusText;
    private readonly Border _topBar;
    private readonly List<Button> _themeButtons = new();
    private readonly Dictionary<ulong, (Guid SessionId, long AccountGeneration)> _navigationSessions = new();
    private long _accountSessionGenerationAtStart;
    private Guid _loginWindowSessionId;

    public LoginWebWindow()
    {
        Title = "校园网自服务系统登录 - 合工大校园助手";
        Width = 916;
        Height = 660;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = ThemeManager.Shared.WindowBackground;

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        _topBar = new Border
        {
            Background = ThemeManager.Shared.TopBarBackground,
            Padding = new Thickness(14, 8, 14, 8),
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(0, 0, 0, 1)
        };
        var topDock = new DockPanel();

        var btnPanel = new StackPanel { Orientation = Orientation.Horizontal };
        DockPanel.SetDock(btnPanel, Dock.Right);

        var extractBtn = new Button
        {
            Content = "⚡ 提取当前页面流量",
            Background = ThemeManager.Shared.Accent,
            Foreground = MediaBrushes.White,
            Padding = new Thickness(10, 4, 10, 4),
            FontSize = 12,
            Margin = new Thickness(6, 0, 0, 0),
            Cursor = Cursors.Hand,
            Tag = "Primary"
        };
        extractBtn.Click += async (_, _) => await ExtractDashboardData(manual: true);

        var reloadBtn = new Button
        {
            Content = "🔄 重新加载",
            Background = ThemeManager.Shared.ControlBackground,
            Foreground = ThemeManager.Shared.TextPrimary,
            BorderBrush = ThemeManager.Shared.ControlBorderBrush,
            Padding = new Thickness(8, 4, 8, 4),
            FontSize = 12,
            Cursor = Cursors.Hand,
            Tag = "Secondary"
        };
        reloadBtn.Click += (_, _) => ShowWindow();

        btnPanel.Children.Add(reloadBtn);
        btnPanel.Children.Add(extractBtn);
        _themeButtons.Add(reloadBtn);
        _themeButtons.Add(extractBtn);
        topDock.Children.Add(btnPanel);

        _statusText = new TextBlock
        {
            Text = "正在打开校园网自服务系统 (xywzz:8443)...",
            FontSize = 12,
            Foreground = ThemeManager.Shared.TextSecondary,
            VerticalAlignment = VerticalAlignment.Center
        };
        topDock.Children.Add(_statusText);
        _topBar.Child = topDock;

        Grid.SetRow(_topBar, 0);
        root.Children.Add(_topBar);

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
        ThemeManager.Shared.ApplyWindowTheme(this);
        ApplyTheme();
        ThemeManager.Shared.ThemeChanged += () => AppEvents.InvokeOnUI(ApplyTheme);
    }

    private void ApplyTheme()
    {
        ThemeManager.Shared.ApplyWindowTheme(this);
        Background = ThemeManager.Shared.WindowBackground;
        _topBar.Background = ThemeManager.Shared.TopBarBackground;
        _topBar.BorderBrush = ThemeManager.Shared.CardBorderBrush;
        _statusText.Foreground = ThemeManager.Shared.TextSecondary;
        foreach (var button in _themeButtons)
        {
            bool primary = Equals(button.Tag, "Primary");
            button.Background = primary ? ThemeManager.Shared.Accent : ThemeManager.Shared.ControlBackground;
            button.Foreground = primary ? MediaBrushes.White : ThemeManager.Shared.TextPrimary;
            button.BorderBrush = primary ? ThemeManager.Shared.Accent : ThemeManager.Shared.ControlBorderBrush;
        }
    }

    private async void InitWebView()
    {
        try
        {
            string userDataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HFUTCampusNet", "WebView2_SelfService");
            var env = await CoreWebView2Environment.CreateAsync(null, userDataDir);
            await _webView.EnsureCoreWebView2Async(env);

            // 忽略校园网自签名证书
            _webView.CoreWebView2.ServerCertificateErrorDetected += (_, args) =>
            {
                bool isSelfServiceRequest = Uri.TryCreate(args.RequestUri, UriKind.Absolute, out var requestUri) &&
                    requestUri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase) &&
                    requestUri.Host.Equals("xywzz.hfut.edu.cn", StringComparison.OrdinalIgnoreCase) &&
                    requestUri.Port == 8443;
                args.Action = isSelfServiceRequest
                    ? CoreWebView2ServerCertificateErrorAction.AlwaysAllow
                    : CoreWebView2ServerCertificateErrorAction.Default;
            };

            _webView.CoreWebView2.NavigationStarting += OnNavigationStarting;
            _webView.CoreWebView2.NavigationCompleted += OnNavigationCompleted;
        }
        catch (Exception ex)
        {
            _statusText.Text = $"WebView2 初始化失败: {ex.Message}";
        }
    }

    public async void ShowWindow()
    {
        var loginWindowSessionId = Guid.NewGuid();
        var accountGeneration = AccountSessionManager.Generation;
        _loginWindowSessionId = loginWindowSessionId;
        _accountSessionGenerationAtStart = accountGeneration;
        _navigationSessions.Clear();
        try { _webView.CoreWebView2?.Stop(); } catch { }
        if (WindowState == WindowState.Minimized)
            WindowState = WindowState.Normal;
        Show();
        Activate();

        await _webView.EnsureCoreWebView2Async();
        if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;
        _statusText.Text = "正在连接校园网自服务系统，若已保存账号密码将自动填充...";
        _webView.CoreWebView2.Navigate("https://xywzz.hfut.edu.cn:8443/Self/login/?302=LI");
    }

    public void ShowLoginWindow() => ShowWindow();
    public static void ShowLogin() => Shared.ShowWindow();

    private void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs e)
    {
        var sessionId = _loginWindowSessionId;
        var accountGeneration = _accountSessionGenerationAtStart;
        if (!IsLoginWindowSessionCurrent(sessionId, accountGeneration))
        {
            e.Cancel = true;
            return;
        }
        _navigationSessions[e.NavigationId] = (sessionId, accountGeneration);
    }

    private async void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (!_navigationSessions.Remove(e.NavigationId, out var navigationSession) ||
            !IsLoginWindowSessionCurrent(navigationSession.SessionId, navigationSession.AccountGeneration)) return;
        if (!e.IsSuccess) return;

        string currentUrl = _webView.Source?.ToString() ?? "";
        _statusText.Text = $"当前页面: {currentUrl}";

        // 强力轮询自动填充账号与密码（持续尝试 20 次，间隔 200ms）并自动提交登录
        if (Uri.TryCreate(currentUrl, UriKind.Absolute, out var currentUri) &&
            currentUri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase) &&
            currentUri.Host.Equals("xywzz.hfut.edu.cn", StringComparison.OrdinalIgnoreCase) &&
            currentUri.Port == 8443 &&
            (currentUri.AbsolutePath.Equals("/Self/login", StringComparison.OrdinalIgnoreCase) ||
             currentUri.AbsolutePath.Equals("/Self/login/", StringComparison.OrdinalIgnoreCase)))
        {
            string username = string.Empty;
            string password = string.Empty;
            if (!AccountSessionManager.TryRunForGeneration(navigationSession.AccountGeneration, () =>
            {
                username = SettingsManager.Shared.PortalUsername;
                password = !string.IsNullOrWhiteSpace(SettingsManager.Shared.PortalPassword)
                    ? SettingsManager.Shared.PortalPassword
                    : SettingsManager.Shared.CasPassword;
            })) return;

            if (!string.IsNullOrEmpty(username) && !string.IsNullOrEmpty(password))
            {
                string script = $@"
                    (function() {{
                        var tries = 0;
                        function setVal(input, val) {{
                            if (!input || !val) return;
                            var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set;
                            if (setter) {{ setter.call(input, val); }} else {{ input.value = val; }}
                            input.dispatchEvent(new Event('input', {{ bubbles: true }}));
                            input.dispatchEvent(new Event('change', {{ bubbles: true }}));
                            input.dispatchEvent(new Event('blur', {{ bubbles: true }}));
                        }}
                        var timer = setInterval(function() {{
                            tries++;
                            var u = document.getElementById('account') || document.querySelector('input[name=""account""]') || document.getElementById('username') || document.querySelector('input[type=""text""]');
                            var p = document.getElementById('password') || document.querySelector('input[name=""password""]') || document.querySelector('input[type=""password""]');
                            if (u && !u.value) {{
                                setVal(u, '{EscapeJs(username)}');
                            }}
                            if (p && !p.value) {{
                                setVal(p, '{EscapeJs(password)}');
                            }}
                            if ((u && u.value && p && p.value) || tries > 20) {{
                                clearInterval(timer);
                                // 检查是否有错误提示或验证码拦截，若无则自动触发登录
                                setTimeout(function() {{
                                    var errTip = document.getElementById('errorTip');
                                    var hasErr = errTip && errTip.innerText.trim().length > 0;
                                    var randDiv = document.getElementById('randomDiv');
                                    var codeInput = document.getElementById('code');
                                    var needCode = (randDiv && !randDiv.classList.contains('hide')) || (codeInput && codeInput.offsetParent !== null && !codeInput.value);
                                    var btn = document.querySelector('button[name=""submit""]') || document.querySelector('button[type=""submit""]') || document.querySelector('.btn-primary') || document.getElementById('login_btn');
                                    if (!hasErr && !needCode && u && u.value && p && p.value && btn) {{
                                        btn.click();
                                    }}
                                }}, 250);
                            }}
                        }}, 200);
                    }})();";
                await _webView.ExecuteScriptAsync(script);
                if (!IsLoginWindowSessionCurrent(navigationSession.SessionId, navigationSession.AccountGeneration)) return;
            }
            return; // 还在登录页，不要误触发提取！
        }

        // 离开登录页后，延迟短暂时间等待仪表盘 DOM 渲染完成后自动提取
        await Task.Delay(500);
        if (!IsLoginWindowSessionCurrent(navigationSession.SessionId, navigationSession.AccountGeneration)) return;
        await ExtractDashboardData(false, navigationSession.SessionId, navigationSession.AccountGeneration);
    }

    private Task ExtractDashboardData(bool manual = false) =>
        ExtractDashboardData(manual, _loginWindowSessionId, _accountSessionGenerationAtStart);

    private async Task ExtractDashboardData(bool manual, Guid loginWindowSessionId, long accountGeneration)
    {
        if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;
        if (_webView.CoreWebView2 == null) return;

        var cookies = await _webView.CoreWebView2.CookieManager.GetCookiesAsync("https://xywzz.hfut.edu.cn:8443");
        if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;
        var jsession = cookies.FirstOrDefault(c => c.Name.Equals("JSESSIONID", StringComparison.OrdinalIgnoreCase));
        if (jsession != null && !string.IsNullOrWhiteSpace(jsession.Value))
        {
            if (!CampusNetworkClient.Shared.TrySetSessionCookie($"JSESSIONID={jsession.Value}", accountGeneration)) return;
            AppEvents.RaiseAuthStatusUpdated();
        }

        // 1. 优先通过 JS 在 DOM 文本中提取结构化数据
        try
        {
            string domScript = @"
                (function() {
                    var res = { used: null, avail: null, bal: null, prot: null };
                    // 1. 精确 DOM 节点兄弟元素提取
                    var allNodes = document.querySelectorAll('dt, dd, span, div, td, p');
                    for (var i = 0; i < allNodes.length; i++) {
                        var el = allNodes[i];
                        var t = (el.innerText || '').trim();
                        if (t === '已用流量' || t === '本月已用') {
                            var sib = el.nextElementSibling || el.previousElementSibling;
                            if (sib && sib !== el) {
                                var m = sib.innerText.match(/([0-9]+(?:\.[0-9]+)?\s*(?:[GMK]B?|M|G)?)/i);
                                if (m && !res.used) res.used = m[1];
                            }
                        } else if (t === '可用流量' || t === '剩余流量') {
                            var sib = el.nextElementSibling || el.previousElementSibling;
                            if (sib && sib !== el) {
                                var m = sib.innerText.match(/([0-9]+(?:\.[0-9]+)?\s*(?:[GMK]B?|M|G)?)/i);
                                if (m && !res.avail) res.avail = m[1];
                            }
                        } else if (t === '账户余额' || t === '余额') {
                            var sib = el.nextElementSibling || el.previousElementSibling;
                            if (sib && sib !== el) {
                                var m = sib.innerText.match(/([0-9]+(?:\.[0-9]+)?\s*元?)/i);
                                if (m && !res.bal) res.bal = m[1];
                            }
                        } else if (t === '消费保护') {
                            var sib = el.nextElementSibling || el.previousElementSibling;
                            if (sib && sib !== el) {
                                var m = sib.innerText.match(/([0-9]+(?:\.[0-9]+)?\s*元?)/i);
                                if (m && !res.prot) res.prot = m[1];
                            }
                        }
                    }

                    // 2. 纯文本单向后行匹配兜底（严禁向前贪婪匹配，防止可用流量数值串入已用流量）
                    var text = document.body ? document.body.innerText : '';
                    if (!res.used) {
                        var mUsed = text.match(/已用流量[^\r\n0-9]{0,25}?([0-9]+(?:\.[0-9]+)?\s*(?:[GMK]B?|M|G))/i);
                        if (mUsed) res.used = mUsed[1];
                    }
                    if (!res.avail) {
                        var mAvail = text.match(/可用流量[^\r\n0-9]{0,25}?([0-9]+(?:\.[0-9]+)?\s*(?:[GMK]B?|M|G))/i);
                        if (mAvail) res.avail = mAvail[1];
                    }
                    if (!res.bal) {
                        var mBal = text.match(/账户余额[^\r\n0-9]{0,25}?([0-9]+(?:\.[0-9]+)?\s*元?)/i);
                        if (mBal) res.bal = mBal[1];
                    }
                    if (!res.prot) {
                        var mProt = text.match(/消费保护[^\r\n0-9]{0,25}?([0-9]+(?:\.[0-9]+)?\s*元?)/i);
                        if (mProt) res.prot = mProt[1];
                    }
                    return JSON.stringify(res);
                })();";
            var rawDom = await _webView.ExecuteScriptAsync(domScript);
            if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;
            if (!string.IsNullOrWhiteSpace(rawDom) && rawDom != "null")
            {
                string jsonDom = rawDom;
                if (jsonDom.StartsWith("\"") && jsonDom.EndsWith("\""))
                {
                    try { jsonDom = JsonSerializer.Deserialize<string>(rawDom) ?? rawDom; } catch { }
                }
                using var doc = JsonDocument.Parse(jsonDom);
                var root = doc.RootElement;
                string? u = root.TryGetProperty("used", out var uE) ? uE.GetString() : null;
                string? a = root.TryGetProperty("avail", out var aE) ? aE.GetString() : null;
                string? b = root.TryGetProperty("bal", out var bE) ? bE.GetString() : null;
                string? p = root.TryGetProperty("prot", out var pE) ? pE.GetString() : null;
                if (CampusNetworkClient.Shared.ApplyExplicitDashboardData(u, a, b, p, accountGeneration))
                {
                    _statusText.Text = "✅ 成功提取自服务流量与余额！正在自动返回...";
                    await Task.Delay(1200);
                    AppEvents.InvokeOnUI(() =>
                    {
                        if (IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) Hide();
                    });
                    return;
                }
            }
        }
        catch { }
        if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;

        // 2. 备用 HTML 正则提取
        string rawHtml = await _webView.ExecuteScriptAsync("document.documentElement.outerHTML");
        if (!IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) return;
        if (!string.IsNullOrWhiteSpace(rawHtml) && rawHtml != "null")
        {
            string fullHtml = "";
            try
            {
                fullHtml = JsonSerializer.Deserialize<string>(rawHtml) ?? "";
            }
            catch
            {
                fullHtml = rawHtml.Trim('"');
            }

            if (CampusNetworkClient.Shared.ApplyParsedDashboardHTML(fullHtml, accountGeneration))
            {
                _statusText.Text = "✅ 成功提取自服务流量与在线设备！正在自动返回...";
                await Task.Delay(1200);
                AppEvents.InvokeOnUI(() =>
                {
                    if (IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration)) Hide();
                });
                return;
            }
        }

        if (manual && IsLoginWindowSessionCurrent(loginWindowSessionId, accountGeneration))
        {
            _statusText.Text = "⚠️ 未在当前页面识别到有效流量数据，请在登录后进入仪表盘重试";
        }
    }

    private bool IsLoginWindowSessionCurrent(Guid loginWindowSessionId, long accountGeneration) =>
        _loginWindowSessionId == loginWindowSessionId &&
        AccountSessionManager.IsGenerationCurrent(accountGeneration);

    private static string EscapeJs(string s) => s.Replace("\\", "\\\\").Replace("'", "\\'").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", "");
}

#endregion

#region Course Schedule Login Web Window

/// <summary>
/// 1:1 Windows WPF Port of CourseLoginWebViewController.swift.
/// Loads the EAMS Course Schedule page (http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table),
/// intercepts authentication cookies, fetches Datum JSON, and syncs course schedule & exams.
/// </summary>
public class CourseLoginWebWindow : Window
{
    private static CourseLoginWebWindow? _shared;
    public static CourseLoginWebWindow Shared => _shared ??= new CourseLoginWebWindow();

    public static void ClearAuthCookiesForAccountSwitch()
    {
        try { _shared?._webView.CoreWebView2?.CookieManager.DeleteAllCookies(); } catch { }
    }

    private readonly WebView2 _webView;
    private readonly TextBlock _statusText;
    private readonly Border _topBar;
    private readonly List<Button> _themeButtons = new();
    private long _accountSessionGenerationAtStart;
    private string? _pendingCasUsername;
    private string? _pendingCasPassword;

    public CourseLoginWebWindow()
    {
        Title = "教务课表与考试同步登录 - 合工大校园助手";
        Width = 976;
        Height = 720;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = ThemeManager.Shared.WindowBackground;

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        _topBar = new Border
        {
            Background = ThemeManager.Shared.TopBarBackground,
            Padding = new Thickness(14, 8, 14, 8),
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(0, 0, 0, 1)
        };
        var topDock = new DockPanel();

        var btnPanel = new StackPanel { Orientation = Orientation.Horizontal };
        DockPanel.SetDock(btnPanel, Dock.Right);

        var extractBtn = new Button
        {
            Content = "📚 从当前页直接提取课表与考试",
            Background = ThemeManager.Shared.Accent,
            Foreground = MediaBrushes.White,
            Padding = new Thickness(12, 5, 12, 5),
            FontSize = 12.5,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(6, 0, 0, 0),
            Cursor = Cursors.Hand,
            Tag = "Primary"
        };
        extractBtn.Click += async (_, _) => await TriggerInPageExtractionAsync();

        var goToTableBtn = new Button
        {
            Content = "📅 前往课表页",
            Background = ThemeManager.Shared.ControlBackground,
            Foreground = ThemeManager.Shared.TextPrimary,
            BorderBrush = ThemeManager.Shared.ControlBorderBrush,
            Padding = new Thickness(8, 5, 8, 5),
            FontSize = 12,
            Margin = new Thickness(6, 0, 0, 0),
            Cursor = Cursors.Hand,
            Tag = "Secondary"
        };
        goToTableBtn.Click += (_, _) =>
        {
            _webView.CoreWebView2?.Navigate("http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table");
        };

        var reloadBtn = new Button
        {
            Content = "🔄 重新登录",
            Background = ThemeManager.Shared.ControlBackground,
            Foreground = ThemeManager.Shared.TextPrimary,
            BorderBrush = ThemeManager.Shared.ControlBorderBrush,
            Padding = new Thickness(8, 5, 8, 5),
            FontSize = 12,
            Cursor = Cursors.Hand,
            Tag = "Secondary"
        };
        reloadBtn.Click += (_, _) => ShowWindow();

        btnPanel.Children.Add(reloadBtn);
        btnPanel.Children.Add(goToTableBtn);
        btnPanel.Children.Add(extractBtn);
        _themeButtons.Add(reloadBtn);
        _themeButtons.Add(goToTableBtn);
        _themeButtons.Add(extractBtn);
        topDock.Children.Add(btnPanel);

        _statusText = new TextBlock
        {
            Text = "正在连接信息门户统一身份认证，请登录后同步课表...",
            FontSize = 12,
            Foreground = ThemeManager.Shared.TextSecondary,
            VerticalAlignment = VerticalAlignment.Center
        };
        topDock.Children.Add(_statusText);
        _topBar.Child = topDock;

        Grid.SetRow(_topBar, 0);
        root.Children.Add(_topBar);

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
        ThemeManager.Shared.ApplyWindowTheme(this);
        ApplyTheme();
        ThemeManager.Shared.ThemeChanged += () => AppEvents.InvokeOnUI(ApplyTheme);
    }

    private void ApplyTheme()
    {
        ThemeManager.Shared.ApplyWindowTheme(this);
        Background = ThemeManager.Shared.WindowBackground;
        _topBar.Background = ThemeManager.Shared.TopBarBackground;
        _topBar.BorderBrush = ThemeManager.Shared.CardBorderBrush;
        _statusText.Foreground = ThemeManager.Shared.TextSecondary;
        foreach (var button in _themeButtons)
        {
            bool primary = Equals(button.Tag, "Primary");
            button.Background = primary ? ThemeManager.Shared.Accent : ThemeManager.Shared.ControlBackground;
            button.Foreground = primary ? MediaBrushes.White : ThemeManager.Shared.TextPrimary;
            button.BorderBrush = primary ? ThemeManager.Shared.Accent : ThemeManager.Shared.ControlBorderBrush;
        }
    }

    private bool _isExtracting = false;

    private async void InitWebView()
    {
        try
        {
            string userDataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HFUTCampusNet", "WebView2_Course");
            var env = await CoreWebView2Environment.CreateAsync(null, userDataDir);
            await _webView.EnsureCoreWebView2Async(env);
            _webView.CoreWebView2.NavigationCompleted += OnNavigationCompleted;
            _webView.CoreWebView2.WebMessageReceived += OnWebMessageReceived;
        }
        catch (Exception ex)
        {
            _statusText.Text = $"WebView2 初始化失败: {ex.Message}";
        }
    }

    public async void ShowWindow()
    {
        _isExtracting = false;
        _accountSessionGenerationAtStart = AccountSessionManager.Generation;
        _pendingCasUsername = null;
        _pendingCasPassword = null;
        if (WindowState == WindowState.Minimized)
            WindowState = WindowState.Normal;
        Show();
        Activate();

        await _webView.EnsureCoreWebView2Async();
        if (!AccountSessionManager.IsGenerationCurrent(_accountSessionGenerationAtStart)) return;
        _statusText.Text = "请登录教务系统（如已登录将自动同步课表与考试）...";
        // 对齐 Mac 端：直接导航至课表页，教务系统会自动无缝重定向到统一认证登录，登录后携票据自动跳回
        _webView.CoreWebView2.Navigate("http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table");
    }

    public void ShowLoginWindow() => ShowWindow();

    private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            if (!AccountSessionManager.IsGenerationCurrent(_accountSessionGenerationAtStart)) return;
            if (!Uri.TryCreate(e.Source, UriKind.Absolute, out var sourceUri)) return;

            bool sourceIsCasLoginPage = sourceUri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase) &&
                sourceUri.Host.Equals("cas.hfut.edu.cn", StringComparison.OrdinalIgnoreCase) &&
                sourceUri.AbsolutePath.Equals("/cas/login", StringComparison.OrdinalIgnoreCase);
            bool sourceIsEamsCourseTable =
                (sourceUri.Scheme.Equals("http", StringComparison.OrdinalIgnoreCase) ||
                 sourceUri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase)) &&
                sourceUri.Host.Equals("jxglstu.hfut.edu.cn", StringComparison.OrdinalIgnoreCase) &&
                (sourceUri.AbsolutePath.Equals("/eams5-student/for-std/course-table", StringComparison.OrdinalIgnoreCase) ||
                 sourceUri.AbsolutePath.StartsWith("/eams5-student/for-std/course-table/", StringComparison.OrdinalIgnoreCase));
            if (!sourceIsCasLoginPage && !sourceIsEamsCourseTable) return;

            string raw = e.TryGetWebMessageAsString();
            if (string.IsNullOrWhiteSpace(raw))
            {
                raw = e.WebMessageAsJson;
            }

            // 安全解包任何外层 JSON 字符串包裹
            while (raw.StartsWith("\"") && raw.EndsWith("\"") && raw.Length > 2)
            {
                try
                {
                    var unescaped = JsonSerializer.Deserialize<string>(raw);
                    if (string.IsNullOrEmpty(unescaped)) break;
                    raw = unescaped;
                }
                catch
                {
                    break;
                }
            }

            using var doc = JsonDocument.Parse(raw);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                _statusText.Text = "⚠️ 收到非对象消息";
                return;
            }

            if (root.TryGetProperty("type", out var typeElem))
            {
                var typeStr = typeElem.GetString();
                if (typeStr == "casCredentials")
                {
                    if (!sourceIsCasLoginPage) return;
                    string u = root.TryGetProperty("username", out var uE) ? uE.GetString() ?? "" : "";
                    string p = root.TryGetProperty("password", out var pE) ? pE.GetString() ?? "" : "";
                    bool submitted = root.TryGetProperty("submitted", out var submittedElem) &&
                        submittedElem.ValueKind == JsonValueKind.True;
                    if (!submitted) return;
                    if (!string.IsNullOrWhiteSpace(u)) _pendingCasUsername = u.Trim();
                    if (!string.IsNullOrWhiteSpace(p)) _pendingCasPassword = p.Trim();
                    return;
                }

                if (typeStr == "casLoginFailed")
                {
                    if (!sourceIsCasLoginPage) return;
                    _pendingCasUsername = null;
                    _pendingCasPassword = null;
                    return;
                }

                if (typeStr != "courseExtract")
                {
                    return;
                }
                if (!sourceIsEamsCourseTable) return;
            }
            else
            {
                return;
            }

            bool success = root.TryGetProperty("success", out var succElem) && succElem.GetBoolean();
            if (success)
            {
                CommitPendingCasCredentialsAfterAuthentication();
                var accountGeneration = _accountSessionGenerationAtStart;
                string stdId = root.TryGetProperty("stdId", out var sElem) ? sElem.GetString() ?? "" : "";
                string semId = root.TryGetProperty("semId", out var smElem) ? smElem.GetString() ?? "" : "";
                string bizId = root.TryGetProperty("bizId", out var bElem) ? bElem.GetString() ?? "" : "";

                string? gradeHtml = root.TryGetProperty("gradeHtml", out var ghE) ? ghE.GetString() : null;
                string? examHtml = root.TryGetProperty("examHtml", out var ehE) ? ehE.GetString() : null;
                string? derivedPwd = root.TryGetProperty("derivedUniAppPwd", out var dpE) ? dpE.GetString() : null;

                if (!string.IsNullOrWhiteSpace(derivedPwd))
                {
                    if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                    {
                        SettingsManager.Shared.JxglstuDefaultPasswordCache = derivedPwd.Trim();
                        SettingsManager.Shared.Save();
                    })) return;
                }

                CourseScheduleData? schedule = null;

                // 1. 优先通过 API datum JSON 还原
                if (root.TryGetProperty("datum", out var dElem) && !string.IsNullOrWhiteSpace(dElem.GetString()))
                {
                    string datum = dElem.GetString()!;
                    schedule = CourseScheduleService.Shared.ApplyDatumJSONString(
                        datum, stdId, semId, bizId, accountGeneration);
                }

                // 2. 兜底：通过页内 DOM 表格解析出的 lessons 数组还原
                if ((schedule == null || schedule.Lessons.Count == 0) && root.TryGetProperty("lessons", out var lessonsElem) && lessonsElem.ValueKind == JsonValueKind.Array)
                {
                    var parsedDomLessons = new List<CourseLesson>();
                    foreach (var item in lessonsElem.EnumerateArray())
                    {
                        var lesson = new CourseLesson
                        {
                            Id = item.TryGetProperty("id", out var idElem) ? idElem.GetString() ?? Guid.NewGuid().ToString("N") : Guid.NewGuid().ToString("N"),
                            CourseName = item.TryGetProperty("name", out var nElem) ? nElem.GetString() ?? "" : "",
                            CourseCode = item.TryGetProperty("code", out var cElem) ? cElem.GetString() : null,
                            Classroom = item.TryGetProperty("room", out var rElem) ? rElem.GetString() : null,
                            Teacher = item.TryGetProperty("teacher", out var tElem) ? tElem.GetString() : null,
                            Weekday = item.TryGetProperty("weekday", out var wElem) ? wElem.GetInt32() : 1,
                            StartUnit = item.TryGetProperty("startUnit", out var suElem) ? suElem.GetInt32() : 1,
                            EndUnit = item.TryGetProperty("endUnit", out var euElem) ? euElem.GetInt32() : 2,
                            DateString = item.TryGetProperty("dateString", out var dsElem) ? dsElem.GetString() ?? "" : "",
                            StartTime = item.TryGetProperty("startTime", out var stElem) ? stElem.GetInt32() : 800,
                            EndTime = item.TryGetProperty("endTime", out var etElem) ? etElem.GetInt32() : 940,
                            WeekIndex = item.TryGetProperty("weekIndex", out var wiElem) ? wiElem.GetInt32() : null,
                            WeekText = item.TryGetProperty("weekText", out var wtElem) ? wtElem.GetString() ?? "" : ""
                        };
                        if (!string.IsNullOrWhiteSpace(lesson.CourseName))
                        {
                            parsedDomLessons.Add(lesson);
                        }
                    }

                    if (parsedDomLessons.Count > 0)
                    {
                        string effectiveStdId = string.Empty;
                        string effectiveSemId = string.Empty;
                        string effectiveBizId = string.Empty;
                        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                        {
                            if (!string.IsNullOrEmpty(stdId)) SettingsManager.Shared.CourseStudentId = stdId;
                            if (!string.IsNullOrEmpty(semId)) SettingsManager.Shared.CourseSemesterId = semId;
                            if (!string.IsNullOrEmpty(bizId)) SettingsManager.Shared.CourseBizTypeId = bizId;
                            SettingsManager.Shared.Save();
                            effectiveStdId = SettingsManager.Shared.CourseStudentId;
                            effectiveSemId = SettingsManager.Shared.CourseSemesterId;
                            effectiveBizId = SettingsManager.Shared.CourseBizTypeId;
                        })) return;

                        int.TryParse(semId, out int sIdNum);
                        schedule = new CourseScheduleData
                        {
                            StudentId = effectiveStdId,
                            SemesterId = effectiveSemId,
                            SemesterName = CourseCalendarHelper.FormatSemesterName(sIdNum > 0 ? sIdNum : 354),
                            BizTypeId = effectiveBizId,
                            LastSyncTime = DateTime.Now,
                            Lessons = parsedDomLessons
                        };
                        CourseScheduleService.Shared.ApplyCustomSchedule(schedule, accountGeneration);
                    }
                }

                // 立即在 UI 线程同步 Cookie
                _ = SyncAllCookiesAsync();

                // 立即就地应用同源提取到的成绩单和考场排考
                if (!string.IsNullOrWhiteSpace(gradeHtml) || !string.IsNullOrWhiteSpace(examHtml))
                {
                    AcademicService.Shared.ApplyWebGradeAndExamHtml(
                        gradeHtml, examHtml, accountGeneration);
                }

                if (schedule != null && schedule.Lessons.Count > 0)
                {
                    _statusText.Text = $"🎉 成功同步 {schedule.Lessons.Count} 节课程！正在同步期末考试、成绩单与空教室...";
                    
                    _ = Task.Run(async () =>
                    {
                        try
                        {
                            await EmptyClassroomService.Shared.EnsureValidTokenAsync(
                                forceRelogin: true,
                                expectedAccountGeneration: accountGeneration);
                            if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return;
                            EmptyClassroomService.Shared.SyncTodayAndTomorrowStudyRooms(forceRefresh: true);
                            AcademicService.Shared.SyncAll(silent: false, expectedAccountGeneration: accountGeneration);
                        }
                        catch { }
                    });

                    TrayMenuController.Shared.ShowNotification("🎉 教务数据全量同步成功", $"已成功同步本学期 {schedule.Lessons.Count} 节课、期末排考及全学期成绩！");
                    Task.Delay(1500).ContinueWith(_ => AppEvents.InvokeOnUI(Hide));
                    return;
                }
                else
                {
                    _statusText.Text = "⚠️ 提取到的排课数据为空，请确认当前学期是否已排课";
                }
            }
            else
            {
                string errMsg = root.TryGetProperty("error", out var errElem) ? errElem.GetString() ?? "未知错误" : "提取失败";
                _statusText.Text = $"⚠️ 提取提示: {errMsg}";
            }
        }
        catch (Exception ex)
        {
            _statusText.Text = $"⚠️ 课表消息解析异常: {ex.Message}";
        }
    }

    private void CommitPendingCasCredentialsAfterAuthentication()
    {
        var username = _pendingCasUsername;
        var password = _pendingCasPassword;
        _pendingCasUsername = null;
        _pendingCasPassword = null;
        if (username == null && password == null) return;

        var settings = SettingsManager.Shared;
        var previousUsername = (settings.PortalUsername ?? string.Empty).Trim();
        var currentUsername = username ?? previousUsername;
        if (!string.Equals(previousUsername, currentUsername, StringComparison.Ordinal))
        {
            AccountSessionManager.InvalidateForAccountSwitch(
                currentUsername,
                preserveCourseWebViewCookies: true
            );
        }

        var accountGeneration = AccountSessionManager.Generation;
        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
        {
            settings.PortalUsername = currentUsername;
            if (password != null) settings.CasPassword = password;
            settings.Save();
        })) return;
        _accountSessionGenerationAtStart = accountGeneration;
    }

    private async void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (!AccountSessionManager.IsGenerationCurrent(_accountSessionGenerationAtStart)) return;
        if (!e.IsSuccess) return;

        string currentUrl = _webView.Source?.ToString() ?? "";
        if (!Uri.TryCreate(currentUrl, UriKind.Absolute, out var currentUri)) return;
        bool isCasLoginPage = currentUri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase) &&
            currentUri.Host.Equals("cas.hfut.edu.cn", StringComparison.OrdinalIgnoreCase) &&
            currentUri.AbsolutePath.Equals("/cas/login", StringComparison.OrdinalIgnoreCase);
        bool isEamsPage = currentUri.Host.Equals("jxglstu.hfut.edu.cn", StringComparison.OrdinalIgnoreCase) &&
            (currentUri.AbsolutePath.Equals("/eams5-student", StringComparison.OrdinalIgnoreCase) ||
             currentUri.AbsolutePath.StartsWith("/eams5-student/", StringComparison.OrdinalIgnoreCase));
        _statusText.Text = $"当前页面: {currentUrl}";

        // 1. 处于信息门户统一身份认证登录页，自动填充账号与密码并自动登录
        if (isCasLoginPage)
        {
            _statusText.Text = "请登录信息门户（已自动填充账号密码，登录后将自动进入教务并同步课表）...";
            string username = string.Empty;
            string password = string.Empty;
            if (!AccountSessionManager.TryRunForGeneration(_accountSessionGenerationAtStart, () =>
            {
                username = SettingsManager.Shared.PortalUsername;
                password = !string.IsNullOrWhiteSpace(SettingsManager.Shared.CasPassword)
                    ? SettingsManager.Shared.CasPassword
                    : SettingsManager.Shared.PortalPassword;
            })) return;

            if (!string.IsNullOrEmpty(username) && !string.IsNullOrEmpty(password))
            {
                string fillScript = $@"
                    (function() {{
                        var tries = 0;
                        function setVal(input, val) {{
                            if (!input || !val) return;
                            var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set;
                            if (setter) {{ setter.call(input, val); }} else {{ input.value = val; }}
                            input.dispatchEvent(new Event('input', {{ bubbles: true }}));
                            input.dispatchEvent(new Event('change', {{ bubbles: true }}));
                            input.dispatchEvent(new Event('blur', {{ bubbles: true }}));
                        }}
                        var timer = setInterval(function() {{
                            tries++;
                            var u = document.getElementById('username') || document.getElementById('u') || document.querySelector('input[name=""username""]') || document.querySelector('input[type=""text""]');
                            var p = document.getElementById('pwd') || document.querySelector('input[type=""password""]:not([type=""hidden""])') || document.querySelector('input[type=""password""]') || document.querySelector('input.password');

                            function reportCreds(submitted) {{
                                var uVal = u ? u.value.trim() : '';
                                var pVal = p ? p.value : '';
                                if ((uVal !== '' || pVal !== '') && window.chrome && window.chrome.webview) {{
                                    window.chrome.webview.postMessage(JSON.stringify({{ type: 'casCredentials', username: uVal, password: pVal, submitted: submitted === true }}));
                                }}
                            }}

                            if (u && !u._hfutBound) {{
                                u._hfutBound = true;
                                u.addEventListener('input', function() {{ reportCreds(false); }});
                                u.addEventListener('change', function() {{ reportCreds(false); }});
                                u.addEventListener('blur', function() {{ reportCreds(false); }});
                            }}
                            if (p && !p._hfutBound) {{
                                p._hfutBound = true;
                                p.addEventListener('input', function() {{ reportCreds(false); }});
                                p.addEventListener('change', function() {{ reportCreds(false); }});
                                p.addEventListener('blur', function() {{ reportCreds(false); }});
                            }}

                            var btn = document.getElementById('sb2') || document.querySelector('.button-submit') || document.querySelector('input[type=""submit""]');
                            if (btn && !btn._hfutCredentialBound) {{
                                btn._hfutCredentialBound = true;
                                btn.addEventListener('click', function() {{ reportCreds(true); }}, true);
                            }}
                            var form = (u && u.form) || (p && p.form) || document.querySelector('form');
                            if (form && !form._hfutCredentialBound) {{
                                form._hfutCredentialBound = true;
                                form.addEventListener('submit', function() {{ reportCreds(true); }}, true);
                            }}

                            if (u && !u.value) {{
                                setVal(u, '{EscapeJs(username)}');
                            }}
                            if (p && !p.value) {{
                                setVal(p, '{EscapeJs(password)}');
                            }}
                            if ((u && u.value && p && p.value) || tries > 25) {{
                                clearInterval(timer);
                                // 自动提交登录（若无错误信息且无验证码拦截）
                                setTimeout(function() {{
                                    var errU = document.getElementById('errorusername');
                                    var errP = document.getElementById('errorpassword');
                                    var errG = document.getElementById('error');
                                    var hasErr = (errU && errU.innerText.trim() !== '') || (errP && errP.innerText.trim() !== '') || (errG && errG.innerText.trim() !== '');
                                    var needCode = (typeof isCodeShow !== 'undefined' && isCodeShow) || (typeof isDynamicVercode !== 'undefined' && isDynamicVercode);
                                    if (hasErr && window.chrome && window.chrome.webview) {{
                                        window.chrome.webview.postMessage(JSON.stringify({{ type: 'casLoginFailed' }}));
                                    }}
                                    if (!hasErr && !needCode && u && u.value && p && p.value && btn) {{
                                        btn.click();
                                    }}
                                }}, 350);
                            }}
                        }}, 200);
                    }})();";
                await _webView.ExecuteScriptAsync(fillScript);
            }
            return;
        }

        // 2. 处于教务 SSO 换票据页面，等待其自动建立 Session 并跳转
        if (isEamsPage && currentUri.AbsolutePath.Contains("neusoft-sso", StringComparison.OrdinalIgnoreCase))
        {
            _statusText.Text = "🎉 信息门户认证通过！正在建立教务系统会话...";
            CommitPendingCasCredentialsAfterAuthentication();
            await SyncAllCookiesAsync();
            if (!AccountSessionManager.IsGenerationCurrent(_accountSessionGenerationAtStart)) return;
            return;
        }

        // 3. 若处于教务系统其它页面（例如首页），平滑导航前往课表页，同时记录 Cookie
        if (isEamsPage)
        {
            CommitPendingCasCredentialsAfterAuthentication();
            await SyncAllCookiesAsync();
            if (!AccountSessionManager.IsGenerationCurrent(_accountSessionGenerationAtStart)) return;

            // 从重定向 URL 提取真实 studentId
            var matchId = Regex.Match(currentUrl, @"/for-std/course-table/info/(\d+)");
            if (matchId.Success)
            {
                if (!AccountSessionManager.TryRunForGeneration(_accountSessionGenerationAtStart, () =>
                {
                    SettingsManager.Shared.CourseStudentId = matchId.Groups[1].Value;
                    SettingsManager.Shared.Save();
                })) return;
            }

            if (!string.IsNullOrEmpty(SettingsManager.Shared.CourseSessionCookie))
            {
                _ = Task.Run(async () =>
                {
                    try
                    {
                        await EmptyClassroomService.Shared.EnsureValidTokenAsync(
                            forceRelogin: true,
                            expectedAccountGeneration: _accountSessionGenerationAtStart);
                        if (!AccountSessionManager.IsGenerationCurrent(_accountSessionGenerationAtStart)) return;
                        EmptyClassroomService.Shared.SyncTodayAndTomorrowStudyRooms(forceRefresh: true, null);
                        AcademicService.Shared.SyncAll(
                            silent: false,
                            expectedAccountGeneration: _accountSessionGenerationAtStart);
                    }
                    catch { }
                });
            }

            if (!currentUrl.Contains("/for-std/course-table"))
            {
                _statusText.Text = "🎉 教务会话已就绪！正在前往学生课表页...";
                await Task.Delay(500);
                if (!AccountSessionManager.IsGenerationCurrent(_accountSessionGenerationAtStart)) return;
                _webView.CoreWebView2.Navigate("http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table");
                return;
            }
        }

        // 4. 若已处于课表页，延迟等待 DOM 与组件渲染稳定后自动提取
        if (currentUrl.Contains("/for-std/course-table"))
        {
            await Task.Delay(800);
            await TriggerInPageExtractionAsync();
        }
    }

    private async Task SyncAllCookiesAsync()
    {
        try
        {
            long accountGeneration = _accountSessionGenerationAtStart;
            if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return;
            if (_webView.CoreWebView2 == null) return;

            string? sessionVal = null;
            string? srvidVal = null;
            string? tgcVal = null;

            // 1. 尝试从教务系统各级路径读取 Cookie（RFC 规范必须匹配 Path）
            var curUrl = _webView.Source?.ToString() ?? "";
            var eamsUrls = new List<string>();
            if (!string.IsNullOrWhiteSpace(curUrl)) eamsUrls.Add(curUrl);
            eamsUrls.Add("http://jxglstu.hfut.edu.cn/eams5-student/for-std/course-table");
            eamsUrls.Add("http://jxglstu.hfut.edu.cn/eams5-student/");
            eamsUrls.Add("http://jxglstu.hfut.edu.cn/");

            foreach (var url in eamsUrls)
            {
                try
                {
                    var cookies = await _webView.CoreWebView2.CookieManager.GetCookiesAsync(url);
                    if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return;
                    foreach (var c in cookies)
                    {
                        if (c.Name.Equals("SESSION", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(c.Value))
                            sessionVal ??= c.Value;
                        if (c.Name.Equals("SRVID", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(c.Value))
                            srvidVal ??= c.Value;
                    }
                }
                catch { }
                if (!string.IsNullOrEmpty(sessionVal)) break;
            }

            // 2. 尝试从 CAS 页面读取 CASTGC
            var casUrls = new[] { "https://cas.hfut.edu.cn/cas/login", "https://cas.hfut.edu.cn/cas/", "https://cas.hfut.edu.cn/" };
            foreach (var url in casUrls)
            {
                try
                {
                    var cookies = await _webView.CoreWebView2.CookieManager.GetCookiesAsync(url);
                    if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return;
                    var tgc = cookies.FirstOrDefault(c => c.Name.Equals("CASTGC", StringComparison.OrdinalIgnoreCase) || c.Name.Equals("TGC", StringComparison.OrdinalIgnoreCase));
                    if (tgc != null && !string.IsNullOrWhiteSpace(tgc.Value))
                    {
                        tgcVal = tgc.Value;
                        break;
                    }
                }
                catch { }
            }

            // 3. 兜底：从 document.cookie 读取
            if (string.IsNullOrEmpty(sessionVal))
            {
                try
                {
                    var rawDocCookie = await _webView.ExecuteScriptAsync("document.cookie");
                    if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return;
                    if (!string.IsNullOrWhiteSpace(rawDocCookie) && rawDocCookie != "null")
                    {
                        var clean = rawDocCookie.Trim('"');
                        var mS = Regex.Match(clean, @"SESSION=([^;]+)");
                        if (mS.Success) sessionVal = mS.Groups[1].Value;
                        var mSr = Regex.Match(clean, @"SRVID=([^;]+)");
                        if (mSr.Success) srvidVal = mSr.Groups[1].Value;
                    }
                }
                catch { }
            }

            if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
            {
                if (!string.IsNullOrEmpty(sessionVal))
                {
                    var cookieHeader = !string.IsNullOrEmpty(srvidVal)
                        ? $"SESSION={sessionVal}; SRVID={srvidVal}"
                        : $"SESSION={sessionVal}";
                    SettingsManager.Shared.CourseSessionCookie = cookieHeader;
                }

                if (!string.IsNullOrEmpty(tgcVal))
                    SettingsManager.Shared.CasTgcCookie = tgcVal;

                SettingsManager.Shared.Save();
            })) return;
            AppEvents.RaiseAuthStatusUpdated();
        }
        catch { }
    }

    public async Task TriggerInPageExtractionAsync()
    {
        long accountGeneration = _accountSessionGenerationAtStart;
        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return;
        if (_webView.CoreWebView2 == null) return;
        if (_isExtracting) return;
        _isExtracting = true;
        _statusText.Text = "⏳ 正在通过页面上下文提取课表、考试与成绩数据...";

        // 1. 同步 Cookie 至 SettingsManager
        await SyncAllCookiesAsync();
        if (!AccountSessionManager.IsGenerationCurrent(accountGeneration))
        {
            _isExtracting = false;
            return;
        }

        // 2. 双引擎页内提取：引擎 1 (官方 API) + 引擎 2 (DOM 视觉扫描)
        try
        {
            string runnerScript = @"
                (function() {
                    window.__hfutExtractor = {
                        status: 'running',
                        logs: [],
                        result: null,
                        error: null
                    };
                    function log(msg) {
                        if (window.__hfutExtractor && window.__hfutExtractor.logs) {
                            window.__hfutExtractor.logs.push(msg);
                        }
                    }

                    async function runExtraction() {
                        try {
                            log('启动教务双通道全量数据提取器');
                            var stdId = '';
                            var semId = '354';
                            var bizId = '23';
                            var gradeHtml = '';
                            var examHtml = '';
                            var derivedUniAppPwd = '';
                            
                            // ----------------- 引擎 1：官方 API 上下文同源提取 -----------------
                            try {
                                log('正在探测 API 所需参数 (stdId, semId, bizId)...');
                                var html = document.documentElement ? document.documentElement.outerHTML : '';
                                var stdMatch = window.location.pathname.match(/\/for-std\/course-table\/info\/(\d+)/) ||
                                               window.location.search.match(/studentId=(\d+)/) ||
                                               html.match(/\/for-std\/course-table\/info\/(\d+)/) ||
                                               html.match(/var\s+studentId\s*=\s*(\d+)/) ||
                                               html.match(/studentId\s*[:=]\s*[""']?(\d+)/) ||
                                               html.match(/dataId\s*[:=]\s*[""']?(\d+)/);
                                if (stdMatch) stdId = stdMatch[1];

                                var semSelect = document.getElementById('allSemesters') || document.querySelector('select');
                                var semMatch = html.match(/'fileInfoAssoc'\s*:\s*null\s*,\s*'id'\s*:\s*(\d+)/) || html.match(/semesterId\s*[:=]\s*[""']?(\d+)/);
                                if (semSelect && semSelect.value) semId = semSelect.value;
                                else if (semMatch) semId = semMatch[1];

                                var bizMatch = html.match(/bizTypeId\s*[:=]\s*[""']?(\d+)/);
                                if (bizMatch) bizId = bizMatch[1];

                                if (!stdId) {
                                    log('stdId 缺失，尝试读取 /eams5-student/for-std/course-table 页面...');
                                    try {
                                        var tableResp = await fetch('/eams5-student/for-std/course-table', { credentials: 'include' });
                                        var urlStd = (tableResp.url || '').match(/\/for-std\/course-table\/info\/(\d+)/);
                                        if (urlStd) {
                                            stdId = urlStd[1];
                                        } else {
                                            var tableHtml = await tableResp.text();
                                            var htmlStd = tableHtml.match(/\/for-std\/course-table\/info\/(\d+)/) || tableHtml.match(/var\s+studentId\s*=\s*(\d+)/);
                                            if (htmlStd) stdId = htmlStd[1];
                                        }
                                    } catch(e) {
                                        log('获取课表重定向页面失败: ' + e.message);
                                    }
                                }

                                if (stdId) {
                                    log('成功定位参数 stdId=' + stdId + ', semId=' + semId + ', bizId=' + bizId);

                                    // 同源并发抓取：成绩单、考场安排与学生学籍信息（用于推导 UniApp 密码）
                                    var gradePromise = fetch('/eams5-student/for-std/grade/sheet/info/' + stdId + '?semester=', { credentials: 'include' }).then(function(r){ return r.text(); }).catch(function(){ return ''; });
                                    var examPromise = fetch('/eams5-student/for-std/exam-arrange/info/' + stdId, { credentials: 'include' }).then(function(r){ return r.text(); }).catch(function(){ return ''; });
                                    var stdInfoPromise = fetch('/eams5-student/for-std/student-info/info/' + stdId, { credentials: 'include' }).then(function(r){ return r.text(); }).catch(function(){ return ''; });

                                    var getDataUrl = '/eams5-student/for-std/course-table/get-data?bizTypeId=' + bizId + '&semesterId=' + semId + '&dataId=' + stdId;
                                    var getDataResp = await fetch(getDataUrl, {
                                        credentials: 'include',
                                        headers: { 'Accept': 'application/json, text/javascript, */*; q=0.01' }
                                    });
                                    var getDataJson = await getDataResp.json();
                                    var lessonIds = getDataJson.lessonIds || [];
                                    log('获取到 lessonIds 数组长度: ' + lessonIds.length);

                                    gradeHtml = await gradePromise;
                                    examHtml = await examPromise;
                                    var stdInfoHtml = await stdInfoPromise;
                                    if (stdInfoHtml) {
                                        var mId = stdInfoHtml.match(/\b([1-9]\d{5}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx])\b/) || stdInfoHtml.match(/证件号[^\r\n0-9]*([0-9Xx]{18})/);
                                        if (mId) derivedUniAppPwd = mId[1].slice(-6);
                                    }

                                    if (lessonIds.length > 0) {
                                        var datumResp = await fetch('/eams5-student/ws/schedule-table/datum', {
                                            method: 'POST',
                                            credentials: 'include',
                                            headers: { 'Content-Type': 'application/json;charset=UTF-8' },
                                            body: JSON.stringify({ lessonIds: lessonIds, studentId: parseInt(stdId, 10), weekIndex: '' })
                                        });
                                        var datumText = await datumResp.text();
                                        if (datumText && datumText.indexOf('scheduleList') !== -1) {
                                            log('API 提取成功，已获取完整 datum 数据');
                                            window.__hfutExtractor.status = 'success';
                                            window.__hfutExtractor.engine = 'api';
                                            window.__hfutExtractor.result = {
                                                stdId: stdId,
                                                semId: semId,
                                                bizId: bizId,
                                                datum: datumText,
                                                gradeHtml: gradeHtml,
                                                examHtml: examHtml,
                                                derivedUniAppPwd: derivedUniAppPwd
                                            };
                                            if (window.chrome && window.chrome.webview) {
                                                window.chrome.webview.postMessage(JSON.stringify({
                                                    type: 'courseExtract',
                                                    success: true,
                                                    stdId: stdId,
                                                    semId: semId,
                                                    bizId: bizId,
                                                    datum: datumText,
                                                    gradeHtml: gradeHtml,
                                                    examHtml: examHtml,
                                                    derivedUniAppPwd: derivedUniAppPwd
                                                }));
                                            }
                                            return;
                                        }
                                    }
                                }
                            } catch(apiEx) {
                                log('API 引擎探测未通过: ' + apiEx.message + '，无缝切换至 DOM 视觉提取引擎');
                            }

                            // ----------------- 引擎 2：DOM 视觉与几何碰撞提取 -----------------
                            log('正在执行 DOM 视觉扫描...');
                            var allText = document.body ? document.body.innerText : '';
                            var startMonday = '2026-09-07';
                            var mDate = allText.match(/起始日期[：:\s]*(\d{4}-\d{2}-\d{2})/);
                            if (mDate) startMonday = mDate[1];

                            var dayCols = [];
                            var days = ['一', '二', '三', '四', '五', '六', '日'];
                            var allElements = document.querySelectorAll('th, td, div, span');
                            for (var d = 0; d < 7; d++) {
                                var tTarget = '星期' + days[d];
                                for (var i = 0; i < allElements.length; i++) {
                                    var el = allElements[i];
                                    var t = (el.innerText || '').trim();
                                    if (t === tTarget || t === '周' + days[d]) {
                                        var r = el.getBoundingClientRect();
                                        if (r.width > 20 && r.height > 10) {
                                            dayCols.push({ weekday: d + 1, left: r.left, right: r.right, centerX: (r.left + r.right) / 2 });
                                            break;
                                        }
                                    }
                                }
                            }
                            log('找到星期列数: ' + dayCols.length);

                            var unitRows = [];
                            for (var u = 1; u <= 12; u++) {
                                for (var i = 0; i < allElements.length; i++) {
                                    var el = allElements[i];
                                    var t = (el.innerText || '').trim();
                                    var tokens = t.split(/[\r\n\s]+/).filter(Boolean);
                                    if (tokens.indexOf(String(u)) !== -1 && tokens.length <= 4) {
                                        var r = el.getBoundingClientRect();
                                        if (r.width > 5 && r.width < 90 && r.height > 10) {
                                            unitRows.push({ unit: u, top: r.top, bottom: r.bottom, centerY: (r.top + r.bottom) / 2 });
                                            break;
                                        }
                                    }
                                }
                            }
                            log('找到节次行数: ' + unitRows.length);

                            var startTimes = { 1: 800, 2: 900, 3: 1010, 4: 1110, 5: 1400, 6: 1500, 7: 1600, 8: 1700, 9: 1900, 10: 2000, 11: 2100, 12: 2200 };
                            var endTimes = { 1: 850, 2: 950, 3: 1100, 4: 1200, 5: 1450, 6: 1550, 7: 1650, 8: 1750, 9: 1950, 10: 2050, 11: 2150, 12: 2250 };

                            var codeRegex = /[0-9A-Za-z]{6,12}(?:--\d{1,4})?/g;
                            var candidates = document.querySelectorAll('div, td, li');
                            var rawCards = [];

                            for (var i = 0; i < candidates.length; i++) {
                                var el = candidates[i];
                                var txt = (el.innerText || '').trim();
                                if (!txt || txt.length < 5 || txt.length > 500) continue;

                                var matches = txt.match(codeRegex);
                                if (matches && matches.length === 1) {
                                    var hasChildMatch = false;
                                    for (var c = 0; c < el.children.length; c++) {
                                        var cTxt = (el.children[c].innerText || '').trim();
                                        var cMatches = cTxt.match(codeRegex);
                                        if (cMatches && cMatches.length === 1) {
                                            hasChildMatch = true;
                                            break;
                                        }
                                    }
                                    if (!hasChildMatch) {
                                        var cr = el.getBoundingClientRect();
                                        if (cr.width > 15 && cr.height > 15) {
                                            rawCards.push({ el: el, text: txt, code: matches[0], rect: cr });
                                        }
                                    }
                                }
                            }
                            log('扫描到独立课程卡片候选: ' + rawCards.length);

                            var lessons = [];
                            var seen = {};

                            for (var i = 0; i < rawCards.length; i++) {
                                var card = rawCards[i];
                                var lines = card.text.split(/[\r\n]+/).map(function(s) { return s.trim(); }).filter(Boolean);
                                var code = card.code;
                                var name = lines.find(function(l) {
                                    return l !== code && !l.match(/^\d+$/) && !l.match(/^\d+~\d+周/) && !l.match(/^(星期|周)/);
                                }) || code;

                                var cx = (card.rect.left + card.rect.right) / 2;
                                var cy = card.rect.top + 8;

                                var weekday = 1;
                                if (dayCols.length > 0) {
                                    var minDx = 999999;
                                    for (var d = 0; d < dayCols.length; d++) {
                                        if (cx >= dayCols[d].left - 5 && cx <= dayCols[d].right + 5) {
                                            weekday = dayCols[d].weekday;
                                            minDx = 0;
                                            break;
                                        }
                                        var diff = Math.abs(cx - dayCols[d].centerX);
                                        if (diff < minDx) {
                                            minDx = diff;
                                            weekday = dayCols[d].weekday;
                                        }
                                    }
                                }

                                var startUnit = 1;
                                if (unitRows.length > 0) {
                                    var minDy = 999999;
                                    for (var u = 0; u < unitRows.length; u++) {
                                        if (cy >= unitRows[u].top - 6 && cy <= unitRows[u].bottom + 6) {
                                            startUnit = unitRows[u].unit;
                                            minDy = 0;
                                            break;
                                        }
                                        var diff = Math.abs(cy - unitRows[u].centerY);
                                        if (diff < minDy) {
                                            minDy = diff;
                                            startUnit = unitRows[u].unit;
                                        }
                                    }
                                }

                                var spanUnits = 2;
                                if (card.rect.height < 50) spanUnits = 1;
                                else if (card.rect.height > 110) spanUnits = 3;
                                var endUnit = Math.min(12, startUnit + spanUnits - 1);

                                var dedupeKey = code + '_' + name + '_' + weekday + '_' + startUnit;
                                if (seen[dedupeKey]) continue;
                                seen[dedupeKey] = true;

                                var locPart = lines.slice(lines.indexOf(name) + 1).join(' ');
                                var weeks = [];
                                var regW = /(\d+)(?:~(\d+))?周/g;
                                var mw;
                                while ((mw = regW.exec(locPart)) !== null) {
                                    var ws = parseInt(mw[1], 10);
                                    var we = mw[2] ? parseInt(mw[2], 10) : ws;
                                    for (var w = ws; w <= we; w++) {
                                        if (weeks.indexOf(w) === -1) weeks.push(w);
                                    }
                                }
                                if (weeks.length === 0) {
                                    for (var w = 1; w <= 16; w++) weeks.push(w);
                                }

                                lessons.push({
                                    code: code,
                                    name: name,
                                    room: locPart,
                                    weekday: weekday,
                                    startUnit: startUnit,
                                    endUnit: endUnit,
                                    startTime: startTimes[startUnit] || (800 + (startUnit - 1) * 100),
                                    endTime: endTimes[endUnit] || (850 + (endUnit - 1) * 100),
                                    weeks: weeks
                                });
                            }

                            log('DOM 解析完成，有效课程数: ' + lessons.length);
                            if (lessons.length > 0) {
                                window.__hfutExtractor.status = 'success';
                                window.__hfutExtractor.engine = 'dom';
                                window.__hfutExtractor.result = {
                                    startMonday: startMonday,
                                    lessons: lessons,
                                    stdId: stdId,
                                    semId: semId,
                                    bizId: bizId,
                                    gradeHtml: gradeHtml,
                                    examHtml: examHtml,
                                    derivedUniAppPwd: derivedUniAppPwd
                                };
                                if (window.chrome && window.chrome.webview) {
                                    window.chrome.webview.postMessage(JSON.stringify({
                                        type: 'courseExtract',
                                        success: true,
                                        startMonday: startMonday,
                                        lessons: lessons,
                                        stdId: stdId,
                                        semId: semId,
                                        bizId: bizId,
                                        gradeHtml: gradeHtml,
                                        examHtml: examHtml,
                                        derivedUniAppPwd: derivedUniAppPwd
                                    }));
                                }
                                return;
                            }

                            window.__hfutExtractor.status = 'error';
                            window.__hfutExtractor.error = '未能通过 DOM 解析出排课数据 (未匹配到有效卡片)';
                        } catch(err) {
                            log('提取器异常: ' + err.message);
                            window.__hfutExtractor.status = 'error';
                            window.__hfutExtractor.error = err.message;
                        }
                    }

                    runExtraction();
                })();";

            await _webView.ExecuteScriptAsync(runnerScript);

            // 轮询 window.__hfutExtractor 状态，最多 35 次 * 120ms = 4.2 秒
            for (int attempt = 0; attempt < 35; attempt++)
            {
                await Task.Delay(120);

                string pollJs = @"(function() {
                    if (!window.__hfutExtractor) return '';
                    return JSON.stringify(window.__hfutExtractor);
                })()";

                string pollRes = await _webView.ExecuteScriptAsync(pollJs);
                if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return;
                if (string.IsNullOrWhiteSpace(pollRes) || pollRes == "\"\"" || pollRes == "null")
                    continue;

                string jsonStr = pollRes;
                if (jsonStr.StartsWith("\"") && jsonStr.EndsWith("\""))
                {
                    try { jsonStr = JsonSerializer.Deserialize<string>(pollRes) ?? pollRes; } catch { }
                }

                using var doc = JsonDocument.Parse(jsonStr);
                var root = doc.RootElement;
                if (!root.TryGetProperty("status", out var statusElem))
                    continue;

                string status = statusElem.GetString() ?? "";
                if (status == "running")
                {
                    continue; // 仍在执行，继续轮询
                }

                if (status == "success" && root.TryGetProperty("result", out var resElem))
                {
                    string engine = root.TryGetProperty("engine", out var engElem) ? engElem.GetString() ?? "" : "";
                    CourseScheduleData? schedule = null;

                    string? gradeHtml = resElem.TryGetProperty("gradeHtml", out var ghE) ? ghE.GetString() : null;
                    string? examHtml = resElem.TryGetProperty("examHtml", out var ehE) ? ehE.GetString() : null;
                    string? derivedPwd = resElem.TryGetProperty("derivedUniAppPwd", out var dpE) ? dpE.GetString() : null;

                    if (!string.IsNullOrWhiteSpace(derivedPwd))
                    {
                        if (!AccountSessionManager.TryRunForGeneration(accountGeneration, () =>
                        {
                            SettingsManager.Shared.JxglstuDefaultPasswordCache = derivedPwd.Trim();
                            SettingsManager.Shared.Save();
                        })) return;
                    }

                    if (engine == "api")
                    {
                        string datum = resElem.TryGetProperty("datum", out var dElem) ? dElem.GetString() ?? "" : "";
                        string stdId = resElem.TryGetProperty("stdId", out var sElem) ? sElem.GetString() ?? "" : "";
                        string semId = resElem.TryGetProperty("semId", out var smElem) ? smElem.GetString() ?? "" : "";
                        string bizId = resElem.TryGetProperty("bizId", out var bElem) ? bElem.GetString() ?? "" : "";

                        schedule = CourseScheduleService.Shared.ApplyDatumJSONString(
                            datum, stdId, semId, bizId, accountGeneration);
                    }
                    else if (engine == "dom" && resElem.TryGetProperty("lessons", out var lesArr) && lesArr.ValueKind == JsonValueKind.Array)
                    {
                        string startMonday = resElem.TryGetProperty("startMonday", out var smElem) ? smElem.GetString() ?? "2026-09-07" : "2026-09-07";
                        DateTime.TryParseExact(startMonday, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var mondayDate);
                        if (mondayDate == default) mondayDate = new DateTime(2026, 9, 7);

                        var allParsedLessons = new List<CourseLesson>();
                        int idx = 0;
                        foreach (var item in lesArr.EnumerateArray())
                        {
                            string code = item.GetProperty("code").GetString() ?? "";
                            string name = item.GetProperty("name").GetString() ?? "";
                            string room = item.GetProperty("room").GetString() ?? "";
                            int weekday = item.GetProperty("weekday").GetInt32();
                            int startUnit = item.GetProperty("startUnit").GetInt32();
                            int endUnit = item.GetProperty("endUnit").GetInt32();
                            int startTime = item.GetProperty("startTime").GetInt32();
                            int endTime = item.GetProperty("endTime").GetInt32();

                            var weeks = new List<int>();
                            if (item.TryGetProperty("weeks", out var wArr) && wArr.ValueKind == JsonValueKind.Array)
                            {
                                foreach (var wv in wArr.EnumerateArray()) weeks.Add(wv.GetInt32());
                            }
                            if (weeks.Count == 0) weeks.Add(1);

                            foreach (var w in weeks)
                            {
                                var classDate = mondayDate.AddDays((w - 1) * 7 + (weekday - 1));
                                allParsedLessons.Add(new CourseLesson
                                {
                                    Id = $"{code}-{w}-{weekday}-{startUnit}-{idx++}",
                                    CourseName = name,
                                    CourseCode = code,
                                    Classroom = room,
                                    Weekday = weekday,
                                    WeekIndex = w,
                                    StartUnit = startUnit,
                                    EndUnit = endUnit,
                                    StartTime = startTime,
                                    EndTime = endTime,
                                    DateString = classDate.ToString("yyyy-MM-dd")
                                });
                            }
                        }

                        if (allParsedLessons.Count > 0)
                        {
                            schedule = new CourseScheduleData
                            {
                                StudentId = SettingsManager.Shared.CourseStudentId,
                                SemesterId = SettingsManager.Shared.CourseSemesterId,
                                SemesterName = "2026-2027学年 第一学期",
                                BizTypeId = SettingsManager.Shared.CourseBizTypeId,
                                LastSyncTime = DateTime.Now,
                                Lessons = allParsedLessons
                            };
                            CourseScheduleService.Shared.ApplyCustomSchedule(schedule, accountGeneration);
                        }
                    }

                    // 立即在 UI 线程同步 Cookie
                    await SyncAllCookiesAsync();
                    if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return;

                    // 立即就地应用同源提取到的成绩单和考场排考
                    if (!string.IsNullOrWhiteSpace(gradeHtml) || !string.IsNullOrWhiteSpace(examHtml))
                    {
                        AcademicService.Shared.ApplyWebGradeAndExamHtml(gradeHtml, examHtml, accountGeneration);
                    }

                    if (schedule != null && schedule.Lessons.Count > 0)
                    {
                        AppEvents.RaiseAuthStatusUpdated();
                        _statusText.Text = $"🎉 成功同步 {schedule.Lessons.Count} 节课程！正在同步期末考试、成绩单与空教室...";

                        _ = Task.Run(async () =>
                        {
                            try
                            {
                                await EmptyClassroomService.Shared.EnsureValidTokenAsync(
                                    forceRelogin: true,
                                    expectedAccountGeneration: accountGeneration);
                                if (!AccountSessionManager.IsGenerationCurrent(accountGeneration)) return;
                                EmptyClassroomService.Shared.SyncTodayAndTomorrowStudyRooms(forceRefresh: true);
                                AcademicService.Shared.SyncAll(silent: false, expectedAccountGeneration: accountGeneration);
                            }
                            catch { }
                        });

                        TrayMenuController.Shared.ShowNotification("🎉 教务数据全量同步成功", $"已成功同步本学期 {schedule.Lessons.Count} 节课、期末排考及全学期成绩！");
                        await Task.Delay(1400);
                        AppEvents.InvokeOnUI(Hide);
                        return; // 提取成功，立刻退出！
                    }
                }

                if (status == "error")
                {
                    string err = root.TryGetProperty("error", out var eElem) ? eElem.GetString() ?? "提取失败" : "提取失败";
                    _statusText.Text = $"⚠️ 提取提示: {err}";
                    break;
                }
            }
        }
        catch (Exception ex)
        {
            _statusText.Text = $"⚠️ 提取执行异常: {ex.Message}";
        }
        finally
        {
            _isExtracting = false;
        }

        // 3. 兜底回退：若页内双引擎未完成，尝试通过后台 HttpClient 提取
        CourseScheduleService.Shared.SyncSchedule(ok =>
        {
            AppEvents.InvokeOnUI(() =>
            {
                if (ok)
                {
                    AcademicService.Shared.SyncAll(silent: false, expectedAccountGeneration: accountGeneration);
                    _statusText.Text = "🎉 课表与考试数据同步成功！";
                    Task.Delay(1200).ContinueWith(_ => AppEvents.InvokeOnUI(Hide));
                }
                else
                {
                    _statusText.Text = "⚠️ 未能完成课表提取，请在下方网页中确认已登录至「学生课表」页面后重试";
                }
            });
        });
    }

    private static string EscapeJs(string s) => s.Replace("\\", "\\\\").Replace("'", "\\'").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", "");
}

#endregion
