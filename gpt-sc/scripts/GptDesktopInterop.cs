// Windows desktop shortcut notification and bounded activation verification.
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public static class GptDesktopInterop
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern void SHChangeNotify(uint events, uint flags, string first, IntPtr second);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] input, int size);

    [StructLayout(LayoutKind.Sequential)] private struct INPUT { public uint type; public INPUTUNION data; }
    [StructLayout(LayoutKind.Explicit)] private struct INPUTUNION
    {
        [FieldOffset(0)] public KEYBDINPUT keyboard;
        [FieldOffset(0)] public MOUSEINPUT mouse;
    }
    [StructLayout(LayoutKind.Sequential)] private struct KEYBDINPUT
    { public ushort key, scan; public uint flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] private struct MOUSEINPUT
    { public int x, y; public uint data, flags, time; public UIntPtr extra; }

    public static void Notify(string path, bool created)
    {
        // SHCNE_CREATE / SHCNE_UPDATEITEM, SHCNF_PATHW | SHCNF_FLUSH.
        SHChangeNotify(created ? 0x2u : 0x2000u, 0x1005, path, IntPtr.Zero);
    }

    public static void NotifyRestored(string path)
    {
        SHChangeNotify(System.IO.File.Exists(path) ? 0x2000u : 0x4u, 0x1005, path, IntPtr.Zero);
    }

    public static ushort[] ParseHotkey(string hotkey)
    {
        string[] parts = hotkey.Replace(" ", "").ToUpperInvariant().Split('+');
        bool control = false, alt = false, shift = false;
        ushort key = 0;
        foreach (string part in parts)
        {
            if (part == "CTRL" || part == "CONTROL") { control = true; continue; }
            if (part == "ALT") { alt = true; continue; }
            if (part == "SHIFT") { shift = true; continue; }
            if (key != 0) throw new ArgumentException("Only one non-modifier desktop key is supported.");
            int number;
            if (part.Length == 1 && ((part[0] >= 'A' && part[0] <= 'Z') || (part[0] >= '0' && part[0] <= '9')))
                key = (ushort)part[0];
            else if (part.StartsWith("F") && Int32.TryParse(part.Substring(1), out number) && number >= 1 && number <= 24 && number != 12)
                key = (ushort)(0x70 + number - 1);
            else throw new ArgumentException("Unsupported desktop key. Use letters, digits or F1-F24 (except reserved F12).");
        }
        if (key == 0) throw new ArgumentException("A desktop hotkey needs a non-modifier key.");
        var keys = new System.Collections.Generic.List<ushort>();
        if (control) keys.Add(0x11);
        if (alt) keys.Add(0x12);
        if (shift) keys.Add(0x10);
        keys.Add(key);
        return keys.ToArray();
    }

    private static INPUT Input(ushort key, bool release)
    {
        return new INPUT { type = 1, data = new INPUTUNION {
            keyboard = new KEYBDINPUT { key = key, flags = release ? 2u : 0u } } };
    }

    private static bool ModifierDown()
    {
        foreach (int key in new int[] { 0x10, 0x11, 0x12, 0x5B, 0x5C })
            if ((GetAsyncKeyState(key) & 0x8000) != 0) return true;
        return false;
    }

    public static string CheckActivation(string appPath, string hotkey, int timeoutMilliseconds)
    {
        ushort[] keys = ParseHotkey(hotkey);
        // A separate neutral window prevents an already foreground GPT from passing.
        using (Form probe = new Form())
        {
            probe.Text = "GPT-SC shortcut check";
            probe.Width = 360; probe.Height = 100;
            probe.StartPosition = FormStartPosition.CenterScreen;
            probe.Controls.Add(new Label { Text = "Checking the desktop shortcut...", Dock = DockStyle.Fill });
            probe.Show(); probe.Activate();
            var watch = Stopwatch.StartNew();
            while (GetForegroundWindow() != probe.Handle && watch.ElapsedMilliseconds < 1500)
            { Application.DoEvents(); Thread.Sleep(50); }
            if (GetForegroundWindow() != probe.Handle) return "Inconclusive: cannot focus the verification window.";
            watch.Restart();
            while (ModifierDown() && watch.ElapsedMilliseconds < 2000)
            { Application.DoEvents(); Thread.Sleep(50); }
            if (ModifierDown()) return "Inconclusive: release held modifier keys before retrying.";
            if (GetForegroundWindow() != probe.Handle) return "Inconclusive: foreground changed before the hotkey test.";

            var inputs = new INPUT[keys.Length * 2];
            for (int i = 0; i < keys.Length; i++)
            {
                inputs[i] = Input(keys[i], false);
                inputs[keys.Length + i] = Input(keys[keys.Length - 1 - i], true);
            }
            if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT))) != inputs.Length)
            {
                var release = new INPUT[keys.Length];
                for (int i = 0; i < keys.Length; i++) release[i] = Input(keys[keys.Length - 1 - i], true);
                SendInput((uint)release.Length, release, Marshal.SizeOf(typeof(INPUT)));
                return "Inconclusive: Windows did not accept all input events (possibly integrity restrictions).";
            }
            watch.Restart();
            while (watch.ElapsedMilliseconds < timeoutMilliseconds)
            {
                Application.DoEvents();
                IntPtr window = GetForegroundWindow();
                if (window != IntPtr.Zero && window != probe.Handle && IsWindowVisible(window) && !IsIconic(window))
                {
                    uint id;
                    GetWindowThreadProcessId(window, out id);
                    try
                    {
                        using (Process process = Process.GetProcessById((int)id))
                            if (String.Equals(process.MainModule.FileName, appPath, StringComparison.OrdinalIgnoreCase))
                                return "Verified";
                    }
                    catch (System.ComponentModel.Win32Exception) { }
                    catch (InvalidOperationException) { }
                    catch (ArgumentException) { }
                }
                Thread.Sleep(100);
            }
            return "Failed: no visible foreground GPT window was observed after the hotkey.";
        }
    }
}
