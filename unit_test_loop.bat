@echo off
:loop
odin test protocol
if %errorlevel% equ 0 (
    echo Test passed, running again...
    goto loop
)
echo Test failed!
