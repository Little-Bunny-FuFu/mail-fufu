<#
.SYNOPSIS
    Regenerates the Mail-fufu project logo (branding\mail-fufu-logo-{1024,512,256}.png).

.DESCRIPTION
    Original artwork drawn with System.Drawing in the addon's house style (see Generate-Art.ps1):
    a rounded-square crimson plate with a dark bevel, like Blizzard's red panel button, carrying
    a tilted gold (255,210,0) envelope with speed lines and a gold check-mark badge, all line
    art with a dark outline. Rendered at 1024 with anti-aliasing, then downscaled to 512 and
    256 with high-quality bicubic interpolation. Opaque background (CurseForge avatar).
    Optional -PreviewDir also writes 128 and 64 px downscales for legibility checks.
#>
param(
    [string]$OutDir = 'C:\Claudeprojects\wow-addons\Mail-fufu\branding',
    [string]$PreviewDir = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------- palette
function C([int]$r, [int]$g, [int]$b, [int]$a = 255) { [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }
$Pal = @{
    Gold      = C 255 210 0      # GameFontNormal (NORMAL_FONT_COLOR)
    Outline   = C 14 4 2 235     # dark outline under every gold stroke
    Backdrop  = C 22 8 6         # opaque canvas behind the plate
    Rim       = C 46 6 6         # dark bevel ring
    PlateTop  = C 196 34 26
    PlateBot  = C 104 10 10
    Paper     = C 60 8 6 200     # dark translucent envelope body
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

function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $d = 2 * $r
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc(($x + $w - $d), $y, $d, $d, 270, 90)
    $p.AddArc(($x + $w - $d), ($y + $h - $d), $d, $d, 0, 90)
    $p.AddArc($x, ($y + $h - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function P([float]$x, [float]$y) { New-Object System.Drawing.PointF($x, $y) }

# ---------------------------------------------------------------- plate
function Draw-Plate($g, [int]$S) {
    $m = $S * 0.035; $w = $S - 2 * $m; $r = $S * 0.17
    # dark bevel ring
    $outer = New-RoundRect $m $m $w $w $r
    $g.FillPath((New-Object System.Drawing.SolidBrush($Pal.Rim)), $outer)
    # crimson face, vertical gradient
    $b = $S * 0.035
    $face = New-RoundRect ($m + $b) ($m + $b) ($w - 2 * $b) ($w - 2 * $b) ($r - $b)
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush((P 0 ($m + $b)), (P 0 ($S - $m - $b)), $Pal.PlateTop, $Pal.PlateBot)
    $g.FillPath($grad, $face)
    # soft inner shadow at the bottom/right, highlight at the top: two offset strokes clipped to the face
    $st = $g.Save()
    $g.SetClip($face)
    $hl = New-RoundRect ($m + $b + $S * 0.012) ($m + $b + $S * 0.012) ($w - 2 * $b) ($w - 2 * $b) ($r - $b)
    $g.DrawPath((New-Pen (C 0 0 0 110) ($S * 0.03)), $hl)
    $sh = New-RoundRect ($m + $b - $S * 0.012) ($m + $b - $S * 0.012) ($w - 2 * $b) ($w - 2 * $b) ($r - $b)
    $g.DrawPath((New-Pen (C 255 150 120 70) ($S * 0.02)), $sh)
    # top gloss band
    $gl = New-Object System.Drawing.Drawing2D.LinearGradientBrush((P 0 ($m + $b)), (P 0 ($S * 0.5)), (C 255 200 180 46), (C 255 200 180 0))
    $g.FillRectangle($gl, 0, 0, $S, ($S * 0.5))
    $g.Restore($st)
    # thin dark line separating rim and face
    $g.DrawPath((New-Pen (C 10 0 0 200) ($S * 0.008)), $face)
    # faint gold hairline just inside the rim's outer edge
    $g.DrawPath((New-Pen (C 255 210 0 70) ($S * 0.004)), (New-RoundRect ($m + $S * 0.008) ($m + $S * 0.008) ($w - $S * 0.016) ($w - $S * 0.016) ($r - $S * 0.008)))
}

# ---------------------------------------------------------------- envelope + speed lines
function Draw-Envelope($g, [int]$S) {
    $k = $S / 1024.0
    $lw = 40 * $k; $ow = 30 * $k
    $ew = 490 * $k; $eh = 330 * $k
    $st = $g.Save()
    $g.TranslateTransform((600 * $k), (466 * $k))
    $g.RotateTransform(-12)
    $body = New-RoundRect (-$ew / 2) (-$eh / 2) $ew $eh (22 * $k)
    $flap = [System.Drawing.PointF[]]@((P (-$ew / 2 + 18 * $k) (-$eh / 2 + 16 * $k)), (P 0 ($eh * 0.10)), (P ($ew / 2 - 18 * $k) (-$eh / 2 + 16 * $k)))
    $lowL = [System.Drawing.PointF[]]@((P (-$ew / 2 + 22 * $k) ($eh / 2 - 22 * $k)), (P (-$ew * 0.14) ($eh * 0.02)))
    $lowR = [System.Drawing.PointF[]]@((P ($ew / 2 - 22 * $k) ($eh / 2 - 22 * $k)), (P ($ew * 0.14) ($eh * 0.02)))
    # speed lines (in the envelope's frame so they trail along its motion)
    $x0 = -$ew / 2 - 62 * $k
    $speed = @(@(($x0 - 120 * $k), (-90 * $k), $x0), @(($x0 - 175 * $k), (0 * $k), ($x0 + 8 * $k)), @(($x0 - 95 * $k), (90 * $k), $x0))
    $op = New-Pen $Pal.Outline ($lw + $ow)
    $gp = New-Pen $Pal.Gold $lw
    $thin = $lw * 0.62
    $opT = New-Pen $Pal.Outline ($thin + $ow)
    $gpT = New-Pen $Pal.Gold $thin
    foreach ($l in $speed) { $g.DrawLine($op, $l[0], $l[1], $l[2], $l[1]) }
    foreach ($l in $speed) { $g.DrawLine($gp, $l[0], $l[1], $l[2], $l[1]) }
    # drop shadow
    $ds = $g.Save(); $g.TranslateTransform((14 * $k), (18 * $k))
    $g.FillPath((New-Object System.Drawing.SolidBrush((C 0 0 0 90))), $body)
    $g.Restore($ds)
    # outline pass, body, gold pass
    $g.DrawPath($op, $body)
    $g.FillPath((New-Object System.Drawing.SolidBrush($Pal.Paper)), $body)
    $g.DrawLines($opT, $lowL); $g.DrawLines($opT, $lowR)
    $g.DrawLines($gpT, $lowL); $g.DrawLines($gpT, $lowR)
    $g.DrawLines($op, $flap)
    $g.DrawPath($gp, $body)
    $g.DrawLines($gp, $flap)
    $g.Restore($st)
}

# ---------------------------------------------------------------- check badge
function Draw-Badge($g, [int]$S) {
    $k = $S / 1024.0
    $cx = 770 * $k; $cy = 760 * $k; $r = 132 * $k
    $g.FillEllipse((New-Object System.Drawing.SolidBrush((C 0 0 0 110))), ($cx - $r + 10 * $k), ($cy - $r + 14 * $k), (2 * $r), (2 * $r))
    $g.FillEllipse((New-Object System.Drawing.SolidBrush($Pal.Outline)), ($cx - $r - 16 * $k), ($cy - $r - 16 * $k), (2 * $r + 32 * $k), (2 * $r + 32 * $k))
    $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush((P 0 ($cy - $r)), (P 0 ($cy + $r)), (C 120 14 12), (C 52 6 6))
    $g.FillEllipse($bg, ($cx - $r), ($cy - $r), (2 * $r), (2 * $r))
    $g.DrawEllipse((New-Pen $Pal.Gold (26 * $k)), ($cx - $r + 13 * $k), ($cy - $r + 13 * $k), (2 * $r - 26 * $k), (2 * $r - 26 * $k))
    $pts = [System.Drawing.PointF[]]@((P ($cx - 62 * $k) ($cy + 4 * $k)), (P ($cx - 16 * $k) ($cy + 50 * $k)), (P ($cx + 66 * $k) ($cy - 48 * $k)))
    $g.DrawLines((New-Pen $Pal.Outline (70 * $k)), $pts)
    $g.DrawLines((New-Pen $Pal.Gold (40 * $k)), $pts)
}

# ---------------------------------------------------------------- build
function Resize($src, [int]$n) {
    $dst = New-Object System.Drawing.Bitmap($n, $n, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $ia = New-Object System.Drawing.Imaging.ImageAttributes
    $ia.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)   # no dark fringe at the edges
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, $n, $n)), 0, 0, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
    $g.Dispose()
    return $dst
}

$S = 1024
$cv = New-Canvas $S $S; $g = $cv.G
$g.Clear($Pal.Backdrop)
Draw-Plate $g $S
Draw-Envelope $g $S
Draw-Badge $g $S
$g.Dispose()

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }
$png = [System.Drawing.Imaging.ImageFormat]::Png
$cv.Bmp.Save((Join-Path $OutDir 'mail-fufu-logo-1024.png'), $png)
foreach ($n in 512, 256) {
    $r = Resize $cv.Bmp $n
    $r.Save((Join-Path $OutDir "mail-fufu-logo-$n.png"), $png)
    $r.Dispose()
}
Write-Output "wrote mail-fufu-logo-{1024,512,256}.png to $OutDir"

if ($PreviewDir) {
    if (-not (Test-Path $PreviewDir)) { New-Item -ItemType Directory -Force $PreviewDir | Out-Null }
    foreach ($n in 128, 64) {
        $r = Resize $cv.Bmp $n
        $r.Save((Join-Path $PreviewDir "mail-fufu-logo-$n.png"), $png)
        $r.Dispose()
    }
    Write-Output "previews in $PreviewDir"
}
$cv.Bmp.Dispose()
