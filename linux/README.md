# A-INTERNAL-IMG 리눅스 판 (`signage.mjs`)

윈도우 `server.ps1` 이 TV(MSX)에 주던 주소를 리눅스에서 Node(의존성 없음)로 그대로 낸다.
여기에 **채널**(주소 첫 경로)이 더해져, 한 서버가 드라이브 폴더 여러 개를 각자 다른 주소로 튼다.

삼성 TV 의 MSX 는 Start Parameter 에 `/` 를 못 친다. 그래서 채널은 **호스트 첫 이름**으로도 고른다.

| TV 의 MSX Start Parameter | 트는 것 | 상태 |
|---|---|---|
| `tv.amartyyc.com` | 첫 채널 = 곰표 영상 폴더 (`11kXPX…`) | 지금 됨 |
| `img.amartyyc.com` | 기존 광고 이미지 폴더 (`1ig4Q-…`, 윈도우판 기본값) | DNS·.221 nginx·인증서 추가 뒤 |
| `tv.amartyyc.com/gompyo`, `tv.amartyyc.com/img` | 같은 채널 (`/` 를 칠 수 있는 기기용) | 지금 됨 |

채널 고르는 순서: 주소 첫 경로가 채널 이름이면 그 채널 → 아니면 호스트 첫 이름(`img.` → img, 대소문자 무관) → 아니면 첫 채널(gompyo).
start.json 이 `…/<채널>/menu.json` 을 내므로 그다음 요청부터는 경로로 간다. 호스트 이름을 다르게 쓰고 싶으면 `CHANNELS` 의 채널 이름을 그 호스트 첫 이름으로 바꾼다.

`tv.amartyyc.com` 은 .221 nginx(인터넷 입구)가 받아 mini0003(.222):8080 으로 넘긴다. 매장 어디서든 인터넷만 되면 된다.
MSX 가 경로 붙은 주소를 `…/gompyo/msx/start.json` 으로 읽든 `…/gompyo/start.json` 으로 읽든 같은 응답을 준다.

| | 윈도우 `server.ps1` | 리눅스 `signage.mjs` |
|---|---|---|
| 실행 | `run.bat` 더블 클릭, 콘솔 창 유지 | systemd `a-signage.service` |
| 드라이브 폴더 | 인스턴스당 1개 (`DriveFolderId`) | 채널마다 1개 (`CHANNELS`) |
| 드라이브 동기화 | 켤 때마다 | 매일 06:00 `a-signage-sync.timer` (꺼져 있던 시각이면 켜질 때) |
| 바뀐 영상 반영 | TV 에서 MSX 를 다시 켜야 함 (영상 1개면 loop 라 목록을 다시 안 읽음) | TV 가 1분마다 목록을 확인해 자동으로 바꿈 |
| 영상 주소 | `/img/<파일>` | `/<채널>/media/<버전>/<파일>` (버전 = 동기화 시각) |
| 이미지 축소(MaxImageWidth) | 함 | 안 함 |
| 즉시 조절 파일(duration.txt 등) | 있음 | 없음, `/etc/a-signage.env` 로 |

## 동작

- 주소 첫 경로가 `CHANNELS` 에 있는 이름이면 그 채널, 아니면 호스트 첫 이름, 아니면 첫 채널. 그래서 LAN 에서 `IP:8080` 만 넣은 TV 는 첫 채널(gompyo)을 튼다.
- `node signage.mjs --sync [채널]` 이 채널마다 드라이브 공개 폴더의 이미지·영상을 `media/<채널>/.tmp-<pid>/` 에 전부 받는다.
  - 하나라도 실패하면 버리고 그 채널의 지금 영상을 그대로 둔다. 실패마다 10초·30초 쉬고 3번까지 하고, 한 채널이라도 실패면 종료 코드 1.
  - 받은 파일이 지금 것과 같으면(sha256) 아무것도 안 바꾼다.
  - 다르면 `media/<채널>/<YYYYMMDD-HHMMSS>/` 로 옮기고 `current` 링크를 바꾼다. 버전 폴더는 채널마다 `KEEP_VERSIONS`(기본 7)개 남긴다.
  - 다운로드는 `drive.usercontent.google.com/download?...&confirm=t` 로 해서 100MB 넘는 파일의 확인 페이지를 건너뛴다. HTML 이 오면 실패로 본다.
  - `DATA_DIR/.sync.lock` 으로 동기화는 한 번에 하나만 돈다.
- 서버는 `list.json` 에 `current` 가 가리키는 버전의 주소를 낸다. TV 슬라이드쇼(`plugins/js/slideshow.js`)는 1분마다 `../list.json`(자기 채널)을 다시 읽어 주소가 바뀌면 새 영상을 처음부터 튼다.
- 화면보호기 억제용 `keep.mp4` 는 이미지를 트는 동안만 켠다. 본 영상을 트는 동안 다시 켜면 영상 두 개를 같이 못 트는 삼성(Tizen)에서 본 영상이 멈춘다 (v1.3.3 에서 고침, 윈도우판도 같음).
- 주소는 요청의 Host 와 `X-Forwarded-Proto` 로 만든다. TV 가 http 로 들어오면 http, https 면 https 주소를 준다.
- `/<채널>/media/` 는 버전 폴더의 이미지·영상만 낸다(manifest.json, .tmp 는 안 나감). 버전 주소는 7일 캐시, `current/` 주소는 매번 확인.
- MSX 라이브러리(jquery, tvx-plugin-ux)는 처음에 msx.benzac.de 에서 `DATA_DIR/js/` 로 받아 둔다. 못 받았으면 MSX 기본 플레이어로 영상만 연다(반복 보장 안 됨).
- 요청 로그는 journald: `journalctl -u a-signage`. nginx 쪽은 .221 `/var/log/nginx/tv.access.log`.

## 설치 (Ubuntu, Node 20 이상) — mini0003(.222) 에 2026-10-13 설치됨

맥에서:

```bash
cd internal-img-server
ssh mini0003 'rm -rf /tmp/a-signage && mkdir -p /tmp/a-signage'
rsync -a --exclude .DS_Store linux/ mini0003:/tmp/a-signage/
```

박스에서:

```bash
sudo useradd --system --home /opt/a-signage --shell /usr/sbin/nologin asignage
sudo install -d -o root -g root /opt/a-signage
sudo rsync -a --delete --exclude deploy --exclude README.md /tmp/a-signage/ /opt/a-signage/
sudo chown -R root:root /opt/a-signage
sudo install -d -o asignage -g asignage /var/lib/a-signage
sudo install -m 644 /tmp/a-signage/deploy/a-signage.env /etc/a-signage.env      # 채널·포트는 여기서
sudo install -m 644 /tmp/a-signage/deploy/a-signage{,-sync}.service /tmp/a-signage/deploy/a-signage-sync.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start a-signage-sync          # 처음 한 번 받기
sudo systemctl enable --now a-signage a-signage-sync.timer
sudo ufw allow from 192.168.22.221 to any port 8080 proto tcp comment 'a-signage via .221 nginx'
```

업데이트는 위 rsync 두 줄(맥, 박스의 `sudo rsync … /opt/a-signage/`) + `sudo systemctl restart a-signage`.
`plugins/` 만 바뀌었으면 재시작 없이 TV 에서 MSX 를 다시 켜면 된다.

### 인터넷 주소 (.221 nginx)

`deploy/tv.amartyyc.com.conf` 를 .221 `/etc/nginx/conf.d/` 에 두고 cert 를 받는다. 2026-10-13 설치됨 (cert 만료 2027-01-11, certbot 이 자동 갱신).
.221 변경이라 다시 할 때도 오너 승인 후에. 리포의 conf 는 certbot 이 덧붙인 443 줄까지 박스 사본과 같다(2026-10-13 대조). 그래서 .221 에 다시 올려도 443 은 그대로다.
아래는 처음 설치 때 쓴 명령이다. 그때는 443 줄이 없는 파일을 올렸으니, 인증서가 없는 새 박스라면 `# managed by Certbot` 줄을 빼고 올린다.
.221 의 nginx 공통 설정(IP 직접 접근 444, fail2ban, certbot 갱신)은 `~/a-search` 리포가 관리한다. tv vhost 는 거기에 손대지 않는다 (conf 머리말 참고).

```bash
scp linux/deploy/tv.amartyyc.com.conf minbong@192.168.22.221:/tmp/
ssh minbong@192.168.22.221 'sudo install -m 644 /tmp/tv.amartyyc.com.conf /etc/nginx/conf.d/ \
  && sudo nginx -t && sudo systemctl reload nginx \
  && sudo certbot --nginx -d tv.amartyyc.com --no-redirect --non-interactive'
```

pop/instacart vhost 와 달리 80 을 https 로 돌리지 않고, X-Frame-Options·HSTS 를 붙이지 않는다 (이유는 conf 머리말).
설치 뒤 `sudo nginx -t` 에 나오는 `protocol options redefined for 443` 경고는 instacart 와 tv 의 `listen 443` 옵션이 달라서 나오는 것으로, 무해하다.

#### img.amartyyc.com 추가 (할 일, 오너 승인 필요)

1. DNS: `img.amartyyc.com` A 레코드 → `162.157.18.82` (tv 와 같은 공인 IP).
2. .221: 박스의 `/etc/nginx/conf.d/tv.amartyyc.com.conf` 80 server 블록의 `server_name` 에 `img.amartyyc.com` 을 더하고 `sudo nginx -t && sudo systemctl reload nginx`.
3. .221: `sudo certbot --nginx --expand -d tv.amartyyc.com -d img.amartyyc.com --no-redirect --non-interactive` (한 인증서에 두 이름).
4. 끝나면 리포의 conf 를 다시 박스 사본으로 맞춘다 (`ssh minbong@192.168.22.221 'cat /etc/nginx/conf.d/tv.amartyyc.com.conf'`).
5. 확인: `curl -s http://img.amartyyc.com/msx/start.json` 의 content 가 `http://img.amartyyc.com/img/menu.json`.

## 채널 추가·변경

`/etc/a-signage.env` 의 `CHANNELS` 에 `이름:폴더ID` 를 쉼표로 더하고 `sudo systemctl restart a-signage && sudo systemctl start a-signage-sync`.
이름은 소문자·숫자·`-`·`_` (msx, plugins, js, media 는 못 씀). 폴더는 "링크가 있는 모든 사용자 보기" 공유여야 한다.

## 운영 명령

```bash
systemctl status a-signage --no-pager | head -5
systemctl list-timers a-signage-sync.timer --no-pager
journalctl -u a-signage-sync -n 30 --no-pager           # 아침 동기화 결과
sudo systemctl start a-signage-sync                      # 지금 바로 전 채널 동기화 (TV 는 1분 안에 바뀜)
curl -s localhost:8080/gompyo/list.json
readlink /var/lib/a-signage/media/gompyo/current
```

동기화 시각을 바꾸려면 `sudo systemctl edit a-signage-sync.timer` 로
`[Timer]` 에 `OnCalendar=` (빈 줄로 기존 값 지움) 다음 줄 `OnCalendar=*-*-* 05:30:00` 처럼 넣는다.
