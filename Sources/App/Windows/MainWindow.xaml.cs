using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace HIPToolkit;

public sealed partial class MainWindow : Window
{
    private readonly MainViewModel _vm;

    public MainWindow()
    {
        InitializeComponent();
        Title = "HIP Toolkit";
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        _vm = new MainViewModel(Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());

        ResultsList.ItemsSource = _vm.Results;
        _vm.Results.CollectionChanged += (_, _) =>
        {
            ResultsPanel.Visibility = _vm.Results.Count > 0
                ? Visibility.Visible : Visibility.Collapsed;
        };

        UpdateUI();
    }

    // ── Category / Direction selection ────────────────────────────────────

    private void Category_Click(object sender, RoutedEventArgs e)
    {
        if (RadioCIF.IsChecked == true)      _vm.Category = AppCategory.CIF;
        else if (RadioCiftree.IsChecked == true) _vm.Category = AppCategory.Ciftree;
        else if (RadioHIS.IsChecked == true)     _vm.Category = AppCategory.HIS;
        UpdateUI();
    }

    private void Direction_Click(object sender, RoutedEventArgs e)
    {
        _vm.Direction = RadioForward.IsChecked == true
            ? AppDirection.Forward : AppDirection.Backward;
        UpdateUI();
    }

    private void Setting_Changed(object sender, RoutedEventArgs e)
    {
        if (_vm is null) return;
        _vm.CompileLua         = ChkCompileLua.IsChecked == true;
        _vm.UseType4PNG        = ChkType4OVL.IsChecked == true;
        _vm.CapitalizeNames    = ChkCapitalizeNames.IsChecked == true;
        _vm.ExtractCifContents = ChkExtractContents.IsChecked == true;
        _vm.DecompileLua       = ChkDecompileLua.IsChecked == true;
    }

    // ── Drop zone ────────────────────────────────────────────────────────

    private void DropZone_DragOver(object sender, DragEventArgs e)
    {
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "Convert";
        e.DragUIOverride.IsCaptionVisible = true;
    }

    private async void DropZone_Drop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        var paths = items.Select(i => i.Path).Where(p => !string.IsNullOrEmpty(p)).ToList();
        if (paths.Count == 0) return;

        _vm.AutoSwitchMode(paths[0]);
        SyncRadioButtons();
        UpdateUI();
        await RunConversion(paths);
    }

    private void DropZone_Click(object sender, PointerRoutedEventArgs e)
    {
        // Only fire on left-click, not during drag
        if (e.GetCurrentPoint(null).Properties.IsLeftButtonPressed)
            _ = PickAndConvert();
    }

    private async void ChooseFiles_Click(object sender, RoutedEventArgs e) => await PickAndConvert();

    private void ClearResults_Click(object sender, RoutedEventArgs e)
    {
        _vm.ClearResults();
        ResultsPanel.Visibility = Visibility.Collapsed;
    }

    // ── Toolbar buttons ──────────────────────────────────────────────────

    private async void Donate_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            Title = "Support Us",
            Content = "HIP Toolkit is built with care for the Nancy Drew community.\n\nIf you enjoy using it, consider supporting our team by donating or following us on Instagram.",
            PrimaryButtonText = "Donate on Ko-Fi",
            SecondaryButtonText = "Follow on Instagram",
            CloseButtonText = "Close",
            XamlRoot = Content.XamlRoot
        };
        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary)
            _ = Windows.System.Launcher.LaunchUriAsync(new Uri("https://ko-fi.com/nancydrewhub"));
        else if (result == ContentDialogResult.Secondary)
            _ = Windows.System.Launcher.LaunchUriAsync(new Uri("https://instagram.com/nancydrewhub"));
    }

    private async void OpenFile_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
        picker.FileTypeFilter.Add(".cif");
        picker.FileTypeFilter.Add(".his");
        picker.FileTypeFilter.Add(".dat");
        picker.FileTypeFilter.Add(".lua");
        picker.FileTypeFilter.Add(".ogg");
        picker.FileTypeFilter.Add(".xsheet");
        picker.FileTypeFilter.Add(".png");
        picker.FileTypeFilter.Add(".jpg");
        picker.FileTypeFilter.Add(".jpeg");

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);

        var file = await picker.PickSingleFileAsync();
        if (file != null)
        {
            // Auto-detect mode and convert
            _vm.AutoSwitchMode(file.Path);
            SyncRadioButtons();
            UpdateUI();
            await RunConversion([file.Path]);
        }
    }

    // ── File picker ──────────────────────────────────────────────────────

    private async Task PickAndConvert()
    {
        var mode = _vm.Mode;

        if (mode == AppMode.CiftreePack)
        {
            var folderPicker = new FolderPicker();
            folderPicker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
            folderPicker.FileTypeFilter.Add("*");

            // Associate the picker with the current window
            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
            WinRT.Interop.InitializeWithWindow.Initialize(folderPicker, hwnd);

            var folder = await folderPicker.PickSingleFolderAsync();
            if (folder != null)
                await RunConversion([folder.Path]);
        }
        else
        {
            var picker = new FileOpenPicker();
            picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;

            switch (mode)
            {
                case AppMode.CifEncode:
                    picker.FileTypeFilter.Add(".png");
                    picker.FileTypeFilter.Add(".jpg");
                    picker.FileTypeFilter.Add(".jpeg");
                    picker.FileTypeFilter.Add(".lua");
                    picker.FileTypeFilter.Add(".xsheet");
                    break;
                case AppMode.CifDecode:
                    picker.FileTypeFilter.Add(".cif");
                    break;
                case AppMode.CiftreeUnpack:
                    picker.FileTypeFilter.Add(".dat");
                    break;
                case AppMode.HisEncode:
                    picker.FileTypeFilter.Add(".ogg");
                    break;
                case AppMode.HisDecode:
                    picker.FileTypeFilter.Add(".his");
                    break;
                default:
                    picker.FileTypeFilter.Add("*");
                    break;
            }

            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);

            bool multi = mode != AppMode.CiftreeUnpack;
            if (multi)
            {
                var files = await picker.PickMultipleFilesAsync();
                if (files.Count > 0)
                    await RunConversion(files.Select(f => f.Path).ToList());
            }
            else
            {
                var file = await picker.PickSingleFileAsync();
                if (file != null)
                    await RunConversion([file.Path]);
            }
        }
    }

    // ── Conversion execution ─────────────────────────────────────────────

    private async Task RunConversion(IReadOnlyList<string> paths)
    {
        BusyRing.IsActive = true;
        BusyRing.Visibility = Visibility.Visible;
        await _vm.ProcessFilesAsync(paths);
        BusyRing.IsActive = false;
        BusyRing.Visibility = Visibility.Collapsed;
    }

    // ── UI state helpers ─────────────────────────────────────────────────

    private void SyncRadioButtons()
    {
        RadioCIF.IsChecked      = _vm.Category == AppCategory.CIF;
        RadioCiftree.IsChecked  = _vm.Category == AppCategory.Ciftree;
        RadioHIS.IsChecked      = _vm.Category == AppCategory.HIS;
        RadioForward.IsChecked  = _vm.Direction == AppDirection.Forward;
        RadioBackward.IsChecked = _vm.Direction == AppDirection.Backward;
    }

    private void UpdateUI()
    {
        var mode = _vm.Mode;

        // Direction labels
        RadioForward.Content = _vm.Category switch
        {
            AppCategory.CIF     => "File → CIF",
            AppCategory.Ciftree => "Pack",
            AppCategory.HIS     => "OGG → HIS",
            _ => "▶"
        };
        RadioBackward.Content = _vm.Category switch
        {
            AppCategory.CIF     => "CIF → File",
            AppCategory.Ciftree => "Unpack",
            AppCategory.HIS     => "HIS → OGG",
            _ => "◀"
        };

        // Settings visibility
        ChkCompileLua.Visibility = mode is AppMode.CifEncode or AppMode.CiftreePack
            ? Visibility.Visible : Visibility.Collapsed;
        ChkType4OVL.Visibility = mode is AppMode.CifEncode or AppMode.CiftreePack
            ? Visibility.Visible : Visibility.Collapsed;
        ChkCapitalizeNames.Visibility = mode == AppMode.CiftreePack
            ? Visibility.Visible : Visibility.Collapsed;
        ChkExtractContents.Visibility = mode == AppMode.CiftreeUnpack
            ? Visibility.Visible : Visibility.Collapsed;
        ChkDecompileLua.Visibility = mode is AppMode.CifDecode or AppMode.CiftreeUnpack
            ? Visibility.Visible : Visibility.Collapsed;

        // Drop zone hints
        (DropTitle.Text, DropSubtitle.Text, BtnChoose.Content) = mode switch
        {
            AppMode.CifEncode     => ("Drag PNG, JPEG, Lua, XSheet or XSheet JSON files",
                                      "PNG/JPEG → CIF image · Lua → CIF script · XSheet / JSON → CIF sprite",
                                      "Choose Files…"),
            AppMode.CifDecode     => ("Drag .cif files",
                                      "CIF → PNG / .lua / .xsheet — saved next to original",
                                      "Choose Files…"),
            AppMode.CiftreePack   => ("Drag a folder",
                                      "All supported files in the folder are converted and packed into .dat",
                                      "Choose Folder…"),
            AppMode.CiftreeUnpack => ("Drag a Ciftree .dat archive",
                                      "Each embedded .cif is extracted to a folder next to the archive",
                                      "Choose Archive…"),
            AppMode.HisEncode     => ("Drag .ogg files",
                                      "OGG Vorbis → HIS (HeR Interactive Sound)",
                                      "Choose Files…"),
            AppMode.HisDecode     => ("Drag .his files",
                                      "HIS → OGG Vorbis — saved next to original",
                                      "Choose Files…"),
            _ => ("Drag files here", "", "Choose…")
        };

        // Drop icon
        DropIcon.Glyph = mode switch
        {
            AppMode.CifEncode     => "\uE896",   // Download
            AppMode.CifDecode     => "\uE898",   // Upload
            AppMode.CiftreePack   => "\uE7B8",   // Package
            AppMode.CiftreeUnpack => "\uE7B8",
            AppMode.HisEncode     => "\uE8D6",   // Volume
            AppMode.HisDecode     => "\uE767",   // Music note
            _ => "\uE896"
        };
    }
}
