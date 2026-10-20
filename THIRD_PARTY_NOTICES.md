# Third-party notices

Glance Studio is free software under the GNU General Public License v3.0 (see `LICENSE`). It contains or downloads
the following work by others, each under its own licence. All of them are compatible with the GPL-3.0.

| Component | Where | Licence |
|---|---|---|
| [Ghostty](https://github.com/ghostty-org/ghostty), the terminal Glance Studio is built on | `terminal/` | MIT (below) |
| Ghostty's vendored libraries and fonts | `terminal/pkg/`, `terminal/vendor/`, `terminal/src/font/res/` | each under the licence file next to it |
| [Sparkle](https://sparkle-project.org) (updates) | Swift package of `terminal/macos` | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) (on-device speech) | Swift package | Apache-2.0 |
| [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) voice model (Core ML conversion by FluidInference), downloaded at build time | `.models/` (not in the repository) | Apache-2.0 |
| [markdown-it](https://github.com/markdown-it/markdown-it) | `Web/vendor/markdown-it.min.js` | MIT |
| [highlight.js](https://highlightjs.org) | `Web/vendor/highlight.min.js`, `github-dark.min.css` | BSD-3-Clause |
| [Mermaid](https://mermaid.js.org) | `Web/vendor/mermaid.min.js` | MIT |
| DM Sans, JetBrains Mono | `Web/vendor/fonts/` | SIL Open Font License 1.1 (`Web/vendor/fonts/LICENSE.md`) |
| [Monaco Editor](https://github.com/microsoft/monaco-editor), [Prettier](https://prettier.io), bundled at build time | `tools/editor-bundle/` | MIT |

## Ghostty

```
MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Sparkle

```
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

Sparkle also bundles third-party code under its own notices (bsdiff, sais, ed25519); see Sparkle's `LICENSE` file.

## Apache-2.0 components

FluidAudio and the Kokoro-82M model are used under the Apache License, Version 2.0
(https://www.apache.org/licenses/LICENSE-2.0). Kokoro-82M is by hexgrad; the Core ML conversion is by FluidInference.
