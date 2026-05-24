@echo off
powershell -ExecutionPolicy Bypass -NoProfile -Command "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -NoProfile -File ""%~dp0switch-version.ps1""' -Verb RunAs"
