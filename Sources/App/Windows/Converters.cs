using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace HIPToolkit;

internal class BoolToVisibilityConverter : IValueConverter
{
    public bool Invert { get; set; }

    public object Convert(object value, Type targetType, object parameter, string language) =>
        ((bool)value ^ Invert) ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotImplementedException();
}
