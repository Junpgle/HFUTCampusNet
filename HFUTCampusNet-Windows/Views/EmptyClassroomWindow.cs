using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using ListView = System.Windows.Controls.ListView;
using ListBox = System.Windows.Controls.ListBox;

namespace HFUTCampusNet;

#region 1. 单间教室 08:00 - 22:00 时间轴自绘控件 (ClassroomTimelineControl)

/// <summary>
/// 1:1 对齐 macOS 端 ClassroomTimelineBarView 的横向排课时间轴控件。
/// 采用 WPF 纯 DrawingContext 矢量绘制，零子视图开销，流畅极高。
/// </summary>
public sealed class ClassroomTimelineControl : FrameworkElement
{
    public static readonly DependencyProperty OccupationsProperty =
        DependencyProperty.Register(nameof(Occupations), typeof(List<RoomOccupationSlot>), typeof(ClassroomTimelineControl),
            new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty IsTodayProperty =
        DependencyProperty.Register(nameof(IsToday), typeof(bool), typeof(ClassroomTimelineControl),
            new FrameworkPropertyMetadata(true, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty NowMinutesProperty =
        DependencyProperty.Register(nameof(NowMinutes), typeof(int), typeof(ClassroomTimelineControl),
            new FrameworkPropertyMetadata(0, FrameworkPropertyMetadataOptions.AffectsRender));

    public List<RoomOccupationSlot>? Occupations
    {
        get => (List<RoomOccupationSlot>?)GetValue(OccupationsProperty);
        set => SetValue(OccupationsProperty, value);
    }

    public bool IsToday
    {
        get => (bool)GetValue(IsTodayProperty);
        set => SetValue(IsTodayProperty, value);
    }

    public int NowMinutes
    {
        get => (int)GetValue(NowMinutesProperty);
        set => SetValue(NowMinutesProperty, value);
    }

    private static readonly (int Hour, string Label)[] HourTicks = new[]
    {
        (8, "08:00"), (10, "10:00"), (12, "12:00"), (14, "14:00"),
        (16, "16:00"), (18, "18:00"), (20, "20:00"), (22, "22:00")
    };

    public ClassroomTimelineControl()
    {
        Height = 42;
        MinHeight = 42;
        ClipToBounds = false;
    }

    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);

        double totalW = ActualWidth;
        if (totalW < 30) return;

        const int startMin = 8 * 60;   // 08:00 (480)
        const int endMin = 22 * 60;    // 22:00 (1320)
        const double totalMinutes = endMin - startMin; // 840 分钟

        const double barY = 2;
        const double barH = 20;

        // 1. 底轨 (中性浅底轨，深浅色自适应)
        bool isDark = ThemeManager.Shared.IsDarkTheme;
        var trackBrush = isDark
            ? new SolidColorBrush(Color.FromArgb(28, 255, 255, 255))
            : new SolidColorBrush(Color.FromArgb(20, 0, 0, 0));
        var trackPen = new Pen(
            isDark ? new SolidColorBrush(Color.FromArgb(40, 255, 255, 255)) : new SolidColorBrush(Color.FromArgb(30, 0, 0, 0)),
            1.0);

        var trackRect = new Rect(0.5, barY + 0.5, Math.Max(0, totalW - 1), barH - 1);
        dc.DrawRoundedRectangle(trackBrush, trackPen, trackRect, 4, 4);

        // 2. 整点刻度与底部时间文字
        var tickPen = new Pen(
            isDark ? new SolidColorBrush(Color.FromArgb(35, 255, 255, 255)) : new SolidColorBrush(Color.FromArgb(25, 0, 0, 0)),
            1.0);
        var labelBrush = isDark
            ? new SolidColorBrush(Color.FromRgb(140, 145, 160))
            : new SolidColorBrush(Color.FromRgb(130, 135, 150));

        var typeface = new Typeface(new FontFamily("Segoe UI, -apple-system, sans-serif"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);

        foreach (var (hour, label) in HourTicks)
        {
            double ratio = (hour * 60 - startMin) / totalMinutes;
            double x = ratio * totalW;

            // 内部刻度线
            if (hour > 8 && hour < 22)
            {
                dc.DrawLine(tickPen, new Point(x, barY + 1), new Point(x, barY + barH - 1));
            }

            // 底部刻度文字
            var formattedText = new FormattedText(
                label,
                CultureInfo.InvariantCulture,
                System.Windows.FlowDirection.LeftToRight,
                typeface,
                9.5,
                labelBrush,
                VisualTreeHelper.GetDpi(this).PixelsPerDip);

            double labelX = Math.Max(0, Math.Min(totalW - formattedText.Width, x - formattedText.Width / 2.0));
            dc.DrawText(formattedText, new Point(labelX, barY + barH + 3));
        }

        // 3. 占用时段色块 (课程蓝色、考试红色、借用橙色)
        var occList = Occupations;
        if (occList != null && occList.Count > 0)
        {
            var whiteBrush = Brushes.White;
            var textTypeface = new Typeface(new FontFamily("Segoe UI, -apple-system, sans-serif"), FontStyles.Normal, FontWeights.Medium, FontStretches.Normal);

            foreach (var occ in occList)
            {
                int sMin = Math.Max(startMin, Math.Min(endMin, ParseMinute(occ.StartTimeString, 8 * 60)));
                int eMin = Math.Max(startMin, Math.Min(endMin, ParseMinute(occ.EndTimeString, 21 * 60)));
                if (eMin <= sMin) continue;

                double x = (sMin - startMin) / totalMinutes * totalW;
                double w = Math.Max(4, (eMin - sMin) / totalMinutes * totalW);
                var blockRect = new Rect(x, barY + 1, Math.Max(2, w - 1), barH - 2);

                Brush blockBrush = occ.CauseTitle switch
                {
                    "考试占用" => new SolidColorBrush(Color.FromArgb(215, 239, 68, 68)),   // 红色
                    "教室借用" => new SolidColorBrush(Color.FromArgb(210, 245, 158, 11)),  // 橙色
                    _ => new SolidColorBrush(Color.FromArgb(205, 59, 130, 246))            // 蓝色
                };

                dc.DrawRoundedRectangle(blockBrush, null, blockRect, 3, 3);

                // 若色块宽度 >= 36px，绘制截断的课程名
                if (w >= 36)
                {
                    string courseTitle = !string.IsNullOrWhiteSpace(occ.CourseName) ? occ.CourseName : occ.CauseTitle;
                    if (w >= 90)
                    {
                        courseTitle = $"{occ.StartTimeString} {courseTitle}";
                    }

                    var blockText = new FormattedText(
                        courseTitle,
                        CultureInfo.InvariantCulture,
                        System.Windows.FlowDirection.LeftToRight,
                        textTypeface,
                        9.0,
                        whiteBrush,
                        VisualTreeHelper.GetDpi(this).PixelsPerDip)
                    {
                        MaxTextWidth = Math.Max(10, w - 6),
                        MaxTextHeight = 16,
                        Trimming = TextTrimming.CharacterEllipsis
                    };

                    dc.DrawText(blockText, new Point(x + 3, barY + 2));
                }
            }
        }

        // 4. 当前时间红色指示细线 (仅今天且在 08:00~22:00 时段显示)
        int currentMin = NowMinutes > 0 ? NowMinutes : (DateTime.Now.Hour * 60 + DateTime.Now.Minute);
        if (IsToday && currentMin >= startMin && currentMin <= endMin)
        {
            double nowX = (currentMin - startMin) / totalMinutes * totalW;
            var nowPen = new Pen(new SolidColorBrush(Color.FromArgb(235, 239, 68, 68)), 1.5);
            dc.DrawLine(nowPen, new Point(nowX, barY - 1), new Point(nowX, barY + barH + 1));
        }
    }

    private static int ParseMinute(string str, int fallback)
    {
        var parts = str.Split(':');
        if (parts.Length >= 2 && int.TryParse(parts[0], out int h) && int.TryParse(parts[1], out int m))
        {
            return h * 60 + m;
        }
        return fallback;
    }
}

#endregion

#region 2. 现代 macOS 风格自习空教室窗口 (EmptyClassroomWindow)

/// <summary>
/// 1:1 对齐 macOS 原版 EmptyClassroomWindowController 的现代自习空教室窗口。
/// 包含：智能自习看板、多维校区/教学楼/楼层/空闲状态筛选、横向时间轴教室卡片、
/// 全屏平滑 Loading 遮罩层与反馈浮条，全方位消除等待卡死感。
/// </summary>
public sealed class EmptyClassroomWindow : Window
{
    private static EmptyClassroomWindow? _shared;
    public static EmptyClassroomWindow Shared => _shared ??= new EmptyClassroomWindow();

    // 状态与筛选参数
    private int _selectedCampusId = 6; // 默认宣城校区 (6)，翡翠湖 (3)，屯溪路 (2)
    private bool _isViewingTomorrow = false;
    private bool _pendingSnapshotAfterCurrentSync;
    private string _selectedBuilding = "全部";
    private int? _selectedFloor = null; // null 表示全部楼层
    private int _statusFilterMode = 0;   // 0 全部, 1 全天无课, 2 余下无课/上午空闲, 3 当前空闲/下午空闲, 4 当前占用
    private string _searchKeyword = string.Empty;

    // 控件引用
    private readonly ComboBox _campusCombo;
    private readonly Button _todayTabBtn;
    private readonly Button _tomorrowTabBtn;
    private readonly StackPanel _buildingCapsulesPanel;
    private readonly ComboBox _moreBuildingCombo;
    private bool _isHandlingBuildingChange = false;
    private readonly StackPanel _floorButtonsPanel;
    private readonly StackPanel _statusButtonsPanel;
    private readonly TextBox _searchBox;
    private readonly TextBlock _lastSyncTextBlock;
    private readonly Button _refreshButton;

    // 顶部自习室看板
    private readonly Border _summaryCard;
    private readonly TextBlock _summaryBadge;
    private readonly TextBlock _summaryTitle;
    private readonly TextBlock _summarySubtitle;
    private readonly Button _summaryActionBtn;

    // 列表与状态
    private readonly ListView _roomsListView;
    private readonly TextBlock _emptyNoticeTextBlock;
    private readonly TextBlock _bottomStatusTextBlock;
    private readonly TextBlock _diningEstimateTextBlock;

    // Loading 遮罩与反馈浮条
    private readonly Grid _loadingOverlay;
    private readonly TextBlock _loadingSubtext;
    private readonly DispatcherTimer _loadingTimer;
    private int _loadingElapsedSeconds = 0;

    private readonly Border _feedbackBanner;
    private readonly TextBlock _feedbackText;
    private readonly DispatcherTimer _feedbackDismissTimer;

    private readonly DispatcherTimer _minuteTicker;
    private int _lastLiveRefreshMinute = -1;

    private EmptyClassroomWindow()
    {
        Title = "空教室查询与自习室管理 - 合工大校园助手";
        Width = 996;
        Height = 720;
        MinWidth = 956;
        MinHeight = 600;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        // 主容器
        var rootGrid = new Grid();
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // 0: 顶部自习室看板
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // 1: 多维综合筛选栏
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); // 2: 教室列表与遮罩
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // 3: 底部状态栏

        // ---------------- 0. 顶部自习室看板 (SummaryCard) ----------------
        _summaryCard = new Border
        {
            Margin = new Thickness(16, 14, 16, 8),
            CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(16, 12, 16, 12)
        };

        var summaryDock = new DockPanel();
        _summaryActionBtn = new Button
        {
            Content = "取消自习",
            Padding = new Thickness(12, 5, 12, 5),
            FontSize = 12,
            FontWeight = FontWeights.Medium,
            Cursor = Cursors.Hand,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed
        };
        _summaryActionBtn.Click += (_, _) =>
        {
            EmptyClassroomService.Shared.ClearCurrentStudyRoom();
            UpdateSummaryCard();
            FilterAndRefreshList();
        };
        DockPanel.SetDock(_summaryActionBtn, Dock.Right);
        summaryDock.Children.Add(_summaryActionBtn);

        var summaryTextStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal };

        _summaryBadge = new TextBlock
        {
            Text = "今日自习室",
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brushes.White,
            Background = new SolidColorBrush(Color.FromRgb(10, 132, 255)),
            Padding = new Thickness(6, 2, 6, 2),
            Margin = new Thickness(0, 0, 8, 0),
            VerticalAlignment = VerticalAlignment.Center
        };
        _summaryTitle = new TextBlock
        {
            Text = "当前未设定自习室",
            FontSize = 14,
            FontWeight = FontWeights.Bold,
            VerticalAlignment = VerticalAlignment.Center
        };
        titleRow.Children.Add(_summaryBadge);
        titleRow.Children.Add(_summaryTitle);

        _summarySubtitle = new TextBlock
        {
            Text = "在下方教室列表中点击右侧「设为自习」，可在小组件和托盘接收冲突提醒与课前换座推荐",
            FontSize = 11.5,
            Margin = new Thickness(0, 4, 0, 0),
            TextWrapping = TextWrapping.Wrap
        };

        summaryTextStack.Children.Add(titleRow);
        summaryTextStack.Children.Add(_summarySubtitle);
        summaryDock.Children.Add(summaryTextStack);

        _summaryCard.Child = summaryDock;
        Grid.SetRow(_summaryCard, 0);
        rootGrid.Children.Add(_summaryCard);

        // ---------------- 1. 多维综合筛选栏 (FilterBar) ----------------
        var filterBar = new Border
        {
            Margin = new Thickness(16, 0, 16, 8),
            CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(12, 10, 12, 10)
        };

        var filterMainStack = new StackPanel();

        // 第一行：校区、日期胶囊、教学楼、搜索框、刷新按钮
        var row1 = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };

        var rightActions = new StackPanel { Orientation = Orientation.Horizontal };
        DockPanel.SetDock(rightActions, Dock.Right);

        _lastSyncTextBlock = new TextBlock
        {
            Text = EmptyClassroomService.Shared.FormattedLastSync(),
            FontSize = 11,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 10, 0)
        };
        rightActions.Children.Add(_lastSyncTextBlock);

        _refreshButton = new Button
        {
            Content = "🔄 刷新排课",
            Padding = new Thickness(12, 5, 12, 5),
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Cursor = Cursors.Hand
        };
        _refreshButton.Click += (_, _) => TriggerManualRefresh();
        rightActions.Children.Add(_refreshButton);

        row1.Children.Add(rightActions);

        var leftGroup1 = new WrapPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };

        // 校区选择
        _campusCombo = new ComboBox
        {
            Width = 125,
            Height = 30,
            FontSize = 12,
            ItemsSource = new[] { "宣城校区", "翡翠湖校区", "屯溪路校区" },
            SelectedIndex = 0,
            Margin = new Thickness(0, 0, 8, 4)
        };
        _campusCombo.SelectionChanged += (_, _) =>
        {
            _selectedCampusId = _campusCombo.SelectedIndex switch
            {
                1 => 3, // 翡翠湖
                2 => 2, // 屯溪路
                _ => 6  // 宣城
            };
            _selectedBuilding = "全部";
            ReloadBuildingOptions();
            FilterAndRefreshList();
            EnsureSelectedSnapshot();
        };
        leftGroup1.Children.Add(_campusCombo);

        // 日期快速切换胶囊 (今天 / 明天)
        var dateCapsule = new Border
        {
            CornerRadius = new CornerRadius(6),
            BorderThickness = new Thickness(1),
            Margin = new Thickness(0, 0, 8, 4)
        };
        var dateStack = new StackPanel { Orientation = Orientation.Horizontal };

        _todayTabBtn = CreateCapsuleButton($"今天 ({DateTime.Now:MM-dd})", isSelected: true, () =>
        {
            _isViewingTomorrow = false;
            UpdateDateTabs();
            FilterAndRefreshList();
            EnsureSelectedSnapshot();
        });
        _tomorrowTabBtn = CreateCapsuleButton($"明天 ({DateTime.Now.AddDays(1):MM-dd})", isSelected: false, () =>
        {
            _isViewingTomorrow = true;
            UpdateDateTabs();
            FilterAndRefreshList();
            EnsureSelectedSnapshot();
        });

        dateStack.Children.Add(_todayTabBtn);
        dateStack.Children.Add(_tomorrowTabBtn);
        dateCapsule.Child = dateStack;
        leftGroup1.Children.Add(dateCapsule);

        // 常用教学楼独立胶囊栏
        _buildingCapsulesPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 4, 0)
        };
        leftGroup1.Children.Add(_buildingCapsulesPanel);

        // “更多教学楼 ▼” 下拉选择
        _moreBuildingCombo = new ComboBox
        {
            Width = 125,
            Height = 30,
            FontSize = 12,
            Margin = new Thickness(0, 0, 8, 4),
            VerticalContentAlignment = VerticalAlignment.Center
        };
        _moreBuildingCombo.SelectionChanged += (_, _) =>
        {
            if (_isHandlingBuildingChange) return;
            if (_moreBuildingCombo.SelectedIndex > 0 && _moreBuildingCombo.SelectedItem is string selB)
            {
                _selectedBuilding = selB;
                RebuildBuildingCapsulesOnly();
                FilterAndRefreshList();
            }
            else if (_moreBuildingCombo.SelectedIndex == 0 && !IsPreferredBuilding(_selectedBuilding))
            {
                _selectedBuilding = "全部";
                RebuildBuildingCapsulesOnly();
                FilterAndRefreshList();
            }
        };
        leftGroup1.Children.Add(_moreBuildingCombo);

        // 即时搜索框
        _searchBox = new TextBox
        {
            Width = 140,
            Height = 30,
            FontSize = 12,
            VerticalContentAlignment = VerticalAlignment.Center,
            Padding = new Thickness(6, 0, 6, 0),
            Margin = new Thickness(0, 0, 8, 4)
        };
        _searchBox.TextChanged += (_, _) =>
        {
            _searchKeyword = _searchBox.Text.Trim();
            FilterAndRefreshList();
        };
        leftGroup1.Children.Add(_searchBox);

        row1.Children.Add(leftGroup1);
        filterMainStack.Children.Add(row1);

        // 第二行：楼层过滤胶囊 + 空闲状态筛选胶囊
        var row2 = new WrapPanel { Orientation = Orientation.Horizontal };

        var floorLabel = new TextBlock
        {
            Text = "楼层：",
            FontSize = 11.5,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 4, 0)
        };
        row2.Children.Add(floorLabel);

        _floorButtonsPanel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 16, 0) };
        BuildFloorButtons();
        row2.Children.Add(_floorButtonsPanel);

        var statusLabel = new TextBlock
        {
            Text = "状态：",
            FontSize = 11.5,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 4, 0)
        };
        row2.Children.Add(statusLabel);

        _statusButtonsPanel = new StackPanel { Orientation = Orientation.Horizontal };
        BuildStatusButtons();
        row2.Children.Add(_statusButtonsPanel);

        filterMainStack.Children.Add(row2);
        filterBar.Child = filterMainStack;

        Grid.SetRow(filterBar, 1);
        rootGrid.Children.Add(filterBar);

        // ---------------- 2. 教室列表与时间轴展示 (ListView) ----------------
        var listContainer = new Grid { Margin = new Thickness(16, 0, 16, 0) };

        _roomsListView = new ListView
        {
            BorderThickness = new Thickness(1),
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(0)
        };
        ScrollViewer.SetHorizontalScrollBarVisibility(_roomsListView, ScrollBarVisibility.Disabled);
        ScrollViewer.SetVerticalScrollBarVisibility(_roomsListView, ScrollBarVisibility.Auto);
        VirtualizingPanel.SetIsVirtualizing(_roomsListView, true);
        VirtualizingPanel.SetVirtualizationMode(_roomsListView, VirtualizationMode.Recycling);

        listContainer.Children.Add(_roomsListView);

        _emptyNoticeTextBlock = new TextBlock
        {
            Text = "暂无匹配的空闲教室数据\n可尝试切换教学楼、放宽楼层限制或点击右上角「刷新排课」",
            FontSize = 13,
            TextAlignment = TextAlignment.Center,
            LineHeight = 22,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed
        };
        listContainer.Children.Add(_emptyNoticeTextBlock);

        // 全覆盖半透明 Loading 遮罩卡片
        _loadingOverlay = new Grid
        {
            Background = new SolidColorBrush(Color.FromArgb(170, 15, 17, 22)),
            Visibility = Visibility.Collapsed
        };

        var loadingCard = new Border
        {
            Width = 320,
            Background = new SolidColorBrush(Color.FromRgb(28, 30, 38)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(60, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(24, 20, 24, 20),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };

        var loadingStack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };

        var spinner = new ProgressBar
        {
            IsIndeterminate = true,
            Width = 180,
            Height = 4,
            Margin = new Thickness(0, 0, 0, 14),
            Foreground = new SolidColorBrush(Color.FromRgb(10, 132, 255))
        };

        var loadingTitle = new TextBlock
        {
            Text = "正在刷新空教室排课数据...",
            FontSize = 13.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brushes.White,
            HorizontalAlignment = HorizontalAlignment.Center
        };

        _loadingSubtext = new TextBlock
        {
            Text = "已耗时 0 秒，正在从教务系统并发获取最新排课",
            FontSize = 11.5,
            Foreground = new SolidColorBrush(Color.FromRgb(160, 166, 180)),
            Margin = new Thickness(0, 6, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Center
        };

        loadingStack.Children.Add(spinner);
        loadingStack.Children.Add(loadingTitle);
        loadingStack.Children.Add(_loadingSubtext);
        loadingCard.Child = loadingStack;
        _loadingOverlay.Children.Add(loadingCard);

        listContainer.Children.Add(_loadingOverlay);

        // 浮动反馈条 (FeedbackBanner)
        _feedbackBanner = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(235, 20, 22, 28)),
            BorderBrush = new SolidColorBrush(Color.FromRgb(10, 132, 255)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(14, 8, 14, 8),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 14, 0, 0),
            Visibility = Visibility.Collapsed
        };
        _feedbackText = new TextBlock
        {
            Text = "✅ 刷新完成！",
            FontSize = 12.5,
            FontWeight = FontWeights.Medium,
            Foreground = Brushes.White
        };
        _feedbackBanner.Child = _feedbackText;
        listContainer.Children.Add(_feedbackBanner);

        Grid.SetRow(listContainer, 2);
        rootGrid.Children.Add(listContainer);

        // ---------------- 3. 底部状态栏 ----------------
        var bottomBar = new Border
        {
            Padding = new Thickness(16, 8, 16, 10),
            BorderThickness = new Thickness(0, 1, 0, 0)
        };
        var bottomStatusStack = new StackPanel();
        _bottomStatusTextBlock = new TextBlock
        {
            Text = "就绪",
            FontSize = 11.5
        };
        _diningEstimateTextBlock = new TextBlock
        {
            Text = "食堂拥挤估算 · 正在分析全校放学拥挤度……",
            FontSize = 10.5,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 6, 0, 0),
            ToolTip = "根据全校午间和下午放学时段的课程下课班次数估算，并与当日其它 30 分钟下课峰值比较；不代表实际就餐人数或现场客流"
        };
        bottomStatusStack.Children.Add(_bottomStatusTextBlock);
        bottomStatusStack.Children.Add(_diningEstimateTextBlock);
        bottomBar.Child = bottomStatusStack;
        Grid.SetRow(bottomBar, 3);
        rootGrid.Children.Add(bottomBar);

        Content = rootGrid;

        // 定时器初始化
        _loadingTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _loadingTimer.Tick += (_, _) =>
        {
            _loadingElapsedSeconds++;
            _loadingSubtext.Text = $"已耗时 {_loadingElapsedSeconds} 秒，正在从教务系统并发获取最新排课";
        };

        _feedbackDismissTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2.5) };
        _feedbackDismissTimer.Tick += (_, _) =>
        {
            _feedbackDismissTimer.Stop();
            _feedbackBanner.Visibility = Visibility.Collapsed;
        };

        _minuteTicker = new DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        _minuteTicker.Tick += (_, _) =>
        {
            if (IsVisible)
            {
                _lastSyncTextBlock.Text = EmptyClassroomService.Shared.FormattedLastSync();
                UpdateSummaryCard();
                int minute = DateTime.Now.Hour * 60 + DateTime.Now.Minute;
                if (minute != _lastLiveRefreshMinute)
                {
                    FilterAndRefreshList();
                }
                else
                {
                    _roomsListView.Items.Refresh();
                }
            }
        };
        _minuteTicker.Start();

        Closing += (_, e) =>
        {
            e.Cancel = true;
            Hide();
        };

        ThemeManager.Shared.ApplyWindowTheme(this);
        ApplyThemeStyles();
        ThemeManager.Shared.ThemeChanged += () => AppEvents.InvokeOnUI(ApplyThemeStyles);

        AppEvents.EmptyClassroomUpdated += () => AppEvents.InvokeOnUI(() =>
        {
            _lastSyncTextBlock.Text = EmptyClassroomService.Shared.FormattedLastSync();
            UpdateSummaryCard();
            FilterAndRefreshList();

            if (_pendingSnapshotAfterCurrentSync && !EmptyClassroomService.Shared.IsSyncing)
            {
                _pendingSnapshotAfterCurrentSync = false;
                EnsureSelectedSnapshot();
            }
        });

        ReloadBuildingOptions();
        UpdateSummaryCard();
    }

    public void ShowWindowAndSync(bool selectTomorrow = false)
    {
        ApplyThemeStyles();
        _isViewingTomorrow = selectTomorrow;
        UpdateDateTabs();

        Show();
        Activate();
        UpdateSummaryCard();
        FilterAndRefreshList();

        EnsureSelectedSnapshot();
    }

    private void EnsureSelectedSnapshot()
    {
        string targetDate = _isViewingTomorrow ? EmptyClassroomService.TomorrowDateString() : EmptyClassroomService.TodayDateString();
        if (!EmptyClassroomService.Shared.IsCampusSnapshotComplete(_selectedCampusId, targetDate))
            TriggerManualRefresh();
    }

    private void TriggerManualRefresh()
    {
        if (EmptyClassroomService.Shared.IsSyncing)
        {
            _pendingSnapshotAfterCurrentSync = true;
            return;
        }

        // 打开全屏 Loading 遮罩并启动计时
        _loadingElapsedSeconds = 0;
        _loadingSubtext.Text = "已耗时 0 秒，正在从教务系统并发获取最新排课";
        _loadingOverlay.Visibility = Visibility.Visible;
        _refreshButton.IsEnabled = false;
        _refreshButton.Content = "⏳ 正在同步...";
        _loadingTimer.Start();

        EmptyClassroomService.Shared.SyncTodayAndTomorrowStudyRooms(_selectedCampusId, forceRefresh: true, (ok, msg) =>
        {
            AppEvents.InvokeOnUI(() =>
            {
                _loadingTimer.Stop();
                _loadingOverlay.Visibility = Visibility.Collapsed;
                _refreshButton.IsEnabled = true;
                _refreshButton.Content = "🔄 刷新排课";
                _lastSyncTextBlock.Text = EmptyClassroomService.Shared.FormattedLastSync();

                UpdateSummaryCard();
                ReloadBuildingOptions();
                FilterAndRefreshList();

                // 弹出浮动反馈 Banner
                _feedbackText.Text = ok
                    ? $"✅ {msg ?? "空教室数据已成功同步！"}"
                    : $"⚠️ {msg ?? "同步未完成，已为您展示本地已有排课"}";
                _feedbackBanner.Visibility = Visibility.Visible;
                _feedbackDismissTimer.Stop();
                _feedbackDismissTimer.Start();
            });
        });
    }

    private void ApplyThemeStyles()
    {
        ThemeManager.Shared.ApplyWindowTheme(this);
        Background = ThemeManager.Shared.WindowBackground;
        Foreground = ThemeManager.Shared.TextPrimary;

        _summaryCard.Background = ThemeManager.Shared.CardBackground;
        _summaryCard.BorderBrush = ThemeManager.Shared.CardBorderBrush;
        _summaryTitle.Foreground = ThemeManager.Shared.TextPrimary;
        _summarySubtitle.Foreground = ThemeManager.Shared.TextSecondary;

        _lastSyncTextBlock.Foreground = ThemeManager.Shared.TextSecondary;
        _bottomStatusTextBlock.Foreground = ThemeManager.Shared.TextSecondary;
        _diningEstimateTextBlock.Foreground = ThemeManager.Shared.TextSecondary;
        _emptyNoticeTextBlock.Foreground = ThemeManager.Shared.TextSecondary;

        _roomsListView.Background = ThemeManager.Shared.TableBackground;
        _roomsListView.BorderBrush = ThemeManager.Shared.CardBorderBrush;

        ThemeManager.Shared.ApplyComboBoxTheme(_campusCombo);
        ThemeManager.Shared.ApplyComboBoxTheme(_moreBuildingCombo);

        ReloadBuildingOptions();
        BuildFloorButtons();
        BuildStatusButtons();
        UpdateDateTabs();
        FilterAndRefreshList();
    }

    private void UpdateDateTabs()
    {
        SetCapsuleSelected(_todayTabBtn, !_isViewingTomorrow);
        SetCapsuleSelected(_tomorrowTabBtn, _isViewingTomorrow);
        if (_isViewingTomorrow && _statusFilterMode == 4) _statusFilterMode = 0;
        BuildStatusButtons(); // 日期切换时更新状态文案（如余下无课/上午空闲）
    }

    private List<string> GetPreferredBuildingsForCampus(int campusId)
    {
        return campusId switch
        {
            6 => new List<string> { "新安学堂", "敬亭学堂" },
            3 => new List<string> { "翠一教", "翠二教", "翠三教", "翠四教", "翠五教", "翠六教", "翠七教", "翠八教", "翠九教", "翠十教", "翠十一教", "翠十二教", "翡翠科教楼" },
            2 => new List<string> { "主楼", "东楼", "西楼", "西二", "逸夫楼" },
            _ => new List<string>()
        };
    }

    private bool IsPreferredBuilding(string building)
    {
        if (building == "全部") return true;
        return GetPreferredBuildingsForCampus(_selectedCampusId).Contains(building);
    }

    private void ReloadBuildingOptions()
    {
        RebuildBuildingCapsulesOnly();

        // 统计当前校区除常用教学楼外的其他楼栋并填入“更多教学楼 ▼”
        string targetDate = _isViewingTomorrow ? EmptyClassroomService.TomorrowDateString() : EmptyClassroomService.TodayDateString();
        var campusRooms = EmptyClassroomService.Shared.CachedRooms
            .Where(r => r.CampusId == _selectedCampusId && r.DateString == targetDate)
            .ToList();

        var preferred = GetPreferredBuildingsForCampus(_selectedCampusId);
        var otherBuildings = campusRooms
            .Select(r => r.CleanBuildingName)
            .Where(name => !string.IsNullOrWhiteSpace(name) && !preferred.Contains(name) && name != "教学楼")
            .Distinct()
            .OrderBy(n => n)
            .ToList();

        var comboItems = new List<string> { "更多教学楼 ▼" };
        comboItems.AddRange(otherBuildings);

        _isHandlingBuildingChange = true;
        _moreBuildingCombo.ItemsSource = comboItems;
        if (otherBuildings.Contains(_selectedBuilding))
        {
            _moreBuildingCombo.SelectedItem = _selectedBuilding;
        }
        else
        {
            _moreBuildingCombo.SelectedIndex = 0;
        }
        _isHandlingBuildingChange = false;
    }

    private void RebuildBuildingCapsulesOnly()
    {
        _buildingCapsulesPanel.Children.Clear();

        var preferred = GetPreferredBuildingsForCampus(_selectedCampusId);
        var capsuleLabels = new List<string> { "全部" };
        capsuleLabels.AddRange(preferred);

        var border = new Border
        {
            CornerRadius = new CornerRadius(6),
            BorderThickness = new Thickness(1),
            Margin = new Thickness(0, 0, 8, 4)
        };
        var stack = new StackPanel { Orientation = Orientation.Horizontal };

        foreach (var bName in capsuleLabels)
        {
            bool isSel = _selectedBuilding == bName;
            var btn = CreateCapsuleButton(bName, isSel, () =>
            {
                _selectedBuilding = bName;
                _isHandlingBuildingChange = true;
                _moreBuildingCombo.SelectedIndex = 0;
                _isHandlingBuildingChange = false;
                RebuildBuildingCapsulesOnly();
                FilterAndRefreshList();
            });
            stack.Children.Add(btn);
        }
        border.Child = stack;
        _buildingCapsulesPanel.Children.Add(border);
    }

    private void BuildFloorButtons()
    {
        _floorButtonsPanel.Children.Clear();
        var options = new (int? Floor, string Text)[]
        {
            (null, "全部"),
            (1, "1F"),
            (2, "2F"),
            (3, "3F"),
            (4, "4F"),
            (5, "5F"),
            (6, "6F")
        };

        foreach (var (fl, txt) in options)
        {
            bool isSel = _selectedFloor == fl;
            var btn = CreateFilterCapsule(txt, isSel, () =>
            {
                _selectedFloor = fl;
                BuildFloorButtons();
                FilterAndRefreshList();
            });
            btn.Margin = new Thickness(0, 0, 4, 0);
            _floorButtonsPanel.Children.Add(btn);
        }
    }

    private void BuildStatusButtons()
    {
        _statusButtonsPanel.Children.Clear();
        string label2 = _isViewingTomorrow ? "上午空闲" : "余下全空";
        string label3 = _isViewingTomorrow ? "下午空闲" : "当前空闲";

        var options = new List<(int Mode, string Text)>
        {
            (0, "全部"),
            (1, "全天无课"),
            (2, label2),
            (3, label3)
        };
        if (!_isViewingTomorrow) options.Add((4, "当前有课"));

        foreach (var (mode, txt) in options)
        {
            bool isSel = _statusFilterMode == mode;
            var btn = CreateFilterCapsule(txt, isSel, () =>
            {
                _statusFilterMode = mode;
                BuildStatusButtons();
                FilterAndRefreshList();
            });
            btn.Margin = new Thickness(0, 0, 4, 0);
            _statusButtonsPanel.Children.Add(btn);
        }
    }

    private void UpdateSummaryCard()
    {
        int nowMin = DateTime.Now.Hour * 60 + DateTime.Now.Minute;
        string todayStr = EmptyClassroomService.TodayDateString();

        var currentRecord = EmptyClassroomService.Shared.CurrentStudyRoomItem();
        if (currentRecord != null)
        {
            var matchRoom = EmptyClassroomService.Shared.FindSelectedRoomInCache(currentRecord, todayStr);

            _summaryBadge.Text = "当前自习室";
            _summaryBadge.Background = new SolidColorBrush(Color.FromRgb(10, 132, 255));
            _summaryActionBtn.Visibility = Visibility.Visible;
            _summaryActionBtn.Content = "取消自习";

            if (matchRoom != null)
            {
                var status = matchRoom.StudyStatus(nowMin);
                if (status.ShouldRecommendSwitch && status.OccupiedPeriod != null)
                {
                    _summaryTitle.Text = $"⚠️ {matchRoom.RoomName} · {status.SubLabel}";
                    var recInfo = EmptyClassroomService.Shared.NearbySwitchRecommendations(matchRoom, 3);
                    string recText = recInfo.Recs.Count > 0
                        ? string.Join("、", recInfo.Recs.Select(r => $"{r.Room.RoomName}({r.Proximity.BadgeText})"))
                        : "请在下方列表中挑选其它空闲教室";
                    _summarySubtitle.Text = $"即将/正在上课，建议就近切换至：{recText}";
                    _summaryBadge.Background = new SolidColorBrush(Color.FromRgb(245, 158, 11)); // 橙色警告
                }
                else
                {
                    _summaryTitle.Text = $"当前自习室：{matchRoom.RoomName} ({status.SubLabel})";
                    _summarySubtitle.Text = $"已锁定 {matchRoom.BuildingName}，将在桌面小组件中常驻显示空闲状态并在上课冲突前预警。";
                }
            }
            else
            {
                _summaryTitle.Text = $"当前自习室：{currentRecord.RoomName}";
                _summarySubtitle.Text = $"已锁定 {currentRecord.BuildingName}，可在小组件和托盘接收冲突提醒与换座推荐。";
            }
        }
        else
        {
            _summaryBadge.Text = "自习精选";
            _summaryBadge.Background = new SolidColorBrush(Color.FromRgb(34, 197, 94));
            _summaryActionBtn.Visibility = Visibility.Collapsed;

            var recommendations = EmptyClassroomService.Shared.RecommendedTodayAllDayFreeRooms(limit: 4);
            if (recommendations.Count > 0)
            {
                string names = string.Join("、", recommendations.Select(r => r.RoomName));
                _summaryTitle.Text = "☀️ 今日自习全天空闲教室推荐 (一坐一整天无需换座)";
                _summarySubtitle.Text = $"精选全天无课教室：{names}。点击下方教室右侧「设为自习」立即占座！";
            }
            else
            {
                _summaryTitle.Text = "当前未设定自习室";
                _summarySubtitle.Text = "在下方教室列表中点击右侧「设为自习」，可在小组件和托盘接收冲突提醒与课前换座推荐。";
            }
        }
    }

    private void FilterAndRefreshList()
    {
        string targetDate = _isViewingTomorrow
            ? EmptyClassroomService.TomorrowDateString()
            : EmptyClassroomService.TodayDateString();
        bool isToday = targetDate == EmptyClassroomService.TodayDateString();

        var query = EmptyClassroomService.Shared.CachedRooms
            .Where(r => r.DateString == targetDate && r.CampusId == _selectedCampusId);

        // 教学楼过滤
        if (!string.IsNullOrEmpty(_selectedBuilding) && _selectedBuilding != "全部" && _selectedBuilding != "全部教学楼" && _selectedBuilding != "更多教学楼 ▼")
        {
            query = query.Where(r => r.CleanBuildingName.Equals(_selectedBuilding, StringComparison.OrdinalIgnoreCase) ||
                                     r.RoomName.Contains(_selectedBuilding));
        }

        // 楼层过滤 (使用 InferredFloor)
        if (_selectedFloor.HasValue)
        {
            query = query.Where(r => r.InferredFloor == _selectedFloor.Value);
        }

        // 关键词也属于统计范围；状态筛选单独应用，避免选“当前占用”后把统计结果过滤成零。
        if (!string.IsNullOrWhiteSpace(_searchKeyword))
        {
            query = query.Where(r => r.RoomName.Contains(_searchKeyword, StringComparison.OrdinalIgnoreCase) ||
                                     r.CleanBuildingName.Contains(_searchKeyword, StringComparison.OrdinalIgnoreCase) ||
                                     r.BuildingName.Contains(_searchKeyword, StringComparison.OrdinalIgnoreCase));
        }

        var scopedRooms = query.ToList();

        int nowMin = DateTime.Now.Hour * 60 + DateTime.Now.Minute;
        _lastLiveRefreshMinute = nowMin;
        var lessonMetrics = CurrentLessonMetrics.Calculate(scopedRooms, nowMin);

        // 状态过滤
        IEnumerable<ClassroomOccupationItem> filteredQuery = scopedRooms;
        if (_statusFilterMode == 1) // 全天无课
        {
            filteredQuery = filteredQuery.Where(r => r.IsAllDayFree);
        }
        else if (_statusFilterMode == 2) // 余下全空 / 上午空闲
        {
            if (_isViewingTomorrow)
                filteredQuery = filteredQuery.Where(r => !r.IsOccupiedAtPeriod(1) && !r.IsOccupiedAtPeriod(2) && !r.IsOccupiedAtPeriod(3) && !r.IsOccupiedAtPeriod(4));
            else
                filteredQuery = filteredQuery.Where(r => r.IsAllDayFree || (r.NextOccupation(nowMin) == null && r.CurrentOccupation(nowMin) == null));
        }
        else if (_statusFilterMode == 3) // 当前空闲 / 下午空闲
        {
            if (_isViewingTomorrow)
                filteredQuery = filteredQuery.Where(r => !r.IsOccupiedAtPeriod(5) && !r.IsOccupiedAtPeriod(6) && !r.IsOccupiedAtPeriod(7) && !r.IsOccupiedAtPeriod(8));
            else
                filteredQuery = filteredQuery.Where(r => r.CurrentOccupation(nowMin) == null);
        }
        else if (_statusFilterMode == 4 && isToday)
        {
            filteredQuery = filteredQuery.Where(r => r.Occupations.Any(o => o.IsLesson && CurrentLessonMetrics.IsOngoing(o, nowMin)));
        }

        var results = filteredQuery
            .OrderBy(r => r.CleanBuildingName)
            .ThenBy(r => r.InferredFloor)
            .ThenBy(r => r.RoomName)
            .ToList();

        _roomsListView.Items.Clear();
        var service = EmptyClassroomService.Shared;
        var currentStudyRoom = service.CurrentStudyRoomItem();
        var nextDayStudyRoom = SettingsManager.Shared.NextDayStudyRoom;

        foreach (var room in results)
        {
            var selectedRecord = isToday ? currentStudyRoom : nextDayStudyRoom;
            bool isSelected = selectedRecord != null
                && selectedRecord.RoomId == room.RoomId
                && selectedRecord.CampusId == room.CampusId
                && (isToday || selectedRecord.DateString == targetDate);
            var itemControl = CreateClassroomRowControl(room, isSelected, isToday, nowMin);
            _roomsListView.Items.Add(itemControl);
        }

        _emptyNoticeTextBlock.Text = _statusFilterMode == 4 && isToday
            ? "当前查询范围没有正在上课的教室"
            : "暂无匹配的空闲教室数据\n可尝试切换教学楼、放宽楼层限制或点击右上角「刷新排课」";
        _emptyNoticeTextBlock.Visibility = results.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        string currentLessonText = isToday
            ? $"当前范围 {lessonMetrics.LessonSessionCount} 班次上课 / 涉及 {lessonMetrics.OccupiedRoomCount} 间教室"
            : "当前上课统计仅适用于今天";
        _bottomStatusTextBlock.Text = $"查询 {results.Count} 间 · {currentLessonText} · {EmptyClassroomService.Shared.FormattedLastSync()}";
        _bottomStatusTextBlock.ToolTip = "班次数按当前校区、教学楼、楼层和搜索范围内的教务排课记录去重统计。双击教室或点击右侧按钮可设为自习室。";

        var campusRooms = service.CachedRooms.Where(r => r.CampusId == _selectedCampusId && r.DateString == targetDate).ToList();
        if (campusRooms.Count == 0)
        {
            _diningEstimateTextBlock.Text = "食堂拥挤估算 · 正在分析全校放学拥挤度……";
            _diningEstimateTextBlock.ToolTip = "正在汇总全校各教学楼排课并测算下课放学峰值，请稍候……";
        }
        else
        {
            var estimate = CampusDiningEstimate.Calculate(_selectedCampusId, targetDate, campusRooms, service.IsCampusSnapshotComplete(_selectedCampusId, targetDate));
            if (estimate.HallEstimates != null && estimate.HallEstimates.Count > 0)
            {
                var hallsText = string.Join("  ｜  ", estimate.HallEstimates.Select(h => $"{h.ShortName}：午间 {h.Lunch.CrowdLabel}  晚间 {h.Dinner.CrowdLabel}"));
                _diningEstimateTextBlock.Text = $"食堂拥挤估算 · {_campusCombo.SelectedItem}  ｜  {hallsText}";

                var tipLines = new List<string>
                {
                    $"食堂拥挤估算（按片区细分 · {_campusCombo.SelectedItem} {targetDate}）："
                };
                foreach (var hall in estimate.HallEstimates)
                {
                    tipLines.Add($"• {hall.HallName}：{hall.AreaDescription}");
                    var lCount = estimate.IsComplete ? $"{hall.Lunch.LessonReleaseCount} 班" : $"至少 {hall.Lunch.LessonReleaseCount} 班";
                    var dCount = estimate.IsComplete ? $"{hall.Dinner.LessonReleaseCount} 班" : $"至少 {hall.Dinner.LessonReleaseCount} 班";
                    tipLines.Add($"  - 午间放学 (11:30–12:30)：下课 {lCount} · 30分钟峰值 {hall.Lunch.PeakThirtyMinuteCount} 班 · {hall.Lunch.CrowdLabel}");
                    tipLines.Add($"  - 下午放学 (17:00–18:30)：下课 {dCount} · 30分钟峰值 {hall.Dinner.PeakThirtyMinuteCount} 班 · {hall.Dinner.CrowdLabel}");
                }
                if (_selectedCampusId == 6)
                {
                    tipLines.Add("💡 敬亭学堂与新安学堂两楼相邻，可结合两楼放学班次错峰就餐。");
                }
                tipLines.Add("以各区域历史最高峰下课班次数为 100% 量化测算拥挤百分比；不代表实际就餐人数或现场客流。" + (estimate.IsComplete ? "" : "（全校教室数据尚未完整）"));
                _diningEstimateTextBlock.ToolTip = string.Join(Environment.NewLine, tipLines);
            }
            else
            {
                string MealText(string title, MealRushForecast forecast)
                {
                    var count = estimate.IsComplete ? $"{forecast.LessonReleaseCount} 班" : $"已统计 {forecast.LessonReleaseCount} 班";
                    return $"{title}：{count}下课 · 30 分钟峰值 {forecast.PeakThirtyMinuteCount} 班 · {forecast.CrowdLabel}";
                }
                _diningEstimateTextBlock.Text = $"食堂拥挤估算 · {_campusCombo.SelectedItem} {targetDate}  ｜  {MealText("午间放学 11:30–12:30", estimate.Lunch)}  ｜  {MealText("下午放学 17:00–18:30", estimate.Dinner)}";
                _diningEstimateTextBlock.ToolTip = estimate.IsComplete
                    ? "以学期最高峰课程下课班次数为 100% 量化测算拥挤百分比；不代表实际就餐人数或现场客流。"
                    : "当前校区全量教室排课尚未完整，显示的班次数为已获取部分，拥挤度暂不显示。";
            }
        }
    }

    private Border CreateClassroomRowControl(ClassroomOccupationItem room, bool isSelectedStudyRoom, bool isToday, int nowMin)
    {
        var rowBorder = new Border
        {
            Margin = new Thickness(0, 0, 0, 8),
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            Background = isSelectedStudyRoom
                ? new SolidColorBrush(Color.FromArgb(30, 10, 132, 255))
                : ThemeManager.Shared.CardBackground,
            BorderBrush = isSelectedStudyRoom
                ? new SolidColorBrush(Color.FromRgb(10, 132, 255))
                : ThemeManager.Shared.CardBorderBrush,
            Padding = new Thickness(14, 10, 14, 10)
        };

        var rowGrid = new Grid();
        rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(200) }); // 左侧教室信息
        rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); // 中间时间轴
        rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(165) }); // 右侧按钮

        // 1. 左侧教室信息
        var leftStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };

        var nameRow = new StackPanel { Orientation = Orientation.Horizontal };
        var nameBlock = new TextBlock
        {
            Text = room.RoomName,
            FontSize = 13.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = isSelectedStudyRoom ? new SolidColorBrush(Color.FromRgb(10, 132, 255)) : ThemeManager.Shared.TextPrimary,
            VerticalAlignment = VerticalAlignment.Center
        };
        nameRow.Children.Add(nameBlock);

        if (isSelectedStudyRoom)
        {
            var studyPill = new Border
            {
                Background = new SolidColorBrush(Color.FromRgb(10, 132, 255)),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(5, 1, 5, 1),
                Margin = new Thickness(6, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center
            };
            studyPill.Child = new TextBlock { Text = isToday ? "当前自习" : "明日预约", FontSize = 9.5, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White };
            nameRow.Children.Add(studyPill);
        }

        leftStack.Children.Add(nameRow);

        // 楼层、座位与状态说明
        string seatText = room.Seats > 0 ? $"{room.Floor}楼 · {room.Seats}座" : $"{room.Floor}楼";
        var metaBlock = new TextBlock
        {
            Text = seatText,
            FontSize = 11,
            Foreground = ThemeManager.Shared.TextSecondary,
            Margin = new Thickness(0, 2, 0, 0)
        };
        leftStack.Children.Add(metaBlock);

        // 状态圆点与状态文字
        var statusRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0) };
        var (statusText, dotBrush) = ResolveRoomStatusDisplay(room, isToday, nowMin);

        var dot = new Ellipse
        {
            Width = 6,
            Height = 6,
            Fill = dotBrush,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 6, 0)
        };
        var statusLabel = new TextBlock
        {
            Text = statusText,
            FontSize = 11,
            Foreground = dotBrush,
            VerticalAlignment = VerticalAlignment.Center
        };
        statusRow.Children.Add(dot);
        statusRow.Children.Add(statusLabel);
        leftStack.Children.Add(statusRow);

        Grid.SetColumn(leftStack, 0);
        rowGrid.Children.Add(leftStack);

        // 2. 中间横向时间轴
        var timeline = new ClassroomTimelineControl
        {
            Occupations = room.Occupations,
            IsToday = isToday,
            NowMinutes = nowMin,
            Margin = new Thickness(10, 0, 14, 0),
            VerticalAlignment = VerticalAlignment.Center
        };

        if (room.Occupations.Count == 0)
        {
            timeline.ToolTip = "08:00 - 22:00 全天无排课";
        }
        else
        {
            timeline.ToolTip = string.Join("\n", room.Occupations.Select(o => $"{o.StartTimeString}~{o.EndTimeString} [{o.CauseTitle}] {o.CourseName} {o.Teacher}"));
        }

        Grid.SetColumn(timeline, 1);
        rowGrid.Children.Add(timeline);

        // 3. 右侧操作按钮组
        var actionsStack = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center
        };

        var scheduleBtn = new Button
        {
            Content = "教室课表",
            Padding = new Thickness(8, 4, 8, 4),
            FontSize = 11,
            Margin = new Thickness(0, 0, 6, 0),
            Cursor = Cursors.Hand
        };
        scheduleBtn.Click += (_, _) =>
        {
            new ClassroomSemesterScheduleWindow(room).ShowDialog();
        };

        var studyBtn = new Button
        {
            Content = isSelectedStudyRoom ? (isToday ? "取消自习" : "取消预约") : (isToday ? "设为自习" : "预约明日"),
            Padding = new Thickness(10, 4, 10, 4),
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Foreground = isSelectedStudyRoom ? Brushes.Red : Brushes.White,
            Background = isSelectedStudyRoom
                ? new SolidColorBrush(Color.FromArgb(40, 239, 68, 68))
                : new SolidColorBrush(Color.FromRgb(10, 132, 255)),
            Cursor = Cursors.Hand
        };
        studyBtn.Click += (_, _) =>
        {
            if (isSelectedStudyRoom)
            {
                if (isToday)
                    EmptyClassroomService.Shared.ClearCurrentStudyRoom();
                else
                    EmptyClassroomService.Shared.ClearNextDayStudyRoom();
            }
            else
            {
                if (isToday)
                    EmptyClassroomService.Shared.SetCurrentStudyRoom(room);
                else
                    EmptyClassroomService.Shared.SetNextDayStudyRoom(room);
            }
            UpdateSummaryCard();
            FilterAndRefreshList();
        };

        actionsStack.Children.Add(scheduleBtn);
        actionsStack.Children.Add(studyBtn);

        Grid.SetColumn(actionsStack, 2);
        rowGrid.Children.Add(actionsStack);

        rowBorder.Child = rowGrid;
        return rowBorder;
    }

    private static (string Text, Brush DotBrush) ResolveRoomStatusDisplay(ClassroomOccupationItem room, bool isToday, int nowMin)
    {
        if (room.IsAllDayFree)
        {
            return ("全天无课", new SolidColorBrush(Color.FromRgb(34, 197, 94))); // 绿色
        }

        if (!isToday)
        {
            return ($"有 {room.Occupations.Count} 节占用", new SolidColorBrush(Color.FromRgb(59, 130, 246))); // 蓝色
        }

        var cur = room.CurrentOccupation(nowMin);
        if (cur != null)
        {
            return ($"正在上课至 {cur.EndTimeString}", new SolidColorBrush(Color.FromRgb(239, 68, 68))); // 红色
        }

        var next = room.NextOccupation(nowMin);
        if (next != null)
        {
            int nextMinutes = ParseClockMinutes(next.StartTimeString);
            int diff = Math.Max(0, nextMinutes - nowMin);
            if (diff <= 35)
                return ($"{diff}分钟后有课", new SolidColorBrush(Color.FromRgb(245, 158, 11))); // 橙色
            return ($"空闲至 {next.StartTimeString}", new SolidColorBrush(Color.FromRgb(20, 184, 166))); // 青色
        }

        return ("余下全天空闲", new SolidColorBrush(Color.FromRgb(34, 197, 94)));
    }

    private static int ParseClockMinutes(string timeText)
    {
        var parts = timeText.Split(':');
        return parts.Length == 2
            && int.TryParse(parts[0], out int hour)
            && int.TryParse(parts[1], out int minute)
            ? hour * 60 + minute
            : 0;
    }

    private static Button CreateCapsuleButton(string text, bool isSelected, Action onClick)
    {
        var btn = new Button
        {
            Content = text,
            Padding = new Thickness(10, 4, 10, 4),
            FontSize = 11.5,
            Cursor = Cursors.Hand,
            BorderThickness = new Thickness(0)
        };
        SetCapsuleSelected(btn, isSelected);
        btn.Click += (_, _) => onClick();
        return btn;
    }

    private static void SetCapsuleSelected(Button btn, bool isSelected)
    {
        if (isSelected)
        {
            btn.Background = new SolidColorBrush(Color.FromRgb(10, 132, 255));
            btn.Foreground = Brushes.White;
            btn.FontWeight = FontWeights.SemiBold;
        }
        else
        {
            btn.Background = Brushes.Transparent;
            btn.Foreground = ThemeManager.Shared.TextPrimary;
            btn.FontWeight = FontWeights.Normal;
        }
    }

    private static Button CreateFilterCapsule(string text, bool isSelected, Action onClick)
    {
        var btn = new Button
        {
            Content = text,
            Padding = new Thickness(9, 3, 9, 3),
            FontSize = 11,
            Cursor = Cursors.Hand,
            BorderThickness = new Thickness(1)
        };
        if (isSelected)
        {
            btn.Background = new SolidColorBrush(Color.FromRgb(10, 132, 255));
            btn.BorderBrush = new SolidColorBrush(Color.FromRgb(10, 132, 255));
            btn.Foreground = Brushes.White;
            btn.FontWeight = FontWeights.SemiBold;
        }
        else
        {
            btn.Background = ThemeManager.Shared.CardBackground;
            btn.BorderBrush = ThemeManager.Shared.CardBorderBrush;
            btn.Foreground = ThemeManager.Shared.TextSecondary;
            btn.FontWeight = FontWeights.Normal;
        }
        btn.Click += (_, _) => onClick();
        return btn;
    }
}

#endregion

#region 3. 教室全学期排课表明细弹窗 (ClassroomSemesterScheduleWindow)

/// <summary>
/// 教室整周/全学期排课表可视化窗口。
/// 采用 7 列 (周一至周日) x 11 节次周排课格子图呈现，完全对齐课程表 (CourseScheduleWindow) 的视觉与交互体验。
/// 同时支持【按周课表】（单周时间轴与当前红线）与【全学期总览】（整学期排课时段汇总与开课周次范围）双视角切换。
/// </summary>
public sealed class ClassroomSemesterScheduleWindow : Window
{
    private readonly ClassroomOccupationItem _room;
    private Border _topBar = null!;
    private TextBlock _statusLabel = null!;
    private ComboBox _semesterCombo = null!;
    private Button _weeklyViewBtn = null!;
    private Button _overviewViewBtn = null!;
    private ComboBox _weekCombo = null!;
    private Button _prevWeekBtn = null!;
    private Button _nextWeekBtn = null!;
    private Button _currentWeekBtn = null!;
    private Button _refreshBtn = null!;
    private Button _studyBtn = null!;
    private Grid _timetableContainer = null!;
    private DispatcherTimer? _clockTimer;
    private Guid _activeScheduleRequestID = Guid.Empty;

    private CourseScheduleData? _scheduleData;
    private int _selectedWeek = 1;
    private bool _isOverviewMode = false;
    private bool _suppressSelectionEvents;

    private static readonly (Color Bg, Color Border, Color Text)[] CoursePaletteLight =
    {
        (Color.FromRgb(237, 246, 255), Color.FromRgb(70, 140, 245),  Color.FromRgb(20, 70, 160)),
        (Color.FromRgb(240, 253, 244), Color.FromRgb(74, 185, 120), Color.FromRgb(22, 101, 52)),
        (Color.FromRgb(254, 243, 242), Color.FromRgb(244, 114, 114), Color.FromRgb(153, 27, 27)),
        (Color.FromRgb(254, 249, 235), Color.FromRgb(234, 179, 40),  Color.FromRgb(133, 77, 14)),
        (Color.FromRgb(245, 243, 255), Color.FromRgb(168, 85, 247), Color.FromRgb(107, 33, 168)),
        (Color.FromRgb(238, 251, 253), Color.FromRgb(45, 185, 210), Color.FromRgb(14, 116, 144)),
        (Color.FromRgb(255, 241, 242), Color.FromRgb(244, 63, 94),   Color.FromRgb(159, 18, 57)),
        (Color.FromRgb(240, 249, 255), Color.FromRgb(56, 189, 248), Color.FromRgb(12, 74, 110))
    };

    private static readonly (Color Bg, Color Border, Color Text)[] CoursePaletteDark =
    {
        (Color.FromRgb(28, 44, 68),  Color.FromRgb(60, 130, 246), Color.FromRgb(191, 219, 254)),
        (Color.FromRgb(24, 48, 36),  Color.FromRgb(34, 197, 94),  Color.FromRgb(187, 247, 208)),
        (Color.FromRgb(52, 28, 30),  Color.FromRgb(239, 68, 68),  Color.FromRgb(254, 202, 202)),
        (Color.FromRgb(48, 40, 20),  Color.FromRgb(234, 179, 8),  Color.FromRgb(254, 240, 138)),
        (Color.FromRgb(44, 28, 64),  Color.FromRgb(168, 85, 247), Color.FromRgb(233, 213, 255)),
        (Color.FromRgb(20, 48, 52),  Color.FromRgb(20, 184, 166), Color.FromRgb(153, 246, 228)),
        (Color.FromRgb(54, 24, 36),  Color.FromRgb(244, 63, 94),  Color.FromRgb(254, 205, 211)),
        (Color.FromRgb(22, 45, 60),  Color.FromRgb(14, 165, 233), Color.FromRgb(186, 230, 253))
    };

    public ClassroomSemesterScheduleWindow(ClassroomOccupationItem room)
    {
        _room = room;
        Title = $"🏫 {room.RoomName} - 教室排课表";
        Width = 1096;
        Height = 800;
        MinWidth = 956;
        MinHeight = 640;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        _selectedWeek = CourseScheduleService.Shared.CurrentSchedule?.CalculatedCurrentWeek() ?? 1;

        var rootGrid = new Grid();
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(58) });
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        _topBar = BuildTopBar();
        Grid.SetRow(_topBar, 0);
        rootGrid.Children.Add(_topBar);

        var scrollViewer = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Padding = new Thickness(14, 12, 14, 14)
        };
        _timetableContainer = new Grid { MinHeight = 600 };
        scrollViewer.Content = _timetableContainer;
        Grid.SetRow(scrollViewer, 1);
        rootGrid.Children.Add(scrollViewer);

        Content = rootGrid;

        ThemeManager.Shared.ApplyWindowTheme(this);
        ApplyTheme();
        ThemeManager.Shared.ThemeChanged += () => AppEvents.InvokeOnUI(() =>
        {
            ApplyTheme();
            RenderTimetableGrid();
        });

        // 定时刷新红线
        _clockTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
        _clockTimer.Tick += (_, _) => RenderTimetableGrid();
        _clockTimer.Start();

        Closed += (_, _) =>
        {
            _activeScheduleRequestID = Guid.Empty;
            _clockTimer?.Stop();
            _clockTimer = null;
        };

        QuerySchedule();
    }

    private Border BuildTopBar()
    {
        var bar = new Border
        {
            Background = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromRgb(228, 233, 242)),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Padding = new Thickness(16, 0, 16, 0)
        };

        var barGrid = new Grid();
        barGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        barGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        barGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        // 左侧：教室标题、校区徽章与状态说明
        var titleStack = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center
        };

        var nameBlock = new TextBlock
        {
            Text = $"🏫 {_room.RoomName}",
            FontSize = 14.5,
            FontWeight = FontWeights.Bold,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0)
        };
        titleStack.Children.Add(nameBlock);

        var badge = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(20, 24, 112, 235)),
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(6, 2, 6, 2),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 10, 0)
        };
        badge.Child = new TextBlock
        {
            Text = $"{_room.CampusName} · {_room.CleanBuildingName} · {_room.Seats}座",
            FontSize = 11,
            Foreground = new SolidColorBrush(Color.FromRgb(24, 112, 235)),
            FontWeight = FontWeights.SemiBold
        };
        titleStack.Children.Add(badge);

        _statusLabel = new TextBlock
        {
            Text = "正在加载教室排课...",
            FontSize = 11.5,
            Foreground = new SolidColorBrush(Color.FromRgb(115, 126, 145)),
            VerticalAlignment = VerticalAlignment.Center
        };
        titleStack.Children.Add(_statusLabel);

        Grid.SetColumn(titleStack, 0);
        barGrid.Children.Add(titleStack);

        // 右侧：学期选择、视图模式切换、周次切换与操作按钮
        var actionPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center
        };

        // 学期下拉框
        _semesterCombo = new ComboBox
        {
            Width = 130,
            Height = 28,
            FontSize = 12,
            Margin = new Thickness(0, 0, 8, 0),
            VerticalContentAlignment = VerticalAlignment.Center
        };
        foreach (int semCode in EmptyClassroomService.AvailableSemesters)
        {
            _semesterCombo.Items.Add(new ComboBoxItem
            {
                Content = EmptyClassroomService.SemesterTitle(semCode),
                Tag = semCode
            });
        }
        _semesterCombo.SelectedIndex = 0;
        _semesterCombo.SelectionChanged += (_, _) =>
        {
            if (!_suppressSelectionEvents) QuerySchedule();
        };
        actionPanel.Children.Add(_semesterCombo);

        // 视图切换胶囊 (按周课表 / 全学期总览)
        var viewModeBorder = new Border
        {
            Background = ThemeManager.Shared.TableHeaderBackground,
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(5),
            Padding = new Thickness(2),
            Margin = new Thickness(0, 0, 8, 0),
            VerticalAlignment = VerticalAlignment.Center
        };
        var segStack = new StackPanel { Orientation = Orientation.Horizontal };

        _weeklyViewBtn = CreateSegmentPill("📅 按周课表", true, (_, _) => SwitchViewMode(false));
        _overviewViewBtn = CreateSegmentPill("🌐 全学期总览", false, (_, _) => SwitchViewMode(true));

        segStack.Children.Add(_weeklyViewBtn);
        segStack.Children.Add(_overviewViewBtn);
        viewModeBorder.Child = segStack;
        actionPanel.Children.Add(viewModeBorder);

        // 周次切换部分
        _prevWeekBtn = CreateToolbarButton("◀", (_, _) =>
        {
            if (_selectedWeek > 1)
            {
                _selectedWeek--;
                SwitchViewMode(false);
            }
        });
        _prevWeekBtn.ToolTip = "上一周";
        actionPanel.Children.Add(_prevWeekBtn);

        _weekCombo = new ComboBox
        {
            Width = 115,
            Height = 28,
            FontSize = 12,
            Margin = new Thickness(4, 0, 4, 0),
            VerticalContentAlignment = VerticalAlignment.Center
        };
        _weekCombo.Items.Add("全部周次 (总览)");
        for (int w = 1; w <= 20; w++) _weekCombo.Items.Add($"第 {w} 周");
        _weekCombo.SelectedIndex = Math.Clamp(_selectedWeek, 1, 20);
        _weekCombo.SelectionChanged += (_, _) =>
        {
            if (_suppressSelectionEvents) return;
            if (_weekCombo.SelectedIndex == 0)
            {
                SwitchViewMode(true);
            }
            else if (_weekCombo.SelectedIndex > 0)
            {
                _selectedWeek = _weekCombo.SelectedIndex;
                SwitchViewMode(false);
            }
        };
        actionPanel.Children.Add(_weekCombo);

        _nextWeekBtn = CreateToolbarButton("▶", (_, _) =>
        {
            if (_selectedWeek < 20)
            {
                _selectedWeek++;
                SwitchViewMode(false);
            }
        });
        _nextWeekBtn.ToolTip = "下一周";
        actionPanel.Children.Add(_nextWeekBtn);

        _currentWeekBtn = CreateToolbarButton("本周", (_, _) =>
        {
            int currentWeek = _scheduleData?.CalculatedCurrentWeek() ?? CourseScheduleService.Shared.CurrentSchedule?.CalculatedCurrentWeek() ?? 1;
            _selectedWeek = currentWeek;
            SwitchViewMode(false);
        });
        _currentWeekBtn.Margin = new Thickness(4, 0, 6, 0);
        _currentWeekBtn.ToolTip = "回到当前自然周";
        actionPanel.Children.Add(_currentWeekBtn);

        _refreshBtn = CreateToolbarButton("🔄 刷新", (_, _) => QuerySchedule(forceRefresh: true));
        _refreshBtn.Margin = new Thickness(0, 0, 6, 0);
        _refreshBtn.ToolTip = "重新拉取该教室全学期排课数据";
        actionPanel.Children.Add(_refreshBtn);

        bool isCurrentStudy = IsCurrentStudyRoom();
        _studyBtn = CreatePrimaryButton(isCurrentStudy ? "✅ 取消自习" : "⭐ 设为自习", (_, _) =>
        {
            if (IsCurrentStudyRoom())
            {
                EmptyClassroomService.Shared.ClearCurrentStudyRoom();
            }
            else
            {
                EmptyClassroomService.Shared.SetCurrentStudyRoom(_room);
            }
            UpdateStudyButtonState();
        });
        if (isCurrentStudy)
        {
            _studyBtn.Background = new SolidColorBrush(Color.FromArgb(40, 239, 68, 68));
            _studyBtn.Foreground = Brushes.Red;
        }
        actionPanel.Children.Add(_studyBtn);

        Grid.SetColumn(actionPanel, 2);
        barGrid.Children.Add(actionPanel);

        bar.Child = barGrid;
        return bar;
    }

    private void SwitchViewMode(bool isOverview)
    {
        _isOverviewMode = isOverview;

        // 更新模式胶囊按钮外观
        UpdateSegmentButtonState(_weeklyViewBtn, !_isOverviewMode);
        UpdateSegmentButtonState(_overviewViewBtn, _isOverviewMode);

        _prevWeekBtn.IsEnabled = !_isOverviewMode && _selectedWeek > 1;
        _nextWeekBtn.IsEnabled = !_isOverviewMode && _selectedWeek < 20;
        _currentWeekBtn.IsEnabled = !_isOverviewMode;

        _suppressSelectionEvents = true;
        try
        {
            _weekCombo.SelectedIndex = _isOverviewMode ? 0 : Math.Clamp(_selectedWeek, 1, 20);
        }
        finally
        {
            _suppressSelectionEvents = false;
        }

        RenderTimetableGrid();
    }

    private static void UpdateSegmentButtonState(Button btn, bool isSelected)
    {
        btn.Background = isSelected
            ? new SolidColorBrush(Color.FromRgb(24, 112, 235))
            : Brushes.Transparent;
        btn.Foreground = isSelected
            ? Brushes.White
            : ThemeManager.Shared.TextSecondary;
        btn.FontWeight = isSelected ? FontWeights.Bold : FontWeights.Normal;
    }

    private void UpdateStudyButtonState()
    {
        bool isCurrent = IsCurrentStudyRoom();
        _studyBtn.Content = isCurrent ? "✅ 取消自习" : "⭐ 设为自习";
        _studyBtn.Background = isCurrent
            ? new SolidColorBrush(Color.FromArgb(40, 239, 68, 68))
            : new SolidColorBrush(Color.FromRgb(24, 112, 235));
        _studyBtn.Foreground = isCurrent ? Brushes.Red : Brushes.White;
    }

    private bool IsCurrentStudyRoom()
    {
        var service = EmptyClassroomService.Shared;
        var current = service.CurrentStudyRoomItem();
        var currentRoom = current == null
            ? null
            : service.FindSelectedRoomInCache(current, EmptyClassroomService.TodayDateString());
        return currentRoom != null && currentRoom.RoomId == _room.RoomId && currentRoom.CampusId == _room.CampusId;
    }

    private void ApplyTheme()
    {
        ThemeManager.Shared.ApplyWindowTheme(this);
        Background = ThemeManager.Shared.WindowBackground;
        Foreground = ThemeManager.Shared.TextPrimary;

        if (_topBar != null)
        {
            _topBar.Background = ThemeManager.Shared.TopBarBackground;
            _topBar.BorderBrush = ThemeManager.Shared.CardBorderBrush;
        }

        if (_statusLabel != null)
        {
            _statusLabel.Foreground = ThemeManager.Shared.TextSecondary;
        }

        ThemeManager.Shared.ApplyComboBoxTheme(_semesterCombo);
        ThemeManager.Shared.ApplyComboBoxTheme(_weekCombo);

        if (_weeklyViewBtn != null && _overviewViewBtn != null)
        {
            UpdateSegmentButtonState(_weeklyViewBtn, !_isOverviewMode);
            UpdateSegmentButtonState(_overviewViewBtn, _isOverviewMode);
        }
    }

    private void QuerySchedule(bool forceRefresh = false)
    {
        int semesterCode = 354;
        if (_semesterCombo.SelectedItem is ComboBoxItem sItem && sItem.Tag is int code)
        {
            semesterCode = code;
        }

        _statusLabel.Text = $"正在拉取 {_room.RoomName} 排课明细...";
        _refreshBtn.IsEnabled = false;
        var requestID = Guid.NewGuid();
        _activeScheduleRequestID = requestID;

        EmptyClassroomService.Shared.FetchClassroomSemesterSchedule(_room, semesterCode, forceRefresh, (data, err) =>
        {
            AppEvents.InvokeOnUI(() =>
            {
                if (_activeScheduleRequestID != requestID) return;
                _refreshBtn.IsEnabled = true;
                if (data == null)
                {
                    if (!string.Equals(_scheduleData?.SemesterId, semesterCode.ToString(), StringComparison.Ordinal))
                    {
                        _scheduleData = null;
                        RenderTimetableGrid();
                    }
                    _statusLabel.Text = string.IsNullOrWhiteSpace(err)
                        ? "获取教室排课失败，请检查网络后重试。"
                        : err;
                    return;
                }

                _scheduleData = data;
                RenderTimetableGrid();
            });
        });
    }

    private void RenderTimetableGrid()
    {
        _timetableContainer.Children.Clear();
        _timetableContainer.RowDefinitions.Clear();
        _timetableContainer.ColumnDefinitions.Clear();

        List<CourseLesson> displayLessons = _isOverviewMode
            ? BuildSemesterConsolidatedLessons(_scheduleData?.Lessons ?? new List<CourseLesson>())
            : ResolveWeekLessons(_selectedWeek);
        displayLessons = displayLessons
            .Where(l => l.Weekday >= 1 && l.Weekday <= 7
                && l.StartMinutes >= 0 && l.EndMinutes > l.StartMinutes && l.EndMinutes <= 24 * 60)
            .OrderBy(l => l.Weekday)
            .ThenBy(l => l.StartMinutes)
            .ThenBy(l => l.EndMinutes)
            .ToList();

        int minLessonHour = displayLessons.Count > 0 ? displayLessons.Min(l => l.StartMinutes) / 60 : 8;
        int maxLessonHour = displayLessons.Count > 0 ? (displayLessons.Max(l => l.EndMinutes) + 59) / 60 : 22;
        int startHour = Math.Min(8, minLessonHour);
        int endHour = Math.Min(24, Math.Max(22, maxLessonHour));
        int totalHours = Math.Max(1, endHour - startHour);
        const double hourHeight = 54.0;

        var outerCard = new Border
        {
            Background = ThemeManager.Shared.CardBackground,
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            ClipToBounds = true
        };

        var tableGrid = new Grid();
        // 列 0 为时间刻度栏 (74px)，列 1~7 为周一至周日 (1*)
        tableGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(74) });
        for (int d = 1; d <= 7; d++)
        {
            tableGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        }

        // 表头加逐小时的真实时间轴。
        tableGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(46) });
        for (int hour = 0; hour < totalHours; hour++)
        {
            tableGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(hourHeight) });
        }

        var today = DateTime.Today;
        int currentWeekday = TodayIsoWeekday();
        int currentMinutes = DateTime.Now.Hour * 60 + DateTime.Now.Minute;
        int currentCalculatedWeek = _scheduleData?.CalculatedCurrentWeek() ?? CourseScheduleService.Shared.CurrentSchedule?.CalculatedCurrentWeek() ?? 1;
        bool isViewingCurrentWeek = (!_isOverviewMode && _selectedWeek == currentCalculatedWeek);

        var weekDates = !_isOverviewMode ? ResolveWeekDates(_selectedWeek) : new List<DateTime?>();

        // 左上角单元格
        var cornerBorder = new Border
        {
            Background = ThemeManager.Shared.TableHeaderBackground,
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(0, 0, 1, 1)
        };
        string cornerText;
        if (_isOverviewMode)
        {
            cornerText = "全学期";
        }
        else
        {
            cornerText = weekDates.Count > 0 && weekDates[0].HasValue
                ? $"{weekDates[0]!.Value.Month}月"
                : $"第{_selectedWeek}周";
        }

        cornerBorder.Child = new TextBlock
        {
            Text = cornerText,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = _isOverviewMode ? new SolidColorBrush(Color.FromRgb(24, 112, 235)) : ThemeManager.Shared.TextSecondary,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetRow(cornerBorder, 0);
        Grid.SetColumn(cornerBorder, 0);
        tableGrid.Children.Add(cornerBorder);

        string[] weekdayNames = { "周一", "周二", "周三", "周四", "周五", "周六", "周日" };
        for (int d = 1; d <= 7; d++)
        {
            DateTime? dayDate = (!_isOverviewMode && d - 1 < weekDates.Count) ? weekDates[d - 1] : null;
            bool isToday = !_isOverviewMode && (dayDate.HasValue
                ? dayDate.Value.Date == today
                : (isViewingCurrentWeek && d == currentWeekday));

            var headerBorder = new Border
            {
                Background = isToday
                    ? new SolidColorBrush(Color.FromArgb(32, 24, 112, 235))
                    : ThemeManager.Shared.TableHeaderBackground,
                BorderBrush = ThemeManager.Shared.CardBorderBrush,
                BorderThickness = new Thickness(0, 0, d < 7 ? 1 : 0, 1)
            };

            var headerStack = new StackPanel
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            };

            headerStack.Children.Add(new TextBlock
            {
                Text = isToday ? $"{weekdayNames[d - 1]} · 今天" : weekdayNames[d - 1],
                FontSize = 12,
                FontWeight = isToday ? FontWeights.Bold : FontWeights.SemiBold,
                Foreground = isToday
                    ? new SolidColorBrush(Color.FromRgb(24, 112, 235))
                    : ThemeManager.Shared.TextPrimary,
                HorizontalAlignment = HorizontalAlignment.Center
            });

            if (dayDate.HasValue)
            {
                headerStack.Children.Add(new TextBlock
                {
                    Text = dayDate.Value.ToString("MM/dd"),
                    FontSize = 10,
                    Foreground = isToday
                        ? new SolidColorBrush(Color.FromRgb(45, 128, 240))
                        : ThemeManager.Shared.TextSecondary,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Margin = new Thickness(0, 1, 0, 0)
                });
            }
            else if (_isOverviewMode)
            {
                headerStack.Children.Add(new TextBlock
                {
                    Text = "固定排课",
                    FontSize = 9.5,
                    Foreground = ThemeManager.Shared.TextSecondary,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Margin = new Thickness(0, 1, 0, 0)
                });
            }

            headerBorder.Child = headerStack;
            Grid.SetRow(headerBorder, 0);
            Grid.SetColumn(headerBorder, d);
            tableGrid.Children.Add(headerBorder);

            // 今日整列淡蓝高亮背景底色 (仅在单周查看今天时启用)
            if (isToday)
            {
                var todayColHighlight = new Border
                {
                    Background = new SolidColorBrush(Color.FromArgb(14, 36, 128, 255)),
                    IsHitTestVisible = false
                };
                Grid.SetRow(todayColHighlight, 1);
                Grid.SetRowSpan(todayColHighlight, totalHours);
                Grid.SetColumn(todayColHighlight, d);
                tableGrid.Children.Add(todayColHighlight);
            }
        }

        // 左侧按小时刻度；课程位置后续按真实分钟数计算。
        var timeAxis = new Grid
        {
            Background = ThemeManager.Shared.TableHeaderBackground,
            ClipToBounds = false,
            IsHitTestVisible = false
        };
        for (int hourIndex = 0; hourIndex < totalHours; hourIndex++)
        {
            timeAxis.RowDefinitions.Add(new RowDefinition { Height = new GridLength(hourHeight) });
            var axisCell = new Border
            {
                BorderBrush = ThemeManager.Shared.CardBorderBrush,
                BorderThickness = new Thickness(0, 0, 1, 1)
            };
            Grid.SetRow(axisCell, hourIndex);
            timeAxis.Children.Add(axisCell);

            var axisLabel = new TextBlock
            {
                Text = $"{startHour + hourIndex:D2}:00",
                Width = 64,
                Height = 16,
                TextAlignment = TextAlignment.Right,
                FontSize = 10.5,
                Foreground = ThemeManager.Shared.TextSecondary,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, -8, 8, 0)
            };
            Grid.SetRow(axisLabel, hourIndex);
            timeAxis.Children.Add(axisLabel);

            for (int day = 1; day <= 7; day++)
            {
                var hourCell = new Border
                {
                    BorderBrush = ThemeManager.Shared.CardBorderBrush,
                    BorderThickness = new Thickness(0, 0, day < 7 ? 1 : 0, 1),
                    IsHitTestVisible = false
                };
                Grid.SetRow(hourCell, hourIndex + 1);
                Grid.SetColumn(hourCell, day);
                tableGrid.Children.Add(hourCell);
            }
        }
        var endTimeLabel = new TextBlock
        {
            Text = $"{endHour:D2}:00",
            Width = 64,
            Height = 16,
            TextAlignment = TextAlignment.Right,
            FontSize = 10.5,
            Foreground = ThemeManager.Shared.TextSecondary,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 8, -8)
        };
        Grid.SetRow(endTimeLabel, totalHours - 1);
        timeAxis.Children.Add(endTimeLabel);
        Grid.SetRow(timeAxis, 1);
        Grid.SetRowSpan(timeAxis, totalHours);
        Grid.SetColumn(timeAxis, 0);
        tableGrid.Children.Add(timeAxis);

        // 更新状态文字
        UpdateStatusSummary(displayLessons);

        if (displayLessons.Count == 0)
        {
            // 空闲状态卡片展示
            var emptyNotice = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(16, 34, 197, 94)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(40, 34, 197, 94)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(18, 14, 18, 14),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                IsHitTestVisible = false
            };
            var st = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
            st.Children.Add(new TextBlock
            {
                Text = _isOverviewMode ? "🌿 全学期无排课记录" : "🌿 本周全天空闲无排课",
                FontSize = 13.5,
                FontWeight = FontWeights.Bold,
                Foreground = new SolidColorBrush(Color.FromRgb(34, 197, 94)),
                HorizontalAlignment = HorizontalAlignment.Center
            });
            st.Children.Add(new TextBlock
            {
                Text = _isOverviewMode ? "该教室在整个学期均无排课，非常适合自习或举办活动" : $"该教室在第 {_selectedWeek} 周完全空闲，非常适合自习或研讨活动",
                FontSize = 11,
                Foreground = ThemeManager.Shared.TextSecondary,
                Margin = new Thickness(0, 4, 0, 0),
                HorizontalAlignment = HorizontalAlignment.Center
            });
            emptyNotice.Child = st;
            Grid.SetRow(emptyNotice, 1);
            Grid.SetRowSpan(emptyNotice, totalHours);
            Grid.SetColumn(emptyNotice, 2);
            Grid.SetColumnSpan(emptyNotice, 4);
            tableGrid.Children.Add(emptyNotice);
        }
        else
        {
            // 按实际开始/结束时间分组，重叠课程使用并排子列。
            for (int day = 1; day <= 7; day++)
            {
                var dayList = displayLessons.Where(c => c.Weekday == day).ToList();
                var overlapGroups = new List<List<CourseLesson>>();
                foreach (var lesson in dayList)
                {
                    if (overlapGroups.Count == 0 || lesson.StartMinutes >= overlapGroups[^1].Max(l => l.EndMinutes))
                        overlapGroups.Add(new List<CourseLesson> { lesson });
                    else
                        overlapGroups[^1].Add(lesson);
                }

                foreach (var group in overlapGroups)
                {
                    int groupStartHour = group.Min(l => l.StartMinutes) / 60;
                    int groupEndHour = (group.Max(l => l.EndMinutes) + 59) / 60;
                    int parentStartRow = Math.Clamp(groupStartHour - startHour, 0, totalHours - 1) + 1;
                    int parentEndRow = Math.Clamp(groupEndHour - startHour + 1, parentStartRow + 1, totalHours + 1);
                    var laneEnds = new List<int>();
                    var assignedLanes = new List<int>();
                    foreach (var lesson in group)
                    {
                        int lane = laneEnds.FindIndex(end => end <= lesson.StartMinutes);
                        if (lane < 0)
                        {
                            lane = laneEnds.Count;
                            laneEnds.Add(lesson.EndMinutes);
                        }
                        else
                        {
                            laneEnds[lane] = lesson.EndMinutes;
                        }
                        assignedLanes.Add(lane);
                    }

                    var groupGrid = new Grid { ClipToBounds = true };
                    for (int lane = 0; lane < laneEnds.Count; lane++)
                        groupGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    for (int hour = groupStartHour; hour < groupEndHour; hour++)
                        groupGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
                    Grid.SetRow(groupGrid, parentStartRow);
                    Grid.SetRowSpan(groupGrid, parentEndRow - parentStartRow);
                    Grid.SetColumn(groupGrid, day);
                    tableGrid.Children.Add(groupGrid);

                    for (int index = 0; index < group.Count; index++)
                    {
                        var lesson = group[index];
                        int localStartRow = lesson.StartMinutes / 60 - groupStartHour;
                        int localEndRow = (lesson.EndMinutes + 59) / 60 - groupStartHour;
                        int endRemainder = lesson.EndMinutes % 60;
                        double topInset = lesson.StartMinutes % 60 / 60.0 * hourHeight;
                        double bottomInset = endRemainder == 0 ? 0 : (60 - endRemainder) / 60.0 * hourHeight;
                        bool isOngoingNow = isViewingCurrentWeek && day == currentWeekday
                            && currentMinutes >= lesson.StartMinutes && currentMinutes < lesson.EndMinutes;
                        var card = CreateCourseCardElement(new List<CourseLesson> { lesson }, isOngoingNow, _isOverviewMode);
                        if (card is FrameworkElement cardElement)
                            cardElement.Margin = new Thickness(3, topInset + 2, 3, bottomInset + 2);
                        int cardStartRow = Math.Clamp(localStartRow, 0, groupGrid.RowDefinitions.Count - 1);
                        int cardEndRow = Math.Clamp(localEndRow, cardStartRow + 1, groupGrid.RowDefinitions.Count);
                        Grid.SetRow(card, cardStartRow);
                        Grid.SetRowSpan(card, cardEndRow - cardStartRow);
                        Grid.SetColumn(card, assignedLanes[index]);
                        groupGrid.Children.Add(card);
                    }
                }

                // 当前时间指示线按实际时刻落位（全学期总览时隐藏）。
                if (isViewingCurrentWeek && day == currentWeekday
                    && currentMinutes >= startHour * 60 && currentMinutes < endHour * 60)
                {
                    int row = Math.Clamp(currentMinutes / 60 - startHour, 0, totalHours - 1) + 1;
                    double offset = currentMinutes % 60 / 60.0 * hourHeight;
                    var indicator = new Grid { IsHitTestVisible = false };
                    indicator.Children.Add(new Border
                    {
                        Height = 2,
                        Margin = new Thickness(0, offset, 0, 0),
                        VerticalAlignment = VerticalAlignment.Top,
                        Background = new SolidColorBrush(Color.FromRgb(239, 68, 68))
                    });
                    indicator.Children.Add(new Ellipse
                    {
                        Width = 6,
                        Height = 6,
                        Margin = new Thickness(-3, offset - 2, 0, 0),
                        HorizontalAlignment = HorizontalAlignment.Left,
                        VerticalAlignment = VerticalAlignment.Top,
                        Fill = new SolidColorBrush(Color.FromRgb(239, 68, 68))
                    });
                    Grid.SetRow(indicator, row);
                    Grid.SetColumn(indicator, day);
                    tableGrid.Children.Add(indicator);
                }
            }
        }

        outerCard.Child = tableGrid;
        _timetableContainer.Children.Add(outerCard);
    }

    private void UpdateStatusSummary(List<CourseLesson> currentList)
    {
        if (_scheduleData == null || _scheduleData.Lessons.Count == 0)
        {
            if (_room.Occupations.Count > 0)
            {
                _statusLabel.Text = $"已显示当日 ({_room.DateString}) 占用记录";
            }
            else
            {
                _statusLabel.Text = "暂无排课记录";
            }
            return;
        }

        int allCount = _scheduleData.Lessons.Count;
        int courseCount = _scheduleData.Lessons.Select(l => l.CourseName).Distinct().Count();

        if (_isOverviewMode)
        {
            _statusLabel.Text = $"全学期总览：共 {courseCount} 门课程、{allCount} 节排课（{currentList.Count} 个固定时段）";
        }
        else
        {
            _statusLabel.Text = $"第 {_selectedWeek} 周共 {currentList.Count} 节排课（全学期共 {allCount} 节）";
        }
    }

    /// <summary>
    /// 将整学期内同一课程、同一星期、同一节次的所有排课合并为带完整周次范围（如 1-16周）的汇总条目
    /// </summary>
    private static List<CourseLesson> BuildSemesterConsolidatedLessons(List<CourseLesson> allLessons)
    {
        if (allLessons == null || allLessons.Count == 0) return new List<CourseLesson>();

        var grouped = new Dictionary<string, List<CourseLesson>>();
        var orderKeys = new List<string>();

        foreach (var l in allLessons)
        {
            string key = $"{l.CourseName}_{l.Weekday}_{l.StartTime}_{l.EndTime}_{l.Classroom}_{l.Teacher}";
            if (!grouped.ContainsKey(key))
            {
                orderKeys.Add(key);
                grouped[key] = new List<CourseLesson>();
            }
            grouped[key].Add(l);
        }

        var result = new List<CourseLesson>();
        int idx = 0;
        foreach (var key in orderKeys)
        {
            idx++;
            var items = grouped[key];
            var first = items[0];

            var weeks = items.Where(it => it.WeekIndex.HasValue && it.WeekIndex.Value > 0)
                             .Select(it => it.WeekIndex!.Value)
                             .Distinct()
                             .OrderBy(w => w)
                             .ToList();

            string weekDesc = weeks.Count > 0 ? CourseLesson.FormatWeekRanges(weeks) : "全学期";

            result.Add(new CourseLesson
            {
                Id = $"consolidated-{first.LessonId}-{idx}",
                LessonId = first.LessonId,
                CourseName = first.CourseName,
                CourseCode = first.CourseCode,
                Teacher = first.Teacher,
                Classroom = first.Classroom,
                AdminClassText = first.AdminClassText,
                DateString = weekDesc,
                StartTime = first.StartTime,
                EndTime = first.EndTime,
                StartUnit = first.StartUnit,
                EndUnit = first.EndUnit,
                WeekIndex = null,
                Weekday = first.Weekday,
                WeekText = weekDesc
            });
        }

        return result.OrderBy(l => l.Weekday).ThenBy(l => l.StartMinutes).ToList();
    }

    private UIElement CreateCourseCardElement(List<CourseLesson> items, bool isOngoingNow, bool isOverviewMode)
    {
        var primary = items[0];
        var palette = GetPaletteForCourse(primary.CourseName);

        var cardBorder = new Border
        {
            Background = new SolidColorBrush(palette.Bg),
            BorderBrush = isOngoingNow
                ? new SolidColorBrush(Color.FromRgb(22, 110, 245))
                : new SolidColorBrush(palette.Border),
            BorderThickness = new Thickness(3.5, 1, 1, 1),
            CornerRadius = new CornerRadius(6),
            Margin = new Thickness(3, 2, 3, 2),
            Padding = new Thickness(6, 4, 6, 4),
            Cursor = Cursors.Hand,
            ClipToBounds = true
        };

        var stack = new StackPanel();

        if (isOngoingNow)
        {
            var ongoingBadge = new Border
            {
                Background = new SolidColorBrush(Color.FromRgb(24, 118, 242)),
                CornerRadius = new CornerRadius(3),
                Padding = new Thickness(4, 1, 4, 1),
                HorizontalAlignment = HorizontalAlignment.Left,
                Margin = new Thickness(0, 0, 0, 2)
            };
            ongoingBadge.Child = new TextBlock
            {
                Text = "正在上课",
                FontSize = 9.5,
                FontWeight = FontWeights.Bold,
                Foreground = Brushes.White
            };
            stack.Children.Add(ongoingBadge);
        }

        // 课程名称
        stack.Children.Add(new TextBlock
        {
            Text = primary.CourseName,
            FontSize = 11,
            FontWeight = FontWeights.Bold,
            Foreground = new SolidColorBrush(palette.Text),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxHeight = 28,
            TextWrapping = TextWrapping.Wrap,
            LineHeight = 14,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight
        });

        // 全学期总览模式下：突出显示周次范围胶囊徽章
        if (isOverviewMode && !string.IsNullOrWhiteSpace(primary.WeekText))
        {
            var weekBadge = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(38, palette.Border.R, palette.Border.G, palette.Border.B)),
                CornerRadius = new CornerRadius(3),
                Padding = new Thickness(4, 1, 4, 1),
                HorizontalAlignment = HorizontalAlignment.Left,
                Margin = new Thickness(0, 2, 0, 0)
            };
            weekBadge.Child = new TextBlock
            {
                Text = primary.WeekText,
                FontSize = 9.5,
                FontWeight = FontWeights.Bold,
                Foreground = new SolidColorBrush(palette.Border)
            };
            stack.Children.Add(weekBadge);
        }

        // 教师
        if (!string.IsNullOrWhiteSpace(primary.Teacher))
        {
            stack.Children.Add(new TextBlock
            {
                Text = $"👨‍🏫 {primary.Teacher}",
                FontSize = 9.5,
                Foreground = new SolidColorBrush(Color.FromArgb(200, palette.Text.R, palette.Text.G, palette.Text.B)),
                TextTrimming = TextTrimming.CharacterEllipsis,
                Margin = new Thickness(0, 2, 0, 0)
            });
        }

        // 班级及人数摘要
        string classText = !string.IsNullOrWhiteSpace(primary.AdminClassText) ? primary.AdminClassText : primary.Classroom ?? "";
        if (!string.IsNullOrWhiteSpace(classText) && classText != _room.RoomName)
        {
            stack.Children.Add(new TextBlock
            {
                Text = $"👥 {classText}",
                FontSize = 9,
                Foreground = new SolidColorBrush(Color.FromArgb(170, palette.Text.R, palette.Text.G, palette.Text.B)),
                TextTrimming = TextTrimming.CharacterEllipsis,
                Margin = new Thickness(0, 1, 0, 0)
            });
        }

        // 节次时间
        stack.Children.Add(new TextBlock
        {
            Text = $"{primary.FormattedStartTime}~{primary.FormattedEndTime}",
            FontSize = 9,
            Foreground = new SolidColorBrush(Color.FromArgb(160, palette.Text.R, palette.Text.G, palette.Text.B)),
            Margin = new Thickness(0, 2, 0, 0)
        });

        // 重叠课程角标
        if (items.Count > 1)
        {
            var multiBadge = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(60, 0, 0, 0)),
                CornerRadius = new CornerRadius(3),
                Padding = new Thickness(3, 1, 3, 1),
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 2, 0, 0)
            };
            multiBadge.Child = new TextBlock
            {
                Text = $"+{items.Count - 1}门",
                FontSize = 8.5,
                FontWeight = FontWeights.Bold,
                Foreground = Brushes.White
            };
            stack.Children.Add(multiBadge);
        }

        cardBorder.Child = stack;

        // ToolTip 悬停明细
        var tipSb = new StringBuilder();
        for (int idx = 0; idx < items.Count; idx++)
        {
            var it = items[idx];
            if (idx > 0) tipSb.AppendLine("\n────────────");
            tipSb.AppendLine($"📖 课程：{it.CourseName}");
            if (!string.IsNullOrWhiteSpace(it.Teacher)) tipSb.AppendLine($"👨‍🏫 教师：{it.Teacher}");
            string itClass = !string.IsNullOrWhiteSpace(it.AdminClassText) ? it.AdminClassText : it.Classroom ?? "";
            if (!string.IsNullOrWhiteSpace(itClass)) tipSb.AppendLine($"👥 班级：{itClass}");
            tipSb.AppendLine($"⏰ 时间：{it.FormattedStartTime} ~ {it.FormattedEndTime}");
            tipSb.AppendLine($"📅 周次：{(!string.IsNullOrWhiteSpace(it.WeekText) ? it.WeekText : "全学期")}");
            if (!string.IsNullOrWhiteSpace(it.DateString) && it.DateString != it.WeekText)
            {
                tipSb.AppendLine($"🗓️ 日期：{it.DateString}");
            }
        }
        cardBorder.ToolTip = tipSb.ToString().TrimEnd();

        return cardBorder;
    }

    private (Color Bg, Color Border, Color Text) GetPaletteForCourse(string courseName)
    {
        var palettes = ThemeManager.Shared.IsDarkTheme ? CoursePaletteDark : CoursePaletteLight;
        if (string.IsNullOrEmpty(courseName)) return palettes[0];
        uint hash = 2166136261;
        foreach (char c in courseName)
        {
            hash ^= c;
            hash *= 16777619;
        }
        return palettes[hash % (uint)palettes.Length];
    }

    private List<CourseLesson> ResolveWeekLessons(int week)
    {
        if (_scheduleData != null && _scheduleData.Lessons.Count > 0)
        {
            return _scheduleData.Lessons
                .Where(l => l.WeekIndex == week || !l.WeekIndex.HasValue)
                .Where(l => l.Weekday >= 1 && l.Weekday <= 7 && l.StartMinutes >= 0 && l.EndMinutes > l.StartMinutes)
                .OrderBy(l => l.Weekday)
                .ThenBy(l => l.StartMinutes)
                .ToList();
        }

        // 兜底逻辑：若全学期排课 API 尚未获取到，自动将当日 Occupations 映射到周课表
        if (_room.Occupations.Count > 0)
        {
            int weekday = 1;
            if (DateTime.TryParse(_room.DateString, out var parsedDate))
            {
                weekday = (int)parsedDate.DayOfWeek == 0 ? 7 : (int)parsedDate.DayOfWeek;
            }

            var fallbackList = new List<CourseLesson>();
            foreach (var occ in _room.Occupations)
            {
                int sTime = ParseTimeToHhMm(occ.StartTimeString);
                int eTime = ParseTimeToHhMm(occ.EndTimeString);
                int su = occ.PeriodStart > 0 ? occ.PeriodStart : CourseLesson.CalculateStartUnit(sTime);
                int eu = occ.PeriodEnd > 0 ? occ.PeriodEnd : CourseLesson.CalculateEndUnit(eTime, su);

                fallbackList.Add(new CourseLesson
                {
                    Id = $"occ-{_room.RoomId}-{occ.CourseName}-{occ.StartTimeString}",
                    CourseName = !string.IsNullOrWhiteSpace(occ.CourseName) ? occ.CourseName : occ.CauseTitle,
                    Teacher = occ.Teacher,
                    Classroom = occ.CauseTitle,
                    AdminClassText = occ.CauseTitle,
                    Weekday = weekday,
                    StartUnit = su,
                    EndUnit = eu,
                    StartTime = sTime,
                    EndTime = eTime,
                    DateString = _room.DateString,
                    WeekIndex = week
                });
            }
            return fallbackList;
        }

        return new List<CourseLesson>();
    }

    private List<DateTime?> ResolveWeekDates(int week)
    {
        if (_scheduleData != null)
        {
            var dict = _scheduleData.DatesForWeek(week);
            if (dict.Count == 7)
            {
                var list = new List<DateTime?>();
                for (int d = 1; d <= 7; d++) list.Add(dict.ContainsKey(d) ? dict[d] : null);
                return list;
            }
        }

        int curWeek = CourseScheduleService.Shared.CurrentSchedule?.CalculatedCurrentWeek() ?? 1;
        var today = DateTime.Today;
        int todayIso = TodayIsoWeekday();
        var monday = today.AddDays(1 - todayIso + (week - curWeek) * 7);

        var fallbackDates = new List<DateTime?>();
        for (int d = 0; d < 7; d++)
        {
            fallbackDates.Add(monday.AddDays(d));
        }
        return fallbackDates;
    }

    private static int TodayIsoWeekday()
    {
        int day = (int)DateTime.Today.DayOfWeek;
        return day == 0 ? 7 : day;
    }

    private static int ParseTimeToHhMm(string timeStr)
    {
        var parts = timeStr.Split(':');
        if (parts.Length == 2 && int.TryParse(parts[0], out int h) && int.TryParse(parts[1], out int m))
        {
            return h * 100 + m;
        }
        return 800;
    }

    private static Button CreateSegmentPill(string text, bool isSelected, Action<object, RoutedEventArgs> onClick)
    {
        var btn = new Button
        {
            Content = text,
            Height = 24,
            Padding = new Thickness(10, 0, 10, 0),
            FontSize = 11.5,
            FontWeight = isSelected ? FontWeights.Bold : FontWeights.Normal,
            Background = isSelected ? new SolidColorBrush(Color.FromRgb(24, 112, 235)) : Brushes.Transparent,
            Foreground = isSelected ? Brushes.White : ThemeManager.Shared.TextSecondary,
            BorderThickness = new Thickness(0),
            Cursor = Cursors.Hand
        };
        btn.Click += (s, e) => onClick(s, e);
        return btn;
    }

    private static Button CreateToolbarButton(string text, Action<object, RoutedEventArgs> onClick)
    {
        var btn = new Button
        {
            Content = text,
            Height = 28,
            Padding = new Thickness(10, 0, 10, 0),
            FontSize = 12,
            Cursor = Cursors.Hand
        };
        btn.Click += (s, e) => onClick(s, e);
        return btn;
    }

    private static Button CreatePrimaryButton(string text, Action<object, RoutedEventArgs> onClick)
    {
        var btn = new Button
        {
            Content = text,
            Height = 28,
            Padding = new Thickness(12, 0, 12, 0),
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Background = new SolidColorBrush(Color.FromRgb(24, 112, 235)),
            Foreground = Brushes.White,
            BorderThickness = new Thickness(0),
            Cursor = Cursors.Hand
        };
        btn.Click += (s, e) => onClick(s, e);
        return btn;
    }
}

#endregion
