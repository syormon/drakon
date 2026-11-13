# Decode every GIF under $Root with Windows' GDI+ decoder and dump raw 32bpp ARGB pixels
# (BGRA byte order) to $Out\<n>.bgra, with an index file of: n|relative path|width|height
param([string]$Root, [string]$Out)
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$index = New-Object System.Collections.Generic.List[string]
$n = 0
Get-ChildItem -Path $Root -Recurse -Filter *.gif | Sort-Object FullName | ForEach-Object {
    $n++
    $bmp = New-Object System.Drawing.Bitmap $_.FullName
    try {
        $rect = New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                              [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $rowBytes = $bmp.Width * 4
        $bytes = New-Object byte[] ($rowBytes * $bmp.Height)
        for ($y = 0; $y -lt $bmp.Height; $y++) {
            $src = [IntPtr]::Add($data.Scan0, $y * $data.Stride)
            [System.Runtime.InteropServices.Marshal]::Copy($src, $bytes, $y * $rowBytes, $rowBytes)
        }
        $bmp.UnlockBits($data)
        [System.IO.File]::WriteAllBytes((Join-Path $Out "$n.bgra"), $bytes)
        $rel = $_.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/')
        $index.Add("$n|$rel|$($bmp.Width)|$($bmp.Height)")
    } finally {
        $bmp.Dispose()
    }
}
[System.IO.File]::WriteAllLines((Join-Path $Out "index.txt"), $index)
"$n GIFs decoded"
