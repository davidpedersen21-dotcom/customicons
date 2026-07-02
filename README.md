# Custom Icon

Rainbow-Folders-style tool for Windows: right-click a folder → **Custom Icon** →
describe the icon you want → an AI generates it → it's converted to a proper
multi-size `.ico` and applied to the folder.

## Install

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

No admin rights needed (installs per-user). On **Windows 11** the entry appears
under **"Show more options"** in the right-click menu (or press Shift+F10).

Uninstall with `uninstall.ps1` (add `-PurgeConfig` to also delete saved API keys).

## Usage

1. Right-click a folder → **Custom Icon**
2. Type a description, e.g. `a blue treasure chest, pixel art` or `minimalist camera, pastel colors`
3. Pick a provider and click **Generate** — a preview appears
4. Click **Apply to Folder** (or Generate again until you like it)
5. **Remove Custom Icon** restores the default folder look

## Providers (image generation)

| Provider | API key needed? | Notes |
|---|---|---|
| **Pollinations** | No — free | The default. Works out of the box. |
| **OpenAI** | Yes | Uses `gpt-image-1` (native transparency), falls back to DALL-E 3. |
| **Gemini** | Yes | Uses `gemini-2.5-flash-image`. |

> **Why no Claude/DeepSeek image option?** Those APIs don't generate images —
> they're text models. Instead, their keys can power the *prompt enhancer* below.

## Settings (the config you asked for)

Click **Settings…** in the app to store:

- **API keys** for OpenAI, Gemini, Claude, and DeepSeek
- **Prompt enhancer**: `none | claude | deepseek | openai | gemini` — rewrites
  your short description into a detailed icon prompt before generating
- **Transparent background**: auto-removes the solid background from generated
  images so icons look like real icons, not squares

Config is stored at `%APPDATA%\CustomIcon\config.json`. You can also edit it by hand:

```json
{
  "provider": "pollinations",
  "enhancer": "claude",
  "openai_api_key": "",
  "gemini_api_key": "",
  "claude_api_key": "sk-ant-...",
  "deepseek_api_key": "",
  "remove_background": true
}
```

## How it applies icons

- Saves the icon as a hidden `CustomIcon_<timestamp>.ico` **inside the folder**
  (so the icon travels with the folder if you move it)
- Writes/updates `desktop.ini` with `IconResource=` and sets the folder's
  ReadOnly attribute so Explorer honors it
- A fresh filename per apply busts Windows' icon cache — no stale icons

## Test without the GUI

```powershell
powershell -ExecutionPolicy Bypass -File .\CustomIcon.ps1 -SelfTest
```

Verifies image→ICO conversion, desktop.ini writing, and cleanup end to end.
