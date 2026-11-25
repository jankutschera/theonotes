// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

enum MobileEditorBoot {
    static let marker = "// baerchen-mobile-theme\n"
    static func script(theme: Theme, boot: Bool) -> String {
        let appearance = theme.appearance.rawValue
        let variables = ThemeSchema.sanitize(variables: theme.editorVariables)
        let background = variables["--bc-color-bg"] ?? "#ffffff"
        func json<T: Encodable>(_ value: T) -> String {
            String(decoding: (try? JSONEncoder().encode(value)) ?? Data("null".utf8), as: UTF8.self)
        }
        let common = """
            var r=document.documentElement;if(!r)return;
            r.style.backgroundColor=\(json(background));r.style.colorScheme=\(json(appearance));
            """
        if boot {
            return marker + """
                (function(){\(common)
                var v=\(json(variables));for(var k in v){r.style.setProperty(k,v[k]);}
                var s=document.createElement('style');s.id='bc-mobile-boot';
                s.textContent=\(json("html,body,.cm-editor{background-color:\(background)}"));r.appendChild(s);
                })();
                """
        }
        return """
            (function(){\(common)
            for(var i=r.style.length-1;i>=0;i--){var n=r.style[i];if(n.indexOf('--bc-')===0)r.style.removeProperty(n);}
            var s=document.getElementById('bc-mobile-boot');if(s)s.remove();
            })();
            """
    }
}
