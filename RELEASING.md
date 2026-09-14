# Conductor 发布

Conductor 1.0.0 固定使用 sing-box 1.14.0。发布脚本会拒绝其他版本。

```bash
SING_BOX_BINARY=/opt/homebrew/bin/sing-box ./scripts/package-release.sh
```

设置 `CODE_SIGN_IDENTITY` 时，脚本会签名内置二进制和应用。正式发布仍需使用 Apple Developer ID 完成公证和 stapling。

分别在 Apple Silicon 和 Intel 构建后：

1. 将两个 ZIP 上传到 GitHub Release `v1.0.0`。
2. 把脚本输出的 SHA-256 写入 `Casks/conductor.rb.template`。
3. 将完成的文件复制到 `hyfly233/homebrew-conductor` 的 `Casks/conductor.rb`。
4. 执行 `brew audit --cask --strict conductor`。
5. 在干净机器测试 `brew install --cask hyfly233/conductor/conductor`。

普通卸载和升级不删除 `~/sing-box`。Cask 的 `zap` 也有意不包含该目录。
