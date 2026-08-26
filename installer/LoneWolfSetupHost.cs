// .NET Framework 4.8 host: one UAC via app.manifest (requireAdministrator).
// Does not relaunch with runas. Extracts the STA installer script and runs it
// already elevated. Optional zip overlay at EOF (magic LWPAYLOAD1).
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

internal static class LoneWolfSetupHost
{
    const string Magic = "LWPAYLOAD1";

    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            var work = Path.Combine(Path.GetTempPath(), "lw-setup-" + Guid.NewGuid().ToString("n"));
            Directory.CreateDirectory(work);

            var script = Path.Combine(work, "Install-LoneWolfLauncher.ps1");
            ExtractEmbeddedScript(script);
            ExtractBranding(work);

            var overlayDir = Path.Combine(work, "payload");
            var exePath = Assembly.GetExecutingAssembly().Location;
            TryExtractOverlay(exePath, overlayDir);

            var psi = new ProcessStartInfo();
            psi.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;

            var sb = new StringBuilder();
            sb.Append("-NoProfile -STA -ExecutionPolicy Bypass -File \"");
            sb.Append(script);
            sb.Append("\" -AlreadyElevated");

            if (Directory.Exists(overlayDir))
            {
                var nsis = Path.Combine(overlayDir, "LoneWolf-Launcher-Nsis.exe");
                var portable = Path.Combine(overlayDir, "LoneWolf-Launcher.exe");
                if (File.Exists(nsis))
                {
                    sb.Append(" -InnerNsis \"");
                    sb.Append(nsis);
                    sb.Append("\"");
                }
                if (File.Exists(portable))
                {
                    sb.Append(" -PortableExe \"");
                    sb.Append(portable);
                    sb.Append("\"");
                }
            }

            foreach (var a in args)
            {
                if (string.Equals(a, "/S", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(a, "-S", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(a, "--silent", StringComparison.OrdinalIgnoreCase))
                {
                    sb.Append(" -Silent");
                    continue;
                }
                if (a.StartsWith("/D=", StringComparison.OrdinalIgnoreCase))
                {
                    sb.Append(" -InstallDir \"");
                    sb.Append(a.Substring(3).Trim('"'));
                    sb.Append("\"");
                    continue;
                }
                sb.Append(' ');
                if (a.IndexOf(' ') >= 0) sb.Append('"').Append(a).Append('"');
                else sb.Append(a);
            }

            psi.Arguments = sb.ToString();
            var p = Process.Start(psi);
            if (p == null) return 1;
            p.WaitForExit();
            return p.ExitCode;
        }
        catch (Exception ex)
        {
            try
            {
                MessageBox.Show(ex.Message, "LoneWolf Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            catch { }
            return 1;
        }
    }

    static void ExtractEmbeddedScript(string dest)
    {
        var asm = Assembly.GetExecutingAssembly();
        Stream s = asm.GetManifestResourceStream("Install-LoneWolfLauncher.ps1");
        if (s == null)
        {
            foreach (var name in asm.GetManifestResourceNames())
            {
                if (name.EndsWith("Install-LoneWolfLauncher.ps1", StringComparison.OrdinalIgnoreCase))
                {
                    s = asm.GetManifestResourceStream(name);
                    break;
                }
            }
        }
        if (s == null)
            throw new InvalidOperationException("Embedded installer script missing.");
        using (s)
        using (var fs = File.Create(dest))
            s.CopyTo(fs);
    }

    static void ExtractBranding(string destDir)
    {
        var asm = Assembly.GetExecutingAssembly();
        foreach (var name in asm.GetManifestResourceNames())
        {
            string destName = null;
            if (name.EndsWith("icon.ico", StringComparison.OrdinalIgnoreCase)) destName = "icon.ico";
            else if (name.EndsWith("installerSidebar.bmp", StringComparison.OrdinalIgnoreCase)) destName = "installerSidebar.bmp";
            else if (name.EndsWith("dotnet-runtime.json", StringComparison.OrdinalIgnoreCase)) destName = "dotnet-runtime.json";
            if (destName == null) continue;
            using (var s = asm.GetManifestResourceStream(name))
            using (var fs = File.Create(Path.Combine(destDir, destName)))
                if (s != null) s.CopyTo(fs);
        }
    }

    static void TryExtractOverlay(string exePath, string destDir)
    {
        try
        {
            using (var fs = File.OpenRead(exePath))
            {
                if (fs.Length < Magic.Length + 8) return;
                fs.Seek(-(Magic.Length + 8), SeekOrigin.End);
                var lenBuf = new byte[8];
                var magBuf = new byte[Magic.Length];
                fs.Read(lenBuf, 0, 8);
                fs.Read(magBuf, 0, magBuf.Length);
                if (Encoding.ASCII.GetString(magBuf) != Magic) return;
                var zipLen = BitConverter.ToInt64(lenBuf, 0);
                if (zipLen <= 0 || zipLen > fs.Length - Magic.Length - 8) return;
                fs.Seek(-(Magic.Length + 8 + zipLen), SeekOrigin.End);
                var zipPath = Path.Combine(Path.GetTempPath(), "lw-overlay-" + Guid.NewGuid().ToString("n") + ".zip");
                using (var zf = File.Create(zipPath))
                {
                    var buf = new byte[81920];
                    long left = zipLen;
                    while (left > 0)
                    {
                        int n = fs.Read(buf, 0, (int)Math.Min(buf.Length, left));
                        if (n <= 0) break;
                        zf.Write(buf, 0, n);
                        left -= n;
                    }
                }
                Directory.CreateDirectory(destDir);
                System.IO.Compression.ZipFile.ExtractToDirectory(zipPath, destDir);
                try { File.Delete(zipPath); } catch { }
            }
        }
        catch { }
    }
}
