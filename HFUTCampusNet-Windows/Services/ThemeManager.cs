using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace HFUTCampusNet;

/// <summary>
/// 全局深浅色主题管理器与 Win32 DWM 沉浸式暗色标题栏服务。
/// 动态监听 Windows 10/11 系统模式变更，并为所有 WPF 窗口提供统一的深浅色配色规范。
/// </summary>
public sealed class ThemeManager
{
    public static ThemeManager Shared { get; } = new ThemeManager();
    private static readonly Lazy<ImageSource> SharedWindowIcon = new(LoadApplicationIcon);

    private const string ControlBackgroundResourceKey = "HFUT.ControlBackground";
    private const string ControlHoverResourceKey = "HFUT.ControlHover";
    private const string ControlBorderResourceKey = "HFUT.ControlBorderBrush";
    private const string WindowBackgroundResourceKey = "HFUT.WindowBackground";
    private const string TableBackgroundResourceKey = "HFUT.TableBackground";
    private const string TableHeaderBackgroundResourceKey = "HFUT.TableHeaderBackground";
    private const string TableAlternatingBackgroundResourceKey = "HFUT.TableAlternatingBackground";
    private const string TableGridLineBrushResourceKey = "HFUT.TableGridLineBrush";
    private const string TableSelectionBackgroundResourceKey = "HFUT.TableSelectionBackground";
    private const string TextPrimaryResourceKey = "HFUT.TextPrimary";
    private const string TextSecondaryResourceKey = "HFUT.TextSecondary";
    private const string TextMutedResourceKey = "HFUT.TextMuted";
    private const string AccentResourceKey = "HFUT.Accent";
    private const string OnAccentResourceKey = "HFUT.OnAccent";
    private const string ScrollBarThumbResourceKey = "HFUT.ScrollBarThumb";
    private const string ScrollBarThumbHoverResourceKey = "HFUT.ScrollBarThumbHover";
    private const string ButtonHoverOverlayResourceKey = "HFUT.ButtonHoverOverlay";
    private const string ButtonPressedOverlayResourceKey = "HFUT.ButtonPressedOverlay";
    private bool _applicationControlStylesLoaded;

    [DllImport("dwmapi.dll", PreserveSig = true)]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    private const int DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 = 19;
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

    public bool IsDarkTheme { get; private set; } = true;
    public event Action? ThemeChanged;

    private ThemeManager()
    {
        RefreshTheme();
        try
        {
            SystemEvents.UserPreferenceChanged += (_, _) =>
            {
                Application.Current?.Dispatcher.BeginInvoke(new Action(() =>
                {
                    bool old = IsDarkTheme;
                    RefreshTheme();
                    if (old != IsDarkTheme)
                    {
                        ThemeChanged?.Invoke();
                    }
                }));
            };
        }
        catch { }
    }

    public void RefreshTheme()
    {
        var isDarkTheme = true;
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            if (key?.GetValue("AppsUseLightTheme") is int lightVal)
            {
                isDarkTheme = lightVal == 0;
            }
        }
        catch { }

        IsDarkTheme = isDarkTheme;
        UpdateApplicationThemeResources();
    }

    /// <summary>
    /// Installs shared WPF control styles and theme resources before any window is shown.
    /// </summary>
    public void InitializeApplicationControlStyles()
    {
        UpdateApplicationThemeResources();

        var app = Application.Current;
        if (app == null || _applicationControlStylesLoaded) return;

        var styles = new ResourceDictionary
        {
            Source = new Uri("/HFUTCampusNet;component/Themes/ControlStyles.xaml", UriKind.Relative)
        };
        app.Resources.MergedDictionaries.Add(styles);
        _applicationControlStylesLoaded = true;
    }

    /// <summary>
    /// 为指定窗口应用 Win32 DWM 沉浸式深色或浅色标题栏
    /// </summary>
    public void ApplyWindowTheme(Window window)
    {
        if (window == null) return;
        InitializeApplicationControlStyles();
        ApplyWindowIcon(window);

        void ApplyCore()
        {
            var hwnd = new WindowInteropHelper(window).Handle;
            if (hwnd == IntPtr.Zero) return;

            int isDark = IsDarkTheme ? 1 : 0;
            // 优先尝试 Win11/Win10 20H1+ 的标准属性 20
            int hr = DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref isDark, sizeof(int));
            if (hr != 0)
            {
                // 回退到早期 Win10 的属性 19
                DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1, ref isDark, sizeof(int));
            }
        }

        if (window.IsLoaded)
        {
            ApplyCore();
        }
        else
        {
            window.SourceInitialized += (_, _) => ApplyCore();
        }
    }

    /// <summary>
    /// 为无主题入口的窗口（例如桌面小组件）设置统一的应用图标。
    /// </summary>
    public void ApplyWindowIcon(Window window)
    {
        if (window == null) return;
        window.Icon ??= SharedWindowIcon.Value;
    }

    public void ApplyDataGridTheme(DataGrid dataGrid)
    {
        if (dataGrid == null) return;

        InitializeApplicationControlStyles();
        dataGrid.SetResourceReference(DataGrid.ColumnHeaderStyleProperty, "HFUT.DataGridColumnHeaderStyle");
        dataGrid.SetResourceReference(DataGrid.CellStyleProperty, "HFUT.DataGridCellStyle");
        dataGrid.SetResourceReference(DataGrid.RowStyleProperty, "HFUT.DataGridRowStyle");
    }

    private static ImageSource LoadApplicationIcon()
    {
        var uri = new Uri("pack://application:,,,/HFUTCampusNet;component/Assets/HFUTCampusNet.ico", UriKind.Absolute);
        var decoder = BitmapDecoder.Create(uri, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        var frame = decoder.Frames.FirstOrDefault(candidate => candidate.PixelWidth >= 32) ?? decoder.Frames[0];
        if (frame.CanFreeze) frame.Freeze();
        return frame;
    }

    // --- 统一的主题颜色与画刷 ---

    public Brush WindowBackground => IsDarkTheme
        ? new SolidColorBrush(Color.FromRgb(24, 26, 32))
        : new SolidColorBrush(Color.FromRgb(245, 245, 247));

    public Brush TopBarBackground => IsDarkTheme
        ? new SolidColorBrush(Color.FromArgb(200, 32, 35, 45))
        : new SolidColorBrush(Color.FromRgb(250, 250, 252));

    public Brush CardBackground => IsDarkTheme
        ? new SolidColorBrush(Color.FromArgb(240, 34, 37, 48))
        : new SolidColorBrush(Color.FromRgb(250, 250, 251));

    public Brush CardBorderBrush => IsDarkTheme
        ? new SolidColorBrush(Color.FromArgb(50, 255, 255, 255))
        : new SolidColorBrush(Color.FromArgb(26, 0, 0, 0));

    public Brush TextPrimary => IsDarkTheme
        ? new SolidColorBrush(Color.FromRgb(240, 243, 250))
        : new SolidColorBrush(Color.FromRgb(29, 29, 31));

    public Brush TextSecondary => IsDarkTheme
        ? new SolidColorBrush(Color.FromRgb(165, 172, 190))
        : new SolidColorBrush(Color.FromRgb(110, 110, 115));

    public Brush TextMuted => IsDarkTheme
        ? new SolidColorBrush(Color.FromRgb(120, 128, 145))
        : new SolidColorBrush(Color.FromRgb(142, 142, 147));

    public Brush ControlBackground => IsDarkTheme
        ? new SolidColorBrush(Color.FromArgb(220, 36, 40, 52))
        : new SolidColorBrush(Color.FromRgb(235, 235, 237));

    public Brush ControlHoverBackground => IsDarkTheme
        ? new SolidColorBrush(Color.FromRgb(50, 55, 69))
        : new SolidColorBrush(Color.FromRgb(222, 224, 229));

    public Brush ControlBorderBrush => IsDarkTheme
        ? new SolidColorBrush(Color.FromArgb(60, 255, 255, 255))
        : new SolidColorBrush(Color.FromArgb(40, 0, 0, 0));

    public Brush Accent => new SolidColorBrush(Color.FromRgb(10, 132, 255));

    public Brush Danger => new SolidColorBrush(Color.FromRgb(255, 59, 48));

    public Brush Success => new SolidColorBrush(Color.FromRgb(52, 199, 89));

    public Brush TableBackground => IsDarkTheme
        ? new SolidColorBrush(Color.FromRgb(28, 30, 38))
        : new SolidColorBrush(Color.FromRgb(255, 255, 255));

    public Brush TableHeaderBackground => IsDarkTheme
        ? new SolidColorBrush(Color.FromRgb(36, 40, 52))
        : new SolidColorBrush(Color.FromRgb(245, 248, 252));

    public Brush TableAlternatingBackground => IsDarkTheme
        ? new SolidColorBrush(Color.FromRgb(32, 35, 45))
        : new SolidColorBrush(Color.FromRgb(248, 250, 252));

    public Brush TableGridLineBrush => IsDarkTheme
        ? new SolidColorBrush(Color.FromArgb(35, 255, 255, 255))
        : new SolidColorBrush(Color.FromArgb(25, 0, 0, 0));

    private void UpdateApplicationThemeResources()
    {
        var resources = Application.Current?.Resources;
        if (resources == null) return;

        resources[ControlBackgroundResourceKey] = ControlBackground;
        resources[ControlHoverResourceKey] = ControlHoverBackground;
        resources[ControlBorderResourceKey] = ControlBorderBrush;
        resources[WindowBackgroundResourceKey] = WindowBackground;
        resources[TableBackgroundResourceKey] = TableBackground;
        resources[TableHeaderBackgroundResourceKey] = TableHeaderBackground;
        resources[TableAlternatingBackgroundResourceKey] = TableAlternatingBackground;
        resources[TableGridLineBrushResourceKey] = TableGridLineBrush;
        resources[TableSelectionBackgroundResourceKey] = new SolidColorBrush(IsDarkTheme
            ? Color.FromArgb(72, 10, 132, 255)
            : Color.FromArgb(38, 10, 132, 255));
        resources[TextPrimaryResourceKey] = TextPrimary;
        resources[TextSecondaryResourceKey] = TextSecondary;
        resources[TextMutedResourceKey] = TextMuted;
        resources[AccentResourceKey] = Accent;
        resources[OnAccentResourceKey] = Brushes.White;
        resources[ScrollBarThumbResourceKey] = new SolidColorBrush(IsDarkTheme
            ? Color.FromRgb(91, 99, 116)
            : Color.FromRgb(156, 156, 162));
        resources[ScrollBarThumbHoverResourceKey] = new SolidColorBrush(IsDarkTheme
            ? Color.FromRgb(133, 144, 166)
            : Color.FromRgb(111, 111, 118));
        resources[ButtonHoverOverlayResourceKey] = new SolidColorBrush(IsDarkTheme
            ? Color.FromArgb(22, 255, 255, 255)
            : Color.FromArgb(14, 0, 0, 0));
        resources[ButtonPressedOverlayResourceKey] = new SolidColorBrush(IsDarkTheme
            ? Color.FromArgb(48, 255, 255, 255)
            : Color.FromArgb(36, 0, 0, 0));

        // ComboBox popups are detached from their owner window's resource scope.
        // Keep WPF's system brush keys in the application dictionary for both sources.
        resources[System.Windows.SystemColors.WindowBrushKey] = ControlBackground;
        resources[System.Windows.SystemColors.WindowTextBrushKey] = TextPrimary;
        resources[System.Windows.SystemColors.ControlBrushKey] = ControlBackground;
        resources[System.Windows.SystemColors.ControlLightBrushKey] = ControlBackground;
        resources[System.Windows.SystemColors.ControlLightLightBrushKey] = ControlBackground;
        resources[System.Windows.SystemColors.ControlDarkBrushKey] = ControlBorderBrush;
        resources[System.Windows.SystemColors.ControlDarkDarkBrushKey] = ControlBorderBrush;
        resources[System.Windows.SystemColors.ControlTextBrushKey] = TextPrimary;
        resources[System.Windows.SystemColors.GrayTextBrushKey] = TextMuted;
        resources[System.Windows.SystemColors.ScrollBarBrushKey] = ControlBackground;
        resources[System.Windows.SystemColors.HighlightBrushKey] = Accent;
        resources[System.Windows.SystemColors.HighlightTextBrushKey] = Brushes.White;
    }

    /// <summary>
    /// Keeps both the closed ComboBox and its detached dropdown popup readable in the active theme.
    /// </summary>
    public void ApplyComboBoxTheme(ComboBox comboBox)
    {
        if (comboBox == null) return;

        InitializeApplicationControlStyles();

        var background = ControlBackground;
        var foreground = TextPrimary;
        var accent = Accent;

        comboBox.Background = background;
        comboBox.Foreground = foreground;
        comboBox.BorderBrush = ControlBorderBrush;
        comboBox.Resources[System.Windows.SystemColors.WindowBrushKey] = background;
        comboBox.Resources[System.Windows.SystemColors.WindowTextBrushKey] = foreground;
        comboBox.Resources[System.Windows.SystemColors.ControlBrushKey] = background;
        comboBox.Resources[System.Windows.SystemColors.ControlTextBrushKey] = foreground;
        comboBox.Resources[System.Windows.SystemColors.HighlightBrushKey] = accent;
        comboBox.Resources[System.Windows.SystemColors.HighlightTextBrushKey] = Brushes.White;

        if (Application.Current?.TryFindResource(typeof(ComboBox)) is Style comboStyle)
        {
            comboBox.Style = comboStyle;
        }

        if (Application.Current?.TryFindResource(typeof(ComboBoxItem)) is Style itemStyle)
        {
            comboBox.ItemContainerStyle = itemStyle;
            foreach (var item in comboBox.Items.OfType<ComboBoxItem>())
            {
                item.Style ??= itemStyle;
            }
        }
    }
}
