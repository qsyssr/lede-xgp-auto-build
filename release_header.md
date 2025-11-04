对西瓜皮V3支持的变更已合并至 LEDE [8547db9c](https://github.com/coolsnowwolf/lede/commit/8547db9c25d697d9d966f8f8e91c6a74066ff243)

第一次使用前请先阅读 [README.md](https://github.com/zzzz0317/lede-xgp-auto-build/blob/main/README.md)

通过转接板连接的 PCIe 5G 模块在刷机后需要断电（直接拔DC插头，拔市电那头要多等几秒电容放电）一次，否则大概率找不到模块，转接板硬件原因导致模块在重启时不能正常下电。

QModem 现已同步 main 分支更新

MBIM 模式若无法正常拨号请在 QWRT模组管理 -> 拨号总览 -> 模组配置 -> 高级设置 中指定 APN，详见 [QModem Issues #129](https://github.com/FUjr/QModem/issues/129)
