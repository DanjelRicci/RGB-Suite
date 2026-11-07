# RGB Suite
A small app with full RGB controls for handheld devices running [MustardOS](https://muos.dev), compatible with Anbernic and TrimUI devices.

<img width="1920" height="1440" alt="preview-small" src="https://github.com/user-attachments/assets/d2b2b840-378a-4843-9643-f6348e8397eb" />

https://github.com/user-attachments/assets/8cf09f31-3f2b-45a4-8b6b-9a73301d4889
> This is [mer ork](https://www.lexaloffle.com/bbs/?pid=152206) running on native Pico-8, showcasing the *Screen React* RGB mode. Volume up!

## ⭐️ Overview
- Many RGB modes in one app
- Integrates with all MustardOS energy saving features
- Unique *Screen React* mode supporting any aspect ratio
- Extremely CPU efficient background process
- User friendly, requires minimal one-time setup

## 💡 RGB modes
- **Static**: fixed color.
- **Breathing**: fixed color smoothly fading in and out.
- **Combo**: a different fixed color on each stick.
- **Theme**: follows the fixed theme color, if provided.
- **Color Cycle**: smooth cycling between different colors.
- **Rainbow**: multicolor spinning ring on each stick.
- **Sparkle**: fixed color with random accent highlights.
- **Screen React**: bias lighting from the colors on screen.
- **Stick React**: fixed color with an accent following the stick direction.

*Please note certain modes are not available on TrimUI devices due to different led board specs.*

## 🔗 Compatibility
**This app is built specifically for MustardOS Andromeda and might not work with other versions of MustardOS.** Compatibility covers H700 Anbernic devices and TrimUI devices, but has only been tested on Anbernic RGCubeXX. Please let me know for any TrimUI compatibility problem!

The app correctly interfaces with MustardOS power functions like sleep, screensaver, screen dim and low battery.

## 📦 Installation
- **Step 1**: download the latest package from [Releases](https://github.com/DanjelRicci/RGB-Suite/releases) and place it into the `ARCHIVE` folder of your MustardOS storage. Go to Applications > Archive Manager, select *RGB_Suite* to install it.
- **Step 2**: go to Configuration > General > Additionals (page 2) > Device Lights, set *Mode* to *External*. This leaves full led control to external apps.
- **Step 3**: go to Configuration > Press X to enter Advanced mode > System (page 8), enable *User init scripts*. This ensures the background process of RGB Suite can restart when you boot the console.

## ▶️ Usage
Launch RGB Suite from the Applications list. The app is very straightforward and all controls are listed at the bottom of the screen.
- **Mode**: choose between 9 different RGB modes, or Off. Certain modes have additional control options.
- **Brightness mode**: manually adjust the led brightness, or automatically match it to the screen brightness.
- **Low Battery**: choose the RGB behavior when the battery is low.

## ⚙️ Technicals
The `rgb_suite.sh` script is responsible for all the background process reading the OS state, battery level, stick input and screen colors, to recreate the different RGB effects that are passed to the led board. The process has been optimized as much as possible and uses roughly 2-3% on the H700 CPU (verified via `top` command during regular emulator usage).

Sample quality and process performance have been improved from my previous app [RGB Screen React](https://github.com/DanjelRicci/RGB-Screen-React); you can read some additional details there. The default variables in `rgb_suite.sh` don't need adjustment, but if you want to experiment with them, keep in mind the Screen React mode is especially heavy on the CPU when increasing the sample count.

## 👥 Disclaimer and credits
This app has been built using [Claude Code](https://claude.com/it/product/claude-code) under my complete supervision. All frontend text including this README was written by me.

RGB Suite is a rewrite and an evolution of [RGB Screen React](https://github.com/DanjelRicci/RGB-Screen-React), which was inspired by a number of different things; please check credits there. Further inspiration for RGB Suite was drawn by [Knulli](https://knulli.org)'s own set of RGB features. 

Special thanks to XongleBongle, AntiKk, corey, Bitter Bizarro and the [rest of the crew](https://muos.dev/crew) for that beast that is MustardOS.

## 📋 License
[PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/) — free to use, modify, and distribute for noncommercial purposes. See [LICENSE](LICENSE) for details.
