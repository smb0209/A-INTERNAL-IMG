/* A-INTERNAL-IMG slideshow: images(crossfade) + videos(fullscreen) - MSX video plugin */
/* 리눅스 판(linux/signage.mjs) 사본. server.ps1 안의 것과 다른 점 3가지:
   1) 1분마다 목록을 다시 읽어, 바뀌었으면 처음부터 다시 튼다. 영상이 1개면 loop라 ended가 안 와서
      아침 동기화로 바뀐 영상이 TV를 다시 켜기 전까지 안 나오던 문제를 막는다.
   2) 영상 오류 뒤 3초 쉬고 넘어간다. 서버가 잠깐 꺼졌을 때 요청이 쉬지 않고 반복되던 것을 막는다.
   3) 목록을 ../list.json(상대 주소)으로 읽는다. /<채널>/plugins/slideshow.html 에서 열려 /<채널>/list.json 이 된다. */
function SlideshowPlayer() {
    var items = [];
    var fadeMs = 2000;
    var idx = 0;
    var front = 0;
    var layers = [];
    var player = null;   // 콘텐츠 영상 엘리먼트
    var keep = null;     // 화면보호기 억제용 영상
    var videoOn = false; // 콘텐츠 영상을 트는 중이면 keep 을 다시 켜지 않는다 (삼성은 영상 2개를 같이 못 틀어 본 영상이 멈춤)
    var timer = null;
    var pollTimer = null;
    var POLL_MS = 60000;
    function listSig(list) {
        var s = "";
        for (var k = 0; k < list.length; k++) { s += (list[k].type || "") + "|" + (list[k].url || "") + "\n"; }
        return s;
    }
    function pollList() {
        var before = listSig(items);
        fetchList(function() {
            if (listSig(items) !== before) { idx = 0; playCurrent(); }
        });
    }
    function applyFade() {
        var t = "opacity " + fadeMs + "ms ease-in-out";
        for (var k = 0; k < layers.length; k++) {
            if (layers[k]) { layers[k].style.transition = t; layers[k].style.webkitTransition = t; }
        }
    }
    function keepPlay() { try { if (keep) { var p = keep.play(); if (p && p.catch) p.catch(function(){}); } } catch (e) {} }
    function keepStop() { try { if (keep) keep.pause(); } catch (e) {} }
    function keepLoop() { if (!videoOn) { keepPlay(); } setTimeout(keepLoop, 5000); }
    function clearTimer() { if (timer) { clearTimeout(timer); timer = null; } }
    function fetchList(cb) {
        try {
            var xhr = new XMLHttpRequest();
            xhr.open("GET", "../list.json?t=" + (new Date().getTime()), true);
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
            videoOn = true;
            keepStop();
            player.style.display = "block";
            player.loop = (items.length === 1);
            player.src = it.url;
            var p = player.play(); if (p && p.catch) p.catch(function(){});
            // 여러 개면 onended 에서 advance (loop=true면 ended 안 옴)
        } else {
            // 이미지: 크로스페이드
            videoOn = false;
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
        // 삼성(Tizen)은 비디오를 하드웨어 오버레이 평면에 그려 CSS opacity/z-index 합성이 안 먹는다.
        // 전체화면 keep 영상이 불투명 검정으로 화면 전체를 덮어 검정화면이 됨 -> 삼성은 1px 구석으로 치운다.
        // webOS(LG)는 인식률 때문에 전체화면 유지(기존 동작).
        try {
            var ua = (navigator.userAgent || "");
            var isTizen = /Tizen|SMART-TV|SamsungBrowser/i.test(ua) && !/Web0S|webOS/i.test(ua);
            if (isTizen && keep) {
                keep.style.width = "2px"; keep.style.height = "2px";
                keep.style.top = "auto"; keep.style.left = "auto";
                keep.style.right = "0"; keep.style.bottom = "0";
                keep.style.zIndex = "0"; keep.style.opacity = "0";
                keep.style.objectFit = "cover";
            }
        } catch (e) {}
        if (player) {
            player.onended = function() { advance(); };
            player.onerror = function() { clearTimer(); timer = setTimeout(advance, 3000); };
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
            if (!pollTimer) { pollTimer = setInterval(pollList, POLL_MS); }
        });
    };
    function stopPoll() { if (pollTimer) { clearInterval(pollTimer); pollTimer = null; } }
    this.dispose = function() { clearTimer(); stopPoll(); };
    this.play = function() {};
    this.pause = function() {};
    this.stop = function() { clearTimer(); stopPoll(); };
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
