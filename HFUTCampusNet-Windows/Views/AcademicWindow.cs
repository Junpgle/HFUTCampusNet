using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace HFUTCampusNet;

public sealed class AcademicWindow : Window
{
    private static AcademicWindow? _shared;
    public static AcademicWindow Shared => _shared ??= new AcademicWindow();

    private int _currentMode = 0; // 0: 成绩单, 1: 考试, 2: 培养方案, 3: 教材与评教
    private int _selectedTermIndex;
    private bool _updatingTermOptions;
    private bool _isSyncing;

    private readonly Button[] _modeButtons = new Button[4];
    private readonly Border _segmentContainer;
    private readonly ComboBox _termComboBox;
    private readonly TextBlock _sectionTitleLabel;
    private readonly TextBlock _statusLabel;
    private readonly CheckBox _hideScoreCheckbox;
    private readonly Button _syncButton;

    // 4 指标卡片
    private readonly Border[] _cardBorders = new Border[4];
    private readonly TextBlock[] _cardTitles = new TextBlock[4];
    private readonly TextBlock[] _cardValues = new TextBlock[4];
    private readonly TextBlock[] _cardSubs = new TextBlock[4];

    private readonly DataGrid _dataGrid;

    private AcademicWindow()
    {
        Title = "合肥工业大学 - 学业成绩、考场安排与培养方案";
        Width = 996;
        Height = 740;
        MinWidth = 896;
        MinHeight = 600;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var root = new Grid { Margin = new Thickness(16) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // Top Bar
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // 4 Cards
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // Section Header
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); // DataGrid

        // Top Bar
        var topBar = new Grid { Margin = new Thickness(0, 0, 0, 14) };
        topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var leftTools = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var segmentGrid = new Grid { Width = 464, Height = 26 };
        string[] modeNames = { "成绩单与 GPA", "考试与校历进度", "培养方案与毕业学分", "课程教材与评教" };
        for (int i = 0; i < modeNames.Length; i++)
        {
            segmentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            int mode = i;
            _modeButtons[i] = CreateSegmentButton(modeNames[i], () => SelectMode(mode));
            Grid.SetColumn(_modeButtons[i], i);
            segmentGrid.Children.Add(_modeButtons[i]);
        }
        _segmentContainer = new Border
        {
            Width = 470,
            Height = 32,
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(2),
            Child = segmentGrid
        };
        leftTools.Children.Add(_segmentContainer);

        _termComboBox = new ComboBox
        {
            Width = 190,
            Height = 28,
            FontSize = 11.5,
            Margin = new Thickness(8, 0, 8, 0),
            VerticalContentAlignment = VerticalAlignment.Center
        };
        _termComboBox.SelectionChanged += (_, _) =>
        {
            if (_updatingTermOptions || _termComboBox.SelectedItem is not ComboBoxItem selected) return;
            var groups = AcademicService.Shared.LatestData?.SemesterGroups ?? new List<SemesterGradeGroup>();
            if (selected.Tag is int groupIndex)
                _selectedTermIndex = groupIndex;
            else if (selected.Tag is string tag && tag == "all-terms")
                _selectedTermIndex = groups.Count;
            ReloadUI();
        };
        leftTools.Children.Add(_termComboBox);

        _hideScoreCheckbox = new CheckBox
        {
            Content = "通知隐藏具体分数",
            FontSize = 11.5,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(4, 0, 0, 0),
            IsChecked = SettingsManager.Shared.HideScoreInNotification
        };
        _hideScoreCheckbox.Checked += (_, _) =>
        {
            SettingsManager.Shared.HideScoreInNotification = true;
            SettingsManager.Shared.Save();
        };
        _hideScoreCheckbox.Unchecked += (_, _) =>
        {
            SettingsManager.Shared.HideScoreInNotification = false;
            SettingsManager.Shared.Save();
        };
        leftTools.Children.Add(_hideScoreCheckbox);
        Grid.SetColumn(leftTools, 0);
        topBar.Children.Add(leftTools);

        _syncButton = CreateActionButton("立即同步", () =>
        {
            _isSyncing = true;
            ReloadUI();
            AcademicService.Shared.SyncAll(silent: false, ok =>
            {
                AppEvents.InvokeOnUI(() =>
                {
                    _isSyncing = false;
                    ReloadUI();
                    if (!ok && (AcademicService.Shared.LatestData == null || AcademicService.Shared.LatestData.AllGrades.Count == 0))
                    {
                        var res = MessageBox.Show(
                            "未获取到成绩与考试数据。这通常是因为尚未登录教务系统或统一身份认证，或凭据已过期。\n\n是否立即打开教务登录页面？",
                            "教务认证提示",
                            MessageBoxButton.YesNo,
                            MessageBoxImage.Question);
                        if (res == MessageBoxResult.Yes)
                        {
                            CourseLoginWebWindow.Shared.ShowWindow();
                        }
                    }
                });
            });
        });
        _syncButton.Width = 95;
        _syncButton.Height = 30;
        Grid.SetColumn(_syncButton, 1);
        topBar.Children.Add(_syncButton);

        Grid.SetRow(topBar, 0);
        root.Children.Add(topBar);

        // 4 Cards Grid
        var cardsGrid = new Grid { Margin = new Thickness(0, 0, 0, 14) };
        for (int i = 0; i < 4; i++) cardsGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        for (int i = 0; i < 4; i++)
        {
            var border = new Border
            {
                Background = (Brush)new BrushConverter().ConvertFromString("#18181B")!,
                BorderBrush = (Brush)new BrushConverter().ConvertFromString("#27272A")!,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(12),
                Padding = new Thickness(14, 10, 14, 10),
                Margin = new Thickness(i == 0 ? 0 : 6, 0, i == 3 ? 0 : 6, 0)
            };

            var stack = new StackPanel();
            _cardTitles[i] = new TextBlock { Text = "指标", FontSize = 11, Foreground = Brushes.Gray };
            _cardValues[i] = new TextBlock { Text = "--", FontSize = 18, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 4, 0, 4) };
            _cardSubs[i] = new TextBlock { Text = "--", FontSize = 10.5, Foreground = Brushes.DarkGray, TextTrimming = TextTrimming.CharacterEllipsis };

            stack.Children.Add(_cardTitles[i]);
            stack.Children.Add(_cardValues[i]);
            stack.Children.Add(_cardSubs[i]);
            border.Child = stack;

            _cardBorders[i] = border;
            Grid.SetColumn(border, i);
            cardsGrid.Children.Add(border);
        }

        Grid.SetRow(cardsGrid, 1);
        root.Children.Add(cardsGrid);

        // Section title and sync status
        var sectionHeader = new Grid { Margin = new Thickness(0, 0, 0, 8) };
        sectionHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        sectionHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _sectionTitleLabel = new TextBlock
        {
            Text = "清单",
            FontSize = 12.5,
            FontWeight = FontWeights.SemiBold,
        };
        Grid.SetColumn(_sectionTitleLabel, 0);
        sectionHeader.Children.Add(_sectionTitleLabel);
        _statusLabel = new TextBlock
        {
            FontSize = 11,
            TextAlignment = TextAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Width = 400,
            MaxWidth = 400
        };
        Grid.SetColumn(_statusLabel, 1);
        sectionHeader.Children.Add(_statusLabel);
        Grid.SetRow(sectionHeader, 2);
        root.Children.Add(sectionHeader);

        // DataGrid
        _dataGrid = new DataGrid
        {
            AutoGenerateColumns = false,
            IsReadOnly = true,
            GridLinesVisibility = DataGridGridLinesVisibility.Horizontal,
            HeadersVisibility = DataGridHeadersVisibility.Column,
            RowHeaderWidth = 0,
            FontSize = 12,
            RowHeight = 26,
            BorderBrush = ThemeManager.Shared.TableGridLineBrush,
            BorderThickness = new Thickness(1)
        };
        Grid.SetRow(_dataGrid, 3);
        root.Children.Add(_dataGrid);

        Content = root;

        Closing += (_, e) =>
        {
            e.Cancel = true;
            Hide();
        };

        ThemeManager.Shared.ApplyWindowTheme(this);
        ApplyTheme();
        ThemeManager.Shared.ThemeChanged += () => AppEvents.InvokeOnUI(ApplyTheme);

        AppEvents.AcademicDataUpdated += () => AppEvents.InvokeOnUI(ReloadUI);
        ReloadUI();
    }

    private static Button CreateSegmentButton(string text, Action onClick)
    {
        var button = new Button
        {
            Content = text,
            Padding = new Thickness(3, 4, 3, 4),
            Margin = new Thickness(1),
            FontSize = 11.5,
            FontWeight = FontWeights.Medium,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            FocusVisualStyle = null,
            Template = CreateFlatButtonTemplate(new CornerRadius(6))
        };
        button.Click += (_, _) => onClick();
        return button;
    }

    private static Button CreateActionButton(string text, Action onClick)
    {
        var button = new Button
        {
            Content = text,
            Padding = new Thickness(12, 5, 12, 5),
            FontSize = 12,
            FontWeight = FontWeights.Medium,
            BorderThickness = new Thickness(0),
            FocusVisualStyle = null,
            Template = CreateFlatButtonTemplate(new CornerRadius(7))
        };
        button.Click += (_, _) => onClick();
        return button;
    }

    private static ControlTemplate CreateFlatButtonTemplate(CornerRadius radius)
    {
        var template = new ControlTemplate(typeof(Button));
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.CornerRadiusProperty, radius);
        border.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding("Background")
        {
            RelativeSource = new System.Windows.Data.RelativeSource(System.Windows.Data.RelativeSourceMode.TemplatedParent)
        });
        border.SetBinding(Border.BorderBrushProperty, new System.Windows.Data.Binding("BorderBrush")
        {
            RelativeSource = new System.Windows.Data.RelativeSource(System.Windows.Data.RelativeSourceMode.TemplatedParent)
        });
        border.SetBinding(Border.BorderThicknessProperty, new System.Windows.Data.Binding("BorderThickness")
        {
            RelativeSource = new System.Windows.Data.RelativeSource(System.Windows.Data.RelativeSourceMode.TemplatedParent)
        });
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        presenter.SetValue(ContentPresenter.RecognizesAccessKeyProperty, true);
        border.AppendChild(presenter);
        template.VisualTree = border;
        return template;
    }

    private void SelectMode(int mode)
    {
        _currentMode = Math.Clamp(mode, 0, 3);
        ReloadUI();
    }

    private void ApplyTheme()
    {
        ThemeManager.Shared.ApplyWindowTheme(this);
        Background = ThemeManager.Shared.WindowBackground;
        Foreground = ThemeManager.Shared.TextPrimary;

        _sectionTitleLabel.Foreground = ThemeManager.Shared.TextPrimary;
        _statusLabel.Foreground = ThemeManager.Shared.TextMuted;
        _hideScoreCheckbox.Foreground = ThemeManager.Shared.TextPrimary;
        _segmentContainer.Background = ThemeManager.Shared.ControlBackground;
        _segmentContainer.BorderBrush = ThemeManager.Shared.ControlBorderBrush;
        _termComboBox.Background = ThemeManager.Shared.ControlBackground;
        _termComboBox.Foreground = ThemeManager.Shared.TextPrimary;
        _termComboBox.BorderBrush = ThemeManager.Shared.ControlBorderBrush;
        ThemeManager.Shared.ApplyComboBoxTheme(_termComboBox);
        _syncButton.Background = ThemeManager.Shared.Accent;
        _syncButton.Foreground = Brushes.White;
        _syncButton.BorderBrush = ThemeManager.Shared.Accent;
        for (int i = 0; i < _modeButtons.Length; i++)
        {
            bool selected = i == _currentMode;
            _modeButtons[i].Background = selected ? ThemeManager.Shared.Accent : Brushes.Transparent;
            _modeButtons[i].Foreground = selected ? Brushes.White : ThemeManager.Shared.TextSecondary;
        }

        for (int i = 0; i < 4; i++)
        {
            if (_cardBorders[i] != null)
            {
                _cardBorders[i].Background = ThemeManager.Shared.CardBackground;
                _cardBorders[i].BorderBrush = ThemeManager.Shared.CardBorderBrush;
                _cardTitles[i].Foreground = ThemeManager.Shared.TextSecondary;
                _cardSubs[i].Foreground = ThemeManager.Shared.TextMuted;
                if (_cardValues[i].Foreground == null || _cardValues[i].Foreground == Brushes.Black)
                {
                    _cardValues[i].Foreground = ThemeManager.Shared.TextPrimary;
                }
            }
        }

        if (_dataGrid != null)
        {
            ThemeManager.Shared.ApplyDataGridTheme(_dataGrid);
            _dataGrid.Background = ThemeManager.Shared.TableBackground;
            _dataGrid.RowBackground = ThemeManager.Shared.TableBackground;
            _dataGrid.AlternatingRowBackground = ThemeManager.Shared.TableAlternatingBackground;
            _dataGrid.HorizontalGridLinesBrush = ThemeManager.Shared.TableGridLineBrush;
            _dataGrid.VerticalGridLinesBrush = ThemeManager.Shared.TableGridLineBrush;
            _dataGrid.Foreground = ThemeManager.Shared.TextPrimary;
            _dataGrid.BorderBrush = ThemeManager.Shared.TableGridLineBrush;

        }
    }

    public void ShowWindow(int mode = 0)
    {
        _currentMode = Math.Clamp(mode, 0, 3);
        if (_currentMode == 0)
        {
            AcademicService.Shared.MarkAllGradesAsRead();
        }
        ApplyTheme();
        Show();
        Activate();
        ReloadUI();

        if (AcademicService.Shared.LatestData == null || AcademicService.Shared.LatestData.AllGrades.Count == 0)
        {
            AcademicService.Shared.SyncAll(silent: true, _ => AppEvents.InvokeOnUI(ReloadUI));
        }
    }

    private void SetCard(int index, string title, string val, string sub, Brush color)
    {
        if (index < 0 || index >= 4) return;
        _cardTitles[index].Text = title;
        _cardValues[index].Text = val;
        _cardValues[index].Foreground = color;
        _cardSubs[index].Text = sub;

        // 根据长度动态调整字号，防止截断
        int len = val.Length;
        _cardValues[index].FontSize = len <= 10 ? 19 : len <= 15 ? 16 : len <= 20 ? 14 : 12;
    }

    private void ReloadUI()
    {
        var snap = AcademicService.Shared.LatestData;
        var groups = snap?.SemesterGroups ?? new List<SemesterGradeGroup>();
        UpdateTermOptions(groups);
        _termComboBox.Visibility = _currentMode == 0 ? Visibility.Visible : Visibility.Collapsed;
        for (int i = 0; i < _modeButtons.Length; i++)
        {
            bool selected = i == _currentMode;
            _modeButtons[i].Background = selected ? ThemeManager.Shared.Accent : Brushes.Transparent;
            _modeButtons[i].Foreground = selected ? Brushes.White : ThemeManager.Shared.TextSecondary;
        }
        UpdateSyncStatus(snap);
        _dataGrid.Columns.Clear();

        switch (_currentMode)
        {
            case 0:
                // 成绩单与 GPA
                bool isAllTerms = groups.Count > 0 && _selectedTermIndex >= groups.Count;
                var activeGroup = !isAllTerms && _selectedTermIndex < groups.Count ? groups[_selectedTermIndex] : null;
                if (isAllTerms && snap != null)
                {
                    var allGrades = snap.AllGrades;
                    _sectionTitleLabel.Text = $"全部学期成绩单（共 {allGrades.Count} 门课程）";
                    var overallGpa = snap.OverallWeightedGPA.HasValue ? $"{snap.OverallWeightedGPA.Value:F2} / 4.3" : "--";
                    var overallScore = snap.OverallWeightedAverageScore.HasValue ? $"{snap.OverallWeightedAverageScore.Value:F2} 分" : "--";
                    int passCount = allGrades.Count(g => g.Passed);
                    SetCard(0, "全学程加权 GPA", overallGpa, "全部已修读计点课程加权", Brushes.DodgerBlue);
                    SetCard(1, "全学程加权平均分", overallScore, "按课程学分加权折算", Brushes.MediumPurple);
                    SetCard(2, "累计获得学分", $"{snap.TotalEarnedCredits:F1} 学分", $"共 {groups.Count} 个学期", Brushes.Teal);
                    var passRate = allGrades.Count == 0 ? 100 : Math.Round(passCount * 100.0 / allGrades.Count);
                    SetCard(3, "已出分科目数", $"{passCount} / {allGrades.Count} 门", $"通过率 {passRate:F0}%", Brushes.SeaGreen);
                    _dataGrid.ItemsSource = allGrades;
                }
                else if (activeGroup != null)
                {
                    var grades = activeGroup.Grades;
                    _sectionTitleLabel.Text = $"{activeGroup.TermName} 成绩明细（共 {grades.Count} 门）";
                    var termGpa = activeGroup.WeightedGPA.HasValue ? $"{activeGroup.WeightedGPA.Value:F2}" : "--";
                    var termScore = activeGroup.WeightedAverageScore.HasValue ? $"{activeGroup.WeightedAverageScore.Value:F2} 分" : "--";
                    var overallGpa = snap?.OverallWeightedGPA.HasValue == true ? $"{snap.OverallWeightedGPA.Value:F2}" : "--";
                    var allCredits = snap != null ? $"总修 {snap.TotalEarnedCredits:F1} 学分" : "--";
                    SetCard(0, "本学期加权 GPA", termGpa, activeGroup.TermName, Brushes.DodgerBlue);
                    SetCard(1, "本学期加权平均分", termScore, $"本学期共 {grades.Count} 门已出分", Brushes.MediumPurple);
                    SetCard(2, "本学期获得学分", $"{activeGroup.TotalCredits:F1} 学分", "已通过科目学分合计", Brushes.Teal);
                    SetCard(3, "全学程总 GPA", overallGpa, allCredits, Brushes.SeaGreen);
                    _dataGrid.ItemsSource = grades;
                }
                else
                {
                    _sectionTitleLabel.Text = "课程成绩明细";
                    SetCard(0, "本学期加权 GPA", "--", "等待同步成绩数据", Brushes.Gray);
                    SetCard(1, "本学期加权平均分", "--", "等待同步成绩数据", Brushes.Gray);
                    SetCard(2, "本学期获得学分", "--", "等待同步成绩数据", Brushes.Gray);
                    SetCard(3, "全学程总 GPA", "--", "等待同步成绩数据", Brushes.Gray);
                    _dataGrid.ItemsSource = new List<GradeItem>();
                }

                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "课程名称", Binding = new System.Windows.Data.Binding("CourseName"), Width = 220 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "学期", Binding = new System.Windows.Data.Binding("TermName"), Width = 150 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "学分", Binding = new System.Windows.Data.Binding("Credits"), Width = 65 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "绩点", Binding = new System.Windows.Data.Binding("Gpa"), Width = 65 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "成绩", Binding = new System.Windows.Data.Binding("ScoreText"), Width = 80 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "课程代码", Binding = new System.Windows.Data.Binding("CourseCode"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });

                break;

            case 1:
                // 考试与校历进度
                var milestone = SemesterMilestoneInfo.Calculate(schedule: CourseScheduleService.Shared.CurrentSchedule);
                var allExams = snap?.Exams ?? new List<ExamItem>();
                var now = DateTime.Now;
                var upcoming = allExams.Where(e => !e.IsFinished(now)).OrderBy(e => e.ExamStartDate ?? DateTime.MaxValue).ToList();
                var finished = allExams.Where(e => e.IsFinished(now)).OrderByDescending(e => e.ExamStartDate ?? DateTime.MinValue).ToList();
                _sectionTitleLabel.Text = allExams.Count == 0
                    ? $"本学期考试安排与校历里程碑（{milestone.SemesterName} · 暂未发布排考）"
                    : $"本学期考试安排（共 {allExams.Count} 场，待考 {upcoming.Count} 场 · {milestone.SemesterName}）";

                var nextExam = upcoming.FirstOrDefault();
                if (nextExam != null)
                {
                    SetCard(0, "最近一场考试", nextExam.CourseName, $"{nextExam.DateString} {nextExam.StartTimeString}~{nextExam.EndTimeString}", Brushes.Orange);
                    SetCard(1, "考试倒计时", nextExam.CountdownBadgeText(), $"考场: {nextExam.DisplayLocation}", Brushes.DodgerBlue);
                }
                else
                {
                    SetCard(0, "最近一场考试", "暂无待考科目", allExams.Count == 0 ? "教务系统尚未公布本学期排考" : "本学期考试已全部结束", Brushes.SeaGreen);
                    SetCard(1, "期末考试周倒计时", milestone.DaysUntilExamWeek > 0 ? $"约 {milestone.DaysUntilExamWeek} 天" : "已进入期末阶段", $"待考 {upcoming.Count} 场 / 已考 {finished.Count} 场", Brushes.DodgerBlue);
                }
                SetCard(2, "本学期校历进度", $"第 {milestone.CurrentWeek}/{milestone.TotalWeeks} 周 ({milestone.ProgressPercentage:F0}%)", $"{milestone.StartDateString} ~ {milestone.EndDateString}", Brushes.Teal);
                SetCard(3, $"距离{milestone.VacationName}放假", milestone.DaysUntilVacation > 0 ? $"还有 {milestone.DaysUntilVacation} 天" : "假期进行中", $"学期结束日：{milestone.EndDateString}", Brushes.MediumPurple);

                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "考试科目", Binding = new System.Windows.Data.Binding("CourseName"), Width = 220 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "考试日期与时间", Binding = new System.Windows.Data.Binding("DateTimeString"), Width = 180 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "倒计时", Binding = new System.Windows.Data.Binding("CountdownBadgeText()"), Width = 100 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "考试考场", Binding = new System.Windows.Data.Binding("DisplayLocation"), Width = 220 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "考试性质", Binding = new System.Windows.Data.Binding("ExamType"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });

                _dataGrid.ItemsSource = upcoming.Concat(finished).ToList();
                break;

            case 2:
                // 培养方案与毕业学分
                var prog = snap?.ProgramCompletion;
                _sectionTitleLabel.Text = $"{prog?.ProgramName ?? "培养方案审计"} (共 {prog?.Modules.Count ?? 0} 个模块分类)";

                if (prog != null)
                {
                    SetCard(0, "毕业要求总学分", $"{prog.PassedCredits:F1} / {prog.RequiredCredits:F0} 分", $"已修占 {prog.CompletionPercentage:F1}% (通过 {prog.PassedCourseCount} 门)", Brushes.DodgerBlue);
                    SetCard(1, "本学期在修学分", $"+{prog.TakingCredits:F1} 学分", $"在修计划内 {prog.TakingCourseCount} 门", Brushes.MediumPurple);
                    SetCard(2, "预计完成进度", $"{prog.ProjectedPercentageWithTaking:F1}% ({prog.PassedCredits + prog.TakingCredits:F1}分)", "本学期全部修过后的预计总学分", Brushes.SeaGreen);
                    var rem = prog.RemainingCreditsAfterTaking;
                    SetCard(3, "扣除在修净缺口", rem <= 0.01 ? "已满额" : $"还差 {rem:F1} 分", rem <= 0.01 ? "已达到毕业学分要求" : "后续学期还需选修/必修", rem <= 0.01 ? Brushes.SeaGreen : Brushes.Orange);
                }
                else
                {
                    SetCard(0, "毕业要求总学分", "--", "等待同步培养方案", Brushes.Gray);
                    SetCard(1, "本学期在修学分", "--", "等待同步", Brushes.Gray);
                    SetCard(2, "预计完成进度", "--", "等待同步", Brushes.Gray);
                    SetCard(3, "扣除在修净缺口", "--", "等待同步", Brushes.Gray);
                }

                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "课程体系模块", Binding = new System.Windows.Data.Binding("IndentedDisplayName"), Width = 220 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "要求学分", Binding = new System.Windows.Data.Binding("RequiredCredits"), Width = 75 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "已获学分", Binding = new System.Windows.Data.Binding("PassedCredits"), Width = 75 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "本学期在修", Binding = new System.Windows.Data.Binding("TakingCredits"), Width = 80 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "达标状态与规则", Binding = new System.Windows.Data.Binding("StatusBadgeText"), Width = 160 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "在修与待修明细", Binding = new System.Windows.Data.Binding("CourseDetailSummary"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });

                _dataGrid.ItemsSource = prog?.Modules ?? new List<ProgramModuleItem>();
                break;

            case 3:
                // 课程教材与评教
                var books = snap?.Textbooks ?? new List<CourseTextbookItem>();
                _sectionTitleLabel.Text = $"本学期所修课程教材与评教清单 (共 {books.Count} 门)";

                int examCount = books.Count(b => b.ExamMode.Contains("考试") && !b.ExamMode.Contains("笔试"));
                int writtenCount = books.Count(b => b.ExamMode.Contains("笔试"));
                int checkCount = books.Count(b => b.ExamMode.Contains("考查"));
                int otherCount = books.Count - examCount - writtenCount - checkCount;

                var distParts = new List<string>();
                if (examCount > 0) distParts.Add($"考试 {examCount}");
                if (writtenCount > 0) distParts.Add($"笔试 {writtenCount}");
                if (checkCount > 0) distParts.Add($"考查 {checkCount}");
                if (otherCount > 0) distParts.Add($"其他 {otherCount}");
                var distText = distParts.Count > 0 ? string.Join(" · ", distParts) : "--";

                double bCredits = books.Sum(b => b.Credits);
                int withBook = books.Count(b => !b.DisplayTextbook.Contains("暂未指定") && !b.DisplayTextbook.Contains("不需要教材"));

                SetCard(0, "本学期课程数", $"{books.Count} 门", $"合计 {bCredits:F1} 学分", Brushes.DodgerBlue);
                SetCard(1, "指定教材课程", $"{withBook} / {books.Count} 门", "含 ISBN 教材或自编讲义", Brushes.MediumPurple);
                SetCard(2, "考核方式分布", distText, "期末考核类型统计", Brushes.Teal);
                int pendingSurveys = snap?.PendingSurveyCount ?? 0;
                SetCard(3, "期末教学评教", pendingSurveys > 0 ? $"待评 {pendingSurveys} 项" : "无待评任务", pendingSurveys > 0 ? "需在教务系统完成评教" : "评教已全部完成", pendingSurveys > 0 ? Brushes.OrangeRed : Brushes.SeaGreen);

                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "课程名称", Binding = new System.Windows.Data.Binding("CourseName"), Width = 220 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "学分/考核", Binding = new System.Windows.Data.Binding("ExamMode"), Width = 90 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "指定教材与参考书", Binding = new System.Windows.Data.Binding("DisplayTextbook"), Width = 300 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "开课学院", Binding = new System.Windows.Data.Binding("Department"), Width = 140 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "课程代码", Binding = new System.Windows.Data.Binding("CourseCode"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });

                _dataGrid.ItemsSource = books;
                break;
        }
    }

    private void UpdateTermOptions(List<SemesterGradeGroup> groups)
    {
        if (_currentMode != 0) return;
        _updatingTermOptions = true;
        try
        {
            _termComboBox.Items.Clear();
            if (groups.Count == 0)
            {
                _selectedTermIndex = 0;
                _termComboBox.Items.Add(new ComboBoxItem { Content = "暂无学期成绩", IsEnabled = false });
                _termComboBox.SelectedIndex = 0;
                return;
            }

            for (int i = 0; i < groups.Count; i++)
            {
                var group = groups[i];
                _termComboBox.Items.Add(new ComboBoxItem
                {
                    Content = $"{group.TermName} ({group.Grades.Count}门)",
                    Tag = i
                });
            }
            _termComboBox.Items.Add(new ComboBoxItem { Content = "────────", IsEnabled = false });
            _termComboBox.Items.Add(new ComboBoxItem
            {
                Content = $"全部学期汇总 ({AcademicService.Shared.LatestData?.AllGrades.Count ?? 0}门)",
                Tag = "all-terms"
            });

            if (_selectedTermIndex < 0 || _selectedTermIndex > groups.Count) _selectedTermIndex = 0;
            _termComboBox.SelectedIndex = _selectedTermIndex == groups.Count ? groups.Count + 1 : _selectedTermIndex;
        }
        finally
        {
            _updatingTermOptions = false;
            ThemeManager.Shared.ApplyComboBoxTheme(_termComboBox);
        }
    }

    private void UpdateSyncStatus(AcademicDataSnapshot? snapshot)
    {
        if (_isSyncing)
        {
            _syncButton.Content = "同步中...";
            _syncButton.IsEnabled = false;
            _statusLabel.Text = "正在向合工大教务系统同步最新成绩、排考、培养方案与教材...";
            return;
        }

        _syncButton.Content = "立即同步";
        _syncButton.IsEnabled = true;
        var lastSync = new[] { snapshot?.LastGradesSyncTime, snapshot?.LastExamsSyncTime }
            .Where(time => time.HasValue)
            .Select(time => time!.Value)
            .DefaultIfEmpty()
            .Max();
        if (lastSync != default)
        {
            _statusLabel.Text = $"上次同步：{lastSync:MM-dd HH:mm:ss}（每 15 分钟后台静默检测新出分）";
        }
        else if (!string.IsNullOrWhiteSpace(snapshot?.LastErrorMessage))
        {
            _statusLabel.Text = $"同步提示：{snapshot.LastErrorMessage}";
        }
        else
        {
            _statusLabel.Text = "尚未同步，点击右上角「立即同步」拉取数据";
        }
    }
}
