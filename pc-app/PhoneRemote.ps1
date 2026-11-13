# PhoneRemote (no-install version) - uses only what ships with Windows 10/11.
# Start it with "Start PhoneRemote.bat".
param([int]$Port = 8765)

$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'PhoneRemote'

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host ""
    Write-Host "This PC is locked down by your organisation (PowerShell 'Constrained Language Mode')," -ForegroundColor Red
    Write-Host "so PhoneRemote can't run here." -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$source = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public static class PhoneRemoteServer
{
    // ------------------------------------------------------------ Win32
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, int dx, int dy, int data, UIntPtr extra);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] static extern short VkKeyScan(char ch);
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public InputUnion U; }

    // ------------------------------------------------------------ state
    static readonly object sync = new object();
    static int monitorIndex = 1;      // 1-based
    static Rectangle[] mons;
    static string token;
    static string htmlPath;
    static int thePort;
    static double relX, relY;         // leftover sub-pixel trackpad movement
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    // ------------------------------------------------------------ start
    public static void Start(int port, string theToken, string theHtmlPath)
    {
        token = theToken;
        thePort = port;
        htmlPath = theHtmlPath;
        try { if (!SetProcessDpiAwarenessContext(new IntPtr(-4))) SetProcessDPIAware(); }
        catch { try { SetProcessDPIAware(); } catch { } }

        List<Rectangle> list = new List<Rectangle>();
        foreach (Screen s in Screen.AllScreens)
        {
            if (s.Primary) list.Insert(0, s.Bounds); else list.Add(s.Bounds);
        }
        mons = list.ToArray();

        TcpListener listener = new TcpListener(IPAddress.Loopback, port)   // this PC only: no firewall prompt;
        listener.Start();   // throws here if the port is taken

        Thread acc = new Thread(AcceptLoop);
        acc.IsBackground = true;
        acc.Start(listener);
    }

    public static string LanIp()
    {
        try
        {
            using (Socket s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp))
            {
                s.Connect(new IPEndPoint(IPAddress.Parse("8.8.8.8"), 53)); // nothing is actually sent
                return ((IPEndPoint)s.LocalEndPoint).Address.ToString();
            }
        }
        catch { return "127.0.0.1"; }
    }

    static Rectangle CurMon()
    {
        int i;
        lock (sync) { i = monitorIndex; }
        if (i < 1 || i > mons.Length) i = 1;
        return mons[i - 1];
    }

    // ------------------------------------------------------------ input
    const uint KEYUP = 0x2, EXTENDED = 0x1, UNICODE = 0x4;

    static readonly Dictionary<string, int> VK = new Dictionary<string, int>
    {
        {"enter",0x0D},{"backspace",0x08},{"esc",0x1B},{"tab",0x09},{"space",0x20},
        {"delete",0x2E},{"insert",0x2D},{"home",0x24},{"end",0x23},{"pageup",0x21},{"pagedown",0x22},
        {"up",0x26},{"down",0x28},{"left",0x25},{"right",0x27},
        {"ctrl",0x11},{"alt",0x12},{"shift",0x10},{"win",0x5B},{"printscreen",0x2C},
        {"volup",0xAF},{"voldown",0xAE},{"mute",0xAD},{"playpause",0xB3},
        {"f1",0x70},{"f2",0x71},{"f3",0x72},{"f4",0x73},{"f5",0x74},{"f6",0x75},
        {"f7",0x76},{"f8",0x77},{"f9",0x78},{"f10",0x79},{"f11",0x7A},{"f12",0x7B}
    };

    static bool IsExtended(int vk)
    {
        return (vk >= 0x21 && vk <= 0x28) || vk == 0x2D || vk == 0x2E || vk == 0x5B || vk == 0x5C || vk == 0x2C;
    }

    static void Key(int vk, bool down)
    {
        uint flags = (IsExtended(vk) ? EXTENDED : 0) | (down ? 0 : KEYUP);
        keybd_event((byte)vk, (byte)MapVirtualKey((uint)vk, 0), flags, UIntPtr.Zero);
    }

    static void TypeText(string s)
    {
        foreach (char ch in s)
        {
            if (ch == '\n' || ch == '\r') { Key(0x0D, true); Key(0x0D, false); continue; }
            INPUT[] inp = new INPUT[2];
            inp[0].type = 1; inp[0].U.ki.wScan = ch; inp[0].U.ki.dwFlags = UNICODE;
            inp[1].type = 1; inp[1].U.ki.wScan = ch; inp[1].U.ki.dwFlags = UNICODE | KEYUP;
            SendInput(2, inp, Marshal.SizeOf(typeof(INPUT)));
        }
    }

    // returns list of virtual keys to press (e.g. shift + key), or null to type it as text
    static List<int> ResolveKey(string name)
    {
        List<int> res = new List<int>();
        string n = name.ToLowerInvariant();
        int vk;
        if (VK.TryGetValue(n, out vk)) { res.Add(vk); return res; }
        if (name.Length == 1)
        {
            short r = VkKeyScan(n[0]);
            if (r == -1) return null;
            if (((r >> 8) & 1) != 0) res.Add(0x10);
            res.Add(r & 0xFF);
            return res;
        }
        return res;
    }

    static void MouseButton(string b, bool down)
    {
        uint f;
        if (b == "right") f = down ? 0x0008u : 0x0010u;
        else if (b == "middle") f = down ? 0x0020u : 0x0040u;
        else f = down ? 0x0002u : 0x0004u;
        mouse_event(f, 0, 0, 0, UIntPtr.Zero);
    }

    static double Clamp01(double v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

    static void HandleEvent(Dictionary<string, object> e)
    {
        string t = S(e, "t", "");
        Rectangle m = CurMon();
        if (t == "move")
        {
            SetCursorPos(m.X + (int)(Clamp01(D(e, "x", 0)) * (m.Width - 1)),
                         m.Y + (int)(Clamp01(D(e, "y", 0)) * (m.Height - 1)));
        }
        else if (t == "rel")
        {
            POINT p; GetCursorPos(out p);
            relX += D(e, "dx", 0) * m.Width;
            relY += D(e, "dy", 0) * m.Width;
            int ix = (int)relX, iy = (int)relY;
            relX -= ix; relY -= iy;
            int nx = Math.Min(Math.Max(p.X + ix, m.X), m.X + m.Width - 1);
            int ny = Math.Min(Math.Max(p.Y + iy, m.Y), m.Y + m.Height - 1);
            SetCursorPos(nx, ny);
        }
        else if (t == "click")
        {
            int n = (int)D(e, "n", 1);
            string b = S(e, "b", "left");
            for (int i = 0; i < n; i++)
            {
                MouseButton(b, true); MouseButton(b, false);
                if (i < n - 1) Thread.Sleep(40);
            }
        }
        else if (t == "down") MouseButton(S(e, "b", "left"), true);
        else if (t == "up") MouseButton(S(e, "b", "left"), false);
        else if (t == "scroll")
        {
            int dy = (int)D(e, "dy", 0), dx = (int)D(e, "dx", 0);
            if (dy != 0) mouse_event(0x0800, 0, 0, dy * 120, UIntPtr.Zero);
            if (dx != 0) mouse_event(0x1000, 0, 0, dx * 120, UIntPtr.Zero);
        }
        else if (t == "text") TypeText(S(e, "s", ""));
        else if (t == "key")
        {
            List<int> press = new List<int>();
            object mo;
            if (e.TryGetValue("mods", out mo) && mo is List<object>)
            {
                foreach (object x in (List<object>)mo)
                {
                    List<int> mk = ResolveKey(Convert.ToString(x, Inv));
                    if (mk != null) press.AddRange(mk);
                }
            }
            List<int> k = ResolveKey(S(e, "k", ""));
            if (k == null) { TypeText(S(e, "k", "")); return; }
            press.AddRange(k);
            foreach (int vk in press) Key(vk, true);
            for (int i = press.Count - 1; i >= 0; i--) Key(press[i], false);
        }
    }

    static string CursorJson()
    {
        Rectangle m = CurMon();
        POINT p;
        if (!GetCursorPos(out p)) return "{}";
        return "{\"cx\":" + ((p.X - m.X) / (double)m.Width).ToString("R", Inv) +
               ",\"cy\":" + ((p.Y - m.Y) / (double)m.Height).ToString("R", Inv) + "}";
    }

    // ------------------------------------------------------------ http
    static void AcceptLoop(object o)
    {
        TcpListener l = (TcpListener)o;
        while (true)
        {
            try
            {
                TcpClient c = l.AcceptTcpClient();
                Thread t = new Thread(Handle);
                t.IsBackground = true;
                t.Start(c);
            }
            catch (Exception ex) { Console.WriteLine("accept error: " + ex.Message); Thread.Sleep(200); }
        }
    }

    static int FindHeaderEnd(byte[] b, int len)
    {
        for (int i = 0; i + 3 < len; i++)
            if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
        return -1;
    }

    static void Handle(object o)
    {
        TcpClient c = (TcpClient)o;
        try
        {
            c.NoDelay = true;
            c.ReceiveTimeout = 15000;
            c.SendTimeout = 15000;
            NetworkStream ns = c.GetStream();

            MemoryStream buf = new MemoryStream();
            byte[] tmp = new byte[8192];
            int hdrEnd = -1;
            while (hdrEnd < 0)
            {
                int n = ns.Read(tmp, 0, tmp.Length);
                if (n <= 0) return;
                buf.Write(tmp, 0, n);
                if (buf.Length > 65536) return;
                hdrEnd = FindHeaderEnd(buf.GetBuffer(), (int)buf.Length);
            }
            byte[] all = buf.ToArray();
            string head = Encoding.ASCII.GetString(all, 0, hdrEnd);
            string[] lines = head.Split(new string[] { "\r\n" }, StringSplitOptions.None);
            string[] rl = lines[0].Split(' ');
            if (rl.Length < 2) return;
            string method = rl[0].ToUpperInvariant(), target = rl[1];

            Dictionary<string, string> h = new Dictionary<string, string>();
            for (int i = 1; i < lines.Length; i++)
            {
                int p = lines[i].IndexOf(':');
                if (p > 0) h[lines[i].Substring(0, p).Trim().ToLowerInvariant()] = lines[i].Substring(p + 1).Trim();
            }
            int len = 0; string cl;
            if (h.TryGetValue("content-length", out cl)) int.TryParse(cl, out len);
            if (len < 0 || len > 1000000) return;
            byte[] body = new byte[len];
            int have = Math.Min(len, all.Length - (hdrEnd + 4));
            Array.Copy(all, hdrEnd + 4, body, 0, have);
            while (have < len)
            {
                int n = ns.Read(body, have, len - have);
                if (n <= 0) return;
                have += n;
            }

            string path = target, query = "";
            int qi = target.IndexOf('?');
            if (qi >= 0) { path = target.Substring(0, qi); query = target.Substring(qi + 1); }
            string ip = ((IPEndPoint)c.Client.RemoteEndPoint).Address.ToString();
            Route(ns, method, path, ParseQuery(query), h, body, ip);
        }
        catch { }
        finally { try { c.Close(); } catch { } }
    }

    static Dictionary<string, string> ParseQuery(string q)
    {
        Dictionary<string, string> d = new Dictionary<string, string>();
        foreach (string part in q.Split('&'))
        {
            if (part.Length == 0) continue;
            int p = part.IndexOf('=');
            string k = p >= 0 ? part.Substring(0, p) : part;
            string v = p >= 0 ? part.Substring(p + 1) : "";
            try { d[Uri.UnescapeDataString(k)] = Uri.UnescapeDataString(v.Replace('+', ' ')); } catch { }
        }
        return d;
    }

    static void Send(NetworkStream ns, int code, string ctype, byte[] body)
    {
        string status = code == 200 ? "OK" : code == 401 ? "Unauthorized" : code == 404 ? "Not Found" : "Bad Request";
        string head = "HTTP/1.1 " + code + " " + status + "\r\nContent-Type: " + ctype +
                      "\r\nContent-Length: " + body.Length + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
        byte[] hb = Encoding.ASCII.GetBytes(head);
        ns.Write(hb, 0, hb.Length);
        ns.Write(body, 0, body.Length);
    }

    static void SendJson(NetworkStream ns, int code, string json)
    {
        Send(ns, code, "application/json", Encoding.UTF8.GetBytes(json));
    }

    // Only our own page may send input: the token is a secret header, and the Host
    // header must be localhost (stops other websites and DNS-rebinding tricks).
    static bool HostOk(Dictionary<string, string> h)
    {
        string host;
        if (!h.TryGetValue("host", out host)) return false;
        return host == "localhost:" + thePort || host == "127.0.0.1:" + thePort;
    }

    static bool Authed(Dictionary<string, string> h)
    {
        string key;
        return h.TryGetValue("x-token", out key) && key == token;
    }

    static string SettingsJson()
    {
        lock (sync)
        {
            return "{\"monitor\":" + monitorIndex + "}";
        }
    }

    static void Route(NetworkStream ns, string method, string path, Dictionary<string, string> q,
                      Dictionary<string, string> h, byte[] body, string ip)
    {
        if (!HostOk(h)) { SendJson(ns, 400, "{\"error\":\"bad host\"}"); return; }
        if (method == "GET" && (path == "/" || path == "/index.html"))
        {
            string page = File.ReadAllText(htmlPath, Encoding.UTF8).Replace("__TOKEN__", token);
            Send(ns, 200, "text/html; charset=utf-8", Encoding.UTF8.GetBytes(page));
            return;
        }
        if (!Authed(h)) { SendJson(ns, 401, "{\"error\":\"bad token\"}"); return; }

        if (method == "GET" && path == "/info")
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("{\"settings\":").Append(SettingsJson()).Append(",\"monitors\":[");
            for (int i = 0; i < mons.Length; i++)
            {
                if (i > 0) sb.Append(',');
                sb.Append("{\"i\":").Append(i + 1).Append(",\"w\":").Append(mons[i].Width).Append(",\"h\":").Append(mons[i].Height).Append('}');
            }
            sb.Append("],\"host\":\"").Append(Esc(Environment.MachineName)).Append("\"}");
            SendJson(ns, 200, sb.ToString());
            return;
        }

        if (method == "POST" && (path == "/input" || path == "/settings"))
        {
            object data;
            try { data = Json.Parse(Encoding.UTF8.GetString(body)); }
            catch { SendJson(ns, 400, "{\"error\":\"bad json\"}"); return; }

            if (path == "/input")
            {
                List<object> evs = data as List<object>;
                if (evs == null) { evs = new List<object>(); evs.Add(data); }
                foreach (object ev in evs)
                {
                    Dictionary<string, object> d = ev as Dictionary<string, object>;
                    if (d == null) continue;
                    try { HandleEvent(d); }
                    catch (Exception ex) { Console.WriteLine("input error: " + ex.Message); }
                }
                SendJson(ns, 200, CursorJson());
                return;
            }

            Dictionary<string, object> s = data as Dictionary<string, object>;
            if (s != null)
            {
                lock (sync)
                {
                    if (s.ContainsKey("monitor"))
                    {
                        int mi = (int)D(s, "monitor", 1);
                        if (mi >= 1 && mi <= mons.Length) monitorIndex = mi;
                    }
                }
            }
            SendJson(ns, 200, "{\"settings\":" + SettingsJson() + "}");
            return;
        }
        SendJson(ns, 404, "{\"error\":\"not found\"}");
    }

    // ------------------------------------------------------------ small helpers
    static string S(Dictionary<string, object> d, string k, string def)
    {
        object v;
        return d.TryGetValue(k, out v) && v != null ? Convert.ToString(v, Inv) : def;
    }

    static double D(Dictionary<string, object> d, string k, double def)
    {
        object v;
        if (d.TryGetValue(k, out v) && v is double) return (double)v;
        return def;
    }

    static string Esc(string s)
    {
        StringBuilder sb = new StringBuilder();
        foreach (char ch in s)
        {
            if (ch == '"' || ch == '\\') sb.Append('\\').Append(ch);
            else if (ch < 32) sb.Append(' ');
            else sb.Append(ch);
        }
        return sb.ToString();
    }

    // Minimal JSON reader: objects -> Dictionary, arrays -> List, numbers -> double
    class Json
    {
        string s; int i;
        public static object Parse(string text)
        {
            Json j = new Json();
            j.s = text; j.i = 0;
            return j.Value();
        }
        void Ws() { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }
        char Peek() { if (i >= s.Length) throw new FormatException("end of json"); return s[i]; }
        void Expect(char c) { Ws(); if (Peek() != c) throw new FormatException("expected " + c); i++; }
        bool Word(string w)
        {
            if (string.CompareOrdinal(s, i, w, 0, w.Length) == 0) { i += w.Length; return true; }
            return false;
        }
        object Value()
        {
            Ws();
            char c = Peek();
            if (c == '{')
            {
                i++;
                Dictionary<string, object> d = new Dictionary<string, object>();
                Ws();
                if (Peek() == '}') { i++; return d; }
                while (true)
                {
                    Ws();
                    string k = Str();
                    Expect(':');
                    d[k] = Value();
                    Ws();
                    if (Peek() == ',') { i++; continue; }
                    Expect('}');
                    return d;
                }
            }
            if (c == '[')
            {
                i++;
                List<object> l = new List<object>();
                Ws();
                if (Peek() == ']') { i++; return l; }
                while (true)
                {
                    l.Add(Value());
                    Ws();
                    if (Peek() == ',') { i++; continue; }
                    Expect(']');
                    return l;
                }
            }
            if (c == '"') return Str();
            if (Word("true")) return true;
            if (Word("false")) return false;
            if (Word("null")) return null;
            int st = i;
            while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
            if (i == st) throw new FormatException("bad json value");
            return double.Parse(s.Substring(st, i - st), NumberStyles.Float, CultureInfo.InvariantCulture);
        }
        string Str()
        {
            if (Peek() != '"') throw new FormatException("expected string");
            i++;
            StringBuilder sb = new StringBuilder();
            while (Peek() != '"')
            {
                char c = s[i];
                if (c == '\\')
                {
                    i++;
                    char e = Peek();
                    switch (e)
                    {
                        case 'n': sb.Append('\n'); break;
                        case 'r': sb.Append('\r'); break;
                        case 't': sb.Append('\t'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'u':
                            sb.Append((char)Convert.ToInt32(s.Substring(i + 1, 4), 16));
                            i += 4;
                            break;
                        default: sb.Append(e); break;
                    }
                }
                else sb.Append(c);
                i++;
            }
            i++;
            return sb.ToString();
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $source -ReferencedAssemblies System.Drawing, System.Windows.Forms
} catch {
    Write-Host ""
    Write-Host "Could not start PhoneRemote:" -ForegroundColor Red
    Write-Host $_.Exception.Message
    Read-Host "Press Enter to close"
    exit 1
}

$token = [guid]::NewGuid().ToString('N')
$html = Join-Path $PSScriptRoot 'pc.html'
if (-not (Test-Path $html)) {
    Write-Host "pc.html is missing - keep it in the same folder as this script." -ForegroundColor Red
    Read-Host "Press Enter to close"; exit 1
}

try {
    [PhoneRemoteServer]::Start($Port, $token, $html)
} catch {
    Write-Host ""
    Write-Host "PhoneRemote seems to be running already (port $Port is busy)." -ForegroundColor Yellow
    Write-Host "Opening it in your browser..."
    Start-Process "http://localhost:$Port/"
    Start-Sleep -Seconds 3
    exit 0
}

Write-Host ""
Write-Host "  PhoneRemote is running." -ForegroundColor Green
Write-Host "  A browser tab is opening - click 'Start' there and pick your screen."
Write-Host "  Keep this window and that tab open. Close this window to stop."
Write-Host ""
Start-Process "http://localhost:$Port/"

while ($true) { Start-Sleep -Seconds 1 }
