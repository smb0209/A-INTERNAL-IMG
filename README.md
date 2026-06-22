# A-INTERNAL-IMG

매장 LG TV(webOS)에 **PC HDMI 연결 없이** 광고 슬라이드쇼를 띄우기 위한 로컬 사이니지 서버.

같은 LAN의 윈도우 PC가 로컬 HTTP 서버로 이미지와 `menu.json`을 제공하고,
LG TV의 **Media Station X(MSX)** 앱이 그걸 받아 자동 재생/전환/무한반복합니다.
외부 인터넷이 아닌 **공유기 내부망 속도**로 받아오므로 대용량 이미지도 끊김 없이 재생됩니다.

```
[LG TV - MSX 앱]  ──(공유기 내부망)──►  [매장 PC - A-INTERNAL-IMG.exe]
                                            └ C:\adImg\img\ 의 이미지를
                                              이름순 슬라이드쇼로 제공
```

## 빠른 시작 (매장 PC)

1. **GitHub Releases** 에서 `A-INTERNAL-IMG.exe` 다운로드 (또는 Actions 빌드 아티팩트).
2. exe를 바탕화면에 두고 **더블 클릭** (관리자 권한 자동 요청 → "예").
3. 처음 실행하면 `C:\adImg\img` 폴더가 생성됩니다. 여기에 광고 이미지를 넣으세요.
   - 재생 순서는 **파일 이름순**입니다. → `01_main.jpg`, `02_event.jpg` 처럼 숫자를 앞에 붙이세요.
   - 권장 포맷: 화면 해상도에 맞춰 리사이즈한 **WebP/JPG** (장당 수백 KB).
4. 검은 콘솔 창에 표시되는 주소를 확인합니다:
   `http://<자동감지된 IP>:8080/menu.json`
   **이 창은 닫지 마세요.** (서버가 떠 있어야 함)

## LG TV 설정 (최초 1회)

1. TV에서 **Media Station X** 앱 실행
2. **Settings → Start Parameter → Setup**
3. 위에서 확인한 주소 입력: `http://192.168.x.x:8080/menu.json`
4. 슬라이드쇼가 자동 재생됩니다. 무한 반복을 위해 플레이어 옵션에서 **Repeat** 를 한 번 켜 주세요.

이미지 교체는 `C:\adImg\img` 폴더에 파일을 넣고/빼기만 하면 됩니다.
서버 재시작 없이 다음 루프에서 자동 반영됩니다(요청마다 폴더를 다시 스캔).

## 동작 방식 (기술 메모)

- 슬라이드쇼는 MSX의 **image-plugin** 액션으로 구현:
  `video:plugin:.../image.html?url=<이미지URL>&duration=10`
  → 이미지 N초 노출 후 자동으로 다음으로 전환. (정적 `type:list` 메뉴로는 자동전환이 안 됨)
- `menu.json` 은 **요청마다 동적 생성** (폴더 스캔 → 이름순 정렬).
- Windows 7 / PowerShell 2.0 호환 (`ConvertTo-Json` 미사용, 수동 JSON 생성).
- `HttpListener` 의 LAN 바인딩 때문에 **관리자 권한 필요** → exe가 자동 승격(UAC).
- LAN IP 자동 감지, CORS 허용, MIME Content-Type 지정.

## 소스에서 직접 실행 (개발)

`server.ps1` 과 `run.bat` 을 같은 폴더에 두고 `run.bat` 더블 클릭.

설정값은 `server.ps1` 상단에서 변경:

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `$Port` | `8080` | 서버 포트 |
| `$ImgDir` | `C:\adImg\img` | 광고 이미지 폴더 |
| `$Duration` | `10` | 이미지 1장당 노출 시간(초) |

## 빌드 (GitHub Actions)

`main` 푸시 / `v*` 태그 / 수동 실행 시 windows 러너에서 `server.ps1` 을
**PS2EXE** 로 단일 `A-INTERNAL-IMG.exe` 로 컴파일합니다.

- 일반 빌드 → Actions 실행 페이지의 **Artifacts** 에서 다운로드
- `v1.0.0` 등 **태그 푸시** → **Releases** 에 exe 자동 첨부 (직접 다운로드 링크)

## 비고 / 한계

- MSX의 image-plugin HTML(`msx.benzac.de`)을 TV가 로드하므로 **플러그인 자체 로딩에는 인터넷이 한 번 필요**합니다. (이미지 본체는 로컬 LAN에서 받음)
  완전 오프라인이 필요하면 플러그인 HTML을 로컬에 번들하는 방식으로 확장 가능.
- 영상(`.mp4` 등)도 폴더에 넣으면 재생 목록에 포함됩니다.
