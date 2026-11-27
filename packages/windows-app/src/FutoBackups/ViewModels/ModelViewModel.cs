using System.Collections;
using System.ComponentModel;
using System.Reflection;
using System.Windows.Input;

using CommunityToolkit.Mvvm.ComponentModel;

using FutoBackups.Core.Models;

namespace FutoBackups.ViewModels;

public abstract class ModelViewModel : ObservableObject, IDisposable
{
    private readonly List<INotifyPropertyChanged> sources = [];
    private readonly PropertyInfo[] derived;
    private readonly Dictionary<string, object?> shown = [];

    protected ModelViewModel(AppModel model)
    {
        Model = model;
        derived = GetType()
            .GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Where(property => property.CanRead && property.GetIndexParameters().Length == 0 && property.DeclaringType != typeof(ModelViewModel) && !typeof(ICommand).IsAssignableFrom(property.PropertyType))
            .ToArray();
        Watch(model);
    }

    public AppModel Model { get; }

    public void Dispose()
    {
        foreach (var source in sources)
        {
            source.PropertyChanged -= SourceChanged;
        }

        sources.Clear();
        GC.SuppressFinalize(this);
    }

    protected void Watch(INotifyPropertyChanged source)
    {
        sources.Add(source);
        source.PropertyChanged += SourceChanged;
    }

    private void SourceChanged(object? sender, PropertyChangedEventArgs args) => NotifyChanges();

    protected void NotifyChanges()
    {
        OnModelChanged();
        foreach (var property in derived)
        {
            var value = property.GetValue(this);
            if (shown.TryGetValue(property.Name, out var previous) && Same(previous, value)) continue;
            shown[property.Name] = value is IEnumerable sequence and not string ? sequence.Cast<object?>().ToList() : value;
            OnPropertyChanged(property.Name);
        }
    }

    protected virtual void OnModelChanged()
    {
    }

    private static bool Same(object? previous, object? value) =>
        value is IEnumerable sequence and not string && previous is IEnumerable<object?> earlier
            ? earlier.SequenceEqual(sequence.Cast<object?>())
            : Equals(previous, value);
}
