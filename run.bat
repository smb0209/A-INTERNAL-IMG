@echo off
rem ====================================================================
rem  A-INTERNAL-IMG  -  Signage Server Launcher (source/dev)
rem  - server.ps1 이 이 .bat 와 같은 폴더에 있어야 합니다.
rem  - 단일 파일로 쓰려면 GitHub Releases 의 A-INTERNAL-IMG.exe 사용.
rem ====================================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
pause
