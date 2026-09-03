# Third-party licenses

TypeFlow itself is licensed under **AGPL-3.0-or-later** (see [LICENSE](LICENSE)).
It builds on the following third-party components, each under its own license.
Versions are the ones pinned in [`Package.resolved`](Package.resolved).

## Swift package dependencies

| Component | Version | License | Source |
|---|---|---|---|
| WhisperKit | 0.18.0 | MIT | https://github.com/argmaxinc/WhisperKit |
| swift-transformers | 1.1.9 | Apache-2.0 | https://github.com/huggingface/swift-transformers |
| swift-jinja | 2.4.1 | Apache-2.0 | https://github.com/huggingface/swift-jinja |
| swift-argument-parser | 1.8.2 | Apache-2.0 | https://github.com/apple/swift-argument-parser |
| swift-asn1 | 1.7.1 | Apache-2.0 | https://github.com/apple/swift-asn1 |
| swift-collections | 1.6.0 | Apache-2.0 | https://github.com/apple/swift-collections |
| swift-crypto | 4.5.1 | Apache-2.0 | https://github.com/apple/swift-crypto |
| yyjson | 0.12.0 | MIT | https://github.com/ibireme/yyjson |

Apache-2.0 requires that its notices travel with redistributions; this file,
together with the upstream `LICENSE` files inside each package checkout, serves
that purpose.

## Speech recognition models

TypeFlow does not train or ship its own speech models. It runs **OpenAI
Whisper** models converted to CoreML by Argmax and distributed through Hugging
Face:

| Component | License | Source |
|---|---|---|
| OpenAI Whisper (model weights and original implementation) | MIT | https://github.com/openai/whisper |
| whisperkit-coreml (CoreML conversions of the above) | MIT | https://huggingface.co/argmaxinc/whisperkit-coreml |
| ivrit.ai Whisper Large v3 Turbo (Hebrew fine-tune) | Apache-2.0 | https://huggingface.co/ivrit-ai/whisper-large-v3-turbo |
| CoreML conversion of the ivrit.ai model, by Eran Shir | MIT | https://huggingface.co/eranshir/ivrit-ai-whisper-large-v3-turbo-coreml |

Models are downloaded on demand at runtime (`scripts/install-hebrew-model.sh`
for the Hebrew one) and are **not** redistributed as part of this repository.

## Optional local cleanup model

The cleanup feature talks to any OpenAI-compatible server on localhost. The
documented default is [LM Studio](https://lmstudio.ai) (proprietary, free for
personal use — its own terms apply) serving **Qwen3-4B-Instruct-2507**
(Apache-2.0, https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507). Neither is
bundled with, or required by, TypeFlow.

## Upstream project

TypeFlow is a fork of **VocaMac** by Jatin Kumar Malik, licensed AGPL-3.0.
See [NOTICE](NOTICE) for attribution and the record of modifications.
