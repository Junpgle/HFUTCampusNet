// 全局类型别名消歧义：优先使用 WPF 控件与绘图类型，避免与 WinForms (System.Windows.Forms) 发生 CS0104 命名冲突

global using Brush = System.Windows.Media.Brush;
global using Brushes = System.Windows.Media.Brushes;
global using Color = System.Windows.Media.Color;
global using Pen = System.Windows.Media.Pen;
global using Point = System.Windows.Point;
global using Rect = System.Windows.Rect;
global using FontFamily = System.Windows.Media.FontFamily;

global using Button = System.Windows.Controls.Button;
global using CheckBox = System.Windows.Controls.CheckBox;
global using ComboBox = System.Windows.Controls.ComboBox;
global using ProgressBar = System.Windows.Controls.ProgressBar;
global using TextBox = System.Windows.Controls.TextBox;
global using Label = System.Windows.Controls.Label;
global using Panel = System.Windows.Controls.Panel;
global using Orientation = System.Windows.Controls.Orientation;
global using HorizontalAlignment = System.Windows.HorizontalAlignment;
global using VerticalAlignment = System.Windows.VerticalAlignment;
global using DataGrid = System.Windows.Controls.DataGrid;
global using DataGridColumn = System.Windows.Controls.DataGridColumn;
global using DataGridTextColumn = System.Windows.Controls.DataGridTextColumn;
global using DataGridTemplateColumn = System.Windows.Controls.DataGridTemplateColumn;
global using MenuItem = System.Windows.Controls.MenuItem;
global using ContextMenu = System.Windows.Controls.ContextMenu;
global using ToolTip = System.Windows.Controls.ToolTip;

global using Timer = System.Threading.Timer;
global using Application = System.Windows.Application;
global using MessageBox = System.Windows.MessageBox;

// 历史记录与组件兼容类型别名
global using DailyFlowRecord = HFUTCampusNet.FlowDailyRecord;
global using DailyElectricityRecord = HFUTCampusNet.ElectricityDailyRecord;
global using CourseScheduleItem = HFUTCampusNet.CourseLesson;
global using EmptyClassroomRoomItem = HFUTCampusNet.ClassroomOccupationItem;
global using ClassroomSemesterScheduleData = HFUTCampusNet.CourseScheduleData;
