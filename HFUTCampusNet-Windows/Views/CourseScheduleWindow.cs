using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace HFUTCampusNet;

// ============================================================================
// 课程表窗口（完全独立 11 节行×7 天列网格 + 周次切换 + 课程卡片详情弹窗）
// ============================================================================
public class CourseScheduleWindow : Window
{
    public static readonly CourseScheduleWindow Shared = new();

    private int _selectedWeek = 1;
    private bool _hasAutoPositionedWeek;
    private DispatcherTimer? _clockTimer;
    private bool _suppressComboEvents;

    private readonly ComboBox _semesterCombo;
    private readonly Button _prevWeekBtn;
    private readonly ComboBox _weekCombo;
    private readonly Button _nextWeekBtn;
    private readonly Button _todayBtn;
    private readonly Button _classroomBtn;
    private readonly Button _academicBtn;
    private readonly TextBlock _pendingSurveyBadge;
    private readonly Button _syncBtn;
    private readonly TextBlock _statusLabel;
    private readonly Grid _timetableContainer;
    private Border _topBarBorder = null!;
    private TextBlock _titleText = null!;

    private static readonly (Color Bg, Color Border, Color Title, Color Sub)[] CoursePalette =
    {
        (Color.FromRgb(232, 242, 255), Color.FromRgb(64, 140, 255),  Color.FromRgb(18, 68, 150),  Color.FromRgb(48, 102, 185)),
        (Color.FromRgb(233, 250, 240), Color.FromRgb(52, 199, 110),  Color.FromRgb(18, 105, 52),  Color.FromRgb(45, 138, 80)),
        (Color.FromRgb(255, 243, 228), Color.FromRgb(255, 155, 45),  Color.FromRgb(145, 72, 8),   Color.FromRgb(178, 98, 28)),
        (Color.FromRgb(245, 236, 255), Color.FromRgb(162, 98, 248),  Color.FromRgb(88, 32, 158),  Color.FromRgb(118, 62, 188)),
        (Color.FromRgb(255, 235, 242), Color.FromRgb(245, 86, 135),  Color.FromRgb(148, 24, 68),  Color.FromRgb(178, 52, 96)),
        (Color.FromRgb(228, 248, 250), Color.FromRgb(38, 188, 205),  Color.FromRgb(12, 98, 112),  Color.FromRgb(38, 128, 142)),
        (Color.FromRgb(254, 248, 225), Color.FromRgb(235, 185, 28),  Color.FromRgb(128, 92, 6),   Color.FromRgb(158, 120, 24)),
        (Color.FromRgb(238, 240, 255), Color.FromRgb(98, 112, 245),  Color.FromRgb(38, 48, 152),  Color.FromRgb(68, 78, 182)),
        (Color.FromRgb(255, 238, 232), Color.FromRgb(248, 108, 75),  Color.FromRgb(148, 42, 18),  Color.FromRgb(178, 68, 42)),
        (Color.FromRgb(235, 248, 232), Color.FromRgb(112, 198, 68),  Color.FromRgb(42, 108, 18),  Color.FromRgb(68, 138, 42))
    };

    private static readonly (Color Bg, Color Border, Color Title, Color Sub)[] CoursePaletteDark =
    {
        (Color.FromRgb(29, 43, 61), Color.FromRgb(64, 140, 255), Color.FromRgb(199, 220, 255), Color.FromRgb(164, 193, 235)),
        (Color.FromRgb(27, 48, 39), Color.FromRgb(52, 199, 110), Color.FromRgb(194, 240, 211), Color.FromRgb(157, 213, 178)),
        (Color.FromRgb(54, 39, 27), Color.FromRgb(255, 155, 45), Color.FromRgb(255, 223, 190), Color.FromRgb(232, 190, 145)),
        (Color.FromRgb(45, 34, 59), Color.FromRgb(162, 98, 248), Color.FromRgb(224, 204, 255), Color.FromRgb(192, 163, 230)),
        (Color.FromRgb(55, 32, 42), Color.FromRgb(245, 86, 135), Color.FromRgb(255, 203, 221), Color.FromRgb(228, 161, 185)),
        (Color.FromRgb(27, 47, 51), Color.FromRgb(38, 188, 205), Color.FromRgb(190, 240, 245), Color.FromRgb(151, 207, 214)),
        (Color.FromRgb(51, 46, 27), Color.FromRgb(235, 185, 28), Color.FromRgb(249, 234, 177), Color.FromRgb(218, 198, 134)),
        (Color.FromRgb(34, 37, 61), Color.FromRgb(98, 112, 245), Color.FromRgb(204, 209, 255), Color.FromRgb(169, 174, 231)),
        (Color.FromRgb(56, 37, 31), Color.FromRgb(248, 108, 75), Color.FromRgb(255, 211, 197), Color.FromRgb(229, 176, 157)),
        (Color.FromRgb(34, 48, 29), Color.FromRgb(112, 198, 68), Color.FromRgb(209, 239, 194), Color.FromRgb(172, 211, 157))
    };

    private CourseScheduleWindow()
    {
        Title = "HFUT 课程表";
        Width = 1076;
        Height = 800;
        MinWidth = 896;
        MinHeight = 640;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(Color.FromRgb(246, 248, 251));

        Closing += (_, e) =>
        {
            e.Cancel = true;
            StopClockTimer();
            Hide();
        };

        var rootGrid = new Grid();
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(54) });
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // 顶部工具栏
        _topBarBorder = new Border
        {
            Background = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromRgb(228, 233, 242)),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Padding = new Thickness(16, 0, 16, 0)
        };

        var topBarGrid = new Grid();
        topBarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        topBarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        topBarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var leftControls = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center
        };

        _titleText = new TextBlock
        {
            Text = "学期课表",
            FontSize = 15,
            FontWeight = FontWeights.Bold,
            Foreground = new SolidColorBrush(Color.FromRgb(28, 36, 52)),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 10, 0)
        };
        leftControls.Children.Add(_titleText);

        _semesterCombo = new ComboBox
        {
            Width = 195,
            Height = 28,
            FontSize = 12,
            VerticalContentAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 10, 0)
        };
        _semesterCombo.SelectionChanged += OnSemesterChanged;
        leftControls.Children.Add(_semesterCombo);

        _prevWeekBtn = CreateToolbarButton("◀ 上周", OnPrevWeekClicked);
        leftControls.Children.Add(_prevWeekBtn);

        _weekCombo = new ComboBox
        {
            Width = 115,
            Height = 28,
            FontSize = 12,
            VerticalContentAlignment = VerticalAlignment.Center,
            Margin = new Thickness(4, 0, 4, 0)
        };
        for (int w = 1; w <= 22; w++)
        {
            _weekCombo.Items.Add($"第 {w} 周");
        }
        _weekCombo.SelectedIndex = 0;
        _weekCombo.SelectionChanged += OnWeekComboChanged;
        leftControls.Children.Add(_weekCombo);

        _nextWeekBtn = CreateToolbarButton("下周 ▶", OnNextWeekClicked);
        leftControls.Children.Add(_nextWeekBtn);

        _todayBtn = CreateToolbarButton("回到本周", OnBackToCurrentWeekClicked);
        _todayBtn.Margin = new Thickness(8, 0, 0, 0);
        leftControls.Children.Add(_todayBtn);

        _classroomBtn = CreateToolbarButton("教室课表", (_, _) => ClassroomScheduleWindow.Shared.ShowWindow());
        _classroomBtn.Margin = new Thickness(8, 0, 0, 0);
        leftControls.Children.Add(_classroomBtn);

        // 教务查询按钮 + 待评教角标
        var academicBtnGrid = new Grid { Margin = new Thickness(8, 0, 0, 0) };
        _academicBtn = CreateToolbarButton("🎓 教务查询", (_, _) => AcademicWindow.Shared.ShowWindow(0));
        academicBtnGrid.Children.Add(_academicBtn);

        var badgeBorder = new Border
        {
            Background = new SolidColorBrush(Color.FromRgb(235, 65, 65)),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(5, 1, 5, 1),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, -5, -6, 0),
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false
        };
        _pendingSurveyBadge = new TextBlock
        {
            Text = "0",
            FontSize = 9.5,
            FontWeight = FontWeights.Bold,
            Foreground = Brushes.White
        };
        badgeBorder.Child = _pendingSurveyBadge;
        academicBtnGrid.Children.Add(badgeBorder);
        leftControls.Children.Add(academicBtnGrid);

        Grid.SetColumn(leftControls, 0);
        topBarGrid.Children.Add(leftControls);

        var rightControls = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center
        };

        _statusLabel = new TextBlock
        {
            Text = "未同步",
            FontSize = 11.5,
            Foreground = new SolidColorBrush(Color.FromRgb(115, 126, 145)),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 12, 0)
        };
        rightControls.Children.Add(_statusLabel);

        _syncBtn = CreatePrimaryButton("🔄 同步课表", OnSyncButtonClicked);
        rightControls.Children.Add(_syncBtn);

        Grid.SetColumn(rightControls, 2);
        topBarGrid.Children.Add(rightControls);

        _topBarBorder.Child = topBarGrid;
        Grid.SetRow(_topBarBorder, 0);
        rootGrid.Children.Add(_topBarBorder);

        // 课表主画布
        var scrollViewer = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Padding = new Thickness(12, 10, 12, 12)
        };

        _timetableContainer = new Grid
        {
            MinHeight = 640
        };
        scrollViewer.Content = _timetableContainer;
        Grid.SetRow(scrollViewer, 1);
        rootGrid.Children.Add(scrollViewer);

        Content = rootGrid;

        ThemeManager.Shared.ApplyWindowTheme(this);
        ApplyTheme();
        ThemeManager.Shared.ThemeChanged += () => AppEvents.InvokeOnUI(() =>
        {
            ApplyTheme();
            ReloadInterface(false);
        });

        AppEvents.CourseScheduleUpdated += () => AppEvents.InvokeOnUI(() => ReloadInterface(false));
        AppEvents.AcademicDataUpdated += () => AppEvents.InvokeOnUI(UpdatePendingSurveyBadge);
    }

    private void ApplyTheme()
    {
        ThemeManager.Shared.ApplyWindowTheme(this);
        Background = ThemeManager.Shared.WindowBackground;
        Foreground = ThemeManager.Shared.TextPrimary;

        if (_topBarBorder != null)
        {
            _topBarBorder.Background = ThemeManager.Shared.TopBarBackground;
            _topBarBorder.BorderBrush = ThemeManager.Shared.CardBorderBrush;
        }

        if (_titleText != null)
        {
            _titleText.Foreground = ThemeManager.Shared.TextPrimary;
        }

        if (_statusLabel != null)
        {
            _statusLabel.Foreground = ThemeManager.Shared.TextSecondary;
        }

        ThemeManager.Shared.ApplyComboBoxTheme(_semesterCombo);
        ThemeManager.Shared.ApplyComboBoxTheme(_weekCombo);
    }

    public void ShowWindow()
    {
        ApplyTheme();
        if (!IsVisible)
        {
            Show();
        }
        if (WindowState == WindowState.Minimized)
        {
            WindowState = WindowState.Normal;
        }
        Activate();
        Topmost = true;
        Topmost = false;
        Focus();

        StartClockTimer();
        ReloadInterface(autoPositionWeek: !_hasAutoPositionedWeek);
        UpdatePendingSurveyBadge();

        if (CourseScheduleService.Shared.CurrentSchedule == null)
        {
            TriggerSync(false);
        }
    }

    private void StartClockTimer()
    {
        StopClockTimer();
        _clockTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(60)
        };
        _clockTimer.Tick += (_, _) => RenderTimetableGrid();
        _clockTimer.Start();
    }

    private void StopClockTimer()
    {
        if (_clockTimer != null)
        {
            _clockTimer.Stop();
            _clockTimer = null;
        }
    }

    private void UpdatePendingSurveyBadge()
    {
        int pending = AcademicService.Shared.LatestData?.PendingSurveyCount ?? 0;
        if (_pendingSurveyBadge.Parent is Border badgeBorder)
        {
            if (pending > 0)
            {
                _pendingSurveyBadge.Text = pending > 99 ? "99+" : pending.ToString();
                badgeBorder.Visibility = Visibility.Visible;
                _academicBtn.ToolTip = $"教务查询（有 {pending} 门课程待评教）";
            }
            else
            {
                badgeBorder.Visibility = Visibility.Collapsed;
                _academicBtn.ToolTip = "打开成绩单、考试安排与评教查询";
            }
        }
    }

    private void ReloadInterface(bool autoPositionWeek)
    {
        var schedule = CourseScheduleService.Shared.CurrentSchedule;
        if (schedule?.Lessons != null && schedule.Lessons.Count > 0)
        {
            CourseLesson.EnrichLessons(schedule.Lessons);
        }

        _suppressComboEvents = true;
        try
        {
            _semesterCombo.Items.Clear();
            if (schedule != null && schedule.Semesters.Count > 0)
            {
                int selectedIdx = 0;
                for (int i = 0; i < schedule.Semesters.Count; i++)
                {
                    var sem = schedule.Semesters[i];
                    _semesterCombo.Items.Add(new ComboBoxItem
                    {
                        Content = sem.NameZh,
                        Tag = sem.Id
                    });
                    if (sem.Id == schedule.CurrentSemesterId)
                    {
                        selectedIdx = i;
                    }
                }
                _semesterCombo.SelectedIndex = selectedIdx;
                _semesterCombo.IsEnabled = true;
            }
            else
            {
                _semesterCombo.Items.Add(new ComboBoxItem
                {
                    Content = schedule?.CurrentSemesterName ?? "当前学期",
                    Tag = schedule?.CurrentSemesterId ?? ""
                });
                _semesterCombo.SelectedIndex = 0;
                _semesterCombo.IsEnabled = false;
            }

            int maxWeek = Math.Max(20, schedule?.MaxWeek ?? 20);
            int? currentCalculatedWeek = schedule?.CurrentWeek();
            _todayBtn.IsEnabled = currentCalculatedWeek.HasValue;

            if (autoPositionWeek || _selectedWeek < 1 || _selectedWeek > maxWeek)
            {
                _selectedWeek = Math.Clamp(currentCalculatedWeek ?? 1, 1, maxWeek);
                _hasAutoPositionedWeek = true;
            }

            _weekCombo.Items.Clear();
            for (int w = 1; w <= maxWeek; w++)
            {
                string suffix = (currentCalculatedWeek == w) ? " (本周)" : "";
                _weekCombo.Items.Add($"第 {w} 周{suffix}");
            }
            _weekCombo.SelectedIndex = Math.Clamp(_selectedWeek - 1, 0, _weekCombo.Items.Count - 1);

            _prevWeekBtn.IsEnabled = _selectedWeek > 1;
            _nextWeekBtn.IsEnabled = _selectedWeek < maxWeek;

            if (schedule != null)
            {
                string syncTimeStr = schedule.LastSyncTime?.ToString("MM-dd HH:mm") ?? "--";
                _statusLabel.Text = $"{schedule.CurrentSemesterName} · 共 {schedule.Items.Count} 门课 · 更新于 {syncTimeStr}";
            }
            else
            {
                _statusLabel.Text = "暂无本地课表缓存，请点击右上角「同步课表」";
            }
        }
        finally
        {
            _suppressComboEvents = false;
        }

        RenderTimetableGrid();
    }

    private void RenderTimetableGrid()
    {
        _timetableContainer.Children.Clear();
        _timetableContainer.RowDefinitions.Clear();
        _timetableContainer.ColumnDefinitions.Clear();

        var schedule = CourseScheduleService.Shared.CurrentSchedule;
        if (schedule == null)
        {
            RenderEmptyPlaceholder();
            return;
        }

        // 与 macOS 版保持一致：以课程数据中的真实时间定位课程，不再按过期的固定节次表排版。
        var weekCourses = schedule.Courses(forWeek: _selectedWeek)
            .Where(c => c.Weekday >= 1 && c.Weekday <= 7
                && c.StartMinutes >= 0 && c.EndMinutes > c.StartMinutes && c.EndMinutes <= 24 * 60)
            .OrderBy(c => c.Weekday)
            .ThenBy(c => c.StartMinutes)
            .ThenBy(c => c.EndMinutes)
            .ToList();

        int minLessonHour = weekCourses.Count > 0 ? weekCourses.Min(c => c.StartMinutes) / 60 : 8;
        int maxLessonHour = weekCourses.Count > 0 ? (weekCourses.Max(c => c.EndMinutes) + 59) / 60 : 22;
        int startHour = Math.Min(8, minLessonHour);
        int endHour = Math.Min(24, Math.Max(22, maxLessonHour));
        int totalHours = Math.Max(1, endHour - startHour);
        const double hourHeight = 54.0;
        double timelineHeight = totalHours * hourHeight;

        // 外层卡片边框
        var outerCard = new Border
        {
            Background = ThemeManager.Shared.TableBackground,
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            ClipToBounds = true
        };

        var tableGrid = new Grid();
        // 列：第0列为时间刻度栏(74px)，第1~7列为周一至周日(1*)
        tableGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(74) });
        for (int d = 1; d <= 7; d++)
        {
            tableGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        }

        // 行：表头 + 按小时等高的实际时间轴。
        tableGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(48) });
        tableGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(timelineHeight) });

        var weekDates = GetDatesForWeek(schedule, _selectedWeek);
        var now = CourseCalendarHelper.BeijingNow;
        var today = now.Date;
        int currentWeekday = CourseCalendarHelper.Weekday(now);
        int currentMinutes = now.Hour * 60 + now.Minute;
        int? currentCalculatedWeek = schedule.CurrentWeek();
        bool isViewingCurrentWeek = currentCalculatedWeek.HasValue && _selectedWeek == currentCalculatedWeek.Value;

        // 左上角时间表头
        var cornerBorder = new Border
        {
            Background = ThemeManager.Shared.TableHeaderBackground,
            BorderBrush = ThemeManager.Shared.TableGridLineBrush,
            BorderThickness = new Thickness(0, 0, 1, 1)
        };
        string monthHeader = weekDates.Count > 0 && weekDates[0].HasValue
            ? $"{weekDates[0]!.Value.Month}月"
            : $"第{_selectedWeek}周";
        cornerBorder.Child = new TextBlock
        {
            Text = monthHeader,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeManager.Shared.TextSecondary,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetRow(cornerBorder, 0);
        Grid.SetColumn(cornerBorder, 0);
        tableGrid.Children.Add(cornerBorder);

        string[] weekdayNames = { "周一", "周二", "周三", "周四", "周五", "周六", "周日" };
        for (int d = 1; d <= 7; d++)
        {
            DateTime? dayDate = (d - 1 < weekDates.Count) ? weekDates[d - 1] : null;
            bool isToday = dayDate.HasValue
                ? dayDate.Value.Date == today
                : (isViewingCurrentWeek && d == currentWeekday);

            var headerBorder = new Border
            {
                Background = isToday
                    ? new SolidColorBrush(Color.FromArgb(ThemeManager.Shared.IsDarkTheme ? (byte)36 : (byte)24, 10, 132, 255))
                    : ThemeManager.Shared.TableHeaderBackground,
                BorderBrush = ThemeManager.Shared.TableGridLineBrush,
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
                    ? ThemeManager.Shared.Accent
                    : ThemeManager.Shared.TextPrimary,
                HorizontalAlignment = HorizontalAlignment.Center
            });

            if (dayDate.HasValue)
            {
                headerStack.Children.Add(new TextBlock
                {
                    Text = dayDate.Value.ToString("MM/dd"),
                    FontSize = 10.5,
                    Foreground = isToday
                        ? ThemeManager.Shared.Accent
                        : ThemeManager.Shared.TextMuted,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Margin = new Thickness(0, 1, 0, 0)
                });
            }

            headerBorder.Child = headerStack;
            Grid.SetRow(headerBorder, 0);
            Grid.SetColumn(headerBorder, d);
            tableGrid.Children.Add(headerBorder);

            // 今日整列淡蓝高亮底色
            if (isToday)
            {
                var todayColHighlight = new Border
                {
                    Background = new SolidColorBrush(Color.FromArgb(ThemeManager.Shared.IsDarkTheme ? (byte)20 : (byte)12, 10, 132, 255)),
                    IsHitTestVisible = false
                };
                Grid.SetRow(todayColHighlight, 1);
                Grid.SetRowSpan(todayColHighlight, 1);
                Grid.SetColumn(todayColHighlight, d);
                tableGrid.Children.Add(todayColHighlight);
            }
        }

        // 左侧小时刻度；时间轴和课程卡片都使用分钟数换算纵向位置。
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
                BorderBrush = ThemeManager.Shared.TableGridLineBrush,
                BorderThickness = new Thickness(0, 0, 1, 1)
            };
            Grid.SetRow(axisCell, hourIndex);
            timeAxis.Children.Add(axisCell);
        }
        var timeLabels = new Canvas { IsHitTestVisible = false };
        for (int hour = startHour; hour <= endHour; hour++)
        {
            var timeLabel = new TextBlock
            {
                Text = $"{hour:D2}:00",
                Width = 64,
                Height = 16,
                TextAlignment = TextAlignment.Right,
                FontSize = 11,
                FontWeight = FontWeights.Medium,
                Foreground = ThemeManager.Shared.TextSecondary
            };
            Canvas.SetLeft(timeLabel, 3);
            Canvas.SetTop(timeLabel, Math.Max(0, (hour - startHour) * hourHeight - 8));
            timeLabels.Children.Add(timeLabel);
        }
        Grid.SetRowSpan(timeLabels, totalHours);
        timeAxis.Children.Add(timeLabels);
        Grid.SetRow(timeAxis, 1);
        Grid.SetColumn(timeAxis, 0);
        tableGrid.Children.Add(timeAxis);

        // 每日小时网格与精确课程卡片。
        for (int day = 1; day <= 7; day++)
        {
            DateTime? dayDate = day - 1 < weekDates.Count ? weekDates[day - 1] : null;
            bool isToday = dayDate.HasValue
                ? dayDate.Value.Date == today
                : isViewingCurrentWeek && day == currentWeekday;

            var dayGrid = new Grid
            {
                Background = isToday
                    ? new SolidColorBrush(Color.FromArgb(ThemeManager.Shared.IsDarkTheme ? (byte)20 : (byte)12, 10, 132, 255))
                    : Brushes.Transparent,
                ClipToBounds = true
            };
            for (int hourIndex = 0; hourIndex < totalHours; hourIndex++)
            {
                dayGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(hourHeight) });
                var hourCell = new Border
                {
                    BorderBrush = ThemeManager.Shared.TableGridLineBrush,
                    BorderThickness = new Thickness(0, 0, day < 7 ? 1 : 0, 1),
                    IsHitTestVisible = false
                };
                Grid.SetRow(hourCell, hourIndex);
                dayGrid.Children.Add(hourCell);
            }

            var dayCourses = weekCourses.Where(c => c.Weekday == day).ToList();
            var overlapGroups = new List<List<CourseScheduleItem>>();
            foreach (var course in dayCourses)
            {
                if (overlapGroups.Count == 0 || course.StartMinutes >= overlapGroups[^1].Max(c => c.EndMinutes))
                {
                    overlapGroups.Add(new List<CourseScheduleItem> { course });
                }
                else
                {
                    overlapGroups[^1].Add(course);
                }
            }

            foreach (var group in overlapGroups)
            {
                int groupStartMin = group.Min(c => c.StartMinutes);
                int groupEndMin = group.Max(c => c.EndMinutes);
                int groupStartHour = groupStartMin / 60;
                int groupEndHour = (groupEndMin + 59) / 60;
                int parentStartRow = Math.Clamp(groupStartHour - startHour, 0, totalHours - 1);
                int parentEndRow = Math.Clamp(groupEndHour - startHour, parentStartRow + 1, totalHours);

                var laneEnds = new List<int>();
                var assignedLanes = new List<int>();
                foreach (var course in group)
                {
                    int lane = laneEnds.FindIndex(end => end <= course.StartMinutes);
                    if (lane < 0)
                    {
                        lane = laneEnds.Count;
                        laneEnds.Add(course.EndMinutes);
                    }
                    else
                    {
                        laneEnds[lane] = course.EndMinutes;
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
                dayGrid.Children.Add(groupGrid);

                for (int index = 0; index < group.Count; index++)
                {
                    var course = group[index];
                    int courseStartHour = course.StartMinutes / 60;
                    int courseEndHour = (course.EndMinutes + 59) / 60;
                    int localStartRow = Math.Clamp(courseStartHour - groupStartHour, 0, groupGrid.RowDefinitions.Count - 1);
                    int localEndRow = Math.Clamp(courseEndHour - groupStartHour, localStartRow + 1, groupGrid.RowDefinitions.Count);
                    double topInset = course.StartMinutes % 60 / 60.0 * hourHeight;
                    int endRemainder = course.EndMinutes % 60;
                    double bottomInset = endRemainder == 0 ? 0 : (60 - endRemainder) / 60.0 * hourHeight;
                    bool isOngoingNow = isViewingCurrentWeek && day == currentWeekday
                        && currentMinutes >= course.StartMinutes && currentMinutes < course.EndMinutes;

                    var card = CreateCourseBlockElement(new List<CourseScheduleItem> { course }, isOngoingNow);
                    if (card is FrameworkElement cardElement)
                        cardElement.Margin = new Thickness(3, topInset + 2, 3, bottomInset + 2);
                    Grid.SetRow(card, localStartRow);
                    Grid.SetRowSpan(card, localEndRow - localStartRow);
                    Grid.SetColumn(card, assignedLanes[index]);
                    groupGrid.Children.Add(card);
                }
            }

            // 当前时间线按真实时刻落位。
            if (isViewingCurrentWeek && day == currentWeekday
                && currentMinutes >= startHour * 60 && currentMinutes < endHour * 60)
            {
                int row = Math.Clamp(currentMinutes / 60 - startHour, 0, totalHours - 1);
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
                dayGrid.Children.Add(indicator);
            }

            Grid.SetRow(dayGrid, 1);
            Grid.SetColumn(dayGrid, day);
            tableGrid.Children.Add(dayGrid);
        }

        outerCard.Child = tableGrid;
        _timetableContainer.Children.Add(outerCard);
    }

    private UIElement CreateCourseBlockElement(List<CourseScheduleItem> items, bool isOngoingNow)
    {
        var primary = items[0];
        var palette = GetPaletteForCourse(primary.CourseName);

        var cardBorder = new Border
        {
            Background = new SolidColorBrush(palette.Bg),
            BorderBrush = isOngoingNow
                ? ThemeManager.Shared.Accent
                : new SolidColorBrush(palette.Border),
            BorderThickness = new Thickness(4, 1, 1, 1),
            CornerRadius = new CornerRadius(6),
            Margin = new Thickness(3, 2, 3, 2),
            Padding = new Thickness(6, 5, 6, 4),
            Cursor = Cursors.Hand,
            ClipToBounds = true
        };

        var contentGrid = new Grid();
        var stack = new StackPanel();

        if (isOngoingNow)
        {
            var ongoingBadge = new Border
            {
                Background = ThemeManager.Shared.Accent,
                CornerRadius = new CornerRadius(3),
                Padding = new Thickness(4, 1, 4, 1),
                HorizontalAlignment = HorizontalAlignment.Left,
                Margin = new Thickness(0, 0, 0, 3)
            };
            ongoingBadge.Child = new TextBlock
            {
                Text = "正在上课",
                FontSize = 9,
                FontWeight = FontWeights.Bold,
                Foreground = Brushes.White
            };
            stack.Children.Add(ongoingBadge);
        }

        stack.Children.Add(new TextBlock
        {
            Text = primary.CourseName,
            FontSize = 11.5,
            FontWeight = FontWeights.Bold,
            Foreground = new SolidColorBrush(palette.Title),
            TextWrapping = TextWrapping.Wrap,
            MaxHeight = 34,
            TextTrimming = TextTrimming.CharacterEllipsis
        });

        string roomDisplay = primary.SimplifiedRoomText;
        if (!string.IsNullOrWhiteSpace(roomDisplay) && roomDisplay != "未安排教室")
        {
            stack.Children.Add(new TextBlock
            {
                Text = $"@{roomDisplay}",
                FontSize = 10.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = new SolidColorBrush(palette.Sub),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 2, 0, 0)
            });
        }

        if (!string.IsNullOrWhiteSpace(primary.TeachersText) && primary.TeachersText != "未知教师")
        {
            stack.Children.Add(new TextBlock
            {
                Text = primary.TeachersText,
                FontSize = 10,
                Foreground = new SolidColorBrush(palette.Sub),
                Opacity = 0.85,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Margin = new Thickness(0, 2, 0, 0)
            });
        }

        contentGrid.Children.Add(stack);

        if (items.Count > 1)
        {
            var multiBadge = new Border
            {
                Background = new SolidColorBrush(palette.Border),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(4, 1, 4, 1),
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top
            };
            multiBadge.Child = new TextBlock
            {
                Text = $"+{items.Count - 1}重课",
                FontSize = 9,
                FontWeight = FontWeights.Bold,
                Foreground = Brushes.White
            };
            contentGrid.Children.Add(multiBadge);
        }

        cardBorder.Child = contentGrid;
        cardBorder.ToolTip = BuildCourseTooltipText(items);
        cardBorder.MouseLeftButtonUp += (_, _) => ShowCourseDetailDialog(items);

        return cardBorder;
    }

    private static string BuildCourseTooltipText(List<CourseScheduleItem> items)
    {
        var lines = new List<string>();
        for (int i = 0; i < items.Count; i++)
        {
            var item = items[i];
            if (i > 0) lines.Add("────────────────────");
            lines.Add($"课程：{item.CourseName}");
            lines.Add($"教室：{item.RoomText}");
            lines.Add($"教师：{item.TeachersText}");
            lines.Add($"上课时间：周{WeekdayName(item.Weekday)} {item.StartTimeText}-{item.EndTimeText}");
            lines.Add($"周次：{item.WeekText}");
            if (!string.IsNullOrWhiteSpace(item.LessonCode))
            {
                lines.Add($"教学班：{item.LessonCode} ({item.CreditsText})");
            }
        }
        return string.Join(Environment.NewLine, lines);
    }

    private void ShowCourseDetailDialog(List<CourseScheduleItem> items)
    {
        var dialog = new Window
        {
            Title = items.Count > 1 ? $"课程详情（共 {items.Count} 门同时间段课程）" : "课程详情",
            Width = 440,
            SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = this,
            Background = ThemeManager.Shared.WindowBackground,
            Foreground = ThemeManager.Shared.TextPrimary
        };

        var rootStack = new StackPanel { Margin = new Thickness(20, 18, 20, 18) };

        for (int i = 0; i < items.Count; i++)
        {
            var item = items[i];
            var palette = GetPaletteForCourse(item.CourseName);

            var card = new Border
            {
                Background = new SolidColorBrush(palette.Bg),
                BorderBrush = new SolidColorBrush(palette.Border),
                BorderThickness = new Thickness(4, 1, 1, 1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(14, 12, 14, 12),
                Margin = new Thickness(0, 0, 0, 12)
            };

            var cStack = new StackPanel();
            cStack.Children.Add(new TextBlock
            {
                Text = item.CourseName,
                FontSize = 15,
                FontWeight = FontWeights.Bold,
                Foreground = new SolidColorBrush(palette.Title),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 8)
            });

            AddDetailRow(cStack, "上课地点", item.RoomText);
            AddDetailRow(cStack, "授课教师", item.TeachersText);
            AddDetailRow(cStack, "上课时间", $"周{WeekdayName(item.Weekday)} {item.StartTimeText} - {item.EndTimeText}");
            AddDetailRow(cStack, "上课周次", item.WeekText);
            if (!string.IsNullOrWhiteSpace(item.CreditsText))
            {
                AddDetailRow(cStack, "课程学分", item.CreditsText);
            }
            if (!string.IsNullOrWhiteSpace(item.LessonCode))
            {
                AddDetailRow(cStack, "教学班号", item.LessonCode);
            }

            card.Child = cStack;
            rootStack.Children.Add(card);
        }

        var closeBtn = CreatePrimaryButton("我知道了", (_, _) => dialog.Close());
        closeBtn.HorizontalAlignment = HorizontalAlignment.Right;
        closeBtn.Width = 96;
        rootStack.Children.Add(closeBtn);

        dialog.Content = rootStack;
        ThemeManager.Shared.ApplyWindowTheme(dialog);
        dialog.ShowDialog();
    }

    private static void AddDetailRow(StackPanel parent, string label, string value)
    {
        var row = new Grid { Margin = new Thickness(0, 2, 0, 2) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(68) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var lbl = new TextBlock
        {
            Text = label + "：",
            FontSize = 12,
            Foreground = ThemeManager.Shared.TextSecondary
        };
        var val = new TextBlock
        {
            Text = string.IsNullOrWhiteSpace(value) ? "—" : value,
            FontSize = 12,
            FontWeight = FontWeights.Medium,
            Foreground = ThemeManager.Shared.TextPrimary,
            TextWrapping = TextWrapping.Wrap
        };
        Grid.SetColumn(lbl, 0);
        Grid.SetColumn(val, 1);
        row.Children.Add(lbl);
        row.Children.Add(val);
        parent.Children.Add(row);
    }

    private void RenderEmptyPlaceholder()
    {
        var card = new Border
        {
            Background = ThemeManager.Shared.CardBackground,
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(32)
        };

        var stack = new StackPanel
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };

        stack.Children.Add(new TextBlock
        {
            Text = "📅 暂无课程表数据",
            FontSize = 17,
            FontWeight = FontWeights.Bold,
            Foreground = ThemeManager.Shared.TextPrimary,
            HorizontalAlignment = HorizontalAlignment.Center
        });

        stack.Children.Add(new TextBlock
        {
            Text = "点击右上角「同步课表」即可通过统一身份认证拉取本学期完整课表。",
            FontSize = 12.5,
            Foreground = ThemeManager.Shared.TextSecondary,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 8, 0, 16)
        });

        var syncNowBtn = CreatePrimaryButton("🔄 立即同步课表", OnSyncButtonClicked);
        syncNowBtn.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(syncNowBtn);

        card.Child = stack;
        _timetableContainer.Children.Add(card);
    }

    private void OnSemesterChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressComboEvents) return;
        if (_semesterCombo.SelectedItem is ComboBoxItem item && item.Tag is string semId && !string.IsNullOrWhiteSpace(semId))
        {
            var currentId = CourseScheduleService.Shared.CurrentSchedule?.CurrentSemesterId;
            if (semId == currentId) return;

            var previousSemesterId = currentId ?? SettingsManager.Shared.CourseSemesterId;
            var previousSemesterManuallySelected = SettingsManager.Shared.CourseSemesterIdManuallySelected;
            var accountGeneration = AccountSessionManager.Generation;
            _statusLabel.Text = "正在切换学期并拉取课表...";
            _syncBtn.IsEnabled = false;
            _semesterCombo.IsEnabled = false;
            CourseScheduleService.Shared.SwitchSemester(semId, (data, err) =>
            {
                AppEvents.InvokeOnUI(() =>
                {
                    _syncBtn.IsEnabled = true;
                    if (!AccountSessionManager.IsGenerationCurrent(accountGeneration))
                    {
                        ReloadInterface(autoPositionWeek: false);
                        return;
                    }

                    var currentSchedule = CourseScheduleService.Shared.CurrentSchedule;
                    if (data != null || currentSchedule?.CurrentSemesterId == semId)
                    {
                        _hasAutoPositionedWeek = false;
                        ReloadInterface(autoPositionWeek: true);
                    }
                    else
                    {
                        if (SettingsManager.Shared.CourseSemesterId == semId)
                        {
                            SettingsManager.Shared.CourseSemesterId = previousSemesterId;
                            SettingsManager.Shared.CourseSemesterIdManuallySelected = previousSemesterManuallySelected;
                            SettingsManager.Shared.Save();
                        }
                        ReloadInterface(autoPositionWeek: false);
                        _statusLabel.Text = $"切换学期失败：{err ?? "未知错误"}，已恢复原学期课表";
                    }
                });
            });
        }
    }

    private void OnPrevWeekClicked(object sender, RoutedEventArgs e)
    {
        if (_selectedWeek > 1)
        {
            _selectedWeek--;
            ReloadInterface(autoPositionWeek: false);
        }
    }

    private void OnNextWeekClicked(object sender, RoutedEventArgs e)
    {
        int maxWeek = Math.Max(20, CourseScheduleService.Shared.CurrentSchedule?.MaxWeek ?? 20);
        if (_selectedWeek < maxWeek)
        {
            _selectedWeek++;
            ReloadInterface(autoPositionWeek: false);
        }
    }

    private void OnWeekComboChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressComboEvents) return;
        if (_weekCombo.SelectedIndex >= 0)
        {
            _selectedWeek = _weekCombo.SelectedIndex + 1;
            ReloadInterface(autoPositionWeek: false);
        }
    }

    private void OnBackToCurrentWeekClicked(object sender, RoutedEventArgs e)
    {
        var schedule = CourseScheduleService.Shared.CurrentSchedule;
        if (schedule?.CurrentWeek() is not int currentWeek) return;
        _selectedWeek = currentWeek;
        ReloadInterface(autoPositionWeek: false);
    }

    private void OnSyncButtonClicked(object sender, RoutedEventArgs e)
    {
        TriggerSync(interactiveIfNeedLogin: true);
    }

    private void TriggerSync(bool interactiveIfNeedLogin)
    {
        _statusLabel.Text = "正在同步教务系统课表...";
        _syncBtn.IsEnabled = false;

        CourseScheduleService.Shared.SyncSchedule((data, err) =>
        {
            AppEvents.InvokeOnUI(() =>
            {
                _syncBtn.IsEnabled = true;
                if (data != null)
                {
                    _hasAutoPositionedWeek = false;
                    ReloadInterface(autoPositionWeek: true);
                }
                else
                {
                    string errMsg = err ?? "获取课表失败";
                    _statusLabel.Text = errMsg;
                    if (interactiveIfNeedLogin && (errMsg.Contains("登录") || errMsg.Contains("认证") || errMsg.Contains("会话")))
                    {
                        var result = MessageBox.Show(
                            this,
                            $"{errMsg}\n\n是否打开统一身份认证登录窗口？",
                            "同步课表需要认证",
                            MessageBoxButton.YesNo,
                            MessageBoxImage.Information);
                        if (result == MessageBoxResult.Yes)
                        {
                            CourseLoginWebWindow.Shared.ShowLoginWindow();
                        }
                    }
                }
            });
        });
    }

    private static List<DateTime?> GetDatesForWeek(CourseScheduleData schedule, int week)
    {
        var result = new List<DateTime?>();
        if (!string.IsNullOrWhiteSpace(schedule.SemesterStartDateString) &&
            DateTime.TryParse(schedule.SemesterStartDateString, out var startDate))
        {
            var weekMonday = startDate.Date.AddDays((week - 1) * 7);
            for (int i = 0; i < 7; i++)
            {
                result.Add(weekMonday.AddDays(i));
            }
        }
        else
        {
            for (int i = 0; i < 7; i++)
            {
                result.Add(null);
            }
        }
        return result;
    }

    private static (Color Bg, Color Border, Color Title, Color Sub) GetPaletteForCourse(string courseName)
    {
        var palette = ThemeManager.Shared.IsDarkTheme ? CoursePaletteDark : CoursePalette;
        if (string.IsNullOrEmpty(courseName))
            return palette[0];
        uint hash = 2166136261;
        foreach (char c in courseName)
        {
            hash ^= c;
            hash *= 16777619;
        }
        return palette[hash % (uint)palette.Length];
    }

    private static string WeekdayName(int weekday) => weekday switch
    {
        1 => "一",
        2 => "二",
        3 => "三",
        4 => "四",
        5 => "五",
        6 => "六",
        7 => "日",
        _ => weekday.ToString()
    };

    internal static Button CreateToolbarButton(string text, RoutedEventHandler onClick)
    {
        var btn = new Button
        {
            Content = text,
            Height = 28,
            Padding = new Thickness(10, 0, 10, 0),
            FontSize = 12,
            BorderThickness = new Thickness(1),
            Cursor = Cursors.Hand
        };
        btn.SetResourceReference(System.Windows.Controls.Control.BackgroundProperty, "HFUT.ControlBackground");
        btn.SetResourceReference(System.Windows.Controls.Control.ForegroundProperty, "HFUT.TextPrimary");
        btn.SetResourceReference(System.Windows.Controls.Control.BorderBrushProperty, "HFUT.ControlBorderBrush");
        btn.Click += onClick;
        return btn;
    }

    internal static Button CreatePrimaryButton(string text, RoutedEventHandler onClick)
    {
        var btn = new Button
        {
            Content = text,
            Height = 28,
            Padding = new Thickness(12, 0, 12, 0),
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            BorderThickness = new Thickness(0),
            Cursor = Cursors.Hand
        };
        btn.SetResourceReference(System.Windows.Controls.Control.BackgroundProperty, "HFUT.Accent");
        btn.SetResourceReference(System.Windows.Controls.Control.ForegroundProperty, "HFUT.OnAccent");
        btn.SetResourceReference(System.Windows.Controls.Control.BorderBrushProperty, "HFUT.Accent");
        btn.Click += onClick;
        return btn;
    }
}

// ============================================================================
// 教室课表独立窗口（按校区 → 教学楼 → 教室 → 学期 → 周次 查询整周排课）
// ============================================================================
public class ClassroomScheduleWindow : Window
{
    public static readonly ClassroomScheduleWindow Shared = new();

    private readonly ComboBox _campusCombo;
    private readonly ComboBox _buildingCombo;
    private readonly ComboBox _roomCombo;
    private readonly ComboBox _semesterCombo;
    private readonly Button _prevWeekBtn;
    private readonly ComboBox _weekCombo;
    private readonly Button _nextWeekBtn;
    private readonly Button _queryBtn;
    private readonly TextBlock _statusLabel;
    private readonly Grid _timetableContainer;
    private Border _topBar = null!;

    private bool _suppressSelectionEvents;
    private int _selectedWeek = 1;
    private int _buildingLoadGeneration;
    private int _roomLoadGeneration;
    private int _classroomScheduleQueryGeneration;
    private List<EmptyClassroomRoomItem> _availableRooms = new();
    private ClassroomSemesterScheduleData? _currentScheduleData;

    private ClassroomScheduleWindow()
    {
        Title = "教室整周课表查询";
        Width = 1096;
        Height = 800;
        MinWidth = 956;
        MinHeight = 640;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(Color.FromRgb(246, 248, 251));

        Closing += (_, e) =>
        {
            e.Cancel = true;
            Hide();
        };

        var rootGrid = new Grid();
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(56) });
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        _topBar = new Border
        {
            Background = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromRgb(228, 233, 242)),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Padding = new Thickness(14, 0, 14, 0)
        };

        var barGrid = new Grid();
        barGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        barGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        barGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var filterPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center
        };

        _campusCombo = new ComboBox { Width = 105, Height = 28, FontSize = 12, Margin = new Thickness(0, 0, 6, 0), VerticalContentAlignment = VerticalAlignment.Center };
        foreach (var campus in StudyCampusExtensions.AllCases)
        {
            _campusCombo.Items.Add(new ComboBoxItem { Content = campus.Title(), Tag = campus });
        }
        _campusCombo.SelectedIndex = 0;
        _campusCombo.SelectionChanged += OnCampusChanged;
        filterPanel.Children.Add(_campusCombo);

        _buildingCombo = new ComboBox { Width = 125, Height = 28, FontSize = 12, Margin = new Thickness(0, 0, 6, 0), VerticalContentAlignment = VerticalAlignment.Center };
        _buildingCombo.SelectionChanged += OnBuildingChanged;
        filterPanel.Children.Add(_buildingCombo);

        _roomCombo = new ComboBox { Width = 145, Height = 28, FontSize = 12, Margin = new Thickness(0, 0, 6, 0), VerticalContentAlignment = VerticalAlignment.Center };
        _roomCombo.SelectionChanged += OnRoomChanged;
        filterPanel.Children.Add(_roomCombo);

        _semesterCombo = new ComboBox { Width = 135, Height = 28, FontSize = 12, Margin = new Thickness(0, 0, 8, 0), VerticalContentAlignment = VerticalAlignment.Center };
        foreach (int semCode in EmptyClassroomService.AvailableSemesters)
        {
            _semesterCombo.Items.Add(new ComboBoxItem
            {
                Content = EmptyClassroomService.SemesterTitle(semCode),
                Tag = semCode
            });
        }
        _semesterCombo.SelectedIndex = 0;
        _semesterCombo.SelectionChanged += (_, _) => { if (!_suppressSelectionEvents) QuerySelectedClassroomSchedule(); };
        filterPanel.Children.Add(_semesterCombo);

        _prevWeekBtn = CourseScheduleWindow.CreateToolbarButton("◀", (_, _) =>
        {
            if (_selectedWeek > 1)
            {
                _selectedWeek--;
                SyncWeekComboAndRender();
            }
        });
        filterPanel.Children.Add(_prevWeekBtn);

        _weekCombo = new ComboBox { Width = 96, Height = 28, FontSize = 12, Margin = new Thickness(4, 0, 4, 0), VerticalContentAlignment = VerticalAlignment.Center };
        for (int w = 1; w <= 20; w++) _weekCombo.Items.Add($"第 {w} 周");
        _weekCombo.SelectedIndex = 0;
        _weekCombo.SelectionChanged += (_, _) =>
        {
            if (!_suppressSelectionEvents && _weekCombo.SelectedIndex >= 0)
            {
                _selectedWeek = _weekCombo.SelectedIndex + 1;
                SyncWeekComboAndRender();
            }
        };
        filterPanel.Children.Add(_weekCombo);

        _nextWeekBtn = CourseScheduleWindow.CreateToolbarButton("▶", (_, _) =>
        {
            if (_selectedWeek < 20)
            {
                _selectedWeek++;
                SyncWeekComboAndRender();
            }
        });
        filterPanel.Children.Add(_nextWeekBtn);

        _queryBtn = CourseScheduleWindow.CreatePrimaryButton("查询排课", (_, _) => QuerySelectedClassroomSchedule());
        _queryBtn.Margin = new Thickness(8, 0, 0, 0);
        filterPanel.Children.Add(_queryBtn);

        Grid.SetColumn(filterPanel, 0);
        barGrid.Children.Add(filterPanel);

        _statusLabel = new TextBlock
        {
            Text = "请选择教室查询整周排课",
            FontSize = 11.5,
            Foreground = new SolidColorBrush(Color.FromRgb(115, 126, 145)),
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(_statusLabel, 2);
        barGrid.Children.Add(_statusLabel);

        _topBar.Child = barGrid;
        Grid.SetRow(_topBar, 0);
        rootGrid.Children.Add(_topBar);

        var scrollViewer = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Padding = new Thickness(12, 10, 12, 12)
        };
        _timetableContainer = new Grid { MinHeight = 580 };
        scrollViewer.Content = _timetableContainer;
        Grid.SetRow(scrollViewer, 1);
        rootGrid.Children.Add(scrollViewer);

        Content = rootGrid;

        ThemeManager.Shared.ApplyWindowTheme(this);
        ApplyTheme();
        ThemeManager.Shared.ThemeChanged += () => AppEvents.InvokeOnUI(() =>
        {
            ApplyTheme();
            if (_currentScheduleData != null)
            {
                RenderClassroomGrid();
            }
        });
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

        ThemeManager.Shared.ApplyComboBoxTheme(_campusCombo);
        ThemeManager.Shared.ApplyComboBoxTheme(_buildingCombo);
        ThemeManager.Shared.ApplyComboBoxTheme(_roomCombo);
        ThemeManager.Shared.ApplyComboBoxTheme(_semesterCombo);
        ThemeManager.Shared.ApplyComboBoxTheme(_weekCombo);
    }

    public void ShowWindow()
    {
        ApplyTheme();
        if (!IsVisible) Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        Focus();

        _selectedWeek = CourseScheduleService.Shared.CurrentSchedule?.CalculatedCurrentWeek() ?? 1;
        PopulateBuildingsForSelectedCampus();
    }

    private StudyCampus GetSelectedCampus()
    {
        if (_campusCombo.SelectedItem is ComboBoxItem item && item.Tag is StudyCampus c)
            return c;
        return StudyCampus.Feicuihu;
    }

    private void OnCampusChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelectionEvents) return;
        PopulateBuildingsForSelectedCampus();
    }

    private void PopulateBuildingsForSelectedCampus()
    {
        InvalidateClassroomScheduleQuery();
        var campus = GetSelectedCampus();
        var generation = ++_buildingLoadGeneration;

        _suppressSelectionEvents = true;
        try
        {
            _buildingCombo.Items.Clear();
            _roomCombo.Items.Clear();
            _availableRooms.Clear();
        }
        finally
        {
            _suppressSelectionEvents = false;
        }

        _statusLabel.Text = $"正在加载 {campus.Title()} 教学楼列表...";
        EmptyClassroomService.Shared.FetchBuildings((buildings, err) =>
        {
            AppEvents.InvokeOnUI(() =>
            {
                if (generation != _buildingLoadGeneration || campus != GetSelectedCampus()) return;

                var campusBuildings = (buildings ?? EmptyClassroomService.AllBuildings)
                    .Where(b => b.Campus == campus)
                    .ToList();

                _suppressSelectionEvents = true;
                try
                {
                    _buildingCombo.Items.Clear();
                    foreach (var building in campusBuildings)
                    {
                        _buildingCombo.Items.Add(new ComboBoxItem { Content = building.Title, Tag = building });
                    }
                    if (_buildingCombo.Items.Count > 0)
                    {
                        _buildingCombo.SelectedIndex = 0;
                    }
                }
                finally
                {
                    _suppressSelectionEvents = false;
                }

                if (_buildingCombo.Items.Count > 0)
                {
                    LoadRoomsForSelectedBuilding();
                }
                else
                {
                    _statusLabel.Text = err ?? "未找到该校区的教学楼";
                }
            });
        });
    }

    private void OnBuildingChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelectionEvents) return;
        LoadRoomsForSelectedBuilding();
    }

    private void LoadRoomsForSelectedBuilding()
    {
        InvalidateClassroomScheduleQuery();
        if (_buildingCombo.SelectedItem is not ComboBoxItem bItem || bItem.Tag is not StudyBuildingOption building)
            return;

        var generation = ++_roomLoadGeneration;

        string today = EmptyClassroomService.TodayDateString();
        var cached = EmptyClassroomService.Shared.CachedBuildingRooms(building, today);
        if (cached != null && cached.Count > 0)
        {
            PopulateRoomCombo(cached);
            return;
        }

        _statusLabel.Text = $"正在加载 {building.Title} 教室列表...";
        EmptyClassroomService.Shared.FetchRooms(building, today, false, (rooms, err) =>
        {
            AppEvents.InvokeOnUI(() =>
            {
                if (generation != _roomLoadGeneration
                    || GetSelectedCampus() != building.Campus
                    || _buildingCombo.SelectedItem is not ComboBoxItem selectedItem
                    || selectedItem.Tag is not StudyBuildingOption selectedBuilding
                    || selectedBuilding.BuildingId != building.BuildingId)
                {
                    return;
                }

                if (rooms != null && rooms.Count > 0)
                {
                    PopulateRoomCombo(rooms);
                }
                else
                {
                    _statusLabel.Text = err ?? "该教学楼暂无可用教室";
                }
            });
        });
    }

    private void PopulateRoomCombo(List<EmptyClassroomRoomItem> rooms)
    {
        _suppressSelectionEvents = true;
        try
        {
            _availableRooms = rooms
                .Where(r => r.Floor > 0)
                .OrderBy(r => r.Floor)
                .ThenBy(r => r.SimplifiedRoomName)
                .ToList();

            _roomCombo.Items.Clear();
            foreach (var r in _availableRooms)
            {
                _roomCombo.Items.Add(new ComboBoxItem
                {
                    Content = $"{r.SimplifiedRoomName} ({r.Seats}座)",
                    Tag = r
                });
            }
            if (_roomCombo.Items.Count > 0)
            {
                _roomCombo.SelectedIndex = 0;
            }
        }
        finally
        {
            _suppressSelectionEvents = false;
        }

        QuerySelectedClassroomSchedule();
    }

    private void OnRoomChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelectionEvents) return;
        QuerySelectedClassroomSchedule();
    }

    private void QuerySelectedClassroomSchedule()
    {
        var requestGeneration = InvalidateClassroomScheduleQuery();
        if (_roomCombo.SelectedItem is not ComboBoxItem rItem || rItem.Tag is not EmptyClassroomRoomItem room)
        {
            _statusLabel.Text = "请选择教室查询整周排课";
            return;
        }

        int semesterCode = 244;
        if (_semesterCombo.SelectedItem is ComboBoxItem sItem && sItem.Tag is int code)
        {
            semesterCode = code;
        }

        _statusLabel.Text = $"正在查询 {room.SimplifiedRoomName} 排课...";
        _queryBtn.IsEnabled = false;

        EmptyClassroomService.Shared.FetchClassroomSemesterSchedule(room, semesterCode, false, (data, err) =>
        {
            AppEvents.InvokeOnUI(() =>
            {
                if (requestGeneration != _classroomScheduleQueryGeneration) return;
                _queryBtn.IsEnabled = true;
                if (data != null)
                {
                    _currentScheduleData = data;
                    SyncWeekComboAndRender();
                }
                else
                {
                    _statusLabel.Text = err ?? "查询教室排课失败";
                }
            });
        });
    }

    private int InvalidateClassroomScheduleQuery()
    {
        _classroomScheduleQueryGeneration++;
        _currentScheduleData = null;
        _queryBtn.IsEnabled = true;
        _timetableContainer.Children.Clear();
        return _classroomScheduleQueryGeneration;
    }

    private void SyncWeekComboAndRender()
    {
        _suppressSelectionEvents = true;
        try
        {
            _weekCombo.SelectedIndex = Math.Clamp(_selectedWeek - 1, 0, _weekCombo.Items.Count - 1);
            _prevWeekBtn.IsEnabled = _selectedWeek > 1;
            _nextWeekBtn.IsEnabled = _selectedWeek < 20;
        }
        finally
        {
            _suppressSelectionEvents = false;
        }

        RenderClassroomGrid();
    }

    private void RenderClassroomGrid()
    {
        _timetableContainer.Children.Clear();
        if (_currentScheduleData == null)
        {
            return;
        }

        var activities = _currentScheduleData.Activities(forWeek: _selectedWeek)
            .Where(a => a.Weekday >= 1 && a.Weekday <= 7
                && a.StartMinutes >= 0 && a.EndMinutes > a.StartMinutes && a.EndMinutes <= 24 * 60)
            .OrderBy(a => a.Weekday)
            .ThenBy(a => a.StartMinutes)
            .ThenBy(a => a.EndMinutes)
            .ToList();
        _statusLabel.Text = $"{_currentScheduleData.RoomName} · 第 {_selectedWeek} 周共 {activities.Count} 节排课";

        int minLessonHour = activities.Count > 0 ? activities.Min(a => a.StartMinutes) / 60 : 8;
        int maxLessonHour = activities.Count > 0 ? (activities.Max(a => a.EndMinutes) + 59) / 60 : 22;
        int startHour = Math.Min(8, minLessonHour);
        int endHour = Math.Min(24, Math.Max(22, maxLessonHour));
        int totalHours = Math.Max(1, endHour - startHour);
        const double hourHeight = 54.0;
        double timelineHeight = totalHours * hourHeight;

        var outerCard = new Border
        {
            Background = ThemeManager.Shared.CardBackground,
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            ClipToBounds = true
        };

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(72) });
        for (int d = 1; d <= 7; d++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        }

        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(42) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(timelineHeight) });

        var timeHeader = new Border
        {
            Background = ThemeManager.Shared.TableHeaderBackground,
            BorderBrush = ThemeManager.Shared.CardBorderBrush,
            BorderThickness = new Thickness(0, 0, 1, 1),
            Child = new TextBlock
            {
                Text = "时间",
                FontSize = 11,
                Foreground = ThemeManager.Shared.TextSecondary,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            }
        };
        Grid.SetRow(timeHeader, 0);
        Grid.SetColumn(timeHeader, 0);
        grid.Children.Add(timeHeader);

        string[] weekdayNames = { "周一", "周二", "周三", "周四", "周五", "周六", "周日" };
        for (int d = 1; d <= 7; d++)
        {
            var hdr = new Border
            {
                Background = ThemeManager.Shared.TableHeaderBackground,
                BorderBrush = ThemeManager.Shared.CardBorderBrush,
                BorderThickness = new Thickness(d == 1 ? 1 : 0, 0, 1, 1)
            };
            hdr.Child = new TextBlock
            {
                Text = weekdayNames[d - 1],
                FontSize = 12,
                FontWeight = FontWeights.SemiBold,
                Foreground = ThemeManager.Shared.TextPrimary,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            };
            Grid.SetRow(hdr, 0);
            Grid.SetColumn(hdr, d);
            grid.Children.Add(hdr);
        }

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
                BorderBrush = ThemeManager.Shared.TableGridLineBrush,
                BorderThickness = new Thickness(0, 0, 1, 1)
            };
            Grid.SetRow(axisCell, hourIndex);
            timeAxis.Children.Add(axisCell);
        }
        var timeLabels = new Canvas { IsHitTestVisible = false };
        for (int hour = startHour; hour <= endHour; hour++)
        {
            var label = new TextBlock
            {
                Text = $"{hour:D2}:00",
                Width = 64,
                Height = 16,
                TextAlignment = TextAlignment.Right,
                FontSize = 10.5,
                Foreground = ThemeManager.Shared.TextSecondary,
            };
            Canvas.SetLeft(label, 3);
            Canvas.SetTop(label, Math.Max(0, (hour - startHour) * hourHeight - 8));
            timeLabels.Children.Add(label);
        }
        Grid.SetRowSpan(timeLabels, totalHours);
        timeAxis.Children.Add(timeLabels);
        Grid.SetRow(timeAxis, 1);
        Grid.SetColumn(timeAxis, 0);
        grid.Children.Add(timeAxis);

        for (int day = 1; day <= 7; day++)
        {
            var dayGrid = new Grid { ClipToBounds = true };
            for (int hourIndex = 0; hourIndex < totalHours; hourIndex++)
            {
                dayGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(hourHeight) });
                var cell = new Border
                {
                    BorderBrush = ThemeManager.Shared.TableGridLineBrush,
                    BorderThickness = new Thickness(0, 0, day < 7 ? 1 : 0, 1),
                    IsHitTestVisible = false
                };
                Grid.SetRow(cell, hourIndex);
                dayGrid.Children.Add(cell);
            }

            var dayActivities = activities.Where(a => a.Weekday == day).ToList();
            var overlapGroups = new List<List<CourseLesson>>();
            foreach (var activity in dayActivities)
            {
                if (overlapGroups.Count == 0 || activity.StartMinutes >= overlapGroups[^1].Max(a => a.EndMinutes))
                    overlapGroups.Add(new List<CourseLesson> { activity });
                else
                    overlapGroups[^1].Add(activity);
            }

            foreach (var group in overlapGroups)
            {
                int groupStartHour = group.Min(a => a.StartMinutes) / 60;
                int groupEndHour = (group.Max(a => a.EndMinutes) + 59) / 60;
                int parentStartRow = Math.Clamp(groupStartHour - startHour, 0, totalHours - 1);
                int parentEndRow = Math.Clamp(groupEndHour - startHour, parentStartRow + 1, totalHours);

                var laneEnds = new List<int>();
                var assignedLanes = new List<int>();
                foreach (var activity in group)
                {
                    int lane = laneEnds.FindIndex(end => end <= activity.StartMinutes);
                    if (lane < 0)
                    {
                        lane = laneEnds.Count;
                        laneEnds.Add(activity.EndMinutes);
                    }
                    else
                    {
                        laneEnds[lane] = activity.EndMinutes;
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
                dayGrid.Children.Add(groupGrid);

                for (int index = 0; index < group.Count; index++)
                {
                    var act = group[index];
                    int startRow = act.StartMinutes / 60 - groupStartHour;
                    int endRow = (act.EndMinutes + 59) / 60 - groupStartHour;
                    int startRemainder = act.StartMinutes % 60;
                    int endRemainder = act.EndMinutes % 60;
                    var stack = new StackPanel();
                    stack.Children.Add(new TextBlock
                    {
                        Text = act.CourseName,
                        FontSize = 11,
                        FontWeight = FontWeights.Bold,
                        Foreground = new SolidColorBrush(Color.FromRgb(20, 72, 155)),
                        TextWrapping = TextWrapping.Wrap,
                        TextTrimming = TextTrimming.CharacterEllipsis
                    });
                    if (!string.IsNullOrWhiteSpace(act.TeacherName))
                    {
                        stack.Children.Add(new TextBlock
                        {
                            Text = act.TeacherName,
                            FontSize = 10,
                            Foreground = new SolidColorBrush(Color.FromRgb(52, 102, 182)),
                            Margin = new Thickness(0, 2, 0, 0),
                            TextTrimming = TextTrimming.CharacterEllipsis
                        });
                    }
                    stack.Children.Add(new TextBlock
                    {
                        Text = $"{act.FormattedStartTime}-{act.FormattedEndTime}",
                        FontSize = 9.5,
                        Foreground = new SolidColorBrush(Color.FromRgb(52, 102, 182)),
                        Margin = new Thickness(0, 2, 0, 0)
                    });

                    var block = new Border
                    {
                        Background = new SolidColorBrush(Color.FromRgb(235, 244, 255)),
                        BorderBrush = new SolidColorBrush(Color.FromRgb(64, 140, 255)),
                        BorderThickness = new Thickness(3, 1, 1, 1),
                        CornerRadius = new CornerRadius(5),
                        Margin = new Thickness(3, startRemainder / 60.0 * hourHeight + 2, 3,
                            (endRemainder == 0 ? 0 : (60 - endRemainder) / 60.0 * hourHeight) + 2),
                        Padding = new Thickness(5, 4, 5, 4),
                        Child = stack,
                        ToolTip = $"{act.CourseName}\n教师：{act.TeacherName}\n时间：{act.FormattedStartTime}-{act.FormattedEndTime}\n周次：{act.WeekText}\n班级：{act.AdminClassText}"
                    };
                    Grid.SetRow(block, Math.Clamp(startRow, 0, groupGrid.RowDefinitions.Count - 1));
                    Grid.SetRowSpan(block, Math.Clamp(endRow, startRow + 1, groupGrid.RowDefinitions.Count) - Math.Clamp(startRow, 0, groupGrid.RowDefinitions.Count - 1));
                    Grid.SetColumn(block, assignedLanes[index]);
                    groupGrid.Children.Add(block);
                }
            }

            Grid.SetRow(dayGrid, 1);
            Grid.SetColumn(dayGrid, day);
            grid.Children.Add(dayGrid);
        }

        outerCard.Child = grid;
        _timetableContainer.Children.Add(outerCard);
    }
}
