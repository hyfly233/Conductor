# Conductor 发布

Conductor 1.0.0 打包 sing-box 1.14.0 作为基线。发布脚本要求提供的二进制版本不低于 1.14.0，低于则拒绝；版本号必须由纯数字与点号构成，预发布与构建元数据后缀一律拒绝。

```bash
SING_BOX_BINARY=/opt/homebrew/bin/sing-box ./scripts/package-release.sh
```

脚本需要上游 `LICENSE`：默认从二进制所在目录读取，也可通过 `SING_BOX_LICENSE` 指定。脚本检查二进制是否支持当前机器架构，并将许可证一同放入应用包。使用官方发布包时，应在运行脚本前核对上游文件的 SHA-256。

脚本在打包前后各自校验一次产物，任一项不满足即退出：

- 版本号从构建出的 `CFBundleShortVersionString` 读取，并要求与 `Casks/conductor.rb.template` 的 `version` 完全一致；不一致时拒绝，避免 ZIP 名称、应用版本和 tap 描述三者漂移。
- 图标资源集必须为每个槽位绑定 `filename` 且文件存在，否则拒绝——`actool` 遇到未绑定槽位只会静默产出空资源目录。
- 构建后确认 `AppIcon.icns` 与 `Assets.car` 存在且不早于本次构建，防止增量构建复用陈旧图标而让检查失效。
- 内置副本的 `sing-box version` 必须与校验通过的源二进制一致。

设置 `CODE_SIGN_IDENTITY` 时，脚本会签名内置二进制和应用并验证签名。未设置时脚本改为 ad-hoc 签名：把运行时放进已被 Xcode 签名的应用会破坏签名封印，不重签则 `codesign --verify` 失败；ad-hoc 包仅供本地检查，不能作为正式分发包。

需要公证时设置 `NOTARY_PROFILE`（`xcrun notarytool` 的钥匙串配置名）并同时提供 `CODE_SIGN_IDENTITY`；脚本会提交公证、staple 并 validate，只设其中一个则拒绝。未提供 `NOTARY_PROFILE` 时仍需手工完成公证和 stapling。

脚本把每个架构的 ZIP 摘要写入 `build/release/SHA256SUMS`，重复运行时替换同名行、保留另一架构的行，因此两个架构的摘要可以累积在同一文件里。

分别在 Apple Silicon 和 Intel 构建后：

1. 将两个 ZIP 与 `SHA256SUMS` 上传到 GitHub Release `v1.0.0`。
2. 把脚本输出的 SHA-256 写入 `Casks/conductor.rb.template` 的 arm/intel 槽位。
3. 将完成的文件复制到 `hyfly233/homebrew-conductor` 的 `Casks/conductor.rb`。
4. 执行 `brew audit --cask --strict conductor`。
5. 在干净机器测试 `brew install --cask hyfly233/conductor/conductor`。

普通卸载和升级不删除 `~/sing-box`。Cask 的 `zap` 也有意不包含该目录。
