<#
.SYNOPSIS
    Regenerates the Mail-fufu button artwork (Images\*.tga) from code.

.DESCRIPTION
    Original clean-room artwork drawn with System.Drawing; re-running the script rewrites
    all 7 TGA files (32-bit, uncompressed, type 2, top-left origin, descriptor 0x28).

    The toolbar buttons (Mark All / Clear All / Mark Page / Clear Page / Get Checked) are
    Blizzard UIPanelButtonTemplate buttons with no text: the red 3-slice plate and its
    Up / Down / Disabled / Highlight states come from the template. These images are only
    the glyph overlay drawn on top of that plate: a transparent canvas holding
    GameFontNormal-gold (255,210,0) line art with a 1 px near-black outline, plus the dark
    inset item-slot square (gold check = Mark, empty = Clear). Inbox.lua shifts the glyph
    1 px on press and desaturates it while disabled, so no Pushed / Disabled / Glow
    variants are generated.
      MarkAll, ClearAll, MarkPage, ClearPage : 64x64, shown by Inbox.lua as a 28x28 texture
          centred on the 34x34 button (inside the stretched plate's bevel); the glyph fills
          the central ~53 canvas px (~23 px on screen).
      GetChecked : 128x64, art in the top-left 112x34 at 1:1 (checked slot, arrow, and an
          empty slot that Inbox.lua fills with Blizzard's backpack icon). The slot
          coordinates are mirrored by the GC_* constants in Inbox.lua: change both.
      HistoryIcon, HistoryIconPushed : white envelope glyph for the history button.
    Optional -PreviewDir writes a PNG of each image plus a contact sheet (toolbar glyphs
    composited over a flat dark-red plate colour, and desaturated over grey, at 1x and 3x).
#>
param(
    [string]$OutDir = 'C:\Claudeprojects\wow-addons\Mail-fufu\Images',
    [string]$PreviewDir = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------- palette
function C([int]$r, [int]$g, [int]$b, [int]$a = 255) { [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }
$Pal = @{
    Gold       = C 255 210 0         # GameFontNormal (NORMAL_FONT_COLOR)
    Outline    = C 10 6 4 180        # 1 px near-black outline, ~70% alpha
    SheetFill  = C 24 4 4 150        # dark translucent paper: hides the sheets behind it
    SlotLight  = C 150 108 62
    SlotShadow = C 12 8 4
}

# ---------------------------------------------------------------- helpers
function New-Canvas([int]$w, [int]$h) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    return @{ Bmp = $bmp; G = $g }
}

function New-Pen([System.Drawing.Color]$c, [float]$w) {
    $pen = New-Object System.Drawing.Pen($c, $w)
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    return $pen
}

# ---------------------------------------------------------------- glyph primitives
# $ow = extra outline pen width (both sides together) = 2 button pixels in canvas units.

# One sheet of paper: dark translucent fill + gold outline with a dog-ear and text lines.
# $EarRatio = dog-ear size as a fraction of the width; 0 = plain rectangle (back sheets of a
# stack, whose clipped corner would otherwise read as a "C" at glyph size).
function Draw-Sheet($g, [float]$x, [float]$y, [float]$w, [float]$h, [float]$lw, [float]$ow, [int]$Lines, [float]$EarRatio = 0.32) {
    $fs = [math]::Round($w * $EarRatio)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddLines([System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF($x, $y)),
        (New-Object System.Drawing.PointF(($x + $w - $fs), $y)),
        (New-Object System.Drawing.PointF(($x + $w), ($y + $fs))),
        (New-Object System.Drawing.PointF(($x + $w), ($y + $h))),
        (New-Object System.Drawing.PointF($x, ($y + $h)))))
    $p.CloseFigure()
    $fold = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF(($x + $w - $fs), $y)),
        (New-Object System.Drawing.PointF(($x + $w - $fs), ($y + $fs))),
        (New-Object System.Drawing.PointF(($x + $w), ($y + $fs))))
    $tl = @()
    for ($i = 0; $i -lt $Lines; $i++) {
        $ly = $y + $h * (0.45 + 0.22 * $i)
        $lx2 = if ($i -eq $Lines - 1) { $x + $w * 0.55 } else { $x + $w - $lw * 2.4 }
        $tl += , @(($x + $lw * 2.4), $ly, $lx2, $ly)
    }
    # outline pass (wide dark pen), then the dark paper, then the gold pass
    $op = New-Pen $Pal.Outline ($lw + $ow)
    $g.DrawPath($op, $p); if ($fs -gt 0) { $g.DrawLines($op, $fold) }
    foreach ($l in $tl) { $g.DrawLine($op, $l[0], $l[1], $l[2], $l[3]) }
    $g.FillPath((New-Object System.Drawing.SolidBrush($Pal.SheetFill)), $p)
    $gp = New-Pen $Pal.Gold $lw
    $g.DrawPath($gp, $p); if ($fs -gt 0) { $g.DrawLines($gp, $fold) }
    foreach ($l in $tl) { $g.DrawLine($gp, $l[0], $l[1], $l[2], $l[3]) }
}

# Item-slot square: dark inset bevel (like Blizzard's slot art); optional gold check.
function Draw-Slot($g, [float]$x, [float]$y, [float]$s, [float]$bev, [bool]$Checked, [float]$checkW, [float]$ow) {
    $g.FillRectangle((New-Object System.Drawing.SolidBrush((C 0 0 0 230))), ($x - $ow / 2), ($y - $ow / 2), ($s + $ow), ($s + $ow))
    $g.FillRectangle((New-Object System.Drawing.SolidBrush($Pal.SlotLight)), $x, $y, $s, $s)
    $tri = New-Object System.Drawing.Drawing2D.GraphicsPath
    $tri.AddPolygon([System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF(($x + $s), $y)),
        (New-Object System.Drawing.PointF(($x + $s), ($y + $s))),
        (New-Object System.Drawing.PointF($x, ($y + $s)))))
    $g.FillPath((New-Object System.Drawing.SolidBrush($Pal.SlotShadow)), $tri)
    $ib = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.PointF($x, $y)), (New-Object System.Drawing.PointF(($x + $s), ($y + $s))),
        (C 66 42 24), (C 30 18 10))
    $g.FillRectangle($ib, ($x + $bev), ($y + $bev), ($s - 2 * $bev), ($s - 2 * $bev))
    if ($Checked) {
        $pts = [System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF(($x + $s * 0.20), ($y + $s * 0.52))),
            (New-Object System.Drawing.PointF(($x + $s * 0.42), ($y + $s * 0.76))),
            (New-Object System.Drawing.PointF(($x + $s * 0.86), ($y + $s * 0.14))))
        $g.DrawLines((New-Pen (C 10 6 4 230) ($checkW + $ow)), $pts)
        $g.DrawLines((New-Pen $Pal.Gold $checkW), $pts)
    }
}

# ---------------------------------------------------------------- toolbar glyphs (64x64 -> 28x28 texture)
# The 64 canvas is shown at 28 px, so 1 screen px ~ 2.29 canvas px. The layout below is in
# design units, scaled by $IconScale about its centre so the glyph (outline included) spans
# ~53 of the 64 canvas px (~23 screen px), centred on the canvas; pen widths are in design units and scale with it.
$IconScale = 0.96
function New-ToolbarIcon([int]$SheetCount, [bool]$Checked) {
    $cv = New-Canvas 64 64; $g = $cv.G
    $g.TranslateTransform(32, 32); $g.ScaleTransform($IconScale, $IconScale); $g.TranslateTransform(-30.5, -30.5)
    $lw = 4.0; $ow = 4.4
    # Sheets: inset from the LEFT bevel (art left edge ~7 canvas px, ~3.7 screen px) but bottom
    # edge on the same line as the slot (~62.4 canvas px) so both parts read bottom-justified.
    # The two parts are placed independently: sheets bottom-left, slot bottom-right.
    $base = $g.Save()
    if ($SheetCount -eq 3) { $g.TranslateTransform(0, 6) } else { $g.TranslateTransform(-4, 6) }
    if ($SheetCount -eq 3) {
        Draw-Sheet $g 23 6 18 24 $lw $ow 0 0   # back sheet, top-right; stack cascades down-left
        Draw-Sheet $g 15 12 18 24 $lw $ow 0 0
        Draw-Sheet $g 7 18 18 24 $lw $ow 0     # front sheet, bottom-left
    } else {
        Draw-Sheet $g 11 7 26 34 $lw $ow 2
    }
    $g.Restore($base)
    # Slot bottom-right justified: right/bottom edge incl. outline at ~62.5 canvas px
    # (design 36 + 24 + 2.2 -> 32 + 0.96 * (62.2 - 30.5) = 62.4).
    Draw-Slot $g 36 36 24 3 $Checked 6 $ow
    $g.Dispose()
    return $cv.Bmp
}

# ---------------------------------------------------------------- Get Checked glyph (128x64, art in 112x34, 1:1)
# Slot geometry. Mirrored by GC_SLOT_X / _Y / _SIZE / _BEVEL in Inbox.lua (the bag icon
# sits in the right-hand slot's interior): change both together.
$GcSlot = @{ Size = 22; Bevel = 2; Y = 6; LeftX = 11; RightX = 79 }
function New-GetChecked {
    $cv = New-Canvas 128 64; $g = $cv.G
    $ow = 2
    $s = $GcSlot.Size; $sy = $GcSlot.Y
    # left: checked slot
    Draw-Slot $g $GcSlot.LeftX $sy $s $GcSlot.Bevel $true 3.2 $ow
    # centre: bold gold arrow with a 1 px dark outline, centred in the gap between the slots
    $len = 32; $shaft = 4; $head = 9; $hl = 13
    $ax = [math]::Round(($GcSlot.LeftX + $s + $GcSlot.RightX) / 2 - $len / 2); $ay = $sy + $s / 2
    $arrow = New-Object System.Drawing.Drawing2D.GraphicsPath
    $arrow.AddPolygon([System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF($ax, ($ay - $shaft))),
        (New-Object System.Drawing.PointF(($ax + $len - $hl), ($ay - $shaft))),
        (New-Object System.Drawing.PointF(($ax + $len - $hl), ($ay - $head))),
        (New-Object System.Drawing.PointF(($ax + $len), $ay)),
        (New-Object System.Drawing.PointF(($ax + $len - $hl), ($ay + $head))),
        (New-Object System.Drawing.PointF(($ax + $len - $hl), ($ay + $shaft))),
        (New-Object System.Drawing.PointF($ax, ($ay + $shaft)))))
    $g.DrawPath((New-Pen $Pal.Outline (2 * $ow)), $arrow)
    $g.FillPath((New-Object System.Drawing.SolidBrush($Pal.Gold)), $arrow)
    # right: empty slot; Inbox.lua overlays Blizzard's own backpack icon (Icons/Inv_misc_bag_08)
    # on its interior (x + bevel, y + bevel, size - 2 * bevel square)
    Draw-Slot $g $GcSlot.RightX $sy $s $GcSlot.Bevel $false 0 $ow
    $g.Dispose()
    return $cv.Bmp
}

# ---------------------------------------------------------------- history envelope (64x64 for a 32x32 button)
function New-HistoryIcon([bool]$Pushed) {
    $cv = New-Canvas 64 64; $g = $cv.G
    $o = if ($Pushed) { 2 } else { 0 }
    $white = if ($Pushed) { C 200 200 200 } else { C 255 255 255 }
    $state = $g.Save()
    $g.TranslateTransform((36 + $o), (24 + $o))
    $g.RotateTransform(-28)
    $ew = 34; $eh = 22
    $env = New-Object System.Drawing.Drawing2D.GraphicsPath
    $env.AddRectangle((New-Object System.Drawing.RectangleF((-$ew / 2), (-$eh / 2), $ew, $eh)))
    $flap = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF((-$ew / 2), (-$eh / 2))),
        (New-Object System.Drawing.PointF(0, 2)),
        (New-Object System.Drawing.PointF(($ew / 2), (-$eh / 2))))
    $shadow = New-Pen (C 0 0 0 170) 6.5
    $g.DrawPath($shadow, $env); $g.DrawLines($shadow, $flap)
    $g.FillPath((New-Object System.Drawing.SolidBrush((C 0 0 0 70))), $env)
    $pen = New-Pen $white 3.2
    $g.DrawPath($pen, $env); $g.DrawLines($pen, $flap)
    $g.Restore($state)
    # speed lines trailing to the lower-left
    $lines = @(@(4, 34, 15, 28), @(7, 42, 19, 35), @(12, 49, 23, 42))
    foreach ($l in $lines) {
        $g.DrawLine($shadow, ($l[0] + $o), ($l[1] + $o), ($l[2] + $o), ($l[3] + $o))
    }
    foreach ($l in $lines) {
        $g.DrawLine($pen, ($l[0] + $o), ($l[1] + $o), ($l[2] + $o), ($l[3] + $o))
    }
    $g.Dispose()
    return $cv.Bmp
}

# ---------------------------------------------------------------- TGA writer
function Save-Tga($bmp, [string]$path) {
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $px = New-Object byte[] ($w * $h * 4)
        for ($y = 0; $y -lt $h; $y++) {
            $src = [IntPtr]::Add($data.Scan0, $y * $data.Stride)
            [System.Runtime.InteropServices.Marshal]::Copy($src, $px, $y * $w * 4, $w * 4)
        }
    } finally { $bmp.UnlockBits($data) }
    $hdr = New-Object byte[] 18
    $hdr[2] = 2
    $hdr[12] = $w -band 0xFF; $hdr[13] = ($w -shr 8) -band 0xFF
    $hdr[14] = $h -band 0xFF; $hdr[15] = ($h -shr 8) -band 0xFF
    $hdr[16] = 32
    $hdr[17] = 0x28
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Create)
    try { $fs.Write($hdr, 0, 18); $fs.Write($px, 0, $px.Length) } finally { $fs.Dispose() }
}

# ---------------------------------------------------------------- build
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }
$images = [ordered]@{}
$images['MarkAll'] = New-ToolbarIcon 3 $true
$images['ClearAll'] = New-ToolbarIcon 3 $false
$images['MarkPage'] = New-ToolbarIcon 1 $true
$images['ClearPage'] = New-ToolbarIcon 1 $false
$images['GetChecked'] = New-GetChecked
$images['HistoryIcon'] = New-HistoryIcon $false
$images['HistoryIconPushed'] = New-HistoryIcon $true

foreach ($k in $images.Keys) {
    Save-Tga $images[$k] (Join-Path $OutDir "$k.tga")
    Write-Output "wrote $k.tga ($($images[$k].Width)x$($images[$k].Height))"
}

# ---------------------------------------------------------------- previews
if ($PreviewDir) {
    if (-not (Test-Path $PreviewDir)) { New-Item -ItemType Directory -Force $PreviewDir | Out-Null }
    foreach ($k in $images.Keys) { $images[$k].Save((Join-Path $PreviewDir "$k.png"), [System.Drawing.Imaging.ImageFormat]::Png) }

    # In-game composite at 1x, matching Inbox.lua: the plate is the button rect; icon glyphs
    # are a 28x28 texture centred on the 34x34 button (3 px inset); Get Checked is the
    # 112x34 crop on a 112x34 button plus an 18x18 grey stand-in for the backpack icon in
    # the right slot's interior. $Pad px of margin shows any overhang.
    # Downscaling is bilinear, like the client; Grey desaturates (SetDesaturated(true)).
    $Pad = 2
    function Get-InGame($k, $bmp, $plate, [bool]$Grey) {
        if ($k -eq 'GetChecked') { $bw = 112; $bh = 34; $sw = 112; $sh = 34; $gx = 0; $gy = 0; $gw = 112; $gh = 34 }
        elseif ($k -like 'History*') { $bw = 32; $bh = 32; $sw = 64; $sh = 64; $gx = 0; $gy = 0; $gw = 32; $gh = 32 }
        else { $bw = 34; $bh = 34; $sw = 64; $sh = 64; $gx = 3; $gy = 3; $gw = 28; $gh = 28 }
        $one = New-Object System.Drawing.Bitmap(($bw + 2 * $Pad), ($bh + 2 * $Pad), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $og = [System.Drawing.Graphics]::FromImage($one)
        $og.Clear((C 40 32 26))
        if ($plate) { $og.FillRectangle($plate, $Pad, $Pad, $bw, $bh) }
        $og.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
        $og.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $dst = New-Object System.Drawing.Rectangle(($Pad + $gx), ($Pad + $gy), $gw, $gh)
        $ia = New-Object System.Drawing.Imaging.ImageAttributes
        if ($Grey) {
            $m = New-Object System.Drawing.Imaging.ColorMatrix
            $m.Matrix00 = 0.299; $m.Matrix01 = 0.299; $m.Matrix02 = 0.299
            $m.Matrix10 = 0.587; $m.Matrix11 = 0.587; $m.Matrix12 = 0.587
            $m.Matrix20 = 0.114; $m.Matrix21 = 0.114; $m.Matrix22 = 0.114
            $ia.SetColorMatrix($m)
        }
        $og.DrawImage($bmp, $dst, 0, 0, $sw, $sh, [System.Drawing.GraphicsUnit]::Pixel, $ia)
        if ($k -eq 'GetChecked') {
            $bi = $GcSlot.Size - 2 * $GcSlot.Bevel
            $og.FillRectangle((New-Object System.Drawing.SolidBrush((C 150 150 150))), ($Pad + $GcSlot.RightX + $GcSlot.Bevel), ($Pad + $GcSlot.Y + $GcSlot.Bevel), $bi, $bi)
        }
        $og.Dispose()
        return $one
    }
    $plateRed = New-Object System.Drawing.SolidBrush((C 150 24 24))   # ~ UI-Panel-Button-Up
    $plateGrey = New-Object System.Drawing.SolidBrush((C 72 72 72))   # ~ UI-Panel-Button-Disabled
    $sheet = New-Object System.Drawing.Bitmap(1040, 1000, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $sg = [System.Drawing.Graphics]::FromImage($sheet)
    $sg.Clear((C 40 32 26))
    $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $sg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $font = New-Object System.Drawing.Font('Segoe UI', 8)
    $y0 = 10
    foreach ($k in $images.Keys) {
        # (leading comma: keep the one-variant list nested through the if-statement's output)
        $variants = if ($k -like 'History*') { , @(, @($null, $false)) } else { @(@($plateRed, $false), @($plateGrey, $true)) }
        $x0 = 10
        foreach ($v in $variants) {
            $one = Get-InGame $k $images[$k] $v[0] $v[1]
            $sg.DrawImage($one, $x0, ($y0 + 16), $one.Width, $one.Height)
            $sg.DrawImage($one, ($x0 + $one.Width + 8), ($y0 + 16), ($one.Width * 3), ($one.Height * 3))
            $x0 += $one.Width * 4 + 30
        }
        $sg.DrawString($k, $font, [System.Drawing.Brushes]::White, 10, $y0)
        $y0 += $one.Height * 3 + 26
    }
    $sg.Dispose()
    $sheet.Save((Join-Path $PreviewDir 'contact-sheet.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Output "contact sheet: $(Join-Path $PreviewDir 'contact-sheet.png')"
}
