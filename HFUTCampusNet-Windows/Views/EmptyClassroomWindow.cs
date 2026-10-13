using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace HFUTCampusNet;

public sealed class EmptyClassroomWindow : Window
{
    private static EmptyClassroomWindow? _shared;
    public static EmptyClassroomWindow Shared => _shared ??= new EmptyClassroomWindow();

    private readonly ComboBox _campusCombo;
    private readonly ComboBox _buildingCombo;
    private readonly ComboBox _dateCombo;
    private readonly CheckBox _onlyFreeCheck;

    private readonly Border _studyRoomBanner;
    private readonly TextBlock _studyRoomTitle;
    private readonly TextBlock _studyRoomDetail;
    private readonly Button _clearStudyRoomBtn;

    private readonly DataGrid _dataGrid;

    private EmptyClassroomWindow()
    {
        Title = "合肥工业大学 - 自习空教室与时间轴推荐";
        Width = 920;
        Height = 650;
        MinWidth = 800;
        MinHeight = 500;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var root = new Grid { Margin = new Thickness(16) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // Filter Toolbar
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // Banner
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); // Grid

        // Toolbar
        var toolbar = new WrapPanel { Margin = new Thickness(0, 0, 0, 12) };

        _campusCombo = new ComboBox
        {
            Width = 140,
            Height = 30,
            FontSize = 12,
            ItemsSource = new[] { "宣城校区", "合肥翡翠湖校区", "合肥屯溪路校区" },
            SelectedIndex = 0,
            Margin = new Thickness(0, 0, 10, 6)
        };
        _campusCombo.SelectionChanged += (_, _) => ReloadBuildings();
        toolbar.Children.Add(_campusCombo);

        _buildingCombo = new ComboBox
        {
            Width = 140,
            Height = 30,
            FontSize = 12,
            Margin = new Thickness(0, 0, 10, 6)
        };
        _buildingCombo.SelectionChanged += (_, _) => FilterRooms();
        toolbar.Children.Add(_buildingCombo);

        _dateCombo = new ComboBox
        {
            Width = 120,
            Height = 30,
            FontSize = 12,
            ItemsSource = new[] { "今日教室", "明日预备" },
            SelectedIndex = 0,
            Margin = new Thickness(0, 0, 10, 6)
        };
        _dateCombo.SelectionChanged += (_, _) => FilterRooms();
        toolbar.Children.Add(_dateCombo);

        _onlyFreeCheck = new CheckBox
        {
            Content = "仅看全天空闲",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(6, 0, 16, 6)
        };
        _onlyFreeCheck.Checked += (_, _) => FilterRooms();
        _onlyFreeCheck.Unchecked += (_, _) => FilterRooms();
        toolbar.Children.Add(_onlyFreeCheck);

        var refreshBtn = new Button
        {
            Content = "刷新空教室",
            Padding = new Thickness(12, 5, 12, 5),
            FontSize = 12,
            Margin = new Thickness(0, 0, 0, 6)
        };
        refreshBtn.Click += (_, _) =>
        {
            EmptyClassroomService.Shared.SyncTodayAndTomorrowStudyRooms(forceRefresh: true, _ => AppEvents.InvokeOnUI(FilterRooms));
        };
        toolbar.Children.Add(refreshBtn);

        Grid.SetRow(toolbar, 0);
        root.Children.Add(toolbar);

        // Banner Card
        _studyRoomBanner = new Border
        {
            Background = (Brush)new BrushConverter().ConvertFromString("#18181B")!,
            BorderBrush = (Brush)new BrushConverter().ConvertFromString("#27272A")!,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(14, 10, 14, 10),
            Margin = new Thickness(0, 0, 0, 12)
        };
        var bannerGrid = new Grid();
        bannerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bannerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var bannerTextStack = new StackPanel();
        _studyRoomTitle = new TextBlock { Text = "当前自习室：未设置", FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Brushes.DodgerBlue };
        _studyRoomDetail = new TextBlock { Text = "在下方教室列表中点击右侧「设为自习室」，可在小组件和托盘接收冲突提醒与课前换座推荐", FontSize = 11, Foreground = Brushes.Gray, Margin = new Thickness(0, 3, 0, 0) };
        bannerTextStack.Children.Add(_studyRoomTitle);
        bannerTextStack.Children.Add(_studyRoomDetail);
        Grid.SetColumn(bannerTextStack, 0);
        bannerGrid.Children.Add(bannerTextStack);

        _clearStudyRoomBtn = new Button { Content = "清除设置", Padding = new Thickness(10, 4, 10, 4), FontSize = 11, Visibility = Visibility.Collapsed };
        _clearStudyRoomBtn.Click += (_, _) =>
        {
            EmptyClassroomService.Shared.ClearCurrentStudyRoom();
            UpdateBanner();
        };
        Grid.SetColumn(_clearStudyRoomBtn, 1);
        bannerGrid.Children.Add(_clearStudyRoomBtn);

        _studyRoomBanner.Child = bannerGrid;
        Grid.SetRow(_studyRoomBanner, 1);
        root.Children.Add(_studyRoomBanner);

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

        _dataGrid.Columns.Add(new DataGridTextColumn { Header = "教室名称", Binding = new System.Windows.Data.Binding("RoomName"), Width = 150 });
        _dataGrid.Columns.Add(new DataGridTextColumn { Header = "教学楼", Binding = new System.Windows.Data.Binding("BuildingName"), Width = 110 });
        _dataGrid.Columns.Add(new DataGridTextColumn { Header = "座位容量", Binding = new System.Windows.Data.Binding("Seats"), Width = 80 });
        _dataGrid.Columns.Add(new DataGridTextColumn { Header = "全天空闲状态", Binding = new System.Windows.Data.Binding("IsAllDayFree") { Converter = new AllDayFreeConverter() }, Width = 120 });
        _dataGrid.Columns.Add(new DataGridTextColumn { Header = "日期", Binding = new System.Windows.Data.Binding("DateString"), Width = 110 });

        // Action Column
        var actionCol = new DataGridTemplateColumn { Header = "操作", Width = new DataGridLength(1, DataGridLengthUnitType.Star) };
        var factory = new FrameworkElementFactory(typeof(Button));
        factory.SetValue(Button.ContentProperty, "设为今日自习室");
        factory.SetValue(Button.PaddingProperty, new Thickness(8, 2, 8, 2));
        factory.SetValue(Button.FontSizeProperty, 11.0);
        factory.AddHandler(Button.ClickEvent, new RoutedEventHandler(OnSetRoomClick));
        actionCol.CellTemplate = new DataTemplate { VisualTree = factory };
        _dataGrid.Columns.Add(actionCol);

        Grid.SetRow(_dataGrid, 2);
        root.Children.Add(_dataGrid);

        Content = root;

        AppEvents.EmptyClassroomUpdated += () => AppEvents.InvokeOnUI(() =>
        {
            UpdateBanner();
            FilterRooms();
        });

        ReloadBuildings();
    }

    public void ShowWindowAndSync(bool selectTomorrow = false)
    {
        _dateCombo.SelectedIndex = selectTomorrow ? 1 : 0;
        Show();
        Activate();
        UpdateBanner();
        FilterRooms();
    }

    private void ReloadBuildings()
    {
        int campusId = _campusCombo.SelectedIndex switch
        {
            1 => 3, // 翡翠湖
            2 => 2, // 屯溪路
            _ => 6  // 宣城
        };
        var buildings = EmptyClassroomService.DefaultBuildings.Where(b => b.CampusId == campusId).Select(b => b.BuildingName).ToList();
        buildings.Insert(0, "全部教学楼");
        _buildingCombo.ItemsSource = buildings;
        _buildingCombo.SelectedIndex = 0;
    }

    private void UpdateBanner()
    {
        var record = EmptyClassroomService.Shared.CurrentStudyRoomItem();
        if (record != null)
        {
            _studyRoomTitle.Text = $"当前自习室：{record.RoomName}";
            _studyRoomDetail.Text = $"已锁定 {record.BuildingName}，将在小组件中常驻显示空闲状态并在上课冲突前预警";
            _clearStudyRoomBtn.Visibility = Visibility.Visible;
        }
        else
        {
            _studyRoomTitle.Text = "当前自习室：未设置";
            _studyRoomDetail.Text = "在下方教室列表中点击右侧「设为自习室」，可在小组件和托盘接收冲突提醒与换座推荐";
            _clearStudyRoomBtn.Visibility = Visibility.Collapsed;
        }
    }

    private void FilterRooms()
    {
        var targetDate = _dateCombo.SelectedIndex == 1
            ? EmptyClassroomService.TomorrowDateString()
            : EmptyClassroomService.TodayDateString();

        var selectedBuilding = _buildingCombo.SelectedItem as string;

        var rooms = EmptyClassroomService.Shared.CachedRooms
            .Where(r => r.DateString == targetDate);

        if (!string.IsNullOrEmpty(selectedBuilding) && selectedBuilding != "全部教学楼")
        {
            rooms = rooms.Where(r => r.BuildingName == selectedBuilding);
        }

        if (_onlyFreeCheck.IsChecked == true)
        {
            rooms = rooms.Where(r => r.IsAllDayFree);
        }

        _dataGrid.ItemsSource = rooms.ToList();
    }

    private void OnSetRoomClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.DataContext is ClassroomOccupationItem room)
        {
            EmptyClassroomService.Shared.SetCurrentStudyRoom(room);
            UpdateBanner();
            MessageBox.Show($"已将【{room.RoomName}】设为自习室！小组件与托盘将自动同步。", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
        }
    }

    private sealed class AllDayFreeConverter : System.Windows.Data.IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        {
            return (value is bool b && b) ? "✅ 全天空闲" : "⚠️ 有排课/考试";
        }
        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotImplementedException();
    }
}
