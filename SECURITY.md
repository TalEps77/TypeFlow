# Security policy

## Scope

TypeFlow runs entirely on your Mac. It has no backend, no account system and no
telemetry, so the attack surface is local: microphone capture, the global hotkey
event tap, clipboard-based text injection, and model files downloaded from
Hugging Face.

Things worth reporting:

* A way for another process to read audio, transcripts or history that TypeFlow
  stores locally.
* Anything that causes transcript text to leave the machine.
* Abuse of the Accessibility or Input Monitoring permissions TypeFlow holds.
* Tampering with the model download path.

## Reporting a vulnerability

Please **do not open a public issue** for a vulnerability. Use GitHub's private
reporting instead: **Security → Report a vulnerability** on this repository.

Include the affected version (Settings → About), macOS version, Mac model, and
the steps to reproduce. Expect an initial response within about a week; this is
a spare-time project, not a staffed product.

## Supported versions

Only the latest `main` is supported. There is no backporting.

## Vulnerabilities in dependencies

TypeFlow's transcription comes from [WhisperKit](https://github.com/argmaxinc/WhisperKit)
and the models come from Hugging Face. Report issues in those to their own
projects; if a fix requires a version bump here, open an issue and say so.
