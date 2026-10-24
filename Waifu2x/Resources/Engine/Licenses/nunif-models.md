# nunif / waifu2x ONNX models

Copyright (C) 2019–2023 nagadomi. MIT license: [nunif.txt](nunif.txt).

The ONNX models and helper graphs are published at [unlimited.waifu2x.net/models](https://unlimited.waifu2x.net/models/). Their source implementation is [nagadomi/nunif — unlimited_waifu2x](https://github.com/nagadomi/nunif/tree/master/waifu2x/unlimited_waifu2x).

This repository repackages the original upstream files without modification into a unified model archive distributed through [its GitHub Releases](https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases). The app downloads that archive when preparing its models; weights are not embedded in the app bundle. [ModelCatalog.json](../../ModelCatalog.json) retains each file's original upstream source URL, expected size, and SHA-256 digest, along with the archive's download URL, size, and checksum. Both the archive and its extracted files are verified before models are cached locally for image processing.

The model families include Swin UNet v3 for illustrations, Swin UNet for illustrations, scanned artwork and photos, CUNet, and the required preprocessing and TTA helper graphs. Native preprocessing and helper execution follow the upstream web implementation.

Model downloads use the network. User images are processed locally and are not uploaded. Inference uses ONNX Runtime 1.23.2, covered by its own [MIT license](onnxruntime.txt).
