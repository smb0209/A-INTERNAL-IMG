# A-INTERNAL-IMG

매장 TV(LG webOS / 삼성 Tizen)에 **PC HDMI 연결 없이** 광고 슬라이드쇼를 띄우는 로컬 사이니지 서버.

같은 공유기(LAN)에 연결된 윈도우 PC가 로컬 HTTP 서버로 이미지·영상과 재생목록을 제공하고,
TV의 **Media Station X(MSX)** 앱이 그걸 받아 **자동 재생 / 크로스페이드 전환 / 무한 반복**합니다.
외부 인터넷이 아닌 **내부망 속도**로 받아오므로 대용량 4K 콘텐츠도 끊김 없이 재생됩니다.

```text
[TV - MSX 앱]  ──(공유기 내부망)──►  [매장 PC - A-INTERNAL-IMG]
                                        ├ 구글 드라이브에서 이미지/영상 자동 동기화
                                        └ C:\adImg\img 의 콘텐츠를 이름순으로 제공
```

광고 교체는 **구글 드라이브 공유 폴더만 수정** → 매장 PC에서 프로그램을 다시 켜면 반영됩니다.
한 번 받아두면 **인터넷이 끊겨도 하루종일 오프라인 재생**됩니다.

---

## 빠른 시작 (매장 PC)

> 백신이 exe를 오탐(false positive)하므로 **스크립트 zip 사용을 권장**합니다.

1. 아래 zip 다운로드 (로그인 불필요):
   ```text
   https://github.com/smb0209/A-INTERNAL-IMG/releases/latest/download/A-INTERNAL-IMG-script.zip
   ```
2. 압축 해제 → 안의 `run.bat` `server.ps1` `config.example.txt` 를 **같은 폴더**에 둠
3. **`run.bat` 더블 클릭** → 관리자 권한 요청에 **"예"**
4. 검은 콘솔 창에 표시되는 주소 확인:
   `http://<자동감지 IP>:8080`  ← **이 창은 닫지 마세요.** (서버가 떠 있어야 함)

> 단일 파일을 원하면 `A-INTERNAL-IMG.exe` 도 릴리스에 있습니다. (단, 백신 오탐 시 예외 추가 필요)

## TV 설정 (최초 1회)

1. TV 앱스토어에서 **Media Station X** 설치 → 실행 (LG·삼성 모두 지원)
2. **Settings → Start Parameter → Setup**
3. 주소 입력: **`192.168.x.x:8080`** (콘솔에 표시된 IP)
   - MSX 앱은 슬래시(`/`) 입력이 안 되므로 **호스트:포트만** 넣으면 됩니다. `http://`·`/menu.json` 불필요.

여러 대 TV는 모두 같은 주소를 넣으면 각자 독립적으로 재생합니다.

## 화면보호기(스크린세이버) 안 뜨게 하기

webOS/Tizen 화면보호기는 **리모컨 입력이 없으면**(유휴) 켜집니다. **전체화면 비디오 재생 중일 때만** 예외로 안 뜹니다.

- **이미지 슬라이드쇼**는 OS가 "비디오 아님"으로 보므로 화면보호기가 뜰 수 있습니다 → **TV 자체 설정에서 꺼야 함**
  - LG: 설정 → 일반 → 화면보호기 / 자동 꺼짐 / 에너지 절약 끄기 (최신 webOS는 설치(1105) 메뉴 필요할 수 있음)
  - 삼성: 설정 → 일반 → 화면보호기 / 에코 솔루션 끄기
- **영상(mp4)으로 재생하면** 진짜 비디오라 화면보호기가 **원천 차단**됩니다 → 아래 "영상 재생" 참고

## 영상(mp4) 재생 — 4K · 화면보호기 해결

드라이브 폴더(또는 `C:\adImg\img`)에 **mp4**를 넣으면:

- 전체화면 **무한 루프 재생** → 화면보호기 완전 차단 ✅
- 4K mp4는 TV가 **4K 네이티브 디코딩** (서버가 영상은 줄이지 않음)
- 이미지와 섞으면 → 이미지는 크로스페이드, 영상은 전체화면 재생으로 순환

## 구글 드라이브 동기화 (시작 시 자동)

**OAuth/API 키 불필요** — 공개 공유 폴더를 그대로 사용합니다.

1. 공유 폴더 목록을 읽어 이미지/영상을 임시폴더에 **전부 다운로드**
2. **전부 성공했을 때만** 기존 `img` 를 `img_backup_<날짜시각>` 으로 백업하고 새 폴더로 **교체**
   (다운로드 중 끊기면 적용 취소 → 기존 이미지로 계속 재생, 화면 안 꺼짐)
3. **7일 지난 백업**(`img_backup_*`)은 자동 삭제
4. 대형 이미지는 가로 `MaxImageWidth`(기본 1920px)로 자동 축소

재생 순서는 **파일 이름순**이라 `1.jpg`, `2.jpg` … 또는 `01_`, `02_` 로 두세요.
지원 확장자: 이미지 `jpg/jpeg/png/webp/gif/bmp`, 영상 `mp4/mov/m4v/webm`. (그 외, 예: `.heic` 는 무시됨)

## 설정 변경 / 한 PC에서 여러 대 운영 (config.txt)

재빌드 없이 **`config.txt`** 로 기본값을 덮어씁니다. exe(또는 run.bat)와 **같은 폴더**에 두면 자동 적용.
릴리스의 `config.example.txt` 를 `config.txt` 로 이름 바꿔 사용하세요.

```ini
Port=8080
BaseDir=C:\adImg
DriveFolderId=1ig4Q-vAs_Gh-PqlBCGkaeB2B0zO9kwrx
Duration=10
FadeMs=2000
MaxImageWidth=1920
BackupKeepDays=7
```

**한 PC에서 2대 이상** (매장/드라이브/포트 분리):

```text
C:\signage1\  ->  run.bat + server.ps1 + config.txt(Port=8080, BaseDir=C:\signage1\data, DriveFolderId=AAA)
C:\signage2\  ->  run.bat + server.ps1 + config.txt(Port=8081, BaseDir=C:\signage2\data, DriveFolderId=BBB)
```

각각 실행, TV에는 `PC아이피:8080` / `PC아이피:8081` 입력. 방화벽 규칙·데이터 폴더·드라이브 동기화는 자동 분리됩니다.

### 즉시 조절 파일 (BaseDir 안에 두면 재시작 없이 다음 루프에 반영)

| 파일 | 내용 | 효과 |
|------|------|------|
| `duration.txt` | 숫자(초) | 이미지 1장당 노출 시간 |
| `fade.txt` | 숫자(ms) | 크로스페이드 시간 |
| `transition.txt` | `none` | 크로스페이드 끄고 기존(per-image) 방식으로 |

## 동작 방식 (기술 메모)

- 슬라이드쇼는 **로컬에 호스팅한 자체 플러그인**(`/plugins/slideshow.html`)으로 구현 — 두 레이어 opacity 크로스페이드 + 다음 이미지 미리로딩(깜빡임 없음), 영상은 전체화면 재생. 한 바퀴 끝나면 목록을 다시 읽어 추가/삭제 자동 반영.
- MSX 플러그인 파일(jquery, tvx-plugin-ux, image plugin)을 시작 시 **로컬로 캐시** → 공개 출처(msx.benzac.de)가 사설망 이미지를 못 그리는 webOS 제약 우회 + **완전 오프라인**. (`transition.txt=none` 이면 외부 image-plugin per-image 방식으로 폴백)
- MSX는 호스트만 입력하면 **`/msx/start.json`** 요청 → 서버가 **Start Object** 응답 → `menu.json`(content) → `list.json`(재생목록) 순으로 로드. 모든 URL은 **요청 Host 헤더** 기반이라 TV가 접속한 주소와 항상 일치.
- 응답에 **Content-Length 명시(chunked 비활성)** — 일부 webOS 디코더가 chunked 이미지를 못 읽는 문제 해결. 영상은 **HTTP Range(206) 스트리밍**(응답당 4MB 청크)으로 멀티 TV 대비.
- 드라이브 동기화: `embeddedfolderview`(목록) + `uc?export=download`(다운로드), **무인증**, TLS 1.2 강제.
- 시작 시: **관리자 권한 자동 승격(UAC)**, **방화벽 인바운드(TCP Port) 자동 허용**, **PC 절전/화면보호기 방지**(SetThreadExecutionState, 서버 24시간 가동).
- Windows 7 / PowerShell 2.0 호환 (`ConvertTo-Json` 미사용, 수동 JSON). LAN IP 자동 감지, CORS 허용.
- 모든 요청은 콘솔 + `BaseDir\access.log` 에 기록(디버깅용).

## 소스에서 직접 실행 (개발)

`server.ps1` 과 `run.bat` 을 같은 폴더에 두고 `run.bat` 더블 클릭. 기본값은 `server.ps1` 상단에서 변경.

## 빌드 (GitHub Actions)

`main` 푸시 / `v*` 태그 / 수동 실행 시 windows 러너에서:

- `server.ps1` → **PS2EXE** 로 단일 `A-INTERNAL-IMG.exe` 컴파일
- `run.bat`+`server.ps1`+`config.example.txt` → **`A-INTERNAL-IMG-script.zip`** 묶음 (백신 오탐 회피용)
- 일반 빌드 → Actions 페이지 **Artifacts**, **태그 푸시** → **Releases** 에 자동 첨부

## 비고 / 한계

- 단일 스레드 서버라 다수 TV가 **동시에 대용량 영상**을 스트리밍하면 다소 느려질 수 있음 (이미지/소수 TV는 문제 없음).
- 백신이 exe를 오탐하면 **스크립트 zip(.ps1+.bat)** 사용 또는 폴더 예외 추가.
- 구글 `embeddedfolderview` 는 폴더 파일이 수백 개 이상이면 일부만 나열될 수 있음.
