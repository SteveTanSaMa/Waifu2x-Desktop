# Waifu2x Desktop

[English](README.md) | **简体中文**

原生 macOS 图片放大与降噪应用，在本机处理图片，以安静的青绿色工作区呈现画面细节。

**版本 1.0.3 · macOS 13.0 或更高版本**

## 下载与安装

从 [Releases](https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/latest) 下载 **Apple Silicon（arm64）** DMG 或 ZIP。打开 DMG 后将 **Waifu2x** 拖入 **Applications（应用程序）**；使用 ZIP 时，解压后将应用移入应用程序目录。安装包要求 macOS 13.0 或更高版本，不支持 Intel Mac。可使用附带的 `SHA256SUMS` 核对下载文件。

应用使用无需证书的临时签名（ad-hoc），**未使用 Developer ID 签名，未经 Apple 公证**。若 macOS 阻止首次打开，且你信任此下载，可先尝试打开应用，再前往 **系统设置 → 隐私与安全性 → 仍要打开**。详见 [Apple 操作说明](https://support.apple.com/zh-cn/102445)。

## 功能

- 将图片放大至 2× 或 4×，也可保持原始尺寸，仅进行降噪
- 为插画、扫描画稿和照片选择合适的模型，调整降噪强度、透明度处理及可选的 TTA
- 将多张图片加入队列，增强所选图片或整个批次，并导出无损 PNG
- 拖动原图与结果之间的分界线，结合缩放、平移和实际像素预览检查细节
- 通过带动画的首次启动教程熟悉操作，也可试用内置示例画作
- 支持英语、简体中文、繁体中文、日语、法语、韩语和俄语，可跟随系统或在设置中手动选择，切换即时生效
- 在紧凑的独立设置窗口中选择外观、重新查看教程，以及查看版本和 GitHub 项目
- 可开启后台批量增强完成通知，仅在增强运行期间防止 Mac 自动睡眠
- 手动检查软件更新，也可每天在启动时检查一次正式版本
- 支持应用增量下载，缺少兼容增量包时回退到经过校验的完整下载
- 通过带扫描动画的只读检查，核对应用签名与模型文件完整性
- 在设置中查看模型占用空间，直接修复缺失或损坏的模型
- 复制应用、系统、运行库与模型状态用于反馈，不包含个人路径或图片名称

## 首次启动与模型下载

首次使用按以下顺序进入工作区：**开屏 → 模型准备 → 教程 → 工作区**。

校验完成后，完整的山海画面会柔和淡出并进入教程；已完成教程的用户直接进入工作区。转场适配“减少动态效果”。

后续启动会在开屏动画下校验已安装的模型，再进入工作区。仅当文件需要下载、解压或准备过程出现异常时，才显示模型准备页面。

模型权重按需下载，不随应用内置。1.0.3 版本从本项目的 GitHub Release 下载单个压缩归档 [`Waifu2x-models-v1.tar.xz`](https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/download/v1.0.3/Waifu2x-models-v1.tar.xz)，实际下载 **839,373,332 字节（约 839 MB）**，比解压后的模型数据**减少约 23.4%**。解压后包含 **99 个模型及辅助文件**，合计 **1,095,327,613 字节，约 1.1 GB**。下载页面显示真实进度，支持暂停、继续和重试，左侧山海画作随下载进度逐步成形。归档包及解压后的每个文件在使用前均会核对预期大小及 SHA-256 校验值。

归档包保留以下上游来源的原始模型文件：

- ONNX 模型及辅助计算图：[unlimited.waifu2x.net/models](https://unlimited.waifu2x.net/models/)，来源为 [nagadomi/nunif](https://github.com/nagadomi/nunif/tree/master/waifu2x/unlimited_waifu2x)
- CUNet 与 Upconv ncnn 模型：[waifu2x-ncnn-vulkan 的 20250915 发布版本](https://github.com/nihui/waifu2x-ncnn-vulkan/releases/tag/20250915)，固定至提交 [`a86cfb0`](https://github.com/nihui/waifu2x-ncnn-vulkan/tree/a86cfb043e6482b5f08778a114df9b5faf6e73b7/models)

归档包的实际下载大小、地址及校验值，以及原始文件的来源地址、大小和校验值，均记录于 [ModelCatalog.json](Waifu2x/Resources/ModelCatalog.json)。缺少模型时需要联网下载；图片增强在 Mac 本机完成，图片不会上传。

如果只有部分模型缺失或损坏，启动时会先核对已有文件，再下载所需的压缩修复包；相同内容只下载一次。每个修复文件校验通过后原子替换，最后再次核对完整模型集合。修复资源不可用，或完整归档更省流量时，会使用经过校验的完整模型包。首次安装仍只下载一个归档。

也可在**设置 → 模型与文件**中检查安装状态，发现异常后选择**修复模型**。关闭设置窗口后修复仍会继续，模型全部校验通过后即可再次增强图片。

## 应用更新

在**设置 → 软件更新**中检查并下载更新。提供 `Waifu2x-update.json` 的 Release 可以使用更小的文件级增量包：复用未变化的应用文件，只下载变化部分。已安装版本不匹配、文件被修改、增量包不可用或校验失败时，回退到完整 ZIP。最终文件与应用签名均在独立暂存目录中校验。

下载完成后，选择**在 Finder 中查看更新**，退出 Waifu2x，再将已验证的新应用替换到应用程序目录。下载过程不会覆盖正在运行的应用。旧 Release 未提供更新清单时，仍可通过 GitHub 链接下载。模型修复包及应用增量资源需随 Release 发布后，才能在线使用。

## 构建与运行

环境要求：

- 支持 Xcode 27 或更高版本的构建主机，并选中其开发工具链
- 应用运行目标：macOS 13.0 或更高版本
- Python 3.10 或更高版本、CMake、Ninja、Node.js、npm 和 Git
- 首次准备运行库及下载模型时需要网络连接

```sh
git clone https://github.com/SteveTanSaMa/Waifu2x-Desktop.git
cd Waifu2x-Desktop
open Waifu2x.xcodeproj
```

在 Xcode 中选择 **Waifu2x** scheme 和 **My Mac**，运行应用。构建会自动补齐缺失的运行库并校验，即使清理过本地构建文件也无需手动恢复依赖。也可从终端构建并启动：

```sh
./script/build_and_run.sh
```

构建会调用 `bootstrap.sh`，下载固定版本的 ONNX Runtime **1.23.2** macOS 通用运行库与头文件，以及 **20250915** 版 ncnn 推理程序。脚本校验下载归档后，准备被 Git 忽略的 `Vendor/` 与运行时目录，后续构建会复用校验通过的本地依赖。也可单独执行 `./script/bootstrap.sh`。为覆盖 macOS 13.0–13.3，构建会重新编译同版本 ONNX Runtime，并保留 CPU、CoreML 与 WebGPU；上游二进制最低要求为 macOS 13.4。首次源码构建需要更长时间，后续构建复用校验过的缓存，详见 [macOS 13 运行库构建说明](script/onnxruntime-macos13.md)。此过程不安装应用所需的模型权重。依赖版本和校验值记录于 [runtime-dependencies.json](script/runtime-dependencies.json)。

仓库已包含 Xcode 工程。[XcodeGen](https://github.com/yonaskolb/XcodeGen) 是可选工具，仅在修改 `project.yml` 后重新生成工程时使用：

```sh
xcodegen generate
```

### Apple Silicon 发布包

```sh
bash script/package_release.sh
```

在 Apple Silicon Mac 上，此脚本构建 Release 应用，将所有内置 Mach-O 程序和动态库裁剪为 arm64，应用无需证书的临时签名并验证应用包，最后在 `dist/` 生成 DMG、ZIP 与 `SHA256SUMS`。模型权重不随包内置。

脚本还会生成 `Waifu2x-update.json`。若需对比之前的正式 ZIP 生成增量包，可执行 `APP_UPDATE_BASE_ZIP=/path/to/previous.zip bash script/package_release.sh`。GitHub Actions 会自动获取上一正式版本；没有可用基础包时，更新清单提供完整下载。

使用已验证的模型缓存准备独立模型归档：

```sh
python3 script/fetch_test_models.py
python3 script/package_models.py --release v1.0.3 --update-catalog
```

此操作生成 `dist/Waifu2x-models-v1.tar.xz`，并将归档信息写入清单。归档直接包含清单中的相对路径 `ONNXModels/` 与 `Engine/`，没有额外的外层目录。

同时会生成修复索引和按内容去重的修复包。若只需从已验证缓存生成修复资源，可执行 `python3 script/package_models.py --release vX.Y.Z --repair-only`。发布 CI 会从已验证的完整归档生成这些资源，并连同应用更新清单及可用的应用增量包上传。

[GitHub Actions](.github/workflows/release.yml) 在 Apple Silicon 上使用 Xcode 27.0，对 `main` 推送、拉取请求和手动运行执行单元测试并打包。发布前，先更新应用版本号和清单中的归档信息，再准备目标为最终提交 SHA 的 `vX.Y.Z` 草稿发布，并上传清单指定的模型归档包。清单中的归档地址必须指向此次发布，记录的大小和 SHA-256 必须与已上传的归档一致。

发布已准备的版本时，推送对应的 `vX.Y.Z` 标签，或向 `main` 推送首行严格为 `release: vX.Y.Z` 的提交；也可在 `main` 手动运行工作流并启用 **publish**。工作流会核对草稿所指向的提交，下载并验证已有模型归档，将其与 DMG、ZIP 一并列入 `SHA256SUMS`。只有测试、打包和校验全部通过后，才会以 **Waifu2x Desktop X.Y.Z** 为标题公开发布；工作流不会覆盖已发布的版本。

## 测试

运行不依赖模型权重的测试：

```sh
./script/test.sh --unit
```

直接运行 `./script/test.sh` 也使用此默认模式；需要真实推理的测试会明确标记为跳过。

运行包含真实推理的完整测试：

```sh
./script/test.sh --integration
```

集成测试会离线复用完整且通过 SHA-256 验证的缓存；缓存不完整时，下载单个模型归档并核对大小与校验值，安全解压并逐一验证文件后，再替换被 Git 忽略的 `build/TestModels/models-v1/` 缓存。也可单独准备或检查测试缓存：

```sh
python3 script/fetch_test_models.py
python3 script/fetch_test_models.py --check
```

`--check` 只检查本地文件大小和校验值，不联网下载。在 Xcode 中使用 **⌘U** 时，缺少模型会跳过推理测试，存在有效缓存时则实际运行。

发布前，可将本地归档校验并安装到全新缓存：

```sh
python3 script/fetch_test_models.py --archive dist/Waifu2x-models-v1.tar.xz --root build/FreshTestModels/models-v1
python3 script/fetch_test_models.py --check --root build/FreshTestModels/models-v1
```

模型归档与增量打包工具测试无需 Xcode 或网络连接：

```sh
python3 -m unittest discover -s script -p 'test_*.py'
```

## 画作与第三方组件

当前图标源文件和重新生成资源的说明见 [Design](Design/README.md)。

应用使用 ONNX Runtime 与 waifu2x-ncnn-vulkan。模型及依赖的来源、版权和许可证文本保留于 [第三方声明](Waifu2x/Resources/Engine/ThirdPartyNotices.md)。

Copyright © 2026 Steve Tan。第三方组件适用各自的许可证。
