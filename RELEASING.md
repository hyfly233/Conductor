# Conductor 发布

Conductor 1.0.0 打包 sing-box 1.14.0 作为基线。发布脚本要求提供的二进制版本不低于 1.14.0，低于则拒绝；版本号必须由纯数字与点号构成，预发布与构建元数据后缀一律拒绝。

```bash
SING_BOX_BINARY=/opt/homebrew/bin/sing-box ./scripts/package-release.sh
```

脚本需要上游 `LICENSE`：默认从二进制所在目录读取，也可通过 `SING_BOX_LICENSE` 指定。脚本检查二进制是否支持当前机器架构，并将许可证一同放入应用包。使用官方发布包时，应在运行脚本前核对上游文件的 SHA-256。

设置 `CODE_SIGN_IDENTITY` 时，脚本会签名内置二进制和应用并验证签名。未设置时生成的包仅供本地检查，不能作为正式分发包。正式发布仍需使用 Apple Developer ID 完成公证和 stapling。

分别在 Apple Silicon 和 Intel 构建后：

1. 将两个 ZIP 上传到 GitHub Release `v1.0.0`。
2. 把脚本输出的 SHA-256 写入 `Casks/conductor.rb.template`。
3. 将完成的文件复制到 `hyfly233/homebrew-conductor` 的 `Casks/conductor.rb`。
4. 执行 `brew audit --cask --strict conductor`。
5. 在干净机器测试 `brew install --cask hyfly233/conductor/conductor`。

普通卸载和升级不删除 `~/sing-box`。Cask 的 `zap` 也有意不包含该目录。
