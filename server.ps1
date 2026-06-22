# ============================================================================
#  A-INTERNAL-IMG  -  LG webOS (Media Station X) Local Signage Server
# ----------------------------------------------------------------------------
#  - C:\adImg\img 폴더의 이미지/동영상을 이름순으로 스캔
#  - MSX image-plugin 기반 "자동 재생 + 자동 전환" 슬라이드쇼 menu.json 생성
#  - 같은 LAN의 LG TV(MSX 앱)가 로컬 PC에서 초고속으로 콘텐츠를 받아감
#  - Windows 7 / PowerShell 2.0 호환 (ConvertTo-Json 미사용)
# ============================================================================

# ----- 설정 ----------------------------------------------------------------
$Version   = "1.0.5"
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

# ----- 4. menu.json 동적 생성 (윈도우7 PS2.0 호환: 수동 JSON) -------------
function Json-Escape($s) {
    $s = $s -replace "\\", "\\"
    $s = $s -replace '"', '\"'
    $s = $s -replace "`r", ""
    $s = $s -replace "`n", "\n"
    $s = $s -replace "`t", "\t"
    return $s
}

function Build-MenuJson($HostBase) {
    # $HostBase : TV가 실제로 접속한 host:port (예: 192.168.22.111:8080)
    if (-not $HostBase) { $HostBase = "$IP`:$Port" }

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
        default          { return "application/octet-stream" }
    }
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

        # 1) 실제 파일(이미지/영상)이면 그 파일을 서빙
        $filePath = $null
        if ($localPath -and $localPath -ne "/") {
            $candidate = Join-Path $BaseDir $localPath.TrimStart("/")
            if (Test-Path $candidate -PathType Leaf) { $filePath = $candidate }
        }

        if ($filePath) {
            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            $response.ContentType = Get-ContentType $filePath
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            $kind = "FILE " + (Split-Path $filePath -Leaf)
        }
        # 2) MSX 가 요청하는 시작 파일 -> Start Object 반환
        elseif ($localPath -match "start\.json$" -or $localPath -match "^/msx") {
            $json  = Build-StartJson $hostBase
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json; charset=utf-8"
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            $kind = "START.JSON"
        }
        # 3) 그 외 모든 경로(/, /menu.json 등) -> 슬라이드쇼 content 반환
        else {
            $json  = Build-MenuJson $hostBase
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json; charset=utf-8"
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            try { [System.IO.File]::WriteAllText("$BaseDir\menu.json", $json, [System.Text.Encoding]::UTF8) } catch {}
            $kind = "MENU.JSON"
        }
        $response.Close()
        Write-Log ("$method $localPath  <- $remote  -> 200 $kind")
    } catch {
        try { Write-Log ("ERROR: " + $_.Exception.Message) } catch {}
    }
}
