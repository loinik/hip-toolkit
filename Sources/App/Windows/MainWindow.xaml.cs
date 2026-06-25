using Microsoft.UI.Windowing;
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

    private bool _allowClose = false;

    public MainWindow()
    {
        S.Load(AppContext.BaseDirectory);
        InitializeComponent();
        Title = "HIP Toolkit";
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        _vm = new MainViewModel(Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());
        _vm.RequestAlternateSavePath = PickAlternativeSavePathAsync;
        AppWindow.Closing += OnWindowClosing;

        ResultsList.ItemsSource = _vm.Results;
        _vm.Results.CollectionChanged += (_, _) =>
        {
            ResultsPanel.Visibility = _vm.Results.Count > 0
                ? Visibility.Visible : Visibility.Collapsed;
        };

        CategoryBar.SelectedItem = ItemCIF;
        UpdateUI();
    }

    // ── Category / Direction selection ────────────────────────────────────

    private void CategoryBar_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs e)
    {
        _vm.Category = (string?)sender.SelectedItem?.Tag switch
        {
            "Ciftree" => AppCategory.Ciftree,
            "HIS"     => AppCategory.HIS,
            _         => AppCategory.CIF
        };
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
        _vm.CompileLua = ChkCompileLua.IsChecked == true;
        _vm.UseType4PNG = ChkType4OVL.IsChecked == true;
        _vm.CapitalizeNames = ChkCapitalizeNames.IsChecked == true;
        _vm.ExtractCifContents = ChkExtractContents.IsChecked == true;
        _vm.DecompileLua = ChkDecompileLua.IsChecked == true;
    }

    private void HisFormat_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_vm is null || CmbHisFormat.SelectedItem is not ComboBoxItem item) return;
        _vm.HisOutputFormat = (string?)item.Tag switch {
            "wav" => HisOutputFormat.WAV,
            "mp3" => HisOutputFormat.MP3,
            _     => HisOutputFormat.OGG
        };
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
        // Only fire on left-click, not during drag, and not while processing
        if (!_vm.IsProcessing && e.GetCurrentPoint(null).Properties.IsLeftButtonPressed)
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
            Title = S.Get("alert_support_title"),
            Content = S.Get("alert_support_message"),
            PrimaryButtonText = S.Get("alert_support_kofi"),
            SecondaryButtonText = S.Get("alert_support_instagram"),
            CloseButtonText = S.Get("alert_support_close"),
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
            PreviewWindow.Show(file.Path);
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
                    picker.FileTypeFilter.Add(".wav");
                    picker.FileTypeFilter.Add(".mp3");
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

    // ── Cancel processing ────────────────────────────────────────────────

    private async void CancelConv_Click(object sender, RoutedEventArgs e)
    {
        if (!await ShowProcessingConfirmDialog(
            S.Get("alert_cancel_title"),
            S.Get("alert_cancel_message")))
            return;
        _vm.RequestCancellation();
    }

    private async void OnWindowClosing(Microsoft.UI.Windowing.AppWindow sender,
                                       Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
    {
        if (_allowClose || !_vm.IsProcessing) return;
        args.Cancel = true;
        if (!await ShowProcessingConfirmDialog(
            S.Get("alert_close_title"),
            S.Get("alert_close_message")))
            return;
        _vm.RequestCancellation();
        _allowClose = true;
        Close();
    }

    private async Task<bool> ShowProcessingConfirmDialog(string title, string message)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = message,
            PrimaryButtonText = "Confirm",
            CloseButtonText = "Keep Running",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    // ── Alternate save path picker (called when access is denied) ────────

    private async Task<string?> PickAlternativeSavePathAsync(string defaultPath)
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var ext  = Path.GetExtension(defaultPath).ToLowerInvariant();

        if (ext == ".dat")
        {
            // Pack: save single .dat file
            var picker = new FileSavePicker();
            picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
            picker.SuggestedFileName = Path.GetFileName(defaultPath);
            picker.FileTypeChoices.Add("Ciftree Archive", [".dat"]);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
            var file = await picker.PickSaveFileAsync();
            return file?.Path;
        }
        else
        {
            // Unpack: choose output folder
            var picker = new FolderPicker();
            picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
            var folder = await picker.PickSingleFolderAsync();
            return folder == null ? null
                : Path.Combine(folder.Path, Path.GetFileName(defaultPath));
        }
    }

    // ── Conversion execution ─────────────────────────────────────────────

    private async Task RunConversion(IReadOnlyList<string> paths)
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        DropHint.Visibility = Visibility.Collapsed;
        BusyPanel.Visibility = Visibility.Visible;
        ConvProgressBar.Value = 0;
        ConvProgressLabel.Text = "";
        CategoryBar.IsEnabled = false;
        RadioForward.IsEnabled = false;
        RadioBackward.IsEnabled = false;

        void OnProgress(int cur, int tot)
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                ConvProgressBar.IsIndeterminate = false;
                ConvProgressBar.Value = tot > 0 ? (double)cur / tot * 100.0 : 0;
                ConvProgressLabel.Text = tot > 0 ? $"{cur} of {tot} · {cur * 100 / tot}%" : "";
                TaskbarProgress.Set(hwnd, cur, tot);
            });
        }

        await _vm.ProcessFilesAsync(paths, OnProgress);

        BusyPanel.Visibility = Visibility.Collapsed;
        DropHint.Visibility = Visibility.Visible;
        ConvProgressBar.Value = 0;
        CategoryBar.IsEnabled = true;
        RadioForward.IsEnabled = true;
        RadioBackward.IsEnabled = true;
        TaskbarProgress.Clear(hwnd);
    }

    private void RevealInExplorer_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string path } && !string.IsNullOrEmpty(path))
            System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{path}\"");
    }

    // ── UI state helpers ─────────────────────────────────────────────────

    private void SyncRadioButtons()
    {
        CategoryBar.SelectedItem = _vm.Category switch
        {
            AppCategory.Ciftree => ItemCiftree,
            AppCategory.HIS     => ItemHIS,
            _                   => ItemCIF
        };
        RadioForward.IsChecked  = _vm.Direction == AppDirection.Forward;
        RadioBackward.IsChecked = _vm.Direction == AppDirection.Backward;
    }

    private void UpdateUI()
    {
        var mode = _vm.Mode;

        // Direction labels
        RadioForward.Content = _vm.Category switch
        {
            AppCategory.CIF     => S.Get("dir_file_to_cif"),
            AppCategory.Ciftree => S.Get("dir_pack"),
            AppCategory.HIS     => S.Get("dir_file_to_his"),
            _                   => "▶"
        };
        RadioBackward.Content = _vm.Category switch
        {
            AppCategory.CIF     => S.Get("dir_cif_to_file"),
            AppCategory.Ciftree => S.Get("dir_unpack"),
            AppCategory.HIS     => S.Get("dir_his_to_file"),
            _                   => "◀"
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
        HisFormatPanel.Visibility = mode == AppMode.HisDecode
            ? Visibility.Visible : Visibility.Collapsed;

        // Drop zone hints
        (DropTitle.Text, DropSubtitle.Text, BtnChoose.Content) = mode switch
        {
            AppMode.CifEncode    => (S.Get("drop_title_cif_encode"),     S.Get("drop_subtitle_cif_encode"),     S.Get("choose_files")),
            AppMode.CifDecode    => (S.Get("drop_title_cif_decode"),     S.Get("drop_subtitle_cif_decode"),     S.Get("choose_files")),
            AppMode.CiftreePack  => (S.Get("drop_title_ciftree_pack"),   S.Get("drop_subtitle_ciftree_pack"),   S.Get("choose_folder")),
            AppMode.CiftreeUnpack=> (S.Get("drop_title_ciftree_unpack"), S.Get("drop_subtitle_ciftree_unpack"), S.Get("choose_archive")),
            AppMode.HisEncode    => (S.Get("drop_title_his_encode"),     S.Get("drop_subtitle_his_encode"),     S.Get("choose_files")),
            AppMode.HisDecode    => (S.Get("drop_title_his_decode"),     S.Get("drop_subtitle_his_decode"),     S.Get("choose_files")),
            _                    => ("Drag files here", "", "Choose…")
        };

        DropIcon.Glyph = mode switch
        {
            AppMode.CifEncode => "\uE896",   // Download
            AppMode.CifDecode => "\uE898",   // Upload
            AppMode.CiftreePack => "\uE7B8",   // Package
            AppMode.CiftreeUnpack => "\uE7B8",   // Package
            AppMode.HisEncode => "\uF61F",   // NoiseCancelation
            AppMode.HisDecode => "\uF620",   // NoiseCancelationOff
            _ => "\uE896"
        };
    }
}