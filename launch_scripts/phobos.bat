
@echo OFF

@REM https://aticleworld.com/batch-file-variables-and-scope/
SETLOCAL

@REM https://stackoverflow.com/questions/3827567/how-to-get-the-path-of-the-batch-script-in-windows
@REM get the directory the script is in
SET script_dir=%~dp0
@REM remove trailing backslash
SET script_dir=%script_dir:~0,-1%

@REM configuration
SET root=%script_dir%
SET c_lib_root=%script_dir%\bin
SET c_lib_extension=.dll
SET main_filename=%root%\main.lua

@REM run
"%script_dir%\bin\lua" -- "%script_dir%\entry_point.lua"^
  "%root%" "%c_lib_root%" "%c_lib_extension%" "%main_filename%" %*

ENDLOCAL

@echo ON
