# Third-party software and models

App builds include the inference runtimes and the notices listed here. Runtime binaries are obtained by the developer bootstrap; model weights and helper graphs are downloaded separately when the app prepares its models. They are not embedded in the app bundle.

Every model download is checked against the size and SHA-256 recorded in [ModelCatalog.json](../ModelCatalog.json). Image processing runs locally; model downloads require network access and do not upload user images.

## waifu2x-ncnn-vulkan

The macOS inference helper comes from [nihui/waifu2x-ncnn-vulkan, release 20250915](https://github.com/nihui/waifu2x-ncnn-vulkan/releases/tag/20250915). The app build applies its signing identity to the helper.

Copyright (c) 2019 nihui. MIT license: [LICENSE-waifu2x](LICENSE-waifu2x).

CUNet and Upconv model files are downloaded from the upstream repository at fixed commit [`a86cfb043e6482b5f08778a114df9b5faf6e73b7`](https://github.com/nihui/waifu2x-ncnn-vulkan/tree/a86cfb043e6482b5f08778a114df9b5faf6e73b7/models), corresponding to the 20250915 release. Model origins include [nagadomi/waifu2x](https://github.com/nagadomi/waifu2x) and [lltcggie/waifu2x-caffe](https://github.com/lltcggie/waifu2x-caffe); their notices are retained in [waifu2x-original.txt](Licenses/waifu2x-original.txt) and [waifu2x-caffe.txt](Licenses/waifu2x-caffe.txt).

The inference executable includes the following third-party components. Upstream license texts and notices are retained here:

| Component | Notices |
| --- | --- |
| [ncnn](https://github.com/Tencent/ncnn) | [ncnn.txt](Licenses/ncnn.txt) |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) | [MoltenVK.txt](Licenses/MoltenVK.txt) |
| [libwebp](https://github.com/webmproject/libwebp) | [libwebp.txt](Licenses/libwebp.txt) |
| [libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo) | [Licenses](Licenses/libjpeg-turbo.md), [IJG](Licenses/libjpeg-IJG.txt), [zlib](Licenses/libjpeg-zlib.txt) |
| [libpng](https://github.com/pnggroup/libpng) | [libpng.txt](Licenses/libpng.txt) |
| [zlib-ng](https://github.com/zlib-ng/zlib-ng) | [zlib-ng.txt](Licenses/zlib-ng.txt) |

This software is based in part on the work of the Independent JPEG Group.

## ONNX Runtime

[ONNX Runtime 1.23.2](https://github.com/microsoft/onnxruntime/releases/tag/v1.23.2) supplies the universal macOS inference library and development headers.

Copyright (c) Microsoft Corporation. MIT license: [onnxruntime.txt](Licenses/onnxruntime.txt). Dependency notices: [onnxruntime-third-party.txt](Licenses/onnxruntime-third-party.txt).

## nunif / waifu2x ONNX models

ONNX models and preprocessing/TTA helper graphs come from [nagadomi/nunif](https://github.com/nagadomi/nunif/tree/master/waifu2x/unlimited_waifu2x), served by [unlimited.waifu2x.net/models](https://unlimited.waifu2x.net/models/).

Copyright (C) 2019–2023 nagadomi. MIT license: [nunif.txt](Licenses/nunif.txt). Additional provenance and download details: [nunif-models.md](Licenses/nunif-models.md).
