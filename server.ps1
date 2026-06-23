# ============================================================================
#  A-INTERNAL-IMG  -  LG webOS (Media Station X) Local Signage Server
# ----------------------------------------------------------------------------
#  - C:\adImg\img 폴더의 이미지/동영상을 이름순으로 스캔
#  - MSX image-plugin 기반 "자동 재생 + 자동 전환" 슬라이드쇼 menu.json 생성
#  - 같은 LAN의 LG TV(MSX 앱)가 로컬 PC에서 초고속으로 콘텐츠를 받아감
#  - Windows 7 / PowerShell 2.0 호환 (ConvertTo-Json 미사용)
# ============================================================================

# ----- 설정 ----------------------------------------------------------------
$Version   = "1.3.1"
$Port      = 8080
$BaseDir   = "C:\adImg"           # 작업 루트 (절대경로 고정)
$ImgDir    = "C:\adImg\img"       # 광고 이미지/영상 폴더
$Duration  = 10                   # 이미지 1장당 노출 시간(초)
$PluginUrl = "http://msx.benzac.de/plugins/image.html"
$ImgExt    = @(".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp")
$VidExt    = @(".mp4", ".mov", ".m4v", ".webm")

# 구글 드라이브 공개 폴더 동기화 설정 (시작 시 1회)
$DriveFolderId  = "1ig4Q-vAs_Gh-PqlBCGkaeB2B0zO9kwrx"  # 공유 폴더 링크의 folders/ 뒤 ID
$BackupKeepDays = 7                                      # 백업(img_backup_*) 보관일수
$MaxImageWidth  = 1920                                   # 이미지 가로 최대폭(px) - TV 디코딩 부담 완화 (0=축소안함)
$UseLocalPlugin = $true                                  # 이미지 플러그인을 로컬 서버에서 제공(사설→사설, 오프라인)
$UseCrossfade   = $true                                  # 자체 슬라이드쇼(크로스페이드). transition.txt 에 none 이면 끔
$FadeMs         = 2000                                   # 크로스페이드 시간(ms) - fade.txt로 조절

# ----- 0. 설정 오버라이드 (exe 옆 config.txt) -----------------------------
# 위 기본값을 config.txt 로 덮어쓸 수 있음. 한 PC에서 폴더별로 exe+config.txt 를
# 따로 두면 Port/BaseDir/DriveFolderId 가 다른 인스턴스를 여러 개 돌릴 수 있다.
# config.txt 예) 한 줄에 key=value (대소문자 무관, # 는 주석):
#   Port=8081
#   BaseDir=C:\adImg2
#   DriveFolderId=다른_폴더_ID
#   Duration=8
#   FadeMs=2500
$ExeDir = $null
try {
    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($exePath -and ($exePath -notlike "*powershell*")) { $ExeDir = Split-Path $exePath -Parent }
} catch {}
if (-not $ExeDir) {
    try { $ExeDir = Split-Path $MyInvocation.MyCommand.Definition -Parent } catch {}
}
$cfgFile = $null
if ($args.Count -ge 1 -and (Test-Path $args[0])) { $cfgFile = $args[0] }
elseif ($ExeDir -and (Test-Path "$ExeDir\config.txt")) { $cfgFile = "$ExeDir\config.txt" }
if ($cfgFile) {
    Write-Host "설정 파일 적용: $cfgFile" -ForegroundColor Cyan
    foreach ($line in (Get-Content $cfgFile)) {
        $t = $line.Trim()
        if ($t -eq "" -or $t.StartsWith("#")) { continue }
        $kv = $t -split "=", 2
        if ($kv.Count -ne 2) { continue }
        $k = $kv[0].Trim().ToLower(); $v = $kv[1].Trim()
        switch ($k) {
            "port"           { if ($v -match '^\d+$') { $Port = [int]$v } }
            "basedir"        { if ($v -ne "") { $BaseDir = $v } }
            "drivefolderid"  { $DriveFolderId = $v }
            "duration"       { if ($v -match '^\d+$') { $Duration = [int]$v } }
            "fadems"         { if ($v -match '^\d+$') { $FadeMs = [int]$v } }
            "maximagewidth"  { if ($v -match '^\d+$') { $MaxImageWidth = [int]$v } }
            "backupkeepdays" { if ($v -match '^\d+$') { $BackupKeepDays = [int]$v } }
            "usecrossfade"   { $UseCrossfade = ($v -match '^(1|true|yes|on)$') }
        }
    }
}
$ImgDir = "$BaseDir\img"   # 이미지 폴더는 항상 BaseDir 하위

# ----- 1. 관리자 권한 자동 승격 -------------------------------------------
# HttpListener 가 LAN IP(http://+:포트)에 바인딩하려면 관리자 권한이 필요함.
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}
if (-not (Test-Admin)) {
    Write-Host "관리자 권한으로 다시 실행합니다..." -ForegroundColor Yellow
    try {
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exe -like "*powershell*") {
            $script = $MyInvocation.MyCommand.Definition
            Start-Process powershell -Verb RunAs `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
        } else {
            # ps2exe 로 컴파일된 단일 실행파일(.exe)인 경우
            Start-Process $exe -Verb RunAs
        }
    } catch {
        Write-Host "관리자 권한 승격 실패. 파일을 우클릭 후 '관리자 권한으로 실행' 하세요." -ForegroundColor Red
        Start-Sleep -Seconds 5
    }
    exit
}

# ----- 2. 폴더 준비 + 포트 점유 프로세스 정리 -----------------------------
if (-not (Test-Path $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir | Out-Null }
if (-not (Test-Path $ImgDir))  { New-Item -ItemType Directory -Path $ImgDir | Out-Null }

Write-Host "[1/3] 포트 $Port 점유 프로세스 정리..." -ForegroundColor Cyan
$lines = netstat -ano | Select-String (":" + $Port + " ")
foreach ($line in $lines) {
    $parts = ($line.ToString().Trim() -split "\s+")
    $procId = $parts[$parts.Length - 1]
    if ($procId -match "^\d+$" -and $procId -ne "0" -and [int]$procId -ne $PID) {
        try {
            Stop-Process -Id ([int]$procId) -Force -ErrorAction SilentlyContinue
            Write-Host ("    이전 프로세스 종료 (PID: {0})" -f $procId) -ForegroundColor Yellow
        } catch {}
    }
}
Start-Sleep -Seconds 1

# ----- 3. 로컬 LAN IP 자동 감지 -------------------------------------------
function Get-LocalIP {
    $addrs = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName())
    $v4 = @()
    foreach ($a in $addrs) {
        if ($a.AddressFamily -eq "InterNetwork" -and $a.IPAddressToString -ne "127.0.0.1") {
            $v4 += $a.IPAddressToString
        }
    }
    $prefer = $v4 | Where-Object { $_ -like "192.168.*" } | Select-Object -First 1
    if ($prefer) { return $prefer }
    if ($v4.Count -gt 0) { return $v4[0] }
    return "127.0.0.1"
}
$IP = Get-LocalIP

# ----- 3.5 구글 드라이브 공개 폴더 동기화 (시작 시 1회) -------------------
# 동작: 임시폴더에 전부 받음 -> 전부 성공하면 기존 img를 백업으로 돌리고 교체.
#       (다운로드 중 인터넷이 끊겨도 기존 img/화면은 그대로 유지됨)
#       7일 지난 백업(img_backup_*)은 삭제.
# 4K 등 대형 이미지를 TV가 디코딩하다 실패하지 않도록 가로폭 기준 축소(JPEG 재저장).
# System.Drawing(GDI+) 사용. 실패하면 원본을 그대로 둔다.
function Resize-ImageFile($path, $maxW) {
    if (-not $maxW -or $maxW -le 0) { return }
    try { Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue } catch {}
    $img = $null; $bmp = $null; $g = $null
    try {
        $img = [System.Drawing.Image]::FromFile($path)
        if ($img.Width -le $maxW) { $img.Dispose(); return }
        $nw = [int]$maxW
        $nh = [int][Math]::Round($img.Height * ($maxW / $img.Width))
        $bmp = New-Object System.Drawing.Bitmap($nw, $nh)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($img, 0, 0, $nw, $nh)
        $g.Dispose(); $g = $null
        $img.Dispose(); $img = $null   # 원본 핸들 해제 후 같은 경로에 덮어쓰기

        $jpg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
               Where-Object { $_.MimeType -eq "image/jpeg" } | Select-Object -First 1
        $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
            [System.Drawing.Imaging.Encoder]::Quality, [long]85)
        $bmp.Save($path, $jpg, $ep)
        $bmp.Dispose(); $bmp = $null
        Write-Host ("        축소 적용 -> {0}px" -f $nw) -ForegroundColor DarkGray
    } catch {
        if ($g)   { try { $g.Dispose() }   catch {} }
        if ($img) { try { $img.Dispose() } catch {} }
        if ($bmp) { try { $bmp.Dispose() } catch {} }
        Write-Host "        (이미지 축소 실패 - 원본 사용)" -ForegroundColor DarkGray
    }
}

function Sync-FromDrive {
    if (-not $DriveFolderId) { return }

    # 윈도우7/구버전 .NET 에서도 구글(HTTPS, TLS1.2) 접속이 되도록 강제
    try { [System.Net.ServicePointManager]::SecurityProtocol = `
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}

    $listUrl = "https://drive.google.com/embeddedfolderview?id=$DriveFolderId#list"
    Write-Host "[2/3] 구글 드라이브 폴더 동기화 시도..." -ForegroundColor Cyan

    # --- 폴더 목록(이름+ID) 가져오기 ---
    $html = $null
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $wc.Headers.Add("User-Agent", "Mozilla/5.0")
        $html = $wc.DownloadString($listUrl)
    } catch {
        Write-Host "    드라이브 접속 실패(오프라인?) -> 기존 이미지로 재생합니다." -ForegroundColor Yellow
        return
    }

    $entries = [regex]::Matches($html, 'id="entry-([^"]+)"[\s\S]*?flip-entry-title">([^<]+)')
    $files = @()
    foreach ($m in $entries) {
        $id   = $m.Groups[1].Value
        $name = $m.Groups[2].Value.Trim()
        $ext  = [System.IO.Path]::GetExtension($name).ToLower()
        if (($ImgExt -contains $ext) -or ($VidExt -contains $ext)) {
            $files += New-Object PSObject -Property @{ Id = $id; Name = $name }
        }
    }

    if ($files.Count -eq 0) {
        Write-Host "    드라이브에서 이미지를 찾지 못함 -> 기존 이미지 유지." -ForegroundColor Yellow
        return
    }
    Write-Host ("    드라이브 파일 {0}개 발견. 다운로드 시작..." -f $files.Count)

    # --- 임시 폴더에 전부 다운로드 ---
    $stamp  = Get-Date -Format "yyyyMMdd_HHmmss"
    $tmpDir = Join-Path $BaseDir ("img_tmp_" + $stamp)
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    $ok = 0
    foreach ($f in $files) {
        $dest = Join-Path $tmpDir $f.Name
        $dlUrl = "https://drive.google.com/uc?export=download&id=" + $f.Id
        try {
            $dwc = New-Object System.Net.WebClient
            $dwc.Headers.Add("User-Agent", "Mozilla/5.0")
            $dwc.DownloadFile($dlUrl, $dest)
            if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) {
                $ok++
                $ext = [System.IO.Path]::GetExtension($f.Name).ToLower()
                if ($ImgExt -contains $ext) { Resize-ImageFile $dest $MaxImageWidth }
                Write-Host ("      OK  {0}" -f $f.Name) -ForegroundColor DarkGray
            }
        } catch {
            Write-Host ("      실패 {0}" -f $f.Name) -ForegroundColor Red
        }
    }

    # --- 전부 받았을 때만 교체 (아니면 임시폴더 폐기, 기존 유지) ---
    if ($ok -eq $files.Count -and $ok -gt 0) {
        if (Test-Path $ImgDir) {
            $backup = Join-Path $BaseDir ("img_backup_" + $stamp)
            try { Rename-Item -Path $ImgDir -NewName $backup -Force } catch {}
        }
        try {
            Rename-Item -Path $tmpDir -NewName "img" -Force
            Write-Host ("    동기화 완료: 이미지 {0}개 적용." -f $ok) -ForegroundColor Green
        } catch {
            Write-Host "    교체 실패 -> 기존 이미지 유지." -ForegroundColor Red
        }
    } else {
        Write-Host ("    일부만 받음({0}/{1}) -> 적용 취소, 기존 이미지 유지." -f $ok, $files.Count) -ForegroundColor Yellow
        try { Remove-Item -Path $tmpDir -Recurse -Force } catch {}
    }

    # --- 7일 지난 백업 정리 ---
    try {
        $cutoff = (Get-Date).AddDays(-1 * $BackupKeepDays)
        Get-ChildItem -Path $BaseDir | Where-Object {
            $_.PSIsContainer -and $_.Name -like "img_backup_*" -and $_.LastWriteTime -lt $cutoff
        } | ForEach-Object {
            Remove-Item -Path $_.FullName -Recurse -Force
            Write-Host ("    오래된 백업 삭제: {0}" -f $_.Name) -ForegroundColor DarkGray
        }
    } catch {}
}
# 동기화에서 무슨 일이 나도 서버는 반드시 기동 -> 기존 오프라인 이미지로 계속 재생
try { Sync-FromDrive } catch {
    Write-Host "    동기화 중 예외 발생 -> 기존 이미지로 계속 진행합니다." -ForegroundColor Yellow
}
# 주의: Ensure-Plugin 호출은 함수 정의 이후(파일 하단)에서 수행한다. (PS는 위->아래 실행)

# ----- 4. menu.json 동적 생성 (윈도우7 PS2.0 호환: 수동 JSON) -------------
function Json-Escape($s) {
    $s = $s -replace "\\", "\\"
    $s = $s -replace '"', '\"'
    $s = $s -replace "`r", ""
    $s = $s -replace "`n", "\n"
    $s = $s -replace "`t", "\t"
    return $s
}

# 슬라이드 1장당 노출 시간(초). C:\adImg\duration.txt 있으면 그 값. 요청마다 읽음(재시작 불필요).
function Get-SlideDuration {
    $dur = $Duration
    $durFile = "$BaseDir\duration.txt"
    if (Test-Path $durFile) {
        try {
            $v = ((Get-Content $durFile -ErrorAction Stop)[0]).Trim()
            if ($v -match '^\d+$' -and [int]$v -gt 0) { $dur = [int]$v }
        } catch {}
    }
    return $dur
}

# 크로스페이드 시간(ms). C:\adImg\fade.txt 있으면 그 값(요청마다 읽음).
function Get-Fade {
    $ms = $FadeMs
    $ff = "$BaseDir\fade.txt"
    if (Test-Path $ff) {
        try {
            $v = ((Get-Content $ff -ErrorAction Stop)[0]).Trim()
            if ($v -match '^\d+$' -and [int]$v -ge 0) { $ms = [int]$v }
        } catch {}
    }
    return $ms
}

# 전환 모드: 기본 fade(크로스페이드). C:\adImg\transition.txt 에 none/simple 이면 기존 방식으로 복귀.
function Get-Transition {
    $t = "fade"
    $tf = "$BaseDir\transition.txt"
    if (Test-Path $tf) {
        try {
            $v = ((Get-Content $tf -ErrorAction Stop)[0]).Trim().ToLower()
            if ($v -eq "none" -or $v -eq "simple" -or $v -eq "off") { $t = "none" }
        } catch {}
    }
    return $t
}

# 슬라이드쇼 플러그인용 재생목록(이미지+영상, 상대경로). 이름순.
function Build-ListJson {
    $dur = Get-SlideDuration
    $items = @()
    if (Test-Path $ImgDir) {
        $all = Get-ChildItem -Path $ImgDir | Where-Object { -not $_.PSIsContainer } | Sort-Object Name
        foreach ($f in $all) {
            $ext = $f.Extension.ToLower()
            $u = "/img/" + [System.Uri]::EscapeDataString($f.Name)
            if ($ImgExt -contains $ext) {
                $items += '{"type":"image","url":"' + $u + '","duration":' + $dur + '}'
            } elseif ($VidExt -contains $ext) {
                $items += '{"type":"video","url":"' + $u + '"}'
            }
        }
    }
    return '{"fade":' + (Get-Fade) + ',"items":[' + ($items -join ',') + ']}'
}

$script:PlayerProps = @"
"properties": {
        "control:type": "extended",
        "control:load": "silent",
        "control:return": "silent",
        "button:play_pause:display": "false",
        "button:content:display": "false",
        "button:restart:display": "false",
        "button:prev:display": "false",
        "button:next:display": "false",
        "button:stop:display": "false",
        "button:speed:display": "false",
        "button:rotate:display": "false",
        "button:zoom:display": "false"
      }
"@

function Build-MenuJson($HostBase) {
    # $HostBase : TV가 실제로 접속한 host:port (예: 192.168.22.111:8080)
    if (-not $HostBase) { $HostBase = "$IP`:$Port" }

    $dur = Get-SlideDuration

    # --- 크로스페이드 모드: 자체 슬라이드쇼 플러그인 1개로 모든 이미지 순환(깜빡임 없음) ---
    if ($UseCrossfade -and $script:SlideshowReady -and ((Get-Transition) -eq "fade")) {
        $shAction = Json-Escape ("video:plugin:http://$HostBase/plugins/slideshow.html")
        return @"
{
  "name": "A-INTERNAL-IMG",
  "version": "1.0.0",
  "type": "list",
  "headline": "Store Signage (crossfade)",
  "action": "$shAction",
  "items": [
    {
      "title": "Slideshow",
      "playerLabel": "Slideshow",
      "action": "$shAction",
      $script:PlayerProps
    }
  ]
}
"@
    }

    # --- 기존(per-image) 방식: 이미지마다 image-plugin (transition.txt=none 또는 슬라이드쇼 미준비) ---
    # 로컬 플러그인이 준비됐으면 사설 출처에서 제공(차단 우회), 아니면 외부 fallback
    if ($script:PluginReady) { $pluginBase = "http://$HostBase/plugins/image.html" }
    else                     { $pluginBase = $PluginUrl }

    # 이미지/영상 파일을 이름순으로 스캔 (숫자 prefix 권장: 01_, 02_ ...)
    $all = @()
    if (Test-Path $ImgDir) {
        $all = Get-ChildItem -Path $ImgDir |
               Where-Object { -not $_.PSIsContainer } |
               Sort-Object Name
    }

    $items = @()
    $firstAction = $null
    $count = 0
    foreach ($f in $all) {
        $ext = $f.Extension.ToLower()
        $isImg = $ImgExt -contains $ext
        $isVid = $VidExt -contains $ext
        if (-not ($isImg -or $isVid)) { continue }

        $fileUrl = "http://$HostBase/img/" + [System.Uri]::EscapeDataString($f.Name)

        if ($isImg) {
            $enc    = [System.Uri]::EscapeDataString($fileUrl)
            $action = "video:plugin:$pluginBase`?url=$enc&duration=$dur"
        } else {
            $action = "video:$fileUrl"
        }

        $title  = Json-Escape $f.BaseName
        $aEsc   = Json-Escape $action
        $imgEsc = Json-Escape $fileUrl

        if ($null -eq $firstAction) { $firstAction = $aEsc }

        $items += @"
    {
      "title": "$title",
      "titleFooter": "$([int]$count + 1)",
      "image": "$imgEsc",
      "playerLabel": "$title",
      "action": "$aEsc",
      $script:PlayerProps
    }
"@
        $count++
    }

    $itemsJson = ($items -join ",`r`n")
    $headline  = "Store Signage ($count items)"
    if ($count -eq 0) {
        $headline  = "C:\adImg\img 폴더에 이미지를 넣어주세요"
        $rootAction = "null"
    } else {
        $rootAction = '"' + $firstAction + '"'
    }

    return @"
{
  "name": "A-INTERNAL-IMG",
  "version": "1.0.0",
  "type": "list",
  "headline": "$headline",
  "action": $rootAction,
  "template": {
    "type": "separate",
    "layout": "0,0,8,1",
    "color": "msx-glass"
  },
  "items": [
$itemsJson
  ]
}
"@
}

# 이미지 플러그인 파일을 로컬에 캐시(없으면 다운로드). 모두 준비되면 $script:PluginReady=$true.
# 공개 출처(msx.benzac.de) 플러그인이 사설 이미지를 못 그리는 webOS 제약을 우회하려고
# 플러그인을 우리 서버(사설 출처)에서 직접 제공한다. 한 번 받아두면 완전 오프라인.
$script:PluginReady = $false
$script:SlideshowReady = $false
function Ensure-Plugin {
    if (-not $UseLocalPlugin) { return }
    $files = @(
        @{ Url = "http://msx.benzac.de/plugins/image.html";          Path = "$BaseDir\plugins\image.html" },
        @{ Url = "http://msx.benzac.de/plugins/css/common.css";      Path = "$BaseDir\plugins\css\common.css" },
        @{ Url = "http://msx.benzac.de/plugins/js/image.js";         Path = "$BaseDir\plugins\js\image.js" },
        @{ Url = "http://msx.benzac.de/js/jquery.min.js";            Path = "$BaseDir\js\jquery.min.js" },
        @{ Url = "http://msx.benzac.de/js/tvx-plugin-ux.min.js";     Path = "$BaseDir\js\tvx-plugin-ux.min.js" }
    )
    try { [System.Net.ServicePointManager]::SecurityProtocol = `
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}
    $allOk = $true
    foreach ($f in $files) {
        if (Test-Path $f.Path) { continue }   # 이미 캐시됨
        $dir = Split-Path $f.Path -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "Mozilla/5.0")
            $wc.DownloadFile($f.Url, $f.Path)
        } catch {
            if (-not (Test-Path $f.Path)) { $allOk = $false }
        }
    }
    if ($allOk -and (Test-Path "$BaseDir\plugins\image.html")) {
        $script:PluginReady = $true
        Write-Host "    이미지 플러그인 로컬 준비 완료 (오프라인 가능)." -ForegroundColor DarkGray
    } else {
        Write-Host "    플러그인 로컬 캐시 실패 -> 외부(msx.benzac.de) 플러그인 사용." -ForegroundColor Yellow
    }

    # --- 자체 크로스페이드 슬라이드쇼 플러그인 파일 생성 (jquery+tvx 가 있어야 동작) ---
    $haveLibs = (Test-Path "$BaseDir\js\jquery.min.js") -and (Test-Path "$BaseDir\js\tvx-plugin-ux.min.js")
    try {
        $shHtml = @'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8" />
<title>A-INTERNAL-IMG Slideshow</title>
<style>
html,body{margin:0;padding:0;width:100%;height:100%;background:#000;overflow:hidden}
#keep{position:absolute;top:0;left:0;width:100%;height:100%;object-fit:cover;z-index:9999;opacity:0.02;pointer-events:none}
#a,#b{position:absolute;top:0;left:0;right:0;bottom:0;background-color:#000;z-index:1;
background-position:center center;background-repeat:no-repeat;background-size:contain;
opacity:0;-webkit-transition:opacity 2s ease-in-out;transition:opacity 2s ease-in-out}
#a.show,#b.show{opacity:1}
#player{position:absolute;top:0;left:0;width:100%;height:100%;background:#000;z-index:5;display:none;object-fit:contain}
</style>
<script type="text/javascript" src="../js/jquery.min.js"></script>
<script type="text/javascript" src="../js/tvx-plugin-ux.min.js"></script>
<script type="text/javascript" src="js/slideshow.js"></script>
</head>
<body>
<video id="keep" autoplay loop muted playsinline webkit-playsinline src="keep.mp4"></video>
<div id="a"></div>
<div id="b"></div>
<video id="player" playsinline webkit-playsinline></video>
</body>
</html>
'@
        $shJs = @'
/* A-INTERNAL-IMG slideshow: images(crossfade) + videos(fullscreen) - MSX video plugin */
function SlideshowPlayer() {
    var items = [];
    var fadeMs = 2000;
    var idx = 0;
    var front = 0;
    var layers = [];
    var player = null;   // 콘텐츠 영상 엘리먼트
    var keep = null;     // 화면보호기 억제용 영상
    var timer = null;
    function applyFade() {
        var t = "opacity " + fadeMs + "ms ease-in-out";
        for (var k = 0; k < layers.length; k++) {
            if (layers[k]) { layers[k].style.transition = t; layers[k].style.webkitTransition = t; }
        }
    }
    function keepPlay() { try { if (keep) { var p = keep.play(); if (p && p.catch) p.catch(function(){}); } } catch (e) {} }
    function keepStop() { try { if (keep) keep.pause(); } catch (e) {} }
    function keepLoop() { keepPlay(); setTimeout(keepLoop, 5000); }
    function clearTimer() { if (timer) { clearTimeout(timer); timer = null; } }
    function fetchList(cb) {
        try {
            var xhr = new XMLHttpRequest();
            xhr.open("GET", "/list.json?t=" + (new Date().getTime()), true);
            xhr.onreadystatechange = function() {
                if (xhr.readyState === 4) {
                    if (xhr.status === 200) {
                        try {
                            var d = JSON.parse(xhr.responseText);
                            if (d.items) { items = d.items; }
                            if (typeof d.fade === "number" && d.fade >= 0) { fadeMs = d.fade; applyFade(); }
                        } catch (e) {}
                    }
                    if (cb) { cb(); }
                }
            };
            xhr.send();
        } catch (e) { if (cb) { cb(); } }
    }
    function preload(url, cb) {
        var im = new Image();
        im.onload = function() { cb(); };
        im.onerror = function() { cb(); };
        im.src = url;
    }
    function showImage(url) {
        var back = 1 - front;
        layers[back].style.backgroundImage = "url('" + url + "')";
        layers[back].className = "show";
        layers[front].className = "";
        front = back;
    }
    function hidePlayer() {
        try { if (player) { player.pause(); player.removeAttribute("src"); player.load(); player.style.display = "none"; } } catch (e) {}
    }
    function playCurrent() {
        clearTimer();
        if (items.length === 0) { timer = setTimeout(function(){ fetchList(playCurrent); }, 3000); return; }
        var it = items[idx];
        if (it && it.type === "video") {
            // 콘텐츠 영상: 전체화면 재생 -> 화면보호기 억제 + 4K 네이티브. 단일이면 무한 loop.
            keepStop();
            player.style.display = "block";
            player.loop = (items.length === 1);
            player.src = it.url;
            var p = player.play(); if (p && p.catch) p.catch(function(){});
            // 여러 개면 onended 에서 advance (loop=true면 ended 안 옴)
        } else {
            // 이미지: 크로스페이드
            hidePlayer();
            keepPlay();
            var dur = (it && it.duration && it.duration > 0) ? it.duration * 1000 : 10000;
            preload(it.url, function() { showImage(it.url); timer = setTimeout(advance, dur); });
        }
    }
    function advance() {
        clearTimer();
        if (items.length === 0) { fetchList(playCurrent); return; }
        var n = idx + 1;
        if (n >= items.length) {
            // 한 바퀴 끝 -> 목록 갱신(추가/삭제 자동 반영) 후 처음부터
            fetchList(function() { idx = 0; playCurrent(); });
            return;
        }
        idx = n;
        playCurrent();
    }
    this.init = function() {
        layers = [document.getElementById("a"), document.getElementById("b")];
        player = document.getElementById("player");
        keep = document.getElementById("keep");
        if (player) {
            player.onended = function() { advance(); };
            player.onerror = function() { advance(); };
        }
        applyFade();
        keepLoop();
    };
    this.ready = function() {
        TVXVideoPlugin.startLoading();
        TVXVideoPlugin.setDuration(0);
        TVXVideoPlugin.disableProgressMarker();
        fetchList(function() {
            TVXVideoPlugin.stopLoading();
            TVXVideoPlugin.startPlayback();
            idx = 0;
            playCurrent();
        });
    };
    this.dispose = function() { clearTimer(); };
    this.play = function() {};
    this.pause = function() {};
    this.stop = function() { clearTimer(); };
    this.getDuration = function() { return 0; };
    this.getPosition = function() { return 0; };
    this.setPosition = function(p) {};
    this.getSpeed = function() { return 1; };
    this.setSpeed = function(s) {};
    this.setSize = function(w, h) {};
    this.getUpdateData = function() { return { position: 0, duration: 0, speed: 1 }; };
    this.handleEvent = function(data) { TVXPluginTools.handleSettingsEvent(data); };
    this.handleData = function(data) {};
}
TVXPluginTools.onReady(function() {
    TVXVideoPlugin.setupPlayer(new SlideshowPlayer());
    TVXVideoPlugin.init();
});
'@
        if (-not (Test-Path "$BaseDir\plugins\js")) { New-Item -ItemType Directory -Path "$BaseDir\plugins\js" -Force | Out-Null }
        [System.IO.File]::WriteAllText("$BaseDir\plugins\slideshow.html", $shHtml, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText("$BaseDir\plugins\js\slideshow.js", $shJs, (New-Object System.Text.UTF8Encoding($false)))
        # 화면보호기 억제용 작은 무음 루프 비디오 (webOS는 "비디오 재생 중"일 때만 화면보호기 억제)
        $keepB64 = "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XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXgAAAAhBmjgf4AOEYAAAAAhBmlQH+ADhGAAAAAhBmmA/wAcIwAAAAAhBmoA/wAcIwAAAAAhBmqA/wAcIwAAAAAhBmsA/wAcIwAAAAAhBmuA/wAcIwAAAAAhBmwA/wAcIwAAAAAhBmyA/wAcIwAAAAAhBm0A/wAcIwAAAAAhBm2A/wAcIwAAAAAhBm4A/wAcIwAAAAAhBm6A/wAcIwAAAAAhBm8A/wAcIwAAAAAhBm+A/wAcIwAAAAAhBmgA/wAcIwAAAAAhBmiA/wAcIwAAAAAhBmkA/wAcIwAAAAAhBmmA/wAcIwAAAAAhBmoA/wAcIwAAAAAhBmqA/wAcIwAAAAAhBmsA/wAcIwAAAAAhBmuA/wAcIwAAAAAhBmwA/wAcIwAAAAAhBmyA/wAcIwAAAAAhBm0A/wAcIwAAAAAhBm2A/wAcIwAAAAAhBm4A/wAcIwAAAAAhBm6A/wAcIwAAAAAhBm8A/wAcIwAAAAAhBm+A/wAcIwAAAAAhBmgA/wAcIwAAAAAhBmiA/wAcIwAAAAAhBmkA/wAcIwAAAAAhBmmA/wAcIwAAAAAhBmoA/wAcIwAAAAAhBmqA/wAcIwAAAAAhBmsA/wAcIwAAAAAhBmuA/wAcIwAAAAAhBmwA7wAcIwAAAAAhBmyA3wAcIwA=="
        try { [System.IO.File]::WriteAllBytes("$BaseDir\plugins\keep.mp4", [System.Convert]::FromBase64String($keepB64)) } catch {}
        if ($haveLibs) {
            $script:SlideshowReady = $true
            Write-Host "    크로스페이드 슬라이드쇼 준비 완료." -ForegroundColor DarkGray
        }
    } catch {
        Write-Host ("    슬라이드쇼 파일 생성 실패: " + $_.Exception.Message) -ForegroundColor Yellow
    }
}
# 이제 함수가 정의됐으니 호출 (사설 출처 플러그인 제공 + 오프라인)
Write-Host "[2.5/3] 이미지 플러그인 로컬 캐시 확인..." -ForegroundColor Cyan
try { Ensure-Plugin } catch { Write-Host ("    Ensure-Plugin 예외: " + $_.Exception.Message) -ForegroundColor Yellow }

# MSX Start Object: /msx/start.json 응답. parameter 가 실제 콘텐츠(menu.json)를 가리킨다.
function Build-StartJson($HostBase) {
    if (-not $HostBase) { $HostBase = "$IP`:$Port" }
    return @"
{
  "name": "A-INTERNAL-IMG",
  "version": "1.0.0",
  "parameter": "content:http://$HostBase/menu.json",
  "welcome": "none"
}
"@
}

# ----- 5. CORS 허용 로컬 HTTP 서버 구동 ------------------------------------
function Get-ContentType($path) {
    switch -Regex ($path.ToLower()) {
        "\.json$"        { return "application/json; charset=utf-8" }
        "\.(jpg|jpeg)$"  { return "image/jpeg" }
        "\.png$"         { return "image/png" }
        "\.webp$"        { return "image/webp" }
        "\.gif$"         { return "image/gif" }
        "\.bmp$"         { return "image/bmp" }
        "\.mp4$"         { return "video/mp4" }
        "\.(mov|m4v)$"   { return "video/quicktime" }
        "\.webm$"        { return "video/webm" }
        "\.html?$"       { return "text/html; charset=utf-8" }
        "\.css$"         { return "text/css; charset=utf-8" }
        "\.js$"          { return "application/javascript; charset=utf-8" }
        default          { return "application/octet-stream" }
    }
}

# ----- 매장 PC 절전/화면보호기 방지 (서버 24시간 가동) --------------------
# PC가 자버리면 서버가 죽어 TV 재생이 끊김. SetThreadExecutionState 로 깨어있게 고정.
try {
    Add-Type -Namespace Win32 -Name PowerUtil -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@ -ErrorAction SilentlyContinue
    # ES_CONTINUOUS(0x80000000) | ES_SYSTEM_REQUIRED(0x1) | ES_DISPLAY_REQUIRED(0x2)
    [Win32.PowerUtil]::SetThreadExecutionState([uint32]2147483651) | Out-Null
    Write-Host "    절전/화면보호기 방지 활성화 (PC 24시간 가동)." -ForegroundColor DarkGray
} catch {
    Write-Host "    절전 방지 설정 실패(무시 가능) - PC 전원 옵션을 '절전 안 함'으로 두세요." -ForegroundColor DarkGray
}

# ----- 방화벽 인바운드 허용 (TV/다른 PC 접속용) ---------------------------
# 관리자 권한으로 실행 중이므로 시작 시 자동으로 방화벽 규칙을 추가한다.
Write-Host "[3/3] 방화벽 인바운드 허용 (TCP $Port)..." -ForegroundColor Cyan
try {
    & netsh advfirewall firewall delete rule name="A-INTERNAL-IMG $Port" 2>$null | Out-Null
    & netsh advfirewall firewall add rule name="A-INTERNAL-IMG $Port" dir=in action=allow protocol=TCP localport=$Port 2>$null | Out-Null
    Write-Host "    방화벽 규칙 적용 완료." -ForegroundColor DarkGray
} catch {
    Write-Host "    방화벽 자동설정 실패 -> 수동으로 $Port 포트 인바운드를 허용하세요." -ForegroundColor Yellow
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")
try {
    $listener.Start()
} catch {
    Write-Host "서버 시작 실패: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "파일을 우클릭 -> '관리자 권한으로 실행' 후 다시 시도하세요." -ForegroundColor Red
    Start-Sleep -Seconds 8
    exit
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "  A-INTERNAL-IMG 사이니지 서버 실행 중 (v$Version)" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "  이미지 폴더 : $ImgDir"
Write-Host "  LG TV(MSX) Start Parameter 에 입력할 주소 :" -ForegroundColor Yellow
Write-Host "    $IP`:$Port" -ForegroundColor White
Write-Host "    (슬래시 없이 호스트:포트만. MSX가 /msx/start.json 을 자동 요청함)"
Write-Host "  요청 로그 파일 : $BaseDir\access.log"
Write-Host "--------------------------------------------------"
Write-Host "  이 창을 닫지 마세요. 종료하려면 Ctrl+C." -ForegroundColor Cyan
Write-Host ""

$logPath = Join-Path $BaseDir "access.log"
function Write-Log($msg) {
    $line = "[" + (Get-Date -Format "HH:mm:ss") + "] " + $msg
    Write-Host $line -ForegroundColor Gray
    try { [System.IO.File]::AppendAllText($logPath, $line + "`r`n", [System.Text.Encoding]::UTF8) } catch {}
}

while ($listener.IsListening) {
    try {
        $context  = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response

        $response.Headers.Add("Access-Control-Allow-Origin", "*")
        $response.Headers.Add("Access-Control-Allow-Methods", "GET, OPTIONS")

        $localPath = $request.Url.LocalPath
        $method    = $request.HttpMethod
        $hostBase  = $request.UserHostName            # TV가 접속한 host:port
        if (-not $hostBase) { $hostBase = "$IP`:$Port" }
        $remote    = $request.RemoteEndPoint
        $kind      = ""

        if ($method -eq "OPTIONS") {
            $response.StatusCode = 200
            $response.Close()
            Write-Log ("$method $localPath  <- $remote  (CORS preflight)")
            continue
        }

        # 동적 엔드포인트(start/menu)는 디스크 파일보다 우선해서 항상 새로 생성한다.
        # (이전 버전이 남긴 낡은 menu.json 이 정적 파일로 나가던 버그 방지)
        $isStart = ($localPath -match "start\.json$" -or $localPath -match "^/msx")
        $isMenu  = ($localPath -eq "/" -or $localPath -match "menu\.json$")
        $isList  = ($localPath -match "list\.json$")

        $bytes = $null
        $ctype = "application/json; charset=utf-8"

        # 1) MSX 시작 파일 -> Start Object
        if ($isStart) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes((Build-StartJson $hostBase))
            $kind = "START.JSON"
        }
        # 1.5) 슬라이드쇼 이미지 목록
        elseif ($isList) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes((Build-ListJson))
            $kind = "LIST.JSON"
        }
        # 2) 슬라이드쇼 content (항상 동적 생성, Host 기반 URL)
        elseif ($isMenu) {
            $json  = Build-MenuJson $hostBase
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            try { [System.IO.File]::WriteAllText("$BaseDir\menu.debug.json", $json, [System.Text.Encoding]::UTF8) } catch {}
            $kind = "MENU.JSON"
        }
        else {
            # 3) 실제 파일(이미지/영상) 서빙 - 영상은 Range(206) 스트리밍 지원
            $candidate = Join-Path $BaseDir $localPath.TrimStart("/")
            if (Test-Path $candidate -PathType Leaf) {
                $fs = $null
                try {
                    $fs = [System.IO.File]::OpenRead($candidate)
                    $total = $fs.Length
                    $start = [int64]0
                    $end   = [int64]($total - 1)
                    $partial = $false
                    $rh = $request.Headers["Range"]
                    if ($rh -and ($rh -match "bytes=(\d*)-(\d*)")) {
                        if ($matches[1] -ne "") { $start = [int64]$matches[1] }
                        if ($matches[2] -ne "") { $end   = [int64]$matches[2] }
                        if ($end -gt $total - 1) { $end = [int64]($total - 1) }
                        if ($start -lt 0 -or $start -gt $end) { $start = [int64]0 }
                        $partial = $true
                    }
                    # 단일스레드 서버가 한 영상에 오래 묶이지 않게 응답당 최대 4MB
                    $maxChunk = [int64]4194304
                    if (($end - $start + 1) -gt $maxChunk) { $end = $start + $maxChunk - 1; $partial = $true }
                    $len = $end - $start + 1

                    $response.ContentType = Get-ContentType $candidate
                    $response.SendChunked = $false
                    $response.Headers.Add("Accept-Ranges", "bytes")
                    if ($partial) {
                        $response.StatusCode = 206
                        $response.Headers.Add("Content-Range", "bytes $start-$end/$total")
                    }
                    $response.ContentLength64 = $len
                    $fs.Seek($start, [System.IO.SeekOrigin]::Begin) | Out-Null
                    $buf = New-Object byte[] 65536
                    $left = $len
                    while ($left -gt 0) {
                        $toRead = [int][Math]::Min([int64]$buf.Length, $left)
                        $r = $fs.Read($buf, 0, $toRead)
                        if ($r -le 0) { break }
                        $response.OutputStream.Write($buf, 0, $r)
                        $left -= $r
                    }
                    $fs.Close(); $fs = $null
                    $response.Close()
                    Write-Log ("$method $localPath  <- $remote  -> $($response.StatusCode) FILE " + (Split-Path $candidate -Leaf) + " ($start-$end/$total)")
                } catch {
                    if ($fs) { try { $fs.Close() } catch {} }
                    try { $response.Close() } catch {}   # 영상 탐색 중 연결 끊김은 정상
                }
                continue
            } else {
                # 미지의 경로도 메뉴로 폴백
                $bytes = [System.Text.Encoding]::UTF8.GetBytes((Build-MenuJson $hostBase))
                $kind = "MENU.JSON (fallback $localPath)"
            }
        }

        # 중요: TV(MSX) 웹뷰 호환을 위해 chunked 대신 Content-Length 명시.
        # (Content-Length 없는 chunked 응답은 일부 webOS 이미지 디코더가 못 읽음)
        $response.ContentType    = $ctype
        $response.SendChunked    = $false
        $response.ContentLength64 = $bytes.Length
        $response.OutputStream.Write($bytes, 0, $bytes.Length)
        $response.Close()
        Write-Log ("$method $localPath  <- $remote  -> 200 $kind ($($bytes.Length)b)")
    } catch {
        try { Write-Log ("ERROR: " + $_.Exception.Message) } catch {}
    }
}
