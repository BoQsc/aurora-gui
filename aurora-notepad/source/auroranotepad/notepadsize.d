module auroranotepad.notepadsize;

// Windows 10 native Notepad metrics, measured live on Windows 10 22H2 at
// 120 DPI (per-monitor DPI aware) and converted to Aurora's 96-DPI logical
// units. Reference: real notepad.exe.
//
//   menu bar     20 logical px  (SM_CYMENU 25 px @120 / 1.25)
//   status bar   23 logical px  (actual msctls_statusbar32 height 29 px @120)
//   caption btn  36 logical px  (SM_CXSIZE 46 px @120)
//   caption font 12 px EM       (Segoe UI 9 pt)
//   status font  12 px EM       (Segoe UI 9 pt)
enum NotepadMenuBarHeight = 20;
enum NotepadStatusBarHeight = 23;
enum NotepadCaptionButtonWidth = 36;
enum NotepadTitleBarHeight = 28;
enum NotepadStatusFontPixelSize = 12;
enum NotepadMenuFontPixelSize = 12;
