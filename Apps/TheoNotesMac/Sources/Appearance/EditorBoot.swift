// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// The scripts that paint the page in the editor's look before the editor has received `setSettings`.
///
/// A page boots with the editor's default (Theo Notes Red) look, and the real look arrives with the first
/// `setSettings`. Without help, a dark or OLED editor would show a white page for the frames in between,
/// in every new window and after every web-process restart. `bootScript` is a document-start user script
/// that gives the root the theme's background and `color-scheme` (and the `--bc-*` variables), and adds a
/// style rule (`#bc-boot`) that paints the editor element the same colour the moment it mounts.
/// `settleScript` runs once the page is ready and after every later change: it keeps the root in step with
/// the look and removes the boot rule and the root variables, so the editor's own settings (the
/// authoritative path, with the editor-side validation) are the only thing that styles the editor.
///
/// Nothing here is free text: variables go through `ThemeSchema.sanitize` (only `--bc-<schema token>` with a
/// `#rrggbb[aa]` value) and the colours are re-validated as hex, and everything is embedded as JSON.
enum EditorBoot {
    static let styleId = "bc-boot"

    static func bootScript(for look: EditorLook) -> String {
        let variables = ThemeSchema.sanitize(variables: look.theme)
        let background = hex(look.backgroundHex)
        let rule = "html,body{background-color:\(background)}html .cm-editor{background-color:\(background)}"
        return """
            (function(){
              var r=document.documentElement;
              var v=\(json(variables));
              for(var k in v){r.style.setProperty(k,v[k]);}
              r.style.backgroundColor=\(json(background));
              r.style.colorScheme=\(json(look.appearance.rawValue));
              var s=document.createElement("style");
              s.id=\(json(styleId));
              s.textContent=\(json(rule));
              r.appendChild(s);
            })();
            """
    }

    static func settleScript(for look: EditorLook) -> String {
        """
        (function(){
          var r=document.documentElement;
          for(var i=r.style.length-1;i>=0;i--){var n=r.style[i];if(n.indexOf("--bc-")===0){r.style.removeProperty(n);}}
          r.style.backgroundColor=\(json(hex(look.backgroundHex)));
          r.style.colorScheme=\(json(look.appearance.rawValue));
          var b=document.getElementById(\(json(styleId)));
          if(b){b.remove();}
        })();
        """
    }

    /// A colour that is exactly `#rrggbb[aa]`, else white (the default theme's page).
    private static func hex(_ value: String) -> String {
        ThemeColor(hex: value) != nil ? value : "#ffffff"
    }

    private static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8)
        else { return "null" }
        // `[value]` -> `value`
        return String(text.dropFirst().dropLast())
    }
}
