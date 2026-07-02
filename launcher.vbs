' Custom Icon - hidden launcher (avoids a console window flash)
Dim sh, fso, scriptDir, folderPath, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)

If WScript.Arguments.Count < 1 Then
    MsgBox "Custom Icon must be launched on a folder.", vbInformation, "Custom Icon"
    WScript.Quit 1
End If
folderPath = WScript.Arguments(0)

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & _
      scriptDir & "\CustomIcon.ps1"" -Folder """ & folderPath & """"
sh.Run cmd, 0, False
