using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using MouseEventArgs = System.Windows.Input.MouseEventArgs;

namespace HFUTCampusNet;

public sealed class BarChartItem
{
    public string Label { get; init; } = string.Empty;
    public double Value { get; init; }
    public string DisplayValue { get; init; } = string.Empty;
}

/// <summary>
/// 套餐限额进度条卡片（单日限额 30GB + 每月限额 200GB免费/400GB上限 + 3终端同时在线 / 电费充裕度 / 校园一卡通充裕度）
/// </summary>
public sealed class HistoryStatsQuotaCardControl : Border
{
    private readonly TextBlock _headerLabel;
    private readonly TextBlock _row1Title;
    private readonly TextBlock _row1SubLeft;
    private readonly TextBlock _row1SubRight;
    private readonly Border _row1Fill;
    private readonly Border _row1Track;

    private readonly TextBlock _row2Title;
    private readonly TextBlock _row2SubLeft;
    private readonly TextBlock _row2SubRight;
    private readonly Border _row2Fill;
    private readonly Border _row2Track;

    private double _row1Ratio = 1.0;
    private double _row2Ratio = 1.0;

    public HistoryStatsQuotaCardControl()
    {
        CornerRadius = new CornerRadius(10);
        Background = ThemeManager.Shared.CardBackground;
        BorderBrush = ThemeManager.Shared.CardBorderBrush;
        BorderThickness = new Thickness(1);
        Padding = new Thickness(18, 12, 18, 12);

        var rootStack = new StackPanel { Orientation = Orientation.Vertical };

        _headerLabel = new TextBlock
        {
            FontSize = 11.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeManager.Shared.TextSecondary,
            Margin = new Thickness(0, 0, 0, 10),
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        rootStack.Children.Add(_headerLabel);

        rootStack.Children.Add(BuildQuotaRow(
            out _row1Title, out _row1SubLeft, out _row1SubRight, out _row1Track, out _row1Fill,
            new Thickness(0, 0, 0, 10)));

        rootStack.Children.Add(BuildQuotaRow(
            out _row2Title, out _row2SubLeft, out _row2SubRight, out _row2Track, out _row2Fill,
            new Thickness(0)));

        Child = rootStack;
        SizeChanged += (_, _) => UpdateBarWidths();
        ApplyTheme();
    }

    private static UIElement BuildQuotaRow(
        out TextBlock titleLabel,
        out TextBlock subLeftLabel,
        out TextBlock subRightLabel,
        out Border trackBorder,
        out Border fillBorder,
        Thickness margin)
    {
        var panel = new StackPanel { Orientation = Orientation.Vertical, Margin = margin };

        titleLabel = new TextBlock
        {
            FontSize = 12.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeManager.Shared.TextPrimary,
            Margin = new Thickness(0, 0, 0, 3)
        };
        panel.Children.Add(titleLabel);

        var subGrid = new Grid { Margin = new Thickness(0, 0, 0, 4) };
        subGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        subGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        subLeftLabel = new TextBlock
        {
            FontSize = 11,
            Foreground = ThemeManager.Shared.TextSecondary,
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        Grid.SetColumn(subLeftLabel, 0);
        subGrid.Children.Add(subLeftLabel);

        subRightLabel = new TextBlock
        {
            FontSize = 11,
            FontWeight = FontWeights.Medium,
            Foreground = ThemeManager.Shared.TextSecondary,
            Margin = new Thickness(8, 0, 0, 0)
        };
        Grid.SetColumn(subRightLabel, 1);
        subGrid.Children.Add(subRightLabel);

        panel.Children.Add(subGrid);

        trackBorder = new Border
        {
            Height = 6,
            CornerRadius = new CornerRadius(3),
            Background = ThemeManager.Shared.IsDarkTheme
                ? new SolidColorBrush(Color.FromArgb(45, 255, 255, 255))
                : new SolidColorBrush(Color.FromArgb(30, 0, 0, 0)),
            HorizontalAlignment = HorizontalAlignment.Stretch
        };

        fillBorder = new Border
        {
            Height = 6,
            CornerRadius = new CornerRadius(3),
            HorizontalAlignment = HorizontalAlignment.Left,
            Width = 0
        };
        trackBorder.Child = fillBorder;
        panel.Children.Add(trackBorder);

        return panel;
    }

    public void Refresh(int mode)
    {
        if (mode == 0)
        {
            _headerLabel.Text = "套餐限额  ·  访问校内资源免费；校外资源日限 30GB、月限 400GB（每月前 200GB 免费，超出 0.5元/GB）；最多 3 个终端同时在线";

            double dailyLimitMB = 30.0 * 1024.0;
            double dailyUsedMB = Math.Max(0.0, CampusHistoryManager.Shared.TodayFlowDeltaMB);
            double dailyRemainRatio = Math.Clamp((dailyLimitMB - dailyUsedMB) / dailyLimitMB, 0.0, 1.0);
            int dailyRemainPct = (int)Math.Round(dailyRemainRatio * 100.0);
            string dailyUsedGBStr = $"{dailyUsedMB / 1024.0:F2} GB";

            _row1Title.Text = "单日限额 (30 GB)";
            _row1SubLeft.Text = $"{CampusHistoryManager.Shared.DailyResetCountdownString}  ·  已用 {dailyUsedGBStr} / 30 GB";
            _row1SubRight.Text = $"剩余 {dailyRemainPct}%";
            _row1Ratio = dailyRemainRatio;

            var netData = CampusNetworkClient.Shared.LatestData;
            double fallbackUsedMB = CampusHistoryManager.Shared.CurrentMonthUsedFlowMB;
            double monthlyUsedMB = Math.Max(0.0, Math.Max(netData.UsedMB ?? 0.0, fallbackUsedMB));
            double freeLimitMB = 200.0 * 1024.0;
            double maxLimitMB = 400.0 * 1024.0;

            int onlineCount = netData.OnlineDevices?.Count ?? 0;
            string onlineBadge = $"  (当前在线 {onlineCount}/3 台终端)";

            if (monthlyUsedMB <= freeLimitMB)
            {
                double remainRatio = Math.Clamp((freeLimitMB - monthlyUsedMB) / freeLimitMB, 0.0, 1.0);
                int pct = (int)Math.Round(remainRatio * 100.0);
                string usedGB = $"{monthlyUsedMB / 1024.0:F2} GB";
                _row2Title.Text = $"每月免费限额 (200 GB 免费 / 月上限 400 GB){onlineBadge}";
                _row2SubLeft.Text = $"{CampusHistoryManager.Shared.MonthlyResetCountdownString}  ·  已用 {usedGB} / 200 GB 免费额度";
                _row2SubRight.Text = $"剩余 {pct}%";
                _row2Ratio = remainRatio;
            }
            else
            {
                double remainRatio = Math.Clamp((maxLimitMB - monthlyUsedMB) / maxLimitMB, 0.0, 1.0);
                int pct = (int)Math.Round(remainRatio * 100.0);
                double usedGB = monthlyUsedMB / 1024.0;
                double extraGB = Math.Max(0.0, usedGB - 200.0);
                double extraFee = extraGB * 0.5;
                _row2Title.Text = $"每月总限额 (400 GB 上限 · 超出 0.5元/GB){onlineBadge}";
                _row2SubLeft.Text = $"{CampusHistoryManager.Shared.MonthlyResetCountdownString}  ·  已用 {usedGB:F2} GB (超免费 {extraGB:F1} GB ≈ ¥{extraFee:F2})";
                _row2SubRight.Text = $"剩余 {pct}%";
                _row2Ratio = remainRatio;
            }
        }
        else if (mode == 1)
        {
            _headerLabel.Text = "宿舍用电限额与续航预估  ·  基于近期日均用电量动态测算剩余电费可用比例";

            var elec = ElectricityService.Shared.LatestData;
            var fallbackElec = CampusHistoryManager.Shared.LatestElectricityRecord;
            double bal = elec?.BalanceRMB ?? fallbackElec?.BalanceRMB ?? 0.0;
            double? kwh = elec?.RemainingKWh ?? fallbackElec?.RemainingKWh;
            string balDisplay = elec?.DisplayBalance ?? (fallbackElec != null ? $"{fallbackElec.BalanceRMB:F2} 元" : "--");
            string pwrDisplay = elec?.DisplayPower ?? (kwh.HasValue ? $"剩余 {kwh.Value:F1} 度" : "--");
            double ratio = Math.Clamp(bal / 200.0, 0.0, 1.0);
            int pct = (int)Math.Round(ratio * 100.0);
            int daysLeft = CampusHistoryManager.Shared.EstimatedElectricityDaysRemaining ?? 0;

            _row1Title.Text = "宿舍电费余额充裕度 (按 200 元满额基准)";
            _row1SubLeft.Text = $"当前余额 {balDisplay}  ·  {pwrDisplay}";
            _row1SubRight.Text = $"充裕度 {pct}%";
            _row1Ratio = ratio;

            double dayRatio = Math.Clamp(daysLeft / 60.0, 0.0, 1.0);
            _row2Title.Text = "预计续航周期 (按 60 天满周期基准)";
            _row2SubLeft.Text = $"近 7 天日均消费 {CampusHistoryManager.Shared.Past7DaysElectricityDailyAverageRMB:F2} 元/天";
            _row2SubRight.Text = daysLeft > 0 ? $"约余 {daysLeft} 天" : "测算中";
            _row2Ratio = dayRatio;
        }
        else
        {
            double budget = Math.Max(1.0, SettingsManager.Shared.CampusCardDailyBudget);
            double warnThresh = SettingsManager.Shared.CampusCardLowWarningThreshold;
            _headerLabel.Text = $"校园一卡通充裕度与消费预算  ·  单日参考基准 {budget:F0} 元 · 低于预警阈值 ({warnThresh:F0}元) 自动提醒充值（点击右上角「一卡通预算...」可自定义）";

            var card = CampusCardService.Shared.LatestData;
            double bal = card?.BalanceRMB ?? 0.0;
            string balDisplay = card?.DisplayBalance ?? "--";
            double ratio = Math.Clamp(bal / 200.0, 0.0, 1.0);
            int pct = (int)Math.Round(ratio * 100.0);

            _row1Title.Text = "校园卡余额充裕度 (按 200 元常备基准)";
            _row1SubLeft.Text = $"当前卡内余额 {balDisplay}  ·  预警红线 {warnThresh:F0} 元";
            _row1SubRight.Text = $"充裕度 {pct}%";
            _row1Ratio = ratio;

            double todaySpent = card?.TodaySpentRMB() ?? 0.0;
            int todayCount = card?.TodayExpenseCount() ?? 0;
            double budgetRemainRatio = Math.Clamp((budget - todaySpent) / budget, 0.0, 1.0);
            _row2Title.Text = $"今日消费参考 (按单日 {budget:F0} 元餐饮/日常基准)";
            _row2SubLeft.Text = $"今日已消费 {todaySpent:F2} 元 (共 {todayCount} 笔交易)";
            _row2SubRight.Text = $"今日已用 {Math.Min(100.0, (todaySpent / budget) * 100.0):F0}%";
            _row2Ratio = budgetRemainRatio;
        }

        UpdateBarWidths();
    }

    public void ApplyTheme()
    {
        Background = ThemeManager.Shared.CardBackground;
        BorderBrush = ThemeManager.Shared.CardBorderBrush;
        _headerLabel.Foreground = ThemeManager.Shared.TextSecondary;
        _row1Title.Foreground = ThemeManager.Shared.TextPrimary;
        _row1SubLeft.Foreground = ThemeManager.Shared.TextSecondary;
        _row1SubRight.Foreground = ThemeManager.Shared.TextSecondary;
        _row2Title.Foreground = ThemeManager.Shared.TextPrimary;
        _row2SubLeft.Foreground = ThemeManager.Shared.TextSecondary;
        _row2SubRight.Foreground = ThemeManager.Shared.TextSecondary;
        _row1Track.Background = ThemeManager.Shared.IsDarkTheme
            ? new SolidColorBrush(Color.FromArgb(45, 255, 255, 255))
            : new SolidColorBrush(Color.FromArgb(30, 0, 0, 0));
        _row2Track.Background = _row1Track.Background;
        UpdateBarWidths();
    }

    private void UpdateBarWidths()
    {
        ApplyBarVisual(_row1Track, _row1Fill, _row1Ratio);
        ApplyBarVisual(_row2Track, _row2Fill, _row2Ratio);
    }

    private static void ApplyBarVisual(Border track, Border fill, double ratio)
    {
        double clamped = Math.Clamp(ratio, 0.0, 1.0);
        double trackW = track.ActualWidth > 0 ? track.ActualWidth : 780;
        fill.Width = Math.Max(6.0, trackW * clamped);

        if (clamped < 0.15)
            fill.Background = new SolidColorBrush(Color.FromRgb(220, 53, 69));
        else if (clamped < 0.30)
            fill.Background = new SolidColorBrush(Color.FromRgb(245, 158, 11));
        else
            fill.Background = ThemeManager.Shared.IsDarkTheme
                ? new SolidColorBrush(Color.FromArgb(220, 215, 220, 232))
                : new SolidColorBrush(Color.FromArgb(200, 35, 42, 52));
    }
}

/// <summary>
/// 7 日历史柱状图控件（1:1 复刻 macOS HistoryBarChartView）
/// </summary>
public sealed class HistoryBarChartControl : FrameworkElement
{
    private List<BarChartItem> _items = new();
    private Color _barColor = Color.FromRgb(0, 122, 255);
    private string _unit = string.Empty;

    public HistoryBarChartControl()
    {
        Height = 184;
        ClipToBounds = true;
    }

    public void SetData(IEnumerable<BarChartItem> items, Color barColor, string unit)
    {
        _items = items?.ToList() ?? new List<BarChartItem>();
        _barColor = barColor;
        _unit = unit;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        double w = ActualWidth;
        double h = ActualHeight;
        if (w <= 20 || h <= 20) return;

        var bgRect = new Rect(0.5, 0.5, w - 1, h - 1);
        bool isDark = ThemeManager.Shared.IsDarkTheme;
        var bgBrush = new SolidColorBrush(isDark
            ? Color.FromRgb(28, 30, 38)
            : Color.FromArgb(230, 250, 251, 253));
        var borderPen = new Pen(new SolidColorBrush(isDark
            ? Color.FromArgb(38, 255, 255, 255)
            : Color.FromArgb(30, 0, 0, 0)), 1.0);
        dc.DrawRoundedRectangle(bgBrush, borderPen, bgRect, 10, 10);

        var typeface = new Typeface(new FontFamily("Microsoft YaHei UI, Segoe UI"), FontStyles.Normal, FontWeights.Medium, FontStretches.Normal);
        double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;

        if (_items.Count == 0)
        {
            var emptyFt = new FormattedText(
                "暂无充足历史统计数据，系统将随日常使用自动积累",
                CultureInfo.CurrentUICulture,
                System.Windows.FlowDirection.LeftToRight,
                typeface,
                12,
                new SolidColorBrush(isDark ? Color.FromRgb(150, 156, 171) : Color.FromRgb(120, 128, 140)),
                dpi);
            dc.DrawText(emptyFt, new Point((w - emptyFt.Width) / 2.0, (h - emptyFt.Height) / 2.0));
            return;
        }

        double maxVal = Math.Max(_items.Max(i => i.Value), 0.05);
        double chartTop = 28;
        double chartBottom = h - 28;
        double chartHeight = Math.Max(10.0, chartBottom - chartTop);
        int count = Math.Max(1, _items.Count);
        double barWidth = Math.Min(42.0, Math.Max(10.0, (w - 60.0) / (count * 2.0)));
        double slotWidth = (w - 40.0) / count;

        var dashPen = new Pen(new SolidColorBrush(isDark
            ? Color.FromArgb(30, 255, 255, 255)
            : Color.FromArgb(26, 0, 0, 0)), 1.0)
        {
            DashStyle = new DashStyle(new double[] { 4, 4 }, 0)
        };
        for (int step = 1; step <= 3; step++)
        {
            double y = chartBottom - chartHeight * step / 3.0;
            dc.DrawLine(dashPen, new Point(20, y), new Point(w - 20, y));
        }

        var topBrush = new SolidColorBrush(_barColor);
        var bottomBrush = new SolidColorBrush(Color.FromArgb(190, _barColor.R, _barColor.G, _barColor.B));
        var barGrad = new LinearGradientBrush(topBrush.Color, bottomBrush.Color, new Point(0, 0), new Point(0, 1));
        var valTextBrush = new SolidColorBrush(isDark ? Color.FromRgb(205, 210, 220) : Color.FromRgb(90, 98, 112));
        var dateTextBrush = new SolidColorBrush(isDark ? Color.FromRgb(150, 156, 171) : Color.FromRgb(135, 142, 155));

        for (int i = 0; i < _items.Count; i++)
        {
            var item = _items[i];
            double centerX = 20.0 + slotWidth * i + slotWidth / 2.0;
            double barX = centerX - barWidth / 2.0;
            double ratio = Math.Clamp(item.Value / maxVal, 0.0, 1.0);
            double barH = Math.Max(4.0, chartHeight * ratio);
            double barY = chartBottom - barH;

            var barRect = new Rect(barX, barY, barWidth, barH);
            dc.DrawRoundedRectangle(barGrad, null, barRect, 4, 4);

            var valFt = new FormattedText(
                item.DisplayValue,
                CultureInfo.CurrentUICulture,
                System.Windows.FlowDirection.LeftToRight,
                typeface,
                10,
                valTextBrush,
                dpi);
            dc.DrawText(valFt, new Point(centerX - valFt.Width / 2.0, Math.Max(4, barY - valFt.Height - 3)));

            var dateFt = new FormattedText(
                item.Label,
                CultureInfo.CurrentUICulture,
                System.Windows.FlowDirection.LeftToRight,
                typeface,
                10,
                dateTextBrush,
                dpi);
            dc.DrawText(dateFt, new Point(centerX - dateFt.Width / 2.0, chartBottom + 6));
        }
    }
}

public sealed class HistoryTableRow
{
    public string Col1 { get; init; } = string.Empty;
    public string Col2 { get; init; } = string.Empty;
    public string Col3 { get; init; } = string.Empty;
    public string Col4 { get; init; } = string.Empty;
    public string Col5 { get; init; } = string.Empty;
    public string Col6 { get; init; } = string.Empty;
    public Brush Col3Foreground { get; init; } = new SolidColorBrush(Color.FromRgb(30, 34, 40));
    public Brush Col4Foreground { get; init; } = new SolidColorBrush(Color.FromRgb(30, 34, 40));
    public FontWeight Col4FontWeight { get; init; } = FontWeights.Normal;
}

/// <summary>
/// 校园用量统计与历史分析窗口 (1:1 移植自 HistoryStatsWindowController.swift)
/// </summary>
public sealed class HistoryStatsWindow : Window
{
    public static HistoryStatsWindow Shared { get; } = new HistoryStatsWindow();

    private readonly Button[] _tabButtons = new Button[3];
    private readonly Button _settingsBtn;
    private readonly Button _ssoBtn;
    private readonly Button _refreshBtn;

    private readonly TextBlock[] _cardTitleLabels = new TextBlock[4];
    private readonly TextBlock[] _cardValueLabels = new TextBlock[4];
    private readonly TextBlock[] _cardSubLabels = new TextBlock[4];

    private readonly HistoryStatsQuotaCardControl _quotaCardView;
    private readonly HistoryBarChartControl _chartView;
    private readonly TextBlock _tableTitleLabel;
    private readonly DataGrid _tableView;
    private Border _topBar = null!;
    private Border _segBorder = null!;
    private readonly Border[] _cardBorders = new Border[4];
    private Border _tableBorder = null!;

    private int _currentMode; // 0: 校园网流量, 1: 宿舍电费, 2: 校园一卡通账单
    private List<DailyFlowRecord> _currentFlowRecords = new();
    private List<DailyElectricityRecord> _currentElectricityRecords = new();
    private List<CampusCardTransaction> _currentCardTransactions = new();

    private HistoryStatsWindow()
    {
        Title = "校园用量统计与历史分析 - 合肥工业大学";
        Width = 896;
        Height = 820;
        MinWidth = 836;
        MinHeight = 680;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = new SolidColorBrush(Color.FromRgb(244, 245, 248));

        var rootGrid = new Grid();
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(54) });
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // 1. 顶部控制条
        _topBar = new Border
        {
            Background = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromArgb(25, 0, 0, 0)),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Padding = new Thickness(20, 0, 20, 0)
        };
        var topBarGrid = new Grid();
        topBarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        topBarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        topBarGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        _segBorder = new Border
        {
            CornerRadius = new CornerRadius(7),
            Background = new SolidColorBrush(Color.FromRgb(236, 238, 242)),
            Padding = new Thickness(2),
            VerticalAlignment = VerticalAlignment.Center
        };
        var segPanel = new UniformGrid { Rows = 1, Columns = 3, Width = 384, Height = 28 };
        string[] tabNames = { "校园网流量统计", "宿舍电费分析", "校园一卡通账单" };
        for (int i = 0; i < 3; i++)
        {
            int modeIdx = i;
            var btn = new Button
            {
                Content = tabNames[i],
                FontSize = 12,
                BorderThickness = new Thickness(0),
                Cursor = Cursors.Hand,
                Padding = new Thickness(8, 2, 8, 2)
            };
            btn.Click += (_, _) => OnSegmentChanged(modeIdx);
            _tabButtons[i] = btn;
            segPanel.Children.Add(btn);
        }
        _segBorder.Child = segPanel;
        Grid.SetColumn(_segBorder, 0);
        topBarGrid.Children.Add(_segBorder);

        var rightBtns = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center
        };

        _settingsBtn = CreateToolbarButton("宿舍配置...", 108, OnOpenSettings);
        _settingsBtn.Margin = new Thickness(0, 0, 8, 0);
        rightBtns.Children.Add(_settingsBtn);

        _ssoBtn = CreateToolbarButton("统一身份认证同步", 136, OnOpenUnifiedLogin);
        _ssoBtn.Margin = new Thickness(0, 0, 8, 0);
        rightBtns.Children.Add(_ssoBtn);

        _refreshBtn = CreateToolbarButton("立即刷新", 88, OnRefreshClicked, isPrimary: true);
        rightBtns.Children.Add(_refreshBtn);

        Grid.SetColumn(rightBtns, 2);
        topBarGrid.Children.Add(rightBtns);
        _topBar.Child = topBarGrid;
        Grid.SetRow(_topBar, 0);
        rootGrid.Children.Add(_topBar);

        // 2. 4 个指标统计卡片
        var cardsGrid = new UniformGrid
        {
            Rows = 1,
            Columns = 4,
            Margin = new Thickness(20, 12, 20, 10),
            Height = 76
        };
        for (int i = 0; i < 4; i++)
        {
            var cardBorder = new Border
            {
                CornerRadius = new CornerRadius(10),
                Background = Brushes.White,
                BorderBrush = new SolidColorBrush(Color.FromArgb(26, 0, 0, 0)),
                BorderThickness = new Thickness(1),
                Margin = new Thickness(i == 0 ? 0 : 6, 0, i == 3 ? 0 : 6, 0),
                Padding = new Thickness(14, 8, 14, 6)
            };

            var stack = new DockPanel();

            var titleLbl = new TextBlock
            {
                Text = "指标",
                FontSize = 11,
                Foreground = new SolidColorBrush(Color.FromRgb(110, 116, 128)),
                TextTrimming = TextTrimming.CharacterEllipsis
            };
            DockPanel.SetDock(titleLbl, Dock.Top);
            stack.Children.Add(titleLbl);

            var subLbl = new TextBlock
            {
                Text = "--",
                FontSize = 10,
                Foreground = new SolidColorBrush(Color.FromRgb(140, 146, 158)),
                TextTrimming = TextTrimming.CharacterEllipsis
            };
            DockPanel.SetDock(subLbl, Dock.Bottom);
            stack.Children.Add(subLbl);

            var valLbl = new TextBlock
            {
                Text = "--",
                FontSize = 20,
                FontWeight = FontWeights.Bold,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis
            };
            stack.Children.Add(valLbl);

            cardBorder.Child = stack;
            cardsGrid.Children.Add(cardBorder);

            _cardBorders[i] = cardBorder;
            _cardTitleLabels[i] = titleLbl;
            _cardValueLabels[i] = valLbl;
            _cardSubLabels[i] = subLbl;
        }
        Grid.SetRow(cardsGrid, 1);
        rootGrid.Children.Add(cardsGrid);

        // 3. 套餐限额进度条卡片
        _quotaCardView = new HistoryStatsQuotaCardControl
        {
            Margin = new Thickness(20, 0, 20, 10)
        };
        Grid.SetRow(_quotaCardView, 2);
        rootGrid.Children.Add(_quotaCardView);

        // 4. 7日柱状图
        _chartView = new HistoryBarChartControl
        {
            Margin = new Thickness(20, 0, 20, 10),
            Height = 184
        };
        Grid.SetRow(_chartView, 3);
        rootGrid.Children.Add(_chartView);

        // 5. 表格标题
        _tableTitleLabel = new TextBlock
        {
            Text = "历史详细记录",
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = new SolidColorBrush(Color.FromRgb(95, 102, 114)),
            Margin = new Thickness(20, 0, 20, 6)
        };
        Grid.SetRow(_tableTitleLabel, 4);
        rootGrid.Children.Add(_tableTitleLabel);

        // 6. 底部明细表格
        _tableBorder = new Border
        {
            Margin = new Thickness(20, 0, 20, 18),
            CornerRadius = new CornerRadius(8),
            BorderBrush = new SolidColorBrush(Color.FromArgb(32, 0, 0, 0)),
            BorderThickness = new Thickness(1),
            Background = Brushes.White,
            ClipToBounds = true
        };

        _tableView = new DataGrid
        {
            AutoGenerateColumns = false,
            IsReadOnly = true,
            CanUserAddRows = false,
            CanUserDeleteRows = false,
            CanUserReorderColumns = false,
            GridLinesVisibility = DataGridGridLinesVisibility.Horizontal,
            HorizontalGridLinesBrush = new SolidColorBrush(Color.FromArgb(16, 0, 0, 0)),
            HeadersVisibility = DataGridHeadersVisibility.Column,
            RowHeight = 27,
            AlternatingRowBackground = new SolidColorBrush(Color.FromRgb(249, 250, 252)),
            Background = Brushes.White,
            BorderThickness = new Thickness(0),
            SelectionMode = DataGridSelectionMode.Single,
            FontSize = 11.5
        };
        _tableBorder.Child = _tableView;
        Grid.SetRow(_tableBorder, 5);
        rootGrid.Children.Add(_tableBorder);

        Content = rootGrid;

        ThemeManager.Shared.ApplyWindowTheme(this);
        ApplyTheme();
        ThemeManager.Shared.ThemeChanged += () => AppEvents.InvokeOnUI(() =>
        {
            ApplyTheme();
            ReloadData();
        });

        Closing += (_, e) =>
        {
            e.Cancel = true;
            Hide();
        };

        AppEvents.HistoryStatsUpdated += () => AppEvents.InvokeOnUI(ReloadData);
        AppEvents.DormElectricityUpdated += () => AppEvents.InvokeOnUI(ReloadData);
        AppEvents.CampusCardUpdated += () => AppEvents.InvokeOnUI(ReloadData);
        AppEvents.NetworkDataUpdated += () => AppEvents.InvokeOnUI(ReloadData);

        UpdateSegmentButtonStyles();
        ApplyToolbarButtonTheme(_settingsBtn, isPrimary: false);
        ApplyToolbarButtonTheme(_ssoBtn, isPrimary: false);
        ApplyToolbarButtonTheme(_refreshBtn, isPrimary: true);
        ReloadData();
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

        if (_segBorder != null)
        {
            _segBorder.Background = ThemeManager.Shared.ControlBackground;
        }

        if (_tableTitleLabel != null)
        {
            _tableTitleLabel.Foreground = ThemeManager.Shared.TextPrimary;
        }

        _quotaCardView?.ApplyTheme();

        for (int i = 0; i < 4; i++)
        {
            if (_cardBorders[i] != null)
            {
                _cardBorders[i].Background = ThemeManager.Shared.CardBackground;
                _cardBorders[i].BorderBrush = ThemeManager.Shared.CardBorderBrush;
                _cardTitleLabels[i].Foreground = ThemeManager.Shared.TextSecondary;
                _cardSubLabels[i].Foreground = ThemeManager.Shared.TextMuted;
            }
        }

        if (_tableBorder != null)
        {
            _tableBorder.Background = ThemeManager.Shared.TableBackground;
            _tableBorder.BorderBrush = ThemeManager.Shared.CardBorderBrush;
        }

        if (_tableView != null)
        {
            ThemeManager.Shared.ApplyDataGridTheme(_tableView);
            _tableView.Background = ThemeManager.Shared.TableBackground;
            _tableView.RowBackground = ThemeManager.Shared.TableBackground;
            _tableView.AlternatingRowBackground = ThemeManager.Shared.TableAlternatingBackground;
            _tableView.HorizontalGridLinesBrush = ThemeManager.Shared.TableGridLineBrush;
            _tableView.Foreground = ThemeManager.Shared.TextPrimary;
        }

        UpdateSegmentButtonStyles();
        ApplyToolbarButtonTheme(_settingsBtn, isPrimary: false);
        ApplyToolbarButtonTheme(_ssoBtn, isPrimary: false);
        ApplyToolbarButtonTheme(_refreshBtn, isPrimary: true);
    }

    private static Button CreateToolbarButton(string title, double width, Action onClick, bool isPrimary = false)
    {
        var btn = new Button
        {
            Content = title,
            Width = width,
            Height = 28,
            FontSize = 12,
            Cursor = Cursors.Hand,
            Background = isPrimary ? ThemeManager.Shared.Accent : ThemeManager.Shared.ControlBackground,
            Foreground = isPrimary ? Brushes.White : ThemeManager.Shared.TextPrimary,
            BorderBrush = isPrimary ? ThemeManager.Shared.Accent : ThemeManager.Shared.ControlBorderBrush,
            BorderThickness = new Thickness(1)
        };
        btn.Click += (_, _) => onClick();
        return btn;
    }

    private void UpdateSegmentButtonStyles()
    {
        for (int i = 0; i < _tabButtons.Length; i++)
        {
            bool selected = (i == _currentMode);
            _tabButtons[i].Background = selected
                ? ThemeManager.Shared.Accent
                : Brushes.Transparent;
            _tabButtons[i].Foreground = selected
                ? Brushes.White
                : ThemeManager.Shared.TextSecondary;
            _tabButtons[i].FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal;
        }
    }

    private static void ApplyToolbarButtonTheme(Button button, bool isPrimary)
    {
        button.Background = isPrimary ? ThemeManager.Shared.Accent : ThemeManager.Shared.ControlBackground;
        button.Foreground = isPrimary ? Brushes.White : ThemeManager.Shared.TextPrimary;
        button.BorderBrush = isPrimary ? ThemeManager.Shared.Accent : ThemeManager.Shared.ControlBorderBrush;
    }

    public void ShowWindow(int mode = 0)
    {
        _currentMode = Math.Clamp(mode, 0, 2);
        ApplyTheme();
        UpdateSegmentButtonStyles();

        if (!IsVisible)
            Show();
        if (WindowState == WindowState.Minimized)
            WindowState = WindowState.Normal;
        Activate();
        Focus();

        ReloadData();

        if (_currentMode == 1 || ElectricityService.Shared.LatestData == null)
        {
            ElectricityService.Shared.FetchData((_, _) => ReloadData());
        }
        if (_currentMode == 2 || CampusCardService.Shared.LatestData == null)
        {
            CampusCardService.Shared.FetchData((_, _) => ReloadData());
        }
        if (_currentMode == 0 || _currentFlowRecords.Count == 0)
        {
            CampusNetworkClient.Shared.FetchData();
            CampusNetworkClient.Shared.FetchOnlineDevices();
        }
    }

    private void OnSegmentChanged(int mode)
    {
        _currentMode = mode;
        UpdateSegmentButtonStyles();
        ReloadData();

        if (_currentMode == 1 && ElectricityService.Shared.LatestData == null)
        {
            ElectricityService.Shared.FetchData((_, _) => ReloadData());
        }
        else if (_currentMode == 2 && CampusCardService.Shared.LatestData == null)
        {
            CampusCardService.Shared.FetchData((_, _) => ReloadData());
        }
    }

    private void OnRefreshClicked()
    {
        CampusNetworkClient.Shared.FetchData();
        CampusNetworkClient.Shared.FetchOnlineDevices();
        ElectricityService.Shared.FetchData((_, _) => ReloadData());
        CampusCardService.Shared.FetchData((_, _) => ReloadData());
    }

    private static void OnOpenUnifiedLogin()
    {
        UnifiedLoginWebWindow.Shared.ShowLoginWindow();
    }

    private void OnOpenSettings()
    {
        if (_currentMode == 2)
        {
            PromptCampusCardBudgetSettings();
        }
        else
        {
            SettingsWindow.Shared.ShowSettings();
        }
    }

    private void PromptCampusCardBudgetSettings()
    {
        var dialog = new Window
        {
            Title = "校园一卡通消费预算与预警设置",
            Width = 400,
            Height = 235,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = this,
            ResizeMode = ResizeMode.NoResize,
            Background = ThemeManager.Shared.WindowBackground,
            Foreground = ThemeManager.Shared.TextPrimary
        };

        var root = new StackPanel { Margin = new Thickness(20, 16, 20, 16) };
        root.Children.Add(new TextBlock
        {
            Text = "可自定义单日餐饮/日常消费参考基准（默认 30 元）以及卡内余额不足提醒红线（默认 15 元）：",
            FontSize = 12,
            Foreground = ThemeManager.Shared.TextSecondary,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 14)
        });

        var row1 = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 10) };
        row1.Children.Add(new TextBlock
        {
            Text = "单日消费预算基准：",
            Width = 130,
            VerticalAlignment = VerticalAlignment.Center,
            TextAlignment = TextAlignment.Right
        });
        var budgetBox = new TextBox
        {
            Width = 90,
            Height = 24,
            VerticalContentAlignment = VerticalAlignment.Center,
            Text = $"{SettingsManager.Shared.CampusCardDailyBudget:F0}"
        };
        row1.Children.Add(budgetBox);
        row1.Children.Add(new TextBlock
        {
            Text = " 元 / 天",
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = new SolidColorBrush(Color.FromRgb(110, 116, 128))
        });
        root.Children.Add(row1);

        var row2 = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 18) };
        row2.Children.Add(new TextBlock
        {
            Text = "低余额预警红线：",
            Width = 130,
            VerticalAlignment = VerticalAlignment.Center,
            TextAlignment = TextAlignment.Right
        });
        var threshBox = new TextBox
        {
            Width = 90,
            Height = 24,
            VerticalContentAlignment = VerticalAlignment.Center,
            Text = $"{SettingsManager.Shared.CampusCardLowWarningThreshold:F0}"
        };
        row2.Children.Add(threshBox);
        row2.Children.Add(new TextBlock
        {
            Text = " 元",
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = new SolidColorBrush(Color.FromRgb(110, 116, 128))
        });
        root.Children.Add(row2);

        var btnRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right
        };

        var resetBtn = CreateToolbarButton("恢复默认 (30元/15元)", 135, () =>
        {
            SettingsManager.Shared.CampusCardDailyBudget = 30.0;
            SettingsManager.Shared.CampusCardLowWarningThreshold = 15.0;
            ReloadData();
            AppEvents.RaiseCampusCardUpdated();
            dialog.Close();
        });
        resetBtn.Margin = new Thickness(0, 0, 8, 0);
        btnRow.Children.Add(resetBtn);

        var cancelBtn = CreateToolbarButton("取消", 68, () => dialog.Close());
        cancelBtn.Margin = new Thickness(0, 0, 8, 0);
        btnRow.Children.Add(cancelBtn);

        var saveBtn = CreateToolbarButton("保存", 76, () =>
        {
            if (double.TryParse(budgetBox.Text.Trim(), NumberStyles.Any, CultureInfo.InvariantCulture, out double b) && b > 0)
                SettingsManager.Shared.CampusCardDailyBudget = b;
            if (double.TryParse(threshBox.Text.Trim(), NumberStyles.Any, CultureInfo.InvariantCulture, out double t) && t > 0)
                SettingsManager.Shared.CampusCardLowWarningThreshold = t;
            ReloadData();
            AppEvents.RaiseCampusCardUpdated();
            dialog.Close();
        }, isPrimary: true);
        btnRow.Children.Add(saveBtn);

        root.Children.Add(btnRow);
        dialog.Content = root;
        ThemeManager.Shared.ApplyWindowTheme(dialog);
        dialog.ShowDialog();
    }

    public void ReloadData()
    {
        _currentFlowRecords = CampusHistoryManager.Shared.GetPastDaysFlowRecords(90).AsEnumerable().Reverse().ToList();
        _currentElectricityRecords = CampusHistoryManager.Shared.GetPastDaysElectricityRecords(90).AsEnumerable().Reverse().ToList();
        _currentCardTransactions = CampusCardService.Shared.LatestData?.Transactions ?? new List<CampusCardTransaction>();

        if (_currentMode == 0)
        {
            _settingsBtn.Content = "宿舍配置...";
            _tableTitleLabel.Text = "校园网每日流量明细";
        }
        else if (_currentMode == 1)
        {
            _settingsBtn.Content = "宿舍配置...";
            _tableTitleLabel.Text = "宿舍每日用电历史记录";
        }
        else
        {
            _settingsBtn.Content = "一卡通预算...";
            if (CampusCardService.Shared.LatestData is { } card)
            {
                var breakdown = card.ExpenseStructureBreakdown();
                _tableTitleLabel.Text =
                    $"校园一卡通近期账单 ({_currentCardTransactions.Count}笔 · 早 ¥{breakdown.BreakfastRMB:F0} / 午 ¥{breakdown.LunchRMB:F0} / 晚 ¥{breakdown.DinnerRMB:F0} / 其他 ¥{breakdown.OtherRMB:F0})";
            }
            else
            {
                _tableTitleLabel.Text = $"校园一卡通近期交易流水 (最近 {_currentCardTransactions.Count} 笔)";
            }
        }

        UpdateCards();
        _quotaCardView.Refresh(_currentMode);
        UpdateChart();
        PopulateTable();
    }

    private void UpdateCards()
    {
        if (_currentMode == 0)
        {
            SetCard(0, "今日新增用量", FormatMB(CampusHistoryManager.Shared.TodayFlowDeltaMB), "今日产生流量消耗", Color.FromRgb(0, 122, 255));
            SetCard(1, "近 7 天累计消耗", FormatMB(CampusHistoryManager.Shared.Past7DaysFlowTotalMB), "近一周网络流量总计", Color.FromRgb(88, 86, 214));
            SetCard(2, "近 7 天日均消耗", FormatMB(CampusHistoryManager.Shared.Past7DaysFlowDailyAverageMB) + "/天", "每日平均使用水平", Color.FromRgb(48, 176, 199));

            var netData = CampusNetworkClient.Shared.LatestData;
            string balText;
            if (!string.IsNullOrWhiteSpace(netData.Balance) && netData.Balance != "-- 元")
            {
                balText = netData.Balance;
            }
            else if ((_currentFlowRecords.FirstOrDefault()?.BalanceRMB ?? CampusHistoryManager.Shared.LatestFlowBalanceRMB) is { } lastBal)
            {
                balText = $"{lastBal:F2} 元";
            }
            else
            {
                balText = "-- 元";
            }

            double bestMonthlyMB = Math.Max(netData.UsedMB ?? 0.0, CampusHistoryManager.Shared.CurrentMonthUsedFlowMB);
            string monthlyUsedStr = (bestMonthlyMB > 0 || netData.UsedMB.HasValue)
                ? $"本月累计已用 {FormatMB(bestMonthlyMB)}"
                : "校园网账户实时余额";

            SetCard(3, "校园网账户余额", balText, monthlyUsedStr, Color.FromRgb(40, 180, 99));
        }
        else if (_currentMode == 1)
        {
            if (!SettingsManager.Shared.IsDormConfigured)
            {
                var gray = Color.FromRgb(142, 142, 147);
                SetCard(0, "当前剩余电费", "未配置", "请先在「设置」中填写楼栋与房间号", gray);
                SetCard(1, "今日消耗电费", "--", "配置宿舍后可查看", gray);
                SetCard(2, "近 7 天日均支出", "--", "配置宿舍后可查看", gray);
                SetCard(3, "预计可用天数", "--", "配置宿舍后可查看", gray);
                return;
            }

            var elec = ElectricityService.Shared.LatestData;
            var fallbackElec = _currentElectricityRecords.FirstOrDefault() ?? CampusHistoryManager.Shared.LatestElectricityRecord;
            double? balRMB = elec?.BalanceRMB ?? fallbackElec?.BalanceRMB;
            double? kwhVal = elec?.RemainingKWh ?? fallbackElec?.RemainingKWh;
            bool isLow = balRMB.HasValue && balRMB.Value < SettingsManager.Shared.ElectricityLowWarningThreshold;
            string balStr = elec?.DisplayBalance ?? (balRMB.HasValue ? $"{balRMB.Value:F2} 元" : "获取中...");
            Color balColor = isLow ? Color.FromRgb(220, 53, 69) : Color.FromRgb(245, 158, 11);
            string powerStr = elec?.DisplayPower ?? (kwhVal.HasValue ? $"剩余 {kwhVal.Value:F1} 度" : "正在查询电量...");
            string warnText = isLow ? "⚠️ 余额偏低，请及时充值" : powerStr;
            SetCard(0, "当前剩余电费", balStr, warnText, balColor);

            double todayCost = CampusHistoryManager.Shared.TodayElectricityCostRMB;
            double todayKWh = CampusHistoryManager.Shared.TodayElectricityUsedKWh;
            SetCard(1, "今日消耗电费", $"{todayCost:F2} 元", $"今日用电约 {todayKWh:F1} 度", Color.FromRgb(155, 89, 182));

            double dailyAvg = CampusHistoryManager.Shared.Past7DaysElectricityDailyAverageCostRMB;
            SetCard(2, "近 7 天日均支出", $"{dailyAvg:F2} 元/天", "基于一周消费模型测算", Color.FromRgb(160, 105, 55));

            int? daysLeft = CampusHistoryManager.Shared.EstimatedElectricityDaysRemaining;
            string daysStr = daysLeft.HasValue ? $"约 {daysLeft.Value} 天" : "测算中...";
            SetCard(3, "预计可用天数", daysStr, "智能预测电费耗尽时间", Color.FromRgb(40, 180, 99));
        }
        else
        {
            var card = CampusCardService.Shared.LatestData;
            if (card == null)
            {
                var gray = Color.FromRgb(142, 142, 147);
                SetCard(0, "校园卡当前余额", "获取中...", "正在向慧新易校查询一卡通", gray);
                SetCard(1, "今日 / 本月消费", "--", "等待同步账单流水", gray);
                SetCard(2, "近 7 天日均消费", "--", "等待同步账单流水", gray);
                SetCard(3, "消费结构占比", "--", "等待同步", gray);
                return;
            }

            bool isLow = card.IsLowBalance;
            Color balColor = isLow ? Color.FromRgb(220, 53, 69) : Color.FromRgb(40, 180, 99);
            double monthRecharged = card.CurrentMonthRechargedRMB();
            string subInfo;
            if (isLow)
                subInfo = $"⚠️ 低于预警阈值 ({SettingsManager.Shared.CampusCardLowWarningThreshold:F0}元)";
            else if (monthRecharged > 0)
                subInfo = $"本月已充值 {monthRecharged:F0} 元 · 状态{card.CardStatusText}";
            else
                subInfo = $"卡号 {card.CardAccount} · 状态{card.CardStatusText}";

            SetCard(0, "校园卡当前余额", card.DisplayBalance, subInfo, balColor);

            double todaySpent = card.TodaySpentRMB();
            int todayCount = card.TodayExpenseCount();
            double monthSpent = card.CurrentMonthSpentRMB();
            int monthCount = card.CurrentMonthExpenseCount();
            SetCard(
                1,
                $"今日消费 ({todayCount}笔)",
                $"{todaySpent:F2} 元",
                $"本月累计 {monthSpent:F2} 元 ({monthCount}笔)",
                Color.FromRgb(245, 158, 11));

            var dailyList = card.DailyExpenseSummary(7);
            int activeDays = Math.Max(1, dailyList.Count(x => x.SpentRMB > 0));
            double weekSum = dailyList.Sum(x => x.SpentRMB);
            double dailyAvg = weekSum / activeDays;
            SetCard(
                2,
                "近 7 日活跃日均",
                $"{dailyAvg:F2} 元/天",
                $"近 7 日共支出 {weekSum:F2} 元",
                Color.FromRgb(88, 86, 214));

            var breakdown = card.ExpenseStructureBreakdown();
            SetCard(
                3,
                "消费场景与三餐占比",
                breakdown.RatioSummaryText,
                breakdown.TopMerchantsText,
                Color.FromRgb(48, 176, 199));
        }
    }

    private void SetCard(int index, string title, string value, string sub, Color color)
    {
        if (index < 0 || index >= 4) return;
        _cardTitleLabels[index].Text = title;
        _cardValueLabels[index].Text = value;
        _cardValueLabels[index].Foreground = new SolidColorBrush(color);
        _cardSubLabels[index].Text = sub;

        int charCount = value?.Length ?? 0;
        double fontSize = charCount <= 10 ? 20 : charCount <= 15 ? 17 : charCount <= 20 ? 14 : 12;
        _cardValueLabels[index].FontSize = fontSize;
    }

    private void UpdateChart()
    {
        if (_currentMode == 0)
        {
            var records = CampusHistoryManager.Shared.GetPastDaysFlowRecords(7);
            var items = records.Select(r =>
            {
                string shortDate = r.DateString.Length >= 5 ? r.DateString[^5..] : r.DateString;
                return new BarChartItem
                {
                    Label = shortDate,
                    Value = Math.Max(0.0, r.DailyDeltaMB),
                    DisplayValue = FormatMB(r.DailyDeltaMB)
                };
            });
            _chartView.SetData(items, Color.FromRgb(0, 122, 255), "MB");
        }
        else if (_currentMode == 1)
        {
            var records = CampusHistoryManager.Shared.GetPastDaysElectricityRecords(7);
            var items = records.Select(r =>
            {
                string shortDate = r.DateString.Length >= 5 ? r.DateString[^5..] : r.DateString;
                return new BarChartItem
                {
                    Label = shortDate,
                    Value = Math.Max(0.0, r.DailyCostRMB),
                    DisplayValue = $"{r.DailyCostRMB:F2}元"
                };
            });
            _chartView.SetData(items, Color.FromRgb(245, 158, 11), "元");
        }
        else
        {
            var dailySummary = CampusCardService.Shared.LatestData?.DailyExpenseSummary(7) ?? new List<(string DateString, double SpentRMB)>();
            var items = dailySummary.Select(d =>
            {
                string shortDate = d.DateString.Length >= 5 ? d.DateString[^5..] : d.DateString;
                return new BarChartItem
                {
                    Label = shortDate,
                    Value = Math.Max(0.0, d.SpentRMB),
                    DisplayValue = $"{d.SpentRMB:F2}元"
                };
            });
            _chartView.SetData(items, Color.FromRgb(48, 176, 199), "元");
        }
    }

    private void PopulateTable()
    {
        _tableView.ItemsSource = null;
        _tableView.Columns.Clear();

        if (_currentMode == 0)
        {
            AddTextColumn("日期", nameof(HistoryTableRow.Col1), 120);
            AddTextColumn("今日新增用量", nameof(HistoryTableRow.Col2), 145);
            AddTextColumn("当月累计已用", nameof(HistoryTableRow.Col3), 145);
            AddTextColumn("月免费剩余 (200G)", nameof(HistoryTableRow.Col4), 145);
            AddTextColumn("校园网余额", nameof(HistoryTableRow.Col5), 130);
            AddTextColumn("更新时间", nameof(HistoryTableRow.Col6), 130);

            var rows = _currentFlowRecords.Select(r =>
            {
                double freeRemMB = Math.Max(0.0, 200.0 * 1024.0 - r.TotalUsedMB);
                return new HistoryTableRow
                {
                    Col1 = r.DateString,
                    Col2 = r.FormattedDailyDelta,
                    Col3 = FormatMB(r.TotalUsedMB),
                    Col4 = FormatMB(freeRemMB),
                    Col5 = r.BalanceRMB.HasValue ? $"{r.BalanceRMB.Value:F2} 元" : "--",
                    Col6 = r.LastUpdated.ToString("HH:mm:ss")
                };
            }).ToList();
            _tableView.ItemsSource = rows;
        }
        else if (_currentMode == 1)
        {
            AddTextColumn("日期", nameof(HistoryTableRow.Col1), 120);
            AddTextColumn("当日消耗电费", nameof(HistoryTableRow.Col2), 145);
            AddTextColumn("当日用电度数", nameof(HistoryTableRow.Col3), 135);
            AddTextColumn("最新剩余电费", nameof(HistoryTableRow.Col4), 145);
            AddTextColumn("剩余度数", nameof(HistoryTableRow.Col5), 130);
            AddTextColumn("更新时间", nameof(HistoryTableRow.Col6), 130);

            var rows = _currentElectricityRecords.Select(r => new HistoryTableRow
            {
                Col1 = r.DateString,
                Col2 = r.FormattedDailyCost,
                Col3 = r.FormattedDailyKWh,
                Col4 = $"{r.BalanceRMB:F2} 元",
                Col5 = r.RemainingKWh.HasValue ? $"{r.RemainingKWh.Value:F1} 度" : "--",
                Col6 = r.LastUpdated.ToString("HH:mm:ss")
            }).ToList();
            _tableView.ItemsSource = rows;
        }
        else
        {
            AddTextColumn("交易时间", nameof(HistoryTableRow.Col1), 160);
            AddTextColumn("消费商户 / 档口名称", nameof(HistoryTableRow.Col2), 265);
            AddStyledColumn("消费场景与餐段", nameof(HistoryTableRow.Col3), nameof(HistoryTableRow.Col3Foreground), null, 130);
            AddStyledColumn("交易金额", nameof(HistoryTableRow.Col4), nameof(HistoryTableRow.Col4Foreground), nameof(HistoryTableRow.Col4FontWeight), 120);
            AddTextColumn("交易后卡余额", nameof(HistoryTableRow.Col5), 130);

            var rows = _currentCardTransactions.Select(tx =>
            {
                string tag = tx.SceneCategoryTag;
                Brush tagBrush;
                if (tag == "圈存充值")
                    tagBrush = new SolidColorBrush(Color.FromRgb(40, 180, 99));
                else if (tag.StartsWith("午餐") || tag.StartsWith("晚餐"))
                    tagBrush = new SolidColorBrush(Color.FromRgb(0, 122, 255));
                else if (tag.StartsWith("早餐"))
                    tagBrush = new SolidColorBrush(Color.FromRgb(48, 176, 199));
                else
                    tagBrush = ThemeManager.Shared.TextSecondary;

                string sign = tx.IsExpense ? "-" : "+";
                Brush amtBrush = tx.IsExpense
                    ? new SolidColorBrush(ThemeManager.Shared.IsDarkTheme
                        ? Color.FromRgb(255, 105, 97)
                        : Color.FromRgb(180, 25, 35))
                    : new SolidColorBrush(Color.FromRgb(40, 180, 99));

                return new HistoryTableRow
                {
                    Col1 = tx.DateTimeString,
                    Col2 = tx.CleanMerchantName,
                    Col3 = tag,
                    Col4 = $"{sign}{tx.AmountRMB:F2} 元",
                    Col5 = tx.BalanceAfterRMB.HasValue ? $"{tx.BalanceAfterRMB.Value:F2} 元" : "--",
                    Col3Foreground = tagBrush,
                    Col4Foreground = amtBrush,
                    Col4FontWeight = FontWeights.SemiBold
                };
            }).ToList();
            _tableView.ItemsSource = rows;
        }
    }

    private void AddTextColumn(string header, string bindingPath, double width)
    {
        var col = new DataGridTextColumn
        {
            Header = header,
            Binding = new System.Windows.Data.Binding(bindingPath),
            Width = new DataGridLength(width)
        };
        _tableView.Columns.Add(col);
    }

    private void AddStyledColumn(string header, string textPath, string foregroundPath, string? weightPath, double width)
    {
        var col = new DataGridTemplateColumn
        {
            Header = header,
            Width = new DataGridLength(width)
        };

        var factory = new FrameworkElementFactory(typeof(TextBlock));
        factory.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding(textPath));
        factory.SetBinding(TextBlock.ForegroundProperty, new System.Windows.Data.Binding(foregroundPath));
        factory.SetValue(TextBlock.VerticalAlignmentProperty, VerticalAlignment.Center);
        factory.SetValue(TextBlock.MarginProperty, new Thickness(6, 0, 6, 0));
        if (!string.IsNullOrEmpty(weightPath))
        {
            factory.SetBinding(TextBlock.FontWeightProperty, new System.Windows.Data.Binding(weightPath));
        }

        col.CellTemplate = new DataTemplate { VisualTree = factory };
        _tableView.Columns.Add(col);
    }

    private static string FormatMB(double mb)
    {
        if (mb >= 1024.0)
            return $"{mb / 1024.0:F2} GB";
        return $"{mb:F0} MB";
    }
}
