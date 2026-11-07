# RGB Suite
A small app with full RGB controls for handheld devices running [MustardOS](https://muos.dev), compatible with Anbernic and TrimUI devices.

![preview](https://github.com/user-attachments/assets/b5f6fb11-9b24-4561-9b6d-88b67e78d08f)

https://github.com/user-attachments/assets/ef946204-35de-4c2c-955d-9ccb7d998325
> The tech demo above is [mer ork](https://www.lexaloffle.com/bbs/?pid=152206), running natively on MustardOS with Pico-8 RasPi, showcasing the Screen React RGB mode. Volume up!

## ⭐️ RGB modes
- **Static**: fixed color.
- **Breathing**: fixed color smoothly fading in and out.
- **Combo**: a different fixed color on each stick.
- **Theme**: follows the theme color, if provided.
- **Color Cycle**: smooth cycling between different colors.
- **Rainbow**: multicolored spinning ring on each stick.
- **Sparkle**: fixed color with random accent highlights.
- **Screen React**: bias lighting from the colors on screen.
- **Stick React**: fixed color with an accent following each stick direction.
Please note certain modes are not available on TrimUI devices due to different led board specs.

## 📐 Compatibility
**This app is built specifically for MustardOS Andromeda and might not work with other versions of MustardOS.** Compatibility covers H700 Anbernic devices and TrimUI devices, but has only been tested on Anbernic RGCubeXX. Please let me know for any TrimUI compatibility problem!

## 📦 Installation
**Step 1**: download the latest package from [Releases](https://github.com/DanjelRicci/RGB-Suite/releases) and place it into the `ARCHIVE` folder of your MustardOS storage. Go to Applications > Archive Manager, select *RGB_Suite* to install it.

**Step 2**: go to Configuration > General > Additionals (page 2) > Device Lights, set *Mode* to *External*. This leaves full led control to external apps.

**Step 3**: go to Configuration > Press X to enter Advanced mode > System (page 8), enable *User init scripts*. This ensures the background process of RGB Suite can restart when you boot the console.

## ▶️ Usage
Launch RGB Suite from the Applications list. The app is very straightforward and all controls are listed at the bottom.
- **Mode**: choose between 9 different RGB modes, or Off. Certain modes have additional control options.
- **Brightness mode**: manually adjust the led brightness, or automatically match it to the screen brightness.
- **Low Battery**: choose the RGB behavior when the battery is low.

## ⚙️ Technicals
The `rgb_suite.sh` script is responsible for all the background process thar reads the OS state, battery level, stick input and screen colors, to recreate the different RGB effects that are passed to the led board. The process has been optimized as much as possible and uses roughly 2-3% of an H700 device CPU (checked via `top` command). Quality and performance are both improved from my previous app [RGB Screen React](https://github.com/DanjelRicci/RGB-Screen-React); you can read some additional details there. The default variables in `rgb_suite.sh` don't need adjustment, but if you want to experiment with them, keep in mind that the Screen React mode is especially heavy on the CPU when increasing the sample count.

## 👥 Disclaimer and credits
This package has been built using [Claude AI](https://claude.ai/new) under my complete supervision.

Special thanks to XongleBongle, AntiKk, corey, Bitter Bizarro and the [rest of the crew](https://muos.dev/crew) for that beast that is MustardOS.

## 📋 License
[PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/) — free to use, modify, and distribute for noncommercial purposes. See [LICENSE](LICENSE) for details.
