// dsh-openai-bridge 安全闸（guard.exe）
// 由 install-guard.ps1 用 Windows 自带的 .NET Framework 编译器（csc.exe）编译。
//
// 作用：dsh 管家的 pwsh 工具每次执行命令都会经过本闸：
//   1) 命令命中危险特征（杀进程 / 关机重启 / 删系统路径等）→ 直接拒绝并返回可读提示；
//   2) 其余命令原样转发给真实 PowerShell（pwsh 7 → PATH → 系统自带 5.1 兜底）。
// 编译目标：.NET Framework 4.0+（Windows 10/11 自带），无任何第三方依赖。

using System;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class Program
{
    // 危险命令特征（子串匹配，大小写不敏感；命中即拒绝）
    private static readonly string[] DenySubstrings =
    {
        "taskkill",                          // 杀进程（含 /IM node.exe /F 等）
        "stop-process",                      // 杀进程（Stop-Process、别名 kill）
        "tskill",                            // 杀进程（旧命令）
        "wmic process call terminate",       // 杀进程（WMIC）
        "shutdown",                          // 关机 / 注销（shutdown.exe 等）
        "restart-computer",                  // 重启
        "stop-computer",                     // 关机
        "format ",                           // 格式化磁盘（带尾空格避免误伤 Format-Table）
        "diskpart",                          // 磁盘分区工具
        "clean-all",                         // 磁盘彻底清理
        "reg delete",                        // 删除注册表
        "reg add",                           // 修改注册表
        "sc delete",                         // 删除 Windows 服务
        "net stop ",                         // 停止服务（含停掉桥依赖的服务）
        "net user",                          // 用户账户管理
    };

    // 系统关键路径标记：配合删除类命令（remove-item / del / rmdir）使用
    private static readonly string[] CriticalPathMarks =
    {
        "c:\\windows",
        "c:\\program files",
        "c:\\programdata",
        "system32",
        "boot",
        "recovery",
        "c:\\$",
    };

    private static int Main(string[] args)
    {
        // 提取 -Command 后的命令文本（pwsh-local 的固定参数：-NoLogo -NoProfile -NonInteractive -Command <cmd>）
        string command = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (string.Equals(args[i], "-Command", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                command = args[i + 1];
                break;
            }
        }

        if (command != null)
        {
            string low = command.ToLowerInvariant();
            string denied = null;

            foreach (string pat in DenySubstrings)
            {
                if (low.Contains(pat)) { denied = pat; break; }
            }

            if (denied == null)
            {
                bool critical = false;
                foreach (string m in CriticalPathMarks)
                {
                    if (low.Contains(m)) { critical = true; break; }
                }
                if (critical &&
                    (low.Contains("remove-item") || low.Contains(" del ") || low.Contains("rmdir")))
                {
                    denied = "remove-item/del on system path";
                }
            }

            if (denied != null)
            {
                Console.WriteLine("[安全拦截] 该命令被 dsh-openai-bridge 安全策略禁止（命中规则: " + denied + "）。");
                Console.WriteLine("[安全拦截] 管家不能执行杀进程/关机/删除系统文件等操作。如需执行，请关闭桥后人工操作。");
                return 1;
            }
        }

        return RunRealPowerShell(args);
    }

    // 转发给真实 PowerShell：与 pwsh-local 原参数完全一致
    private static int RunRealPowerShell(string[] args)
    {
        string pwsh = ResolvePowerShell();
        if (pwsh == null)
        {
            Console.Error.WriteLine("guard: 找不到真实 PowerShell 可执行文件");
            return 2;
        }

        var psi = new ProcessStartInfo
        {
            FileName = pwsh,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        psi.Arguments = JoinArguments(args);

        using (Process p = Process.Start(psi))
        {
            p.OutputDataReceived += (s, e) => { if (e.Data != null) Console.WriteLine(e.Data); };
            p.ErrorDataReceived += (s, e) => { if (e.Data != null) Console.Error.WriteLine(e.Data); };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            p.WaitForExit();
            return p.ExitCode;
        }
    }

    // 探测真实 PowerShell：PowerShell 7 安装位置 → PATH → Windows 自带 5.1 兜底
    private static string ResolvePowerShell()
    {
        string[] candidates =
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7-preview", "pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "pwsh.exe"),
        };
        foreach (string c in candidates)
        {
            if (File.Exists(c)) return c;
        }

        string path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (string raw in path.Split(';'))
        {
            string dir = raw.Trim().Trim('"');
            if (dir.Length == 0) continue;
            try
            {
                string p1 = Path.Combine(dir, "pwsh.exe"); if (File.Exists(p1)) return p1;
                string p2 = Path.Combine(dir, "powershell.exe"); if (File.Exists(p2)) return p2;
            }
            catch { /* 忽略不可读的 PATH 条目 */ }
        }

        string sys = Environment.GetFolderPath(Environment.SpecialFolder.System);
        string legacy = Path.Combine(sys, "WindowsPowerShell", "v1.0", "powershell.exe");
        if (File.Exists(legacy)) return legacy;
        return null;
    }

    // 拼接 Windows 命令行参数（MSDN 标准引号算法，兼容 .NET Framework 4.x）
    private static string JoinArguments(string[] args)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < args.Length; i++)
        {
            if (i > 0) sb.Append(' ');
            sb.Append(QuoteArgument(args[i]));
        }
        return sb.ToString();
    }

    private static string QuoteArgument(string s)
    {
        if (s.Length == 0) return "\"\"";
        bool needs = false;
        foreach (char c in s)
        {
            if (c == ' ' || c == '\t' || c == '"') { needs = true; break; }
        }
        if (!needs) return s;

        var sb = new StringBuilder("\"");
        for (int i = 0; i < s.Length; i++)
        {
            int backslashes = 0;
            while (i < s.Length && s[i] == '\\') { backslashes++; i++; }
            if (i < s.Length)
            {
                if (s[i] == '"') { sb.Append('\\', backslashes * 2 + 1); sb.Append('"'); }
                else { sb.Append('\\', backslashes); sb.Append(s[i]); }
            }
            else { sb.Append('\\', backslashes * 2); }
        }
        sb.Append('"');
        return sb.ToString();
    }
}
