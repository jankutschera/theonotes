# Font licence texts

Copies of the licence files of the fonts behind the maths rendering. They are the input
of the Acknowledgements entries (`assets` in `scripts/acknowledgements-config.json`); the app shows
them from `Acknowledgements.json`, not from this folder. Never edit them: they are upstream's text.

| File | Font | Upstream file | sha256 |
| --- | --- | --- | --- |
| `STIXTwo-OFL.txt` | STIX Two Math and Text, 2.13 b171 | `OFL.txt` in https://github.com/stipub/stixfonts, release v2.13b171 (identical on the default branch on 2026-10-27) | `0c8825913b60d858aacdb33c4ca6660a7d64b0d6464702efbb19313f5765861a` |
| `SourceSansPro-OFL.txt` | Source Sans Pro, release 2.045 | `LICENSE.txt` at tag `2.045R-ro/1.095R-it` of https://github.com/adobe-fonts/source-sans | `e1d1fdcefb57985226c06fa9500d29caacfa2b1f8b8c74db911f13c6cad186a1` |

Facts read from the primary sources (2026-10-27):

- STIX Two is licensed under the SIL Open Font License 1.1. The copyright line of `OFL.txt` is
  "Copyright 2001-2021 The STIX Fonts Project Authors (https://github.com/stipub/stixfonts), with
  Reserved Font Name "TM Math"". The name table of the font files themselves
  (`STIXTwoMath-Regular.otf`, `STIXTwoText-Regular.otf`, release 2.13 b171) carries the same
  copyright without a Reserved Font Name and adds: "STIX Fonts and STIX Two are trademarks of The
  Institute of Electrical and Electronics Engineers, Inc."; designers Ross Mills, John Hudson and
  Paul Hanslow (Tiro Typeworks Ltd), with prior portions by MicroPress Inc. and Coen Hoffman; the
  math sans-serif alphanumerics are derived from Source Sans, designed by Paul Hunt.
- `FONTLOG.txt` of the release: the sans-serif and sans-serif bold digits and letters ranges
  marked [SSP] are "derived from the Source Sans Pro fonts, with proportions and weight modified".
- Source Sans Pro is licensed under the same OFL 1.1, "with Reserved Font Name 'Source'".
- `@mathjax/mathjax-stix2-font` 4.1.3 (npm tarball sha256
  `664c8c40d739a231016cd6108cb6401166151772913e82b802bdd4b64812acf5`, registry integrity
  `sha512-DjJh93JuKodoYmvWawiqa22y/dwP+hn6/DN/DepFRFaRbdndNcSD3iBsBunSrLPFIJBS83mn4iR015YRPWZWhg==`)
  names its inputs in its shipped definition `def/mathjax-stix2.ts`: only `STIXTwoMath-Regular.otf`
  and `STIXTwoText-{Regular,Bold,Italic,BoldItalic}.otf`. The package has no licence file and
  declares Apache-2.0; its build repository (mathjax/MathJax-fonts) is not public.
