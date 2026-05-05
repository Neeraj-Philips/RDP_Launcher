// ============================================
// RDP UI Automation Helper
// ============================================
// .NET UI Automation wrapper for mstsc dialogs.
// Used by rdp-gui.ps1 and rdp-auto.ps1 to:
//   - Dismiss security/certificate warnings
//   - Detect connected RDP sessions
//   - Fill credential prompts
//
// Compiled at runtime via Add-Type in PowerShell.
// Requires: UIAutomationClient, UIAutomationTypes
// ============================================

using System;
using System.Windows.Automation;
using System.Threading;
using System.Collections.Generic;

public class RdpUIAutomation
{
    // ===== WINDOW SEARCH =====

    /// <summary>Find the first top-level window owned by a process.</summary>
    public static AutomationElement FindWindowByPid(int pid, int timeoutMs)
    {
        var root = AutomationElement.RootElement;
        var deadline = DateTime.Now.AddMilliseconds(timeoutMs);
        while (DateTime.Now < deadline)
        {
            try
            {
                var cond = new PropertyCondition(AutomationElement.ProcessIdProperty, pid);
                var win = root.FindFirst(TreeScope.Children, cond);
                if (win != null) return win;
            }
            catch { }
            Thread.Sleep(500);
        }
        return null;
    }

    /// <summary>Wait for a window by PID that contains Edit controls (credential prompts).</summary>
    public static AutomationElement WaitForWindowWithEditsByPid(int pid, int timeoutMs)
    {
        var root = AutomationElement.RootElement;
        var editCond = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit);
        var pidCond = new PropertyCondition(AutomationElement.ProcessIdProperty, pid);
        var deadline = DateTime.Now.AddMilliseconds(timeoutMs);
        while (DateTime.Now < deadline)
        {
            try
            {
                var wins = root.FindAll(TreeScope.Children, pidCond);
                foreach (AutomationElement w in wins)
                {
                    try
                    {
                        var edits = w.FindAll(TreeScope.Descendants, editCond);
                        if (edits.Count > 0) return w;
                    }
                    catch { }
                }
            }
            catch { }
            Thread.Sleep(500);
        }
        return null;
    }

    /// <summary>Wait for a window by PID whose title contains one of the given strings.</summary>
    public static AutomationElement WaitForWindowTitleByPid(int pid, string[] titleContains, int timeoutMs)
    {
        var root = AutomationElement.RootElement;
        var pidCond = new PropertyCondition(AutomationElement.ProcessIdProperty, pid);
        var deadline = DateTime.Now.AddMilliseconds(timeoutMs);
        while (DateTime.Now < deadline)
        {
            try
            {
                var wins = root.FindAll(TreeScope.Children, pidCond);
                foreach (AutomationElement w in wins)
                {
                    try
                    {
                        string name = w.Current.Name;
                        if (string.IsNullOrEmpty(name)) continue;
                        foreach (string t in titleContains)
                        {
                            if (name.IndexOf(t, StringComparison.OrdinalIgnoreCase) >= 0)
                                return w;
                        }
                    }
                    catch { }
                }
            }
            catch { }
            Thread.Sleep(500);
        }
        return null;
    }

    // ===== DIAGNOSTICS =====

    /// <summary>List all windows for a specific PID.</summary>
    public static List<string> ListWindowsByPid(int pid)
    {
        var result = new List<string>();
        var root = AutomationElement.RootElement;
        try
        {
            var pidCond = new PropertyCondition(AutomationElement.ProcessIdProperty, pid);
            var wins = root.FindAll(TreeScope.Children, pidCond);
            foreach (AutomationElement w in wins)
            {
                try { result.Add("Title='" + w.Current.Name + "' Class='" + w.Current.ClassName + "'"); }
                catch { }
            }
        }
        catch { }
        return result;
    }

    /// <summary>Dump all descendant controls of a window (for diagnostics).</summary>
    public static List<string> DumpControls(AutomationElement parent)
    {
        var info = new List<string>();
        try
        {
            var all = parent.FindAll(TreeScope.Descendants, Condition.TrueCondition);
            foreach (AutomationElement el in all)
            {
                try
                {
                    info.Add(el.Current.ControlType.ProgrammaticName +
                             " | Name='" + el.Current.Name +
                             "' | Id='" + el.Current.AutomationId + "'");
                }
                catch { }
            }
        }
        catch { }
        return info;
    }

    // ===== BUTTON INTERACTION =====

    /// <summary>Get all button names in a window.</summary>
    public static List<string> GetButtonNames(AutomationElement parent)
    {
        var names = new List<string>();
        try
        {
            var cond = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button);
            var buttons = parent.FindAll(TreeScope.Descendants, cond);
            foreach (AutomationElement btn in buttons)
            {
                try { names.Add(btn.Current.Name); } catch { }
            }
        }
        catch { }
        return names;
    }

    /// <summary>Click a button by partial name match.</summary>
    public static bool ClickButton(AutomationElement parent, string buttonName)
    {
        try
        {
            var cond = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button);
            var buttons = parent.FindAll(TreeScope.Descendants, cond);
            foreach (AutomationElement btn in buttons)
            {
                try
                {
                    string name = btn.Current.Name;
                    if (!string.IsNullOrEmpty(name) &&
                        name.IndexOf(buttonName, StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        ((InvokePattern)btn.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
                        return true;
                    }
                }
                catch { }
            }
        }
        catch { }
        return false;
    }

    /// <summary>Click the first button that isn't Cancel/No/Help/Close.</summary>
    public static string ClickFirstActionButton(AutomationElement parent)
    {
        try
        {
            var cond = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button);
            var buttons = parent.FindAll(TreeScope.Descendants, cond);
            foreach (AutomationElement btn in buttons)
            {
                try
                {
                    string name = btn.Current.Name;
                    if (string.IsNullOrEmpty(name)) continue;
                    string lower = name.ToLower();
                    if (lower.Contains("cancel") || lower.Contains("no") || lower.Contains("help") ||
                        lower.Contains("don't") || lower.Contains("close") || lower.Contains("hide") ||
                        lower.Contains("back") || lower.Contains("more"))
                        continue;
                    ((InvokePattern)btn.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
                    return name;
                }
                catch { }
            }
        }
        catch { }
        return null;
    }

    // ===== CREDENTIAL FILLING =====

    /// <summary>Fill Edit controls: 2+ edits = username+password, 1 edit = password only.</summary>
    public static int FillCredentials(AutomationElement parent, string username, string password)
    {
        try
        {
            var cond = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit);
            var edits = parent.FindAll(TreeScope.Descendants, cond);
            if (edits.Count >= 2)
            {
                try { ((ValuePattern)edits[0].GetCurrentPattern(ValuePattern.Pattern)).SetValue(username); } catch { }
                try { ((ValuePattern)edits[1].GetCurrentPattern(ValuePattern.Pattern)).SetValue(password); } catch { }
                return edits.Count;
            }
            else if (edits.Count == 1)
            {
                try { ((ValuePattern)edits[0].GetCurrentPattern(ValuePattern.Pattern)).SetValue(password); } catch { }
                return 1;
            }
        }
        catch { }
        return 0;
    }

    // ===== WINDOW HANDLE =====

    /// <summary>Get the native window handle (HWND) for a PID's top-level window.</summary>
    public static IntPtr GetWindowHandleByPid(int pid, int timeoutMs)
    {
        var root = AutomationElement.RootElement;
        var deadline = DateTime.Now.AddMilliseconds(timeoutMs);
        while (DateTime.Now < deadline)
        {
            try
            {
                var pidCond = new PropertyCondition(AutomationElement.ProcessIdProperty, pid);
                var wins = root.FindAll(TreeScope.Children, pidCond);
                foreach (AutomationElement w in wins)
                {
                    try
                    {
                        string name = w.Current.Name;
                        // Skip progress/connecting dialogs, find the actual session window
                        if (!string.IsNullOrEmpty(name) &&
                            !name.Contains("security warning") &&
                            !name.Contains("Connecting to") &&
                            !name.Contains("Configuring") &&
                            !name.Contains("Securing"))
                        {
                            IntPtr hwnd = new IntPtr(w.Current.NativeWindowHandle);
                            if (hwnd != IntPtr.Zero) return hwnd;
                        }
                    }
                    catch { }
                }
            }
            catch { }
            Thread.Sleep(500);
        }
        return IntPtr.Zero;
    }
}
