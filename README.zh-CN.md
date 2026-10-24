# Waifu2x Desktop

[English](README.md) | **简体中文**

原生 macOS 图片放大与降噪应用，在本机处理图片，以安静的青绿色工作区呈现画面细节。

**版本 1.0.1 · macOS 26 或更高版本**

## 下载与安装

从 [Releases](https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/latest) 下载 **Apple Silicon（arm64）** DMG 或 ZIP。打开 DMG 后将 **Waifu2x** 拖入 **Applications（应用程序）**；使用 ZIP 时，解压后将应用移入应用程序目录。安装包要求 macOS 26 或更高版本，不支持 Intel Mac。可使用附带的 `SHA256SUMS` 核对下载文件。

应用使用无需证书的临时签名（ad-hoc），**未使用 Developer ID 签名，未经 Apple 公证**。若 macOS 阻止首次打开，且你信任此下载，可先尝试打开应用，再前往 **系统设置 → 隐私与安全性 → 仍要打开**。详见 [Apple 操作说明](https://support.apple.com/zh-cn/102445)。

## 功能

- 将图片放大至 2× 或 4×，也可保持原始尺寸，仅进行降噪
- 为插画、扫描画稿和照片选择合适的模型，调整降噪强度、透明度处理及可选的 TTA
- 将多张图片加入队列，增强所选图片或整个批次，并导出无损 PNG
- 拖动原图与结果之间的分界线，结合缩放、平移和实际像素预览检查细节
- 通过带动画的首次启动教程熟悉操作，也可试用内置示例画作
- 支持英语、简体中文、繁体中文、日语、法语、韩语和俄语，界面跟随系统首选语言

## 首次启动与模型下载

首次使用按以下顺序进入工作区：**开屏 → 模型准备 → 教程 → 工作区**。

模型权重按需下载，不随应用内置。1.0.1 版本从本项目的 GitHub Release 下载单个压缩归档 [`Waifu2x-models-v1.tar.xz`](https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/download/v1.0.1/Waifu2x-models-v1.tar.xz)，实际下载 **839,373,332 字节（约 839 MB）**，比解压后的模型数据**减少约 23.4%**。解压后包含 **99 个模型及辅助文件**，合计 **1,095,327,613 字节，约 1.1 GB**。下载页面显示真实进度，支持暂停、继续和重试，左侧山海画作随下载进度逐步成形。归档包及解压后的每个文件在使用前均会核对预期大小及 SHA-256 校验值。

归档包保留以下上游来源的原始模型文件：

- ONNX 模型及辅助计算图：[unlimited.waifu2x.net/models](https://unlimited.waifu2x.net/models/)，来源为 [nagadomi/nunif](https://github.com/nagadomi/nunif/tree/master/waifu2x/unlimited_waifu2x)
- CUNet 与 Upconv ncnn 模型：[waifu2x-ncnn-vulkan 的 20250915 发布版本](https://github.com/nihui/waifu2x-ncnn-vulkan/releases/tag/20250915)，固定至提交 [`a86cfb0`](https://github.com/nihui/waifu2x-ncnn-vulkan/tree/a86cfb043e6482b5f08778a114df9b5faf6e73b7/models)

归档包的实际下载大小、地址及校验值，以及原始文件的来源地址、大小和校验值，均记录于 [ModelCatalog.json](Waifu2x/Resources/ModelCatalog.json)。缺少模型时需要联网下载；图片增强在 Mac 本机完成，图片不会上传。

## 构建与运行

环境要求：

- macOS 26 或更高版本
- Xcode 27 或更高版本，并选中其开发工具链
- Python 3
- 首次准备运行库及下载模型时需要网络连接

```sh
git clone https://github.com/SteveTanSaMa/Waifu2x-Desktop.git
cd Waifu2x-Desktop
./script/bootstrap.sh
open Waifu2x.xcodeproj
```

在 Xcode 中选择 **Waifu2x** scheme 和 **My Mac**，运行应用。也可从终端构建并启动：

```sh
./script/build_and_run.sh
```

`bootstrap.sh` 下载固定版本的 ONNX Runtime **1.23.2** macOS 通用运行库与头文件，以及 **20250915** 版 ncnn 推理程序。脚本校验下载归档后，准备被 Git 忽略的 `Vendor/` 与运行时目录，不安装应用所需的模型权重。依赖版本和校验值记录于 [runtime-dependencies.json](script/runtime-dependencies.json)。

仓库已包含 Xcode 工程。[XcodeGen](https://github.com/yonaskolb/XcodeGen) 是可选工具，仅在修改 `project.yml` 后重新生成工程时使用：

```sh
xcodegen generate
```

### Apple Silicon 发布包

```sh
bash script/package_release.sh
```

在 Apple Silicon Mac 上，此脚本构建 Release 应用，将所有内置 Mach-O 程序和动态库裁剪为 arm64，应用无需证书的临时签名并验证应用包，最后在 `dist/` 生成 DMG、ZIP 与 `SHA256SUMS`。模型权重不随包内置。

使用已验证的模型缓存准备独立模型归档：

```sh
python3 script/fetch_test_models.py
python3 script/package_models.py --release v1.0.1 --update-catalog
```

此操作生成 `dist/Waifu2x-models-v1.tar.xz`，并将归档信息写入清单。归档直接包含清单中的相对路径 `ONNXModels/` 与 `Engine/`，没有额外的外层目录。

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

模型归档工具测试无需 Xcode 或网络连接：

```sh
python3 -m unittest discover -s script -p test_fetch_test_models.py
```

## 画作与第三方组件

当前图标源文件和重新生成资源的说明见 [Design](Design/README.md)。

应用使用 ONNX Runtime 与 waifu2x-ncnn-vulkan。模型及依赖的来源、版权和许可证文本保留于 [第三方声明](Waifu2x/Resources/Engine/ThirdPartyNotices.md)。

Copyright © 2026 Steve Tan。第三方组件适用各自的许可证。
