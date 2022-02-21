
@echo OFF

@REM https://aticleworld.com/batch-file-variables-and-scope/
SETLOCAL

@REM https://stackoverflow.com/questions/3827567/how-to-get-the-path-of-the-batch-script-in-windows
@REM get the directory the script is in
SET script_dir=%~dp0
@REM remove trailing backslash
SET script_dir=%script_dir:~0,-1%

@REM dev specific configuration
@REM 'windows' (or 'linux' or 'osx', although running batch scripts on anything but windows doesn't "just work" I think)
SET platform=%1
@REM 'src' (for now), 'out/src/debug' or 'out/src/release'
SET dir_with_phobos_files=%2
@REM main file relative to root
SET relative_main=%3

@REM get all positional arguments past the first 3 to pass them along
@REM SHIFT 3, SHIFT /N 3, SHIFT /n 3 and SHIFT /3 didn't work for some reason
SHIFT
SHIFT
SHIFT
@REM this doesn't affect %* however, and I only found "the hard way" to work around this:
@REM https://stackoverflow.com/questions/4871620/how-to-pass-multiple-params-in-batch
@REM specifically: https://stackoverflow.com/a/4871831
@REM although their version of it is broken. I fixed the loop and the check for empty strings

SET PARAMS=

:_PARAMS_LOOP

@REM https://exceptionshub.com/what-is-the-proper-way-to-test-if-variable-is-empty-in-a-batch-file.html
IF [%1]==[] GOTO _PARAMS_DONE

SET PARAMS=%PARAMS% %1
SHIFT

GOTO _PARAMS_LOOP

:_PARAMS_DONE


@REM configuration
SET root=%script_dir%\..\%dir_with_phobos_files%
SET c_lib_root=%script_dir%\..\bin\%platform%
SET c_lib_extension=.dll
SET main_filename=%root%\%relative_main%

@REM run
"%script_dir%\..\bin\%platform%\lua" -- "%script_dir%\..\%dir_with_phobos_files%\entry_point.lua"^
  "%root%" "%c_lib_root%" "%c_lib_extension%" "%main_filename%"%PARAMS%
@REM %PARAMS% has a leading space

ENDLOCAL

@echo ON
