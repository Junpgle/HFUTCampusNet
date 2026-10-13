using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace HFUTCampusNet;

public sealed class AcademicWindow : Window
{
    private static AcademicWindow? _shared;
    public static AcademicWindow Shared => _shared ??= new AcademicWindow();

    private int _currentMode = 0; // 0: 成绩单, 1: 考试, 2: 培养方案, 3: 教材与评教

    private readonly ComboBox _tabComboBox;
    private readonly TextBlock _sectionTitleLabel;
    private readonly CheckBox _hideScoreCheckbox;

    // 4 指标卡片
    private readonly Border[] _cardBorders = new Border[4];
    private readonly TextBlock[] _cardTitles = new TextBlock[4];
    private readonly TextBlock[] _cardValues = new TextBlock[4];
    private readonly TextBlock[] _cardSubs = new TextBlock[4];

    private readonly DataGrid _dataGrid;

    private AcademicWindow()
    {
        Title = "合肥工业大学 - 学业成绩、考场安排与培养方案";
        Width = 980;
        Height = 700;
        MinWidth = 880;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var root = new Grid { Margin = new Thickness(16) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // Top Bar
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // 4 Cards
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // Section Header
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); // DataGrid

        // Top Bar
        var topBar = new Grid { Margin = new Thickness(0, 0, 0, 14) };
        topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        topBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        _tabComboBox = new ComboBox
        {
            Width = 240,
            Height = 32,
            FontSize = 13,
            FontWeight = FontWeights.Medium,
            ItemsSource = new[] { "成绩单与 GPA", "考试与校历进度", "培养方案与毕业学分", "课程教材与评教" },
            SelectedIndex = 0
        };
        _tabComboBox.SelectionChanged += (_, _) =>
        {
            _currentMode = _tabComboBox.SelectedIndex;
            ReloadUI();
        };
        Grid.SetColumn(_tabComboBox, 0);
        topBar.Children.Add(_tabComboBox);

        _hideScoreCheckbox = new CheckBox
        {
            Content = "通知中隐藏具体分数与 GPA",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(16, 0, 0, 0),
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
        Grid.SetColumn(_hideScoreCheckbox, 1);
        topBar.Children.Add(_hideScoreCheckbox);

        var refreshBtn = new Button
        {
            Content = "立即同步教务数据",
            Padding = new Thickness(12, 6, 12, 6),
            FontSize = 12
        };
        refreshBtn.Click += (_, _) =>
        {
            AcademicService.Shared.SyncAll(silent: false, _ => AppEvents.InvokeOnUI(ReloadUI));
        };
        Grid.SetColumn(refreshBtn, 2);
        topBar.Children.Add(refreshBtn);

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

        // Section Title
        _sectionTitleLabel = new TextBlock
        {
            Text = "清单",
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 8)
        };
        Grid.SetRow(_sectionTitleLabel, 2);
        root.Children.Add(_sectionTitleLabel);

        // DataGrid
        _dataGrid = new DataGrid
        {
            AutoGenerateColumns = false,
            IsReadOnly = true,
            GridLinesVisibility = DataGridGridLinesVisibility.Horizontal,
            HeadersVisibility = DataGridHeadersVisibility.Column,
            RowHeaderWidth = 0,
            FontSize = 12
        };
        Grid.SetRow(_dataGrid, 3);
        root.Children.Add(_dataGrid);

        Content = root;

        AppEvents.AcademicDataUpdated += () => AppEvents.InvokeOnUI(ReloadUI);
    }

    public void ShowWindow(int mode = 0)
    {
        _currentMode = Math.Clamp(mode, 0, 3);
        _tabComboBox.SelectedIndex = _currentMode;
        if (_currentMode == 0)
        {
            AcademicService.Shared.MarkAllGradesAsRead();
        }
        Show();
        Activate();
        ReloadUI();
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
        _dataGrid.Columns.Clear();

        switch (_currentMode)
        {
            case 0:
                // 成绩单与 GPA
                _sectionTitleLabel.Text = $"全部已出分科目清单 (共 {snap?.AllGrades.Count ?? 0} 门)";
                var overallGpa = snap?.OverallWeightedGPA.HasValue == true ? $"{snap.OverallWeightedGPA.Value:F2}" : "--";
                var overallScore = snap?.OverallWeightedAverageScore.HasValue == true ? $"{snap.OverallWeightedAverageScore.Value:F1} 分" : "--";
                var totalCredits = $"{snap?.TotalEarnedCredits ?? 0:F1} 学分";
                int passCount = snap?.AllGrades.Count(g => g.Passed) ?? 0;

                SetCard(0, "全学程加权 GPA", overallGpa, "全部已修计点课程加权", Brushes.DodgerBlue);
                SetCard(1, "全学程加权均分", overallScore, "按课程学分折算", Brushes.MediumPurple);
                SetCard(2, "累计获得学分", totalCredits, $"共 {snap?.SemesterGroups.Count ?? 0} 个学期", Brushes.Teal);
                SetCard(3, "已出分科目数", $"{passCount} / {snap?.AllGrades.Count ?? 0} 门", "通过率考核", Brushes.SeaGreen);

                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "课程名称", Binding = new System.Windows.Data.Binding("CourseName"), Width = 220 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "学期", Binding = new System.Windows.Data.Binding("TermName"), Width = 150 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "学分", Binding = new System.Windows.Data.Binding("Credits"), Width = 65 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "绩点", Binding = new System.Windows.Data.Binding("Gpa"), Width = 65 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "成绩", Binding = new System.Windows.Data.Binding("ScoreText"), Width = 80 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "课程代码", Binding = new System.Windows.Data.Binding("CourseCode"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });

                _dataGrid.ItemsSource = snap?.AllGrades ?? new List<GradeItem>();
                break;

            case 1:
                // 考试与校历进度
                var milestone = SemesterMilestoneInfo.Calculate(schedule: CourseScheduleService.Shared.CurrentSchedule);
                var upcoming = snap?.UpcomingExams() ?? new List<ExamItem>();
                _sectionTitleLabel.Text = $"本学期考试安排 (共 {snap?.Exams.Count ?? 0} 场，待考 {upcoming.Count} 场 · {milestone.SemesterName})";

                var nextExam = upcoming.FirstOrDefault();
                if (nextExam != null)
                {
                    SetCard(0, "最近一场考试", nextExam.CourseName, $"{nextExam.DateString} {nextExam.StartTimeString}~{nextExam.EndTimeString}", Brushes.Orange);
                    SetCard(1, "考试倒计时", nextExam.CountdownBadgeText(), $"考场: {nextExam.DisplayLocation}", Brushes.DodgerBlue);
                }
                else
                {
                    SetCard(0, "最近一场考试", "暂无待考科目", "本学期排考尚未公布或已考完", Brushes.SeaGreen);
                    SetCard(1, "期末周倒计时", $"约 {milestone.DaysUntilExamWeek} 天", "已进入期末备考阶段", Brushes.DodgerBlue);
                }
                SetCard(2, "校历学期进度", $"{milestone.ProgressPercentage:F0}%", $"第 {milestone.CurrentWeek} / {milestone.TotalWeeks} 周", Brushes.Teal);
                SetCard(3, $"距{milestone.VacationName}放假", $"约 {milestone.DaysUntilVacation} 天", $"学期结束: {milestone.EndDateString}", Brushes.MediumPurple);

                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "考试科目", Binding = new System.Windows.Data.Binding("CourseName"), Width = 220 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "考试日期与时间", Binding = new System.Windows.Data.Binding("DateTimeString"), Width = 180 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "倒计时", Binding = new System.Windows.Data.Binding("CountdownBadgeText()"), Width = 100 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "考试考场", Binding = new System.Windows.Data.Binding("DisplayLocation"), Width = 220 });
                _dataGrid.Columns.Add(new DataGridTextColumn { Header = "考试性质", Binding = new System.Windows.Data.Binding("ExamType"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });

                _dataGrid.ItemsSource = snap?.Exams ?? new List<ExamItem>();
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
}
