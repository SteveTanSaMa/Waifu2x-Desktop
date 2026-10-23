# Waifu2x Desktop

[English](README.md) | **简体中文**

原生 macOS 图片放大与降噪应用，在本机处理图片，以安静的青绿色工作区呈现画面细节。

**版本 1.0.0 · macOS 26 或更高版本**

## 功能

- 将图片放大至 2× 或 4×，也可保持原始尺寸，仅进行降噪
- 为插画、扫描画稿和照片选择合适的模型，调整降噪强度、透明度处理及可选的 TTA
- 将多张图片加入队列，增强所选图片或整个批次，并导出无损 PNG
- 拖动原图与结果之间的分界线，结合缩放、平移和实际像素预览检查细节
- 通过带动画的首次启动教程熟悉操作，也可试用内置示例画作
- 支持英语、简体中文、繁体中文、日语、法语、韩语和俄语，界面跟随系统首选语言

## 首次启动与模型下载

首次使用按以下顺序进入工作区：**开屏 → 模型准备 → 教程 → 工作区**。

模型权重按需下载，不随应用内置。初始清单包含 **99 个模型及辅助文件**，合计 **1,095,327,613 字节，约 1.1 GB**。下载页面显示真实的字节和文件进度，支持暂停、继续和重试，左侧山海画作随下载进度逐步成形。模型在使用前会核对预期大小及 SHA-256 校验值。

模型直接来自上游官方来源：

- ONNX 模型及辅助计算图：[unlimited.waifu2x.net/models](https://unlimited.waifu2x.net/models/)，来源为 [nagadomi/nunif](https://github.com/nagadomi/nunif/tree/master/waifu2x/unlimited_waifu2x)
- CUNet 与 Upconv ncnn 模型：[waifu2x-ncnn-vulkan 的 20250915 发布版本](https://github.com/nihui/waifu2x-ncnn-vulkan/releases/tag/20250915)，固定至提交 [`a86cfb0`](https://github.com/nihui/waifu2x-ncnn-vulkan/tree/a86cfb043e6482b5f08778a114df9b5faf6e73b7/models)

完整下载地址、文件大小和校验值记录于 [ModelCatalog.json](Waifu2x/Resources/ModelCatalog.json)。缺少模型时需要联网下载；图片增强在 Mac 本机完成，图片不会上传。

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

集成测试会先按照清单下载模型并验证 SHA-256，缓存到被 Git 忽略的 `build/TestModels/models-v1/`。后续运行会复用已验证的文件。也可单独获取或检查测试缓存：

```sh
python3 script/fetch_test_models.py
python3 script/fetch_test_models.py --check
```

`--check` 只检查本地文件大小和校验值，不联网下载。在 Xcode 中使用 **⌘U** 时，缺少模型会跳过推理测试，存在有效缓存时则实际运行。

## 画作与第三方组件

当前图标源文件和重新生成资源的说明见 [Design](Design/README.md)。

应用使用 ONNX Runtime 与 waifu2x-ncnn-vulkan。模型及依赖的来源、版权和许可证文本保留于 [第三方声明](Waifu2x/Resources/Engine/ThirdPartyNotices.md)。

Copyright © 2026 Steve Tan。第三方组件适用各自的许可证。
