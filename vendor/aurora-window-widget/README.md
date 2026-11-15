# aurora-window-widget

Standard window and control widgets for Aurora applications, built on the
bundled Aurora-D framework. The package publishes the proven framework
controls under stable names and supplies the controls the framework does not
provide.

## Modules

| Module | Contents |
| --- | --- |
| `aurorawindowwidget` | Public facade for every module below. |
| `aurorawindowwidget.window` | `Window` (native Aurora window host). |
| `aurorawindowwidget.titlebar` | `TitleBar`, `FramelessWindowTitleBar`, `StandardTitleBar`, snap preview. |
| `aurorawindowwidget.button` | `Button`, `IconButton`. |
| `aurorawindowwidget.label` | `Label`. |
| `aurorawindowwidget.layout` | `Box`, `HBox`, `VBox`, `Spacer`. |
| `aurorawindowwidget.advanced.dialog` | `Dialog` with content and action rows. |
| `aurorawindowwidget.advanced.image` | `ImageView`. |
| `aurorawindowwidget.advanced.sidebar` | `Sidebar` navigation rail. |
| `aurorawindowwidget.advanced.textbox` | `TextBox`, `MultilineTextBox`. |
| `aurorawindowwidget.advanced.tickbox` | `TickBox`. |
| `aurorawindowwidget.advanced.tooltip` | `Tooltip`. |
| `aurorawindowwidget.advanced.button` | `Option`, `Tabs`. |
| `aurorawindowwidget.advanced.layout` | `SplitPane`, `Table`. |
| `aurorawindowwidget.advanced.mouse` | `ContextMenu`. |
| `aurorawindowwidget.advanced.panel` | `Panel`, `ComboBox`, `DropdownList`, `ListBox`, `ProgressBar`, `Scrollbar`, `ScrollView`, `Slider`. |

## Usage

```d
import aurorawindowwidget;

auto panel = new Panel();
panel.add(new Label("Content"));

auto tabs = new Tabs();
tabs.addTab("First", new Label("One"));
tabs.addTab("Second", new Label("Two"));
```

Widgets that Aurora-D already implements are re-exported unchanged; the
option, tabs, dialog, image, table, combo box, dropdown list, list box,
sidebar and tooltip controls are implemented in this package on top of the
framework primitives.

## Build and test

```text
dub build
dmd -Isource -I../aurora-d-0.4.5/source -i user32.lib gdi32.lib shell32.lib -run tests/window_widget_smoke.d
```

The smoke test constructs and lays out the widgets headlessly; it does not
open a window.

## License

0BSD, see [LICENSE](LICENSE).