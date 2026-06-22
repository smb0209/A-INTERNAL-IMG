# ============================================================================
#  A-INTERNAL-IMG  -  LG webOS (Media Station X) Local Signage Server
# ----------------------------------------------------------------------------
#  - C:\adImg\img 폴더의 이미지/동영상을 이름순으로 스캔
#  - MSX image-plugin 기반 "자동 재생 + 자동 전환" 슬라이드쇼 menu.json 생성
#  - 같은 LAN의 LG TV(MSX 앱)가 로컬 PC에서 초고속으로 콘텐츠를 받아감
#  - Windows 7 / PowerShell 2.0 호환 (ConvertTo-Json 미사용)
# ============================================================================

# ----- 설정 ----------------------------------------------------------------
$Port      = 8080
$BaseDir   = "C:\adImg"           # 작업 루트 (절대경로 고정)
$ImgDir    = "C:\adImg\img"       # 광고 이미지/영상 폴더
$Duration  = 10                   # 이미지 1장당 노출 시간(초)
$PluginUrl = "http://msx.benzac.de/plugins/image.html"
$ImgExt    = @(".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp")
$VidExt    = @(".mp4", ".mov", ".m4v", ".webm")

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

# ----- 4. menu.json 동적 생성 (윈도우7 PS2.0 호환: 수동 JSON) -------------
function Json-Escape($s) {
    $s = $s -replace "\\", "\\"
    $s = $s -replace '"', '\"'
    $s = $s -replace "`r", ""
    $s = $s -replace "`n", "\n"
    $s = $s -replace "`t", "\t"
    return $s
}

function Build-MenuJson {
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

        $fileUrl = "http://$IP`:$Port/img/" + [System.Uri]::EscapeDataString($f.Name)

        if ($isImg) {
            $enc    = [System.Uri]::EscapeDataString($fileUrl)
            $action = "video:plugin:$PluginUrl`?url=$enc&duration=$Duration"
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
      "action": "$aEsc"
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
        default          { return "application/octet-stream" }
    }
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
Write-Host "  A-INTERNAL-IMG 로컬 사이니지 서버 실행 중" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "  이미지 폴더 : $ImgDir"
Write-Host "  LG TV(MSX) Start Parameter 주소 :" -ForegroundColor Yellow
Write-Host "    http://$IP`:$Port/menu.json" -ForegroundColor White
Write-Host "--------------------------------------------------"
Write-Host "  이 창을 닫지 마세요. 종료하려면 Ctrl+C." -ForegroundColor Cyan
Write-Host ""

while ($listener.IsListening) {
    try {
        $context  = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response

        $response.Headers.Add("Access-Control-Allow-Origin", "*")
        $response.Headers.Add("Access-Control-Allow-Methods", "GET, OPTIONS")

        if ($request.HttpMethod -eq "OPTIONS") {
            $response.StatusCode = 200
            $response.Close()
            continue
        }

        $localPath = $request.Url.LocalPath

        if ($localPath -eq "/menu.json" -or $localPath -eq "/") {
            # 매 요청마다 폴더를 다시 스캔 -> 서버 재시작 없이 이미지 교체 반영
            $json  = Build-MenuJson
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json; charset=utf-8"
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            # 디버깅용 파일도 갱신
            try { [System.IO.File]::WriteAllText("$BaseDir\menu.json", $json, [System.Text.Encoding]::UTF8) } catch {}
        } else {
            $filePath = Join-Path $BaseDir $localPath.TrimStart("/")
            if (Test-Path $filePath -PathType Leaf) {
                $bytes = [System.IO.File]::ReadAllBytes($filePath)
                $response.ContentType = Get-ContentType $filePath
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            } else {
                $response.StatusCode = 404
            }
        }
        $response.Close()
    } catch {
        # 개별 요청 오류는 무시하고 계속 서비스
    }
}
