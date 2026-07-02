<#
.SYNOPSIS
  Custom Icon - generate an AI icon from a description and apply it to a folder.
.DESCRIPTION
  Launched from the right-click context menu on a folder ("Custom Icon").
  Generates an image via Pollinations (free), OpenAI, or Gemini, converts it
  to a multi-size .ico, and applies it to the folder via desktop.ini.
  Claude / DeepSeek / OpenAI / Gemini API keys can optionally be used to
  "enhance" your short description into a detailed icon prompt first.
#>
param(
    [string]$Folder,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
$ConfigDir  = Join-Path $env:APPDATA 'CustomIcon'
$ConfigPath = Join-Path $ConfigDir 'config.json'

function Get-DefaultConfig {
    @{
        provider          = 'pollinations'   # pollinations | openai | gemini
        enhancer          = 'none'           # none | claude | deepseek | openai | gemini
        openai_api_key    = ''
        gemini_api_key    = ''
        claude_api_key    = ''
        deepseek_api_key  = ''
        remove_background = $true
    }
}

function Load-Config {
    $cfg = Get-DefaultConfig
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $json = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                $prop = $json.PSObject.Properties[$k]
                if ($null -ne $prop -and $null -ne $prop.Value) { $cfg[$k] = $prop.Value }
            }
        } catch { }
    }
    return $cfg
}

function Save-Config($cfg) {
    if (-not (Test-Path -LiteralPath $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }
    ($cfg | ConvertTo-Json) | Out-File -FilePath $ConfigPath -Encoding utf8 -Force
}

# ---------------------------------------------------------------------------
# C# helper: ICO writer, background removal, shell refresh
# ---------------------------------------------------------------------------
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

public static class IconMaker
{
    // Convert arbitrary image bytes (png/jpg/webp) into a multi-size ICO.
    public static byte[] MakeIco(byte[] imageBytes, bool removeBackground)
    {
        using (var ms = new MemoryStream(imageBytes))
        using (var loaded = new Bitmap(ms))
        {
            Bitmap src = new Bitmap(loaded.Width, loaded.Height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(src)) { g.DrawImage(loaded, 0, 0, loaded.Width, loaded.Height); }

            if (removeBackground && !HasTransparency(src))
            {
                var cleaned = RemoveBackground(src);
                src.Dispose();
                src = cleaned;
            }

            int[] sizes = new int[] { 256, 64, 48, 32, 16 };
            var pngs = new List<byte[]>();
            foreach (int s in sizes)
            {
                using (var bmp = new Bitmap(s, s, PixelFormat.Format32bppArgb))
                using (var g = Graphics.FromImage(bmp))
                {
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.SmoothingMode = SmoothingMode.HighQuality;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.Clear(Color.Transparent);
                    g.DrawImage(src, new Rectangle(0, 0, s, s));
                    using (var pms = new MemoryStream())
                    {
                        bmp.Save(pms, ImageFormat.Png);
                        pngs.Add(pms.ToArray());
                    }
                }
            }
            src.Dispose();

            using (var outMs = new MemoryStream())
            using (var w = new BinaryWriter(outMs))
            {
                w.Write((short)0);            // reserved
                w.Write((short)1);            // type: icon
                w.Write((short)pngs.Count);   // count
                int offset = 6 + 16 * pngs.Count;
                for (int i = 0; i < pngs.Count; i++)
                {
                    int s = sizes[i];
                    byte dim = (byte)(s == 256 ? 0 : s);   // 0 means 256
                    w.Write(dim);              // width
                    w.Write(dim);              // height
                    w.Write((byte)0);          // palette
                    w.Write((byte)0);          // reserved
                    w.Write((short)1);         // planes
                    w.Write((short)32);        // bpp
                    w.Write(pngs[i].Length);   // data size
                    w.Write(offset);           // data offset
                    offset += pngs[i].Length;
                }
                foreach (var p in pngs) w.Write(p);
                w.Flush();
                return outMs.ToArray();
            }
        }
    }

    private static bool HasTransparency(Bitmap b)
    {
        // sample a grid; if any pixel already transparent, image has real alpha
        for (int y = 0; y < b.Height; y += Math.Max(1, b.Height / 16))
            for (int x = 0; x < b.Width; x += Math.Max(1, b.Width / 16))
                if (b.GetPixel(x, y).A < 250) return true;
        return false;
    }

    // Flood-fill transparent from the borders, keyed on the corner color.
    private static Bitmap RemoveBackground(Bitmap src)
    {
        int w = src.Width, h = src.Height;
        const int tol = 38;
        Color key = AverageCornerColor(src);

        var result = new Bitmap(src);
        var visited = new bool[w * h];
        var queue = new Queue<Point>();

        for (int x = 0; x < w; x++) { queue.Enqueue(new Point(x, 0)); queue.Enqueue(new Point(x, h - 1)); }
        for (int y = 0; y < h; y++) { queue.Enqueue(new Point(0, y)); queue.Enqueue(new Point(w - 1, y)); }

        while (queue.Count > 0)
        {
            var p = queue.Dequeue();
            if (p.X < 0 || p.Y < 0 || p.X >= w || p.Y >= h) continue;
            int idx = p.Y * w + p.X;
            if (visited[idx]) continue;
            visited[idx] = true;

            Color c = result.GetPixel(p.X, p.Y);
            if (Math.Abs(c.R - key.R) > tol || Math.Abs(c.G - key.G) > tol || Math.Abs(c.B - key.B) > tol) continue;

            result.SetPixel(p.X, p.Y, Color.Transparent);
            queue.Enqueue(new Point(p.X + 1, p.Y));
            queue.Enqueue(new Point(p.X - 1, p.Y));
            queue.Enqueue(new Point(p.X, p.Y + 1));
            queue.Enqueue(new Point(p.X, p.Y - 1));
        }
        return result;
    }

    private static Color AverageCornerColor(Bitmap b)
    {
        Color[] corners = new Color[] {
            b.GetPixel(1, 1),
            b.GetPixel(b.Width - 2, 1),
            b.GetPixel(1, b.Height - 2),
            b.GetPixel(b.Width - 2, b.Height - 2)
        };
        int r = 0, g = 0, bl = 0;
        foreach (var c in corners) { r += c.R; g += c.G; bl += c.B; }
        return Color.FromArgb(r / 4, g / 4, bl / 4);
    }

    // Pull the 256px PNG frame back out of the ICO (entry 0) for previewing.
    // (Icon.ToBitmap() can't decode PNG-compressed frames on .NET Framework.)
    public static byte[] ExtractLargestPng(byte[] ico)
    {
        int size = BitConverter.ToInt32(ico, 6 + 8);
        int offset = BitConverter.ToInt32(ico, 6 + 12);
        var result = new byte[size];
        Array.Copy(ico, offset, result, 0, size);
        return result;
    }

    [DllImport("shell32.dll")]
    private static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);

    public static void RefreshFolder(string path)
    {
        IntPtr p = Marshal.StringToHGlobalUni(path);
        try
        {
            SHChangeNotify(0x00001000, 0x0005, p, IntPtr.Zero); // SHCNE_UPDATEDIR, SHCNF_PATHW
            SHChangeNotify(0x00000800, 0x0005, p, IntPtr.Zero); // SHCNE_ATTRIBUTES
        }
        finally { Marshal.FreeHGlobal(p); }
    }
}
'@

# ---------------------------------------------------------------------------
# Prompt enhancement (optional, via Claude / DeepSeek / OpenAI / Gemini)
# ---------------------------------------------------------------------------
$EnhancerSystemPrompt = 'You turn a short description into a single detailed image-generation prompt for a small desktop folder icon. The icon must be a single centered subject, bold simple shapes, readable at small sizes. Reply with ONLY the prompt text, no quotes, no explanation, under 60 words.'

function Invoke-Enhancer($cfg, [string]$description) {
    $enhancer = "$($cfg.enhancer)".ToLower()
    switch ($enhancer) {
        'claude' {
            if (-not $cfg.claude_api_key) { throw 'Claude API key not set (open Settings).' }
            $body = @{
                model      = 'claude-opus-4-8'
                max_tokens = 300
                system     = $EnhancerSystemPrompt
                messages   = @(@{ role = 'user'; content = $description })
            } | ConvertTo-Json -Depth 6
            $resp = Invoke-RestMethod -Method Post -Uri 'https://api.anthropic.com/v1/messages' -Headers @{
                'x-api-key'         = $cfg.claude_api_key
                'anthropic-version' = '2023-06-01'
            } -ContentType 'application/json' -Body $body -TimeoutSec 60
            $text = ($resp.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text
            return $text.Trim()
        }
        'deepseek' {
            if (-not $cfg.deepseek_api_key) { throw 'DeepSeek API key not set (open Settings).' }
            $body = @{
                model    = 'deepseek-chat'
                messages = @(
                    @{ role = 'system'; content = $EnhancerSystemPrompt },
                    @{ role = 'user'; content = $description }
                )
            } | ConvertTo-Json -Depth 6
            $resp = Invoke-RestMethod -Method Post -Uri 'https://api.deepseek.com/chat/completions' -Headers @{
                'Authorization' = "Bearer $($cfg.deepseek_api_key)"
            } -ContentType 'application/json' -Body $body -TimeoutSec 60
            return $resp.choices[0].message.content.Trim()
        }
        'openai' {
            if (-not $cfg.openai_api_key) { throw 'OpenAI API key not set (open Settings).' }
            $body = @{
                model    = 'gpt-4o-mini'
                messages = @(
                    @{ role = 'system'; content = $EnhancerSystemPrompt },
                    @{ role = 'user'; content = $description }
                )
            } | ConvertTo-Json -Depth 6
            $resp = Invoke-RestMethod -Method Post -Uri 'https://api.openai.com/v1/chat/completions' -Headers @{
                'Authorization' = "Bearer $($cfg.openai_api_key)"
            } -ContentType 'application/json' -Body $body -TimeoutSec 60
            return $resp.choices[0].message.content.Trim()
        }
        'gemini' {
            if (-not $cfg.gemini_api_key) { throw 'Gemini API key not set (open Settings).' }
            $body = @{
                contents = @(@{ parts = @(@{ text = "$EnhancerSystemPrompt`n`nDescription: $description" }) })
            } | ConvertTo-Json -Depth 8
            $uri = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$($cfg.gemini_api_key)"
            $resp = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/json' -Body $body -TimeoutSec 60
            return $resp.candidates[0].content.parts[0].text.Trim()
        }
        default { return $description }
    }
}

# ---------------------------------------------------------------------------
# Image generation
# ---------------------------------------------------------------------------
function Build-IconPrompt($cfg, [string]$description, [bool]$transparentNative) {
    $prompt = "a single app icon of $description, flat modern vector style, bold simple shapes, centered, vibrant colors, no text"
    if ($transparentNative) {
        $prompt += ', transparent background'
    } elseif ($cfg.remove_background) {
        $prompt += ', on a plain solid white background'
    }
    return $prompt
}

# Returns @{ Bytes = <byte[]>; NativeAlpha = <bool> }
function Invoke-ImageGen($cfg, [string]$description) {
    $provider = "$($cfg.provider)".ToLower()
    switch ($provider) {
        'openai' {
            if (-not $cfg.openai_api_key) { throw 'OpenAI API key not set (open Settings).' }
            $headers = @{ 'Authorization' = "Bearer $($cfg.openai_api_key)" }
            # Try gpt-image-1 (supports native transparency), fall back to DALL-E 3
            try {
                $body = @{
                    model      = 'gpt-image-1'
                    prompt     = Build-IconPrompt $cfg $description $true
                    size       = '1024x1024'
                    background = 'transparent'
                } | ConvertTo-Json
                $resp = Invoke-RestMethod -Method Post -Uri 'https://api.openai.com/v1/images/generations' -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 180
                return @{ Bytes = [Convert]::FromBase64String($resp.data[0].b64_json); NativeAlpha = $true }
            } catch {
                $body = @{
                    model           = 'dall-e-3'
                    prompt          = Build-IconPrompt $cfg $description $false
                    size            = '1024x1024'
                    response_format = 'b64_json'
                } | ConvertTo-Json
                $resp = Invoke-RestMethod -Method Post -Uri 'https://api.openai.com/v1/images/generations' -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 180
                return @{ Bytes = [Convert]::FromBase64String($resp.data[0].b64_json); NativeAlpha = $false }
            }
        }
        'gemini' {
            if (-not $cfg.gemini_api_key) { throw 'Gemini API key not set (open Settings).' }
            $body = @{
                contents         = @(@{ parts = @(@{ text = (Build-IconPrompt $cfg $description $false) }) })
                generationConfig = @{ responseModalities = @('IMAGE') }
            } | ConvertTo-Json -Depth 8
            $uri = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent?key=$($cfg.gemini_api_key)"
            $resp = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/json' -Body $body -TimeoutSec 180
            $part = $resp.candidates[0].content.parts | Where-Object { $_.inlineData } | Select-Object -First 1
            if (-not $part) { throw 'Gemini returned no image data.' }
            return @{ Bytes = [Convert]::FromBase64String($part.inlineData.data); NativeAlpha = $false }
        }
        default {
            # Pollinations - free, no API key required
            $prompt = Build-IconPrompt $cfg $description $false
            $seed = Get-Random -Maximum 999999
            $uri = 'https://image.pollinations.ai/prompt/' + [Uri]::EscapeDataString($prompt) + "?width=1024&height=1024&nologo=true&seed=$seed"
            $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 180
            return @{ Bytes = $resp.Content; NativeAlpha = $false }
        }
    }
}

# ---------------------------------------------------------------------------
# Applying / removing the folder icon
# ---------------------------------------------------------------------------
function Set-FolderIcon([string]$folder, [byte[]]$icoBytes) {
    # remove any previous icons made by this tool (new filename busts the icon cache)
    Get-ChildItem -LiteralPath $folder -Filter 'CustomIcon_*.ico' -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Attributes = 'Normal'; Remove-Item -LiteralPath $_.FullName -Force }

    $icoName = "CustomIcon_$([DateTime]::Now.Ticks).ico"
    $icoPath = Join-Path $folder $icoName
    [IO.File]::WriteAllBytes($icoPath, $icoBytes)
    (Get-Item -LiteralPath $icoPath -Force).Attributes = [IO.FileAttributes]::Hidden

    $iniPath = Join-Path $folder 'desktop.ini'
    $lines = @()
    if (Test-Path -LiteralPath $iniPath) {
        $item = Get-Item -LiteralPath $iniPath -Force
        $item.Attributes = 'Normal'
        $lines = @(Get-Content -LiteralPath $iniPath) | Where-Object { $_ -notmatch '^\s*Icon(Resource|File|Index)\s*=' }
    }
    if (-not ($lines -match '^\s*\[\.ShellClassInfo\]')) {
        $lines = @('[.ShellClassInfo]') + $lines
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $out.Add($line)
        if ($line -match '^\s*\[\.ShellClassInfo\]') { $out.Add("IconResource=$icoName,0") }
    }
    [IO.File]::WriteAllLines($iniPath, $out, [Text.Encoding]::Unicode)
    (Get-Item -LiteralPath $iniPath -Force).Attributes = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System

    # ReadOnly on the folder tells Explorer to honor desktop.ini
    $f = Get-Item -LiteralPath $folder -Force
    $f.Attributes = $f.Attributes -bor [IO.FileAttributes]::ReadOnly

    [IconMaker]::RefreshFolder($folder)
}

function Remove-FolderIcon([string]$folder) {
    Get-ChildItem -LiteralPath $folder -Filter 'CustomIcon_*.ico' -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Attributes = 'Normal'; Remove-Item -LiteralPath $_.FullName -Force }

    $iniPath = Join-Path $folder 'desktop.ini'
    if (Test-Path -LiteralPath $iniPath) {
        $item = Get-Item -LiteralPath $iniPath -Force
        $item.Attributes = 'Normal'
        $lines = @(Get-Content -LiteralPath $iniPath) | Where-Object { $_ -notmatch '^\s*IconResource\s*=\s*CustomIcon_' }
        $meaningful = $lines | Where-Object { $_ -and $_ -notmatch '^\s*\[\.ShellClassInfo\]\s*$' }
        if ($meaningful) {
            [IO.File]::WriteAllLines($iniPath, $lines, [Text.Encoding]::Unicode)
            (Get-Item -LiteralPath $iniPath -Force).Attributes = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
        } else {
            Remove-Item -LiteralPath $iniPath -Force
            $f = Get-Item -LiteralPath $folder -Force
            $f.Attributes = $f.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
        }
    }
    [IconMaker]::RefreshFolder($folder)
}

# ---------------------------------------------------------------------------
# Self-test (no GUI, no network): draw an image, convert, apply, verify
# ---------------------------------------------------------------------------
if ($SelfTest) {
    Add-Type -AssemblyName System.Drawing
    $testDir = Join-Path $env:TEMP ("CustomIconTest_" + [DateTime]::Now.Ticks)
    New-Item -ItemType Directory -Path $testDir | Out-Null
    try {
        # draw a fake "generated" image: white bg + colored circle
        $bmp = New-Object System.Drawing.Bitmap(512, 512)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::White)
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::OrangeRed)
        $g.FillEllipse($brush, 80, 80, 352, 352)
        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $imgBytes = $ms.ToArray()
        $bmp.Dispose()

        $ico = [IconMaker]::MakeIco($imgBytes, $true)
        if ($ico.Length -lt 1000) { throw "ICO too small: $($ico.Length)" }
        if ($ico[2] -ne 1 -or $ico[4] -ne 5) { throw "Bad ICO header" }

        Set-FolderIcon $testDir $ico
        $icoFile = Get-ChildItem -LiteralPath $testDir -Filter 'CustomIcon_*.ico' -Force
        $ini = Get-Content -LiteralPath (Join-Path $testDir 'desktop.ini') -Force
        if (-not $icoFile) { throw 'ico not written' }
        if (-not ($ini -match 'IconResource=CustomIcon_')) { throw 'desktop.ini missing IconResource' }

        # verify the ICO loads back as a real icon
        $loaded = New-Object System.Drawing.Icon((Join-Path $testDir $icoFile.Name))
        $loaded.Dispose()

        Remove-FolderIcon $testDir
        if (Get-ChildItem -LiteralPath $testDir -Force) { throw 'cleanup left files behind' }

        Write-Output "SELFTEST PASS (ico size: $($ico.Length) bytes, 5 sizes embedded)"
    } finally {
        Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------
if (-not $Folder -or -not (Test-Path -LiteralPath $Folder -PathType Container)) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("Custom Icon must be launched on a folder.`n`nUsage: CustomIcon.ps1 -Folder <path>", 'Custom Icon') | Out-Null
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$cfg = Load-Config
$script:LastIcoBytes = $null

$form               = New-Object System.Windows.Forms.Form
$form.Text          = 'Custom Icon'
$form.ClientSize    = New-Object System.Drawing.Size(560, 420)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox   = $false
$form.StartPosition = 'CenterScreen'
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)

$lblFolder          = New-Object System.Windows.Forms.Label
$lblFolder.Text     = "Folder:  $Folder"
$lblFolder.Location = New-Object System.Drawing.Point(12, 10)
$lblFolder.Size     = New-Object System.Drawing.Size(536, 18)
$lblFolder.AutoEllipsis = $true

$lblDesc            = New-Object System.Windows.Forms.Label
$lblDesc.Text       = 'Describe the icon (type / style / subject):'
$lblDesc.Location   = New-Object System.Drawing.Point(12, 36)
$lblDesc.Size       = New-Object System.Drawing.Size(280, 18)

$txtDesc            = New-Object System.Windows.Forms.TextBox
$txtDesc.Multiline  = $true
$txtDesc.Location   = New-Object System.Drawing.Point(12, 56)
$txtDesc.Size       = New-Object System.Drawing.Size(260, 70)

$lblProv            = New-Object System.Windows.Forms.Label
$lblProv.Text       = 'Image provider:'
$lblProv.Location   = New-Object System.Drawing.Point(12, 136)
$lblProv.Size       = New-Object System.Drawing.Size(100, 18)

$cmbProv            = New-Object System.Windows.Forms.ComboBox
$cmbProv.DropDownStyle = 'DropDownList'
[void]$cmbProv.Items.AddRange(@('Pollinations (free, no key)', 'OpenAI', 'Gemini'))
$cmbProv.Location   = New-Object System.Drawing.Point(112, 132)
$cmbProv.Size       = New-Object System.Drawing.Size(160, 24)
switch ("$($cfg.provider)".ToLower()) {
    'openai' { $cmbProv.SelectedIndex = 1 }
    'gemini' { $cmbProv.SelectedIndex = 2 }
    default  { $cmbProv.SelectedIndex = 0 }
}

$btnGenerate          = New-Object System.Windows.Forms.Button
$btnGenerate.Text     = 'Generate'
$btnGenerate.Location = New-Object System.Drawing.Point(12, 170)
$btnGenerate.Size     = New-Object System.Drawing.Size(125, 32)

$btnApply             = New-Object System.Windows.Forms.Button
$btnApply.Text        = 'Apply to Folder'
$btnApply.Location    = New-Object System.Drawing.Point(147, 170)
$btnApply.Size        = New-Object System.Drawing.Size(125, 32)
$btnApply.Enabled     = $false

$btnRemove            = New-Object System.Windows.Forms.Button
$btnRemove.Text       = 'Remove Custom Icon'
$btnRemove.Location   = New-Object System.Drawing.Point(12, 210)
$btnRemove.Size       = New-Object System.Drawing.Size(125, 32)

$btnSettings          = New-Object System.Windows.Forms.Button
$btnSettings.Text     = 'Settings...'
$btnSettings.Location = New-Object System.Drawing.Point(147, 210)
$btnSettings.Size     = New-Object System.Drawing.Size(125, 32)

$picPreview             = New-Object System.Windows.Forms.PictureBox
$picPreview.Location    = New-Object System.Drawing.Point(288, 56)
$picPreview.Size        = New-Object System.Drawing.Size(256, 256)
$picPreview.SizeMode    = 'Zoom'
$picPreview.BorderStyle = 'FixedSingle'
$picPreview.BackColor   = [System.Drawing.Color]::FromArgb(245, 245, 245)

$lblStatus            = New-Object System.Windows.Forms.Label
$lblStatus.Location   = New-Object System.Drawing.Point(12, 330)
$lblStatus.Size       = New-Object System.Drawing.Size(536, 80)
$lblStatus.Text       = 'Ready. Describe your icon and click Generate.'

$form.Controls.AddRange(@($lblFolder, $lblDesc, $txtDesc, $lblProv, $cmbProv,
                          $btnGenerate, $btnApply, $btnRemove, $btnSettings, $picPreview, $lblStatus))

function Set-Status([string]$msg) {
    $lblStatus.Text = $msg
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-SelectedProvider {
    switch ($cmbProv.SelectedIndex) {
        1 { 'openai' }
        2 { 'gemini' }
        default { 'pollinations' }
    }
}

$btnGenerate.Add_Click({
    $desc = $txtDesc.Text.Trim()
    if (-not $desc) { Set-Status 'Please enter a description first.'; return }
    $cfg.provider = Get-SelectedProvider
    $btnGenerate.Enabled = $false
    $btnApply.Enabled = $false
    try {
        $finalDesc = $desc
        if ("$($cfg.enhancer)" -ne 'none') {
            Set-Status "Enhancing prompt via $($cfg.enhancer)..."
            try { $finalDesc = Invoke-Enhancer $cfg $desc }
            catch { Set-Status "Enhancer failed ($($_.Exception.Message)) - using your description as-is."; $finalDesc = $desc }
        }
        Set-Status "Generating image via $($cfg.provider)... (this can take up to a minute)"
        $result = Invoke-ImageGen $cfg $finalDesc

        Set-Status 'Converting to .ico...'
        $removeBg = [bool]$cfg.remove_background -and -not $result.NativeAlpha
        $script:LastIcoBytes = [IconMaker]::MakeIco($result.Bytes, $removeBg)

        # preview: render the 256px PNG frame embedded in the ico
        $png = [IconMaker]::ExtractLargestPng($script:LastIcoBytes)
        $ms = New-Object System.IO.MemoryStream(,$png)
        $tmp = New-Object System.Drawing.Bitmap($ms)
        if ($picPreview.Image) { $picPreview.Image.Dispose() }
        $picPreview.Image = New-Object System.Drawing.Bitmap($tmp)
        $tmp.Dispose(); $ms.Dispose()

        $btnApply.Enabled = $true
        Set-Status "Done. Click 'Apply to Folder' if you like it, or Generate again for a new one."
    } catch {
        Set-Status "Error: $($_.Exception.Message)"
    } finally {
        $btnGenerate.Enabled = $true
    }
})

$btnApply.Add_Click({
    if (-not $script:LastIcoBytes) { return }
    try {
        Set-FolderIcon $Folder $script:LastIcoBytes
        Set-Status 'Icon applied! If Explorer still shows the old icon, press F5 in the folder view.'
    } catch {
        Set-Status "Error applying icon: $($_.Exception.Message)"
    }
})

$btnRemove.Add_Click({
    try {
        Remove-FolderIcon $Folder
        Set-Status 'Custom icon removed - folder is back to default.'
    } catch {
        Set-Status "Error removing icon: $($_.Exception.Message)"
    }
})

$btnSettings.Add_Click({
    $dlg               = New-Object System.Windows.Forms.Form
    $dlg.Text          = 'Custom Icon - Settings'
    $dlg.ClientSize    = New-Object System.Drawing.Size(430, 300)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox   = $false
    $dlg.MinimizeBox   = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font          = New-Object System.Drawing.Font('Segoe UI', 9)

    $fields = @(
        @{ Label = 'OpenAI API key (images + enhancer)';  Key = 'openai_api_key' },
        @{ Label = 'Gemini API key (images + enhancer)';  Key = 'gemini_api_key' },
        @{ Label = 'Claude API key (prompt enhancer)';    Key = 'claude_api_key' },
        @{ Label = 'DeepSeek API key (prompt enhancer)';  Key = 'deepseek_api_key' }
    )
    $y = 12
    $boxes = @{}
    foreach ($f in $fields) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $f.Label; $l.Location = New-Object System.Drawing.Point(12, $y); $l.Size = New-Object System.Drawing.Size(220, 18)
        $t = New-Object System.Windows.Forms.TextBox
        $t.Location = New-Object System.Drawing.Point(235, ($y - 2)); $t.Size = New-Object System.Drawing.Size(180, 22)
        $t.UseSystemPasswordChar = $true
        $t.Text = "$($cfg[$f.Key])"
        $dlg.Controls.AddRange(@($l, $t))
        $boxes[$f.Key] = $t
        $y += 34
    }

    $lE = New-Object System.Windows.Forms.Label
    $lE.Text = 'Prompt enhancer (rewrites your description):'
    $lE.Location = New-Object System.Drawing.Point(12, $y); $lE.Size = New-Object System.Drawing.Size(220, 18)
    $cE = New-Object System.Windows.Forms.ComboBox
    $cE.DropDownStyle = 'DropDownList'
    [void]$cE.Items.AddRange(@('none', 'claude', 'deepseek', 'openai', 'gemini'))
    $cE.Location = New-Object System.Drawing.Point(235, ($y - 2)); $cE.Size = New-Object System.Drawing.Size(180, 22)
    $idx = $cE.Items.IndexOf("$($cfg.enhancer)".ToLower())
    if ($idx -lt 0) { $idx = 0 }
    $cE.SelectedIndex = $idx
    $dlg.Controls.AddRange(@($lE, $cE))
    $y += 34

    $chkBg = New-Object System.Windows.Forms.CheckBox
    $chkBg.Text = 'Make icon background transparent (auto-remove solid background)'
    $chkBg.Location = New-Object System.Drawing.Point(12, $y); $chkBg.Size = New-Object System.Drawing.Size(410, 22)
    $chkBg.Checked = [bool]$cfg.remove_background
    $dlg.Controls.Add($chkBg)
    $y += 40

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Save'; $btnOk.Location = New-Object System.Drawing.Point(235, $y); $btnOk.Size = New-Object System.Drawing.Size(85, 28)
    $btnOk.DialogResult = 'OK'
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'; $btnCancel.Location = New-Object System.Drawing.Point(330, $y); $btnCancel.Size = New-Object System.Drawing.Size(85, 28)
    $btnCancel.DialogResult = 'Cancel'
    $dlg.Controls.AddRange(@($btnOk, $btnCancel))
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel

    if ($dlg.ShowDialog($form) -eq 'OK') {
        foreach ($k in $boxes.Keys) { $cfg[$k] = $boxes[$k].Text.Trim() }
        $cfg.enhancer          = $cE.SelectedItem
        $cfg.remove_background = $chkBg.Checked
        $cfg.provider          = Get-SelectedProvider
        Save-Config $cfg
        Set-Status 'Settings saved.'
    }
    $dlg.Dispose()
})

$form.Add_FormClosing({
    $cfg.provider = Get-SelectedProvider
    Save-Config $cfg
})

[void]$form.ShowDialog()
