@echo off
title PhoneRemote
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PhoneRemote.ps1" %*
if errorlevel 1 pause
