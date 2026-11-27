using System.Windows.Input;

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

using Windows.System;

namespace FutoBackups.Controls;

public static class Commit
{
    public static readonly DependencyProperty CommandProperty =
        DependencyProperty.RegisterAttached("Command", typeof(ICommand), typeof(Commit), new PropertyMetadata(null, (target, args) => Attach(target, args, true)));

    public static readonly DependencyProperty EnterCommandProperty =
        DependencyProperty.RegisterAttached("EnterCommand", typeof(ICommand), typeof(Commit), new PropertyMetadata(null, (target, args) => Attach(target, args, false)));

    public static ICommand? GetCommand(DependencyObject target) => (ICommand?)target.GetValue(CommandProperty);

    public static void SetCommand(DependencyObject target, ICommand? value) => target.SetValue(CommandProperty, value);

    public static ICommand? GetEnterCommand(DependencyObject target) => (ICommand?)target.GetValue(EnterCommandProperty);

    public static void SetEnterCommand(DependencyObject target, ICommand? value) => target.SetValue(EnterCommandProperty, value);

    private static void Attach(DependencyObject target, DependencyPropertyChangedEventArgs args, bool onLostFocus)
    {
        if (target is not TextBox box || args.OldValue is not null) return;
        box.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter)
            {
                Run(args.Property == CommandProperty ? GetCommand(box) : GetEnterCommand(box));
            }
        };
        if (onLostFocus)
        {
            box.LostFocus += (_, _) => Run(GetCommand(box));
        }
    }

    private static void Run(ICommand? command)
    {
        if (command is not null && command.CanExecute(null))
        {
            command.Execute(null);
        }
    }
}
