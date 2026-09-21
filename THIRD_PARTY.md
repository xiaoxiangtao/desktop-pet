# 第三方素材与数据

## ECDICT 英汉词典

- 来源：https://github.com/skywind3000/ECDICT
- 作者：Linwei (skywind3000)
- 许可：MIT License，**要求署名**
- 用法：本项目**不分发**词典数据。首次运行的设置向导会从上述仓库下载
  `ecdict.csv`，在用户本机建成 SQLite（约 100 MB，落在 Application Support）。
- 署名位置：app 内「关于桌宠」、本文件、README。

ECDICT 的 MIT 许可证要求在分发时保留版权声明，因此上述署名是法律义务。

## 猫的美术素材

`DesktopPet/Sources/PetAnimation/Resources/` 下的 `cat-poses.webp`、
`cat-sleep-breath.webp`、`icon.icns`、`tray-icon.png` 由本项目作者用 AI 生成后
手工加工（裁切、对齐、拼雪碧图、补中间帧），随本项目一同以 MIT 许可发布。

## 系统框架

语音识别用 macOS 自带的 `SpeechAnalyzer`（Speech.framework），系统音频采集用
`ScreenCaptureKit`。两者都是 Apple 的系统框架，不随本项目分发。
